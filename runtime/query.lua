-- runtime/query.lua
-- Find form and relation queries.
--
-- Implements:
--   find family where ... order-by ... limit ... count
--   adjacent?, reachable?, shortest-path, reachable-set, inverse-adjacent?

local M = {}

-- ============================================================
-- Dynamic relation helper (mirrors eval.lua:effective_rel)
-- ============================================================

--- Merge static relation data with dynamic cache overrides stored at
--- "__rel/<rel_name>/<src>" in the state cache.
---@param rel      table?  game_table.relations[name]
---@param rel_name string
---@param cache    table?  state._cache (may be nil)
---@return table  relation object with .data
local function effective_rel(rel, rel_name, cache)
  if not cache or not rel_name then return rel end
  local prefix = "__rel/" .. rel_name .. "/"
  local plen   = #prefix
  local has_dyn = false
  for k in pairs(cache) do
    if k:sub(1, plen) == prefix then has_dyn = true; break end
  end
  if not has_dyn then return rel end
  local static = rel and rel.data or {}
  local merged = {}
  for src, tgts in pairs(static) do
    local m = {}; for t in pairs(tgts) do m[t] = true end; merged[src] = m
  end
  for k, dyn in pairs(cache) do
    if k:sub(1, plen) == prefix and type(dyn) == "table" then
      local src = k:sub(plen + 1)
      merged[src] = merged[src] or {}
      for t, v in pairs(dyn) do
        if v then merged[src][t] = true else merged[src][t] = nil end
      end
    end
  end
  return { data = merged }
end

-- ============================================================
-- find query helpers
-- ============================================================

--- Walk an expression node and collect all single-segment interp variable names
--- referenced in INTERP_PATH segments (e.g. {e} in enemies/{e}/status → "e").
--- Path-like variables (containing "/") are state-path lookups and are skipped.
--- Does NOT descend into LAMBDA_EXPR bodies (lambdas bind their own parameters).
local function collect_interp_vars(node, into)
  if not node or type(node) ~= "table" then return end
  if node.kind == "lambda_expr" then return end
  if node.kind == "interp_path" then
    for _, seg in ipairs(node.segments or {}) do
      if type(seg) == "table" and seg.interp and not seg.interp:find("/", 1, true) then
        into[seg.interp] = true
      end
    end
    return
  end
  for _, field in ipairs({"left","right","expr","condition","value","inner_expr","path"}) do
    collect_interp_vars(node[field], into)
  end
  if type(node.args) == "table" then
    for _, a in ipairs(node.args) do collect_interp_vars(a, into) end
  end
  if type(node.body) == "table" then
    if node.body.kind then
      collect_interp_vars(node.body, into)
    else
      for _, s in ipairs(node.body) do collect_interp_vars(s, into) end
    end
  end
end

-- ============================================================
-- find query
-- ============================================================

--- Execute a find query over an entity family.
---
---@param ctx     table  Evaluation context (with ctx.state)
---@param family  string Family name (e.g. "npcs")
---@param clauses table  List of clause tables from the AST
---@return table|integer  List of matching keys (or integer for count)
function M.find(ctx, family, clauses)
  local eval_mod = require("runtime.eval")

  -- Get all instantiated keys
  local keys = ctx.state:path_list(family)

  -- Extract clause info
  local where_conditions   = {}
  local relation_filters   = {}  -- within / connected-to clauses
  local order_path         = nil
  local order_dir          = "asc"
  local limit              = nil
  local count_only         = false

  for _, clause in ipairs(clauses or {}) do
    if clause.kind == "where" or clause.kind == "or_where" then
      where_conditions[#where_conditions + 1] = clause
    elseif clause.kind == "order_by" then
      order_path = clause.path
      order_dir  = clause.dir or "asc"
    elseif clause.kind == "limit" then
      limit = clause.value
    elseif clause.kind == "count" then
      count_only = true
    elseif clause.kind == "within" or clause.kind == "connected_to" then
      relation_filters[#relation_filters + 1] = clause
    end
  end

  -- Filter: evaluate where conditions with var bound to each key.
  -- Pre-scan all where conditions for interpolation variables so that non-lambda
  -- conditions can use any variable name (not only the family name) as the entity
  -- variable. All unbound single-segment interp vars found in conditions are bound
  -- to the current entity key alongside the family name itself.
  local var_name = family  -- e.g. "npc" in "find npc" (family name is the var binding)
  local where_vars = { [var_name] = true }  -- vars to bind per-entity
  for _, clause in ipairs(where_conditions) do
    collect_interp_vars(clause.condition, where_vars)
  end

  -- Pre-evaluate relation filters (src values don't change per-key)
  -- Each entry: {kind, relation, hops?, src_val?, path_val?}
  -- Relations are merged with dynamic cache overrides so relate!/unrelate! are visible.
  local compiled_rel_filters = {}
  local state_cache = ctx.state and ctx.state._cache
  for _, rf in ipairs(relation_filters) do
    local raw_rel = (ctx.game and ctx.game.relations and rf.relation_name)
                    and ctx.game.relations[rf.relation_name] or nil
    local rel = effective_rel(raw_rel, rf.relation_name, state_cache)
    if rf.kind == "within" then
      local ok_src, src_val = pcall(eval_mod.eval_expr, rf.from, ctx)
      compiled_rel_filters[#compiled_rel_filters+1] = {
        kind = "within", relation = rel, hops = rf.hops,
        src  = ok_src and src_val or nil,
      }
    elseif rf.kind == "connected_to" then
      local ok_pv, path_val = pcall(eval_mod.eval_expr, rf.path, ctx)
      compiled_rel_filters[#compiled_rel_filters+1] = {
        kind = "connected_to", relation = rel,
        target = ok_pv and path_val or nil,
      }
    end
  end

  local results = {}
  for _, key in ipairs(keys) do
    -- Bind all detected where-condition vars to the current entity key,
    -- but do not override variables already bound in the parent context.
    local bindings = {}
    for v in pairs(where_vars) do
      if ctx.vars[v] == nil then
        bindings[v] = key
      end
    end
    local child = eval_mod.child_ctx_vars(ctx, bindings)
    local passes = true

    if #where_conditions > 0 then
      -- Build OR-groups: consecutive 'where' clauses AND together within a group;
      -- each 'or_where' starts a new OR branch. Entity passes if any branch passes.
      local or_groups = {}
      local cur = {}
      for _, clause in ipairs(where_conditions) do
        if clause.kind == "or_where" then
          if #cur > 0 then or_groups[#or_groups + 1] = cur end
          cur = { clause }
        else
          cur[#cur + 1] = clause
        end
      end
      if #cur > 0 then or_groups[#or_groups + 1] = cur end

      passes = false
      for _, group in ipairs(or_groups) do
        local all = true
        for _, cond_clause in ipairs(group) do
          local ok, v = pcall(eval_mod.eval_expr, cond_clause.condition, child)
          -- If condition evaluated to a lambda closure, call it with the entity key
          if ok and type(v) == "table" and v._lambda then
            local call_lambda = eval_mod.call_lambda
            ok, v = pcall(call_lambda, v, {key}, child)
          end
          if not ok or not v then all = false; break end
        end
        if all then passes = true; break end
      end
    end

    -- Relation filters: within N hops / connected-to
    if passes and #compiled_rel_filters > 0 then
      for _, rf in ipairs(compiled_rel_filters) do
        if rf.kind == "within" then
          -- key must be reachable from rf.src within rf.hops hops (source included: 0 hops = src itself)
          if not M.reachable(rf.relation, rf.src, key, rf.hops) then
            passes = false; break
          end
        elseif rf.kind == "connected_to" then
          -- key must be directly connected to rf.target (in either direction), target excluded
          if key == rf.target
            or (not M.reachable(rf.relation, key, rf.target, nil)
                and not M.reachable(rf.relation, rf.target, key, nil)) then
            passes = false; break
          end
        end
      end
    end

    if passes then results[#results + 1] = key end
  end

  -- Order by
  if order_path then
    table.sort(results, function(a, b)
      local ca = eval_mod.child_ctx_vars(ctx, { [var_name] = a })
      local cb = eval_mod.child_ctx_vars(ctx, { [var_name] = b })
      local ok_a, va = pcall(eval_mod.eval_expr, order_path, ca)
      local ok_b, vb = pcall(eval_mod.eval_expr, order_path, cb)
      va = ok_a and va or 0
      vb = ok_b and vb or 0
      if order_dir == "desc" then
        return (va or 0) > (vb or 0)
      else
        return (va or 0) < (vb or 0)
      end
    end)
  end

  -- Limit
  if limit and #results > limit then
    local trimmed = {}
    for i = 1, limit do trimmed[i] = results[i] end
    results = trimmed
  end

  -- Count
  if count_only then return #results end
  return results
end

-- ============================================================
-- Relation queries
-- ============================================================

--- adjacent?(relation, source) → Set of nodes 1 hop from source.
---@param relation table  Relation data table
---@param source   any    Source node value
---@return table          Set of adjacent nodes {val=true, ...}
function M.adjacent(relation, source)
  local data = relation and relation.data or {}
  return data[source] or {}
end

--- reachable?(relation, source, target, max_hops?) → Bool.
---@param relation table
---@param source   any
---@param target   any
---@param max_hops integer?
---@return boolean
function M.reachable(relation, source, target, max_hops)
  if not relation then return false end
  local data = relation.data or {}
  max_hops = max_hops or 100

  if source == target then return true end

  local visited = { [source] = true }
  local queue   = { { node = source, depth = 0 } }
  local head    = 1

  while head <= #queue do
    local item    = queue[head]; head = head + 1
    if item.depth >= max_hops then break end
    local neighbours = data[item.node] or {}
    for neighbour in pairs(neighbours) do
      if neighbour == target then return true end
      if not visited[neighbour] then
        visited[neighbour] = true
        queue[#queue + 1] = { node = neighbour, depth = item.depth + 1 }
      end
    end
  end

  return false
end

--- shortest-path(relation, source, target) → List of nodes including endpoints, or nil.
---@param relation table
---@param source   any
---@param target   any
---@return table?
function M.shortest_path(relation, source, target)
  if not relation then return nil end
  local data = relation.data or {}

  if source == target then return { source } end

  local visited = {}
  local prev    = {}
  local queue   = { source }
  local head    = 1

  visited[source] = true

  while head <= #queue do
    local current = queue[head]; head = head + 1
    local neighbours = data[current] or {}
    for neighbour in pairs(neighbours) do
      if not visited[neighbour] then
        visited[neighbour] = true
        prev[neighbour]    = current
        if neighbour == target then
          -- Reconstruct path
          local path = {}
          local node = target
          while node ~= nil do
            table.insert(path, 1, node)
            node = prev[node]
          end
          return path
        end
        queue[#queue + 1] = neighbour
      end
    end
  end

  return nil  -- unreachable
end

--- reachable-set(relation, source, max_hops?) → Set of reachable nodes {node=true}.
---@param relation table
---@param source   any
---@param max_hops integer?
---@return table
function M.reachable_set(relation, source, max_hops)
  if not relation then return {} end
  local data = relation.data or {}
  max_hops = max_hops or 100

  local visited = { [source] = true }
  local queue   = { { node = source, depth = 0 } }
  local head    = 1

  while head <= #queue do
    local item    = queue[head]; head = head + 1
    if item.depth < max_hops then
      local neighbours = data[item.node] or {}
      for neighbour in pairs(neighbours) do
        if not visited[neighbour] then
          visited[neighbour] = true
          queue[#queue + 1]  = { node = neighbour, depth = item.depth + 1 }
        end
      end
    end
  end

  -- Remove source from result (only reachable FROM source)
  visited[source] = nil
  return visited
end

--- inverse-adjacent(relation, target) → Set of nodes that point into target.
---@param relation table
---@param target   any
---@return table  {node=true, ...}
function M.inverse_adjacent(relation, target)
  if not relation then return {} end
  local data   = relation.data or {}
  local result = {}
  for source, neighbours in pairs(data) do
    if neighbours[target] then
      result[source] = true
    end
  end
  return result
end

return M

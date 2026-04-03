-- runtime/query.lua
-- Find form and relation queries.
--
-- Implements:
--   find family where ... order-by ... limit ... count
--   adjacent?, reachable?, shortest-path, reachable-set, inverse-adjacent?

local M = {}

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
  local where_conditions = {}
  local order_path       = nil
  local order_dir        = "asc"
  local limit            = nil
  local count_only       = false

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
    end
  end

  -- Filter: evaluate where conditions with var bound to each key
  local var_name = family  -- e.g. "npc" in "find npc" (family name is the var binding)

  local results = {}
  for _, key in ipairs(keys) do
    local child = eval_mod.child_ctx_vars(ctx, { [var_name] = key })
    local passes = true

    if #where_conditions > 0 then
      -- All where conditions are ANDed; or_where is also AND for now
      for _, cond_clause in ipairs(where_conditions) do
        local ok, v = pcall(eval_mod.eval_expr, cond_clause.condition, child)
        if not ok or not v then
          passes = false
          break
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

  local visited = {}
  local queue   = { source }
  local head    = 1
  local depth   = 0

  visited[source] = true

  while head <= #queue and depth <= max_hops do
    local current = queue[head]; head = head + 1
    local neighbours = data[current] or {}
    for neighbour in pairs(neighbours) do
      if neighbour == target then return true end
      if not visited[neighbour] then
        visited[neighbour] = true
        queue[#queue + 1] = neighbour
      end
    end
    depth = depth + 1
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

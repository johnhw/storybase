-- runtime/actor_search.lua
-- §H1 goal-directed actor planning.
--
-- For an actor declared with `goal:` + `actions:` (no `behavior:`), runs a
-- bounded BFS over `(cache_snapshot, action) → cache'` transitions to find the
-- shortest sequence of actions that makes the goal expression true.  Returns
-- the first action of that plan so the registry can commit it through the
-- normal capture-proxy path.
--
-- Public API:
--   M.find_plan(real_state, game, actor)  → action_call | nil
--     action_call = { name = "move-to", arg_nodes = [...AST nodes...] }
--
-- Plans are cached by cache-hash so a multi-tick chase doesn't re-search from
-- scratch when state hasn't changed.

local M = {}

local DEFAULT_DEPTH       = 3
local DEFAULT_BUDGET_MS   = 50
local MAX_ARGS_PER_ACTION = 64    -- cap Cartesian product per action
local MAX_FRONTIER        = 2000  -- safety bound on BFS queue size

-- ============================================================
-- Cache cloning + hashing
-- ============================================================

local function clone_cache(src)
  local dst = {}
  for k, v in pairs(src) do
    if type(v) == "table" then
      local c = {}
      for tk, tv in pairs(v) do c[tk] = tv end
      dst[k] = c
    else
      dst[k] = v
    end
  end
  return dst
end

local function fmt_val(v)
  if type(v) == "number" then return string.format("%.17g", v) end
  if type(v) == "boolean" then return v and "T" or "F" end
  return tostring(v)
end

local function hash_cache(cache)
  local keys = {}
  for k in pairs(cache) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = cache[k]
    if type(v) == "table" then
      if #v > 0 then
        local items = {}
        for _, item in ipairs(v) do items[#items + 1] = fmt_val(item) end
        parts[#parts + 1] = k .. "=[" .. table.concat(items, ",") .. "]"
      else
        local subkeys = {}
        for sk in pairs(v) do subkeys[#subkeys + 1] = sk end
        table.sort(subkeys)
        local items = {}
        for _, sk in ipairs(subkeys) do
          items[#items + 1] = fmt_val(sk) .. ":" .. fmt_val(v[sk])
        end
        parts[#parts + 1] = k .. "={" .. table.concat(items, ",") .. "}"
      end
    else
      parts[#parts + 1] = k .. "=" .. fmt_val(v)
    end
  end
  return table.concat(parts, ";")
end

-- ============================================================
-- Schema introspection for argument enumeration
-- ============================================================

--- Build a name → type_record map from schema.types (the codegen-emitted list).
local function build_type_lookup(schema)
  local idx = {}
  for _, t in ipairs((schema or {}).types or {}) do
    if t.name then idx[t.name] = t end
  end
  return idx
end

--- Enumerate live family keys by scanning the cache for `family/<key>/...` paths.
local function family_live_keys(cache, family)
  local prefix = family .. "/"
  local seen, keys = {}, {}
  for path in pairs(cache) do
    if path:sub(1, #prefix) == prefix then
      local key = path:sub(#prefix + 1):match("^([^/]+)")
      if key and not seen[key] then
        seen[key] = true
        keys[#keys + 1] = key
      end
    end
  end
  table.sort(keys)  -- deterministic enumeration order
  return keys
end

--- Resolve a (possibly chained) TYPE_NAMED through alias entries.
--- Returns either a list of enum values, a {tag="int", min, max} desc,
--- {tag="bool"}, or nil for things we can't enumerate.
local function resolve_named(name, type_lookup, seen)
  seen = seen or {}
  if seen[name] then return nil end  -- alias cycle
  seen[name] = true
  local t = type_lookup[name]
  if not t then return nil end
  if t.kind == "enum" then return { _enum = true, values = t.values or {} } end
  if t.kind == "alias" and t.type_desc then
    local desc = t.type_desc
    if desc.tag == "named" then return resolve_named(desc.name, type_lookup, seen) end
    if desc.tag == "int" then return desc end
    if desc.tag == "bool" then return desc end
  end
  return nil
end

--- Enumerate values for a single param given its type_expr AST node.
--- Returns a Lua array, or nil if not enumerable (caller skips action).
local function enumerate_param(type_expr, cache, type_lookup)
  if not type_expr then return nil end
  local k = type_expr.kind
  if k == "type_bool" then
    return { false, true }
  elseif k == "type_int" then
    local lo, hi = type_expr.min, type_expr.max
    if type(lo) ~= "number" or type(hi) ~= "number" then return nil end
    if hi - lo + 1 > 16 then return nil end
    local vals = {}
    for v = lo, hi do vals[#vals + 1] = v end
    return vals
  elseif k == "type_enum_inline" then
    return type_expr.values or {}
  elseif k == "type_symbol_of" then
    if not type_expr.family then return nil end
    return family_live_keys(cache, type_expr.family)
  elseif k == "type_named" then
    local resolved = resolve_named(type_expr.name, type_lookup, {})
    if not resolved then return nil end
    if resolved._enum then return resolved.values end
    if resolved.tag == "int" then
      local lo, hi = resolved.min or 0, resolved.max or 0
      if hi - lo + 1 > 16 then return nil end
      local vals = {}
      for v = lo, hi do vals[#vals + 1] = v end
      return vals
    end
    if resolved.tag == "bool" then return { false, true } end
    return nil
  end
  return nil
end

local function cartesian(arg_lists)
  if #arg_lists == 0 then return { {} } end
  local total = 1
  for _, lst in ipairs(arg_lists) do
    if #lst == 0 then return {} end
    total = total * #lst
    if total > MAX_ARGS_PER_ACTION then return nil end
  end
  local result = { {} }
  for _, lst in ipairs(arg_lists) do
    local next_result = {}
    for _, partial in ipairs(result) do
      for _, v in ipairs(lst) do
        local new = {}
        for i, x in ipairs(partial) do new[i] = x end
        new[#new + 1] = v
        next_result[#next_result + 1] = new
      end
    end
    result = next_result
  end
  return result
end

--- Wrap a value as an AST literal node so it can flow through `eval.call_fn`.
--- Strings are emitted as symbol literals — the dominant case (enum variants,
--- family keys, room labels) since H1 actions almost always quantify over
--- discrete symbol-shaped domains.
local function literal_node(v)
  if v == nil then return { kind = "nil_lit", pos = {file="<h1>",line=0,col=0} } end
  if type(v) == "boolean" then
    return { kind = "bool_lit", value = v, pos = {file="<h1>",line=0,col=0} }
  end
  if type(v) == "number" then
    if v == math.floor(v) then
      return { kind = "int_lit", value = v, pos = {file="<h1>",line=0,col=0} }
    end
    return { kind = "float_lit", value = v, pos = {file="<h1>",line=0,col=0} }
  end
  if type(v) == "string" then
    -- symbol_lit reads `.name`, not `.value` (see runtime/eval.lua:280).
    return { kind = "symbol_lit", name = v, pos = {file="<h1>",line=0,col=0} }
  end
  return { kind = "nil_lit", pos = {file="<h1>",line=0,col=0} }
end

-- ============================================================
-- Sandbox state — fresh runtime/state.lua store with nop log
-- ============================================================

local _state_mod, _log_mod, _eval_mod

local function get_modules()
  _state_mod = _state_mod or require("runtime.state")
  _log_mod   = _log_mod   or require("runtime.log")
  _eval_mod  = _eval_mod  or require("runtime.eval")
end

--- Build a sandbox state store seeded from a cache snapshot.
--- Reuses runtime/state.lua so clamping, family spawn/despawn, and the type
--- index all behave the same way the engine does.
local function make_sandbox(schema, cache)
  get_modules()
  local log = _log_mod.new()
  local store = _state_mod.new(schema or {}, log)
  -- Seed the sandbox with the snapshot.
  for k, v in pairs(cache) do
    if type(v) == "table" then
      local c = {}
      for tk, tv in pairs(v) do c[tk] = tv end
      store._cache[k] = c
    else
      store._cache[k] = v
    end
  end
  -- Suppress dev warnings — sandbox calls aren't user-visible.
  store._production = true
  return store
end

--- Apply an action to a sandbox seeded with `cache`, returning the resulting
--- cache or nil if the precondition failed (or the action errored).
local function apply_action(schema, fns, game, cache, action_name, args_tuple)
  get_modules()
  local sandbox = make_sandbox(schema, cache)
  local ctx = _eval_mod.new_ctx(sandbox, fns, action_name, game)
  -- Build literal AST nodes for the argument values
  local arg_nodes = {}
  for i, v in ipairs(args_tuple) do
    arg_nodes[i] = literal_node(v)
  end
  local ok = pcall(_eval_mod.call_fn, action_name, arg_nodes, ctx)
  if not ok then return nil end
  return sandbox._cache
end

--- Evaluate the goal expression against a cache snapshot.
local function eval_goal(schema, fns, game, cache, goal_expr)
  get_modules()
  local sandbox = make_sandbox(schema, cache)
  local ctx = _eval_mod.new_ctx(sandbox, fns, "_h1_goal", game)
  local ok, result = pcall(_eval_mod.eval_expr, goal_expr, ctx)
  if not ok then return false end
  return result and true or false
end

-- ============================================================
-- Action / args enumeration for one BFS expansion
-- ============================================================

--- Returns a list of {action_name, arg_lists, fn} structs ready for expansion
--- from `cache`. Caches per-fn param-arity but recomputes SymbolOf args each
--- call because live family keys change.
local function expand_actions(actor, fns, schema, type_lookup, cache)
  local actions = actor.actions or {}
  local expansions = {}
  for _, action_name in ipairs(actions) do
    local fn = fns and fns[action_name]
    if fn then
      local params = fn.params or {}
      local per_param_values = {}
      local ok = true
      for _, p in ipairs(params) do
        local te = type(p) == "table" and p.type_expr or nil
        if te then
          local vals = enumerate_param(te, cache, type_lookup)
          if not vals or #vals == 0 then ok = false; break end
          per_param_values[#per_param_values + 1] = vals
        else
          -- Untyped param — refuse to enumerate (would explode)
          ok = false; break
        end
      end
      if ok then
        local combos = cartesian(per_param_values)
        if combos then
          for _, args_tuple in ipairs(combos) do
            expansions[#expansions + 1] = {
              name      = action_name,
              args      = args_tuple,
              fn        = fn,
            }
          end
        end
      end
    end
  end
  return expansions
end

-- ============================================================
-- Plan cache (per-actor, persists across ticks)
-- ============================================================

--- Per-actor plan cache table: keyed by cache hash, holds a list of
--- {action_name, args_tuple} from that state onward.
local function plan_cache_get(actor, hash)
  if not actor._h1_plan_cache then actor._h1_plan_cache = {} end
  return actor._h1_plan_cache[hash]
end

local function plan_cache_put(actor, hash, plan)
  if not actor._h1_plan_cache then actor._h1_plan_cache = {} end
  actor._h1_plan_cache[hash] = plan  -- nil = delete entry
end

--- Drop the cache (e.g. when actor.goal/actions changes via hot reload).
function M.clear_plan_cache(actor)
  actor._h1_plan_cache = nil
end

-- ============================================================
-- BFS driver
-- ============================================================

local function now_ms()
  return (os.clock() * 1000)
end

--- Run a depth-bounded BFS from `start_cache` toward `actor.goal`.
--- Returns a plan list (array of {name, args}) on success, or nil.
local function bfs_plan(actor, schema, fns, game, type_lookup, start_cache,
                       depth_bound, budget_ms)
  if eval_goal(schema, fns, game, start_cache, actor.goal) then
    return {}  -- already satisfied — no action needed
  end

  local visited = { [hash_cache(start_cache)] = true }
  -- Each frontier entry: { cache = ..., path = { {name, args}, ... } }
  local frontier = { { cache = start_cache, path = {} } }
  local deadline = now_ms() + (budget_ms or DEFAULT_BUDGET_MS)
  local iters    = 0

  while #frontier > 0 do
    iters = iters + 1
    if iters % 16 == 0 and now_ms() > deadline then return nil end
    if #frontier > MAX_FRONTIER then return nil end

    local node = table.remove(frontier, 1)
    if #node.path >= (depth_bound or DEFAULT_DEPTH) then
      -- depth-bounded: don't expand further
    else
      local expansions = expand_actions(actor, fns, schema, type_lookup, node.cache)
      for _, exp in ipairs(expansions) do
        local next_cache = apply_action(schema, fns, game, node.cache, exp.name, exp.args)
        if next_cache then
          local h = hash_cache(next_cache)
          if not visited[h] then
            visited[h] = true
            local new_path = {}
            for i, step in ipairs(node.path) do new_path[i] = step end
            new_path[#new_path + 1] = { name = exp.name, args = exp.args }
            if eval_goal(schema, fns, game, next_cache, actor.goal) then
              return new_path
            end
            frontier[#frontier + 1] = { cache = next_cache, path = new_path }
          end
        end
      end
    end
  end
  return nil
end

-- ============================================================
-- Public entrypoint
-- ============================================================

--- Find the next action for a goal-directed actor.
--- Returns a table `{name=action_name, arg_nodes={literal AST nodes}}` ready
--- for `call_fn`, or nil if no progress is possible within the bound.
---
--- Plan caching: after a fresh BFS finds plan `[A, B, C]`, we commit A and
--- stash `[B, C]` under the hash of the **post-A** cache snapshot.  On the
--- next tick, if the real state's hash matches that snapshot (i.e. no other
--- actor or player intervened to disturb the plan), we pop B and continue
--- without re-searching.  When the actual state has drifted from the stashed
--- post-step state — common in adversarial / contested simulations — the
--- lookup misses and a fresh BFS runs.  This keeps long single-actor walks
--- cheap and stays correct under interference.
function M.find_plan(real_state, game, actor)
  if not actor.goal or not actor.actions or #actor.actions == 0 then
    return nil
  end
  local schema  = game and game.schema or {}
  local fns     = game and game.fns    or {}
  local type_lookup = build_type_lookup(schema)
  local start_cache = clone_cache(real_state._cache or {})
  local hash        = hash_cache(start_cache)

  -- Already at goal — nothing to commit.
  if eval_goal(schema, fns, game, start_cache, actor.goal) then
    return nil
  end

  -- Plan cache hit: a prior tick stashed the remaining plan under THIS hash.
  -- Validate by replaying the cached first step on the current cache; if the
  -- precondition still holds we trust the rest of the plan.
  local cached = plan_cache_get(actor, hash)
  if cached and #cached > 0 then
    local step = cached[1]
    local next_cache = apply_action(schema, fns, game, start_cache, step.name, step.args)
    if next_cache then
      local next_hash = hash_cache(next_cache)
      local rest = {}
      for i = 2, #cached do rest[#rest + 1] = cached[i] end
      plan_cache_put(actor, hash, nil)  -- consume the entry under the start hash
      if #rest > 0 then plan_cache_put(actor, next_hash, rest) end
      local arg_nodes = {}
      for i, v in ipairs(step.args) do arg_nodes[i] = literal_node(v) end
      return { name = step.name, arg_nodes = arg_nodes }
    end
    -- Cached step no longer applicable — fall through and re-plan.
    plan_cache_put(actor, hash, nil)
  end

  -- Fresh search.
  local plan = bfs_plan(actor, schema, fns, game, type_lookup, start_cache,
                        actor.search_depth or DEFAULT_DEPTH,
                        actor.search_budget_ms or DEFAULT_BUDGET_MS)
  if not plan or #plan == 0 then return nil end

  -- Stash the rest of the plan keyed on the post-step state so the NEXT tick
  -- hits the cache if nothing has disturbed our intermediate state.
  local step = plan[1]
  local after_step = apply_action(schema, fns, game, start_cache, step.name, step.args)
  if after_step and #plan > 1 then
    local rest = {}
    for i = 2, #plan do rest[#rest + 1] = plan[i] end
    plan_cache_put(actor, hash_cache(after_step), rest)
  end

  local arg_nodes = {}
  for i, v in ipairs(step.args) do arg_nodes[i] = literal_node(v) end
  return { name = step.name, arg_nodes = arg_nodes }
end

-- ============================================================
-- Test hooks (exposed for tests/runtime/actors_goal_spec.lua)
-- ============================================================

M._hash_cache         = hash_cache
M._clone_cache        = clone_cache
M._enumerate_param    = enumerate_param
M._family_live_keys   = family_live_keys
M._cartesian          = cartesian
M._build_type_lookup  = build_type_lookup
M._apply_action       = apply_action
M._eval_goal          = eval_goal

return M

-- runtime/verify.lua
-- Verify block runner: evaluates verify declarations from the compiled game table.
--
-- Supported clause kinds:
--   "always"         — verify-always expr: check expr at every BFS-reachable state
--   "requires"       — requires expr: filter states (see "after" semantics below)
--   "after"          — after (fn args): assertions: apply fn, check assertions with path@before
--                      Without requires: runs from fresh initial state only.
--                      With requires:    runs from every BFS-reachable state where requires holds.
--   "from_any_state" — BFS-reachable state filter with when/can-reach checks
--   "when"           — sub-clause of from_any_state
--
-- BFS (used by verify-always, after+requires, from-any-state):
--   Explores (cache_snapshot, scene_stack) pairs from the entry scene up to
--   DEFAULT_BFS_DEPTH steps. Uses a content hash for cycle detection.
--   Fan-out = number of visible choices at each scene.

local eval = require("runtime.eval")
local M    = {}

local DEFAULT_BFS_DEPTH         = 5
local DEFAULT_SHRINK_BUDGET_SECS = 5.0

-- ============================================================
-- Path pattern matching (§4.3)
-- ============================================================

--- Return true when `path` matches `pattern`.
---
--- Supported wildcards:
---   *     — any single segment (no slashes)
---   **    — any sequence of segments (including slashes)
---   (a|b) — alternation (recursively expanded)
---
---@param pattern string
---@param path    string
---@return boolean
local function match_path_pattern(pattern, path)
  if pattern == "*"  then return true end
  if pattern == path then return true end
  -- Expand (a|b|c) alternation groups
  local alt_s, alt_e = pattern:find("%((.-)%)")
  if alt_s then
    local before    = pattern:sub(1, alt_s - 1)
    local alt_inner = pattern:sub(alt_s + 1, alt_e - 1)
    local after     = pattern:sub(alt_e + 1)
    for branch in alt_inner:gmatch("[^|]+") do
      if match_path_pattern(before .. branch .. after, path) then return true end
    end
    return false
  end
  -- Convert wildcards to Lua pattern
  local lp = pattern:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")
  lp = lp:gsub("%*%*", "\0")
  lp = lp:gsub("%*", "[^/]+")
  lp = lp:gsub("\0", ".*")
  return path:match("^" .. lp .. "$") ~= nil
end

M.match_path_pattern = match_path_pattern

-- ============================================================
-- State helpers
-- ============================================================

--- Deep-copy a single cache value (table = Set/UList or UMap).
local function copy_cache_val(v)
  if #v > 0 then
    local copy = {}
    for i, item in ipairs(v) do copy[i] = item end
    return copy
  else
    local copy = {}
    for tk, tv in pairs(v) do copy[tk] = tv end
    return copy
  end
end

--- Serialise a single cache key/value pair to a stable string (for hashing/display).
local function ser_cache_val(k, v)
  if #v > 0 then
    local items = {}
    for _, item in ipairs(v) do items[#items+1] = tostring(item) end
    return k .. "=[" .. table.concat(items, ",") .. "]"
  else
    local subkeys = {}
    for sk in pairs(v) do subkeys[#subkeys+1] = sk end
    table.sort(subkeys)
    local items = {}
    for _, sk in ipairs(subkeys) do items[#items+1] = tostring(sk) .. ":" .. tostring(v[sk]) end
    return k .. "={" .. table.concat(items, ",") .. "}"
  end
end

--- Shallow-clone the flat state cache (all values are scalars/tables by ref).
--- For path@before snapshots this is sufficient since we only read the snapshot.
local function clone_cache(store)
  local snap = {}
  for k, v in pairs(store._cache) do
    if type(v) == "table" then
      snap[k] = copy_cache_val(v)
    else
      snap[k] = v
    end
  end
  return snap
end

--- Build a fresh state store initialised to game defaults.
local function make_fresh_store(game_table)
  local log_mod   = require("runtime.log")
  local state_mod = require("runtime.state")
  local l = log_mod.new()
  local s = state_mod.new(game_table.schema, l)
  s:init_defaults()
  return s
end

--- Produce a stable string key for a cache snapshot (for cycle detection).
local function hash_cache(cache, stack)
  local keys = {}
  for k in pairs(cache) do keys[#keys+1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = cache[k]
    if type(v) == "table" then
      parts[#parts+1] = ser_cache_val(k, v)
    else
      parts[#parts+1] = k .. "=" .. tostring(v)
    end
  end
  -- Include scene stack in hash so same cache + different scene = different node
  parts[#parts+1] = "||" .. table.concat(stack or {}, "/")
  return table.concat(parts, ";")
end

-- ============================================================
-- BFS over (cache, scene_stack) nodes
-- ============================================================

--- BFS from the entry scene up to max_depth choices deep.
--- Returns a list of {cache, path} where cache is a state snapshot and
--- path is a list of {scene, label} steps from the initial state.
local function bfs_states(game_table, max_depth)
  local engine_mod = require("runtime.engine")
  local snapshots  = {}
  local seen       = {}

  local entry = game_table.schema
    and game_table.schema.engine_config
    and game_table.schema.engine_config["entry-scene"]
  if not entry then return snapshots end

  -- Build initial node
  local init_eng = engine_mod.new(game_table, { io_out = { write = function() end } })
  init_eng:init()
  local init_cache = clone_cache(init_eng._state)
  local init_stack = { entry }

  local queue = { { stack = init_stack, cache = init_cache, depth = 0, path = {} } }
  local head  = 1

  while head <= #queue do
    local item = queue[head]; head = head + 1
    local h    = hash_cache(item.cache, item.stack)

    if not seen[h] then
      seen[h] = true
      snapshots[#snapshots+1] = { cache = item.cache, path = item.path }

      if item.depth < max_depth then
        local scene_name = item.stack[#item.stack]
        if not scene_name then goto continue end

        -- Build a temporary engine from this snapshot to enumerate choices
        local eng = engine_mod.new(game_table, { io_out = { write = function() end } })
        eng:register_actors_schedules()
        eng._in_bfs = true  -- prevent recursive BFS when rendering narration
        -- Restore state directly (internal access, consistent with test approach)
        for k in pairs(eng._state._cache) do eng._state._cache[k] = nil end
        for k, v in pairs(item.cache) do
          eng._state._cache[k] = type(v) == "table" and copy_cache_val(v) or v
        end
        eng._scene_stack = {}
        for _, s in ipairs(item.stack) do
          eng._scene_stack[#eng._scene_stack+1] = s
        end

        local _, choices = eng:render_scene(scene_name)
        for _, ch in ipairs(choices) do
          -- Apply choice on a fresh copy of the engine state
          local eng2 = engine_mod.new(game_table, { io_out = { write = function() end } })
          eng2:register_actors_schedules()
          eng2._in_bfs = true  -- prevent recursive BFS when rendering narration
          for k in pairs(eng2._state._cache) do eng2._state._cache[k] = nil end
          for k, v in pairs(item.cache) do
            eng2._state._cache[k] = type(v) == "table" and copy_cache_val(v) or v
          end
          eng2._scene_stack = {}
          for _, s in ipairs(item.stack) do eng2._scene_stack[#eng2._scene_stack+1] = s end

          local ok, sig = pcall(function()
            return eng2:do_choice(scene_name, ch.index)
          end)
          if ok then
            -- Also run post-action phases (actors, scheduler)
            pcall(function() eng2:post_action() end)

            local new_cache = clone_cache(eng2._state)
            local new_stack = {}
            for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack+1] = s end

            -- Apply navigation signal
            if sig then
              if sig.type == "goto" and sig.target then
                if #new_stack > 0 then new_stack[#new_stack] = sig.target
                else new_stack[1] = sig.target end
              elseif sig.type == "enter" and sig.target then
                new_stack[#new_stack+1] = sig.target
              elseif sig.type == "exit" then
                new_stack[#new_stack] = nil
              end
            end

            if #new_stack > 0 then
              local new_path = {}
              for _, step in ipairs(item.path) do new_path[#new_path+1] = step end
              new_path[#new_path+1] = { scene = scene_name, label = ch.label, index = ch.index }
              queue[#queue+1] = {
                stack = new_stack,
                cache = new_cache,
                depth = item.depth + 1,
                path  = new_path,
              }
            end
          end
        end
      end
    end

    ::continue::
  end

  return snapshots
end

-- ============================================================
-- Shared helpers
-- ============================================================

--- Serialise a cache snapshot to a human-readable "{k=v, ...}" string.
local function snap_str(cache)
  local keys = {}
  for k in pairs(cache) do keys[#keys+1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = cache[k]
    parts[#parts+1] = type(v) == "table" and ser_cache_val(k, v) or k .. "=" .. tostring(v)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

--- Build a fresh state store from a cache snapshot.
local function store_from_snap(snap, game_table)
  local log_mod   = require("runtime.log")
  local state_mod = require("runtime.state")
  local s = state_mod.new(game_table.schema, log_mod.new())
  for k, v in pairs(snap) do
    s._cache[k] = type(v) == "table" and copy_cache_val(v) or v
  end
  return s
end

-- ============================================================
-- Counterexample minimisation (B2)
-- ============================================================

--- Replay a list of choice steps from the initial game state.
--- Each step is {scene, label, index?}.  Matching is by label first; the stored
--- index is used as a fallback when labels are dynamic.
--- Returns (cache_snapshot, scene_stack) on success, or nil, nil on any failure
--- (wrong scene, choice not found, error during execution).
local function replay_path(game_table, steps)
  local engine_mod = require("runtime.engine")

  local eng = engine_mod.new(game_table, { io_out = { write = function() end } })
  eng:init()
  eng._in_bfs = true

  -- Mirror the BFS approach: track scene stack manually because do_choice does
  -- not update eng._scene_stack.
  local stack = {}
  for _, s in ipairs(eng._scene_stack) do stack[#stack+1] = s end

  for _, step in ipairs(steps) do
    local current_scene = stack[#stack]
    if not current_scene then return nil, nil end

    -- If the step recorded a scene, it must match where we are now.
    if step.scene and step.scene ~= current_scene then return nil, nil end

    -- Render available choices at the current scene.
    local ok_r, _, choices = pcall(function()
      return eng:render_scene(current_scene)
    end)
    if not ok_r then return nil, nil end

    -- Match choice by label (primary), fall back to the stored index.
    local chosen_idx = nil
    for _, ch in ipairs(choices or {}) do
      if ch.label == step.label then chosen_idx = ch.index; break end
    end
    if not chosen_idx and step.index then
      for _, ch in ipairs(choices or {}) do
        if ch.index == step.index then chosen_idx = ch.index; break end
      end
    end
    if not chosen_idx then return nil, nil end

    -- Execute the choice body.
    local ok_c, sig = pcall(function() return eng:do_choice(current_scene, chosen_idx) end)
    if not ok_c then return nil, nil end
    -- Run post-action phases; actors/scheduler may update eng._scene_stack.
    pcall(function() eng:post_action() end)

    -- Read scene stack after post_action (mirrors BFS pattern).
    local new_stack = {}
    for _, s in ipairs(eng._scene_stack) do new_stack[#new_stack+1] = s end

    -- Apply the choice's navigation signal on top.
    if sig then
      if sig.type == "goto" and sig.target then
        if #new_stack > 0 then new_stack[#new_stack] = sig.target
        else new_stack[1] = sig.target end
      elseif sig.type == "enter" and sig.target then
        new_stack[#new_stack+1] = sig.target
      elseif sig.type == "exit" then
        new_stack[#new_stack] = nil
      end
    end

    stack = new_stack
    eng._scene_stack = {}
    for _, s in ipairs(stack) do eng._scene_stack[#eng._scene_stack+1] = s end
  end

  return clone_cache(eng._state), stack
end

--- Return true when replaying `steps` ends in a state where `condition_expr`
--- is false (i.e. the invariant is still violated).
local function path_still_fails(game_table, steps, condition_expr)
  local cache, stack = replay_path(game_table, steps)
  if not cache then return false end

  local log_mod   = require("runtime.log")
  local state_mod = require("runtime.state")
  local fake_state = state_mod.new(game_table.schema, log_mod.new())
  for k, v in pairs(cache) do fake_state._cache[k] = v end

  local ctx = eval.new_ctx(fake_state, game_table.fns, "verify-shrink", game_table)
  ctx.scene_stack = stack

  local ok, result = pcall(eval.eval_expr, condition_expr, ctx)
  if not ok then return false end
  return not result  -- violated when the invariant expression is false
end

--- Greedily shrink a counterexample path by attempting to remove one step at
--- a time.  Restarts the greedy pass each time a step is successfully removed,
--- so the result is 1-minimal: no single step can be dropped further.
---
--- Returns (minimised_path, budget_exceeded_bool).
--- If budget_secs is nil there is no time limit.
---
---@param game_table    table   compiled game table
---@param path          table   list of {scene, label, index?} steps
---@param condition_expr table  AST node for the violated invariant
---@param budget_secs   number? wall-clock budget in seconds; nil = unlimited
---@return table, boolean
local function shrink_path(game_table, path, condition_expr, budget_secs)
  if #path <= 1 then return path, false end

  local current = {}
  for _, s in ipairs(path) do current[#current+1] = s end

  local deadline        = budget_secs and (os.clock() + budget_secs)
  local budget_exceeded = false

  local changed = true
  while changed and #current > 1 do
    changed = false
    for i = 1, #current do
      if deadline and os.clock() > deadline then
        budget_exceeded = true
        return current, budget_exceeded
      end

      -- Try removing step i.
      local candidate = {}
      for j, s in ipairs(current) do
        if j ~= i then candidate[#candidate+1] = s end
      end

      if path_still_fails(game_table, candidate, condition_expr) then
        current = candidate
        changed = true
        break  -- restart the greedy pass on the shorter path
      end
    end
  end

  return current, budget_exceeded
end

--- Public entry point so tests and external tooling can call the shrinker
--- directly without going through run_all.
M.shrink_path = shrink_path

-- ============================================================
-- verify-always evaluation
-- ============================================================

local function run_always_check(verify_entry, game_table)
  local always_expr = nil
  for _, c in ipairs(verify_entry.clauses) do
    if c.kind == "always" then always_expr = c.condition end
  end
  if not always_expr then return { pass = true } end

  local log_mod   = require("runtime.log")
  local state_mod = require("runtime.state")

  local snapshots = bfs_states(game_table, DEFAULT_BFS_DEPTH)
  if #snapshots == 0 then
    return { pass = true, states_checked = 0 }
  end

  for i, snap_item in ipairs(snapshots) do
    local cache_snap = snap_item.cache
    local fake_log   = log_mod.new()
    local fake_state = state_mod.new(game_table.schema, fake_log)
    for k, v in pairs(cache_snap) do fake_state._cache[k] = v end

    local ctx = eval.new_ctx(fake_state, game_table.fns, "verify-always", game_table)
    local ok, result = pcall(eval.eval_expr, always_expr, ctx)
    if not ok then
      return { pass = false,
               fail_msg = "error evaluating verify-always: " .. tostring(result) }
    end
    if not result then
      -- Post-process: minimise the counterexample path with greedy delta-debugging.
      local min_path            = snap_item.path
      local original_len        = nil
      local shrink_budget_flag  = nil

      if #snap_item.path > 1 then
        local shrunk, budget_exceeded = shrink_path(
          game_table, snap_item.path, always_expr, DEFAULT_SHRINK_BUDGET_SECS)
        if #shrunk < #snap_item.path then
          original_len = #snap_item.path
          min_path     = shrunk
        end
        if budget_exceeded then shrink_budget_flag = true end
      end

      return {
        pass                                  = false,
        fail_msg                              = string.format(
          "verify-always violated at BFS state %d: %s", i, snap_str(cache_snap)),
        counterexample                        = cache_snap,
        counterexample_n                      = i,
        counterexample_path                   = min_path,
        counterexample_path_original_len      = original_len,
        counterexample_shrink_budget_exceeded = shrink_budget_flag,
      }
    end
  end

  return { pass = true, states_checked = #snapshots }
end

-- ============================================================
-- after-check evaluation
-- ============================================================

--- Run one (store, before_snap) pair through the after-call and assertions.
--- Returns a result table; pass=true means all assertions held.
local function check_one_after(store, after_call, assertions, game_table, snap_label)
  local ctx = eval.new_ctx(store, game_table.fns, "verify-after", game_table)
  local before_snap = clone_cache(store)
  ctx.before_snapshot = before_snap

  local call_ok, call_err = pcall(eval.eval_expr, after_call, ctx)
  if not call_ok then
    return { pass = false,
             fail_msg = "function raised error: " .. tostring(call_err) }
  end

  for i, assert_expr in ipairs(assertions) do
    local ok, result = pcall(eval.eval_expr, assert_expr, ctx)
    if not ok then
      return { pass = false,
               fail_msg = string.format(
                 "assertion %d raised error at %s: %s", i, snap_label, tostring(result)) }
    end
    if not result then
      return { pass = false,
               fail_msg = string.format(
                 "assertion %d failed at %s: %s", i, snap_label, snap_str(before_snap)) }
    end
  end

  return { pass = true }
end

local function run_after_check(verify_entry, game_table)
  local requires_expr = nil
  local after_call    = nil
  local assertions    = {}

  for _, c in ipairs(verify_entry.clauses) do
    if c.kind == "requires" then requires_expr = c.condition
    elseif c.kind == "after" then after_call = c.condition; assertions = c.body
    end
  end

  if not after_call then return { pass = true } end

  -- Without requires: single fresh initial state (original behaviour).
  if not requires_expr then
    return check_one_after(make_fresh_store(game_table), after_call, assertions,
                           game_table, "initial state")
  end

  -- With requires: run from every BFS-reachable state where requires holds.
  local snapshots = bfs_states(game_table, DEFAULT_BFS_DEPTH)
  local checked   = 0

  for i, snap_item in ipairs(snapshots) do
    local store = store_from_snap(snap_item.cache, game_table)
    local rctx  = eval.new_ctx(store, game_table.fns, "verify-requires", game_table)
    local ok, result = pcall(eval.eval_expr, requires_expr, rctx)

    -- Distinguish "requires errored" from "requires is false in this state".
    -- An evaluation error (typo in the requires expression, reference to a
    -- removed path) used to be silently treated as `not met` — the assertion
    -- was never run and the block was reported as skipped. Now we fail loudly.
    if not ok then
      return {
        pass     = false,
        fail_msg = string.format(
          "requires clause errored at BFS state %d: %s", i, tostring(result)),
        counterexample      = snap_item.cache,
        counterexample_n    = i,
        counterexample_path = snap_item.path,
      }
    end
    if not result then goto continue end

    checked = checked + 1
    local label = string.format("BFS state %d", i)
    local r = check_one_after(store_from_snap(snap_item.cache, game_table),
                              after_call, assertions, game_table, label)
    if not r.pass then
      r.counterexample      = snap_item.cache
      r.counterexample_n    = i
      r.counterexample_path = snap_item.path
      return r
    end

    ::continue::
  end

  if checked == 0 then
    return { pass = true, skipped = true,
             reason = "requires not met in any reachable state" }
  end
  return { pass = true, states_checked = checked }
end

-- ============================================================
-- from-any-state / when check
-- ============================================================

local function run_can_reach_check(verify_entry, game_table)
  local from_any_state_body = nil
  local when_cond           = nil

  for _, c in ipairs(verify_entry.clauses) do
    if c.kind == "from_any_state" then
      -- condition may be set (inline expr) or body may be a list of sub-exprs
      if c.condition then
        from_any_state_body = { c.condition }
      elseif c.body and #c.body > 0 then
        from_any_state_body = c.body
      end
    elseif c.kind == "when" then
      when_cond = c.condition
    end
  end

  if not from_any_state_body then return { pass = true } end

  local log_mod   = require("runtime.log")
  local state_mod = require("runtime.state")

  local entry = game_table.schema
    and game_table.schema.engine_config
    and game_table.schema.engine_config["entry-scene"]

  -- Collect all BFS-reachable snapshots
  local snapshots = bfs_states(game_table, DEFAULT_BFS_DEPTH)

  -- For each snapshot, optionally filter by when: condition
  for i, snap_item in ipairs(snapshots) do
    local snap = snap_item.cache
    -- Apply when: filter
    if when_cond then
      local l  = log_mod.new()
      local fs = state_mod.new(game_table.schema, l)
      for k, v in pairs(snap) do fs._cache[k] = v end
      local wctx = eval.new_ctx(fs, game_table.fns, "verify-when", game_table)
      local ok, result = pcall(eval.eval_expr, when_cond, wctx)
      -- Same fix as for `requires:`: an evaluation error in the `when:` filter
      -- is a real bug, not a "this snapshot doesn't apply" signal. Surface it.
      if not ok then
        return {
          pass     = false,
          fail_msg = string.format(
            "when clause errored at BFS state %d: %s", i, tostring(result)),
          counterexample      = snap,
          counterexample_n    = i,
          counterexample_path = snap_item.path,
        }
      end
      if not result then
        goto continue_snap
      end
    end

    -- Evaluate each from-any-state expression from this snapshot
    for _, check_node in ipairs(from_any_state_body) do
      -- Unwrap expr_stmt if needed
      local check_expr = check_node
      if check_expr and check_expr.kind == "expr_stmt" then
        check_expr = check_expr.expr
      end
      if not check_expr then goto continue_snap end

      local l          = log_mod.new()
      local fake_state = state_mod.new(game_table.schema, l)
      for k, v in pairs(snap) do fake_state._cache[k] = v end

      local ctx = eval.new_ctx(fake_state, game_table.fns, "verify-from-any", game_table)
      ctx.scene_stack = entry and { entry } or {}

      local ok2, result2 = pcall(eval.eval_expr, check_expr, ctx)
      if not ok2 then
        return {
          pass                = false,
          fail_msg            = string.format(
            "from-any-state: condition errored at BFS state %d: %s",
            i, tostring(result2)),
          counterexample      = snap,
          counterexample_n    = i,
          counterexample_path = snap_item.path,
        }
      end
      if not result2 then
        return {
          pass                = false,
          fail_msg            = string.format(
            "from-any-state: condition failed at BFS state %d: %s", i, snap_str(snap)),
          counterexample      = snap,
          counterexample_n    = i,
          counterexample_path = snap_item.path,
        }
      end
    end

    ::continue_snap::
  end

  return { pass = true, states_checked = #snapshots }
end

-- ============================================================
-- Public API
-- ============================================================

-- ============================================================
-- Temporal-logic checks (C3: EF / AF / AU)
-- ============================================================
--
-- These wrap `runtime/search.lua` verifiers. The shape of each result is the
-- same as the existing checks (`pass`, `fail_msg`, `counterexample`,
-- `counterexample_path`, `states_checked`, `truncated`).

local DEFAULT_CTL_DEPTH  = 5
local DEFAULT_CTL_BUDGET = 30  -- seconds

--- Build the initial cache + scene stack for CTL-style checks.
local function ctl_initial(game_table)
  local engine_mod = require("runtime.engine")
  local eng = engine_mod.new(game_table, { io_out = { write = function() end } })
  eng:init()
  local search_mod = require("runtime.search")
  local cache = search_mod.clone_cache(eng._state, eng._scheduler, game_table)
  local entry = game_table.schema
    and game_table.schema.engine_config
    and game_table.schema.engine_config["entry-scene"]
  local stack = entry and { entry } or {}
  return cache, stack
end

--- Build a closure that evaluates an AST condition against a state snapshot.
local function make_condition_fn(game_table, fn_name, condition_expr)
  local log_mod   = require("runtime.log")
  local state_mod = require("runtime.state")
  return function(snap_cache)
    local fake_state = state_mod.new(game_table.schema or {}, log_mod.new())
    for k, v in pairs(snap_cache) do
      if not k:match("^__") then fake_state._cache[k] = v end
    end
    local ctx = eval.new_ctx(fake_state, game_table.fns, fn_name, game_table)
    local ok, result = pcall(eval.eval_expr, condition_expr, ctx)
    return ok and result
  end
end

local function run_eventually_check(verify_entry, game_table)
  local expr = nil
  for _, c in ipairs(verify_entry.clauses) do
    if c.kind == "eventually" then expr = c.condition end
  end
  if not expr then return { pass = true } end

  local search_mod = require("runtime.search")
  local cache, stack = ctl_initial(game_table)
  local cond_fn = make_condition_fn(game_table, "verify-eventually", expr)
  return search_mod.verify_eventually(
    game_table, cache, stack, cond_fn, DEFAULT_CTL_DEPTH, DEFAULT_CTL_BUDGET)
end

local function run_always_eventually_check(verify_entry, game_table)
  local expr = nil
  for _, c in ipairs(verify_entry.clauses) do
    if c.kind == "always_eventually" then expr = c.condition end
  end
  if not expr then return { pass = true } end

  local search_mod = require("runtime.search")
  local cache, stack = ctl_initial(game_table)
  local cond_fn = make_condition_fn(game_table, "verify-always-eventually", expr)
  return search_mod.verify_always_eventually(
    game_table, cache, stack, cond_fn, DEFAULT_CTL_DEPTH, DEFAULT_CTL_BUDGET)
end

local function run_until_check(verify_entry, game_table)
  local p_expr, q_expr = nil, nil
  for _, c in ipairs(verify_entry.clauses) do
    if c.kind == "until" then
      p_expr = c.condition
      q_expr = c.body and c.body[1] or nil
    end
  end
  if not p_expr or not q_expr then return { pass = true } end

  local search_mod = require("runtime.search")
  local cache, stack = ctl_initial(game_table)
  local p_fn = make_condition_fn(game_table, "verify-until-p", p_expr)
  local q_fn = make_condition_fn(game_table, "verify-until-q", q_expr)
  return search_mod.verify_until(
    game_table, cache, stack, p_fn, q_fn, DEFAULT_CTL_DEPTH, DEFAULT_CTL_BUDGET)
end

-- ============================================================
-- Public API
-- ============================================================

--- Run all verify blocks in a compiled game table.
---@param game_table table  Compiled game table from codegen
---@return table  list of {label, pass, fail_msg?, skipped?, reason?, states_checked?}
function M.run_all(game_table)
  local results = {}

  for _, verify_entry in ipairs(game_table.verifies or {}) do
    local has_always             = false
    local has_after              = false
    local has_from_any_state     = false
    local has_eventually         = false
    local has_always_eventually  = false
    local has_until              = false
    for _, c in ipairs(verify_entry.clauses) do
      if c.kind == "always"             then has_always            = true end
      if c.kind == "after"              then has_after             = true end
      if c.kind == "from_any_state"     then has_from_any_state    = true end
      if c.kind == "eventually"         then has_eventually        = true end
      if c.kind == "always_eventually"  then has_always_eventually = true end
      if c.kind == "until"              then has_until             = true end
    end

    local result = { label = verify_entry.label, pass = true }

    local function absorb(r)
      if not r.pass then
        result.pass                 = false
        result.fail_msg             = r.fail_msg
        result.counterexample       = r.counterexample
        result.counterexample_n     = r.counterexample_n
        result.counterexample_path  = r.counterexample_path
        result.truncated            = r.truncated
      else
        if r.states_checked then result.states_checked = r.states_checked end
        if r.truncated      then result.truncated      = r.truncated      end
        if r.counterexample_path and not result.counterexample_path then
          result.counterexample_path = r.counterexample_path
        end
      end
    end

    if has_always then absorb(run_always_check(verify_entry, game_table)) end

    if has_after and result.pass then
      local r = run_after_check(verify_entry, game_table)
      if not r.pass then
        result.pass                = false
        result.fail_msg            = r.fail_msg
        result.counterexample      = r.counterexample
        result.counterexample_n    = r.counterexample_n
        result.counterexample_path = r.counterexample_path
      elseif r.skipped then
        result.skipped = true
        result.reason  = r.reason
      else
        result.states_checked = r.states_checked
      end
    end

    if has_from_any_state        and result.pass then absorb(run_can_reach_check(verify_entry, game_table)) end
    if has_eventually            and result.pass then absorb(run_eventually_check(verify_entry, game_table)) end
    if has_always_eventually     and result.pass then absorb(run_always_eventually_check(verify_entry, game_table)) end
    if has_until                 and result.pass then absorb(run_until_check(verify_entry, game_table)) end

    results[#results+1] = result
  end

  return results
end

return M

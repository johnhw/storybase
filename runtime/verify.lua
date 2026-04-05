-- runtime/verify.lua
-- Verify block runner: evaluates verify declarations from the compiled game table.
--
-- Supported clause kinds:
--   "always"      — verify-always expr: check expr at every BFS-reachable state
--   "requires"    — requires expr: skip verify if expr is false in initial state
--   "after"       — after (fn args): assertions: apply fn, check assertions with path@before
--   "from_any_state" — not yet evaluated (deferred; treated as always-pass)
--   "when"        — not yet evaluated (deferred; treated as always-pass)
--
-- BFS for verify-always:
--   Explores (cache_snapshot, scene_stack) pairs from the entry scene up to
--   DEFAULT_BFS_DEPTH steps. Uses a content hash for cycle detection.
--   Fan-out = number of visible choices at each scene.

local eval = require("runtime.eval")
local M    = {}

local DEFAULT_BFS_DEPTH = 5

-- ============================================================
-- State helpers
-- ============================================================

--- Shallow-clone the flat state cache (all values are scalars/tables by ref).
--- For path@before snapshots this is sufficient since we only read the snapshot.
local function clone_cache(store)
  local snap = {}
  for k, v in pairs(store._cache) do
    -- Deep-copy table values (sets/lists) so the snapshot is independent
    if type(v) == "table" then
      local copy = {}
      for i, item in ipairs(v) do copy[i] = item end
      snap[k] = copy
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
      local items = {}
      for _, item in ipairs(v) do items[#items+1] = tostring(item) end
      parts[#parts+1] = k .. "=[" .. table.concat(items, ",") .. "]"
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
        -- Restore state directly (internal access, consistent with test approach)
        for k in pairs(eng._state._cache) do eng._state._cache[k] = nil end
        for k, v in pairs(item.cache) do
          if type(v) == "table" then
            local copy = {}
            for i, x in ipairs(v) do copy[i] = x end
            eng._state._cache[k] = copy
          else
            eng._state._cache[k] = v
          end
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
          for k in pairs(eng2._state._cache) do eng2._state._cache[k] = nil end
          for k, v in pairs(item.cache) do
            if type(v) == "table" then
              local copy = {}; for i, x in ipairs(v) do copy[i] = x end
              eng2._state._cache[k] = copy
            else eng2._state._cache[k] = v end
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
              new_path[#new_path+1] = { scene = scene_name, label = ch.label }
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
      -- Build a human-readable snapshot of the failing state
      local snap_parts = {}
      local keys = {}
      for k in pairs(cache_snap) do keys[#keys+1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local v = cache_snap[k]
        if type(v) == "table" then
          local items = {}
          for _, item in ipairs(v) do items[#items+1] = tostring(item) end
          snap_parts[#snap_parts+1] = k .. "=[" .. table.concat(items, ",") .. "]"
        else
          snap_parts[#snap_parts+1] = k .. "=" .. tostring(v)
        end
      end
      return {
        pass                 = false,
        fail_msg             = string.format(
          "verify-always violated at BFS state %d: {%s}",
          i, table.concat(snap_parts, ", ")),
        counterexample       = cache_snap,
        counterexample_n     = i,
        counterexample_path  = snap_item.path,
      }
    end
  end

  return { pass = true, states_checked = #snapshots }
end

-- ============================================================
-- after-check evaluation
-- ============================================================

local function run_after_check(verify_entry, game_table)
  local requires_expr = nil
  local after_call    = nil
  local assertions    = {}

  for _, c in ipairs(verify_entry.clauses) do
    if c.kind == "requires" then
      requires_expr = c.condition
    elseif c.kind == "after" then
      after_call = c.condition
      assertions = c.body
    end
  end

  if not after_call then return { pass = true } end

  -- Build fresh state from defaults
  local store = make_fresh_store(game_table)
  local ctx   = eval.new_ctx(store, game_table.fns, "verify", game_table)

  -- Check requires clause — skip (pass vacuously) if not satisfied
  if requires_expr then
    local ok, result = pcall(eval.eval_expr, requires_expr, ctx)
    if not ok or not result then
      return { pass = true, skipped = true,
               reason = "requires not met at initial state" }
    end
  end

  -- Snapshot state before applying the function
  local before_snap = clone_cache(store)
  ctx.before_snapshot = before_snap

  -- Apply the function
  local call_ok, call_err = pcall(eval.eval_expr, after_call, ctx)
  if not call_ok then
    return { pass = false,
             fail_msg = "function raised error: " .. tostring(call_err) }
  end

  -- Check each assertion expression with before_snapshot available
  for i, assert_expr in ipairs(assertions) do
    local ok, result = pcall(eval.eval_expr, assert_expr, ctx)
    if not ok then
      return { pass = false,
               fail_msg = string.format(
                 "assertion %d raised error: %s", i, tostring(result)) }
    end
    if not result then
      return { pass = false,
               fail_msg = string.format("assertion %d failed", i) }
    end
  end

  return { pass = true }
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
      if not ok or not result then
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
      if not ok2 or not result2 then
        -- Build counterexample detail
        local snap_parts = {}
        local keys = {}
        for k in pairs(snap) do keys[#keys+1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
          local v = snap[k]
          if type(v) == "table" then
            local items = {}
            for _, item in ipairs(v) do items[#items+1] = tostring(item) end
            snap_parts[#snap_parts+1] = k .. "=[" .. table.concat(items, ",") .. "]"
          else
            snap_parts[#snap_parts+1] = k .. "=" .. tostring(v)
          end
        end
        return {
          pass                = false,
          fail_msg            = string.format(
            "from-any-state: condition failed at BFS state %d: {%s}",
            i, table.concat(snap_parts, ", ")),
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

--- Run all verify blocks in a compiled game table.
---@param game_table table  Compiled game table from codegen
---@return table  list of {label, pass, fail_msg?, skipped?, reason?, states_checked?}
function M.run_all(game_table)
  local results = {}

  for _, verify_entry in ipairs(game_table.verifies or {}) do
    local has_always          = false
    local has_after           = false
    local has_from_any_state  = false
    for _, c in ipairs(verify_entry.clauses) do
      if c.kind == "always"          then has_always         = true end
      if c.kind == "after"           then has_after          = true end
      if c.kind == "from_any_state"  then has_from_any_state = true end
    end

    local result = { label = verify_entry.label, pass = true }

    if has_always then
      local r = run_always_check(verify_entry, game_table)
      if not r.pass then
        result.pass                 = false
        result.fail_msg             = r.fail_msg
        result.counterexample       = r.counterexample
        result.counterexample_n     = r.counterexample_n
        result.counterexample_path  = r.counterexample_path
      else
        result.states_checked = r.states_checked
      end
    end

    if has_after and result.pass then
      local r = run_after_check(verify_entry, game_table)
      if not r.pass then
        result.pass     = false
        result.fail_msg = r.fail_msg
      elseif r.skipped then
        result.skipped = true
        result.reason  = r.reason
      end
    end

    if has_from_any_state and result.pass then
      local r = run_can_reach_check(verify_entry, game_table)
      if not r.pass then
        result.pass                 = false
        result.fail_msg             = r.fail_msg
        result.counterexample       = r.counterexample
        result.counterexample_n     = r.counterexample_n
        result.counterexample_path  = r.counterexample_path
      end
    end

    results[#results+1] = result
  end

  return results
end

return M

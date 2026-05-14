-- runtime/search.lua
-- Future-state search engine (BFS/DFS/best-first reachability).
--
-- Public API:
--   can_reach(gt, cache, stack, cond_fn, depth, budget, strategy, heuristic)
--   find_path(gt, cache, stack, cond_fn, depth, budget, strategy)
--   probability(gt, cache, stack, cond_fn, depth, threshold, budget)
--     → (number, boolean)  probability, approximate
--   optimal_path(gt, cache, stack, cond_fn, depth, cost_fn, budget)
--   make_iterator(gt, cache, stack, cond_fn, depth, budget)
--     → coroutine iterator yielding (cache, path) pairs

local M = {}

-- Module-level fallback PCG used only when the BFS random-injection queue is
-- exhausted (a rare defensive path). Seeded once per process so BFS results
-- remain reproducible across calls within the same process without touching
-- Lua's global math.random state.
local _random_mod = require("runtime.random")
local _fallback_rng = _random_mod.new(0x5BFE6C09)  -- arbitrary fixed seed

-- ============================================================
-- Binary min-heap (used by optimal_path)
-- ============================================================

local function heap_push(h, item)
  local n = #h + 1
  h[n] = item
  local i = n
  while i > 1 do
    local p = math.floor(i / 2)
    if h[p].cost > h[i].cost then h[p], h[i] = h[i], h[p]; i = p else break end
  end
end

local function heap_pop(h)
  local n = #h
  if n == 0 then return nil end
  local top = h[1]
  h[1] = h[n]; h[n] = nil
  local i, size = 1, n - 1
  while true do
    local l, r, s = 2*i, 2*i+1, i
    if l <= size and h[l].cost < h[s].cost then s = l end
    if r <= size and h[r].cost < h[s].cost then s = r end
    if s == i then break end
    h[i], h[s] = h[s], h[i]; i = s
  end
  return top
end

local DEFAULT_DEPTH      = 20
local BUDGET_CHECK_N     = 50    -- check the clock every N BFS iterations
local MAX_BOUNDED_OUTCOMES = 200
local MAX_RANDOM_OUTCOMES  = 50  -- max outcomes per random-int call
local MAX_RANDOM_TOTAL     = 200 -- max total random outcome combinations

-- ============================================================
-- Helpers (shared across all search operations)
-- ============================================================

--- Apply a navigation signal to a mutable scene stack.
local function apply_signal(stack, sig)
  if not sig then return end
  if sig.type == "goto" and sig.target then
    if #stack > 0 then stack[#stack] = sig.target else stack[1] = sig.target end
  elseif sig.type == "enter" and sig.target then
    stack[#stack + 1] = sig.target
  elseif sig.type == "exit" then
    stack[#stack] = nil
  end
end

--- Clone a flat cache table (key → value).
--- Table values are shallow-copied with pairs so hash-keyed values (UMap) are preserved.
local function clone_flat(cache)
  local snap = {}
  for k, v in pairs(cache) do
    if type(v) == "table" then
      local copy = {}
      for tk, tv in pairs(v) do copy[tk] = tv end
      snap[k] = copy
    else
      snap[k] = v
    end
  end
  return snap
end

--- Clone cache + time + scheduler state from a state store + scheduler.
--- Time axes stored as "__time/<axis>" keys.
--- Scheduler state stored as "__sched/<name>/nf/<axis>", "__sched/<name>/fired/<axis>",
--- "__sched/<name>/x" (exists: 1|0) so they participate in hash_state automatically.
local function clone_cache(store, scheduler, game_table)
  local snap = clone_flat(store._cache or store)
  -- Capture time axes
  if type(store) == "table" and type(store._time) == "table" then
    for axis, val in pairs(store._time) do
      snap["__time/" .. axis] = val
    end
  end
  -- Capture scheduler state (static + dynamic schedules)
  if scheduler then
    local static_sched = (game_table and game_table.schedules) or {}
    -- Collect all schedule names we care about
    local all_names = {}
    for name in pairs(static_sched) do all_names[name] = true end
    for name in pairs(scheduler._static or {}) do all_names[name] = true end
    for name in pairs(all_names) do
      local ss = scheduler._static and scheduler._static[name]
      local prefix = "__sched/" .. name
      snap[prefix .. "/x"] = ss and 1 or 0  -- exists flag
      if ss then
        for axis, val in pairs(ss.next_fire or {}) do
          snap[prefix .. "/nf/" .. axis] = val
        end
        for axis in pairs(ss.fired or {}) do
          snap[prefix .. "/fired/" .. axis] = 1
        end
        -- Dynamic schedule: record fn_body name for reconstruction
        if not static_sched[name] and ss.fn_body then
          snap[prefix .. "/fn"] = ss.fn_body
          -- Store trigger config (every entries)
          local e_i = 0
          for _, entry in ipairs((ss.trigger or {}).every or {}) do
            e_i = e_i + 1
            snap[prefix .. "/trig/ev/" .. e_i .. "/ax"] = entry.axis
            snap[prefix .. "/trig/ev/" .. e_i .. "/v"]  = entry.value
          end
          -- at entries
          local a_i = 0
          for _, entry in ipairs((ss.trigger or {}).at or {}) do
            a_i = a_i + 1
            snap[prefix .. "/trig/at/" .. a_i .. "/ax"] = entry.axis
            snap[prefix .. "/trig/at/" .. a_i .. "/v"]  = entry.value
          end
        end
      end
    end
  end
  return snap
end

-- Render a single state cache value as a stable hash component.
-- Numbers are formatted with %.17g so that:
--   (a) floats hash deterministically across Lua versions and platforms
--       (default tostring() uses %.14g and the precision is not guaranteed);
--   (b) integer-valued floats and integers hash the same — semantically equal
--       states never inflate the BFS frontier just because a path was stored
--       once as 1 and once as 1.0.
-- Other types fall back to tostring, which is already stable for booleans,
-- strings, and symbols.
local function fmt_hash_val(v)
  if type(v) == "number" then return string.format("%.17g", v) end
  return tostring(v)
end

--- Build a deterministic hash string for a (cache, stack) state.
local function hash_state(cache, stack)
  local keys = {}
  for k in pairs(cache) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = cache[k]
    if type(v) == "table" then
      if #v > 0 then
        -- Array-like (Set, UList): iterate in order
        local items = {}
        for _, item in ipairs(v) do items[#items + 1] = fmt_hash_val(item) end
        parts[#parts + 1] = k .. "=[" .. table.concat(items, ",") .. "]"
      else
        -- Hash-keyed (UMap): sort keys for determinism
        local subkeys = {}
        for sk in pairs(v) do subkeys[#subkeys + 1] = sk end
        table.sort(subkeys)
        local items = {}
        for _, sk in ipairs(subkeys) do
          items[#items + 1] = fmt_hash_val(sk) .. ":" .. fmt_hash_val(v[sk])
        end
        parts[#parts + 1] = k .. "={" .. table.concat(items, ",") .. "}"
      end
    else
      parts[#parts + 1] = k .. "=" .. fmt_hash_val(v)
    end
  end
  parts[#parts + 1] = "||" .. table.concat(stack or {}, "/")
  return table.concat(parts, ";")
end

--- Restore an engine instance's state from a cache snapshot + scene stack.
--- Handles "__time/<axis>" keys (time axes) and "__sched/<name>/..." keys
--- (scheduler state) as special fields; everything else goes to _state._cache.
local function restore_engine(eng, cache, stack)
  -- Clear and restore the value cache
  for k in pairs(eng._state._cache) do eng._state._cache[k] = nil end
  -- Reset all time axes to 0 before applying snapshot
  if type(eng._state._time) == "table" then
    for k in pairs(eng._state._time) do eng._state._time[k] = 0 end
  end

  -- Collect scheduler state from special keys (applied after cache pass)
  -- sched_data[name] = { exists, nf={axis=val,...}, fired={axis=true,...}, fn, trig_ev, trig_at }
  local sched_data = {}

  -- Apply the snapshot
  for k, v in pairs(cache) do
    local time_axis = k:match("^__time/(.+)$")
    if time_axis then
      if type(eng._state._time) == "table" then
        eng._state._time[time_axis] = v
      end
    else
      local sched_name, rest = k:match("^__sched/([^/]+)/(.+)$")
      if sched_name then
        local d = sched_data[sched_name]
        if not d then
          d = { exists=0, nf={}, fired={}, fn=nil, trig_ev={}, trig_at={} }
          sched_data[sched_name] = d
        end
        if rest == "x" then
          d.exists = v
        elseif rest == "fn" then
          d.fn = v
        else
          local nf_axis = rest:match("^nf/(.+)$")
          if nf_axis then d.nf[nf_axis] = v; goto sched_done end
          local fired_axis = rest:match("^fired/(.+)$")
          if fired_axis then d.fired[fired_axis] = true; goto sched_done end
          -- Dynamic trigger: trig/ev/<i>/ax or trig/ev/<i>/v
          local ev_i, field = rest:match("^trig/ev/(%d+)/(.+)$")
          if ev_i then
            local idx = tonumber(ev_i)
            d.trig_ev[idx] = d.trig_ev[idx] or {}
            if field == "ax" then d.trig_ev[idx].axis = v
            else d.trig_ev[idx].value = v end
            goto sched_done
          end
          local at_i, at_field = rest:match("^trig/at/(%d+)/(.+)$")
          if at_i then
            local idx = tonumber(at_i)
            d.trig_at[idx] = d.trig_at[idx] or {}
            if at_field == "ax" then d.trig_at[idx].axis = v
            else d.trig_at[idx].value = v end
          end
          ::sched_done::
        end
      elseif type(v) == "table" then
        local copy = {}
        for tk, tv in pairs(v) do copy[tk] = tv end
        eng._state._cache[k] = copy
      else
        eng._state._cache[k] = v
      end
    end
  end

  -- Apply scheduler state from snapshot
  if next(sched_data) ~= nil and eng._scheduler then
    local static_sched = (eng._game and eng._game.schedules) or {}
    for name, d in pairs(sched_data) do
      if d.exists == 0 then
        -- Schedule was removed (cancel-schedule! or at: exhausted)
        eng._scheduler._static[name] = nil
      else
        -- Schedule exists: update its next_fire and fired thresholds
        local ss = eng._scheduler._static[name]
        if ss then
          -- Override thresholds from snapshot
          ss.next_fire = {}
          for axis, val in pairs(d.nf) do ss.next_fire[axis] = val end
          ss.fired = {}
          for axis in pairs(d.fired) do ss.fired[axis] = true end
        elseif not static_sched[name] and d.fn then
          -- Dynamic schedule not in game_table: reconstruct from snapshot
          local fn_decl = eng._fns and eng._fns[d.fn]
          local body    = fn_decl and fn_decl.body or {}
          local ev_list, at_list = {}, {}
          for _, e in ipairs(d.trig_ev) do
            if e then ev_list[#ev_list+1] = { axis=e.axis, value=e.value } end
          end
          for _, e in ipairs(d.trig_at) do
            if e then at_list[#at_list+1] = { axis=e.axis, value=e.value } end
          end
          local trigger = { every=ev_list, at=at_list, offset={} }
          local fire_at = {}
          for _, e in ipairs(at_list) do fire_at[e.axis] = e.value end
          eng._scheduler._static[name] = {
            name      = name,
            trigger   = trigger,
            body      = body,
            fn_body   = d.fn,
            next_fire = d.nf,
            fire_at   = fire_at,
            fired     = d.fired,
          }
        end
      end
    end
  end

  -- Restore the scene stack
  eng._scene_stack = {}
  for _, s in ipairs(stack) do eng._scene_stack[#eng._scene_stack + 1] = s end

  -- Restore grid cells: reset to defaults then apply __grid/* cache overrides so that
  -- tilegrid algorithms (visible-from?, path-to) see the correct mutated cell values.
  if next(eng._grids or {}) ~= nil then
    local tg_mod = require("runtime.tilegrid")
    for name, g in pairs(eng._grids) do
      eng._grids[name].cells = tg_mod.new(g.width, g.height, g.default_val)
    end
    for k, v in pairs(cache) do
      local gname, sx, sy = k:match("^__grid/([^/]+)/(-?%d+),(-?%d+)$")
      if gname and eng._grids[gname] then
        local g = eng._grids[gname]
        tg_mod.set(g.cells, g.width, g.height, tonumber(sx), tonumber(sy), v)
      end
    end
  end
end

-- ============================================================
-- Bounded computation branching helpers
-- ============================================================

--- Return the list of discrete values for a bounded declaration's return type.
--- Returns nil if the range is not enumerable or is too large (> MAX_BOUNDED_OUTCOMES).
local function bounded_return_values(decl)
  local r = decl and decl.returns
  if not r or type(r) ~= "table" then return nil end
  if r.tag == "int" then
    local lo = r.min or 0
    local hi = r.max or 1
    if type(lo) ~= "number" or type(hi) ~= "number" then return nil end
    if hi - lo + 1 > MAX_BOUNDED_OUTCOMES then return nil end
    local vals = {}
    for v = lo, hi do vals[#vals + 1] = v end
    return vals
  end
  return nil
end

--- Build a list of {name → value} handler maps for all enumerable bounded decls.
--- Returns {{}} (one empty combo) when there are no enumerable bounded decls.
local function bounded_outcome_combos(bounded_decls)
  if not bounded_decls or not next(bounded_decls) then return {{}} end

  local names     = {}
  local val_lists = {}
  for name, decl in pairs(bounded_decls) do
    local vals = bounded_return_values(decl)
    if vals and #vals > 0 then
      names[#names + 1] = name
      val_lists[name]   = vals
    end
  end
  if #names == 0 then return {{}} end

  table.sort(names)  -- deterministic order

  local combos = {{}}
  for _, name in ipairs(names) do
    local new_combos = {}
    for _, combo in ipairs(combos) do
      for _, val in ipairs(val_lists[name]) do
        local c = {}
        for k, v in pairs(combo) do c[k] = v end
        c[name] = val
        new_combos[#new_combos + 1] = c
        if #new_combos >= MAX_BOUNDED_OUTCOMES then break end
      end
      if #new_combos >= MAX_BOUNDED_OUTCOMES then break end
    end
    combos = new_combos
  end
  return combos
end

-- ============================================================
-- Random source branching helpers
-- ============================================================

--- Build a list of value-sequence arrays for all possible random-int outcomes.
--- Each element is a list [v1, v2, ...] giving one outcome per random call.
--- randoms: list of {lo=N, hi=N} captured from a tracing pass.
local function random_outcome_combos(randoms)
  if not randoms or #randoms == 0 then return { {} } end  -- one "no inject" combo

  local combos = {{}}  -- list of value-sequences
  for _, r in ipairs(randoms) do
    local new_combos = {}
    local hi_capped  = math.min(r.hi, r.lo + MAX_RANDOM_OUTCOMES - 1)
    for _, existing in ipairs(combos) do
      for v = r.lo, hi_capped do
        local c = {}
        for j, x in ipairs(existing) do c[j] = x end
        c[#c + 1] = v
        new_combos[#new_combos + 1] = c
        if #new_combos >= MAX_RANDOM_TOTAL then break end
      end
      if #new_combos >= MAX_RANDOM_TOTAL then break end
    end
    combos = new_combos
  end
  return combos
end

--- Trace a single do_choice execution to discover which random-int calls it makes.
--- Returns a list of {lo=N, hi=N} for each call in execution order.
local function trace_random_calls(game_table, engine_mod, io_sink, cache, stack, scene_name, choice_index)
  local randoms = {}
  local saved   = game_table._random_inject
  game_table._random_inject = function(lo, hi)
    randoms[#randoms + 1] = { lo = lo, hi = hi }
    return lo  -- placeholder: use minimum value
  end
  local eng = engine_mod.new(game_table, { io_out = io_sink })
  eng:register_actors_schedules()
    eng._in_bfs = true
  restore_engine(eng, cache, stack)
  pcall(function() eng:do_choice(scene_name, choice_index) end)
  game_table._random_inject = saved
  return randoms
end

-- ============================================================
-- BFS / DFS / best-first can_reach
-- ============================================================

--- Search over (cache, stack) states; return true if condition_fn is
--- satisfied by any reachable state within depth steps.
---
--- strategy:
---   "bfs"        — breadth-first (default)
---   "dfs"        — depth-first
---   "best-first" — heuristic-guided (explore lowest heuristic value first)
---
--- heuristic: function(cache) → number  (lower = closer to goal; only for best-first)
---
---@return boolean, boolean  reached, timed_out
function M.can_reach(game_table, initial_cache, initial_stack, condition_fn,
                     depth, budget, strategy, heuristic)
  depth    = depth    or DEFAULT_DEPTH
  strategy = strategy or "bfs"
  heuristic = heuristic or function() return 0 end

  local engine_mod = require("runtime.engine")
  local seen       = {}
  local io_sink    = { write = function() end }
  local start_time = budget and os.clock() or nil
  local iter_count = 0

  if condition_fn(initial_cache) then return true, false end

  -- Queue entries: {cache, stack, d, priority}
  -- priority is used for best-first (lower = dequeued first)
  local queue = { {
    cache    = clone_flat(initial_cache),
    stack    = initial_stack,
    d        = 0,
    priority = heuristic(initial_cache),
  } }
  local head = 1  -- BFS FIFO head pointer (not used for DFS/best-first)

  while true do
    -- Check termination condition
    if strategy == "dfs" then
      if #queue < head then break end
    elseif strategy == "best-first" then
      if head > #queue then break end
    else  -- bfs
      if head > #queue then break end
    end

    -- Dequeue
    local item
    if strategy == "dfs" then
      item = table.remove(queue)
    elseif strategy == "best-first" then
      -- Find minimum-priority item from head onward
      local best_i = head
      for i = head + 1, #queue do
        if queue[i].priority < queue[best_i].priority then best_i = i end
      end
      if best_i == head then
        item = queue[head]; head = head + 1
      else
        item = table.remove(queue, best_i)
        -- head pointer still valid (we removed from a later position)
      end
    else  -- bfs
      item = queue[head]; head = head + 1
    end

    iter_count = iter_count + 1

    -- Time-budget check (every BUDGET_CHECK_N iterations)
    if budget and iter_count % BUDGET_CHECK_N == 0 then
      if (os.clock() - start_time) >= budget then
        return nil, true  -- timed out: result unknown
      end
    end

    if item.d >= depth then goto next_item end

    local h = hash_state(item.cache, item.stack)
    if seen[h] then goto next_item end
    seen[h] = true

    local scene_name = item.stack[#item.stack]
    if not scene_name then goto next_item end

    -- ── Choices expansion ────────────────────────────────────────

    local eng = engine_mod.new(game_table, { io_out = io_sink })
    eng:register_actors_schedules()
    eng._in_bfs = true
    restore_engine(eng, item.cache, item.stack)

    local ok, choices_or_err = pcall(function()
      local _, choices = eng:render_scene(scene_name)
      return choices
    end)
    if not ok then goto next_item end
    local choices = choices_or_err or {}

    -- Pre-compute bounded outcome combos (once per scene-item)
    local b_combos = bounded_outcome_combos(game_table.bounded)

    for _, ch in ipairs(choices) do
      -- Trace random calls for this choice (one tracing pass)
      local randoms    = trace_random_calls(game_table, engine_mod, io_sink,
                                            item.cache, item.stack,
                                            scene_name, ch.index)
      local r_combos   = random_outcome_combos(randoms)

      for _, outcome_map in ipairs(b_combos) do
        -- Inject bounded handlers for this outcome combination
        local saved_b = game_table._bounded_handlers
        if next(outcome_map) ~= nil then
          local new_h = {}
          for k, v in pairs(saved_b or {}) do new_h[k] = v end
          for bname, bval in pairs(outcome_map) do
            local bval_cap = bval
            new_h[bname] = function() return bval_cap end
          end
          game_table._bounded_handlers = new_h
        end

        for _, r_seq in ipairs(r_combos) do
          -- Inject random outcomes for this sequence (nil seq = no injection)
          local saved_r = game_table._random_inject
          if r_seq ~= nil then
            local queue_vals = {}
            for _, v in ipairs(r_seq) do queue_vals[#queue_vals + 1] = v end
            game_table._random_inject = function(lo, hi)
              local v = table.remove(queue_vals, 1)
              return v ~= nil and v or _fallback_rng:int(lo, hi)
            end
          end

          local eng2 = engine_mod.new(game_table, { io_out = io_sink })
          eng2:register_actors_schedules()
    eng2._in_bfs = true
          restore_engine(eng2, item.cache, item.stack)

          local ok2, sig = pcall(function()
            return eng2:do_choice(scene_name, ch.index)
          end)

          game_table._random_inject = saved_r

          if ok2 then
            pcall(function() eng2:post_action() end)

            local new_cache = clone_cache(eng2._state, eng2._scheduler, game_table)
            local new_stack = {}
            for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack + 1] = s end

            apply_signal(new_stack, sig)

            if condition_fn(new_cache) then
              game_table._bounded_handlers = saved_b
              return true, false
            end

            if #new_stack > 0 then
              queue[#queue + 1] = {
                cache    = new_cache,
                stack    = new_stack,
                d        = item.d + 1,
                priority = heuristic(new_cache),
              }
            end
          end
        end  -- r_seq loop

        game_table._bounded_handlers = saved_b
      end  -- outcome_map loop
    end  -- choices loop

    -- ── Autonomous tick successor (scheduled events, actor phases) ──
    -- Fire pending scheduled events without a player choice.
    do
      local eng_t = engine_mod.new(game_table, { io_out = io_sink })
      eng_t:register_actors_schedules()
  eng_t._in_bfs = true
      restore_engine(eng_t, item.cache, item.stack)
      local ok_t = pcall(function() eng_t:autonomous_turn() end)
      if ok_t then
        local new_cache_t = clone_cache(eng_t._state, eng_t._scheduler, game_table)
        local new_stack_t = {}
        for _, s in ipairs(eng_t._scene_stack) do
          new_stack_t[#new_stack_t + 1] = s
        end
        local h_t = hash_state(new_cache_t, new_stack_t)
        if not seen[h_t] then
          if condition_fn(new_cache_t) then return true, false end
          if #new_stack_t > 0 then
            queue[#queue + 1] = {
              cache    = new_cache_t,
              stack    = new_stack_t,
              d        = item.d + 1,
              priority = heuristic(new_cache_t),
            }
          end
        end
      end
    end

    ::next_item::
  end

  return false, false
end

-- ============================================================
-- BFS / DFS find_path
-- ============================================================

--- Search over (cache, stack) states; return the action sequence leading to
--- a state satisfying condition_fn, or nil if unreachable within depth.
---
---@return table?  list of {scene, label, index} steps, or nil
function M.find_path(game_table, initial_cache, initial_stack, condition_fn,
                     depth, budget, strategy)
  depth    = depth    or DEFAULT_DEPTH
  strategy = strategy or "bfs"

  local engine_mod = require("runtime.engine")
  local seen       = {}
  local io_sink    = { write = function() end }
  local start_time = budget and os.clock() or nil
  local iter_count = 0

  if condition_fn(initial_cache) then return {} end

  local queue = { {
    cache = clone_flat(initial_cache),
    stack = initial_stack,
    d     = 0,
    path  = {},
  } }
  local head = 1

  while (strategy == "bfs" and head <= #queue) or
        (strategy == "dfs" and #queue >= head) do

    local item
    if strategy == "dfs" then
      item = table.remove(queue)
    else
      item = queue[head]; head = head + 1
    end

    iter_count = iter_count + 1

    if budget and iter_count % BUDGET_CHECK_N == 0 then
      if (os.clock() - start_time) >= budget then return nil end
    end

    if item.d >= depth then goto next_fp_item end

    local h = hash_state(item.cache, item.stack)
    if seen[h] then goto next_fp_item end
    seen[h] = true

    local scene_name = item.stack[#item.stack]
    if not scene_name then goto next_fp_item end

    local eng = engine_mod.new(game_table, { io_out = io_sink })
    eng:register_actors_schedules()
    eng._in_bfs = true
    restore_engine(eng, item.cache, item.stack)

    local ok, choices_or_err = pcall(function()
      local _, choices = eng:render_scene(scene_name)
      return choices
    end)
    if not ok then goto next_fp_item end
    local choices = choices_or_err or {}

    local b_combos2 = bounded_outcome_combos(game_table.bounded)

    for _, ch in ipairs(choices) do
      local randoms2  = trace_random_calls(game_table, engine_mod, io_sink,
                                           item.cache, item.stack,
                                           scene_name, ch.index)
      local r_combos2 = random_outcome_combos(randoms2)

      for _, outcome_map in ipairs(b_combos2) do
        local saved_b2 = game_table._bounded_handlers
        if next(outcome_map) ~= nil then
          local new_h = {}
          for k, v in pairs(saved_b2 or {}) do new_h[k] = v end
          for bname, bval in pairs(outcome_map) do
            local bval_cap = bval
            new_h[bname] = function() return bval_cap end
          end
          game_table._bounded_handlers = new_h
        end

        for _, r_seq2 in ipairs(r_combos2) do
          local saved_r2 = game_table._random_inject
          if r_seq2 ~= nil then
            local queue_vals2 = {}
            for _, v in ipairs(r_seq2) do queue_vals2[#queue_vals2 + 1] = v end
            game_table._random_inject = function(lo, hi)
              local v = table.remove(queue_vals2, 1)
              return v ~= nil and v or _fallback_rng:int(lo, hi)
            end
          end

          local eng2 = engine_mod.new(game_table, { io_out = io_sink })
          eng2:register_actors_schedules()
    eng2._in_bfs = true
          restore_engine(eng2, item.cache, item.stack)

          local ok2, sig = pcall(function()
            return eng2:do_choice(scene_name, ch.index)
          end)
          game_table._random_inject = saved_r2

          if ok2 then
            pcall(function() eng2:post_action() end)

            local new_cache = clone_cache(eng2._state, eng2._scheduler, game_table)
            local new_stack = {}
            for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack + 1] = s end

            apply_signal(new_stack, sig)

            local new_path = {}
            for _, step in ipairs(item.path) do new_path[#new_path + 1] = step end
            new_path[#new_path + 1] = {
              scene = scene_name,
              label = ch.label,
              index = ch.index,
            }

            if condition_fn(new_cache) then
              game_table._bounded_handlers = saved_b2
              return new_path
            end

            if #new_stack > 0 then
              queue[#queue + 1] = {
                cache = new_cache,
                stack = new_stack,
                d     = item.d + 1,
                path  = new_path,
              }
            end
          end
        end  -- r_seq loop

        game_table._bounded_handlers = saved_b2
      end  -- outcome_map loop
    end  -- choices loop

    -- Autonomous tick successor (with "_tick" label)
    do
      local eng_t = engine_mod.new(game_table, { io_out = io_sink })
      eng_t:register_actors_schedules()
  eng_t._in_bfs = true
      restore_engine(eng_t, item.cache, item.stack)
      local ok_t = pcall(function() eng_t:autonomous_turn() end)
      if ok_t then
        local new_cache_t = clone_cache(eng_t._state, eng_t._scheduler, game_table)
        local new_stack_t = {}
        for _, s in ipairs(eng_t._scene_stack) do new_stack_t[#new_stack_t + 1] = s end
        local h_t = hash_state(new_cache_t, new_stack_t)
        if not seen[h_t] then
          local new_path_t = {}
          for _, step in ipairs(item.path) do new_path_t[#new_path_t + 1] = step end
          new_path_t[#new_path_t + 1] = { scene = scene_name, label = "_tick", index = 0 }

          if condition_fn(new_cache_t) then return new_path_t end
          if #new_stack_t > 0 then
            queue[#queue + 1] = {
              cache = new_cache_t,
              stack = new_stack_t,
              d     = item.d + 1,
              path  = new_path_t,
            }
          end
        end
      end
    end

    ::next_fp_item::
  end

  return nil
end

-- ============================================================
-- Probability search
-- ============================================================

--- Compute the probability that condition_fn holds at exactly `depth` steps
--- in the future, assuming uniform random choice at each step.
---
---@param budget    number?   Max wall-clock seconds (nil = no limit)
---@return number, boolean   probability in [0,1], approximate (true if pruning occurred)
function M.probability(game_table, initial_cache, initial_stack, condition_fn,
                       depth, threshold, budget)
  depth     = depth     or 10
  threshold = threshold or 0.001

  local engine_mod = require("runtime.engine")
  local io_sink    = { write = function() end }
  local start_time = budget and os.clock() or nil
  local iter_count = 0
  local approximate = false  -- becomes true if any branch is pruned below threshold

  local queue = { { cache = clone_flat(initial_cache), stack = initial_stack,
                    prob = 1.0, d = 0 } }
  local head  = 1
  local total_prob = 0.0

  if depth == 0 and condition_fn(initial_cache) then return 1.0, false end

  while head <= #queue do
    local item = queue[head]; head = head + 1

    iter_count = iter_count + 1
    if budget and iter_count % BUDGET_CHECK_N == 0 then
      if (os.clock() - start_time) >= budget then
        return math.min(1.0, total_prob), true  -- timed out → approximate
      end
    end

    if item.prob < threshold then
      approximate = true  -- pruned a branch
      goto next_prob_item
    end

    if item.d == depth then
      if condition_fn(item.cache) then
        total_prob = total_prob + item.prob
      end
      goto next_prob_item
    end

    local scene_name = item.stack[#item.stack]
    if not scene_name then goto next_prob_item end

    local eng = engine_mod.new(game_table, { io_out = io_sink })
    eng:register_actors_schedules()
    eng._in_bfs = true
    restore_engine(eng, item.cache, item.stack)

    local ok, choices = pcall(function()
      local _, ch = eng:render_scene(scene_name); return ch
    end)
    if not ok or not choices or #choices == 0 then
      if condition_fn(item.cache) then total_prob = total_prob + item.prob end
      goto next_prob_item
    end

    local branch_prob = item.prob / #choices

    for _, ch in ipairs(choices) do
      if branch_prob >= threshold then
        local eng2 = engine_mod.new(game_table, { io_out = io_sink })
        eng2:register_actors_schedules()
    eng2._in_bfs = true
        restore_engine(eng2, item.cache, item.stack)

        local ok2, sig = pcall(function() return eng2:do_choice(scene_name, ch.index) end)
        if ok2 then
          pcall(function() eng2:post_action() end)

          local new_cache = clone_cache(eng2._state, eng2._scheduler, game_table)
          local new_stack = {}
          for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack+1] = s end

          apply_signal(new_stack, sig)

          if #new_stack > 0 then
            queue[#queue+1] = { cache = new_cache, stack = new_stack,
                                prob = branch_prob, d = item.d + 1 }
          end
        end
      else
        approximate = true  -- pruned low-probability branch
      end
    end

    ::next_prob_item::
  end

  return math.min(1.0, total_prob), approximate
end

-- ============================================================
-- Optimal path search (Dijkstra / uniform cost BFS)
-- ============================================================

--- Find the minimum-cost action sequence to reach a state satisfying condition_fn.
---
---@param budget  number?   Max wall-clock seconds (nil = no limit)
---@return table?  list of {scene, label, index} steps (minimum cost), or nil
function M.optimal_path(game_table, initial_cache, initial_stack, condition_fn,
                        depth, cost_fn, budget)
  depth   = depth   or DEFAULT_DEPTH
  cost_fn = cost_fn or function() return 1 end

  local engine_mod = require("runtime.engine")
  local seen       = {}
  local io_sink    = { write = function() end }
  local start_time = budget and os.clock() or nil
  local iter_count = 0

  if condition_fn(initial_cache) then return {} end

  local open = {}
  heap_push(open, {
    cache = clone_flat(initial_cache),
    stack = initial_stack,
    d     = 0,
    cost  = 0,
    path  = {},
  })

  while #open > 0 do
    local item = heap_pop(open)

    iter_count = iter_count + 1
    if budget and iter_count % BUDGET_CHECK_N == 0 then
      if (os.clock() - start_time) >= budget then return nil end
    end

    if item.d > depth then goto next_opt_item end

    local h = hash_state(item.cache, item.stack)
    if seen[h] then goto next_opt_item end
    seen[h] = true

    local scene_name = item.stack[#item.stack]
    if not scene_name then goto next_opt_item end

    local eng = engine_mod.new(game_table, { io_out = io_sink })
    eng:register_actors_schedules()
    eng._in_bfs = true
    restore_engine(eng, item.cache, item.stack)

    local ok, choices = pcall(function()
      local _, ch = eng:render_scene(scene_name); return ch
    end)
    if not ok then goto next_opt_item end
    local choices = choices or {}

    for _, ch in ipairs(choices) do
      local eng2 = engine_mod.new(game_table, { io_out = io_sink })
      eng2:register_actors_schedules()
    eng2._in_bfs = true
      restore_engine(eng2, item.cache, item.stack)

      local ok2, sig = pcall(function() return eng2:do_choice(scene_name, ch.index) end)
      if ok2 then
        pcall(function() eng2:post_action() end)

        local new_cache = clone_cache(eng2._state, eng2._scheduler, game_table)
        local new_stack = {}
        for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack+1] = s end

        apply_signal(new_stack, sig)

        local new_path = {}
        for _, step in ipairs(item.path) do new_path[#new_path+1] = step end
        new_path[#new_path+1] = { scene = scene_name, label = ch.label, index = ch.index }

        if condition_fn(new_cache) then return new_path end

        if #new_stack > 0 then
          local step_cost = cost_fn(new_cache)
          if type(step_cost) ~= "number" then step_cost = 1 end
          heap_push(open, {
            cache = new_cache,
            stack = new_stack,
            d     = item.d + 1,
            cost  = item.cost + step_cost,
            path  = new_path,
          })
        end
      end
    end

    ::next_opt_item::
  end

  return nil
end

-- ============================================================
-- Coroutine iterator
-- ============================================================

--- Return a Lua iterator (coroutine) that yields every (cache, path) pair
--- satisfying condition_fn, up to depth steps from the initial state.
---
--- Usage:
---   local iter = search_mod.make_iterator(gt, cache, stack, cond_fn, depth)
---   for state_cache, path in iter do
---     -- process each found state
---   end
---
---@return function  iterator: → (cache, path) or nothing when exhausted
function M.make_iterator(game_table, initial_cache, initial_stack, condition_fn,
                         depth, budget)
  depth = depth or DEFAULT_DEPTH

  return coroutine.wrap(function()
    local engine_mod = require("runtime.engine")
    local seen       = {}
    local io_sink    = { write = function() end }
    local start_time = budget and os.clock() or nil
    local iter_count = 0

    if condition_fn(initial_cache) then
      coroutine.yield(initial_cache, {})
    end

    local queue = { {
      cache = clone_flat(initial_cache),
      stack = initial_stack,
      d     = 0,
      path  = {},
    } }
    local head = 1

    while head <= #queue do
      local item = queue[head]; head = head + 1

      iter_count = iter_count + 1
      if budget and iter_count % BUDGET_CHECK_N == 0 then
        if (os.clock() - start_time) >= budget then return end
      end

      if item.d >= depth then goto next_iter_item end

      local h = hash_state(item.cache, item.stack)
      if seen[h] then goto next_iter_item end
      seen[h] = true

      local scene_name = item.stack[#item.stack]
      if not scene_name then goto next_iter_item end

      local eng = engine_mod.new(game_table, { io_out = io_sink })
      eng:register_actors_schedules()
    eng._in_bfs = true
      restore_engine(eng, item.cache, item.stack)

      local ok, choices_or_err = pcall(function()
        local _, choices = eng:render_scene(scene_name)
        return choices
      end)
      if not ok then goto next_iter_item end
      local choices = choices_or_err or {}

      for _, ch in ipairs(choices) do
        local eng2 = engine_mod.new(game_table, { io_out = io_sink })
        eng2:register_actors_schedules()
    eng2._in_bfs = true
        restore_engine(eng2, item.cache, item.stack)

        local ok2, sig = pcall(function()
          return eng2:do_choice(scene_name, ch.index)
        end)

        if ok2 then
          pcall(function() eng2:post_action() end)

          local new_cache = clone_cache(eng2._state, eng2._scheduler, game_table)
          local new_stack = {}
          for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack + 1] = s end

          apply_signal(new_stack, sig)

          local new_path = {}
          for _, step in ipairs(item.path) do new_path[#new_path + 1] = step end
          new_path[#new_path + 1] = { scene = scene_name, label = ch.label, index = ch.index }

          if condition_fn(new_cache) then
            coroutine.yield(new_cache, new_path)
          end

          if #new_stack > 0 then
            queue[#queue + 1] = {
              cache = new_cache,
              stack = new_stack,
              d     = item.d + 1,
              path  = new_path,
            }
          end
        end
      end

      ::next_iter_item::
    end
  end)
end

-- ============================================================
-- Legacy object-based API (stub, kept for compatibility)
-- ============================================================

--- Create a new search engine instance (legacy API).
function M.new(state, game, opts)
  opts = opts or {}
  local eng = {
    _state     = state,
    _game      = game,
    _depth     = opts.depth                  or DEFAULT_DEPTH,
    _strategy  = opts.strategy               or "breadth-first",
    _threshold = opts.probability_threshold  or 0.01,
    _approximate = false,
  }

  function eng:can_reach(condition) local _ = condition; return false end
  function eng:find_path(condition) local _ = condition; return nil end
  function eng:verify_always(condition) local _ = condition; return true end
  function eng:find_counterexample(condition) local _ = condition; return nil end
  function eng:probability(condition, d) local _ = condition; local _ = d; return 0.0 end

  return eng
end

--- Exported for use by eval.lua builtins (counterfactual, can-reach?, etc.)
--- Equivalent to clone_cache but accessible outside this module.
M.clone_cache = clone_cache

-- Exposed for testing only; not part of the stable public API.
M._hash_state = hash_state

return M

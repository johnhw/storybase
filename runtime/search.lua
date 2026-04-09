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

local DEFAULT_DEPTH      = 20
local BUDGET_CHECK_N     = 50    -- check the clock every N BFS iterations
local MAX_BOUNDED_OUTCOMES = 200
local MAX_RANDOM_OUTCOMES  = 50  -- max outcomes per random-int call
local MAX_RANDOM_TOTAL     = 200 -- max total random outcome combinations

-- ============================================================
-- Helpers (shared across all search operations)
-- ============================================================

--- Clone a flat cache table (key → value).
--- Table values are treated as arrays (shallow ipairs copy).
local function clone_flat(cache)
  local snap = {}
  for k, v in pairs(cache) do
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

--- Clone cache + time from a state store object.
--- Time axes are stored as "__time/<axis>" keys so they participate
--- in cycle detection via hash_state without special-casing.
local function clone_cache(store)
  local snap = clone_flat(store._cache or store)
  -- Also capture time axes (present on real store objects, absent on plain dicts)
  if type(store) == "table" and type(store._time) == "table" then
    for axis, val in pairs(store._time) do
      snap["__time/" .. axis] = val
    end
  end
  return snap
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
      -- Treat as array (list values in entity families, etc.)
      local items = {}
      for _, item in ipairs(v) do items[#items + 1] = tostring(item) end
      parts[#parts + 1] = k .. "=[" .. table.concat(items, ",") .. "]"
    else
      parts[#parts + 1] = k .. "=" .. tostring(v)
    end
  end
  parts[#parts + 1] = "||" .. table.concat(stack or {}, "/")
  return table.concat(parts, ";")
end

--- Restore an engine instance's state from a cache snapshot + scene stack.
--- Handles "__time/<axis>" keys by writing them to eng._state._time.
local function restore_engine(eng, cache, stack)
  -- Clear and restore the value cache
  for k in pairs(eng._state._cache) do eng._state._cache[k] = nil end
  -- Reset all time axes to 0 before applying snapshot
  if type(eng._state._time) == "table" then
    for k in pairs(eng._state._time) do eng._state._time[k] = 0 end
  end
  -- Apply the snapshot
  for k, v in pairs(cache) do
    local axis = k:match("^__time/(.+)$")
    if axis then
      if type(eng._state._time) == "table" then
        eng._state._time[axis] = v
      end
    elseif type(v) == "table" then
      local copy = {}
      for i, x in ipairs(v) do copy[i] = x end
      eng._state._cache[k] = copy
    else
      eng._state._cache[k] = v
    end
  end
  -- Restore the scene stack
  eng._scene_stack = {}
  for _, s in ipairs(stack) do eng._scene_stack[#eng._scene_stack + 1] = s end
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
        return false, true  -- timed out
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
              return v ~= nil and v or math.random(lo, hi)
            end
          end

          local eng2 = engine_mod.new(game_table, { io_out = io_sink })
          eng2:register_actors_schedules()
          restore_engine(eng2, item.cache, item.stack)

          local ok2, sig = pcall(function()
            return eng2:do_choice(scene_name, ch.index)
          end)

          game_table._random_inject = saved_r

          if ok2 then
            pcall(function() eng2:post_action() end)

            local new_cache = clone_cache(eng2._state)
            local new_stack = {}
            for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack + 1] = s end

            -- Apply navigation signal
            if sig then
              if sig.type == "goto" and sig.target then
                if #new_stack > 0 then new_stack[#new_stack] = sig.target
                else new_stack[1] = sig.target end
              elseif sig.type == "enter" and sig.target then
                new_stack[#new_stack + 1] = sig.target
              elseif sig.type == "exit" then
                new_stack[#new_stack] = nil
              end
            end

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
      restore_engine(eng_t, item.cache, item.stack)
      local ok_t = pcall(function() eng_t:autonomous_turn() end)
      if ok_t then
        local new_cache_t = clone_cache(eng_t._state)
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
              return v ~= nil and v or math.random(lo, hi)
            end
          end

          local eng2 = engine_mod.new(game_table, { io_out = io_sink })
          eng2:register_actors_schedules()
          restore_engine(eng2, item.cache, item.stack)

          local ok2, sig = pcall(function()
            return eng2:do_choice(scene_name, ch.index)
          end)
          game_table._random_inject = saved_r2

          if ok2 then
            pcall(function() eng2:post_action() end)

            local new_cache = clone_cache(eng2._state)
            local new_stack = {}
            for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack + 1] = s end

            if sig then
              if sig.type == "goto" and sig.target then
                if #new_stack > 0 then new_stack[#new_stack] = sig.target
                else new_stack[1] = sig.target end
              elseif sig.type == "enter" and sig.target then
                new_stack[#new_stack + 1] = sig.target
              elseif sig.type == "exit" then
                new_stack[#new_stack] = nil
              end
            end

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
      restore_engine(eng_t, item.cache, item.stack)
      local ok_t = pcall(function() eng_t:autonomous_turn() end)
      if ok_t then
        local new_cache_t = clone_cache(eng_t._state)
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
        restore_engine(eng2, item.cache, item.stack)

        local ok2, sig = pcall(function() return eng2:do_choice(scene_name, ch.index) end)
        if ok2 then
          pcall(function() eng2:post_action() end)

          local new_cache = clone_cache(eng2._state)
          local new_stack = {}
          for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack+1] = s end

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

  local open = { {
    cache = clone_flat(initial_cache),
    stack = initial_stack,
    d     = 0,
    cost  = 0,
    path  = {},
  } }

  while #open > 0 do
    table.sort(open, function(a, b) return a.cost < b.cost end)
    local item = table.remove(open, 1)

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
    restore_engine(eng, item.cache, item.stack)

    local ok, choices = pcall(function()
      local _, ch = eng:render_scene(scene_name); return ch
    end)
    if not ok then goto next_opt_item end
    local choices = choices or {}

    for _, ch in ipairs(choices) do
      local eng2 = engine_mod.new(game_table, { io_out = io_sink })
      eng2:register_actors_schedules()
      restore_engine(eng2, item.cache, item.stack)

      local ok2, sig = pcall(function() return eng2:do_choice(scene_name, ch.index) end)
      if ok2 then
        pcall(function() eng2:post_action() end)

        local new_cache = clone_cache(eng2._state)
        local new_stack = {}
        for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack+1] = s end

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

        local new_path = {}
        for _, step in ipairs(item.path) do new_path[#new_path+1] = step end
        new_path[#new_path+1] = { scene = scene_name, label = ch.label, index = ch.index }

        if condition_fn(new_cache) then return new_path end

        if #new_stack > 0 then
          local step_cost = cost_fn(new_cache)
          if type(step_cost) ~= "number" then step_cost = 1 end
          open[#open+1] = {
            cache = new_cache,
            stack = new_stack,
            d     = item.d + 1,
            cost  = item.cost + step_cost,
            path  = new_path,
          }
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
        restore_engine(eng2, item.cache, item.stack)

        local ok2, sig = pcall(function()
          return eng2:do_choice(scene_name, ch.index)
        end)

        if ok2 then
          pcall(function() eng2:post_action() end)

          local new_cache = clone_cache(eng2._state)
          local new_stack = {}
          for _, s in ipairs(eng2._scene_stack) do new_stack[#new_stack + 1] = s end

          if sig then
            if sig.type == "goto" and sig.target then
              if #new_stack > 0 then new_stack[#new_stack] = sig.target
              else new_stack[1] = sig.target end
            elseif sig.type == "enter" and sig.target then
              new_stack[#new_stack + 1] = sig.target
            elseif sig.type == "exit" then
              new_stack[#new_stack] = nil
            end
          end

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

return M

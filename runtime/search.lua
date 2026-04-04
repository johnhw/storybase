-- runtime/search.lua
-- Future-state search engine (BFS-based reachability).
--
-- Implements:
--   can_reach(game_table, initial_cache, initial_stack, condition_fn, depth)
--     Returns true if any reachable state (within depth steps) satisfies
--     condition_fn(cache).

local M = {}

local DEFAULT_DEPTH = 20

-- ============================================================
-- Helpers (shared with verify.lua logic)
-- ============================================================

--- Clone a flat cache table (key → value).
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

--- Clone from a state store object (reads store._cache).
local function clone_cache(store)
  return clone_flat(store._cache or store)
end

local function hash_state(cache, stack)
  local keys = {}
  for k in pairs(cache) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = cache[k]
    if type(v) == "table" then
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

local function restore_engine(eng, cache, stack)
  for k in pairs(eng._state._cache) do eng._state._cache[k] = nil end
  for k, v in pairs(cache) do
    if type(v) == "table" then
      local copy = {}
      for i, x in ipairs(v) do copy[i] = x end
      eng._state._cache[k] = copy
    else
      eng._state._cache[k] = v
    end
  end
  eng._scene_stack = {}
  for _, s in ipairs(stack) do eng._scene_stack[#eng._scene_stack + 1] = s end
end

-- ============================================================
-- BFS can_reach
-- ============================================================

--- BFS over (cache, stack) states, returning true if condition_fn is
--- satisfied by any reachable state within depth steps.
---@param game_table    table     Compiled game table
---@param initial_cache table     Initial state cache snapshot
---@param initial_stack table     Initial scene stack (list of scene names)
---@param condition_fn  function  Predicate: condition_fn(cache) → bool
---@param depth         integer?  Max BFS depth (default 20)
---@return boolean
function M.can_reach(game_table, initial_cache, initial_stack, condition_fn, depth)
  depth = depth or DEFAULT_DEPTH

  local engine_mod = require("runtime.engine")
  local seen       = {}
  local io_sink    = { write = function() end }

  -- Check initial state
  if condition_fn(initial_cache) then return true end

  local queue = { { cache = clone_flat(initial_cache), stack = initial_stack, d = 0 } }
  local head  = 1

  while head <= #queue do
    local item = queue[head]; head = head + 1
    if item.d >= depth then goto next_item end

    local h = hash_state(item.cache, item.stack)
    if seen[h] then goto next_item end
    seen[h] = true

    local scene_name = item.stack[#item.stack]
    if not scene_name then goto next_item end

    local eng = engine_mod.new(game_table, { io_out = io_sink })
    eng:register_actors_schedules()
    restore_engine(eng, item.cache, item.stack)

    local ok, choices_or_err = pcall(function()
      local _, choices = eng:render_scene(scene_name)
      return choices
    end)
    if not ok then goto next_item end
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

        -- Build new cache snapshot
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

        -- Check condition
        if condition_fn(new_cache) then return true end

        if #new_stack > 0 then
          queue[#queue + 1] = {
            cache = new_cache,
            stack = new_stack,
            d     = item.d + 1,
          }
        end
      end
    end

    ::next_item::
  end

  return false
end

-- ============================================================
-- BFS find_path
-- ============================================================

--- BFS over (cache, stack) states, returning the sequence of choice labels
--- that leads to a state satisfying condition_fn, or nil if unreachable.
---@param game_table    table     Compiled game table
---@param initial_cache table     Initial state cache snapshot
---@param initial_stack table     Initial scene stack
---@param condition_fn  function  Predicate: condition_fn(cache) → bool
---@param depth         integer?  Max BFS depth (default 20)
---@return table?  Ordered list of {scene, choice_label, choice_index} or nil
function M.find_path(game_table, initial_cache, initial_stack, condition_fn, depth)
  depth = depth or DEFAULT_DEPTH

  local engine_mod = require("runtime.engine")
  local seen       = {}
  local io_sink    = { write = function() end }

  -- Check initial state
  if condition_fn(initial_cache) then return {} end

  -- Queue entries carry the path taken to reach each state
  local queue = { {
    cache = clone_flat(initial_cache),
    stack = initial_stack,
    d     = 0,
    path  = {},  -- list of {scene, label, index}
  } }
  local head = 1

  while head <= #queue do
    local item = queue[head]; head = head + 1
    if item.d >= depth then goto next_item end

    local h = hash_state(item.cache, item.stack)
    if seen[h] then goto next_item end
    seen[h] = true

    local scene_name = item.stack[#item.stack]
    if not scene_name then goto next_item end

    local eng = engine_mod.new(game_table, { io_out = io_sink })
    eng:register_actors_schedules()
    restore_engine(eng, item.cache, item.stack)

    local ok, choices_or_err = pcall(function()
      local _, choices = eng:render_scene(scene_name)
      return choices
    end)
    if not ok then goto next_item end
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

        -- Build extended path
        local new_path = {}
        for _, step in ipairs(item.path) do new_path[#new_path + 1] = step end
        new_path[#new_path + 1] = {
          scene  = scene_name,
          label  = ch.label,
          index  = ch.index,
        }

        if condition_fn(new_cache) then return new_path end

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

    ::next_item::
  end

  return nil
end

-- ============================================================
-- Probability search
-- ============================================================

--- Compute the probability that condition_fn holds at exactly `depth` steps
--- in the future, assuming uniform random choice at each step.
--- Returns a float in [0, 1].
---@param game_table    table     Compiled game table
---@param initial_cache table     Initial state cache snapshot
---@param initial_stack table     Initial scene stack
---@param condition_fn  function  Predicate: condition_fn(cache) → bool
---@param depth         integer   Number of steps to simulate (default 10)
---@param threshold     number?   Probability pruning threshold (default 0.001)
---@return number  probability in [0, 1]
function M.probability(game_table, initial_cache, initial_stack, condition_fn, depth, threshold)
  depth     = depth     or 10
  threshold = threshold or 0.001

  local engine_mod = require("runtime.engine")
  local io_sink    = { write = function() end }

  -- Queue entries: {cache, stack, prob, d}
  -- No cycle detection: depth limit bounds exploration; cycle detection would
  -- incorrectly deduplicate states that must be counted at different path weights.
  local queue = { { cache = clone_flat(initial_cache), stack = initial_stack, prob = 1.0, d = 0 } }
  local head  = 1
  local total_prob = 0.0

  -- Check initial state at depth 0
  if depth == 0 and condition_fn(initial_cache) then return 1.0 end

  while head <= #queue do
    local item = queue[head]; head = head + 1

    if item.prob < threshold then goto next_prob_item end

    if item.d == depth then
      -- Leaf: check condition
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
      -- No choices: treat as terminal
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
              if #new_stack > 0 then new_stack[#new_stack] = sig.target else new_stack[1] = sig.target end
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
      end
    end

    ::next_prob_item::
  end

  return math.min(1.0, total_prob)
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
    _depth     = opts.depth             or DEFAULT_DEPTH,
    _strategy  = opts.strategy          or "breadth-first",
    _threshold = opts.probability_threshold or 0.01,
    _approximate = false,
  }

  function eng:can_reach(condition)
    local _ = condition
    return false
  end

  function eng:find_path(condition)
    local _ = condition
    return nil
  end

  function eng:verify_always(condition)
    local _ = condition
    return true
  end

  function eng:find_counterexample(condition)
    local _ = condition
    return nil
  end

  function eng:probability(condition, d)
    local _ = condition; local _ = d
    return 0.0
  end

  return eng
end

return M

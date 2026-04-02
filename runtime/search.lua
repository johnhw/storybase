-- runtime/search.lua
-- Future-state search engine (BFS, DFS, best-first).
--
-- Operates on a symbolic state (copy of state cache) and applies successor
-- functions to enumerate the future-state graph.  Implements:
--   can-reach?, find-path, verify-always, find-counterexample,
--   probability, optimal-path
--
-- Key properties:
--   - Nodes identified by content hash for cycle detection
--   - Random sources branch over all outcomes with probability weights
--   - Branches below probability-threshold are pruned
--   - Coroutine-based iterator at top-level for wall-clock time budgets
--
-- Phase 5 deliverable. Not yet implemented.

local M = {}

local DEFAULT_DEPTH     = 20
local DEFAULT_THRESHOLD = 0.01

--- Create a new search engine instance.
---@param state    table  State store snapshot (for search)
---@param game     table  Compiled game table (for successor functions)
---@param opts     table? Options: depth, strategy, probability_threshold
---@return table
function M.new(state, game, opts)
  opts = opts or {}
  local eng = {
    _state     = state,
    _game      = game,
    _depth     = opts.depth             or DEFAULT_DEPTH,
    _strategy  = opts.strategy          or "breadth-first",
    _threshold = opts.probability_threshold or DEFAULT_THRESHOLD,
    _approximate = false,  -- set true when pruning has occurred
  }

  --- can-reach? condition: return true if condition is reachable within depth.
  ---@param condition function  Predicate over state
  ---@return boolean
  function eng:can_reach(condition)
    local _ = condition
    return false  -- not yet implemented
  end

  --- find-path condition: return action sequence reaching condition, or nil.
  ---@param condition function
  ---@return table?
  function eng:find_path(condition)
    local _ = condition
    return nil  -- not yet implemented
  end

  --- verify-always condition: return true if condition holds in all futures.
  ---@param condition function
  ---@return boolean
  function eng:verify_always(condition)
    local _ = condition
    return true  -- not yet implemented (optimistic stub)
  end

  --- find-counterexample condition: return failing state + path, or nil.
  ---@param condition function
  ---@return table?
  function eng:find_counterexample(condition)
    local _ = condition
    return nil  -- not yet implemented
  end

  --- probability condition depth: return probability in [0,1].
  ---@param condition function
  ---@param depth     integer
  ---@return number
  function eng:probability(condition, depth)
    local _ = condition; local _ = depth
    return 0.0  -- not yet implemented
  end

  return eng
end

return M

-- runtime/counterfactual.lua
-- Branched immutable GameState for counterfactual reasoning.
--
-- counterfactual creates a private copy of state by replaying the log
-- to a past tick and applying a sequence of transitions.  The resulting
-- GameState is immutable and garbage-collected when it leaves scope.
-- Mutations in a counterfactual never appear in live state.
--
-- Phase 6 deliverable. Not yet implemented.

local M = {}

local MAX_DEPTH = 3  -- default max-counterfactual-depth

--- Create a counterfactual GameState.
---
---@param live_state  table    Live state store instance
---@param log         table    Transaction log instance
---@param from_tick   integer  Tick to replay the log back to
---@param transitions table    List of transaction functions to apply
---@param simulate    boolean  Whether to include actor/schedule steps
---@param depth       integer  Current nesting depth
---@param max_depth   integer  Maximum allowed nesting depth
---@return table?              GameState value, or nil on depth-limit error
function M.create(live_state, log, from_tick, transitions, simulate, depth, max_depth)
  depth     = depth     or 0
  max_depth = max_depth or MAX_DEPTH

  if depth >= max_depth then
    return nil, "counterfactual nesting depth limit exceeded"
  end

  -- Not yet implemented: return a shallow copy of live state as a placeholder.
  local gs = {
    _cache    = {},
    _depth    = depth + 1,
    _simulate = simulate or false,
  }

  -- Shallow-copy current live cache
  if live_state and live_state._cache then
    for k, v in pairs(live_state._cache) do
      gs._cache[k] = v
    end
  end

  --- Read a path from this GameState.
  function gs:get(path)
    return self._cache[path]
  end

  --- Return true if the given path is instantiated in this GameState.
  function gs:path_exists(path)
    return self._cache[path] ~= nil
  end

  return gs, nil
end

return M

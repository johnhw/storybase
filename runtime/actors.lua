-- runtime/actors.lua
-- Actor perception snapshots, deferred mutation queue, and inbox management.
--
-- Before calling a behavior function the engine builds a perception snapshot —
-- a frozen filtered copy of state containing only the paths matching the
-- actor's perceives: patterns. Mutations from behavior functions are deferred
-- and applied in priority order after all actors have run.
--
-- Phase 4 deliverable. Not yet implemented.

local M = {}

--- Create a new actor registry.
---@param state table  State store instance
---@param log   table  Transaction log instance
---@return table
function M.new(state, log)
  local registry = {
    _state   = state,
    _log     = log,
    _actors  = {},   -- {name, state_path, perceives, inbox_type, behavior, priority}
    _deferred = {},  -- list of {priority, path, value, actor_name}
    _pending_msgs = {},  -- messages to be delivered next turn
  }

  --- Register an actor from the compiled game table.
  function registry:register(actor_def)
    self._actors[#self._actors + 1] = actor_def
    -- Sort by priority descending (highest priority first)
    table.sort(self._actors, function(a, b) return a.priority > b.priority end)
  end

  --- Build a perception snapshot for an actor.
  ---@param actor table  Actor definition
  ---@return table  Read-only table of {path: value}
  function registry:snapshot(actor)
    local snap = {}
    local _ = actor  -- perceives patterns not yet evaluated
    return snap
  end

  --- Run all actor behavior functions (deferred mutation mode).
  ---@param current_time table
  function registry:run_behaviors(current_time)
    local _ = current_time
    self._deferred = {}
    -- Not yet implemented
  end

  --- Apply deferred mutations in priority order.
  function registry:apply_deferred()
    -- Not yet implemented
  end

  --- Deliver pending messages into actor inboxes.
  function registry:deliver_messages()
    self._pending_msgs = {}
    -- Not yet implemented
  end

  --- Enqueue a message for delivery on the next turn.
  ---@param actor_name string
  ---@param msg        table  Typed ActorMsg value
  function registry:send(actor_name, msg)
    if not self._pending_msgs[actor_name] then
      self._pending_msgs[actor_name] = {}
    end
    self._pending_msgs[actor_name][#self._pending_msgs[actor_name] + 1] = msg
  end

  --- Clear all actor inboxes at end of turn.
  function registry:clear_inboxes()
    -- Not yet implemented
  end

  return registry
end

return M

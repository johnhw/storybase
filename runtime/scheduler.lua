-- runtime/scheduler.lua
-- Schedule queue: static and imperative scheduled events.
--
-- Static schedules are declared with `schedule name: every:/at:` in .sb files.
-- Imperative schedules are created with `schedule!` from within transaction fns.
-- Both kinds appear in the transaction log and are included in future-state search.
--
-- Phase 4 deliverable. Not yet implemented.

local M = {}

--- Create a new scheduler instance.
---@param log table  Transaction log instance
---@return table
function M.new(log)
  local sched = {
    _log      = log,
    _static   = {},  -- static schedules registered at load time
    _pending  = {},  -- active named schedules {name, trigger, fn, next_fire}
  }

  --- Register a static schedule from the compiled game table.
  ---@param name    string
  ---@param trigger table   {every?, at?, offset?}
  ---@param fn      function
  function sched:register(name, trigger, fn)
    self._static[name] = { name = name, trigger = trigger, fn = fn }
  end

  --- Fire any schedules whose trigger time <= current time.
  ---@param current_time table  Time tuple
  function sched:tick(current_time)
    local _ = current_time
    -- Not yet implemented
  end

  --- Imperatively create a named schedule from within a transaction function.
  function sched:schedule(name, opts, fn)
    local _ = name; local _ = opts; local _ = fn
    -- Not yet implemented
  end

  --- Cancel a named schedule.
  function sched:cancel(name)
    self._pending[name] = nil
  end

  return sched
end

return M

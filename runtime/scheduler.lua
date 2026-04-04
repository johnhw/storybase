-- runtime/scheduler.lua
-- Static schedule queue: fires schedule bodies based on game-time triggers.
--
-- Trigger semantics:
--   every: [axis: +N]  — fires each time the axis advances by N since last fire
--   at:    [axis: +N]  — fires once when axis reaches (initial_value + N)
--   offset: [axis: N]  — Phase 4: not yet enforced (offset within the period)
--
-- Schedules are checked after each player action (or autonomous turn step).
-- Multiple trigger axes in one schedule must ALL be satisfied simultaneously.

local M = {}

--- Create a new scheduler instance.
---@param state table  Runtime state store instance
---@param log   table  Transaction log instance
---@return table
function M.new(state, log)
  local sched = {
    _state  = state,
    _log    = log,
    _static = {},   -- { name → schedule_state }
  }

  -- ── Registration ──────────────────────────────────────────

  --- Register a static schedule from the compiled game table.
  ---@param name    string
  ---@param trigger table   {every?, at?, offset?} — lists of {axis, value} entries
  ---@param body    table   list of AST stmt nodes (schedule fn body)
  function sched:register(name, trigger, body)
    local current  = self._state:get_time()
    local next_fire = {}  -- { axis → threshold } for "every" schedules
    local fire_at  = {}   -- { axis → threshold } for "at" schedules
    local fired    = {}   -- { axis → true } marks fired "at" entries

    -- Build offset map for easy lookup
    local offset_map = {}
    for _, entry in ipairs(trigger.offset or {}) do
      offset_map[entry.axis] = entry.value
    end

    -- every: next fire = current_value + step (adjusted by offset)
    for _, entry in ipairs(trigger.every or {}) do
      local cur_val = current[entry.axis] or 0
      local offset  = offset_map[entry.axis] or 0
      -- First fire: offset from current, then step from that point
      next_fire[entry.axis] = cur_val + offset + entry.value
    end

    -- at: fire when axis reaches this absolute value (relative to start = 0)
    for _, entry in ipairs(trigger.at or {}) do
      fire_at[entry.axis] = entry.value
    end

    self._static[name] = {
      name       = name,
      trigger    = trigger,
      body       = body,
      next_fire  = next_fire,
      fire_at    = fire_at,
      fired      = fired,
    }
  end

  -- ── Tick ──────────────────────────────────────────────────

  --- Check all registered schedules against current time and fire any that
  --- are due.  Called once per turn after player action + actor phases.
  ---@param fns table  game_table.fns (needed for eval context)
  function sched:tick(fns)
    local eval    = require("runtime.eval")
    local current = self._state:get_time()

    for name, ss in pairs(self._static) do
      local should_fire = false

      -- ── every: trigger ──────────────────────────────────────
      if ss.trigger.every and #ss.trigger.every > 0 then
        local all_ready = true
        for _, entry in ipairs(ss.trigger.every) do
          local cur_val  = current[entry.axis] or 0
          local need_val = ss.next_fire[entry.axis]
          if need_val == nil or cur_val < need_val then
            all_ready = false; break
          end
        end
        if all_ready then
          should_fire = true
          -- Advance each axis threshold by the step size
          for _, entry in ipairs(ss.trigger.every) do
            local axis = entry.axis
            ss.next_fire[axis] = (ss.next_fire[axis] or (current[axis] or 0))
                                 + entry.value
          end
        end
      end

      -- ── at: trigger ─────────────────────────────────────────
      if ss.trigger.at and #ss.trigger.at > 0 then
        local all_ready  = true
        local any_unfired = false
        for _, entry in ipairs(ss.trigger.at) do
          if not ss.fired[entry.axis] then
            any_unfired = true
            if (current[entry.axis] or 0) < entry.value then
              all_ready = false; break
            end
          end
        end
        if all_ready and any_unfired then
          should_fire = true
          for _, entry in ipairs(ss.trigger.at) do
            ss.fired[entry.axis] = true
          end
        end
      end

      -- ── Fire ────────────────────────────────────────────────
      if should_fire then
        if self._log then
          self._log:append({
            kind = "schedule_fired",
            fn   = "schedule:" .. name,
            path = nil,
            old  = nil,
            new  = nil,
            time = self._state:get_time(),
          })
        end
        local ctx    = eval.new_ctx(self._state, fns, "schedule:" .. name)
        local ok, _err = pcall(eval.eval_stmts, ss.body, ctx)
        local _ = ok  -- result unused; errors are silent
      end
    end
  end

  -- ── Imperative schedule API (Phase 5) ─────────────────────

  --- Create a named schedule dynamically (schedule! mutation).
  function sched:schedule(_name, _opts, _fn)
    -- Not yet implemented (Phase 5)
  end

  --- Cancel a named schedule.
  ---@param name string
  function sched:cancel(name)
    if self._static[name] and self._log then
      self._log:append({
        kind = "cancel_schedule",
        fn   = "cancel-schedule!",
        path = nil,
        old  = nil,
        new  = nil,
        schedule_name = name,
      })
    end
    self._static[name] = nil
  end

  return sched
end

return M

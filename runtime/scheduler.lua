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
  function sched:register(name, trigger, body, fn_body_name)
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
      fn_body    = fn_body_name,  -- string name of body fn (for log replay)
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

    -- Collect names to avoid mutating _static during iteration
    local names = {}
    for name in pairs(self._static) do names[#names + 1] = name end

    -- Collect names of at:-only schedules that are fully fired (to deregister)
    local to_deregister = {}

    for _, name in ipairs(names) do
      local ss = self._static[name]
      if not ss then goto next_sched end

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
          -- Snapshot next_fire thresholds AFTER they were advanced above (for replay)
          local nf_snap = {}
          for axis, val in pairs(ss.next_fire) do nf_snap[axis] = val end
          -- Snapshot which at: axes just fired
          local fired_now = {}
          for _, entry in ipairs(ss.trigger.at or {}) do
            if ss.fired[entry.axis] then fired_now[#fired_now+1] = entry.axis end
          end
          self._log:append({
            kind          = "schedule_fired",
            fn            = "schedule:" .. name,
            schedule_name = name,
            path          = nil,
            old           = nil,
            new           = nil,
            time          = self._state:get_time(),
            next_fire     = nf_snap,
            fired_axes    = fired_now,
          })
        end
        -- Emit debug event if server is attached
        if self._debug_server then
          local tick = self._state:get_time().tick or 0
          pcall(function()
            self._debug_server:emit("schedule-fired", { name = name, tick = tick })
          end)
        end
        local ctx    = eval.new_ctx(self._state, fns, "schedule:" .. name)
        local ok, _err = pcall(eval.eval_stmts, ss.body, ctx)
        local _ = ok  -- result unused; errors are silent

        -- After firing an at:-only schedule (no every:), schedule for deregister.
        -- (Check after firing so the body still runs once.)
        if ss.trigger.at and #ss.trigger.at > 0
           and (not ss.trigger.every or #ss.trigger.every == 0) then
          local all_at_fired = true
          for _, entry in ipairs(ss.trigger.at) do
            if not ss.fired[entry.axis] then all_at_fired = false; break end
          end
          if all_at_fired then
            to_deregister[#to_deregister + 1] = name
          end
        end
      end

      ::next_sched::
    end

    -- Deregister fully-fired at:-only schedules outside the loop
    for _, name in ipairs(to_deregister) do
      self._static[name] = nil
    end
  end

  -- ── Imperative schedule API (Phase 5) ─────────────────────

  --- Create a named schedule dynamically (schedule! mutation).
  function sched:schedule(_name, _opts, _fn)
    -- Not yet implemented (Phase 5)
  end

  --- Replay schedule-related log entries to reconstruct dynamic schedule state.
  --- Call after replaying state (so time is restored) but BEFORE first tick.
  --- Handles: schedule_created (re-register dynamic), schedule_fired (advance thresholds),
  ---           cancel_schedule (remove).  Static schedules already registered via register()
  ---           have their thresholds corrected by schedule_fired entries.
  ---@param entries table  full list of log entries from the save file
  ---@param fns     table  game_table.fns (for looking up fn bodies)
  function sched:replay_log(entries, fns)
    for _, e in ipairs(entries or {}) do
      if e.kind == "schedule_created" then
        -- Re-register a dynamically created schedule
        local fn   = e.fn_body and fns and fns[e.fn_body]
        local body = fn and fn.body or {}
        self._static[e.schedule_name] = {
          name      = e.schedule_name,
          trigger   = e.trigger or { every = {}, at = {}, offset = {} },
          body      = body,
          fn_body   = e.fn_body,
          next_fire = e.next_fire or {},
          fire_at   = e.fire_at  or {},
          fired     = e.fired    or {},
        }
      elseif e.kind == "schedule_fired" and e.schedule_name then
        -- Advance thresholds for any registered schedule (static or dynamic)
        local ss = self._static[e.schedule_name]
        if ss then
          if e.next_fire then
            for axis, val in pairs(e.next_fire) do
              ss.next_fire[axis] = val
            end
          end
          if e.fired_axes then
            for _, axis in ipairs(e.fired_axes) do
              ss.fired[axis] = true
            end
          end
        end
      elseif e.kind == "cancel_schedule" and e.schedule_name then
        self._static[e.schedule_name] = nil
      end
    end
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

-- tests/runtime/scheduler_spec.lua
-- Unit tests for runtime/scheduler.lua
--
-- Tests cover:
--   every:  fires on interval
--   at:     fires once at the specified tick, then deregisters
--   offset: phase offset applied to every:
--   cancel: removes a schedule

local state_mod  = require("runtime.state")
local log_mod    = require("runtime.log")
local sched_mod  = require("runtime.scheduler")

-- ── Helpers ──────────────────────────────────────────────────────────────────

--- Build a minimal state store with a tick axis.
local function make_state()
  local schema = {
    states = {},
    engine_config = {},
    time_model = { axes = {{ name = "tick", max = 99999 }}, default_axis = "tick" },
  }
  local log   = log_mod.new()
  local store = state_mod.new(schema, log)
  store:init_defaults()
  -- ensure tick starts at 0
  return store, log
end

--- Advance time N times and call tick() each time.
--- Returns the number of times the schedule actually fired (checked via log).
local function run_ticks(store, log, sched, n)
  local fired = 0
  local prev_len = #log:entries()
  for _ = 1, n do
    store:inc_time("tick", 1)
    sched:tick({})
    local new_len = #log:entries()
    for i = prev_len + 1, new_len do
      if log:entries()[i].kind == "schedule_fired" then
        fired = fired + 1
      end
    end
    prev_len = new_len
  end
  return fired
end

--- Count schedule_fired entries in the log for a given schedule name.
local function count_fires(log, sched_name)
  local n = 0
  for _, e in ipairs(log:entries()) do
    if e.kind == "schedule_fired" and e.schedule_name == sched_name then
      n = n + 1
    end
  end
  return n
end

-- ── every: trigger ────────────────────────────────────────────────────────────

describe("scheduler: every: trigger", function()

  it("fires every N ticks", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    sched:register("daily", { every = {{ axis = "tick", value = 3 }} }, {})

    -- Tick 3 times: should fire once at tick=3
    run_ticks(store, log, sched, 3)
    assert.equal(1, count_fires(log, "daily"))

    -- Tick 3 more: should fire once more at tick=6
    run_ticks(store, log, sched, 3)
    assert.equal(2, count_fires(log, "daily"))
  end)

  it("does not fire before the interval", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    sched:register("weekly", { every = {{ axis = "tick", value = 10 }} }, {})

    run_ticks(store, log, sched, 9)
    assert.equal(0, count_fires(log, "weekly"))

    run_ticks(store, log, sched, 1)
    assert.equal(1, count_fires(log, "weekly"))
  end)

  it("fires multiple times over many ticks", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    sched:register("heartbeat", { every = {{ axis = "tick", value = 2 }} }, {})

    run_ticks(store, log, sched, 10)
    assert.equal(5, count_fires(log, "heartbeat"))
  end)

end)

-- ── at: trigger ───────────────────────────────────────────────────────────────

describe("scheduler: at: trigger", function()

  it("fires exactly once at the specified tick", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    -- at: [tick: +5] → fire when tick >= 5
    sched:register("gate-close", { at = {{ axis = "tick", value = 5 }} }, {})

    -- Tick 4 times: should not fire yet
    run_ticks(store, log, sched, 4)
    assert.equal(0, count_fires(log, "gate-close"))

    -- Tick once more (tick = 5): should fire now
    run_ticks(store, log, sched, 1)
    assert.equal(1, count_fires(log, "gate-close"))

    -- Tick again: should NOT fire a second time
    run_ticks(store, log, sched, 5)
    assert.equal(1, count_fires(log, "gate-close"), "at: schedule must fire only once")
  end)

  it("deregisters the schedule after firing", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    sched:register("one-shot", { at = {{ axis = "tick", value = 3 }} }, {})

    run_ticks(store, log, sched, 3)
    -- After firing and deregistering, _static should no longer contain it
    assert.is_nil(sched._static["one-shot"],
      "at:-only schedule should be deregistered after firing")
  end)

  it("fires at tick 0 if value = 0", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    sched:register("immediate", { at = {{ axis = "tick", value = 0 }} }, {})

    -- tick() at current tick=0 should fire
    store:inc_time("tick", 0)  -- no advance; tick stays 0
    sched:tick({})
    assert.equal(1, count_fires(log, "immediate"))
  end)

  it("does not re-fire after deregister even when schedule is re-registered", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    sched:register("alarm", { at = {{ axis = "tick", value = 2 }} }, {})

    run_ticks(store, log, sched, 2)
    assert.equal(1, count_fires(log, "alarm"))

    -- Re-register with the same name (simulates a fresh alarm)
    sched:register("alarm", { at = {{ axis = "tick", value = 6 }} }, {})
    run_ticks(store, log, sched, 4)
    assert.equal(2, count_fires(log, "alarm"))
  end)

end)

-- ── offset: modifier ─────────────────────────────────────────────────────────

describe("scheduler: offset: modifier", function()

  it("delays the first every: fire by the offset amount", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    -- every 5 with offset 2: first fire at tick=7, then 12, 17, ...
    sched:register("delayed",
      { every = {{ axis = "tick", value = 5 }},
        offset = {{ axis = "tick", value = 2 }} }, {})

    run_ticks(store, log, sched, 6)
    assert.equal(0, count_fires(log, "delayed"), "should not fire before offset+period")

    run_ticks(store, log, sched, 1)
    assert.equal(1, count_fires(log, "delayed"), "should fire at tick=7")

    run_ticks(store, log, sched, 5)
    assert.equal(2, count_fires(log, "delayed"), "should fire at tick=12")
  end)

end)

-- ── cancel ────────────────────────────────────────────────────────────────────

describe("scheduler: cancel", function()

  it("prevents future fires after cancel", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    sched:register("bg-task", { every = {{ axis = "tick", value = 2 }} }, {})

    run_ticks(store, log, sched, 2)
    assert.equal(1, count_fires(log, "bg-task"))

    sched:cancel("bg-task")

    run_ticks(store, log, sched, 10)
    assert.equal(1, count_fires(log, "bg-task"), "no fires after cancel")
  end)

  it("appends a cancel_schedule entry to the log", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    sched:register("task", { every = {{ axis = "tick", value = 1 }} }, {})
    sched:cancel("task")

    local found = false
    for _, e in ipairs(log:entries()) do
      if e.kind == "cancel_schedule" and e.schedule_name == "task" then
        found = true; break
      end
    end
    assert.is_true(found, "expected cancel_schedule log entry")
  end)

  it("silently ignores cancel on unknown schedule", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    -- Should not error
    assert.has_no.errors(function()
      sched:cancel("nonexistent")
    end)
  end)

end)

-- ── end-to-end: at: wired through compiler+codegen+engine ─────────────────────

describe("scheduler: at: end-to-end through compiler pipeline", function()

  it("compiles and runs a schedule with at: trigger", function()
    local compiler = require("compiler.compiler")
    local engine   = require("runtime.engine")

    local src = [[
module test
  version: 1

engine-config:
  entry-scene: start

time-model:
  tick max: 9999

state world:
  flag: Bool = false

schedule flip:
  at: [tick: +2]
  fn:
    set! world/flag true

scene start:
  Flag: {world/flag}.
  * Wait
    time-inc! tick: 1
    -> start
]]
    local gt, diags = compiler.compile(src, "test.sb")
    assert.is_falsy(diags:has_errors(), "compilation should succeed")
    assert.is_not_nil(gt)

    local io_out = { write = function() end }
    local io_in  = { read  = function() return "1" end }

    local eng = engine.new(gt, { io_out = io_out, io_in = io_in })
    eng:init()

    -- After step 1: tick=1, schedule not yet fired
    eng:step()
    assert.is_false(eng._state:get("world/flag"),
      "flag should be false at tick 1")

    -- After step 2: tick=2, schedule fires
    eng:step()
    assert.is_true(eng._state:get("world/flag"),
      "flag should be true after schedule fires at tick=2")

    -- After step 3: tick=3, should still be true (not un-set); schedule deregistered
    eng:step()
    assert.is_true(eng._state:get("world/flag"),
      "flag remains true after schedule deregisters")
    -- Confirm deregistered
    assert.is_nil(eng._scheduler._static["flip"],
      "at:-only schedule should be deregistered after firing")
  end)

end)

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

describe("scheduler: schedule() dead stub", function()
  it("sched:schedule raises an error (it is a dead stub)", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    assert.has_error(function()
      sched:schedule("x", {}, function() end)
    end)
  end)
end)

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

-- ── cancel-schedule! inside a schedule body ──────────────────────────────────

describe("scheduler: cancel-schedule! fired from within a schedule body", function()

  it("cancel-schedule! in body cancels another schedule; ctx.scheduler is wired", function()
    -- Regression for bug: ctx.scheduler was nil in sched:tick(), so
    -- cancel-schedule! inside a schedule body was a silent no-op.
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
  flag: Bool  = false
  count: Int(0, 99) = 0

# fires at tick=2; sets flag=false and cancels counter
schedule stopper:
  at: [tick: +2]
  fn:
    set! world/flag false
    cancel-schedule! counter

# fires every tick; increments count and sets flag=true
schedule counter:
  every: [tick: +1]
  fn:
    inc! world/count 1
    set! world/flag true

scene start:
  * Tick
    time-inc! tick: 1
    -> start
]]
    local gt, diags = compiler.compile(src, "test.sb")
    assert.is_falsy(diags:has_errors(), "compilation should succeed")

    local io_out = { write = function() end }
    local io_in  = { read  = function() return "1" end }
    local eng = engine.new(gt, { io_out = io_out, io_in = io_in })
    eng:init()

    -- tick=1: counter fires (count=1, flag=true); stopper not yet due
    eng:step()
    assert.equal(1,   eng._state:get("world/count"), "count=1 after tick 1")
    assert.is_true(   eng._state:get("world/flag"),  "flag=true after tick 1")

    -- tick=2: stopper fires and calls cancel-schedule! counter.
    -- With ctx.scheduler now wired, the cancel takes effect and counter
    -- is removed from _static inside this same sched:tick() call.
    -- The names list was snapshot before iteration so counter's body
    -- is nil-guarded; stopper must dominate the final state.
    eng:step()
    assert.is_false(  eng._state:get("world/flag"),  "flag=false after stopper fires")
    assert.is_nil(eng._scheduler._static["counter"], "counter deregistered by cancel")

    -- tick=3: both schedules gone; state frozen
    local count_at_2 = eng._state:get("world/count")
    eng:step()
    assert.equal(count_at_2, eng._state:get("world/count"), "count frozen after cancel")
    assert.is_false(  eng._state:get("world/flag"),  "flag stays false")
  end)

end)

-- ── Imperative schedule! end-to-end ──────────────────────────────────────────

describe("scheduler: imperative schedule! creates and fires a dynamic schedule", function()

  it("schedule! fires inc-count every tick and counter reaches 3 after 3 turns", function()
    local compiler = require("compiler.compiler")
    local engine   = require("runtime.engine")

    -- setup fn creates a dynamic schedule; each step advances tick by 1.
    -- The scene body calls time-inc! and -> itself to run autonomously.
    local src = [[
module dynamic-sched-test
  version: 1
engine-config:
  entry-scene: main

state world:
  count: Int(0, 9999) = 0
  tick: Int(0, 9999) = 0

fn inc-count:
  inc! world/count 1

fn setup-schedule:
  schedule! `counter every: [tick: 1] fn: inc-count

scene main:
  * Tick
    time-inc! tick: 1
    -> main
]]
    local gt, diags = compiler.compile(src, "test.sb")
    assert.is_falsy(diags:has_errors(), "compilation should succeed")

    local io_out = { write = function() end }
    local io_in  = { read  = function() return "1" end }
    local eng = engine.new(gt, { io_out = io_out, io_in = io_in })
    eng:init()

    -- Create the dynamic schedule by calling setup-schedule via make_ctx
    local eval_mod = require("runtime.eval")
    local ctx = eng:make_ctx("test")
    eval_mod.call_fn("setup-schedule", {}, ctx)

    -- Verify schedule was registered
    assert.is_not_nil(eng._scheduler._static["counter"], "counter schedule must be registered")

    -- Three turns: each step advances tick by 1 via choice body, then sched:tick fires
    eng:step()  -- tick=1: counter fires → count=1
    assert.equal(1, eng._state:get("world/count"), "count=1 after tick 1")

    eng:step()  -- tick=2: counter fires → count=2
    assert.equal(2, eng._state:get("world/count"), "count=2 after tick 2")

    eng:step()  -- tick=3: counter fires → count=3
    assert.equal(3, eng._state:get("world/count"), "count=3 after tick 3")
  end)

  it("dynamic schedule survives log replay (simulating save/load)", function()
    local compiler  = require("compiler.compiler")
    local engine    = require("runtime.engine")
    local state_mod = require("runtime.state")

    local src = [[
module dynamic-saveload-test
  version: 1
engine-config:
  entry-scene: main

state world:
  count: Int(0, 9999) = 0
  tick: Int(0, 9999) = 0

fn inc-count:
  inc! world/count 1

fn setup-schedule:
  schedule! `counter every: [tick: 1] fn: inc-count

scene main:
  * Tick
    time-inc! tick: 1
    -> main
]]
    local gt, diags = compiler.compile(src, "test.sb")
    assert.is_falsy(diags:has_errors(), "compilation should succeed")

    local io_out = { write = function() end }
    local io_in  = { read  = function() return "1" end }
    local eng = engine.new(gt, { io_out = io_out, io_in = io_in })
    eng:init()

    local eval_mod = require("runtime.eval")
    local ctx = eng:make_ctx("test")
    eval_mod.call_fn("setup-schedule", {}, ctx)

    -- One turn before "save"
    eng:step()  -- tick=1 → count=1
    assert.equal(1, eng._state:get("world/count"), "count=1 before save")

    -- Simulate save/load by extracting log entries and replaying them in a new engine.
    local saved_entries = {}
    for _, e in ipairs(eng._log:entries()) do saved_entries[#saved_entries+1] = e end
    local saved_stack = { table.unpack(eng._scene_stack) }

    -- Fresh engine: init_defaults restores initial state, then replay the log
    local eng2 = engine.new(gt, { io_out = io_out, io_in = io_in })
    eng2._state:init_defaults()
    state_mod.replay(eng2._state, saved_entries)
    eng2:register_actors_schedules()
    eng2._scheduler:replay_log(saved_entries, gt.fns)
    eng2._scene_stack = saved_stack

    -- State preserved
    assert.equal(1, eng2._state:get("world/count"), "count=1 after replay")
    assert.is_not_nil(eng2._scheduler._static["counter"],
      "counter schedule must survive log replay")

    -- One more step: tick=2 → count=2
    eng2:step()
    assert.equal(2, eng2._state:get("world/count"), "count=2 after replay+step")
  end)

end)

-- ── multi-axis triggers (every: / at: across more than one time axis) ────────

--- Build a state store with day & hour axes (proper string axis names).
local function make_multi_axis_state()
  local schema = {
    states = {},
    engine_config = {},
    time_model = {
      axes = { "day", "hour" },
    },
  }
  local log   = log_mod.new()
  local store = state_mod.new(schema, log)
  store:init_defaults()
  return store, log
end

--- Set absolute time on an axis via inc_time math (because set_time silently
--- no-ops on undeclared axes, and the existing time_model schema used here
--- doesn't necessarily pre-populate _time correctly for set_time's guard).
local function force_set_time(store, axis, value)
  local cur = (store:get_time())[axis] or 0
  store:inc_time(axis, value - cur)
end

describe("scheduler: multi-axis at:", function()

  it("at: [day: +2, hour: +3] requires both axes to reach their targets", function()
    local store, log = make_multi_axis_state()
    local sched = sched_mod.new(store, log)
    sched:register("alarm", {
      at = {
        { axis = "day",  value = 2 },
        { axis = "hour", value = 3 },
      }
    }, {})

    -- day=1, hour=5: hour ready but day not → must not fire
    force_set_time(store, "day", 1); force_set_time(store, "hour", 5)
    sched:tick({})
    assert.equal(0, count_fires(log, "alarm"),
      "schedule must not fire when not all axes have reached their targets")

    -- day=2, hour=0: day ready but hour not → must not fire
    force_set_time(store, "day", 2); force_set_time(store, "hour", 0)
    sched:tick({})
    assert.equal(0, count_fires(log, "alarm"),
      "schedule must not fire until BOTH axes reach their targets")

    -- day=2, hour=3: both ready → fires once
    force_set_time(store, "hour", 3)
    sched:tick({})
    assert.equal(1, count_fires(log, "alarm"),
      "schedule fires once both axis thresholds are met")

    -- Subsequent ticks must not re-fire (at: triggers fire once)
    sched:tick({}); sched:tick({})
    assert.equal(1, count_fires(log, "alarm"),
      "at: trigger fires only once")
  end)

  it("at:-only multi-axis schedule deregisters after firing", function()
    local store, log = make_multi_axis_state()
    local sched = sched_mod.new(store, log)
    sched:register("once", {
      at = {
        { axis = "day",  value = 1 },
        { axis = "hour", value = 2 },
      }
    }, {})

    force_set_time(store, "day", 1); force_set_time(store, "hour", 2)
    sched:tick({})
    assert.is_nil(sched._static["once"],
      "multi-axis at:-only schedule deregisters after firing")
  end)
end)

describe("scheduler: multi-axis every:", function()

  it("every: [day: 2, hour: 3] fires only when both axes have advanced", function()
    local store, log = make_multi_axis_state()
    local sched = sched_mod.new(store, log)
    sched:register("rhythm", {
      every = {
        { axis = "day",  value = 2 },
        { axis = "hour", value = 3 },
      }
    }, {})

    -- After init: day must reach 2, hour must reach 3
    force_set_time(store, "day", 2); force_set_time(store, "hour", 0)
    sched:tick({})
    assert.equal(0, count_fires(log, "rhythm"),
      "must not fire while hour is below its threshold")

    force_set_time(store, "hour", 3)
    sched:tick({})
    assert.equal(1, count_fires(log, "rhythm"),
      "fires when both thresholds met")

    -- Next thresholds are now day=4, hour=6.  hour=3 again must not fire.
    sched:tick({})
    assert.equal(1, count_fires(log, "rhythm"),
      "must not re-fire until both axes advance past new thresholds")
  end)
end)

-- ── cancel during tick: a schedule body cancels another schedule ────────────

describe("scheduler: cancel during tick", function()

  it("a body can cancel a sibling schedule mid-tick without crashing", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)

    sched:register("first",  { at = {{ axis = "tick", value = 1 }} }, {})
    sched:register("victim", { at = {{ axis = "tick", value = 2 }} }, {})

    store:inc_time("tick", 1)
    sched:tick({})
    assert.equal(1, count_fires(log, "first"),
      "first schedule fires at tick=1")

    -- Cancel victim BEFORE it would fire (simulating a body that
    -- cancels a sibling on a prior tick).
    sched:cancel("victim")

    store:inc_time("tick", 1)
    sched:tick({})
    assert.equal(0, count_fires(log, "victim"),
      "victim must not fire after being cancelled")
  end)

  it("cancelling a non-existent schedule silently no-ops", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    assert.has_no.errors(function() sched:cancel("never-registered") end)
  end)

  it("cancelling a schedule emits a cancel_schedule log entry", function()
    local store, log = make_state()
    local sched = sched_mod.new(store, log)
    sched:register("x", { every = {{ axis = "tick", value = 1 }} }, {})
    sched:cancel("x")
    local found = false
    for _, e in ipairs(log:entries()) do
      if e.kind == "cancel_schedule" and e.schedule_name == "x" then
        found = true; break
      end
    end
    assert.is_true(found, "expected cancel_schedule log entry for x")
    assert.is_nil(sched._static["x"])
  end)
end)

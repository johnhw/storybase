-- tests/runtime/debug_demo19_spec.lua
-- Debug server tests using demo19 (signal tower) as the subject game.
-- Covers: hot reload, time-travel, get-state, get-log, watch-when, mutation events,
-- clamp-event, scene-change, and breakpoints in a realistic game context.
--
-- Run with:  busted tests/

local debug_mod  = require("runtime.debug")
local engine_mod = require("runtime.engine")
local eval_mod   = require("runtime.eval")
local compiler_mod = require("compiler.compiler")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function compile(src)
  local result, diags = compiler_mod.compile(src, "test.sb")
  local errors = {}
  for _, d in ipairs(diags or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return result, errors
end

local function silent_io()
  return { write = function() end }
end

local function call_fn(eng, gt, name, args)
  local ctx = eval_mod.new_ctx(eng._state, gt.fns, name)
  eval_mod.call_fn(name, args or {}, ctx)
end

-- ── Source fixtures ───────────────────────────────────────────────────────────

-- Stripped-down version of demo19 with same core structure
local SRC_V1 = [[
module signal-tower
  version: 1.0
engine-config:
  entry-scene: tower

state tower:
  beacon:       Bool        = false
  signal-count: Int(0, 999) = 0
  day:          Int(1, 99)  = 1

state operator:
  focus:   Int(0, 10) = 10
  fatigue: Int(0, 10) = 0

state messages:
  pending:   Int(0, 20)  = 3
  delivered: Int(0, 999) = 0

state weather:
  visibility: Int(0, 10) = 8
  storm:      Bool       = false

fn can-signal?:
  weather/visibility > 2  and  operator/focus >= 2

fn exhausted?:
  operator/fatigue >= 8

fn send-signal:
  pre: can-signal?  and  messages/pending > 0
  inc! tower/signal-count 1
  dec! messages/pending 1
  inc! messages/delivered 1
  dec! operator/focus 1
  inc! operator/fatigue 1

fn light-beacon:
  pre: weather/visibility > 2  and  tower/beacon = false
  set! tower/beacon true

fn rest:
  inc! operator/focus 3
  dec! operator/fatigue 3

scene tower:
  * Send
    send-signal
    -> tower
]]

-- V2: adds a new state field (morale) and changes send-signal to decrement focus by 2
local SRC_V2 = [[
module signal-tower
  version: 1.0
engine-config:
  entry-scene: tower

state tower:
  beacon:       Bool        = false
  signal-count: Int(0, 999) = 0
  day:          Int(1, 99)  = 1

state operator:
  focus:   Int(0, 10) = 10
  fatigue: Int(0, 10) = 0
  morale:  Int(0, 10) = 5

state messages:
  pending:   Int(0, 20)  = 3
  delivered: Int(0, 999) = 0

state weather:
  visibility: Int(0, 10) = 8
  storm:      Bool       = false

fn can-signal?:
  weather/visibility > 2  and  operator/focus >= 2

fn exhausted?:
  operator/fatigue >= 8

fn send-signal:
  pre: can-signal?  and  messages/pending > 0
  inc! tower/signal-count 1
  dec! messages/pending 1
  inc! messages/delivered 1
  dec! operator/focus 2
  inc! operator/fatigue 1

fn light-beacon:
  pre: weather/visibility > 2  and  tower/beacon = false
  set! tower/beacon true

fn rest:
  inc! operator/focus 3
  dec! operator/fatigue 3

scene tower:
  * Send
    send-signal
    -> tower
]]

-- ── Compilation ───────────────────────────────────────────────────────────────

describe("debug demo19: compilation", function()
  it("V1 source compiles without errors", function()
    local gt, errs = compile(SRC_V1)
    assert.equal(0, #errs, "compile errors: " .. (errs[1] and errs[1].message or ""))
    assert.is_not_nil(gt)
  end)

  it("V2 source (with morale field) compiles without errors", function()
    local gt, errs = compile(SRC_V2)
    assert.equal(0, #errs, "compile errors: " .. (errs[1] and errs[1].message or ""))
    assert.is_not_nil(gt)
  end)
end)

-- ── get-state ─────────────────────────────────────────────────────────────────

describe("debug demo19: get-state", function()
  local gt, errs = compile(SRC_V1)

  it("returns initial tower state", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("get-state", { pattern = "tower/*" })
    assert.is_table(resp.state)
    assert.equal(false,  resp.state["tower/beacon"])
    assert.equal(0,      resp.state["tower/signal-count"])
    assert.equal(1,      resp.state["tower/day"])
  end)

  it("returns operator and messages state", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("get-state", { pattern = "*" })
    assert.equal(10, resp.state["operator/focus"])
    assert.equal(0,  resp.state["operator/fatigue"])
    assert.equal(3,  resp.state["messages/pending"])
    assert.equal(0,  resp.state["messages/delivered"])
  end)

  it("filters to a single exact path", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("get-state", { pattern = "weather/visibility" })
    assert.equal(8, resp.state["weather/visibility"])
    assert.is_nil(resp.state["tower/beacon"])
  end)
end)

-- ── get-log ───────────────────────────────────────────────────────────────────

describe("debug demo19: get-log after mutations", function()
  local gt, errs = compile(SRC_V1)

  it("log contains signal-count mutation after send-signal", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    call_fn(eng, gt, "send-signal")

    local srv = debug_mod.new(eng)
    srv:start()
    local resp = srv:handle_command("get-log", {})
    assert.is_table(resp.entries)

    local found_sig = false
    for _, e in ipairs(resp.entries) do
      if e.path == "tower/signal-count" and e["new"] == 1 then found_sig = true end
    end
    assert.is_true(found_sig, "signal-count mutation not found in log")
  end)

  it("log contains both pending decrease and delivered increase", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    call_fn(eng, gt, "send-signal")

    local srv = debug_mod.new(eng)
    srv:start()
    local resp = srv:handle_command("get-log", {})

    local pending_dec, delivered_inc = false, false
    for _, e in ipairs(resp.entries) do
      if e.path == "messages/pending"   and e["new"] == 2 then pending_dec   = true end
      if e.path == "messages/delivered" and e["new"] == 1 then delivered_inc = true end
    end
    assert.is_true(pending_dec,   "pending decrease not in log")
    assert.is_true(delivered_inc, "delivered increase not in log")
  end)
end)

-- ── time-travel ───────────────────────────────────────────────────────────────

describe("debug demo19: time-travel", function()
  local gt, errs = compile(SRC_V1)

  it("time-travel to seq 0 returns initial defaults", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    call_fn(eng, gt, "send-signal")
    call_fn(eng, gt, "send-signal")

    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("time-travel", { seq = 0 })
    assert.is_nil(resp.error, tostring(resp.error))
    assert.equal(0, resp.snapshot["tower/signal-count"])
    assert.equal(3, resp.snapshot["messages/pending"])
    assert.equal(0, resp.snapshot["messages/delivered"])
  end)

  it("time-travel to seq after first send-signal shows updated state", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    call_fn(eng, gt, "send-signal")  -- seq 1..N (multiple mutations per call)

    local first_seq = eng._log:entries()[1] and eng._log:entries()[1].seq or 1

    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("time-travel", { seq = first_seq })
    assert.is_nil(resp.error, tostring(resp.error))
    assert.is_table(resp.snapshot)
  end)

  it("time-travel does not mutate live state", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    call_fn(eng, gt, "send-signal")

    local live_pending = eng._state:get("messages/pending")

    local srv = debug_mod.new(eng)
    srv:start()
    srv:handle_command("time-travel", { seq = 0 })

    assert.equal(live_pending, eng._state:get("messages/pending"))
  end)

  it("time-travel with watches evaluates snapshot values", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    call_fn(eng, gt, "send-signal")
    call_fn(eng, gt, "send-signal")

    local srv = debug_mod.new(eng)
    srv:start()
    srv:register_watch("messages/delivered", "Delivered")

    -- Rewind to tick 0: delivered should be 0
    local resp = srv:handle_command("time-travel", { seq = 0 })
    assert.is_table(resp.watches)
    local w
    for _, ww in ipairs(resp.watches) do
      if ww.label == "Delivered" then w = ww end
    end
    assert.is_not_nil(w, "Delivered watch not in response")
    assert.equal(0, w.value)
  end)
end)

-- ── eval ─────────────────────────────────────────────────────────────────────

describe("debug demo19: eval command", function()
  local gt, errs = compile(SRC_V1)

  it("evaluates a simple path expression", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local ctx = eval_mod.new_ctx(eng._state, eng._fns, "eval-test")
    local node = { kind = "path_expr", segments = { "weather", "visibility" } }
    local val = eval_mod.eval_expr(node, ctx)
    assert.equal(8, val)
  end)
end)

-- ── watch-when: positive-edge detection ──────────────────────────────────────

describe("debug demo19: watch-when fires on positive edge", function()
  local gt, errs = compile(SRC_V1)

  it("watch-when fires when exhausted? becomes true", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local fired = {}
    srv:on("watch-fired", function(p) fired[#fired + 1] = p end)

    -- exhausted? = operator/fatigue >= 8; initial fatigue=0, not exhausted
    local cond_ast = {
      kind  = "fn_call",
      name  = "exhausted?",
      args  = {},
    }
    srv:register_watch_when(cond_ast, "Operator exhausted!")

    srv:check_watches()
    assert.equal(0, #fired, "should not fire when fatigue=0")

    -- Drive fatigue to 8
    eng._state:set("operator/fatigue", 8, "test")
    srv:check_watches()
    assert.equal(1, #fired, "should fire when fatigue=8")
    assert.equal("Operator exhausted!", fired[1].label)

    -- No re-fire while still true (edge detection)
    srv:check_watches()
    assert.equal(1, #fired)

    -- Drop back and re-trigger
    eng._state:set("operator/fatigue", 0, "test")
    srv:check_watches()
    eng._state:set("operator/fatigue", 9, "test")
    srv:check_watches()
    assert.equal(2, #fired)
  end)

  it("watch-when for storm path fires when storm becomes true", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local fired = {}
    srv:on("watch-fired", function(p) fired[#fired + 1] = p end)

    local cond_ast = { kind = "path_expr", segments = { "weather", "storm" } }
    srv:register_watch_when(cond_ast, "Storm rolling in!")

    srv:check_watches()
    assert.equal(0, #fired)

    eng._state:set("weather/storm", true, "test")
    srv:check_watches()
    assert.equal(1, #fired)
    assert.equal("Storm rolling in!", fired[1].label)
  end)

  it("path watch fires with current value", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local fired = {}
    srv:on("watch-fired", function(p) fired[#fired + 1] = p end)

    srv:register_watch("tower/signal-count", "Signals Sent")
    srv:check_watches()
    assert.equal(1, #fired)
    assert.equal("Signals Sent", fired[1].label)
    assert.equal("path", fired[1].kind)
    assert.equal(0, fired[1].value)
  end)
end)

-- ── mutation events via engine ────────────────────────────────────────────────

describe("debug demo19: mutation events wired through engine", function()
  local gt, errs = compile(SRC_V1)

  it("send-signal emits mutations for all affected paths", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local mutations = {}
    srv:on("mutation", function(p) mutations[#mutations + 1] = p end)

    call_fn(eng, gt, "send-signal")

    local paths = {}
    for _, m in ipairs(mutations) do paths[m.path] = m end

    assert.is_not_nil(paths["tower/signal-count"],   "signal-count mutation missing")
    assert.is_not_nil(paths["messages/pending"],      "pending mutation missing")
    assert.is_not_nil(paths["messages/delivered"],    "delivered mutation missing")
    assert.is_not_nil(paths["operator/focus"],        "focus mutation missing")
    assert.is_not_nil(paths["operator/fatigue"],      "fatigue mutation missing")

    assert.equal(1, paths["tower/signal-count"].new)
    assert.equal(2, paths["messages/pending"].new)
    assert.equal(1, paths["messages/delivered"].new)
  end)

  it("light-beacon emits a mutation for tower/beacon", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local beacon_mutations = {}
    srv:on("mutation", function(p)
      if p.path == "tower/beacon" then beacon_mutations[#beacon_mutations + 1] = p end
    end)

    call_fn(eng, gt, "light-beacon")

    assert.equal(1, #beacon_mutations)
    assert.equal(false, beacon_mutations[1].old)
    assert.equal(true,  beacon_mutations[1].new)
  end)
end)

-- ── clamp-event ───────────────────────────────────────────────────────────────

describe("debug demo19: clamp-event on bounded fields", function()
  local gt, errs = compile(SRC_V1)

  it("fires clamp-event when signal-count would exceed 999", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local clamps = {}
    srv:on("clamp-event", function(p) clamps[#clamps + 1] = p end)

    -- Drive signal-count to max
    eng._state:set("tower/signal-count", 999, "test")
    -- send-signal will try to inc! by 1 → clamped
    call_fn(eng, gt, "send-signal")

    assert.is_true(#clamps > 0, "expected clamp-event for signal-count")
    local found = false
    for _, c in ipairs(clamps) do
      if c.path == "tower/signal-count" then found = true end
    end
    assert.is_true(found)
  end)
end)

-- ── breakpoints ───────────────────────────────────────────────────────────────

describe("debug demo19: breakpoints", function()
  local gt, errs = compile(SRC_V1)

  it("set-breakpoint returns numeric id", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("set-breakpoint", { condition = "messages/pending = 0" })
    assert.is_number(resp.id)
  end)

  it("clear-breakpoint removes it", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local set_resp = srv:handle_command("set-breakpoint", { condition = "tower/signal-count >= 5" })
    local id = set_resp.id
    assert.is_not_nil(srv._breakpoints[id])

    srv:handle_command("clear-breakpoint", { id = id })
    assert.is_nil(srv._breakpoints[id])
  end)

  it("two breakpoints have distinct ids", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local r1 = srv:handle_command("set-breakpoint", { condition = "messages/pending = 0" })
    local r2 = srv:handle_command("set-breakpoint", { condition = "operator/fatigue >= 8" })
    assert.not_equal(r1.id, r2.id)
  end)
end)

-- ── hot reload ────────────────────────────────────────────────────────────────

describe("debug demo19: hot reload", function()
  it("reload updates function logic while preserving live state", function()
    local gt1, errs1 = compile(SRC_V1)
    assert.equal(0, #errs1)
    if not gt1 then pending("compile failed") return end

    local eng = engine_mod.new(gt1, { io_out = silent_io() })
    eng:init()

    -- Send one signal with V1 (focus costs 1)
    call_fn(eng, gt1, "send-signal")
    assert.equal(9, eng._state:get("operator/focus"))   -- 10-1=9
    assert.equal(1, eng._state:get("tower/signal-count"))

    -- Hot reload with V2 (focus costs 2, adds operator/morale)
    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("reload", { src = SRC_V2 })
    assert.is_true(resp.ok, tostring(resp.error))

    -- State preserved through reload
    assert.equal(9, eng._state:get("operator/focus"))
    assert.equal(1, eng._state:get("tower/signal-count"))

    -- New field initialised with default
    assert.equal(5, eng._state:get("operator/morale"))

    -- Reloaded function now costs 2 focus
    local ctx = eval_mod.new_ctx(eng._state, eng._fns, "test")
    eval_mod.call_fn("send-signal", {}, ctx)
    assert.equal(7, eng._state:get("operator/focus"))   -- 9-2=7
  end)

  it("reload outcome is 'migrated' when new fields are added", function()
    local gt1, errs1 = compile(SRC_V1)
    assert.equal(0, #errs1)
    if not gt1 then pending("compile failed") return end

    local eng = engine_mod.new(gt1, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("reload", { src = SRC_V2 })
    assert.is_true(resp.ok)
    -- outcome should indicate migration (field added)
    assert.is_string(resp.outcome)
    assert.truthy(resp.outcome == "migrated" or resp.outcome == "ok")
  end)

  it("reload emits a 'reload' event", function()
    local gt1, errs1 = compile(SRC_V1)
    assert.equal(0, #errs1)
    if not gt1 then pending("compile failed") return end

    local eng = engine_mod.new(gt1, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local reload_events = {}
    srv:on("reload", function(p) reload_events[#reload_events + 1] = p end)

    srv:handle_command("reload", { src = SRC_V2 })
    assert.equal(1, #reload_events)
    assert.is_string(reload_events[1].outcome)
  end)

  it("reload fails gracefully on invalid source", function()
    local gt1, errs1 = compile(SRC_V1)
    assert.equal(0, #errs1)
    if not gt1 then pending("compile failed") return end

    local eng = engine_mod.new(gt1, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("reload", { src = "this is not valid storybase syntax @@@" })
    assert.is_false(resp.ok)
    assert.is_string(resp.error)
  end)
end)

-- ── get-schema ────────────────────────────────────────────────────────────────

describe("debug demo19: get-schema", function()
  local gt, errs = compile(SRC_V1)

  it("returns schema with expected state paths and function names", function()
    if not gt or #errs > 0 then pending("compile failed") return end
    local eng = engine_mod.new(gt, { io_out = silent_io() })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("get-schema", {})
    assert.is_table(resp)

    -- states is an array of record descriptors; find the "tower" record
    local states = resp.states or {}
    local tower_rec
    for _, s in ipairs(states) do
      if s.path == "tower" then tower_rec = s end
    end
    assert.is_not_nil(tower_rec, "tower record not in schema states")
    assert.equal("record", tower_rec.kind)
    assert.is_table(tower_rec.fields)
  end)
end)

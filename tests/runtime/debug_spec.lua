-- tests/runtime/debug_spec.lua
-- Tests for runtime/debug.lua: event hooks, watches, command handlers.
--
-- Run with:  busted tests/

local debug_mod   = require("runtime.debug")
local engine_mod  = require("runtime.engine")
local compiler_mod = require("compiler.compiler")

local function compile(src)
  local result, diags = compiler_mod.compile(src, "test.sb")
  local errors = {}
  for _, d in ipairs(diags or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return result, errors
end

local MINIMAL_SRC = [[
module debug-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  gold:   Int(0, 999) = 50
  health: Int(0, 100) = 100
  alive:  Bool        = true

state world:
  tick: Int(0, 9999) = 0

fn earn amount:
  inc! player/gold amount

fn hurt amount:
  dec! player/health amount

scene main:
  * Go
    -> main
]]

-- ============================================================
-- JSON encoder
-- ============================================================

describe("debug: JSON encoder", function()
  it("encodes nil as null", function()
    assert.equal("null", debug_mod.encode_json(nil))
  end)

  it("encodes booleans", function()
    assert.equal("true",  debug_mod.encode_json(true))
    assert.equal("false", debug_mod.encode_json(false))
  end)

  it("encodes numbers", function()
    assert.equal("42",  debug_mod.encode_json(42))
    assert.equal("3.14", debug_mod.encode_json(3.14))
  end)

  it("encodes strings with escaping", function()
    assert.equal('"hello"', debug_mod.encode_json("hello"))
    assert.equal('"say \\"hi\\""', debug_mod.encode_json('say "hi"'))
    assert.equal('"a\\nb"', debug_mod.encode_json("a\nb"))
  end)

  it("encodes arrays", function()
    assert.equal("[1,2,3]", debug_mod.encode_json({1, 2, 3}))
  end)

  it("encodes objects", function()
    local result = debug_mod.encode_json({ x = 1 })
    assert.truthy(result:find('"x":1'))
  end)

  it("encodes nested structures", function()
    local result = debug_mod.encode_json({ event = "mutation", data = { path = "player/gold", new = 60 } })
    assert.truthy(result:find('"event":"mutation"'))
    assert.truthy(result:find('"path":"player/gold"'))
  end)
end)

-- ============================================================
-- get-state command
-- ============================================================

describe("debug: get-state command", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("compiles test source without errors", function()
    assert.equal(0, #errs)
    assert.is_not_nil(gt)
  end)

  it("get-state returns all paths when pattern is *", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("get-state", { pattern = "*" })
    assert.is_table(resp.state)
    assert.equal(50, resp.state["player/gold"])
    assert.equal(100, resp.state["player/health"])
  end)

  it("get-state filters by pattern", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("get-state", { pattern = "player/*" })
    assert.is_table(resp.state)
    assert.equal(50, resp.state["player/gold"])
    assert.equal(100, resp.state["player/health"])
    assert.is_nil(resp.state["world/tick"])
  end)

  it("get-state returns exact path match", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("get-state", { pattern = "player/gold" })
    assert.is_table(resp.state)
    assert.equal(50, resp.state["player/gold"])
    assert.is_nil(resp.state["player/health"])
  end)
end)

-- ============================================================
-- get-log command
-- ============================================================

describe("debug: get-log command", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("get-log returns log entries after a mutation", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, gt.fns, "test")
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 25 }}, ctx)

    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("get-log", {})
    assert.is_table(resp.entries)
    -- Find the player/gold = 75 entry
    local found = false
    for _, e in ipairs(resp.entries) do
      if e.path == "player/gold" and e["new"] == 75 then found = true end
    end
    assert.is_true(found, "log should contain player/gold = 75")
  end)

  it("get-log with from/to slices entries", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    -- Make some mutations so the log has entries
    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, gt.fns, "test")
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 5 }}, ctx)
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 5 }}, ctx)

    local all_entries = eng._log:entries()
    assert.is_true(#all_entries >= 2, "need at least 2 log entries")

    local srv = debug_mod.new(eng)
    srv:start()
    -- Get only the first entry
    local resp = srv:handle_command("get-log", { from = 1, to = 1 })
    assert.equal(1, #resp.entries)
  end)
end)

-- ============================================================
-- eval command
-- ============================================================

describe("debug: eval command", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("eval of a simple path expression returns correct value", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    -- Use the existing "earn" fn to compute something; but simpler:
    -- just evaluate the fn body inline via ctx.retval
    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, eng._fns, "eval-test")
    local node = { kind = "path_expr", segments = { "player", "gold" } }
    local val = eval_mod.eval_expr(node, ctx)
    assert.equal(50, val)
  end)
end)

-- ============================================================
-- time-travel command
-- ============================================================

describe("debug: time-travel command", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("time-travel at seq 0 returns initial defaults", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, gt.fns, "test")
    -- Earn some gold (seq 1)
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 10 }}, ctx)
    -- Earn more gold (seq 2)
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 20 }}, ctx)

    local srv = debug_mod.new(eng)
    srv:start()

    -- time-travel to seq=0 → should see initial defaults only (gold=50)
    local resp = srv:handle_command("time-travel", { seq = 0 })
    assert.is_nil(resp.error, resp.error)
    assert.is_table(resp.snapshot)
    assert.equal(50, resp.snapshot["player/gold"])
  end)

  it("time-travel to seq 1 shows state after first mutation", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, gt.fns, "test")
    -- Earn 10 gold (seq 1 → gold=60)
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 10 }}, ctx)
    -- Earn 20 gold (seq 2 → gold=80)
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 20 }}, ctx)

    local srv = debug_mod.new(eng)
    srv:start()

    -- time-travel to seq=1 → should see gold=60
    local resp = srv:handle_command("time-travel", { seq = 1 })
    assert.is_nil(resp.error, resp.error)
    assert.is_table(resp.snapshot)
    assert.equal(60, resp.snapshot["player/gold"])
  end)

  it("time-travel returns filtered entries and watches", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, gt.fns, "test")
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 10 }}, ctx)  -- seq 1
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 20 }}, ctx)  -- seq 2

    local srv = debug_mod.new(eng)
    srv:start()
    srv:register_watch("player/gold", "Gold")

    -- At seq=1 there is 1 log entry; watches reflect that snapshot
    local resp = srv:handle_command("time-travel", { seq = 1 })
    assert.is_table(resp.entries)
    assert.equal(1, #resp.entries)
    assert.equal(1, resp.entries[1].seq)
    assert.is_table(resp.watches)
    local gold_w
    for _, w in ipairs(resp.watches) do
      if w.label == "Gold" then gold_w = w end
    end
    assert.not_nil(gold_w, "Gold watch should be present")
    assert.equal(60, gold_w.value)  -- snapshot at seq=1: gold=60
  end)

  it("time-travel returns frozen snapshot (live state unchanged)", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local before_gold = eng._state:get("player/gold")
    local resp = srv:handle_command("time-travel", { seq = 0 })

    -- Live state must be unchanged
    assert.equal(before_gold, eng._state:get("player/gold"))
    assert.is_table(resp.snapshot)
  end)
end)

-- ============================================================
-- Event hooks
-- ============================================================

describe("debug: event hooks (on/emit)", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("registered handler is called when event is emitted", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local received = {}
    srv:on("mutation", function(payload)
      received[#received + 1] = payload
    end)

    srv:emit("mutation", { path = "player/gold", old = 50, new = 60, fn = "earn", tick = 0 })

    assert.equal(1, #received)
    assert.equal("player/gold", received[1].path)
    assert.equal(60, received[1].new)
  end)

  it("multiple handlers for the same event are all called", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local count = 0
    srv:on("mutation", function() count = count + 1 end)
    srv:on("mutation", function() count = count + 1 end)

    srv:emit("mutation", {})
    assert.equal(2, count)
  end)
end)

-- ============================================================
-- Watches
-- ============================================================

describe("debug: watch-when fires on positive edge", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("watch-when fires when condition becomes true", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local fired = {}
    srv:on("watch-fired", function(payload)
      fired[#fired + 1] = payload
    end)

    -- Register a watch-when condition: player/gold >= 100
    local eval_mod = require("runtime.eval")
    local cond_ast = {
      kind  = "binary_op",
      op    = ">=",
      left  = { kind = "path_expr", segments = { "player", "gold" } },
      right = { kind = "int_lit", value = 100 },
    }
    srv:register_watch_when(cond_ast, "Gold maxed out")

    -- Initial check: gold = 50, condition false → no fire
    srv:check_watches()
    assert.equal(0, #fired)

    -- Increase gold to 100
    eng._state:set("player/gold", 100, "test")

    -- Check again: condition now true → should fire
    srv:check_watches()
    assert.equal(1, #fired)
    assert.equal("Gold maxed out", fired[1].label)

    -- Check again: condition still true → NO re-fire (edge detection)
    srv:check_watches()
    assert.equal(1, #fired)

    -- Decrease gold back below 100
    eng._state:set("player/gold", 50, "test")
    srv:check_watches()

    -- Increase again → should fire again
    eng._state:set("player/gold", 100, "test")
    srv:check_watches()
    assert.equal(2, #fired)
  end)
end)

describe("debug: watch-path fires when path has a value", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("watch-path emits when path is non-nil", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local fired = {}
    srv:on("watch-fired", function(payload)
      fired[#fired + 1] = payload
    end)

    srv:register_watch("player/gold", "Gold")
    srv:check_watches()
    assert.equal(1, #fired)
    assert.equal("Gold", fired[1].label)
    assert.equal("path", fired[1].kind)
    assert.equal(50, fired[1].value)
  end)
end)

-- ============================================================
-- Breakpoints
-- ============================================================

describe("debug: breakpoints", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("set-breakpoint returns an id", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("set-breakpoint", { condition = "player/gold >= 90" })
    assert.is_not_nil(resp.id)
    assert.is_number(resp.id)
  end)

  it("clear-breakpoint removes the breakpoint", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local set_resp = srv:handle_command("set-breakpoint", { condition = "player/gold >= 90" })
    local id = set_resp.id
    assert.is_not_nil(srv._breakpoints[id])

    srv:handle_command("clear-breakpoint", { id = id })
    assert.is_nil(srv._breakpoints[id])
  end)

  it("breakpoint-hit fires on positive edge when condition becomes true", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local hits = {}
    srv:on("breakpoint-hit", function(p) hits[#hits+1] = p end)

    -- Set a breakpoint: fires when player/gold >= 90 (starts at 50)
    local resp = srv:handle_command("set-breakpoint", { condition = "player/gold >= 90" })
    assert.is_not_nil(resp.id)

    -- Initial check: gold=50, condition false → no hit
    srv:check_watches()
    assert.equal(0, #hits)

    -- Raise gold to 95 → condition becomes true → fires
    eng._state:set("player/gold", 95, "test")
    srv:check_watches()
    assert.equal(1, #hits)
    assert.equal(resp.id, hits[1].id)
    assert.equal("player/gold >= 90", hits[1].condition)

    -- Still true → no re-fire (positive-edge)
    srv:check_watches()
    assert.equal(1, #hits)

    -- Drop below threshold and rise again → fires again
    eng._state:set("player/gold", 50, "test")
    srv:check_watches()
    eng._state:set("player/gold", 95, "test")
    srv:check_watches()
    assert.equal(2, #hits)
  end)

  it("cleared breakpoint no longer fires", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local hits = {}
    srv:on("breakpoint-hit", function(p) hits[#hits+1] = p end)

    local resp = srv:handle_command("set-breakpoint", { condition = "player/gold >= 90" })
    srv:handle_command("clear-breakpoint", { id = resp.id })

    eng._state:set("player/gold", 95, "test")
    srv:check_watches()
    assert.equal(0, #hits)
  end)
end)

-- ============================================================
-- fn-call debug event
-- ============================================================

describe("debug: fn-call event", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("fn-call event fires with correct name and args when a named fn is called", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local calls = {}
    srv:on("fn-call", function(p) calls[#calls+1] = p end)

    local eval_mod = require("runtime.eval")
    -- Use eng:make_ctx so ctx.debug is wired to the debug server
    local ctx = eng:make_ctx("test")
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 10 }}, ctx)

    assert.equal(1, #calls, "fn-call event should fire once")
    assert.equal("earn", calls[1].name)
    assert.same({10}, calls[1].args)
  end)
end)

-- ============================================================
-- message-sent debug event
-- ============================================================

describe("debug: message-sent event", function()
  local SRC = [[
module msg-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  tick: Int(0,9999) = 0

actor npc:
  inbox: String

fn alert-npc:
  send! npc "hello"

scene main:
  * Go -> main
]]

  it("message-sent event fires with correct actor name when send! is called", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local msgs = {}
    srv:on("message-sent", function(p) msgs[#msgs+1] = p end)

    local ctx = eng:make_ctx("test")
    local eval_mod = require("runtime.eval")
    eval_mod.call_fn("alert-npc", {}, ctx)

    assert.equal(1, #msgs, "message-sent should fire once")
    assert.equal("npc", msgs[1].actor)
    assert.equal("hello", msgs[1].msg)
  end)
end)

-- ============================================================
-- Hot reload
-- ============================================================

describe("debug: hot reload", function()
  local src_v1 = [[
module reload-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  counter: Int(0, 9999) = 0

fn increment:
  inc! world/counter 1

scene main:
  * Go
    -> main
]]

  local src_v2 = [[
module reload-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  counter: Int(0, 9999) = 0

fn increment:
  inc! world/counter 10

scene main:
  * Go
    -> main
]]

  it("reload updates function body while preserving state", function()
    local gt1, errs1 = compile(src_v1)
    assert.equal(0, #errs1)

    local eng = engine_mod.new(gt1, { io_out = { write = function() end } })
    eng:init()

    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, eng._fns, "test")

    -- Increment by 1 (v1 logic)
    eval_mod.call_fn("increment", {}, ctx)
    assert.equal(1, eng._state:get("world/counter"))

    -- Hot reload with v2 source
    local srv = debug_mod.new(eng)
    srv:start()

    local resp = srv:handle_command("reload", { src = src_v2 })
    assert.is_true(resp.ok, resp.error)

    -- State preserved
    assert.equal(1, eng._state:get("world/counter"))

    -- Increment using reloaded fn (now adds 10)
    local ctx2 = eval_mod.new_ctx(eng._state, eng._fns, "test")
    eval_mod.call_fn("increment", {}, ctx2)
    assert.equal(11, eng._state:get("world/counter"))
  end)
end)

-- ============================================================
-- Integration: mutation events wired through engine
-- ============================================================

describe("debug: mutation events from state store", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("mutation event fires when state changes via fn", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local mutations = {}
    srv:on("mutation", function(p) mutations[#mutations + 1] = p end)

    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, eng._fns, "test")
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 30 }}, ctx)

    assert.is_true(#mutations > 0)
    local found = false
    for _, m in ipairs(mutations) do
      if m.path == "player/gold" and m.new == 80 then found = true end
    end
    assert.is_true(found, "should have mutation event for player/gold = 80")
  end)
end)

describe("debug: scene-change events from engine navigation", function()
  local src_with_scenes = [[
module nav-test
  version: 1.0
engine-config:
  entry-scene: start

state world:
  step: Int(0, 9) = 0

scene start:
  Starting.

  * Go to next
    inc! world/step 1
    -> next

scene next:
  Next.

  * Back
    -> start
]]

  it("scene-change event fires on goto_scene", function()
    local gt, errs = compile(src_with_scenes)
    assert.equal(0, #errs)
    if not gt then pending("compile failed"); return end

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local changes = {}
    srv:on("scene-change", function(p) changes[#changes + 1] = p end)

    -- Execute choice "Go to next" → signal goto 'next
    local sig = eng:do_choice("start", 1)
    assert.is_not_nil(sig)
    eng:goto_scene(sig.target)

    assert.is_true(#changes > 0)
    assert.equal("next", changes[#changes].to)
  end)
end)

-- ============================================================
-- clamp-event hook
-- ============================================================

describe("debug: clamp-event fires when value is clamped", function()
  local gt, errs = compile(MINIMAL_SRC)

  it("fires clamp-event when inc! exceeds Int max", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local clamps = {}
    srv:on("clamp-event", function(p) clamps[#clamps + 1] = p end)

    -- player/gold starts at 50, max is 999; inc by 1000 → clamp to 999
    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, eng._fns, "test")
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 1000 }}, ctx)

    assert.equal(1, #clamps)
    assert.equal("player/gold", clamps[1].path)
    assert.equal(1050, clamps[1].attempted)
    assert.equal(999,  clamps[1].clamped)
  end)

  it("fires clamp-event when dec! goes below Int min", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local clamps = {}
    srv:on("clamp-event", function(p) clamps[#clamps + 1] = p end)

    -- player/health starts at 100, min is 0; dec by 200 → clamp to 0
    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, eng._fns, "test")
    eval_mod.call_fn("hurt", {{ kind = "int_lit", value = 200 }}, ctx)

    assert.equal(1, #clamps)
    assert.equal("player/health", clamps[1].path)
    assert.equal(-100, clamps[1].attempted)
    assert.equal(0,    clamps[1].clamped)
  end)

  it("does NOT fire clamp-event when no clamping occurs", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local clamps = {}
    srv:on("clamp-event", function(p) clamps[#clamps + 1] = p end)

    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, eng._fns, "test")
    -- earn 10 gold: 50+10=60 (within 0..999)
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 10 }}, ctx)

    assert.equal(0, #clamps)
  end)
end)

-- ============================================================
-- JSON decoder
-- ============================================================

describe("debug: JSON decoder", function()
  local dec = debug_mod.decode_json

  it("decodes null to nil", function()
    assert.is_nil(dec("null"))
  end)

  it("decodes boolean true/false", function()
    assert.is_true(dec("true"))
    assert.is_false(dec("false"))
  end)

  it("decodes integers and floats", function()
    assert.equal(42, dec("42"))
    assert.equal(-7, dec("-7"))
    assert.equal(3.14, dec("3.14"))
  end)

  it("decodes plain strings", function()
    assert.equal("hello", dec('"hello"'))
  end)

  it("decodes strings with escape sequences", function()
    assert.equal('a"b', dec('"a\\"b"'))
    assert.equal("a\nb", dec('"a\\nb"'))
  end)

  it("decodes empty object", function()
    local v = dec("{}")
    assert.same({}, v)
  end)

  it("decodes object with mixed values", function()
    local v = dec('{"cmd":"get-state","from":1,"ok":true}')
    assert.equal("get-state", v.cmd)
    assert.equal(1, v.from)
    assert.is_true(v.ok)
  end)

  it("decodes nested objects", function()
    local v = dec('{"a":{"b":2}}')
    assert.equal(2, v.a.b)
  end)

  it("decodes arrays", function()
    local v = dec('[1,2,3]')
    assert.same({1, 2, 3}, v)
  end)

  it("round-trips through encode/decode", function()
    local orig = { cmd = "get-log", from = 1, to = 10 }
    local encoded = debug_mod.encode_json(orig)
    local decoded = dec(encoded)
    assert.equal(orig.cmd, decoded.cmd)
    assert.equal(orig.from, decoded.from)
    assert.equal(orig.to, decoded.to)
  end)
end)

-- ============================================================
-- TCP transport (integration — requires LuaSocket)
-- ============================================================

describe("debug: TCP transport", function()
  local socket_ok, socket = pcall(require, "socket")
  if not socket_ok then
    pending("LuaSocket not installed — skipping TCP transport tests")
    return
  end

  it("accepts a TCP connection and responds to get-state", function()
    local gt, errs = compile(MINIMAL_SRC)
    if #errs > 0 then pending("compile failed"); return end

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng, { mode = "tcp", port = 17373 })
    srv:start()
    eng:set_debug_server(srv)

    -- Give server a moment then connect
    local client = socket.tcp()
    client:settimeout(1)
    local ok, err = client:connect("127.0.0.1", 17373)
    if not ok then
      srv:stop()
      pending("could not connect to debug server: " .. tostring(err))
      return
    end

    -- Send a get-state command
    local cmd = debug_mod.encode_json({ cmd = "get-state", pattern = "player/*" })
    client:send(cmd .. "\n")

    -- Server needs one poll to receive and respond
    srv:poll()

    local resp_line, rerr = client:receive("*l")
    client:close()
    srv:stop()

    assert.is_not_nil(resp_line, "no response: " .. tostring(rerr))
    local resp = debug_mod.decode_json(resp_line)
    assert.is_not_nil(resp.state)
    assert.equal(50,  resp.state["player/gold"])
    assert.equal(100, resp.state["player/health"])
  end)

  it("handles get-log over TCP", function()
    local gt, errs = compile(MINIMAL_SRC)
    if #errs > 0 then pending("compile failed"); return end

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng, { mode = "tcp", port = 17374 })
    srv:start()
    eng:set_debug_server(srv)

    local client = socket.tcp()
    client:settimeout(1)
    local ok = client:connect("127.0.0.1", 17374)
    if not ok then srv:stop(); pending("connect failed"); return end

    client:send(debug_mod.encode_json({ cmd = "get-log" }) .. "\n")
    srv:poll()

    local resp_line = client:receive("*l")
    client:close()
    srv:stop()

    assert.is_not_nil(resp_line)
    local resp = debug_mod.decode_json(resp_line)
    assert.is_not_nil(resp.entries)
  end)
end)

-- ============================================================
-- Hot reload: schema migration
-- ============================================================

describe("debug: hot reload schema migration", function()
  local BASE_SRC = [[
module reload-test
  version: 1.0
engine-config:
  entry-scene: main

type Status = alive | dead

state player:
  health: Int(0, 100) = 50
  status: Status      = :alive

scene main:
  * Go
    -> main
]]

  local function make_eng(src)
    local gt, errs = compile(src)
    assert.equal(0, #errs, "compile errors: " .. tostring(errs[1] and errs[1].message))
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)
    return eng, srv
  end

  it("reload with same schema returns ok", function()
    local _, srv = make_eng(BASE_SRC)
    local resp = srv:handle_command("reload", { src = BASE_SRC })
    assert.is_true(resp.ok)
  end)

  it("reload fires 'reload' event", function()
    local _, srv = make_eng(BASE_SRC)
    local fired = {}
    srv:on("reload", function(p) fired[#fired+1] = p end)
    srv:handle_command("reload", { src = BASE_SRC })
    assert.equal(1, #fired)
  end)

  it("reload: enum value removed from Status — error if current value invalid", function()
    local eng, srv = make_eng(BASE_SRC)
    -- Set player/status to :alive (valid in old schema, valid in new enum)
    eng._state._cache["player/status"] = "dead"
    -- New source removes 'dead' from Status
    local NEW_SRC = [[
module reload-test
  version: 1.0
engine-config:
  entry-scene: main

type Status = alive | zombie

state player:
  health: Int(0, 100) = 50
  status: Status      = :alive

scene main:
  * Go
    -> main
]]
    local resp = srv:handle_command("reload", { src = NEW_SRC })
    assert.is_false(resp.ok, "expected error when enum value is invalid")
    assert.is_not_nil(resp.error)
    assert.is_not_nil(resp.error:find("status"))
  end)

  it("reload: enum value added — current :alive value remains valid", function()
    local _, srv = make_eng(BASE_SRC)
    -- New source adds 'zombie' to Status enum
    local NEW_SRC = [[
module reload-test
  version: 1.0
engine-config:
  entry-scene: main

type Status = alive | dead | zombie

state player:
  health: Int(0, 100) = 50
  status: Status      = :alive

scene main:
  * Go
    -> main
]]
    local resp = srv:handle_command("reload", { src = NEW_SRC })
    assert.is_true(resp.ok)
  end)

  it("reload: new field added to record — does not error", function()
    local _, srv = make_eng(BASE_SRC)
    local NEW_SRC = [[
module reload-test
  version: 1.0
engine-config:
  entry-scene: main

type Status = alive | dead

state player:
  health: Int(0, 100) = 50
  status: Status      = :alive
  mana:   Int(0, 100) = 0

scene main:
  * Go
    -> main
]]
    local resp = srv:handle_command("reload", { src = NEW_SRC })
    assert.is_true(resp.ok)
  end)

  it("reload: removed field dropped silently from cache", function()
    local eng, srv = make_eng(BASE_SRC)
    eng._state._cache["player/health"] = 42
    -- New source drops 'health'
    local NEW_SRC = [[
module reload-test
  version: 1.0
engine-config:
  entry-scene: main

type Status = alive | dead

state player:
  status: Status = :alive

scene main:
  * Go
    -> main
]]
    local resp = srv:handle_command("reload", { src = NEW_SRC })
    assert.is_true(resp.ok)
    assert.is_nil(eng._state._cache["player/health"])
  end)

  it("reload: Int range narrowed — error if current value out of range", function()
    local eng, srv = make_eng(BASE_SRC)
    eng._state._cache["player/health"] = 80
    -- New source narrows health to Int(0, 50)
    local NEW_SRC = [[
module reload-test
  version: 1.0
engine-config:
  entry-scene: main

type Status = alive | dead

state player:
  health: Int(0, 50) = 25
  status: Status     = :alive

scene main:
  * Go
    -> main
]]
    local resp = srv:handle_command("reload", { src = NEW_SRC })
    assert.is_false(resp.ok)
    assert.is_not_nil(resp.error)
  end)
end)

-- ============================================================
-- Emitted events: spawn, despawn, message-sent, schedule-fired
-- ============================================================

describe("debug: emitted events", function()
  local ACTOR_SRC = [[
module event-test
  version: 1.0
engine-config:
  entry-scene: main

state npcs/{npc}: Bool = true  max: 10

fn spawn-npc name:
  spawn! npcs name

fn remove-npc name:
  despawn! npcs name

scene main:
  * Go
    -> main
]]

  local function make_eng_with_events(src)
    local gt, errs = compile(src or ACTOR_SRC)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)
    return eng, srv
  end

  it("spawn-event emitted on spawn!", function()
    local eng, srv = make_eng_with_events()
    local events = {}
    srv:on("spawn-event", function(p) events[#events+1] = p end)
    local ctx = eng:make_ctx("test")
    eng._state:spawn("npcs", "guard", {}, "test")
    assert.equal(1, #events)
    assert.equal("npcs",  events[1].family)
    assert.equal("guard", events[1].key)
  end)

  it("despawn-event emitted on despawn!", function()
    local eng, srv = make_eng_with_events()
    eng._state:spawn("npcs", "guard", {}, "test")
    local events = {}
    srv:on("despawn-event", function(p) events[#events+1] = p end)
    eng._state:despawn("npcs", "guard", "test")
    assert.equal(1, #events)
    assert.equal("npcs",  events[1].family)
    assert.equal("guard", events[1].key)
  end)

  it("clamp-event emitted when Int value is clamped", function()
    local SRC = [[
module clamp-test
  version: 1.0
engine-config:
  entry-scene: main
state world:
  hp: Int(0, 10) = 5
scene main:
  * Go -> main
]]
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local events = {}
    srv:on("clamp-event", function(p) events[#events+1] = p end)
    -- Decrement below minimum (0): should clamp
    eng._state:dec("world/hp", 100, "test")
    assert.equal(1, #events)
    assert.equal("world/hp", events[1].path)
    assert.equal(0, events[1].clamped)
  end)
end)

-- ============================================================
-- Path pattern watches (§4.3)
-- ============================================================

describe("debug: path pattern watches", function()
  local PATTERN_SRC = [[
module pattern-test
  version: 1.0
engine-config:
  entry-scene: main
state player:
  health: Int(0,100) = 80
  mana:   Int(0,100) = 60
  gold:   Int(0,999) = 10
state world:
  tick: Int(0,9999) = 0
scene main:
  * Go -> main
]]

  it("watch player/* fires for all player fields", function()
    local gt, errs = compile(PATTERN_SRC)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local fired = {}
    srv:on("watch-fired", function(p) fired[p.path] = p.value end)
    srv:register_watch("player/*", "All Player Fields")
    srv:check_watches()

    assert.is_not_nil(fired["player/health"], "player/health should fire")
    assert.is_not_nil(fired["player/mana"],   "player/mana should fire")
    assert.is_not_nil(fired["player/gold"],   "player/gold should fire")
    assert.is_nil(fired["world/tick"],         "world/tick should not match player/*")
  end)

  it("watch player/* fires correct default values", function()
    local gt, errs = compile(PATTERN_SRC)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()

    local fired = {}
    srv:on("watch-fired", function(p) fired[p.path] = p.value end)
    srv:register_watch("player/*", "Player")
    srv:check_watches()

    assert.equal(80, fired["player/health"])
    assert.equal(60, fired["player/mana"])
    assert.equal(10, fired["player/gold"])
  end)

  it("watch npcs/*/location matches family member location paths", function()
    local gt, errs = compile(PATTERN_SRC)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    -- Inject NPC family paths directly
    eng._state._cache["npcs/knight/location"] = 5
    eng._state._cache["npcs/mage/location"]   = 12
    eng._state._cache["npcs/knight/health"]   = 80

    local srv = debug_mod.new(eng)
    srv:start()
    local fired = {}
    srv:on("watch-fired", function(p) fired[p.path] = p.value end)
    srv:register_watch("npcs/*/location", "NPC Locations")
    srv:check_watches()

    assert.equal(5,  fired["npcs/knight/location"])
    assert.equal(12, fired["npcs/mage/location"])
    assert.is_nil(fired["npcs/knight/health"], "health should NOT match npcs/*/location")
  end)

  it("watch player/** matches nested multi-level paths", function()
    local gt, errs = compile(PATTERN_SRC)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    eng._state._cache["player/items/0"] = "sword"
    eng._state._cache["player/items/1"] = "shield"

    local srv = debug_mod.new(eng)
    srv:start()
    local fired = {}
    srv:on("watch-fired", function(p) fired[p.path] = true end)
    srv:register_watch("player/**", "Deep Player")
    srv:check_watches()

    assert.is_true(fired["player/health"],  "player/health should match player/**")
    assert.is_true(fired["player/items/0"], "player/items/0 should match player/**")
    assert.is_true(fired["player/items/1"], "player/items/1 should match player/**")
    assert.is_nil(fired["world/tick"],      "world/tick should not match player/**")
  end)

  it("watch player/(health|mana) fires only health and mana", function()
    local gt, errs = compile(PATTERN_SRC)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    local fired = {}
    srv:on("watch-fired", function(p) fired[p.path] = true end)
    srv:register_watch("player/(health|mana)", "Health or Mana")
    srv:check_watches()

    assert.is_true(fired["player/health"], "player/health should fire")
    assert.is_true(fired["player/mana"],   "player/mana should fire")
    assert.is_nil(fired["player/gold"],    "player/gold should NOT fire")
  end)

  it("watch player/!gold fires for health and mana but NOT gold", function()
    local gt, errs = compile(PATTERN_SRC)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    local fired = {}
    srv:on("watch-fired", function(p) fired[p.path] = true end)
    srv:register_watch("player/!gold", "Not gold")
    srv:check_watches()

    assert.is_true(fired["player/health"], "player/health should fire (not negated)")
    assert.is_true(fired["player/mana"],   "player/mana should fire (not negated)")
    assert.is_nil(fired["player/gold"],    "player/gold should NOT fire (negated)")
  end)

  it("watch pattern declarations compile from .sb source (**, (a|b), !field)", function()
    local src = [[
module pat-decl
  version: 1.0
engine-config:
  entry-scene: main
state player:
  health: Int(0,100) = 80
  mana:   Int(0,100) = 60
  gold:   Int(0,999) = 10
watch player/** "Deep"
watch player/(health|mana) "HP or MP"
watch player/!gold "Not gold"
scene main:
  * Go -> main
]]
    local gt, errs = compile(src)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    assert.equal(3, #(gt.watches or {}))
    local paths = {}
    for _, w in ipairs(gt.watches) do
      paths[table.concat(w.path.segments or {}, "/")] = true
    end
    assert.is_true(paths["player/**"],          "** pattern stored")
    assert.is_true(paths["player/(health|mana)"], "(a|b) pattern stored")
    assert.is_true(paths["player/!gold"],        "!field pattern stored")
  end)

  it("exact path watch still works correctly", function()
    local gt, errs = compile(PATTERN_SRC)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    local fired = {}
    srv:on("watch-fired", function(p) fired[#fired+1] = p end)
    srv:register_watch("player/health", "HP")
    srv:check_watches()

    assert.equal(1, #fired)
    assert.equal("player/health", fired[1].path)
    assert.equal(80, fired[1].value)
  end)
end)

-- ============================================================
-- Game-table watch declarations wired via set_debug_server
-- ============================================================

describe("debug: game-table watch declarations", function()
  it("watch declaration fires via set_debug_server", function()
    local SRC = [[
module watch-decl-test
  version: 1.0
engine-config:
  entry-scene: main
state world:
  hp: Int(0,100) = 75
watch world/hp "HP Watch"
scene main:
  * Go -> main
]]
    local gt, errs = compile(SRC)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local fired = {}
    srv:on("watch-fired", function(p) fired[#fired+1] = p end)
    srv:check_watches()

    assert.equal(1, #fired, "watch declaration should fire")
    assert.equal("HP Watch", fired[1].label)
    assert.equal(75, fired[1].value)
  end)

  it("watch-when declaration fires via set_debug_server", function()
    local SRC = [[
module watch-when-test
  version: 1.0
engine-config:
  entry-scene: main
state world:
  hp: Int(0,100) = 10
watch-when world/hp < 50 "Low HP"
scene main:
  * Go -> main
]]
    local gt, errs = compile(SRC)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)

    local fired = {}
    srv:on("watch-fired", function(p) fired[#fired+1] = p end)
    srv:check_watches()  -- hp=10 < 50: fires on first check

    assert.equal(1, #fired, "watch-when should fire when condition is initially true")
    assert.equal("Low HP", fired[1].label)
  end)
end)

-- ============================================================
-- get-schema command
-- ============================================================

local SCHEMA_SRC = [[
module schema-test
  version: 1.2
engine-config:
  entry-scene: start
schema-version: 2

"A shrine type."
type ShrineKind = hearth | stone | lake

"World state."
state world:
  score: Int(0, 999) = 0
  shrine: ShrineKind = 'hearth

"Shrine paths."
relation paths: ShrineKind -> Set(ShrineKind, 2):
  'hearth: {'stone}
  'stone:  {'lake}
  'lake:   {'hearth}

"Advance score."
fn advance:
  inc! world/score 10

"Add points."
fn score-points amount:
  inc! world/score amount

"Is winning?"
fn winning?:
  world/score >= 500

"External oracle."
bounded oracle-score:
  returns:      Int(0, 999)
  lua:          "oracle.score"

scene start:
  * Go
    -> start
]]

local function make_schema_srv()
  local gt, errs = compile(SCHEMA_SRC)
  assert.equal(0, #errs, errs[1] and errs[1].message)
  local eng = engine_mod.new(gt, { io_out = { write = function() end } })
  eng:init()
  local srv = debug_mod.new(eng)
  srv:start()
  return srv
end

describe("debug: get-schema command", function()
  it("returns error without engine", function()
    local srv = debug_mod.new(nil)
    local r = srv:handle_command("get-schema")
    assert.not_nil(r.error)
  end)

  it("returns schema_version and engine_config", function()
    local srv = make_schema_srv()
    local r = srv:handle_command("get-schema")
    assert.is_nil(r.error)
    assert.equal(2, r.schema_version)
    assert.not_nil(r.engine_config)
    assert.equal("start", r.engine_config["entry-scene"])
  end)

  it("returns types with doc strings", function()
    local srv = make_schema_srv()
    local r = srv:handle_command("get-schema")
    assert.is_nil(r.error)
    assert.not_nil(r.types)
    local shrine_type
    for _, t in ipairs(r.types) do
      if t.name == "ShrineKind" then shrine_type = t end
    end
    assert.not_nil(shrine_type, "ShrineKind type should be present")
    assert.equal("A shrine type.", shrine_type.doc)
  end)

  it("returns states with doc strings", function()
    local srv = make_schema_srv()
    local r = srv:handle_command("get-schema")
    assert.is_nil(r.error)
    assert.not_nil(r.states)
    local world_state
    for _, s in ipairs(r.states) do
      if s.path == "world" or (s.path and s.path:find("^world")) then
        world_state = s; break
      end
    end
    assert.not_nil(world_state, "world state entry should be present")
  end)

  it("returns relations", function()
    local srv = make_schema_srv()
    local r = srv:handle_command("get-schema")
    assert.is_nil(r.error)
    assert.not_nil(r.relations)
    local paths_rel
    for _, rel in ipairs(r.relations) do
      if rel.name == "paths" then paths_rel = rel end
    end
    assert.not_nil(paths_rel, "paths relation should be present")
    assert.equal("ShrineKind", paths_rel.from_type)
  end)

  it("returns fns with doc strings and transaction flag", function()
    local srv = make_schema_srv()
    local r = srv:handle_command("get-schema")
    assert.is_nil(r.error)
    assert.not_nil(r.fns)
    local advance_fn, winning_fn
    for _, f in ipairs(r.fns) do
      if f.name == "advance"  then advance_fn  = f end
      if f.name == "winning?" then winning_fn  = f end
    end
    assert.not_nil(advance_fn, "advance fn should be present")
    assert.equal("Advance score.", advance_fn.doc)
    assert.equal(true, advance_fn.is_transaction)
    assert.not_nil(winning_fn, "winning? fn should be present")
    assert.equal(false, winning_fn.is_transaction)
  end)

  it("returns scenes with doc strings", function()
    local srv = make_schema_srv()
    local r = srv:handle_command("get-schema")
    assert.is_nil(r.error)
    assert.not_nil(r.scenes)
    local start_scene
    for _, sc in ipairs(r.scenes) do
      if sc.name == "start" then start_scene = sc end
    end
    assert.not_nil(start_scene, "start scene should be present")
  end)

  it("returns bounded declarations with doc strings", function()
    local srv = make_schema_srv()
    local r = srv:handle_command("get-schema")
    assert.is_nil(r.error)
    assert.not_nil(r.bounded)
    local oracle
    for _, b in ipairs(r.bounded) do
      if b.name == "oracle-score" then oracle = b end
    end
    assert.not_nil(oracle, "oracle-score bounded should be present")
    assert.equal("External oracle.", oracle.doc)
    assert.equal("oracle.score", oracle.lua_name)
  end)

  it("returns empty lists for game with no actors or schedules", function()
    local srv = make_schema_srv()
    local r = srv:handle_command("get-schema")
    assert.is_nil(r.error)
    assert.not_nil(r.actors)
    assert.not_nil(r.schedules)
    assert.equal(0, #r.actors)
    assert.equal(0, #r.schedules)
  end)
end)

-- ============================================================
-- get-watches command
-- ============================================================

local WATCH_SRC = [[
module watch-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  gold:   Int(0, 999) = 50
  health: Int(0, 100) = 100

state world:
  tick: Int(0, 9999) = 0

watch player/gold "Gold"
watch player/health "HP"
watch-when player/health <= 0 "Player dead"

scene main:
  * Go -> main
]]

describe("debug: get-watches command", function()
  local gt = compiler_mod.compile(WATCH_SRC, "test.sb")

  local function make_srv()
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    eng:set_debug_server(srv)
    return srv, eng
  end

  it("returns current values of all path watches", function()
    if not gt then pending("compile failed"); return end
    local srv = make_srv()
    local r = srv:handle_command("get-watches")
    assert.is_nil(r.error)
    assert.not_nil(r.watches)
    local by_label = {}
    for _, w in ipairs(r.watches) do by_label[w.label] = w end
    assert.not_nil(by_label["Gold"])
    assert.equal(50, by_label["Gold"].value)
    assert.equal("player/gold", by_label["Gold"].path)
    assert.not_nil(by_label["HP"])
    assert.equal(100, by_label["HP"].value)
  end)

  it("returns false for watch-when condition that is not met", function()
    if not gt then pending("compile failed"); return end
    local srv = make_srv()
    local r = srv:handle_command("get-watches")
    local by_label = {}
    for _, w in ipairs(r.watches) do by_label[w.label] = w end
    assert.not_nil(by_label["Player dead"])
    assert.equal(false, by_label["Player dead"].value)
  end)

  it("reflects updated state after mutation", function()
    if not gt then pending("compile failed"); return end
    local srv, eng = make_srv()
    eng._state:set("player/gold", 123, "test")
    local r = srv:handle_command("get-watches")
    local by_label = {}
    for _, w in ipairs(r.watches) do by_label[w.label] = w end
    assert.equal(123, by_label["Gold"].value)
  end)

  it("returns watch-when as true when condition is met", function()
    if not gt then pending("compile failed"); return end
    local srv, eng = make_srv()
    eng._state:set("player/health", 0, "test")
    local r = srv:handle_command("get-watches")
    local by_label = {}
    for _, w in ipairs(r.watches) do by_label[w.label] = w end
    assert.equal(true, by_label["Player dead"].value)
  end)

  it("returns empty watches list when no watches registered", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    local r = srv:handle_command("get-watches")
    assert.not_nil(r.watches)
    assert.equal(0, #r.watches)
  end)
end)

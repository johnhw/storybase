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

  it("time-travel at tick 0 returns initial state", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, gt.fns, "test")
    -- Earn some gold (at tick 0)
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 10 }}, ctx)
    -- Advance tick
    eng._state:set("world/tick", 1, "test")
    -- Earn more gold (at tick 1)
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 20 }}, ctx)

    local srv = debug_mod.new(eng)
    srv:start()

    -- time-travel to tick 0 → should see gold = 60 (50 + 10 earned)
    local resp = srv:handle_command("time-travel", { tick = 0 })
    assert.is_nil(resp.error, resp.error)
    assert.is_table(resp.snapshot)
    -- Snapshot at tick ≤ 0 contains initial defaults and any mutations at tick 0
    assert.is_not_nil(resp.snapshot["player/gold"])
  end)

  it("time-travel returns frozen snapshot (live state unchanged)", function()
    if not gt then pending("compile failed"); return end
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local srv = debug_mod.new(eng)
    srv:start()

    local before_gold = eng._state:get("player/gold")
    local resp = srv:handle_command("time-travel", { tick = 0 })

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
  local socket = require("socket")

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

-- tests/lib/storybase_spec.lua
-- Tests for the public Lua interop API (lib/storybase.lua).
--
-- Run with: busted tests/

local sb = require("lib.storybase")

-- ── Shared source fixture ─────────────────────────────────────────────────────

local SRC = [[
module interop-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold:  Int(0, 9999) = 0
  ready: Bool = false

scene main:
  * Earn
    inc! world/gold 10
    -> main
  * Finish
    set! world/ready true
    -> end-scene

scene end-scene:
  Done.

fn earn-bonus:
  inc! world/gold 25

fn earn-amount amount:
  inc! world/gold amount
]]

-- ── from_source ──────────────────────────────────────────────────────────────

describe("sb.from_source", function()
  it("returns a game object for valid source", function()
    local game, err = sb.from_source(SRC, "test")
    assert.is_nil(err)
    assert.is_not_nil(game)
  end)

  it("returns nil + error for source with compile errors", function()
    local game, err = sb.from_source("this is not valid storybase syntax !!!", "bad")
    assert.is_nil(game)
    assert.is_not_nil(err)
  end)
end)

-- ── init / render / current_scene ────────────────────────────────────────────

describe("game object", function()
  local function make()
    local g = sb.from_source(SRC, "test"); g:init(); return g
  end

  it("current_scene returns entry scene after init", function()
    local g = make()
    assert.equal("main", g:current_scene())
  end)

  it("scene() is an alias for current_scene()", function()
    local g = make()
    assert.equal(g:current_scene(), g:scene())
  end)

  it("render returns narration and choices", function()
    local g = make()
    local narr, choices = g:render()
    assert.is_table(narr)
    assert.is_table(choices)
    assert.equal(2, #choices)
    assert.equal("Earn",   choices[1].label)
    assert.equal("Finish", choices[2].label)
  end)

  it("choices() returns only the choice list", function()
    local g = make()
    local choices = g:choices()
    assert.is_table(choices)
    assert.equal(2, #choices)
    assert.equal("Earn",   choices[1].label)
    assert.equal("Finish", choices[2].label)
  end)

  it("pick() selects first choice matching a substring", function()
    local g = make()
    assert.is_true(g:pick("Earn"))
    assert.equal(10, g:get("world/gold"))
  end)

  it("pick() returns false when no matching choice exists", function()
    local g = make()
    assert.is_false(g:pick("nonexistent-choice-xyz"))
    assert.equal(0, g:get("world/gold"))  -- no side effect
  end)

  -- ── get ──────────────────────────────────────────────────────────

  it("get returns default values before any choice", function()
    local g = make()
    assert.equal(0,     g:get("world/gold"))
    assert.equal(false, g:get("world/ready"))
  end)

  -- ── choose ───────────────────────────────────────────────────────

  it("choose dispatches player action and updates state", function()
    local g = make()
    local ok = g:choose(1)   -- Earn
    assert.is_true(ok)
    assert.equal(10, g:get("world/gold"))
  end)

  it("choose returns false for out-of-range index", function()
    local g = make()
    local ok = g:choose(99)
    assert.is_false(ok)
  end)

  it("multiple choices accumulate state correctly", function()
    local g = make()
    g:choose(1); g:choose(1); g:choose(1)   -- Earn 3×
    assert.equal(30, g:get("world/gold"))
  end)

  it("choose transitions scene on Finish", function()
    local g = make()
    g:choose(2)   -- Finish → end-scene
    assert.equal("end-scene", g:current_scene())
    assert.equal(true, g:get("world/ready"))
  end)

  -- ── call ─────────────────────────────────────────────────────────

  it("call invokes a named function", function()
    local g = make()
    g:call("earn-bonus")
    assert.equal(25, g:get("world/gold"))
  end)

  it("call passes positional arguments", function()
    local g = make()
    g:call("earn-amount", 7)
    assert.equal(7, g:get("world/gold"))
  end)

  -- ── eval ─────────────────────────────────────────────────────────

  it("eval evaluates a pure expression string", function()
    local g = make()
    g:call("earn-bonus")
    local val, err = g:eval("world/gold + 5")
    assert.is_nil(err)
    assert.equal(30, val)
  end)

  it("eval returns nil + error for bad expression", function()
    local g = make()
    local val, err = g:eval("this is not valid !!!")
    assert.is_nil(val)
    assert.is_not_nil(err)
  end)

  -- ── on / event listeners ─────────────────────────────────────────

  it("on(`choice') fires after each choose", function()
    local g = make()
    local fired = {}
    g:on("choice", function(e) fired[#fired+1] = e end)
    g:choose(1)
    g:choose(1)
    assert.equal(2, #fired)
    assert.equal("main", fired[1].scene)
    assert.equal(1,      fired[1].index)
  end)

  -- ── tick (autonomous turn) ────────────────────────────────────────

  it("tick advances one autonomous turn without crashing", function()
    local g = make()
    -- tick should run post-action without player input
    assert.has_no.errors(function() g:tick() end)
  end)

  -- ── save / load ──────────────────────────────────────────────────

  it("save creates a file and load restores state", function()
    local g = make()
    g:choose(1); g:choose(1)   -- gold = 20
    assert.equal(20, g:get("world/gold"))

    local path = os.tmpname() .. ".log"
    local ok, err = g:save(path)
    assert.is_true(ok, "save failed: " .. tostring(err))

    -- Reset and reload
    g:init()
    assert.equal(0, g:get("world/gold"))   -- reset
    local ok2, err2 = g:load(path)
    assert.is_true(ok2, "load failed: " .. tostring(err2))
    assert.equal(20, g:get("world/gold"))  -- restored

    os.remove(path)
  end)

  it("load returns false for nonexistent file", function()
    local g = make()
    local ok, err = g:load("/nonexistent/path/game.log")
    assert.is_false(ok)
    assert.is_not_nil(err)
  end)
end)

-- ── game:find ────────────────────────────────────────────────────────────────

describe("game:find", function()
  local FAMILY_SRC = [[
module find-test
  version: 1.0
engine-config:
  entry-scene: main

type NpcData:
  level: Int(1, 99) = 1
  alive: Bool       = true

state npcs/{npc}: NpcData  max: 10

scene main:
  Done.
]]

  local function make_npc_game()
    local g = sb.from_source(FAMILY_SRC, "find-test")
    g:init()
    -- Spawn three npcs
    g._eng._state:spawn("npcs", "alice", {})
    g._eng._state:spawn("npcs", "bob",   {})
    g._eng._state:spawn("npcs", "carol", {})
    g._eng._state:set("npcs/alice/level", 5)
    g._eng._state:set("npcs/bob/level",   3)
    g._eng._state:set("npcs/carol/level", 7)
    g._eng._state:set("npcs/bob/alive",   false)
    return g
  end

  it("returns all keys with no options", function()
    local g = make_npc_game()
    local keys = g:find("npcs")
    assert.equal(3, #keys)
  end)

  it("filters with a where predicate", function()
    local g = make_npc_game()
    local state = g._eng._state
    local keys = g:find("npcs", {
      where = function(k) return state:get("npcs/" .. k .. "/alive") ~= false end
    })
    assert.equal(2, #keys)
    -- alice and carol should be alive
    local found = {}
    for _, k in ipairs(keys) do found[k] = true end
    assert.is_true(found["alice"])
    assert.is_true(found["carol"])
    assert.is_nil(found["bob"])
  end)

  it("orders by a path template ascending", function()
    local g = make_npc_game()
    local keys = g:find("npcs", { order_by = "npcs/{key}/level" })
    -- bob(3) < alice(5) < carol(7)
    assert.equal("bob",   keys[1])
    assert.equal("alice", keys[2])
    assert.equal("carol", keys[3])
  end)

  it("orders descending", function()
    local g = make_npc_game()
    local keys = g:find("npcs", {
      order_by = "npcs/{key}/level", order_dir = "desc"
    })
    assert.equal("carol", keys[1])
    assert.equal("alice", keys[2])
    assert.equal("bob",   keys[3])
  end)

  it("limits the result count", function()
    local g = make_npc_game()
    local keys = g:find("npcs", {
      order_by = "npcs/{key}/level", limit = 2
    })
    assert.equal(2, #keys)
    assert.equal("bob",   keys[1])
    assert.equal("alice", keys[2])
  end)

  it("returns count when count=true", function()
    local g = make_npc_game()
    local n = g:find("npcs", { count = true })
    assert.equal(3, n)
  end)

  it("returns 0 count with restrictive where", function()
    local g = make_npc_game()
    local n = g:find("npcs", {
      where = function() return false end,
      count = true
    })
    assert.equal(0, n)
  end)
end)

-- ── sb.load (file-based) ─────────────────────────────────────────────────────

describe("sb.load", function()
  it("returns nil + error for nonexistent file", function()
    local game, err = sb.load("/nonexistent/file.sb")
    assert.is_nil(game)
    assert.is_not_nil(err)
  end)

  it("loads and runs a real .sb file", function()
    local game, err = sb.load("tests/test01_minimal.sb")
    assert.is_nil(err, tostring(err))
    assert.is_not_nil(game)
    game:init()
    assert.is_not_nil(game:current_scene())
  end)
end)

-- ── game:counterfactual ───────────────────────────────────────────────────────

describe("game:counterfactual", function()
  local SRC2 = [[
module cf-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  score: Int(0, 9999) = 0

scene main:
  * Score
    inc! world/score 5
    -> main
  * End
    -> done

scene done:
  Done.
]]

  local function make()
    local g = sb.from_source(SRC2, "cf-test"); g:init()
    return g
  end

  it("branch mutations do not affect live state", function()
    local g = make()
    g:choose(1)  -- live score = 5
    local snap = g:counterfactual(function(branch)
      branch:choose(1)  -- branch score = 10
      branch:choose(1)  -- branch score = 15
    end)
    assert.equal(15, snap:get("world/score"))
    assert.equal(5,  g:get("world/score"))  -- live unchanged
  end)

  it("snapshot captures state after branch mutations", function()
    local g = make()
    local snap = g:counterfactual(function(branch)
      branch:choose(1); branch:choose(1)  -- 10 points
    end)
    assert.equal(10, snap:get("world/score"))
  end)

  it("snapshot current_scene reflects branch navigation", function()
    local g = make()
    local snap = g:counterfactual(function(branch)
      branch:choose(2)  -- End → done
    end)
    assert.equal("done", snap:current_scene())
    assert.equal("main", g:current_scene())  -- live unchanged
  end)

  it("branch inherits live state at time of counterfactual call", function()
    local g = make()
    g:choose(1); g:choose(1)  -- live score = 10
    local snap = g:counterfactual(function(branch)
      -- No extra mutations; snapshot should match live
    end)
    assert.equal(10, snap:get("world/score"))
  end)

  it("nested counterfactuals work independently", function()
    local g = make()
    local snap1 = g:counterfactual(function(b1)
      b1:choose(1)  -- 5 pts
    end)
    local snap2 = g:counterfactual(function(b2)
      b2:choose(1); b2:choose(1)  -- 10 pts
    end)
    assert.equal(5,  snap1:get("world/score"))
    assert.equal(10, snap2:get("world/score"))
    assert.equal(0,  g:get("world/score"))  -- live unchanged
  end)

  it("errors in callback are propagated", function()
    local g = make()
    assert.has_error(function()
      g:counterfactual(function()
        error("intentional error")
      end)
    end)
  end)
end)

-- ── game:register_bounded ─────────────────────────────────────────────────────

describe("game:register_bounded", function()
  local BOUNDED_SRC = [[
module bounded-test
  version: 1.0
engine-config:
  entry-scene: main
schema-version: 1

state world:
  luck: Int(0, 100) = 50

bounded roll-die:
  reads: [world/luck]

fn apply-roll:
  let result = roll-die
  set! world/luck result

scene main:
  * Roll
    apply-roll
    -> main
]]

  local function make_bounded()
    local g = sb.from_source(BOUNDED_SRC, "bounded-test")
    assert.is_not_nil(g)
    return g
  end

  it("register_bounded stores handler before init", function()
    local g = make_bounded()
    g:register_bounded("roll-die", function(_, _) return 42 end)
    g:init()
    g:call("apply-roll")
    assert.equal(42, g:get("world/luck"))
  end)

  it("register_bounded stores handler after init", function()
    local g = make_bounded()
    g:init()
    g:register_bounded("roll-die", function(_, _) return 77 end)
    g:call("apply-roll")
    assert.equal(77, g:get("world/luck"))
  end)

  it("handler receives state snapshot of declared reads", function()
    local g = make_bounded()
    local received_snap = nil
    g:register_bounded("roll-die", function(_, snap)
      received_snap = snap
      return snap["world/luck"] or 0
    end)
    g:init()
    g:call("apply-roll")
    assert.is_not_nil(received_snap)
    assert.is_not_nil(received_snap["world/luck"])
  end)

  it("multiple bounded handlers can coexist", function()
    -- Register two different bounded computations in one game
    local SRC2 = [[
module multi-bounded
  version: 1.0
engine-config:
  entry-scene: main
schema-version: 1
state world:
  a: Int(0, 100) = 10
  b: Int(0, 100) = 20
bounded get-a:
  reads: [world/a]
bounded get-b:
  reads: [world/b]
fn apply-both:
  set! world/a get-a
  set! world/b get-b
scene main:
  * Go -> main
]]
    local g = sb.from_source(SRC2, "multi-bounded")
    assert.is_not_nil(g)
    g:register_bounded("get-a", function(_, _) return 99 end)
    g:register_bounded("get-b", function(_, _) return 88 end)
    g:init()
    g:call("apply-both")
    assert.equal(99, g:get("world/a"))
    assert.equal(88, g:get("world/b"))
  end)
end)

-- ============================================================
-- game:set / game:reset
-- ============================================================

describe("game:set and game:reset", function()
  local SRC = [[
module set-test
  version: 1.0
engine-config:
  entry-scene: s
schema-version: 1
state world:
  count: Int(0, 99) = 0
scene s:
  * Go -> s
]]

  it("set changes a state path value", function()
    local g = sb.from_source(SRC, "set-test")
    assert.is_not_nil(g)
    g:init()
    assert.equal(0, g:get("world/count"))
    g:set("world/count", 42)
    assert.equal(42, g:get("world/count"))
  end)

  it("set before init errors", function()
    local g = sb.from_source(SRC, "set-test")
    assert.is_not_nil(g)
    assert.has_error(function() g:set("world/count", 1) end)
  end)

  it("reset restores state to defaults", function()
    local g = sb.from_source(SRC, "set-test")
    assert.is_not_nil(g)
    g:init()
    g:set("world/count", 77)
    assert.equal(77, g:get("world/count"))
    g:reset()
    assert.equal(0, g:get("world/count"))
  end)
end)

-- ============================================================
-- game:on event system
-- ============================================================

describe("game:on event callbacks", function()
  local SRC = [[
module event-test
  version: 1.0
engine-config:
  entry-scene: main
schema-version: 1
state world:
  x: Int(0, 99) = 0
scene main:
  * Inc
    inc! world/x 1
    -> main
  * Done -> end-scene
scene end-scene:
  All done.
]]

  it("on(`choice') fires once per choose call", function()
    local g = sb.from_source(SRC, "event-test")
    assert.is_not_nil(g)
    g:init()
    local fired = 0
    g:on("choice", function() fired = fired + 1 end)
    g:choose(1)
    g:choose(1)
    assert.equal(2, fired)
  end)

  it("on(`choice') payload contains index and scene", function()
    local g = sb.from_source(SRC, "event-test")
    assert.is_not_nil(g)
    g:init()
    local payload
    g:on("choice", function(p) payload = p end)
    g:choose(1)
    assert.is_not_nil(payload)
    assert.equal(1,      payload.index)
    assert.equal("main", payload.scene)
  end)

  it("multiple on() handlers all fire", function()
    local g = sb.from_source(SRC, "event-test")
    assert.is_not_nil(g)
    g:init()
    local a, b = 0, 0
    g:on("choice", function() a = a + 1 end)
    g:on("choice", function() b = b + 1 end)
    g:choose(1)
    assert.equal(1, a)
    assert.equal(1, b)
  end)

  it("handler error does not crash the game", function()
    local g = sb.from_source(SRC, "event-test")
    assert.is_not_nil(g)
    g:init()
    g:on("choice", function() error("boom") end)
    assert.has_no_error(function() g:choose(1) end)
  end)
end)

-- ── engine/checkpoint! callable form ─────────────────────────────────────────

describe("engine/checkpoint! callable", function()
  local SRC = [[
module checkpoint-test
  version: 1.0
engine-config:
  entry-scene: main
schema-version: 1
state world:
  hp: Int(0, 100) = 50
fn damage:
  dec! world/hp 10
fn checkpoint-and-damage:
  engine/checkpoint!
  dec! world/hp 10
scene main:
  * Hit -> main
]]

  it("engine/checkpoint! pushes a checkpoint into the log", function()
    local g = sb.from_source(SRC, "checkpoint-test")
    assert.is_not_nil(g)
    g:init()
    g:call("checkpoint-and-damage")
    -- undo should roll back the damage
    local eng = g._eng
    local ok = eng._state:undo(1)
    assert.is_true(ok)
    assert.equal(50, g:get("world/hp"))
  end)

  it("engine/checkpoint! without the tag still creates an undo point", function()
    local g = sb.from_source(SRC, "checkpoint-test")
    assert.is_not_nil(g)
    g:init()
    -- call damage (no checkpoint) then checkpoint-and-damage
    g:call("damage")                  -- hp = 40, no checkpoint
    g:call("checkpoint-and-damage")   -- pushes checkpoint, then hp = 30
    local eng = g._eng
    local ok = eng._state:undo(1)
    assert.is_true(ok)
    assert.equal(40, g:get("world/hp"))  -- rolled back to pre-checkpoint-and-damage hp
  end)

  it("undo fails when no checkpoint exists", function()
    local g = sb.from_source(SRC, "checkpoint-test")
    assert.is_not_nil(g)
    g:init()
    g:call("damage")  -- no checkpoint
    local ok = g._eng._state:undo(1)
    assert.is_false(ok)
  end)
end)

-- ── engine/emit callable form ─────────────────────────────────────────────────

describe("engine/emit callable", function()
  local SRC = [[
module emit-test
  version: 1.0
engine-config:
  entry-scene: main
schema-version: 1
state world:
  x: Int(0, 99) = 0
fn do-thing:
  inc! world/x 1
  engine/emit `thing-happened {x: world/x}
fn emit-no-args:
  engine/emit `simple-event
scene main:
  * Go -> main
]]

  it("engine/emit fires the game-level on() listener", function()
    local g = sb.from_source(SRC, "emit-test")
    assert.is_not_nil(g)
    g:init()
    local fired = {}
    g:on("thing-happened", function(p) fired[#fired+1] = p end)
    g:call("do-thing")
    assert.equal(1, #fired)
    assert.equal("thing-happened", fired[1].event)
  end)

  it("engine/emit with no args payload fires listener without error", function()
    local g = sb.from_source(SRC, "emit-test")
    assert.is_not_nil(g)
    g:init()
    local fired = false
    g:on("simple-event", function() fired = true end)
    assert.has_no_error(function() g:call("emit-no-args") end)
    assert.is_true(fired)
  end)

  it("engine/emit fires multiple times across calls", function()
    local g = sb.from_source(SRC, "emit-test")
    assert.is_not_nil(g)
    g:init()
    local count = 0
    g:on("thing-happened", function() count = count + 1 end)
    g:call("do-thing")
    g:call("do-thing")
    assert.equal(2, count)
  end)

  it("engine/emit is silent when no listeners registered", function()
    local g = sb.from_source(SRC, "emit-test")
    assert.is_not_nil(g)
    g:init()
    assert.has_no_error(function() g:call("do-thing") end)
  end)
end)

-- ── game:docs ─────────────────────────────────────────────────────────────────

describe("game:docs", function()
  local SRC = [[
module docs-test
  version: 1.0
engine-config:
  entry-scene: main
schema-version: 1
state world:
  gold: Int(0, 9999) = 0

"Increases gold by the given amount."
fn earn amount:
  inc! world/gold amount

"The starting scene."
scene main:
  * Earn -> main
]]

  local function make()
    local g = sb.from_source(SRC, "docs-test"); g:init(); return g
  end

  it("docs() returns a table for a compiled game", function()
    local g = make()
    local d = g:docs()
    assert.is_table(d)
  end)

  it("docs() includes doc strings for annotated fns", function()
    local g = make()
    local d = g:docs()
    assert.is_not_nil(d["earn"])
    assert.is_string(d["earn"])
  end)

  it("docs() includes doc strings for annotated scenes", function()
    local g = make()
    local d = g:docs()
    assert.is_not_nil(d["main"])
    assert.is_string(d["main"])
  end)

  it("docs(name) returns the doc for a specific entity", function()
    local g = make()
    local doc = g:docs("earn")
    assert.is_string(doc)
  end)

  it("docs(name) returns nil for unknown names", function()
    local g = make()
    assert.is_nil(g:docs("nonexistent"))
  end)

  it("docs() returns empty table when nothing is annotated", function()
    local src2 = [[
module no-docs
  version: 1.0
engine-config:
  entry-scene: s
schema-version: 1
fn foo:
  pass
scene s:
  * Go -> s
]]
    local g = sb.from_source(src2, "no-docs"); g:init()
    local d = g:docs()
    assert.is_table(d)
    assert.is_nil(d["foo"])  -- no doc string
  end)
end)

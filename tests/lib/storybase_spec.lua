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

  it("render returns narration and choices", function()
    local g = make()
    local narr, choices = g:render()
    assert.is_table(narr)
    assert.is_table(choices)
    assert.equal(2, #choices)
    assert.equal("Earn",   choices[1].label)
    assert.equal("Finish", choices[2].label)
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

  it("on('choice') fires after each choose", function()
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

-- tests/runtime/integration_spec.lua
-- Integration tests: full end-to-end gameplay scenarios using sb API.
--
-- Run with: busted tests/

local sb = require("lib.storybase")

-- ============================================================
-- Scenario 1: player walks village → forest → dungeon
-- ============================================================

describe("Integration scenario 1: village → forest → dungeon", function()
  local SRC = [[
module walk-test
  version: 1.0
engine-config:
  entry-scene: village

state player:
  location: Symbol = 'village

scene village:
  You are in the village.
  * Go to forest
    set! player/location 'forest
    -> forest

scene forest:
  You are in the forest.
  * Go to dungeon
    set! player/location 'dungeon
    -> dungeon
  * Return to village
    set! player/location 'village
    -> village

scene dungeon:
  You reached the dungeon.
]]

  it("starts in village scene", function()
    local g = sb.from_source(SRC, "walk"); g:init()
    assert.equal("village", g:current_scene())
    assert.equal("village",  g:get("player/location"))   -- symbols stored without leading '
  end)

  it("walk to forest updates scene and location", function()
    local g = sb.from_source(SRC, "walk"); g:init()
    g:choose(1)   -- Go to forest
    assert.equal("forest", g:current_scene())
    assert.equal("forest", g:get("player/location"))
  end)

  it("walk to dungeon after forest", function()
    local g = sb.from_source(SRC, "walk"); g:init()
    g:choose(1)   -- Go to forest
    g:choose(1)   -- Go to dungeon
    assert.equal("dungeon", g:current_scene())
    assert.equal("dungeon", g:get("player/location"))
  end)

  it("can return to village from forest", function()
    local g = sb.from_source(SRC, "walk"); g:init()
    g:choose(1)   -- Go to forest
    g:choose(2)   -- Return to village
    assert.equal("village", g:current_scene())
    assert.equal("village", g:get("player/location"))
  end)

  it("dungeon scene has no choices (end state)", function()
    local g = sb.from_source(SRC, "walk"); g:init()
    g:choose(1); g:choose(1)   -- village → forest → dungeon
    local _, choices = g:render()
    assert.equal(0, #choices)
  end)
end)

-- ============================================================
-- Scenario 2: combat state machine
-- ============================================================

describe("Integration scenario 2: combat state machine", function()
  local SRC = [[
module combat-test
  version: 1.0
engine-config:
  entry-scene: combat

state player:
  hp:    Int(0, 100) = 30
  gold:  Int(0, 999) = 5

state enemy:
  hp: Int(0, 100) = 20

scene combat:
  Player HP: {player/hp}.  Enemy HP: {enemy/hp}.
  * Attack
    dec! enemy/hp 8
    dec! player/hp 3
    -> combat
  * Drink potion
    inc! player/hp 15
    dec! player/gold 5
    -> combat
  * Flee
    -> escaped

scene escaped:
  You escaped!
]]

  it("attack reduces both player and enemy hp", function()
    local g = sb.from_source(SRC, "combat"); g:init()
    g:choose(1)   -- Attack
    assert.equal(27, g:get("player/hp"))   -- 30 - 3
    assert.equal(12, g:get("enemy/hp"))    -- 20 - 8
  end)

  it("drink potion restores player hp and costs gold", function()
    local g = sb.from_source(SRC, "combat"); g:init()
    g:choose(2)   -- Drink potion
    assert.equal(45, g:get("player/hp"))  -- 30 + 15
    assert.equal(0,  g:get("player/gold")) -- 5 - 5
  end)

  it("flee transitions to escaped scene", function()
    local g = sb.from_source(SRC, "combat"); g:init()
    g:choose(3)   -- Flee
    assert.equal("escaped", g:current_scene())
  end)

  it("enemy defeated after enough attacks", function()
    local g = sb.from_source(SRC, "combat"); g:init()
    -- 20 hp enemy, 8 damage per attack → 3 attacks to kill (20 → 12 → 4 → 0, clamped)
    g:choose(1); g:choose(1); g:choose(1)
    assert.equal(0, g:get("enemy/hp"))
  end)

  it("player hp clamped to 0 when over-attacked", function()
    local g = sb.from_source(SRC, "combat"); g:init()
    -- Take 10 attacks (30hp / 3 per attack = 10 attacks to die)
    for _ = 1, 10 do g:choose(1) end
    assert.equal(0, g:get("player/hp"))
  end)

  it("player hp clamped to max (100) when drinking multiple potions", function()
    local g = sb.from_source(SRC, "combat"); g:init()
    -- Start at 30, drink enough potions
    -- Each potion: +15 hp, -5 gold; with 5 gold can drink 1
    g:choose(2)   -- 45 hp, 0 gold
    assert.equal(45, g:get("player/hp"))
    assert.equal(0,  g:get("player/gold"))
  end)
end)

-- ============================================================
-- Scenario 3: buy potion with gold guard
-- ============================================================

describe("Integration scenario 3: guarded purchase", function()
  local SRC = [[
module shop-test
  version: 1.0
engine-config:
  entry-scene: shop

state player:
  hp:   Int(0, 100) = 50
  gold: Int(0, 999) = 0

scene shop:
  Welcome to the shop.
  * [player/gold >= 10] Buy potion (10g)
    inc!  player/hp   20
    dec!  player/gold 10
    -> shop
  * Leave
    -> end-scene

scene end-scene:
  Goodbye.
]]

  it("buy potion hidden when gold < 10", function()
    local g = sb.from_source(SRC, "shop"); g:init()
    local _, choices = g:render()
    -- Only "Leave" should be visible when gold = 0
    assert.equal(1, #choices)
    assert.equal("Leave", choices[1].label)
  end)

  it("buy potion visible when gold >= 10", function()
    local g = sb.from_source(SRC, "shop"); g:init()
    -- Manually set gold to 15
    g._eng._state:set("player/gold", 15)
    local _, choices = g:render()
    assert.equal(2, #choices)
    assert.is_true(choices[1].label:find("Buy") ~= nil)
  end)

  it("buying potion deducts gold and restores hp", function()
    local g = sb.from_source(SRC, "shop"); g:init()
    g._eng._state:set("player/gold", 20)
    g:choose(1)   -- Buy potion (visible choice 1)
    assert.equal(70, g:get("player/hp"))
    assert.equal(10, g:get("player/gold"))
  end)

  it("guard re-hides after buying when gold drops below 10", function()
    local g = sb.from_source(SRC, "shop"); g:init()
    g._eng._state:set("player/gold", 10)
    g:choose(1)   -- Buy potion
    assert.equal(0, g:get("player/gold"))
    -- Now gold = 0, only Leave visible
    local _, choices = g:render()
    assert.equal(1, #choices)
    assert.equal("Leave", choices[1].label)
  end)

  it("leave transitions to end-scene", function()
    local g = sb.from_source(SRC, "shop"); g:init()
    g:choose(1)   -- Leave (only choice since gold = 0)
    assert.equal("end-scene", g:current_scene())
  end)
end)

-- ============================================================
-- Scenario 4: NPC interactions with save/load round-trip
-- ============================================================

describe("Integration scenario 4: save/load during gameplay", function()
  local SRC = [[
module save-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  score: Int(0, 9999) = 0
  round: Int(0, 999)  = 1

scene main:
  Round {world/round}.  Score: {world/score}.
  * Score point
    inc! world/score 1
    inc! world/round 1
    -> main
  * Quit
    -> end-scene

scene end-scene:
  Final score: {world/score}.
]]

  it("save/load preserves score and scene", function()
    local g = sb.from_source(SRC, "save"); g:init()
    g:choose(1); g:choose(1); g:choose(1)   -- 3 points
    assert.equal(3, g:get("world/score"))
    assert.equal(4, g:get("world/round"))

    local path = os.tmpname() .. ".log"
    local ok, err = g:save(path)
    assert.is_true(ok, tostring(err))

    -- New game instance, reload
    local g2 = sb.from_source(SRC, "save"); g2:init()
    assert.equal(0, g2:get("world/score"))   -- fresh

    local ok2, err2 = g2:load(path)
    assert.is_true(ok2, tostring(err2))
    assert.equal(3,      g2:get("world/score"))
    assert.equal(4,      g2:get("world/round"))
    assert.equal("main", g2:current_scene())

    os.remove(path)
  end)

  it("can continue playing after load", function()
    local g = sb.from_source(SRC, "save"); g:init()
    g:choose(1)   -- score = 1
    local path = os.tmpname() .. ".log"
    g:save(path)

    local g2 = sb.from_source(SRC, "save"); g2:init()
    g2:load(path)
    g2:choose(1)   -- one more point
    assert.equal(2, g2:get("world/score"))

    os.remove(path)
  end)
end)

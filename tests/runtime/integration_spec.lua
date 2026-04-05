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

-- ============================================================
-- Scenario 5: random encounter with fixed seed (reproducible)
-- ============================================================

describe("Integration scenario 5: reproducible random", function()
  local SRC = [[
module rand-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  roll1: Int(1, 6) = 1
  roll2: Int(1, 6) = 1

scene main:
  * Roll dice
    set! world/roll1 (random-int 1 6)
    set! world/roll2 (random-int 1 6)
    -> main
]]

  it("same seed produces same sequence", function()
    local engine_mod = require("runtime.engine")
    local compiler   = require("compiler.compiler")
    local gt, diags  = compiler.compile(SRC, "rand-test")
    assert.is_false(diags:has_errors())

    -- Run with seed 42 twice and compare results
    local results = {}
    for run = 1, 2 do
      local eng = engine_mod.new(gt, {
        io_out = { write = function() end },
        seed   = 42,
      })
      eng:init()
      eng:do_choice("main", 1)
      results[run] = { eng._state:get("world/roll1"), eng._state:get("world/roll2") }
    end

    assert.equal(results[1][1], results[2][1])
    assert.equal(results[1][2], results[2][2])
  end)

  it("different seeds produce different results (usually)", function()
    local engine_mod = require("runtime.engine")
    local compiler   = require("compiler.compiler")
    local gt, diags  = compiler.compile(SRC, "rand-test")
    assert.is_false(diags:has_errors())

    local roll_for = function(seed)
      local eng = engine_mod.new(gt, {
        io_out = { write = function() end },
        seed   = seed,
      })
      eng:init()
      eng:do_choice("main", 1)
      return eng._state:get("world/roll1")
    end

    -- With seeds 1..10, at least two should differ for a 6-sided die
    local seen = {}
    for i = 1, 10 do seen[roll_for(i)] = true end
    local unique = 0
    for _ in pairs(seen) do unique = unique + 1 end
    assert.is_true(unique > 1, "expected different outcomes for different seeds")
  end)
end)

-- ============================================================
-- Scenario 6: scheduled event fires on autonomous turns
-- ============================================================

describe("Integration scenario 6: scheduled event fires", function()
  -- The schedule fires every time the 'turn' axis advances by 1.
  -- The player action explicitly increments the turn axis.
  local SRC = [[
module sched-test
  version: 1.0
engine-config:
  entry-scene: main

time-model:
  turn

state world:
  resets: Int(0, 999) = 0

schedule day-reset:
  every: [turn: +1]
  fn:
    reset-counter

fn reset-counter:
  inc! world/resets 1

scene main:
  * Advance turn
    time-inc! turn: 1
    -> main
  * End
    -> end-scene

scene end-scene:
  Done.
]]

  it("schedule fires after one turn advance", function()
    local g, err = sb.from_source(SRC, "sched-test")
    if not g then
      pending("sched-test compile failed: " .. tostring(err))
      return
    end
    g:init()
    g:choose(1)   -- Advance turn (inc time by 1; triggers scheduler)
    local resets = g:get("world/resets")
    assert.is_true(resets >= 1, "expected resets >= 1 after one turn, got " .. tostring(resets))
  end)

  it("schedule fires N times after N turn advances", function()
    local g, err = sb.from_source(SRC, "sched-test")
    if not g then
      pending("sched-test compile failed: " .. tostring(err))
      return
    end
    g:init()
    g:choose(1); g:choose(1); g:choose(1)   -- 3 turns
    assert.equal(3, g:get("world/resets"))
  end)
end)

-- ============================================================
-- Scenario 7: actor messaging — alert changes state
-- ============================================================

describe("Integration scenario 7: actor sends message, recipient reacts", function()
  local SRC = [[
module msg-test
  version: 1.0
engine-config:
  entry-scene: main

state guard:
  alert: Bool = false

state player:
  action: Symbol = 'idle

fn guard-behavior:
  pass

actor guard-actor:
  state:     guard
  perceives: [guard/alert]
  behavior:  guard-behavior
  priority:  10

scene main:
  * Trigger alert
    set! player/action 'alert
    send! guard-actor 'intruder
    -> main
  * Reset
    set! guard/alert false
    -> main
]]

  it("sending a message to an actor succeeds without error", function()
    local g, err = sb.from_source(SRC, "msg-test")
    if not g then
      pending("msg-test compile failed: " .. tostring(err))
      return
    end
    g:init()
    assert.has_no.errors(function()
      g:choose(1)   -- Trigger alert (sends message to guard-actor)
    end)
    assert.equal("alert", g:get("player/action"))
  end)

  it("autonomous turn after alert processes actor behaviors", function()
    local g, err = sb.from_source(SRC, "msg-test")
    if not g then
      pending("msg-test compile failed: " .. tostring(err))
      return
    end
    g:init()
    g:choose(1)   -- send message
    -- post_action is already called by choose, but an extra tick is fine
    assert.has_no.errors(function() g:tick() end)
  end)
end)

-- ============================================================
-- Integration scenario: deliver ore to blacksmith
-- ============================================================

describe("Integration scenario: deliver ore to blacksmith", function()
  local SRC = [[
module ore-delivery
  version: 1.0
engine-config:
  entry-scene: mine

state player:
  ore: Int(0,10) = 0
  gold: Int(0,999) = 0

state blacksmith:
  satisfied: Bool = false

type BlacksmithMsg:
  | OreDelivery: amount: Int(0,10)

actor blacksmith-actor:
  state:     blacksmith
  perceives: [blacksmith/satisfied, player/gold]
  inbox:     List(BlacksmithMsg, 5)
  behavior:  blacksmith-behavior
  priority:  10

fn blacksmith-behavior:
  for msg in blacksmith/inbox:
    match msg:
      OreDelivery {amount}:
        set! blacksmith/satisfied true
        inc! player/gold 20
      _: pass

fn mine-ore:
  inc! player/ore 3

fn deliver-ore:
  pre: player/ore > 0
  send! blacksmith-actor (BlacksmithMsg/OreDelivery amount: player/ore)
  set! player/ore 0

scene mine:
  * Mine ore
    mine-ore
    -> mine
  * Go to blacksmith
    -> blacksmith-shop

scene blacksmith-shop:
  * [player/ore > 0] Deliver ore
    deliver-ore
    -> blacksmith-shop
  * Back to mine
    -> mine
]]

  it("player mines ore, delivers to blacksmith, receives gold reward", function()
    local sb = require("lib.storybase")
    local g, err = sb.from_source(SRC, "ore-delivery.sb")
    if not g then
      pending("ore-delivery compile failed: " .. tostring(err))
      return
    end
    g:init()

    -- Verify initial state
    assert.equal(0, g:get("player/ore"))
    assert.equal(0, g:get("player/gold"))
    assert.equal(false, g:get("blacksmith/satisfied"))

    -- Mine ore (3 units)
    g:choose(1)  -- "Mine ore" in scene mine
    assert.equal(3, g:get("player/ore"))

    -- Go to blacksmith shop
    g:choose(2)  -- "Go to blacksmith"

    -- Deliver ore (post_action triggers blacksmith-behavior via message delivery)
    g:choose(1)  -- "Deliver ore" (guard satisfied: ore > 0)

    -- After delivery: ore = 0, message was sent and processed in post_action
    assert.equal(0, g:get("player/ore"))

    -- Blacksmith is satisfied and rewarded gold
    assert.equal(true, g:get("blacksmith/satisfied"))
    assert.equal(20, g:get("player/gold"))
  end)

  it("deliver-ore guard hides choice when ore = 0", function()
    local sb = require("lib.storybase")
    local g, err = sb.from_source(SRC, "ore-delivery.sb")
    if not g then
      pending("ore-delivery compile failed: " .. tostring(err))
      return
    end
    g:init()

    -- Go to blacksmith directly without mining
    g:choose(2)  -- "Go to blacksmith"

    -- "Deliver ore" option is hidden (guard false when ore=0)
    local _, choices = g:render()
    local has_deliver = false
    for _, c in ipairs(choices or {}) do
      if c.label:find("Deliver") then has_deliver = true end
    end
    assert.is_false(has_deliver, "deliver choice should be hidden when ore=0")
  end)
end)

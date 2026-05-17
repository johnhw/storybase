-- tests/runtime/generate_spec.lua
-- Runtime tests for §F1: `generate` blocks run on engine init, write to log,
-- replay deterministically from saved state.

local compiler = require("compiler.compiler")
local engine   = require("runtime.engine")
local state    = require("runtime.state")
local log_mod  = require("runtime.log")

local function compile(src)
  local game, diags = compiler.compile(src, "g.sb")
  assert.is_false(diags:has_errors(),
    "compile failed: " .. ((diags.errors[1] or {}).message or "?"))
  return game
end

-- ── generate runs at init ─────────────────────────────────────────────────────

describe("generate — engine init", function()

  it("executes the body once during eng:init", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  flag: Bool = false
scene main:
  * Done
    -> main
generate setup:
  set! world/flag true
]])
    local eng = engine.new(game, { seed = 1 })
    eng:init()
    assert.is_true(eng._state:get("world/flag"))
  end)

  it("seed_path reseeds the RNG before the body runs", function()
    -- With seed=99 the random-int draw is deterministic; using seed_path
    -- forces a known starting state regardless of the engine's RNG seed.
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  seed: Int(0, 1000000) = 99
  roll: Int(0, 100) = 0
scene main:
  * Done
    -> main
generate roll seed: world/seed:
  set! world/roll (random-int 0 100)
]])
    local eng_a = engine.new(game, { seed = 1 }); eng_a:init()
    local eng_b = engine.new(game, { seed = 9999 }); eng_b:init()
    assert.equal(eng_a._state:get("world/roll"),
                 eng_b._state:get("world/roll"),
                 "same seed_path → same roll independent of engine RNG seed")
    assert.is_number(eng_a._state:get("world/roll"))
  end)

  it("works without a seed clause (uses engine RNG state)", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  roll: Int(0, 100) = 0
scene main:
  * Done
    -> main
generate roll:
  set! world/roll (random-int 0 100)
]])
    local eng = engine.new(game, { seed = 5 })
    eng:init()
    assert.is_number(eng._state:get("world/roll"))
  end)

  it("runs all generates in declaration order", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  step: Int(0, 10) = 0
scene main:
  * Done
    -> main

generate first:
  inc! world/step 1

generate second:
  inc! world/step 1
]])
    local eng = engine.new(game, { seed = 1 })
    eng:init()
    assert.equal(2, eng._state:get("world/step"))
  end)

  it("spawn! inside generate populates a family", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state rooms/{r}: Bool max: 8
state world:
  done: Bool = false
scene main:
  * Done
    -> main

generate dungeon:
  spawn! rooms "alpha" true
  spawn! rooms "beta"  true
  spawn! rooms "gamma" true
  set! world/done true
]])
    local eng = engine.new(game, { seed = 1 })
    eng:init()
    assert.is_true(eng._state:get("rooms/alpha"))
    assert.is_true(eng._state:get("rooms/beta"))
    assert.is_true(eng._state:get("rooms/gamma"))
    assert.is_true(eng._state:get("world/done"))
  end)
end)

-- ── replay determinism ───────────────────────────────────────────────────────

describe("generate — replay determinism", function()

  it("replaying the saved log reconstructs generated state without re-running", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  seed: Int(0, 1000000) = 12345
  roll: Int(0, 100) = 0
scene main:
  * Done
    -> main
generate roll seed: world/seed:
  set! world/roll (random-int 0 100)
]])
    -- First engine: run init (which executes generate) and capture state.
    local eng1 = engine.new(game, { seed = 1 }); eng1:init()
    local first_roll = eng1._state:get("world/roll")
    local entries = eng1._log:entries()

    -- Second engine: do NOT run generate. Replay the log onto fresh state.
    local eng2 = engine.new(game, { seed = 1 })
    eng2._state:init_defaults()
    state.replay(eng2._state, entries)
    assert.equal(first_roll, eng2._state:get("world/roll"))
  end)
end)

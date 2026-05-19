-- tests/runtime/diff_replay_spec.lua
-- H2: diff-mode hot reload (runtime/diff_replay.lua) and the corresponding
-- debug command `get-replay-diff`.

local debug_mod    = require("runtime.debug")
local engine_mod   = require("runtime.engine")
local diff_mod     = require("runtime.diff_replay")
local compiler_mod = require("compiler.compiler")

local function compile(src)
  local result, diags = compiler_mod.compile(src, "test.sb")
  local errors = {}
  for _, d in ipairs(diags or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return result, errors
end

local function play(eng, choices_seq)
  for _, idx in ipairs(choices_seq) do
    local scene = eng:current_scene()
    local sig = eng:do_choice(scene, idx)
    eng:post_action()
    if sig then
      if sig.type == "goto" then eng:goto_scene(sig.target)
      elseif sig.type == "enter" then eng:enter_scene(sig.target)
      elseif sig.type == "exit" then eng:exit_scene() end
    end
  end
end

-- ============================================================
-- Choice logging (engine.do_choice records "choice" entries)
-- ============================================================

describe("diff-replay: choice logging", function()
  local SRC = [[
module choice-log-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  gold: Int(0, 999) = 0

scene main:
  * Earn 5
    inc! player/gold 5
    -> main
  * Earn 10
    inc! player/gold 10
    -> main
]]

  it("do_choice appends a choice entry with scene + idx", function()
    local gt = assert((compile(SRC)))
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    play(eng, { 1, 2, 1 })

    local choices = {}
    for _, e in ipairs(eng._log:entries()) do
      if e.kind == "choice" then choices[#choices + 1] = e end
    end
    assert.equal(3, #choices)
    assert.equal("main", choices[1].scene); assert.equal(1, choices[1].idx)
    assert.equal("main", choices[2].scene); assert.equal(2, choices[2].idx)
    assert.equal("main", choices[3].scene); assert.equal(1, choices[3].idx)
  end)

  it("choice entries are skipped on state.replay", function()
    local gt = assert((compile(SRC)))
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    play(eng, { 1, 2, 1 })
    -- Final gold should be 5 + 10 + 5 = 20
    assert.equal(20, eng._state:get("player/gold"))

    -- Build a fresh state and replay the log; choice markers must not crash
    -- or affect the cache. The result should be identical to the live state.
    local state_mod = require("runtime.state")
    local store = state_mod.new(gt.schema)
    store:init_defaults()
    state_mod.replay(store, eng._log:entries())
    assert.equal(20, store._cache["player/gold"])
  end)

  it("BFS engines (_in_bfs=true) do not record choice entries", function()
    local gt = assert((compile(SRC)))
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    eng._in_bfs = true
    play(eng, { 1, 1, 1 })

    for _, e in ipairs(eng._log:entries()) do
      assert.not_equal("choice", e.kind,
        "BFS engine should not produce choice entries")
    end
  end)
end)

-- ============================================================
-- diff_replay.replay — core algorithm
-- ============================================================

describe("diff-replay: core replay", function()
  -- "Halve damage" acceptance scenario for H2: a take-damage fn whose body
  -- changes between v1 and v2, run over a multi-turn playthrough.
  local SRC_V1 = [[
module dmg-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  health: Int(0, 100) = 100

fn take-damage amount:
  dec! player/health amount

scene main:
  * Take 10 damage
    take-damage 10
    -> main
  * Take 6 damage
    take-damage 6
    -> main
  * Rest
    -> main
]]

  local SRC_V2 = [[
module dmg-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  health: Int(0, 100) = 100

fn take-damage amount:
  dec! player/health (int-div amount 2)

scene main:
  * Take 10 damage
    take-damage 10
    -> main
  * Take 6 damage
    take-damage 6
    -> main
  * Rest
    -> main
]]

  it("identical source produces an empty diff", function()
    local gt = assert((compile(SRC_V1)))
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    play(eng, { 1, 1, 2, 3, 1 })

    local gt2 = assert((compile(SRC_V1)))
    local result = diff_mod.replay(eng, gt2, {})
    assert.is_true(result.ok)
    assert.equal(0, #result.diffs, "no divergence when source is unchanged")
    assert.equal(0, #result.final_diff)
    assert.is_nil(result.aborted)
  end)

  it("halved-damage edit reports divergence on health for each hit", function()
    local gt1 = assert((compile(SRC_V1)))
    local eng = engine_mod.new(gt1, { io_out = { write = function() end } })
    eng:init()

    -- Five hits: 10, 10, 6, rest, 10 → orig health: 100→90→80→74→74→64
    play(eng, { 1, 1, 2, 3, 1 })
    assert.equal(64, eng._state:get("player/health"))

    local gt2 = assert((compile(SRC_V2)))
    local result = diff_mod.replay(eng, gt2, {})
    assert.is_true(result.ok)
    assert.is_nil(result.aborted)

    -- New trajectory: each damage is halved (int-div by 2):
    -- 10→5, 10→5, 6→3, rest, 10→5  → 100→95→90→87→87→82
    -- Old vs New per tick: 90/95, 80/90, 74/87, 74/87, 64/82
    -- Tick 4 (rest) has the same (old, new) pair as tick 3, so it should NOT
    -- produce a fresh diff entry (prev_diff dedupe).
    local health_diffs = {}
    for _, d in ipairs(result.diffs) do
      if d.path == "player/health" then
        health_diffs[#health_diffs + 1] = d
      end
    end
    assert.equal(4, #health_diffs,
      "expected 4 unique health divergences (ticks 1, 2, 3, 5), got "
      .. #health_diffs)

    -- First divergence: old 90, new 95
    assert.equal("player/health", health_diffs[1].path)
    assert.equal(90, health_diffs[1].old_value)
    assert.equal(95, health_diffs[1].new_value)

    -- Dedupe check: no entry should have (74, 87) appearing twice
    local seen_74_87 = 0
    for _, d in ipairs(health_diffs) do
      if d.old_value == 74 and d.new_value == 87 then
        seen_74_87 = seen_74_87 + 1
      end
    end
    assert.equal(1, seen_74_87,
      "the (74, 87) pair should appear exactly once (dedupe)")

    -- Final diff: old 64, new 82
    local found_final = false
    for _, d in ipairs(result.final_diff) do
      if d.path == "player/health" then
        assert.equal(64, d.old_value)
        assert.equal(82, d.new_value)
        found_final = true
      end
    end
    assert.is_true(found_final, "final_diff should report player/health")
  end)

  it("reports choices_replayed and leaves the live engine untouched", function()
    local gt1 = assert((compile(SRC_V1)))
    local eng = engine_mod.new(gt1, { io_out = { write = function() end } })
    eng:init()
    play(eng, { 1, 2, 1 })  -- 10, 5, 10 → 75
    local pre_health = eng._state:get("player/health")
    local pre_seq    = eng._log:seq()

    local gt2 = assert((compile(SRC_V2)))
    local result = diff_mod.replay(eng, gt2, {})
    assert.is_true(result.ok)
    assert.equal(3, result.choices_replayed)

    -- Live engine is untouched.
    assert.equal(pre_health, eng._state:get("player/health"))
    assert.equal(pre_seq,    eng._log:seq())
  end)

  it("aborts with a marker when no choices were recorded", function()
    local gt = assert((compile(SRC_V1)))
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    -- No choices played

    local result = diff_mod.replay(eng, gt, {})
    assert.is_true(result.ok)
    assert.is_string(result.aborted)
    assert.truthy(result.aborted:find("no choices"))
  end)
end)

-- ============================================================
-- 50-tick acceptance: matches the spec criterion verbatim
-- ============================================================

describe("diff-replay: 50-tick acceptance scenario", function()
  -- Long playthrough (>= 50 ticks): repeatedly take damage until health
  -- saturates, then verify that halving damage produces divergence at every
  -- still-damaging tick.
  local SRC_V1 = [[
module long-play
  version: 1.0
engine-config:
  entry-scene: main

state player:
  health: Int(0, 100) = 100

fn take-damage amount:
  dec! player/health amount

scene main:
  * Hit me
    take-damage 2
    -> main
]]

  local SRC_V2 = [[
module long-play
  version: 1.0
engine-config:
  entry-scene: main

state player:
  health: Int(0, 100) = 100

fn take-damage amount:
  dec! player/health (int-div amount 2)

scene main:
  * Hit me
    take-damage 2
    -> main
]]

  it("50 hits + halve damage reports health divergence", function()
    local gt1 = assert((compile(SRC_V1)))
    local eng = engine_mod.new(gt1, { io_out = { write = function() end } })
    eng:init()

    local seq = {}
    for _ = 1, 50 do seq[#seq + 1] = 1 end
    play(eng, seq)
    -- Original: 50 hits × 2 = 100 damage, clamped at 0
    assert.equal(0, eng._state:get("player/health"))

    local gt2 = assert((compile(SRC_V2)))
    local result = diff_mod.replay(eng, gt2, {})
    assert.is_true(result.ok)
    assert.equal(50, result.choices_replayed)

    -- New trajectory: each hit takes 1 dmg (2/2). After 50 hits, health = 50.
    local found_final = false
    for _, d in ipairs(result.final_diff) do
      if d.path == "player/health" then
        assert.equal(0,  d.old_value)
        assert.equal(50, d.new_value)
        found_final = true
      end
    end
    assert.is_true(found_final)

    -- Per-tick diff: every health change while old hasn't clamped is unique.
    -- Old health: 98, 96, 94, ... 2, 0, 0, ... (clamped at tick 50)
    -- New health: 99, 98, 97, ... (decreasing by 1 per tick)
    -- A fresh diff entry is emitted whenever (old, new) changes — so for the
    -- first ~50 ticks every tick is a new (old, new) pair.
    local health_diff_count = 0
    for _, d in ipairs(result.diffs) do
      if d.path == "player/health" then
        health_diff_count = health_diff_count + 1
      end
    end
    assert.is_true(health_diff_count >= 49,
      "expected ~50 per-tick health divergences, got " .. health_diff_count)
  end)
end)

-- ============================================================
-- Random-draw replay: recorded results feed the new engine's RNG
-- ============================================================

describe("diff-replay: random replay", function()
  -- A choice that draws a random damage roll. The diff-mode replay must
  -- feed the *same* recorded random values into the new engine so behavior
  -- changes are attributable to fn-body edits, not random reseeding.
  local SRC_V1 = [[
module rnd-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  health: Int(0, 100) = 100

fn random-hit:
  let roll = random-int 1 10
  dec! player/health roll

scene main:
  * Hit
    random-hit
    -> main
]]

  local SRC_V2 = [[
module rnd-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  health: Int(0, 100) = 100

fn random-hit:
  let roll = random-int 1 10
  dec! player/health (int-div roll 2)

scene main:
  * Hit
    random-hit
    -> main
]]

  it("recorded random rolls replay deterministically into new engine", function()
    local gt1 = assert((compile(SRC_V1)))
    local eng = engine_mod.new(gt1, {
      io_out = { write = function() end },
      seed = 42,
    })
    eng:init()
    play(eng, { 1, 1, 1, 1, 1 })

    -- Collect the original random rolls.
    local rolls = {}
    for _, e in ipairs(eng._log:entries()) do
      if e.kind == "random" then rolls[#rolls + 1] = e.result end
    end
    assert.equal(5, #rolls, "expected 5 random rolls")

    local orig_total_damage = 0
    for _, r in ipairs(rolls) do orig_total_damage = orig_total_damage + r end
    assert.equal(100 - orig_total_damage, eng._state:get("player/health"))

    -- Re-run with halved damage. New engine must consume the SAME 5 rolls.
    local gt2 = assert((compile(SRC_V2)))
    local result = diff_mod.replay(eng, gt2, {})
    assert.is_true(result.ok)

    local new_total = 0
    for _, r in ipairs(rolls) do new_total = new_total + math.floor(r / 2) end
    local expected_new_health = 100 - new_total

    for _, d in ipairs(result.final_diff) do
      if d.path == "player/health" then
        assert.equal(100 - orig_total_damage, d.old_value)
        assert.equal(expected_new_health,     d.new_value)
      end
    end
  end)
end)

-- ============================================================
-- HTTP/debug command wiring
-- ============================================================

describe("debug command: get-replay-diff", function()
  local SRC_V1 = [[
module dmg-cmd-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  health: Int(0, 100) = 100

fn take-damage amount:
  dec! player/health amount

scene main:
  * Take 10
    take-damage 10
    -> main
]]

  local SRC_V2 = [[
module dmg-cmd-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  health: Int(0, 100) = 100

fn take-damage amount:
  dec! player/health (int-div amount 2)

scene main:
  * Take 10
    take-damage 10
    -> main
]]

  it("get-replay-diff returns diffs and final_diff", function()
    local gt1 = assert((compile(SRC_V1)))
    local eng = engine_mod.new(gt1, { io_out = { write = function() end } })
    eng:init()
    play(eng, { 1, 1, 1 })  -- 30 damage; health = 70

    local srv = debug_mod.new(eng)
    srv:start()
    local resp = srv:handle_command("get-replay-diff", { src = SRC_V2 })
    assert.is_true(resp.ok, tostring(resp.error))
    assert.equal(3, resp.choices_replayed)

    -- Final: old 70, new 85 (10→5 per hit, 3 hits = 15 damage)
    local found = false
    for _, d in ipairs(resp.final_diff) do
      if d.path == "player/health" then
        assert.equal(70, d.old_value)
        assert.equal(85, d.new_value)
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("get-replay-diff with compile error returns ok=false", function()
    local gt1 = assert((compile(SRC_V1)))
    local eng = engine_mod.new(gt1, { io_out = { write = function() end } })
    eng:init()
    play(eng, { 1 })

    local srv = debug_mod.new(eng)
    srv:start()
    local resp = srv:handle_command("get-replay-diff",
      { src = "this is not valid storybase" })
    assert.is_false(resp.ok)
    assert.truthy(resp.error)
  end)

  it("get-replay-diff missing src returns error", function()
    local gt1 = assert((compile(SRC_V1)))
    local eng = engine_mod.new(gt1, { io_out = { write = function() end } })
    eng:init()
    local srv = debug_mod.new(eng)
    srv:start()
    local resp = srv:handle_command("get-replay-diff", {})
    assert.truthy(resp.error)
  end)
end)

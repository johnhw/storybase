-- tests/runtime/engine_spec.lua
-- Unit tests for runtime/engine.lua: scene stack, rendering, turn lifecycle.
--
-- Run with:  busted tests/

local engine_mod  = require("runtime.engine")
local compiler_mod = require("compiler.compiler")

-- ============================================================
-- Helpers
-- ============================================================

--- Compile a .sb source string and return (game_table, errors).
local function compile(src)
  local result, diags = compiler_mod.compile(src, "test.sb")
  local errors = {}
  for _, d in ipairs(diags or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return result, errors
end

--- Build a capture output stream that records lines.
local function make_output()
  local lines = {}
  local stream = {
    write = function(self, s)
      -- Split on newlines and collect non-empty lines
      for line in s:gmatch("[^\n]+") do
        lines[#lines + 1] = line
      end
    end,
    lines = lines,
  }
  return stream
end

--- Build an input stream from a list of expected responses.
local function make_input(responses)
  local idx = 0
  return {
    read = function(self, _fmt)
      idx = idx + 1
      return responses[idx]
    end,
  }
end

-- ============================================================
-- Scene stack tests
-- ============================================================

describe("engine: scene stack", function()
  local game = {
    schema  = { engine_config = {}, states = {}, types = {}, relations = {} },
    fns     = {},
    scenes  = {},
    verifies = {},
    watches  = {},
  }

  it("current_scene returns nil before init", function()
    local eng = engine_mod.new(game)
    assert.is_nil(eng:current_scene())
  end)

  it("push_scene makes it current", function()
    local eng = engine_mod.new(game)
    eng:push_scene("room")
    assert.equal("room", eng:current_scene())
  end)

  it("pop_scene removes top and returns it", function()
    local eng = engine_mod.new(game)
    eng:push_scene("room")
    eng:push_scene("dungeon")
    local popped = eng:pop_scene()
    assert.equal("dungeon", popped)
    assert.equal("room", eng:current_scene())
  end)

  it("goto_scene replaces top of stack", function()
    local eng = engine_mod.new(game)
    eng:push_scene("room")
    eng:goto_scene("north-room")
    assert.equal("north-room", eng:current_scene())
  end)

  it("enter_scene pushes onto stack", function()
    local eng = engine_mod.new(game)
    eng:push_scene("room")
    eng:enter_scene("dungeon")
    assert.equal("dungeon", eng:current_scene())
    eng:exit_scene()
    assert.equal("room", eng:current_scene())
  end)

  it("push_scene errors on stack overflow", function()
    local small_game = {
      schema = { engine_config = { ["scene-stack-max"] = 3 }, states = {}, types = {}, relations = {} },
      fns = {}, scenes = {}, verifies = {}, watches = {},
    }
    local eng = engine_mod.new(small_game)
    eng:push_scene("a")
    eng:push_scene("b")
    eng:push_scene("c")
    assert.has_error(function() eng:push_scene("d") end)
  end)
end)

-- ============================================================
-- Integration: compile + run test02_choices.sb
-- ============================================================

describe("engine: test02_choices.sb end-to-end", function()
  local src_path = "tests/test02_choices.sb"

  local function load_src()
    local f = io.open(src_path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
  end

  local src = load_src()
  if not src then
    pending("test02_choices.sb not found — skipping")
    return
  end

  local game, errs = compile(src)

  it("test02 compiles without errors", function()
    assert.same({}, errs)
    assert.is_table(game)
  end)

  it("test02 has fns and scenes", function()
    assert.is_table(game.fns)
    assert.is_table(game.scenes)
    assert.is_not_nil(game.fns["pickup-key"])
    assert.is_not_nil(game.scenes["room"])
    assert.is_not_nil(game.scenes["north-room"])
  end)

  it("pickup-key fn is marked transaction", function()
    assert.is_true(game.fns["pickup-key"].is_transaction)
  end)

  it("room scene has choices", function()
    local eng = engine_mod.new(game)
    eng:init()
    local narration, choices = eng:render_scene("room")
    -- Before picking up key: should see "Pick up the key" and "Go north"
    assert.is_true(#choices >= 2)
    -- Find "Go north"
    local has_go_north = false
    for _, c in ipairs(choices) do
      if c.label:find("north") or c.label:find("North") then
        has_go_north = true
      end
    end
    assert.is_true(has_go_north)
  end)

  it("picking up key changes state", function()
    local eng = engine_mod.new(game)
    eng:init()

    -- Initial state: player/has-key = false
    assert.is_false(eng._state:get("player/has-key"))

    -- Choice 1 in room = "Pick up the key" (guard: not player/has-key)
    local _, choices = eng:render_scene("room")
    local pickup_idx = nil
    for _, c in ipairs(choices) do
      if c.label:find("Pick up") or c.label:find("key") then
        pickup_idx = c.index
      end
    end
    assert.is_not_nil(pickup_idx, "should find 'Pick up the key' choice")

    -- Execute the pickup choice (1 = first visible choice = "Pick up the key")
    local signal = eng:do_choice("room", 1)  -- visible index 1
    assert.is_true(eng._state:get("player/has-key"))
  end)

  it("after picking up key, 'Pick up the key' choice is hidden", function()
    local eng = engine_mod.new(game)
    eng:init()

    -- Pick up the key first
    eng:do_choice("room", 1)

    -- Now render again — "Pick up the key" should be gone
    local _, choices = eng:render_scene("room")
    for _, c in ipairs(choices) do
      assert.is_false(
        (c.label:find("Pick up") ~= nil),
        "should not see 'Pick up the key' after picking it up"
      )
    end
  end)

  it("scene transition: goto room returns 'goto' signal", function()
    local eng = engine_mod.new(game)
    eng:init()

    -- Execute "Pick up the key" → body ends with -> room
    local signal = eng:do_choice("room", 1)
    assert.is_not_nil(signal)
    assert.equal("goto", signal.type)
    assert.equal("room", signal.target)
  end)

  it("log records state change", function()
    local eng = engine_mod.new(game)
    eng:init()
    eng:do_choice("room", 1)
    local entries = eng._log:entries()
    -- At least the init defaults + pickup change
    local found = false
    for _, e in ipairs(entries) do
      if e.path == "player/has-key" and e.new == true then
        found = true
      end
    end
    assert.is_true(found, "log should contain player/has-key = true")
  end)

  it("north-room shows key-opened text when key held", function()
    local eng = engine_mod.new(game)
    eng:init()
    eng:do_choice("room", 1)  -- pick up key

    local narration, _ = eng:render_scene("north-room")
    local text = table.concat(narration, " ")
    assert.is_truthy(text:find("padlock") or text:find("chest") or text:find("springs") or text:find("nothing"))
  end)
end)

-- ============================================================
-- Computed goto (scene_goto in scene body with match expression)
-- ============================================================

describe("engine: computed goto in scene body", function()
  -- Minimal game with a dispatch scene that uses match to redirect
  local src = [[
module dispatch-test
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: hub

type Phase = a | b

state world:
  phase: Phase = 'a

scene hub:
  Hub scene.

  -> (match world/phase:
        'a: 'scene-a
        'b: 'scene-b)

scene scene-a:
  You are in A.

  * Go to B
    set! world/phase 'b
    -> hub

scene scene-b:
  You are in B.

  * Done
    -> hub
]]

  local game, errs = compile(src)

  it("dispatch game compiles without errors", function()
    assert.same({}, errs)
    assert.is_not_nil(game)
  end)

  it("render_scene returns nav_signal for computed goto", function()
    if not game then pending("compile failed"); return end
    local eng = engine_mod.new(game)
    eng:init()
    local narr, choices, signal = eng:render_scene("hub")
    assert.is_table(signal)
    assert.equal("goto", signal.type)
    assert.equal("scene-a", signal.target)
  end)

  it("step follows nav_signal and shows scene-a", function()
    if not game then pending("compile failed"); return end
    local out = make_output()
    local inp = make_input({ "1", "q" })
    local eng = engine_mod.new(game, { io_out = out, io_in = inp })
    eng:init()
    -- step 1: hub → redirects to scene-a (no input needed), then shows scene-a choices
    eng:step()
    -- Now current scene should be scene-a
    assert.equal("scene-a", eng:current_scene())
  end)
end)

-- ============================================================
-- Full interactive run (simulated)
-- ============================================================

describe("engine: simulated turn loop", function()
  local src_path = "tests/test02_choices.sb"
  local function load_src()
    local f = io.open(src_path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close(); return s
  end
  local src = load_src()
  if not src then pending("test02 not found"); return end

  it("completes 2-turn sequence without error", function()
    local game = compile(src)
    assert.is_not_nil(game)

    local out = make_output()
    -- Turn 1: pick up key (choice 1), Turn 2: quit
    local inp = make_input({ "1", "q" })

    local eng = engine_mod.new(game, { io_out = out, io_in = inp })
    eng:init()
    engine_mod.run(game, { io_out = out, io_in = inp })

    -- Should have output (narration + prompts)
    assert.is_true(#out.lines > 0)
  end)
end)

-- ============================================================
-- Save / load round-trip
-- ============================================================

describe("engine: save/load round-trip", function()
  local src = [[
module test-save
  version: 1.0
engine-config:
  entry-scene: main
state player/gold: Int(0,999) = 10
fn earn:
  inc! player/gold 50
scene main:
  * Earn gold
    earn
    -> main
  * Done
    -> main
]]

  it("state is identical after save then load", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs)

    local save_path = os.tmpname()

    -- First run: earn gold once, then save
    local out1 = make_output()
    local inp1 = { read = function(self, _)
      local seq = { "1", "q" }
      self._i = (self._i or 0) + 1
      return seq[self._i]
    end }
    engine_mod.run(gt, { io_out=out1, io_in=inp1, save_path=save_path })

    -- Second run: load from save
    local eng2 = engine_mod.new(gt, {})
    -- Load restores state via replay
    local state_mod = require("runtime.state")
    local log_mod   = require("runtime.log")
    local f = io.open(save_path, "r")
    assert.is_not_nil(f)
    local src2 = f:read("*a"); f:close()
    local fn = load(src2)
    assert.is_not_nil(fn)
    local save_data = fn()
    eng2._state:init_defaults()
    state_mod.replay(eng2._state, save_data.entries or {})

    -- Gold should be 60 (10 default + 50 earned)
    assert.equal(60, eng2._state:get("player/gold"))

    os.remove(save_path)
  end)
end)

-- ============================================================
-- undo! with checkpoint tags
-- ============================================================

describe("undo!", function()
  local src = [[
module undo-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 100

fn spend amount:
  tags:  [checkpoint]
  dec! world/gold amount

fn earn amount:
  tags:  [checkpoint]
  inc! world/gold amount

fn undo-last:
  undo!

scene main:
  * Go
    -> main
]]

  it("undo! reverts state to before the last checkpoint fn", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    assert.equal(100, eng._state:get("world/gold"))

    -- Call spend (checkpoint): gold → 70
    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, gt.fns, "test")
    eval_mod.call_fn("spend", {{ kind = "int_lit", value = 30 }}, ctx)
    assert.equal(70, eng._state:get("world/gold"))

    -- undo! should revert to 100
    eval_mod.call_fn("undo-last", {}, ctx)
    assert.equal(100, eng._state:get("world/gold"))
  end)

  it("undo! with multiple checkpoints reverts to the Nth one back", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, gt.fns, "test")

    -- spend 30 (checkpoint 1): gold → 70
    eval_mod.call_fn("spend", {{ kind = "int_lit", value = 30 }}, ctx)
    assert.equal(70, eng._state:get("world/gold"))

    -- earn 20 (checkpoint 2): gold → 90
    eval_mod.call_fn("earn", {{ kind = "int_lit", value = 20 }}, ctx)
    assert.equal(90, eng._state:get("world/gold"))

    -- undo! steps: 2 — reverts to before spend (100)
    eval_mod.eval_stmt({ kind = "undo_mut", steps = { kind = "int_lit", value = 2 } }, ctx)
    assert.equal(100, eng._state:get("world/gold"))
  end)

  it("undo! errors when no checkpoint exists", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local eval_mod = require("runtime.eval")
    local ctx = eval_mod.new_ctx(eng._state, gt.fns, "test")

    assert.has_error(function()
      eval_mod.eval_stmt({ kind = "undo_mut", steps = nil }, ctx)
    end)
  end)
end)

-- ============================================================
-- Integration scenario 8: undo! restores pre-death state
-- ============================================================

describe("engine: integration scenario 8 — undo restores pre-death state", function()
  local src = [[
module death-test
  version: 1.0
engine-config:
  entry-scene: combat

state player:
  health: Int(0, 100) = 50
  alive:  Bool        = true

fn take-damage amount:
  tags: [checkpoint]
  dec! player/health amount
  when player/health = 0:
    set! player/alive false

fn undo-death:
  undo!

scene combat:
  HP: {player/health}.
  [not player/alive] You died.

  * Take 50 damage
    take-damage 50
    -> combat

  * Undo last action
    undo-death
    -> combat
]]

  local gt, errs = compile(src)

  it("compiles without errors", function()
    assert.equal(0, #errs)
    assert.is_not_nil(gt)
  end)

  it("undo! after death restores health and alive flag", function()
    if not gt then pending("compile failed"); return end

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local eval_mod = require("runtime.eval")
    local ctx = eng:make_ctx("test")

    -- Initial state
    assert.equal(50, eng._state:get("player/health"))
    assert.equal(true, eng._state:get("player/alive"))

    -- Take 50 damage → health = 0, alive = false
    eval_mod.call_fn("take-damage", {{ kind = "int_lit", value = 50 }}, ctx)
    assert.equal(0, eng._state:get("player/health"))
    assert.equal(false, eng._state:get("player/alive"))

    -- undo! → restore to pre-damage state
    eval_mod.call_fn("undo-death", {}, ctx)
    assert.equal(50, eng._state:get("player/health"))
    assert.equal(true, eng._state:get("player/alive"))
  end)
end)

-- ============================================================
-- Integration scenario 10: save → migrate → reload → state identical
-- ============================================================

describe("engine: integration scenario 10 — save, migrate, reload", function()
  local src_v1 = [[
module migrate-test
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main

state world:
  score: Int(0, 9999) = 0

scene main:
  * Score point
    inc! world/score 1
    -> main
]]

  local src_v2 = [[
module migrate-test
  version: 1.0
schema-version: 2
engine-config:
  entry-scene: main

state world:
  score:  Int(0, 9999) = 0
  points: Int(0, 9999) = 0

migration 1 -> 2:
  rename world/score -> world/points

scene main:
  * Score point
    inc! world/points 1
    -> main
]]

  it("migrated save has correct value after reload", function()
    local gt1, errs1 = compile(src_v1)
    assert.equal(0, #errs1)
    local gt2, errs2 = compile(src_v2)
    assert.equal(0, #errs2)

    local save_path = os.tmpname()

    -- Run v1: score 3 points, then save
    local out = { write = function() end }
    local inp = { _i = 0, read = function(self, _)
      self._i = self._i + 1
      return ({ "1", "1", "1", "q" })[self._i]
    end }
    engine_mod.run(gt1, { io_out = out, io_in = inp, save_path = save_path })

    -- Load the save file raw to get entries
    local f = assert(io.open(save_path, "r"))
    local save_src = f:read("*a"); f:close()
    local fn = assert(load(save_src))
    local save_data = fn()

    -- Apply migration: v1 → v2
    local migrate_mod = require("runtime.migrate")
    local cache = {}
    for _, e in ipairs(save_data.entries or {}) do
      cache[e.path] = e["new"]
    end
    local diags = migrate_mod.migrate(cache, gt2.migrations, 1, 2, gt2)
    assert.equal(0, #(diags.errors or {}))

    -- world/score should be gone; world/points should be 3
    assert.is_nil(cache["world/score"])
    assert.equal(3, cache["world/points"])

    os.remove(save_path)
  end)
end)


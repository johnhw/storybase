-- tests/runtime/engine_spec.lua
-- Unit tests for runtime/engine.lua: scene stack, rendering, turn lifecycle.
--
-- Run with:  busted tests/

local engine_mod  = require("runtime.engine")
local compiler_mod = require("compiler.compiler")
local config       = require("runtime.config")

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

--- Flatten a structured narration list to a single space-joined text string.
local function narr_text(narr)
  local parts = {}
  for _, item in ipairs(narr) do
    parts[#parts + 1] = (type(item) == "table" and item.text) or tostring(item)
  end
  return table.concat(parts, " ")
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
-- Config-resolved scene-stack-max (L2 pilot migration)
-- ============================================================

describe("engine: scene-stack-max via config module", function()
  local empty_game = {
    schema  = { engine_config = {}, states = {}, types = {}, relations = {} },
    fns     = {}, scenes = {}, verifies = {}, watches = {},
  }

  -- Construction triggers idempotent declare; clear runtime/game layers
  -- between specs so they don't leak.
  before_each(function()
    if config.spec("engine.scene-stack-max") then
      config.set("engine.scene-stack-max", nil)
    end
  end)
  after_each(function()
    if config.spec("engine.scene-stack-max") then
      config.set("engine.scene-stack-max", nil)
    end
  end)

  it("uses the registry default when no override is present", function()
    local eng = engine_mod.new(empty_game)
    assert.equal(16, eng._max_stack)
    local _, layer = config.get("engine.scene-stack-max")
    assert.equal("default", layer)
  end)

  it("picks up engine-config: block from the game (game layer)", function()
    local game = {
      schema = { engine_config = { ["scene-stack-max"] = 7 },
                 states = {}, types = {}, relations = {} },
      fns = {}, scenes = {}, verifies = {}, watches = {},
    }
    local eng = engine_mod.new(game)
    assert.equal(7, eng._max_stack)
    local v, layer = config.get("engine.scene-stack-max")
    assert.equal(7, v)
    assert.equal("game", layer)
  end)

  it("config.set at runtime overrides the engine-config: block", function()
    local game = {
      schema = { engine_config = { ["scene-stack-max"] = 7 },
                 states = {}, types = {}, relations = {} },
      fns = {}, scenes = {}, verifies = {}, watches = {},
    }
    config.set("engine.scene-stack-max", 4)
    local eng = engine_mod.new(game)
    assert.equal(4, eng._max_stack)
    local _, layer = config.get("engine.scene-stack-max")
    assert.equal("runtime", layer)
  end)

  it("opts.max_stack still wins as a per-instance escape hatch", function()
    local game = {
      schema = { engine_config = { ["scene-stack-max"] = 7 },
                 states = {}, types = {}, relations = {} },
      fns = {}, scenes = {}, verifies = {}, watches = {},
    }
    local eng = engine_mod.new(game, { max_stack = 2 })
    assert.equal(2, eng._max_stack)
    -- config state itself is unchanged: game layer still reports 7
    local v = config.get("engine.scene-stack-max")
    assert.equal(7, v)
  end)
end)

-- ============================================================
-- Engine-config network keys: engine.debug-port + engine.http-port (L6a)
-- These keys are declared by engine.lua but consumed only by the CLI
-- (`cli/main.lua` for --debug / --serve / --http-port). Spec just verifies
-- the declarations + the layered resolution that cli/main.lua relies on.
-- ============================================================

describe("engine: debug-port + http-port declarations", function()
  before_each(function()
    if config.spec("engine.debug-port") then config.set("engine.debug-port", nil) end
    if config.spec("engine.http-port")  then config.set("engine.http-port",  nil) end
    config.bind_cli(nil)
    config.bind_game(nil)
  end)
  after_each(function()
    if config.spec("engine.debug-port") then config.set("engine.debug-port", nil) end
    if config.spec("engine.http-port")  then config.set("engine.http-port",  nil) end
    config.bind_cli(nil)
    config.bind_game(nil)
  end)

  it("declares engine.debug-port with default 7373", function()
    assert.is_truthy(config.spec("engine.debug-port"))
    local v, layer = config.get("engine.debug-port")
    assert.equal(7373, v)
    assert.equal("default", layer)
  end)

  it("declares engine.http-port with no default (unset until layered)", function()
    assert.is_truthy(config.spec("engine.http-port"))
    local v, layer = config.get("engine.http-port")
    assert.is_nil(v)
    assert.equal("unset", layer)
  end)

  it("game layer (engine-config block) overrides default debug-port", function()
    local game = {
      schema = {
        engine_config = { ["debug-port"] = 9999 },
        states = {}, types = {}, relations = {},
      },
      fns = {}, scenes = {}, verifies = {}, watches = {},
      actors = {}, schedules = {}, generates = {},
    }
    config.bind_game(game)
    local v, layer = config.get("engine.debug-port")
    assert.equal(9999, v)
    assert.equal("game", layer)
  end)

  it("set_cli (CLI flag path) wins over game layer", function()
    local game = {
      schema = {
        engine_config = { ["debug-port"] = 9999, ["http-port"] = 9000 },
        states = {}, types = {}, relations = {},
      },
      fns = {}, scenes = {}, verifies = {}, watches = {},
      actors = {}, schedules = {}, generates = {},
    }
    config.bind_game(game)
    config.set_cli("engine.http-port", 17000)
    assert.equal(17000, config.get("engine.http-port"))
    -- debug-port unchanged
    assert.equal(9999, config.get("engine.debug-port"))
  end)
end)

-- ============================================================
-- network.bind: cross-cutting CLI-only key (L6b). Declared in
-- runtime/engine.lua's declare helper even though it's not engine.*
-- because the engine module is universally loaded by both the CLI
-- and serve-api code paths.
-- ============================================================

describe("network.bind declaration", function()
  before_each(function()
    if config.spec("network.bind") then config.set("network.bind", nil) end
    config.bind_cli(nil)
  end)
  after_each(function()
    if config.spec("network.bind") then config.set("network.bind", nil) end
    config.bind_cli(nil)
  end)

  it("declares network.bind with default 127.0.0.1", function()
    assert.is_truthy(config.spec("network.bind"))
    local v, layer = config.get("network.bind")
    assert.equal("127.0.0.1", v)
    assert.equal("default", layer)
  end)

  it("set_cli overrides default", function()
    config.set_cli("network.bind", "0.0.0.0")
    assert.equal("0.0.0.0", config.get("network.bind"))
  end)

  it("is NOT auto-bound from .sb engine-config block", function()
    -- Confirm the namespacing decision: engine-config: bind: ... in the
    -- .sb source would map to engine.bind (not declared), so the registry
    -- ignores it. network.bind stays CLI-only.
    local game = {
      schema = {
        engine_config = { bind = "0.0.0.0" },
        states = {}, types = {}, relations = {},
      },
      fns = {}, scenes = {}, verifies = {}, watches = {},
      actors = {}, schedules = {}, generates = {},
    }
    config.bind_game(game)
    assert.equal("127.0.0.1", config.get("network.bind"))
  end)
end)

-- ============================================================
-- cli.ui: enum-typed UI driver default (L6c)
-- ============================================================

describe("cli.ui declaration", function()
  before_each(function()
    if config.spec("cli.ui") then config.set("cli.ui", nil) end
    config.bind_cli(nil)
  end)
  after_each(function()
    if config.spec("cli.ui") then config.set("cli.ui", nil) end
    config.bind_cli(nil)
  end)

  it("declares cli.ui with default plain", function()
    assert.is_truthy(config.spec("cli.ui"))
    local v, layer = config.get("cli.ui")
    assert.equal("plain", v)
    assert.equal("default", layer)
  end)

  it("accepts the documented enum values", function()
    config.set_cli("cli.ui", "ansi")
    assert.equal("ansi", config.get("cli.ui"))
    config.set_cli("cli.ui", "plain")
    assert.equal("plain", config.get("cli.ui"))
  end)

  it("rejects values outside the enum (defends against package.path traversal)", function()
    assert.has_error(function() config.set_cli("cli.ui", "../../evil") end)
    assert.has_error(function() config.set_cli("cli.ui", "fancy") end)
  end)
end)

-- ============================================================
-- serve-api.port (L6d) — declared in engine.lua but consumed only by
-- cli/serve_api_cmd.lua.
-- ============================================================

describe("serve-api.port declaration", function()
  before_each(function()
    if config.spec("serve-api.port") then config.set("serve-api.port", nil) end
    config.bind_cli(nil)
  end)
  after_each(function()
    if config.spec("serve-api.port") then config.set("serve-api.port", nil) end
    config.bind_cli(nil)
  end)

  it("declares serve-api.port with default 8080", function()
    assert.is_truthy(config.spec("serve-api.port"))
    local v, layer = config.get("serve-api.port")
    assert.equal(8080, v)
    assert.equal("default", layer)
  end)

  it("coerces string values to int", function()
    config.set_cli("serve-api.port", "9090")
    assert.equal(9090, config.get("serve-api.port"))
  end)
end)

-- ============================================================
-- fuzz.* defaults (L6e) — declared in engine.lua but consumed only by
-- cli/fuzz_cmd.lua.
-- ============================================================

describe("fuzz.* declarations", function()
  local fuzz_keys = {
    "fuzz.runs", "fuzz.max-steps", "fuzz.failures-dir", "fuzz.max-failures",
  }
  before_each(function()
    for _, k in ipairs(fuzz_keys) do
      if config.spec(k) then config.set(k, nil) end
    end
    config.bind_cli(nil)
  end)
  after_each(function()
    for _, k in ipairs(fuzz_keys) do
      if config.spec(k) then config.set(k, nil) end
    end
    config.bind_cli(nil)
  end)

  it("declares all four keys with the historic defaults", function()
    assert.equal(1000,       config.get("fuzz.runs"))
    assert.equal(50,         config.get("fuzz.max-steps"))
    assert.equal("failures", config.get("fuzz.failures-dir"))
    assert.equal(10,         config.get("fuzz.max-failures"))
  end)

  it("set_cli overrides default for each key", function()
    config.set_cli("fuzz.runs",          "5")
    config.set_cli("fuzz.max-steps",     "7")
    config.set_cli("fuzz.failures-dir",  "/tmp/fuzz-fails")
    config.set_cli("fuzz.max-failures",  "3")
    assert.equal(5,                 config.get("fuzz.runs"))
    assert.equal(7,                 config.get("fuzz.max-steps"))
    assert.equal("/tmp/fuzz-fails", config.get("fuzz.failures-dir"))
    assert.equal(3,                 config.get("fuzz.max-failures"))
  end)
end)

-- ============================================================
-- coverage.* defaults (L6f) — declared in engine.lua, consumed by
-- cli/coverage_cmd.lua.
-- ============================================================

describe("coverage.* declarations", function()
  local cov_keys = { "coverage.depth", "coverage.budget" }
  before_each(function()
    for _, k in ipairs(cov_keys) do
      if config.spec(k) then config.set(k, nil) end
    end
    config.bind_cli(nil)
  end)
  after_each(function()
    for _, k in ipairs(cov_keys) do
      if config.spec(k) then config.set(k, nil) end
    end
    config.bind_cli(nil)
  end)

  it("declares depth + budget with the historic defaults", function()
    assert.equal(8,  config.get("coverage.depth"))
    assert.equal(30, config.get("coverage.budget"))
  end)

  it("set_cli overrides each key", function()
    config.set_cli("coverage.depth",  "12")
    config.set_cli("coverage.budget", "60")
    assert.equal(12, config.get("coverage.depth"))
    assert.equal(60, config.get("coverage.budget"))
  end)
end)

-- ============================================================
-- engine.max-counterfactual-depth (L7a) — closes the L3 carve-off.
-- Declared in engine.lua, consumed by runtime/eval.lua's
-- COUNTERFACTUAL_EXPR branch via config.get.
-- ============================================================

describe("engine.max-counterfactual-depth declaration", function()
  before_each(function()
    if config.spec("engine.max-counterfactual-depth") then
      config.set("engine.max-counterfactual-depth", nil)
    end
    config.bind_cli(nil)
    config.bind_game(nil)
  end)
  after_each(function()
    if config.spec("engine.max-counterfactual-depth") then
      config.set("engine.max-counterfactual-depth", nil)
    end
    config.bind_cli(nil)
    config.bind_game(nil)
  end)

  it("declares the key with default 10", function()
    assert.is_truthy(config.spec("engine.max-counterfactual-depth"))
    local v, layer = config.get("engine.max-counterfactual-depth")
    assert.equal(10, v)
    assert.equal("default", layer)
  end)

  it("game layer (engine-config block) overrides default", function()
    local game = {
      schema = {
        engine_config = { ["max-counterfactual-depth"] = 3 },
        states = {}, types = {}, relations = {},
      },
      fns = {}, scenes = {}, verifies = {}, watches = {},
      actors = {}, schedules = {}, generates = {},
    }
    config.bind_game(game)
    local v, layer = config.get("engine.max-counterfactual-depth")
    assert.equal(3, v)
    assert.equal("game", layer)
  end)

  it("set_cli wins over game layer (CLI override path)", function()
    local game = {
      schema = {
        engine_config = { ["max-counterfactual-depth"] = 3 },
        states = {}, types = {}, relations = {},
      },
      fns = {}, scenes = {}, verifies = {}, watches = {},
      actors = {}, schedules = {}, generates = {},
    }
    config.bind_game(game)
    config.set_cli("engine.max-counterfactual-depth", 20)
    assert.equal(20, config.get("engine.max-counterfactual-depth"))
  end)
end)

-- ============================================================
-- Config-resolved entry-scene and npc-speed (L3 sweep)
-- ============================================================

describe("engine: entry-scene via config module", function()
  before_each(function()
    if config.spec("engine.entry-scene") then
      config.set("engine.entry-scene", nil)
    end
  end)
  after_each(function()
    if config.spec("engine.entry-scene") then
      config.set("engine.entry-scene", nil)
    end
  end)

  local function bare_game(ec)
    return {
      schema = { engine_config = ec or {}, states = {}, types = {}, relations = {} },
      fns = {}, scenes = {}, verifies = {}, watches = {},
      actors = {}, schedules = {}, generates = {},
    }
  end

  it("init pushes engine-config: entry-scene onto the stack", function()
    local eng = engine_mod.new(bare_game({ ["entry-scene"] = "lobby" }))
    eng:init()
    assert.equal("lobby", eng:current_scene())
    local _, layer = config.get("engine.entry-scene")
    assert.equal("game", layer)
  end)

  it("config.set runtime override wins over the game block", function()
    config.set("engine.entry-scene", "alt-start")
    local eng = engine_mod.new(bare_game({ ["entry-scene"] = "lobby" }))
    eng:init()
    assert.equal("alt-start", eng:current_scene())
    local _, layer = config.get("engine.entry-scene")
    assert.equal("runtime", layer)
  end)

  it("init leaves the stack empty when no entry-scene is configured", function()
    local eng = engine_mod.new(bare_game())
    eng:init()
    assert.is_nil(eng:current_scene())
  end)
end)

describe("engine: npc-speed via config module", function()
  before_each(function()
    if config.spec("engine.npc-speed") then
      config.set("engine.npc-speed", nil)
    end
  end)
  after_each(function()
    if config.spec("engine.npc-speed") then
      config.set("engine.npc-speed", nil)
    end
  end)

  local function bare_game(ec)
    return {
      schema = { engine_config = ec or {}, states = {}, types = {}, relations = {} },
      fns = {}, scenes = {}, verifies = {}, watches = {},
      actors = {}, schedules = {}, generates = {},
    }
  end

  it("post_action_chain runs npc-speed extra turns (default = 0)", function()
    local eng = engine_mod.new(bare_game())
    local count = 0
    eng.post_action = function() count = count + 1 end
    eng:post_action_chain()
    assert.equal(1, count)  -- one base call only
    local v, layer = config.get("engine.npc-speed")
    assert.equal(0, v)
    assert.equal("default", layer)
  end)

  it("post_action_chain honours engine-config: npc-speed = N", function()
    local eng = engine_mod.new(bare_game({ ["npc-speed"] = 3 }))
    local count = 0
    eng.post_action = function() count = count + 1 end
    eng:post_action_chain()
    assert.equal(4, count)  -- 1 base + 3 extras
    local _, layer = config.get("engine.npc-speed")
    assert.equal("game", layer)
  end)

  it("config.set npc-speed beats the game block at runtime", function()
    config.set("engine.npc-speed", 1)
    local eng = engine_mod.new(bare_game({ ["npc-speed"] = 5 }))
    local count = 0
    eng.post_action = function() count = count + 1 end
    eng:post_action_chain()
    assert.equal(2, count)  -- 1 base + 1 extra (runtime layer wins)
    local v, layer = config.get("engine.npc-speed")
    assert.equal(1, v)
    assert.equal("runtime", layer)
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
    assert.is_not_nil(pickup_idx, "should find `Pick up the key' choice")

    -- Execute the pickup choice (1 = first visible choice = "Pick up the key")
    local signal = eng:do_choice("room", 1)  -- visible index 1
    assert.is_true(eng._state:get("player/has-key"))
  end)

  it("after picking up key, `Pick up the key' choice is hidden", function()
    local eng = engine_mod.new(game)
    eng:init()

    -- Pick up the key first
    eng:do_choice("room", 1)

    -- Now render again — "Pick up the key" should be gone
    local _, choices = eng:render_scene("room")
    for _, c in ipairs(choices) do
      assert.is_false(
        (c.label:find("Pick up") ~= nil),
        "should not see `Pick up the key' after picking it up"
      )
    end
  end)

  it("scene transition: goto room returns `goto' signal", function()
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
    local text = narr_text(narration)
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
  phase: Phase = `a

scene hub:
  Hub scene.

  -> (match world/phase:
        `a: `scene-a
        `b: `scene-b)

scene scene-a:
  You are in A.

  * Go to B
    set! world/phase `b
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
      -- Skip marker entries (choice, random, checkpoint) that lack a path.
      if e.path then cache[e.path] = e["new"] end
    end
    local diags = migrate_mod.migrate(cache, gt2.migrations, 1, 2, gt2)
    assert.equal(0, #(diags.errors or {}))

    -- world/score should be gone; world/points should be 3
    assert.is_nil(cache["world/score"])
    assert.equal(3, cache["world/points"])

    os.remove(save_path)
  end)
end)

-- ============================================================
-- Autonomous turns (steps 2–6 without player input)
-- ============================================================

describe("engine: autonomous turns", function()
  local src = [[
module auto-test
  version: 1.0
engine-config:
  entry-scene: main

time-model:
  axes: [tick]
  wrap: [none]

state world:
  tick: Int(0, 9999) = 0

actor ticker:
  state:     world
  perceives: [world/tick]
  inbox:     List(Int(0,9), 2)
  behavior:  ticker-fn
  priority:  1

fn ticker-fn:
  inc! world/tick 1

scene main:
  * Wait
    -> main
]]

  local gt, errs = compile(src)

  it("compiles without errors", function()
    assert.equal(0, #errs)
    assert.is_not_nil(gt)
  end)

  it("autonomous_turn runs actor behaviors without player input", function()
    if not gt then pending("compile failed"); return end

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    assert.equal(0, eng._state:get("world/tick"))

    -- One autonomous turn → ticker-fn runs → tick increments
    eng:autonomous_turn()
    assert.equal(1, eng._state:get("world/tick"))

    -- Another autonomous turn
    eng:autonomous_turn()
    assert.equal(2, eng._state:get("world/tick"))
  end)
end)

-- ============================================================
-- Bounded computation: random_draw log entry
-- ============================================================

describe("engine: bounded computation logs random_draw entry", function()

  local src = [[
module bounded-log-test
  version: 1.0
engine-config:
  entry-scene: main
state world:
  roll: Int(1, 6) = 1
bounded roll-die:
  distribution: uniform
  returns: Int(1, 6)
scene main:
  * Roll
    set! world/roll (roll-die)
    -> main
]]

  it("appends a random_draw log entry when bounded fn is called", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs)

    local io_out = { write = function() end }
    local eng = engine_mod.new(gt, { io_out = io_out })
    -- Register the bounded handler to return 4
    gt._bounded_handlers = gt._bounded_handlers or {}
    gt._bounded_handlers["roll-die"] = function(_arg, _snap) return 4 end
    eng:init()
    eng:do_choice("main", 1)  -- choice "Roll"

    -- Find a random_draw entry in the log
    local found
    for _, entry in ipairs(eng._state._log._entries or {}) do
      if entry.kind == "random_draw" and entry.source == "roll-die" then
        found = entry
        break
      end
    end
    assert.is_not_nil(found, "expected random_draw log entry for roll-die")
    assert.equal(4, found.result)
  end)

end)

-- ============================================================
-- => (enter) and <- (exit) navigation
-- ============================================================

describe("engine: => enter and <- exit navigation", function()

  local src = [[
module nav-test
  version: 1.0
engine-config:
  entry-scene: lobby
state world:
  visited: Bool = false
scene lobby:
  Welcome to the lobby.
  * Enter shop
    => shop
scene shop:
  You are in the shop.
  * Leave shop
    <-
]]

  local function make_eng()
    local gt, errs = compile(src)
    assert.equal(0, #errs, "compile errors: " .. tostring(errs[1] and errs[1].message))
    local io_out = { write = function() end }
    local eng = engine_mod.new(gt, { io_out = io_out })
    eng:init()
    return eng
  end

  it("=> choice returns `enter' signal with target", function()
    local eng = make_eng()
    local signal = eng:do_choice("lobby", 1)
    assert.is_not_nil(signal)
    assert.equal("enter", signal.type)
    assert.equal("shop",  signal.target)
  end)

  it("after enter_scene, current_scene is the pushed scene", function()
    local eng = make_eng()
    local signal = eng:do_choice("lobby", 1)
    eng:enter_scene(signal.target)
    assert.equal("shop", eng:current_scene())
  end)

  it("stack has two entries after push", function()
    local eng = make_eng()
    eng:enter_scene("shop")
    assert.equal(2, #eng._scene_stack)
  end)

  it("<- choice returns `exit' signal", function()
    local eng = make_eng()
    eng:enter_scene("shop")
    local signal = eng:do_choice("shop", 1)
    assert.is_not_nil(signal)
    assert.equal("exit", signal.type)
  end)

  it("exit_scene restores previous scene", function()
    local eng = make_eng()
    eng:enter_scene("shop")
    eng:exit_scene()
    assert.equal("lobby", eng:current_scene())
  end)

  it("exit_scene on single-scene stack does not error and leaves empty stack", function()
    local eng = make_eng()
    eng:exit_scene()  -- pops the only scene
    -- stack is now empty — current_scene returns nil
    assert.is_nil(eng:current_scene())
  end)

end)

-- ============================================================
-- Conditional narration (if/else in scene body)
-- ============================================================

describe("engine: conditional narration in scene body", function()

  local src = [[
module cond-narr
  version: 1.0
engine-config:
  entry-scene: room
state world:
  flag: Bool = false
scene room:
  if world/flag:
    Flag is set.
  else:
    Flag is not set.
  * Toggle
    set! world/flag true
    -> room
  * Nothing -> room
]]

  local function make_eng()
    local gt, errs = compile(src)
    assert.equal(0, #errs, "compile errors: " .. tostring(errs[1] and errs[1].message))
    local io_out = { write = function() end }
    local eng = engine_mod.new(gt, { io_out = io_out })
    eng:init()
    return eng
  end

  it("renders else branch when flag is false", function()
    local eng = make_eng()
    local narr = eng:render_scene("room")
    local text = narr_text(narr)
    assert.is_truthy(text:find("not set"))
  end)

  it("renders then branch after flag is set", function()
    local eng = make_eng()
    eng:do_choice("room", 1)  -- Toggle sets flag=true
    local narr = eng:render_scene("room")
    local text = narr_text(narr)
    assert.is_falsy(text:find("not set"))
    assert.is_truthy(text:find("Flag is set"))
  end)

end)

-- ============================================================
-- post_action: actor behaviors run after do_choice
-- ============================================================

describe("engine: post_action runs actor behaviors", function()

  local src = [[
module post-act-test
  version: 1.0
engine-config:
  entry-scene: main
state world:
  counter: Int(0, 99) = 0
actor inc-actor:
  priority: 1
  perceives: []
  behavior: inc-fn
fn inc-fn:
  inc! world/counter 1
scene main:
  * Tick -> main
]]

  it("post_action increments counter via actor behavior", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs, "compile errors")
    local io_out = { write = function() end }
    local eng = engine_mod.new(gt, { io_out = io_out })
    eng:init()
    assert.equal(0, eng._state:get("world/counter"))
    eng:post_action()
    assert.equal(1, eng._state:get("world/counter"))
    eng:post_action()
    assert.equal(2, eng._state:get("world/counter"))
  end)

end)

-- ============================================================
-- npc-speed: extra post_action passes per player turn
-- ============================================================

-- ============================================================
-- for_stmt in scene body narration
-- ============================================================

describe("engine: for loop in scene body narration", function()

  local src = [[
module for-narr-test
  version: 1.0
engine-config:
  entry-scene: main
state bag:
  items: UList(String) = []
fn add-item item:
  push! bag/items item
scene main:
  for item in (bag/items[1:99]):
    Item: {item}
  else:
    (no items)
  * Add apple
    add-item "apple"
    -> main
  * Add banana
    add-item "banana"
    -> main
  * Done -> done
scene done:
  Finished.
]]

  local function make_eng()
    local gt, errs = compile(src)
    assert.equal(0, #errs, "compile errors: " .. tostring(errs[1] and errs[1].message))
    local io_out = { write = function() end }
    local eng = engine_mod.new(gt, { io_out = io_out })
    eng:init()
    return eng
  end

  it("renders else branch when list is empty", function()
    local eng = make_eng()
    local narr = eng:render_scene("main")
    local text = narr_text(narr)
    assert.is_truthy(text:find("no items"), "expected '(no items)' in: " .. text)
    assert.is_falsy(text:find("Item:"))
  end)

  it("renders loop body with interpolated variable after items added", function()
    local eng = make_eng()
    eng:do_choice("main", 1)  -- add apple
    eng:do_choice("main", 2)  -- add banana
    local narr = eng:render_scene("main")
    local text = narr_text(narr)
    assert.is_truthy(text:find("Item: apple"),  "expected `Item: apple' in: "  .. text)
    assert.is_truthy(text:find("Item: banana"), "expected `Item: banana' in: " .. text)
    assert.is_falsy(text:find("no items"))
  end)

  it("else branch disappears once list has items", function()
    local eng = make_eng()
    eng:do_choice("main", 1)  -- add apple
    local narr = eng:render_scene("main")
    local text = narr_text(narr)
    assert.is_falsy(text:find("no items"))
  end)

end)

-- ============================================================
-- npc-speed: extra post_action passes per player turn
-- ============================================================

describe("engine: npc-speed runs extra actor passes", function()

  local src = [[
module npc-speed-test
  version: 1.0
engine-config:
  entry-scene: main
  npc-speed: 2
state world:
  counter: Int(0, 99) = 0
actor inc-actor:
  priority: 1
  perceives: []
  behavior: inc-fn
fn inc-fn:
  inc! world/counter 1
scene main:
  * Tick -> main
]]

  it("step with npc-speed 2 runs 3 actor passes (1 normal + 2 extra)", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs, "compile errors")
    local lines_in = {"1", "1"}  -- two turns
    local eng = engine_mod.new(gt, {
      io_out = { write = function() end },
      io_in  = make_input(lines_in),
    })
    eng:init()
    assert.equal(0, eng._state:get("world/counter"))
    eng:step()  -- 1 step → 1+2=3 post_action calls → counter=3
    assert.equal(3, eng._state:get("world/counter"))
  end)

end)

-- ============================================================
-- SF-4: transitions to undefined scenes emit a warning
-- ============================================================

describe("SF-4: undefined scene transition warning", function()

  local function make_minimal_game(extra_scenes, production)
    local scenes = { main = { body = {} } }
    for k, v in pairs(extra_scenes or {}) do scenes[k] = v end
    local warns = {}
    local gt = {
      production  = production or false,
      _print_sink = function(m) warns[#warns+1] = m end,
      schema      = { engine_config = {}, states = {}, types = {}, relations = {} },
      fns         = {},
      scenes      = scenes,
      verifies    = {},
      watches     = {},
    }
    return gt, warns
  end

  it("goto_scene warns for unknown target in dev mode", function()
    local gt, warns = make_minimal_game()
    local eng = engine_mod.new(gt)
    eng:push_scene("main")
    eng:goto_scene("ghost-town")
    assert.equal(1, #warns)
    assert.is_truthy(warns[1]:find("ghost%-town"))
  end)

  it("enter_scene warns for unknown target in dev mode", function()
    local gt, warns = make_minimal_game()
    local eng = engine_mod.new(gt)
    eng:push_scene("main")
    eng:enter_scene("ghost-town")
    assert.equal(1, #warns)
    assert.is_truthy(warns[1]:find("ghost%-town"))
  end)

  it("goto_scene does not warn for a known scene", function()
    local gt, warns = make_minimal_game({ town = { body = {} } })
    local eng = engine_mod.new(gt)
    eng:push_scene("main")
    eng:goto_scene("town")
    assert.equal(0, #warns)
  end)

  it("enter_scene does not warn for a known scene", function()
    local gt, warns = make_minimal_game({ town = { body = {} } })
    local eng = engine_mod.new(gt)
    eng:push_scene("main")
    eng:enter_scene("town")
    assert.equal(0, #warns)
  end)

  it("goto_scene suppresses warning in production mode", function()
    local gt, warns = make_minimal_game(nil, true)
    local eng = engine_mod.new(gt)
    eng:push_scene("main")
    eng:goto_scene("ghost-town")
    assert.equal(0, #warns)
  end)

  it("enter_scene suppresses warning in production mode", function()
    local gt, warns = make_minimal_game(nil, true)
    local eng = engine_mod.new(gt)
    eng:push_scene("main")
    eng:enter_scene("ghost-town")
    assert.equal(0, #warns)
  end)

  it("step() emits warning when choice body navigates to undefined scene", function()
    local src = [[
module sf4-test
  version: 1.0
engine-config:
  entry-scene: main
scene main:
  * Go
    -> nowhere
]]
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    local warns = {}
    gt._print_sink = function(m) warns[#warns+1] = m end
    local eng = engine_mod.new(gt, {
      io_out = { write = function() end },
      io_in  = make_input({"1"}),
    })
    eng:init()
    eng:step()
    assert.equal(1, #warns)
    assert.is_truthy(warns[1]:find("nowhere"))
  end)

end)

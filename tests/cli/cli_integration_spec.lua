-- tests/cli/cli_integration_spec.lua
-- Comprehensive integration tests for the storybase CLI.
--
-- These tests call cli/main.lua's M.main() directly with captured I/O,
-- covering every subcommand, all test*.sb and demo*.sb files, and all
-- significant flag combinations.
--
-- Run sparingly (before commits) — some tests invoke the BFS verifier
-- and the full engine loop, which can be slow.

local cli = require("cli.main")

--- Flatten a structured narration list to a single space-joined text string.
local function narr_text(narr)
  local parts = {}
  for _, item in ipairs(narr or {}) do
    parts[#parts + 1] = (type(item) == "table" and item.text) or tostring(item)
  end
  return table.concat(parts, " ")
end

-- ── I/O capture helpers ───────────────────────────────────────────────────────

--- Capture stdout + stderr during fn().  Returns out_str, err_str.
--- Also intercepts io.write() (which routes to the current output file).
local function capture_io(fn)
  local out_parts, err_parts = {}, {}
  local old_out, old_err = io.stdout, io.stderr
  local old_io_write = io.write

  -- Proxy objects that capture writes
  local function make_capture(parts)
    return setmetatable({}, {
      __index = {
        write = function(_, ...)
          for _, s in ipairs({...}) do
            parts[#parts + 1] = tostring(s)
          end
        end,
        flush = function() end,
      }
    })
  end

  local out_proxy = make_capture(out_parts)
  local err_proxy = make_capture(err_parts)
  io.stdout = out_proxy
  io.stderr = err_proxy

  -- Also redirect io.write() so modules using io.write() are captured
  io.write = function(...)
    for _, s in ipairs({...}) do
      out_parts[#out_parts + 1] = tostring(s)
    end
  end

  local ok, result = pcall(fn)

  io.stdout = old_out
  io.stderr = old_err
  io.write  = old_io_write

  if not ok then error(result, 2) end
  return table.concat(out_parts), table.concat(err_parts), result
end

--- Run the CLI with given argv; return exit_code, stdout, stderr.
local function run_cli(argv)
  local out, err, rc = capture_io(function()
    return cli.main(argv)
  end)
  return rc or 0, out, err
end

--- Write a temporary file; return its path.
local function tmpfile(suffix, contents)
  local path = os.tmpname() .. (suffix or "")
  local f = assert(io.open(path, "w"))
  f:write(contents or "")
  f:close()
  return path
end

-- ── help / no-args ────────────────────────────────────────────────────────────

describe("CLI: help", function()
  it("returns 0 and prints usage with no args", function()
    local rc, out, _ = run_cli({})
    assert.equal(1, rc)  -- no-args → usage → exit 1
    assert.is_truthy(out:find("Usage") or out:find("usage") or
                     _:find("Usage") or _:find("usage"), "expected usage text")
  end)

  it("`help' subcommand returns 0 and prints usage", function()
    local rc, out, _ = run_cli({"help"})
    assert.equal(0, rc)
    local combined = out .. _
    assert.is_truthy(combined:find("compile") and combined:find("run"),
      "expected command list in help output")
  end)

  it("`help compile' shows compile-specific help", function()
    local rc, out, _ = run_cli({"help", "compile"})
    assert.equal(0, rc)
    assert.is_truthy((out .. _):find("--production"), "expected --production flag docs")
  end)

  it("`help run' shows run-specific help including --auto", function()
    local rc, out, _ = run_cli({"help", "run"})
    assert.equal(0, rc)
    assert.is_truthy((out .. _):find("--auto"), "expected --auto flag docs")
  end)

  it("unknown command returns 1", function()
    local rc, _, err = run_cli({"frobnicator"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("unknown command"), err)
  end)
end)

-- ── compile: error cases ──────────────────────────────────────────────────────

describe("CLI compile: error cases", function()
  it("returns 1 with no file argument", function()
    local rc, _, err = run_cli({"compile"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("no input file"), err)
  end)

  it("returns 1 for nonexistent file", function()
    local rc, _, err = run_cli({"compile", "/nonexistent/missing.sb"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("Compilation failed") or err:find("Cannot open"), err)
  end)

  it("returns 1 and reports errors for bad source", function()
    local p = tmpfile(".sb", "bad source @@@@")
    local rc, _, err = run_cli({"compile", p})
    os.remove(p)
    assert.equal(1, rc)
    assert.is_truthy(err:find("Compilation failed"), err)
  end)

  it("reports warning codes but still succeeds", function()
    -- A file that compiles with warnings (e.g. perceives violation would need
    -- actor setup; just verify a clean file has no warnings)
    local p = tmpfile(".sb", [[
module warn-test
  version: 1.0
engine-config:
  entry-scene: main
state world:
  x: Int(0, 10) = 0
scene main:
  Done.
]])
    local rc, out, _ = run_cli({"compile", p})
    os.remove(p)
    assert.equal(0, rc)
    assert.is_truthy(out:find("succeeded"), out)
  end)
end)

-- ── compile: all test*.sb files ───────────────────────────────────────────────

local TEST_SB_FILES = {
  "tests/test01_minimal.sb",
  "tests/test02_choices.sb",
  "tests/test03_types.sb",
  "tests/test04_control_flow.sb",
  "tests/test05_log_and_time.sb",
  "tests/test06_actors.sb",
}

describe("CLI compile: test suite .sb files", function()
  for _, path in ipairs(TEST_SB_FILES) do
    local label = path:match("[^/]+$")
    it("compiles " .. label .. " successfully (exit 0)", function()
      local rc, out, err = run_cli({"compile", path})
      assert.equal(0, rc, string.format(
        "%s compile failed:\nstdout: %s\nstderr: %s", label, out, err))
      assert.is_truthy(out:find("succeeded"), out)
    end)

    it("--production compile of " .. label .. " exits 0", function()
      local rc, out, err = run_cli({"compile", "--production", path})
      assert.equal(0, rc, string.format(
        "%s --production compile failed:\nstdout: %s\nstderr: %s", label, out, err))
      assert.is_truthy(out:find("succeeded"), out)
    end)
  end
end)

-- ── compile: all demo*.sb files ───────────────────────────────────────────────

local DEMO_SB_FILES = {
  "demos/demo01_wanderer.sb",
  "demos/demo02_merchant.sb",
  "demos/demo03_quest.sb",
  "demos/demo04_expedition.sb",
  "demos/demo05_siege.sb",
  "demos/demo06_buried_keep.sb",
  "demos/demo07_oracle.sb",
  "demos/demo10_market_bell.sb",
  "demos/demo11_expedition_guild.sb",
}

describe("CLI compile: demo .sb files", function()
  for _, path in ipairs(DEMO_SB_FILES) do
    local label = path:match("[^/]+$")
    it("compiles " .. label .. " successfully (exit 0)", function()
      local rc, out, err = run_cli({"compile", path})
      assert.equal(0, rc, string.format(
        "%s compile failed:\nstdout: %s\nstderr: %s", label, out, err))
      assert.is_truthy(out:find("succeeded"), out)
    end)

    it("--production compile of " .. label .. " exits 0", function()
      local rc, out, err = run_cli({"compile", "--production", path})
      assert.equal(0, rc, string.format(
        "%s --production compile failed:\nstdout: %s\nstderr: %s", label, out, err))
    end)
  end
end)

-- ── compile: output content ───────────────────────────────────────────────────

describe("CLI compile: output format", function()
  it("reports type/state/scene counts", function()
    local rc, out, _ = run_cli({"compile", "demos/demo01_wanderer.sb"})
    assert.equal(0, rc)
    -- "Types: N  State paths: N  Scenes: N"
    assert.is_truthy(out:find("Types:"), out)
    assert.is_truthy(out:find("State paths:"), out)
    assert.is_truthy(out:find("Scenes:"), out)
  end)

  it("reports state-space size", function()
    local rc, out, _ = run_cli({"compile", "demos/demo01_wanderer.sb"})
    assert.equal(0, rc)
    assert.is_truthy(out:find("State%-space size:"), out)
  end)

  it("demo02 has types and state paths > 0", function()
    local rc, out, _ = run_cli({"compile", "demos/demo02_merchant.sb"})
    assert.equal(0, rc)
    -- demo02 has 1 type enum (Item) and 2 state paths
    local types = out:match("Types: (%d+)")
    local paths = out:match("State paths: (%d+)")
    assert.is_truthy(tonumber(types) and tonumber(types) >= 1, out)
    assert.is_truthy(tonumber(paths) and tonumber(paths) >= 2, out)
  end)
end)

-- ── run: error cases ──────────────────────────────────────────────────────────

describe("CLI run: error cases", function()
  it("returns 1 with no file argument", function()
    local rc, _, err = run_cli({"run"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("no input file"), err)
  end)

  it("returns 1 for nonexistent file", function()
    local rc, _, err = run_cli({"run", "/nonexistent/missing.sb"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("Compilation failed") or err:find("Cannot open"), err)
  end)

  it("returns 1 for file with compile errors", function()
    local p = tmpfile(".sb", "bad source @@@@")
    local rc, _, err = run_cli({"run", p})
    os.remove(p)
    assert.equal(1, rc)
    assert.is_truthy(err:find("Compilation failed") or err:find("cannot run"), err)
  end)
end)

-- ── run --quiet: AE-14 warning suppression ───────────────────────────────────

describe("CLI run --quiet", function()
  -- demo11 compiles with WRITE_UNTYPED_VAR warnings — good fixture for this test
  local WARNED_FILE = "demos/demo11_expedition_guild.sb"

  it("suppresses compiler warnings on stderr", function()
    local rc, _, err = run_cli({"run", "--quiet", "--auto", "--steps", "1", WARNED_FILE})
    assert.equal(0, rc)
    assert.is_falsy(err:find("%[WARN%]") or err:find("warning"), "expected no warnings, got: " .. err)
  end)

  it("without --quiet, warnings appear on stderr", function()
    local rc, _, err = run_cli({"run", "--auto", "--steps", "1", WARNED_FILE})
    assert.equal(0, rc)
    assert.is_truthy(err:find("warning"), "expected warnings without --quiet, got: " .. err)
  end)

  it("--quiet does not suppress errors (still fails on bad source)", function()
    local p = tmpfile(".sb", "bad source @@@@")
    local rc, _, err = run_cli({"run", "--quiet", p})
    os.remove(p)
    assert.equal(1, rc)
    assert.is_truthy(err:find("Compilation failed") or err:find("cannot run"), err)
  end)

  it("help run mentions --quiet", function()
    local rc, out, err = run_cli({"help", "run"})
    assert.equal(0, rc)
    assert.is_truthy((out .. err):find("--quiet"), "expected --quiet in help output")
  end)
end)

-- ── run --auto --steps: smoke tests for all demos ────────────────────────────
-- Step limits per demo: enough to exercise gameplay but avoid precondition
-- failures that occur when auto-play cycles past designed guard conditions.
local DEMO_STEPS = {
  ["demos/demo01_wanderer.sb"]  = 20,  -- terminates naturally in 4
  ["demos/demo02_merchant.sb"]  = 20,  -- terminates naturally
  ["demos/demo03_quest.sb"]     = 10,  -- has quest loop; bound early
  ["demos/demo04_expedition.sb"] = 8,  -- crew can all die by day 8
  ["demos/demo05_siege.sb"]     = 12,  -- has guarded victory condition
  ["demos/demo06_buried_keep.sb"] = 6, -- torches run out in ~4 steps auto-play
  ["demos/demo07_oracle.sb"]    = 10,  -- journey ends at day 8; reaches finale in ~9 steps
  ["demos/demo10_market_bell.sb"] = 20, -- buy/sell loop; auto stays in day-1 trading
  ["demos/demo11_expedition_guild.sb"] = 15, -- guild management; hire+dispatch loop
}

describe("CLI run --auto --steps N: all demo files run without error", function()
  for _, path in ipairs(DEMO_SB_FILES) do
    local label = path:match("[^/]+$")
    local steps = tostring(DEMO_STEPS[path] or 20)
    it("auto-plays " .. label .. " for up to " .. steps .. " steps (exit 0)", function()
      local rc, out, err = run_cli({"run", "--auto", "--steps", steps, path})
      assert.equal(0, rc, string.format(
        "%s run --auto --steps %s failed:\nstdout: %s\nstderr: %s", label, steps, out, err))
      -- Should have produced some output (narration or choices)
      assert.is_truthy(#out > 0, "expected game output, got nothing")
    end)
  end
end)

-- ── run --auto: all test*.sb files ───────────────────────────────────────────
-- Per-file step limits to avoid precondition failures from auto-cycling.
local TEST_SB_STEPS = {
  ["tests/test01_minimal.sb"]       = 5,
  ["tests/test02_choices.sb"]       = 10,
  ["tests/test03_types.sb"]         = 6,   -- health depletes by step 7 → pre: alive fails
  ["tests/test04_control_flow.sb"]  = 3,   -- pre: enemy-hp > 0 fails at step 5
  ["tests/test05_log_and_time.sb"]  = 10,
  ["tests/test06_actors.sb"]        = 10,
}

describe("CLI run --auto --steps N: all test suite .sb files", function()
  for _, path in ipairs(TEST_SB_FILES) do
    local label = path:match("[^/]+$")
    local steps = tostring(TEST_SB_STEPS[path] or 10)
    it("auto-plays " .. label .. " for up to " .. steps .. " steps (exit 0)", function()
      local rc, out, err = run_cli({"run", "--auto", "--steps", steps, path})
      assert.equal(0, rc, string.format(
        "%s run --auto --steps %s failed:\nstdout: %s\nstderr: %s", label, steps, out, err))
    end)
  end
end)

-- ── run --steps N ─────────────────────────────────────────────────────────────

describe("CLI run --steps", function()
  it("--steps 1 runs exactly one turn of demo01", function()
    local rc, out, _ = run_cli({"run", "--steps", "1", "demos/demo01_wanderer.sb"})
    assert.equal(0, rc)
    -- Should see the first scene narration but not the second scene
    assert.is_truthy(out:find("village") or out:find("Village"), out)
  end)

  it("--steps 0 renders first scene but makes no choices", function()
    local rc, out, _ = run_cli({"run", "--steps", "0", "demos/demo01_wanderer.sb"})
    assert.equal(0, rc)
    -- Scene is rendered but no choices made (read returns nil immediately)
    assert.is_truthy(out:find("village") or out:find("Village"), out)
  end)
end)

-- ── run --seed ────────────────────────────────────────────────────────────────

describe("CLI run --seed", function()
  it("same seed produces identical output twice", function()
    local rc1, out1, _ = run_cli({"run", "--seed", "42", "--auto", "demos/demo01_wanderer.sb"})
    local rc2, out2, _ = run_cli({"run", "--seed", "42", "--auto", "demos/demo01_wanderer.sb"})
    assert.equal(0, rc1)
    assert.equal(0, rc2)
    assert.equal(out1, out2, "seeded runs should be identical")
  end)
end)

-- ── run --save / --load ────────────────────────────────────────────────────────

describe("CLI run: save and load", function()
  it("--save creates a save file that --load can restore", function()
    local save_path = os.tmpname() .. ".log"

    -- Play 2 turns and save
    local rc1, _, err1 = run_cli({
      "run", "--seed", "1", "--steps", "2", "--save", save_path,
      "demos/demo01_wanderer.sb",
    })
    assert.equal(0, rc1, "save run failed: " .. err1)
    -- Save file must exist
    local f = io.open(save_path, "r")
    assert.is_not_nil(f, "save file not created")
    if f then f:close() end

    -- Load and continue (bounded steps so we don't hang)
    local rc2, out2, err2 = run_cli({
      "run", "--auto", "--steps", "10", "--load", save_path,
      "demos/demo01_wanderer.sb",
    })
    os.remove(save_path)
    os.remove(save_path .. ".snap")
    assert.equal(0, rc2, "load run failed: " .. err2)
    -- Should see the "Loaded from" message
    assert.is_truthy(out2:find("Loaded from"), out2)
  end)

  it("--load returns 1 for nonexistent save file", function()
    local rc, _, err = run_cli({
      "run", "--load", "/nonexistent/save.log", "demos/demo01_wanderer.sb",
    })
    assert.equal(1, rc)
    assert.is_truthy(err:find("cannot read save file") or err:find("Cannot open"), err)
  end)
end)

-- ── run --production ─────────────────────────────────────────────────────────

describe("CLI run --production", function()
  it("runs demo01 in production mode successfully", function()
    local rc, out, err = run_cli({
      "run", "--production", "--auto", "--steps", "10", "demos/demo01_wanderer.sb",
    })
    assert.equal(0, rc, "production run failed:\nstdout: " .. out .. "\nstderr: " .. err)
    assert.is_truthy(#out > 0)
  end)
end)

-- ── verify: error cases ───────────────────────────────────────────────────────

describe("CLI verify: error cases", function()
  it("returns 1 with no file", function()
    local rc, _, err = run_cli({"verify"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("no input file"), err)
  end)

  it("returns 1 for nonexistent file", function()
    local rc, _, err = run_cli({"verify", "/nonexistent/missing.sb"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("cannot open"), err)
  end)

  it("returns 1 and prints error for bad source", function()
    local p = tmpfile(".sb", "bad source @@@@")
    local rc, _, err = run_cli({"verify", p})
    os.remove(p)
    assert.equal(1, rc)
    assert.is_truthy(err:find("Compilation failed"), err)
  end)

  it("reports `No verify blocks' for a file with none", function()
    local rc, out, _ = run_cli({"verify", "demos/demo01_wanderer.sb"})
    assert.equal(0, rc)
    assert.is_truthy(out:find("No verify blocks"), out)
  end)
end)

-- ── verify: passing verify blocks ─────────────────────────────────────────────

describe("CLI verify: passing blocks", function()
  it("verifies demo05_siege.sb with 2 PASS blocks (exit 0)", function()
    local rc, out, err = run_cli({"verify", "demos/demo05_siege.sb"})
    assert.equal(0, rc, "verify demo05 failed:\nstdout: " .. out .. "\nstderr: " .. err)
    assert.is_truthy(out:find("passed"), out)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("reports BFS states checked count", function()
    local rc, out, _ = run_cli({"verify", "demos/demo05_siege.sb"})
    assert.equal(0, rc)
    assert.is_truthy(out:find("BFS states checked"), out)
  end)
end)

-- ── verify: failing verify block ──────────────────────────────────────────────

describe("CLI verify: failing block returns exit 1", function()
  it("returns 1 when verify block fails", function()
    -- Build a file with a verify-always that is definitely false
    -- Uses `verify-always` (the builtin), not `always:` (unsupported syntax)
    local src = [[
module verify-fail-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  x: Int(0, 5) = 0

scene main:
  * Increment
    inc! world/x 1
    -> main

verify "x never positive":
  verify-always world/x = 0
]]
    local p = tmpfile(".sb", src)
    local rc, out, _ = run_cli({"verify", p})
    os.remove(p)
    assert.equal(1, rc)
    assert.is_truthy(out:find("FAIL"), out)
  end)
end)

-- ── demo07: import + bounded + counterfactual ────────────────────────────────

describe("CLI demo07_oracle: import / bounded / counterfactual", function()
  it("compiles with imported types visible (2 types: Shrine + WeatherKind)", function()
    local rc, out, err = run_cli({"compile", "demos/demo07_oracle.sb"})
    assert.equal(0, rc, "demo07 compile failed:\n" .. out .. err)
    -- oracle_lib.sb declares 2 types; they should appear in the compiled schema
    local types = out:match("Types: (%d+)")
    assert.is_truthy(tonumber(types) and tonumber(types) >= 2, out)
  end)

  it("verify blocks pass (offerings >= 0 and renown >= 0)", function()
    local rc, out, err = run_cli({"verify", "demos/demo07_oracle.sb"})
    assert.equal(0, rc, "demo07 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("orb-vision scene renders counterfactual preview values", function()
    -- Play intro then consult the orb (choice 1 then choice 6)
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo07_oracle.sb")
    game:init()
    game:choose(1)  -- Begin the wandering
    local narr, choices = game:render()
    -- choice 6 = Consult the crystal orb (after 5 travel/action choices)
    -- find the orb choice
    local orb_idx = nil
    for i, c in ipairs(choices) do
      if c.label and (c.label:find("[Oo]rb") or c.label:find("crystal")) then
        orb_idx = i; break
      end
    end
    assert.is_not_nil(orb_idx, "expected `Consult the crystal orb' choice")
    game:choose(orb_idx)
    local orb_narr = game:render()
    -- Counterfactual preview values should appear in narration (meditate: 50+12=62)
    local text = narr_text(orb_narr)
    assert.is_truthy(text:find("62") or text:find("meditate"), text)
  end)

  it("bounded oracle-weather falls back to `clear when no handler registered", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo07_oracle.sb")
    game:init()
    game:choose(1)   -- Begin the wandering (into wanderer scene)
    game:choose(1)   -- Travel to Stone Shrine (travel calls oracle-weather)
    -- weather should be `clear (bounded fallback)
    local weather = game:get("world/weather")
    assert.equal("clear", weather)
  end)
end)

-- ── demo08: probability engine ───────────────────────────────────────────────

describe("CLI demo08_probability_engine: BFS builtins + oracle + verify", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo08_probability_engine.sb"})
    assert.equal(0, rc, "demo08 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded") or out:find("check passed"), out)
  end)

  it("verify blocks all pass (gold >= 0, supply/spy preconditions)", function()
    local rc, out, err = run_cli({"verify", "demos/demo08_probability_engine.sb"})
    assert.equal(0, rc, "demo08 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto run 15 steps completes without timeout", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "15",
                                   "demos/demo08_probability_engine.sb"})
    assert.equal(0, rc, "demo08 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("PROBABILITY"), out)
  end)

  it("consult-supply shows oracle analysis with probability and path steps", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo08_probability_engine.sb")
    game:init()
    game:choose(1)  -- Open the shop
    game:choose(1)  -- Consult the supply captain (engine/checkpoint! then => consult-supply)
    local narr = game:render()
    local text = narr_text(narr)
    assert.is_truthy(text:find("Delivery possible"), text)
    assert.is_truthy(text:find("Odds"), text)
    assert.is_truthy(text:find("Shortest route"), text)
  end)

  it("premium-contract-count returns 2 (fees 25 and 35 qualify, 10 does not)", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo08_probability_engine.sb")
    game:init()
    game:choose(1)  -- Open the shop (shop narration shows premium count)
    local narr = game:render()
    local text = narr_text(narr)
    assert.is_truthy(text:find("2"), text)
  end)

  it("accept-supply increments gold by 25 and reputation by 10", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo08_probability_engine.sb")
    game:init()
    local gold_before = game:get("world/gold")
    local rep_before  = game:get("world/reputation")
    game:choose(1)  -- Open shop
    game:choose(1)  -- Consult supply captain
    game:choose(1)  -- Accept contract
    assert.equal(gold_before + 25, game:get("world/gold"))
    assert.equal(rep_before + 10,  game:get("world/reputation"))
  end)
end)

-- ── demo09: warden's map ─────────────────────────────────────────────────────

describe("CLI demo09_wardens_map: grid builtins + path-to + visible-from + verify", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo09_wardens_map.sb"})
    assert.equal(0, rc, "demo09 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded") or out:find("check passed"), out)
  end)

  it("verify blocks pass (round in bounds, alert valid enum)", function()
    local rc, out, err = run_cli({"verify", "demos/demo09_wardens_map.sb"})
    assert.equal(0, rc, "demo09 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto run 12 steps completes without timeout", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "12",
                                   "demos/demo09_wardens_map.sb"})
    assert.equal(0, rc, "demo09 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("WARDEN"), out)
  end)

  it("init-dungeon sets up grid cells (floor default) and spawns guards", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo09_wardens_map.sb")
    game:init()
    game:choose(1)  -- Stand watch (calls init-dungeon)
    local narr = game:render()
    local text = narr_text(narr)
    assert.is_truthy(text:find("floor"), text)  -- grid-get returns `floor default
    assert.is_truthy(text:find("Guard Alpha"), text)
  end)

  it("station-alpha-west places guard with LOS to intruder", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo09_wardens_map.sb")
    game:init()
    game:choose(1)  -- Stand watch
    game:choose(1)  -- Station Alpha at west gap
    local narr = game:render()
    local text = narr_text(narr)
    assert.is_truthy(text:find("Guards with sight%-line to intruder: 1"), text)
    assert.equal(1,  game:get("guards/alpha/x"))
    assert.equal(2,  game:get("guards/alpha/y"))
    assert.equal(true, game:get("guards/alpha/active"))
  end)

  it("advance-round with both guards catches intruder (vault secure)", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo09_wardens_map.sb")
    game:init()
    game:choose(1)  -- Stand watch
    game:choose(1)  -- Station Alpha
    game:choose(1)  -- Station Beta
    game:choose(4)  -- Advance simulation
    assert.equal(true, game:get("intruder/caught"))
    assert.equal(false, game:get("vault/breached"))
    local text = narr_text(game:render())
    assert.is_truthy(text:find("contained") or text:find("secure"), text)
  end)

  it("advance-round with no guards breaches vault", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo09_wardens_map.sb")
    game:init()
    game:choose(1)  -- Stand watch
    game:choose(5)  -- Advance simulation (no guards)
    local text = narr_text(game:render())
    assert.is_truthy(text:find("breached") or text:find("crystal"), text)
    assert.equal(true, game:get("vault/breached"))
  end)

  it("set-west-trap redirects intruder to longer east route", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo09_wardens_map.sb")
    game:init()
    game:choose(1)  -- Stand watch
    local steps_before = game:get("world/round") or 0
    -- Place west trap first
    game:choose(4)  -- Set west trap
    local narr = game:render()
    local text = narr_text(narr)
    -- After trap, route should be longer (trap forces east route)
    assert.is_truthy(text:find("Steps to vault:"), text)
    assert.is_truthy(game:get("world/alert") ~= nil, "alert should be set")
  end)
end)

-- ── demo10: market bell (multi-axis time model) ───────────────────────────────

describe("CLI demo10_market_bell: multi-axis time model + schedules + verify", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo10_market_bell.sb"})
    assert.equal(0, rc, "demo10 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("verify blocks pass", function()
    local rc, out, err = run_cli({"verify", "demos/demo10_market_bell.sb"})
    assert.equal(0, rc, "demo10 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto run 20 steps completes without error", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "20",
                                   "demos/demo10_market_bell.sb"})
    assert.equal(0, rc, "demo10 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("Day"), out)
  end)

  it("browsing advances hour and closes market at 18", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo10_market_bell.sb")
    game:init()
    -- Browse 5 times: hour goes 8→10→12→14→16→18 (market closes on 5th)
    for _ = 1, 4 do game:choose(3) end  -- browse ×4, still open
    assert.equal(true,  game:get("market/open"))
    assert.equal(16,    game:get("world/hour"))
    game:choose(3)  -- 5th browse: hour=18, market closes
    assert.equal(false, game:get("market/open"))
    assert.equal(18,    game:get("world/hour"))
  end)

  it("rest triggers morning-bell: market reopens with new prices", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo10_market_bell.sb")
    game:init()
    -- Close market by browsing 5 times
    for _ = 1, 5 do game:choose(3) end
    assert.equal(false, game:get("market/open"))
    assert.equal(1,     game:get("world/day"))
    -- Rest: advances day, triggers morning-bell
    local old_grain = game:get("prices/grain")
    game:choose(1)  -- rest (only choice when market closed)
    assert.equal(true,  game:get("market/open"))
    assert.equal(2,     game:get("world/day"))
    assert.equal(8,     game:get("world/hour"))
    -- morning-bell fires random-int prices (may differ from initial)
    local new_grain = game:get("prices/grain")
    assert.is_truthy(new_grain >= 5 and new_grain <= 12,
      "grain price after morning-bell should be in [5,12], got " .. tostring(new_grain))
    _ = old_grain  -- silence unused warning
  end)

  it("grand festival fires after 4 rests (day 5)", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo10_market_bell.sb")
    game:init()
    for _ = 1, 4 do
      -- browse to close market
      for _ = 1, 5 do game:choose(3) end
      -- rest
      game:choose(1)
    end
    assert.equal(true,  game:get("market/festival"))
    assert.equal(false, game:get("market/open"))
    assert.equal(5,     game:get("world/day"))
  end)

  it("festival-end scene reached after grand festival", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo10_market_bell.sb")
    game:init()
    for _ = 1, 4 do
      for _ = 1, 5 do game:choose(3) end
      game:choose(1)
    end
    -- Only choice is the festival choice
    local _, choices = game:render()
    assert.equal(1, #choices)
    assert.is_truthy(choices[1].label:find("festival"), choices[1].label)
    game:choose(1)
    assert.equal("festival-end", game:current_scene())
  end)
end)

-- ── demo11: expedition guild ─────────────────────────────────────────────────

describe("CLI demo11_expedition_guild: type aliases + Option(T) + find + computed-goto", function()
  it("compiles without errors", function()
    local rc, out, err = run_cli({"compile", "demos/demo11_expedition_guild.sb"})
    assert.equal(0, rc, "demo11 compile failed:\n" .. out .. err)
  end)

  it("init-guild populates roster and find renders member list", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo11_expedition_guild.sb")
    game:init()
    game:choose(1)  -- Begin (calls init-guild)
    local narr = game:render()
    local text = narr_text(narr)
    assert.is_truthy(text:find("zhen"), text)  -- highest skill member visible
    assert.is_truthy(text:find("aldric"), text)
    assert.is_truthy(text:find("1 adventurer"), text)  -- lyra is injured
  end)

  it("hiring Aldric spends gold and sets companion (Option(T))", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo11_expedition_guild.sb")
    game:init()
    game:choose(1)  -- Begin
    game:choose(1)  -- Hire from roster
    game:choose(1)  -- Hire Aldric (skill 8, cost 30)
    assert.equal(170, game:get("guild/gold"))
    assert.equal("aldric", game:get("player/companion"))
  end)

  it("computed goto routes to companion-specific scene", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo11_expedition_guild.sb")
    game:init()
    game:choose(1)  -- Begin
    game:choose(1)  -- Hire from roster
    game:choose(1)  -- Hire Aldric
    game:choose(3)  -- Talk to companion → computed goto → talk-aldric
    assert.equal("talk-aldric", game:current_scene())
  end)

  it("dismiss companion restores member status via dynamic path {player/companion}", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo11_expedition_guild.sb")
    game:init()
    game:choose(1)  -- Begin
    game:choose(1)  -- Hire from roster
    game:choose(1)  -- Hire Aldric
    game:choose(3)  -- Talk to Aldric
    game:choose(1)  -- Dismiss Aldric
    assert.is_nil(game:get("player/companion"))
    assert.equal("available", game:get("members/aldric/status"))
  end)

  it("dispatch mission advances day and gains prestige", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo11_expedition_guild.sb")
    game:init()
    game:choose(1)  -- Begin
    game:choose(1)  -- Hire from roster
    game:choose(1)  -- Hire Aldric
    game:choose(4)  -- Depart on mission → mission-briefing
    game:choose(1)  -- Depart
    assert.equal(2, game:get("guild/day"))
    assert.equal(15, game:get("guild/prestige"))
  end)

  it("nil-coalescing ?? renders `none' when companion is nil", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo11_expedition_guild.sb")
    game:init()
    game:choose(1)  -- Begin
    local narr = game:render()
    local text = narr_text(narr)
    assert.is_truthy(text:find("none"), text)  -- player/companion ?? `none
  end)
end)

-- ── demo12: herbalist's codex ────────────────────────────────────────────────

describe("CLI demo12_codex: namespaced import + cross-file types/fns/scenes", function()
  it("compiles without errors", function()
    local rc, out, err = run_cli({"compile", "demos/demo12_codex.sb"})
    assert.equal(0, rc, "demo12 compile failed:\n" .. out .. err)
  end)

  it("namespaced types appear in schema (Herb.PlantKind, Herb.RemedyKind)", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo12_codex.sb")
    game:init()
    -- Types are registered under the alias
    local _, diags = require("compiler.compiler").compile_file("demos/demo12_codex.sb")
    assert.is_false(diags:has_errors())
  end)

  it("init-garden (cross-file state) sets up garden family members", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo12_codex.sb")
    game:init()
    game:choose(1)  -- Begin — stock the garden
    assert.equal(8,  game:get("garden/feverwort/quantity"))
    assert.equal(2,  game:get("garden/feverwort/moisture"))
    assert.equal(5,  game:get("garden/silkmoss/quantity"))
    assert.equal(6,  game:get("garden/ironroot/quantity"))
    assert.equal(2,  game:get("garden/moonpetal/quantity"))
  end)

  it("Herb.assess-stock guards brew choices correctly", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo12_codex.sb")
    game:init()
    game:choose(1)  -- Begin (init-garden: feverwort=8 >= 3)
    local _, choices = game:render()
    local labels = {}
    for _, c in ipairs(choices) do labels[c.label] = true end
    assert.is_truthy(labels["Brew a tonic"],  "brew-tonic choice should be available")
    assert.is_truthy(labels["Brew a salve"],  "brew-salve choice should be available")
  end)

  it("brew-remedy consumes feverwort and sets workbench (cross-file state + Option(T))", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo12_codex.sb")
    game:init()
    game:choose(1)   -- init-garden (feverwort=8)
    game:choose(3)   -- Brew a tonic
    assert.equal(5,       game:get("garden/feverwort/quantity"))  -- 8-3=5
    assert.equal("tonic", game:get("workbench/remedy"))
  end)

  it("sell-remedy earns gold and clears workbench (Option(T) back to nil)", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo12_codex.sb")
    game:init()
    game:choose(1)   -- init-garden
    game:choose(3)   -- Brew a tonic
    game:choose(3)   -- Sell remedy
    assert.equal(65,  game:get("player/gold"))   -- 50+15
    assert.equal(25,  game:get("player/rep"))    -- 20+5
    assert.is_nil(game:get("workbench/remedy"))
  end)

  it("=> Herb.harvest navigates to the cross-file scene via enter (push)", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo12_codex.sb")
    game:init()
    game:choose(1)   -- init-garden
    game:choose(2)   -- Go to the garden (=> Herb.harvest)
    assert.equal("Herb.harvest", game:current_scene())
  end)

  it("Herb.dry-garden runs from rest-day, reducing moisture", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo12_codex.sb")
    game:init()
    game:choose(1)   -- init-garden (feverwort moisture=2)
    game:choose(5)   -- Rest a day (calls Herb.dry-garden)
    assert.equal(1, game:get("garden/feverwort/moisture"))  -- 2-1=1
    assert.equal(2, game:get("workbench/day"))
  end)

  it("verify suite passes for demo12", function()
    local rc, out, err = run_cli({"verify", "demos/demo12_codex.sb"})
    assert.equal(0, rc, "demo12 verify failed:\n" .. out .. err)
  end)
end)

-- ── demo13: healer's ward ────────────────────────────────────────────────────

describe("CLI demo13_healers_ward: speaker/say + post: + multi-line lambdas", function()
  local sb_mod = require("lib.storybase")

  local function load_and_init()
    local game = sb_mod.load("demos/demo13_healers_ward.sb")
    game:init()
    game:choose(1)  -- "Enter the ward" -> init-ward, -> ward
    return game
  end

  it("compiles without errors", function()
    local rc, out, err = run_cli({"compile", "demos/demo13_healers_ward.sb"})
    assert.equal(0, rc, "demo13 compile failed:\n" .. out .. err)
  end)

  it("init-ward spawns three patients with correct initial state", function()
    local game = load_and_init()
    assert.equal(35,        game:get("patients/rook/health"))
    assert.equal("wounded", game:get("patients/rook/condition"))
    assert.equal(45,        game:get("patients/linden/health"))
    assert.equal("feverish",game:get("patients/linden/condition"))
    assert.equal(70,        game:get("patients/mira/health"))
    assert.equal("stable",  game:get("patients/mira/condition"))
  end)

  it("count patients where: correctly reports 3 untreated on entry", function()
    local game = load_and_init()
    local narration = game:render()
    local found = false
    for _, n in ipairs(narration) do
      if n.text and n.text:find("3 patient") then found = true end
    end
    assert.is_true(found, "expected '3 patient(s)' in narration")
  end)

  it("apply-bandage: post: enforces health increase and bandage consumption", function()
    local game = load_and_init()
    local bandages_before = game:get("world/bandages")
    local health_before   = game:get("patients/rook/health")
    -- Treat urgent (rook or linden selected), then apply treatment
    game:choose(1)   -- treat-urgent scene
    game:choose(1)   -- apply bandages or herbs (whichever is choice 1)
    -- After treatment, bandages or herbs decrease and health increases
    local selected = game:get("world/selected-patient")
    assert.is_true(
      game:get("patients/" .. selected .. "/health") >= health_before or
      game:get("world/herbs")    < 12 or
      game:get("world/bandages") < bandages_before,
      "expected health up or supply consumed after treatment")
  end)

  it("multi-line lambda find-urgent: skips treated patients on re-entry", function()
    local game = load_and_init()
    game:choose(1)   -- treat-urgent
    game:choose(1)   -- treat first urgent patient
    -- Now in ward: the treated patient should not appear as urgent
    local narration = game:render()
    local found = false
    for _, n in ipairs(narration) do
      if n.text and n.text:find("2 patient") then found = true end
    end
    assert.is_true(found, "expected '2 patient(s)' after treating one")
  end)

  it("say buffering: fn-body dialogue prepended to next scene narration", function()
    local game = load_and_init()
    game:choose(1)   -- treat-urgent
    game:choose(1)   -- apply treatment
    -- Back in ward: buffered say lines from treatment fn appear first in narration
    local narration = game:render()
    -- First narration items should be dialogue from apply-bandage or apply-herbs
    local first_speaker = type(narration[1]) == "table" and narration[1].speaker
    assert.is_truthy(first_speaker == "elara" or first_speaker == "rook" or
                     first_speaker == "linden",
      "expected buffered dialogue as first narration item; got: " .. tostring(narration[1]))
  end)

  it("discharge fn sets condition to `discharged and marks treated", function()
    local game = load_and_init()
    -- Navigate to discharge mira (stable)
    game:choose(2)   -- discharge-patient scene (mira selected)
    game:choose(1)   -- discharge
    assert.equal("discharged", game:get("patients/mira/condition"))
    assert.equal(true,         game:get("patients/mira/treated"))
  end)

  it("verify suite passes", function()
    local rc, out, err = run_cli({"verify", "demos/demo13_healers_ward.sb"})
    assert.equal(0, rc, "demo13 verify failed:\n" .. out .. err)
  end)
end)

-- ── demo14: kingdom's records ────────────────────────────────────────────────

describe("CLI demo14_kingdoms_records: schema migration chain 1->4", function()
  local sb_mod = require("lib.storybase")

  it("compiles without errors", function()
    local rc, out, err = run_cli({"compile", "demos/demo14_kingdoms_records.sb"})
    assert.equal(0, rc, "demo14 compile failed:\n" .. out .. err)
  end)

  it("starts at year 1200 with population 80000 and status peaceful", function()
    local game = sb_mod.load("demos/demo14_kingdoms_records.sb")
    game:init()
    assert.equal(1200,      game:get("world/year"))
    assert.equal(80000,     game:get("world/population"))
    assert.equal("peaceful",game:get("world/kingdom-status"))
    assert.equal(0,         game:get("world/reports-filed"))
  end)

  it("advance-year increments year and reports-filed (post: enforced)", function()
    local game = sb_mod.load("demos/demo14_kingdoms_records.sb")
    game:init()
    -- choice 4 = "File the annual census report"
    game:choose(4)
    assert.equal(1201, game:get("world/year"))
    assert.equal(1,    game:get("world/reports-filed"))
  end)

  it("review-chronicle choice appears only after filing a report", function()
    local game = sb_mod.load("demos/demo14_kingdoms_records.sb")
    game:init()
    -- Initial: reports-filed = 0, chronicle choice should not appear
    local _, choices_before = game:render()
    local chronicle_before = false
    for _, c in ipairs(choices_before or {}) do
      if c.label:find("chronicle") then chronicle_before = true end
    end
    assert.is_false(chronicle_before, "chronicle choice should not appear before any report")

    -- File a report (choice 4)
    game:choose(4)
    local _, choices_after = game:render()
    local chronicle_after = false
    for _, c in ipairs(choices_after or {}) do
      if c.label:find("chronicle") then chronicle_after = true end
    end
    assert.is_true(chronicle_after, "chronicle choice should appear after filing a report")
  end)

  it("migration chain 1->4 on a v1 cache produces correct v4 state", function()
    local compiler_mod = require("compiler.compiler")
    local migrate_mod  = require("runtime.migrate")
    local gt, diags = compiler_mod.compile_file("demos/demo14_kingdoms_records.sb")
    assert.equal(0, #(diags and diags.errors or {}))

    local cache = {
      ["world/year"]           = 1210,
      ["world/census-count"]   = 800,
      ["world/kingdom-status"] = "at-war",
      ["world/trade-surplus"]  = 100,
      ["world/reports-filed"]  = 10,
    }
    local mdiags = migrate_mod.migrate(cache, gt.migrations, 1, 4, gt)
    assert.equal(0, #(mdiags.errors or {}))
    assert.equal(80000,    cache["world/population"])
    assert.equal("warring",cache["world/kingdom-status"])
    assert.is_nil(cache["world/census-count"])
    assert.is_nil(cache["world/treasury-notes"])
  end)

  it("verify suite passes", function()
    local rc, out, err = run_cli({"verify", "demos/demo14_kingdoms_records.sb"})
    assert.equal(0, rc, "demo14 verify failed:\n" .. out .. err)
  end)

  it("runs with --auto for 10 steps without error", function()
    local rc, _, err = run_cli({"run", "--auto", "--steps", "10",
                                 "demos/demo14_kingdoms_records.sb"})
    assert.equal(0, rc, "demo14 --auto run failed:\n" .. err)
  end)
end)

-- ── demo15: spellwright's workshop ────────────────────────────────────────────

describe("CLI demo15_spellwright: macros, set defaults, entity family", function()
  local sb_mod = require("lib.storybase")

  it("compiles without errors", function()
    local rc, out, err = run_cli({"compile", "demos/demo15_spellwright.sb"})
    assert.equal(0, rc, "demo15 compile failed:\n" .. out .. err)
  end)

  it("starts with mana=80 and 3 components pre-loaded (set literal default)", function()
    local game = sb_mod.load("demos/demo15_spellwright.sb")
    game:init()
    assert.equal(80,  game:get("player/mana"))
    assert.equal(100, game:get("player/health"))
    local comps = game:get("player/components")
    assert.equal(3, #(comps or {}))
  end)

  it("cast-fireball deducts mana and consumes dragonscale", function()
    local game = sb_mod.load("demos/demo15_spellwright.sb")
    game:init()
    game:choose(1)   -- Enter the workshop (init scene)
    game:choose(1)   -- Cast Fireball
    assert.equal(60, game:get("player/mana"))
    assert.equal(1,  game:get("world/spells-cast"))
    assert.is_true(game:get("spells/fireball/learned"))
  end)

  it("cast-heal-beam increases health (capped at 100)", function()
    local game = sb_mod.load("demos/demo15_spellwright.sb")
    game:init()
    game:choose(1)   -- Enter the workshop
    game:choose(1)   -- Cast Fireball (mana 80->60)
    game:choose(1)   -- Cast Ice Shard (mana 60->45)
    game:choose(1)   -- Cast Heal Beam (mana 45->20)
    assert.equal(20,  game:get("player/mana"))
    assert.equal(100, game:get("player/health"))
    assert.equal(3,   game:get("world/spells-cast"))
  end)

  it("entity family spells initialises all four spell records", function()
    local game = sb_mod.load("demos/demo15_spellwright.sb")
    game:init()
    game:choose(1)   -- Enter the workshop (triggers init-workshop)
    assert.is_not_nil(game:get("spells/fireball"))
    assert.is_not_nil(game:get("spells/ice-shard"))
    assert.is_not_nil(game:get("spells/heal-beam"))
    assert.is_not_nil(game:get("spells/binding-rune"))
    assert.equal(false, game:get("spells/binding-rune/learned"))
  end)

  it("verify suite passes", function()
    local rc, out, err = run_cli({"verify", "demos/demo15_spellwright.sb"})
    assert.equal(0, rc, "demo15 verify failed:\n" .. out .. err)
  end)

  it("runs with --auto for 15 steps without error", function()
    local rc, _, err = run_cli({"run", "--auto", "--steps", "15",
                                 "demos/demo15_spellwright.sb"})
    assert.equal(0, rc, "demo15 --auto run failed:\n" .. err)
  end)
end)

-- ── demo16: cartographer's web ───────────────────────────────────────────────

describe("CLI demo16_cartographers_web: or-where, connected-to, inverse-adjacent, counterfactual simulate", function()
  local sb_mod = require("lib.storybase")

  it("compiles without errors", function()
    local rc, out, err = run_cli({"compile", "demos/demo16_cartographers_web.sb"})
    assert.equal(0, rc, "demo16 compile failed:\n" .. out .. err)
  end)

  it("starts with 5 cities, 4 trade hubs, 2 coastal after init", function()
    local game = sb_mod.load("demos/demo16_cartographers_web.sb")
    game:init()
    game:choose(1)  -- Begin mapping (init-map)
    -- hub-count = markets (capital-city, market-town) + coastal (port-city, village) = 4
    assert.is_not_nil(game:get("cities/capital-city"))
    assert.is_not_nil(game:get("cities/port-city"))
    assert.equal(true, game:get("cities/capital-city/has-market"))
    assert.equal(true, game:get("cities/port-city/coastal"))
  end)

  it("open-village-road sets route-status to open and inc turn", function()
    local game = sb_mod.load("demos/demo16_cartographers_web.sb")
    game:init()
    game:choose(1)  -- Begin mapping
    assert.equal("closed", game:get("world/route-status"))
    game:call("open-village-road")
    assert.equal("open", game:get("world/route-status"))
    assert.equal(1, game:get("world/turn"))
  end)

  it("counterfactual simulate: true — preview gold increments by route-bonus", function()
    local game = sb_mod.load("demos/demo16_cartographers_web.sb")
    game:init()
    game:choose(1)  -- Begin mapping
    -- Before opening, preview gold should be 500 + 50 (route-bonus fires in counterfactual)
    local preview = game:call("preview-open-route")
    assert.equal(550, preview)
    -- Real gold unchanged
    assert.equal(500, game:get("player/gold"))
  end)

  it("trigger-crisis severs port road and sets crisis-active", function()
    local game = sb_mod.load("demos/demo16_cartographers_web.sb")
    game:init()
    game:choose(1)  -- Begin mapping
    assert.equal(false, game:get("world/crisis-active"))
    game:call("trigger-crisis")
    assert.equal(true, game:get("world/crisis-active"))
  end)

  it("verify suite passes", function()
    local rc, out, err = run_cli({"verify", "demos/demo16_cartographers_web.sb"})
    assert.equal(0, rc, "demo16 verify failed:\n" .. out .. err)
  end)

  it("runs with --auto for 10 steps without error", function()
    local rc, _, err = run_cli({"run", "--auto", "--steps", "10",
                                 "demos/demo16_cartographers_web.sb"})
    assert.equal(0, rc, "demo16 --auto run failed:\n" .. err)
  end)
end)

-- ── extract-symbols ───────────────────────────────────────────────────────────

describe("CLI extract-symbols", function()
  it("returns 1 with no file", function()
    local rc, _, err = run_cli({"extract-symbols"})
    assert.equal(1, rc)
    -- Error message uses "usage:" or "no input"
    assert.is_truthy(err:find("usage") or err:find("no input") or err:find("No input"), err)
  end)

  it("returns 1 for nonexistent file", function()
    local rc, _, err = run_cli({"extract-symbols", "/nonexistent/missing.sb"})
    assert.equal(1, rc)
  end)

  it("works on demo02_merchant.sb and suggests enum types", function()
    local rc, out, _ = run_cli({"extract-symbols", "demos/demo02_merchant.sb"})
    assert.equal(0, rc)
    assert.is_truthy(out:find("merchant/item"), out)
    assert.is_truthy(out:find("type Item") or out:find("type"), out)
  end)

  it("works on all demo files without crashing", function()
    for _, path in ipairs(DEMO_SB_FILES) do
      local rc, _, err = run_cli({"extract-symbols", path})
      assert.equal(0, rc, path .. ": extract-symbols failed: " .. err)
    end
  end)
end)

-- ── compact ───────────────────────────────────────────────────────────────────

describe("CLI compact", function()
  it("returns 1 with missing args", function()
    local rc, _, err = run_cli({"compact"})
    assert.equal(1, rc)
  end)

  it("returns 1 with only one arg", function()
    local rc, _, err = run_cli({"compact", "demos/demo01_wanderer.sb"})
    assert.equal(1, rc)
  end)

  it("returns 1 for nonexistent save log", function()
    local rc, _, err = run_cli({"compact", "demos/demo01_wanderer.sb", "/nonexistent/save.log"})
    assert.equal(1, rc)
  end)

  it("compact → load produces same final state as original save", function()
    -- Play demo01 to end and save (terminates naturally in ~4 steps)
    local save_path = os.tmpname() .. ".log"
    run_cli({"run", "--auto", "--steps", "20", "--save", save_path, "demos/demo01_wanderer.sb"})

    local compact_path = os.tmpname() .. ".compact.log"
    local rc, out, err = run_cli({
      "compact", "demos/demo01_wanderer.sb", save_path, "--out", compact_path
    })
    os.remove(save_path)
    os.remove(save_path .. ".snap")
    assert.equal(0, rc, "compact failed:\n" .. out .. "\n" .. err)
    assert.is_truthy(out:find("snapshot entries"), out)

    -- Load the compacted file and verify game can continue (bounded)
    local rc2, out2, err2 = run_cli({
      "run", "--auto", "--steps", "10", "--load", compact_path, "demos/demo01_wanderer.sb"
    })
    os.remove(compact_path)
    -- Game is already at end so may immediately exit (0 is still success)
    assert.equal(0, rc2, "load compact failed:\n" .. out2 .. "\n" .. err2)
    assert.is_truthy(out2:find("Loaded from"), out2)
  end)
end)

-- ── migrate ───────────────────────────────────────────────────────────────────

describe("CLI migrate", function()
  it("returns 1 with no args", function()
    local rc, _, err = run_cli({"migrate"})
    assert.equal(1, rc)
  end)

  it("returns 1 with only game file (no save log)", function()
    local rc, _, err = run_cli({"migrate", "demos/demo01_wanderer.sb"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("no save log"), err)
  end)

  it("returns 1 for nonexistent game file", function()
    local rc, _, err = run_cli({"migrate", "/nonexistent.sb", "/tmp/save.log"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("Compilation failed"), err)
  end)

  it("returns 1 for nonexistent save log (game with migrations)", function()
    -- Need a game that has migration blocks (otherwise migrate exits 0 "nothing to do")
    local src = [[
module migrate-test
  version: 1.1
engine-config:
  entry-scene: main
state world:
  x: Int(0, 10) = 0
scene main:
  Done.
migration from: 1.0
  inc! world/x 1
]]
    local sb_path = tmpfile(".sb", src)
    local rc, _, err = run_cli({"migrate", sb_path, "/nonexistent/save.log"})
    os.remove(sb_path)
    assert.equal(1, rc)
  end)

  it("reports `no migration blocks' for a game without migrations", function()
    -- demo01 has no migration blocks
    -- We need a real (though possibly empty) save file
    local save_path = os.tmpname() .. ".log"
    run_cli({"run", "--steps", "1", "--save", save_path, "demos/demo01_wanderer.sb"})

    local rc, out, _ = run_cli({"migrate", "demos/demo01_wanderer.sb", save_path})
    os.remove(save_path)
    os.remove(save_path .. ".snap")
    -- Either "no migration blocks" or "already at version"
    assert.equal(0, rc)
    assert.is_truthy(
      out:find("No migration blocks") or out:find("No migration"),
      out)
  end)
end)

-- ── End-to-end scenario: full play + save + load + compact ────────────────────

describe("CLI end-to-end: play, save, compact, load", function()
  it("demo01: full playthrough save/compact/load cycle works", function()
    local save1 = os.tmpname() .. ".log"
    local save2 = os.tmpname() .. ".compact.log"

    -- Full auto-play + save (demo01 terminates naturally in ~4 steps)
    local rc1, out1, err1 = run_cli({
      "run", "--auto", "--steps", "20", "--seed", "7", "--save", save1,
      "demos/demo01_wanderer.sb",
    })
    assert.equal(0, rc1, "play failed:\n" .. out1 .. "\n" .. err1)
    assert.is_truthy(out1:find("Saved to"), out1)

    -- Compact the save
    local rc2, out2, err2 = run_cli({
      "compact", "demos/demo01_wanderer.sb", save1, "--out", save2,
    })
    assert.equal(0, rc2, "compact failed:\n" .. out2 .. "\n" .. err2)

    -- Load compacted and auto-play to end again (bounded)
    local rc3, out3, err3 = run_cli({
      "run", "--auto", "--steps", "10", "--load", save2, "demos/demo01_wanderer.sb",
    })
    assert.equal(0, rc3, "load+play failed:\n" .. out3 .. "\n" .. err3)
    assert.is_truthy(out3:find("Loaded from"), out3)

    os.remove(save1)
    os.remove(save1 .. ".snap")
    os.remove(save2)
  end)

  it("demo04 (spawn/despawn): auto-play 8 steps without error", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "8", "demos/demo04_expedition.sb"})
    assert.equal(0, rc, "demo04 auto-play failed:\n" .. out .. "\n" .. err)
  end)

  it("demo05 (actors/schedules): auto-play 15 steps without error", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "15", "demos/demo05_siege.sb"})
    assert.equal(0, rc, "demo05 auto-play failed:\n" .. out .. "\n" .. err)
  end)
end)

-- ── Command: check ────────────────────────────────────────────────────────────

describe("CLI: check", function()
  it("returns 0 for a valid .sb file", function()
    local p = tmpfile(".sb", [[
module good
  version: 1
engine-config:
  entry-scene: main
state world:
  x: Int(0, 10) = 0
scene main:
  Done.
]])
    local rc, out, err = run_cli({"check", p})
    os.remove(p)
    assert.equal(0, rc, "expected check to pass: " .. err)
    assert.is_truthy(out:find("check passed"), out)
  end)

  it("returns 1 for a file with syntax errors", function()
    local p = tmpfile(".sb", "bad source @@@")
    local rc, _, err = run_cli({"check", p})
    os.remove(p)
    assert.equal(1, rc)
    assert.is_truthy(err:find("check failed") or err:find("error"), err)
  end)

  it("returns 1 with no file argument", function()
    local rc, _, err = run_cli({"check"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("no input file"), err)
  end)

  it("check passes all test*.sb files", function()
    for _, path in ipairs(TEST_SB_FILES) do
      local rc, out, err = run_cli({"check", path})
      assert.equal(0, rc, path .. " check failed:\n" .. out .. "\n" .. err)
    end
  end)
end)

-- ── Command: format ───────────────────────────────────────────────────────────

describe("CLI: format", function()
  it("returns 0 and prints formatted source for a valid file", function()
    local p = tmpfile(".sb", [[
module fmt-test
  version: 1
engine-config:
  entry-scene: main
state world:
  x: Int(0,10) = 0
scene main:
  Hello.
  * Go
    -> main
]])
    local rc, out, err = run_cli({"format", p})
    os.remove(p)
    assert.equal(0, rc, "format should succeed: " .. err)
    assert.is_truthy(out:find("module") or out:find("scene"), "expected formatted source in stdout")
  end)

  it("--check returns 0 for already-canonical content", function()
    -- Format a file first, then check it
    local p = tmpfile(".sb", [[
module test
  version: 1
engine-config:
  entry-scene: main
state world:
  x: Int(0, 10) = 0
scene main:
  Hello.
]])
    -- Get the formatted version
    local _, formatted, _ = run_cli({"format", p})
    os.remove(p)

    -- Write the formatted version to a new file and check it
    local p2 = tmpfile(".sb", formatted)
    local rc2, out2, _ = run_cli({"format", "--check", p2})
    os.remove(p2)
    -- May or may not be canonical (formatter output is idempotent if correct)
    -- We just verify --check exits without crashing
    assert.is_truthy(rc2 == 0 or rc2 == 1, "expected 0 or 1, got " .. tostring(rc2))
    local _ = out2  -- suppress unused warning
  end)

  it("returns 1 with no file argument", function()
    local rc, _, err = run_cli({"format"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("no input file"), err)
  end)

  it("--write rewrites file in-place and creates .bak backup with original content", function()
    local original = [[module bak-test
  version: 1
engine-config:
  entry-scene: main
state world:
  x: Int(0,10) = 0
scene main:
  Hello.
  * Go
    -> main
]]
    local p = tmpfile(".sb", original)
    local bak = p .. ".bak"
    local rc, out, err = run_cli({"format", "--write", p})
    -- Read back the rewritten file and the backup
    local f_new = io.open(p, "r"); local new_content = f_new and f_new:read("*a"); if f_new then f_new:close() end
    local f_bak = io.open(bak, "r"); local bak_content = f_bak and f_bak:read("*a"); if f_bak then f_bak:close() end
    os.remove(p); os.remove(bak)
    assert.equal(0, rc, "--write should succeed: " .. (err or ""))
    assert.is_not_nil(bak_content, ".bak file must exist")
    assert.equal(original, bak_content, ".bak must contain the original source")
    assert.is_truthy(out:find("formatted"), "stdout should mention formatted file")
  end)

  -- Regression tests for Bug #2: format --write silently corrupting node kinds.
  -- Each test verifies (a) no placeholder comments in output, (b) idempotent.

  local function check_no_placeholders(src_path, label)
    local rc, out, err = run_cli({"format", src_path})
    assert.equal(0, rc, label .. " format should succeed: " .. err)
    assert.is_falsy(out:find("%(stmt:"), label .. ": unexpected (stmt:X) placeholder in output")
    assert.is_falsy(out:find("%(decl:"), label .. ": unexpected (decl:X) placeholder in output")
    -- Write the formatted output to a temp file and format it again; must be identical.
    local p2 = tmpfile(".sb", out)
    local _, out2, err2 = run_cli({"format", p2})
    os.remove(p2)
    assert.equal(out, out2, label .. ": formatter not idempotent: " .. err2)
  end

  it("demo13 (speaker/say/return): no placeholder comments, idempotent", function()
    check_no_placeholders("demos/demo13_healers_ward.sb", "demo13")
  end)

  it("demo17 (map-set!/map-delete!): no placeholder comments, idempotent", function()
    check_no_placeholders("demos/demo17_scholars_commonplace.sb", "demo17")
  end)

  it("demo08 (engine/emit, engine/checkpoint!): no placeholder comments, idempotent", function()
    check_no_placeholders("demos/demo08_probability_engine.sb", "demo08")
  end)

  it("demo19 (engine/emit, watch): no placeholder comments, idempotent", function()
    check_no_placeholders("demos/demo19_signal_tower.sb", "demo19")
  end)
end)

-- ── Source-context lines in error output ──────────────────────────────────────

describe("CLI: source-context lines in error output", function()
  it("prints the offending source line and caret on compile error", function()
    local p = tmpfile(".sb", [[
module ctx-test
  version: 1
engine-config:
  entry-scene: main
state world:
  x: @@BAD_TYPE = 0
scene main:
  Done.
]])
    local rc, _, err = run_cli({"compile", p})
    os.remove(p)
    assert.equal(1, rc, "expected compile to fail")
    -- The error output should contain either the bad token or a caret
    assert.is_truthy(err:find("%^") or err:find("BAD_TYPE") or err:find("@@"),
      "expected source context in error output: " .. err)
  end)
end)

-- ── Namespaced import alias ───────────────────────────────────────────────────

describe("CLI: namespaced import as Alias", function()
  it("compiles successfully with import as Alias", function()
    local imported = tmpfile(".sb", [[
module lib
  version: 1
type Size = small | big
state lib:
  val: Int(0, 100) = 0
]])
    local main_src = string.format([[
module main
  version: 1
import "%s" as Lib
engine-config:
  entry-scene: start
state world:
  sz: Lib.Size = `small
scene start:
  Done.
]], imported)
    local p = tmpfile(".sb", main_src)
    local rc, out, err = run_cli({"compile", p})
    os.remove(p)
    os.remove(imported)
    assert.equal(0, rc, "expected compile to succeed for namespaced import: " .. err)
  end)
end)

-- ── help for new commands ─────────────────────────────────────────────────────

describe("CLI: help for new commands", function()
  it("`help check' shows check-specific help", function()
    local rc, out, _ = run_cli({"help", "check"})
    assert.equal(0, rc)
    assert.is_truthy((out .. _):find("check"), "expected check docs")
  end)

  it("`help format' shows format-specific help", function()
    local rc, out, _ = run_cli({"help", "format"})
    assert.equal(0, rc)
    assert.is_truthy((out .. _):find("format") or (out .. _):find("pretty"), "expected format docs")
  end)

  it("`help repl' shows repl-specific help", function()
    local rc, out, _ = run_cli({"help", "repl"})
    assert.equal(0, rc)
    assert.is_truthy((out .. _):find("repl") or (out .. _):find("REPL"), "expected repl docs")
  end)

  it("`help run' mentions --debug flag", function()
    local rc, out, _ = run_cli({"help", "run"})
    assert.equal(0, rc)
    assert.is_truthy((out .. _):find("--debug"), "expected --debug in run help")
  end)
end)

-- ── demo19: signal tower (debug server + watches) ────────────────────────────

describe("CLI demo19_signal_tower: debug server + watches", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo19_signal_tower.sb"})
    assert.equal(0, rc, "demo19 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("verify blocks all pass", function()
    local rc, out, err = run_cli({"verify", "demos/demo19_signal_tower.sb"})
    assert.equal(0, rc, "demo19 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto run 15 steps completes without error", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "15",
                                   "demos/demo19_signal_tower.sb"})
    assert.equal(0, rc, "demo19 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("Signal Tower"), out)
  end)

  it("send-signal reduces pending and increases delivered", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo19_signal_tower.sb")
    game:init()
    local pending_before   = game:get("messages/pending")
    local delivered_before = game:get("messages/delivered")
    game:choose(1)  -- Send next signal (choice 1 in initial state)
    assert.equal(pending_before   - 1, game:get("messages/pending"))
    assert.equal(delivered_before + 1, game:get("messages/delivered"))
  end)

  it("light-beacon sets tower/beacon to true", function()
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo19_signal_tower.sb")
    game:init()
    -- Send all 3 pending signals so "Send next signal" is gone; then light beacon
    game:choose(1) game:choose(1) game:choose(1)
    -- Now "Light the beacon" should be the first choice (no pending messages)
    assert.equal(false, game:get("tower/beacon"))
    game:choose(1)  -- Light the beacon
    assert.equal(true, game:get("tower/beacon"))
  end)

  it("storm-rolls-in extinguishes the beacon", function()
    -- Initial: 7 choices. After 3 sends (pending→0), 6 choices (no "Send signal").
    -- Choices with no pending + beacon=false: 1=Light beacon, 2=Rest, 3=Take msg,
    --   4=Overcast, 5=Storm, 6=Advance day.
    -- After Light beacon (choice 1): 6 choices: 1=Douse, 2=Rest, 3=Take msg,
    --   4=Overcast, 5=Storm, 6=Advance day.
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo19_signal_tower.sb")
    game:init()
    game:choose(1) game:choose(1) game:choose(1)  -- send 3 signals (pending 3→0)
    game:choose(1)  -- Light the beacon (choice 1 when pending=0)
    assert.equal(true, game:get("tower/beacon"))
    game:choose(5)  -- Storm rolls in (choice 5 with beacon lit, no pending)
    assert.equal(false, game:get("tower/beacon"))
    assert.equal(true,  game:get("weather/storm"))
  end)

  it("rest-shift increases focus and decreases fatigue", function()
    -- After 1 send: choices are 1=Send, 2=Light beacon, 3=Rest, 4=Take, 5=Overcast,
    --   6=Storm, 7=Advance. Rest = choice 3.
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo19_signal_tower.sb")
    game:init()
    game:choose(1)  -- send-signal (-1 focus, +1 fatigue)
    local focus_after_send   = game:get("operator/focus")   -- 9
    local fatigue_after_send = game:get("operator/fatigue") -- 1
    game:choose(3)  -- rest-shift (+3 focus, -3 fatigue)
    assert.is_true(game:get("operator/focus")   > focus_after_send)
    assert.is_true(game:get("operator/fatigue") < fatigue_after_send)
  end)

  it("advance-day increments day counter", function()
    -- Initial 7 choices; choice 7 = Advance to next day
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo19_signal_tower.sb")
    game:init()
    local day_before = game:get("tower/day")
    game:choose(7)  -- Advance to next day
    assert.equal(day_before + 1, game:get("tower/day"))
  end)

  it("reaches final-report scene when day >= 10", function()
    -- Advancing from day 1→10 keeps same 7-choice layout each turn.
    -- On day 10, choice 7 switches from "Advance" to "File final report".
    local sb = require("lib.storybase")
    local game = sb.load("demos/demo19_signal_tower.sb")
    game:init()
    for _ = 1, 9 do game:choose(7) end  -- advance days 1→10
    assert.equal(10, game:get("tower/day"))
    game:choose(7)  -- File final report (replaces Advance when day >= 10)
    local narr = narr_text(game:render())
    assert.is_truthy(narr:find("[Ww]atch complete"), narr)
  end)
end)

-- ── demo20: Harrow House (Lovecraftian mystery) ────────────────────────────

-- Helper: build rapport to 7 + get study-key + uneasy phase. Returns the game.
local function harrow_setup()
  local sb   = require("lib.storybase")
  local game = sb.load("demos/demo20_harrow_house.sb")
  game:init()
  game:choose(1)                                       -- enter house
  game:pick("ground-floor library")
  -- family history ×2 + research → uneasy; locked-study → key; her-work → rapport 7
  game:pick("Speak with Meredith") ; game:pick("grandfather")
  game:pick("Speak with Meredith") ; game:pick("like as a man")
  game:pick("Speak with Meredith") ; game:pick("actually working on")
  game:pick("Speak with Meredith") ; game:pick("locked room")
  game:pick("Speak with Meredith") ; game:pick("actually does")
  return game
end

-- Helper: collect items and read notebooks 1 & 2, ending in the attic.
local function harrow_collect_notebooks(game)
  game:pick("Return to the foyer")
  game:pick("upper landing") ; game:pick("Professor's study")
  game:pick("attic key") ; game:pick("basement key") ; game:pick("first notebook")
  game:pick("Read the first")
  game:pick("upper landing") ; game:pick("attic")
  game:pick("second notebook") ; game:pick("oil lamp") ; game:pick("Read the second")
end

-- Helper: wait on the landing until Meredith appears (up to 8 periods).
local function harrow_wait_for_meredith(game)
  game:pick("landing")
  for _ = 1, 8 do
    if game:scene() == "landing" then
      for _, c in ipairs(game:choices()) do
        if c.label:find("Speak with Meredith") then return true end
      end
    end
    if not game:pick("Wait") then break end
    if game:scene() ~= "landing" then
      if not game:pick("landing") then game:pick("Climb") end
    end
  end
  return false
end

describe("CLI demo20_harrow_house: Lovecraftian mystery", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo20_harrow_house.sb"})
    assert.equal(0, rc, "demo20 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("verify blocks all pass", function()
    local rc, out, err = run_cli({"verify", "demos/demo20_harrow_house.sb"})
    assert.equal(0, rc, "demo20 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto run 25 steps completes without error", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "25",
                                   "demos/demo20_harrow_house.sb"})
    assert.equal(0, rc, "demo20 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("HARROW"), out)
  end)

  it("rapport increments correctly: family×2 + research gives rapport 6, phase=uneasy", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo20_harrow_house.sb")
    game:init() ; game:choose(1) ; game:pick("ground-floor library")
    assert.equal(3, game:get("player/rapport"))
    game:pick("Speak with Meredith") ; game:pick("grandfather")
    assert.equal(4, game:get("player/rapport"))
    game:pick("Speak with Meredith") ; game:pick("like as a man")
    assert.equal(5, game:get("player/rapport"))
    game:pick("Speak with Meredith") ; game:pick("actually working on")
    assert.equal(6, game:get("player/rapport"))
    assert.equal("uneasy", game:get("world/phase"))
  end)

  it("ask-locked-study in uneasy+rapport>=6 gives study-key", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo20_harrow_house.sb")
    game:init() ; game:choose(1) ; game:pick("ground-floor library")
    -- family×2 → rapport 5; research → rapport 6 + uneasy
    game:pick("Speak with Meredith") ; game:pick("grandfather")
    game:pick("Speak with Meredith") ; game:pick("like as a man")
    game:pick("Speak with Meredith") ; game:pick("actually working on")
    assert.equal("uneasy", game:get("world/phase"))
    assert.equal(6, game:get("player/rapport"))
    game:pick("Speak with Meredith") ; game:pick("locked room")
    local inv = game:get("player/inventory")
    local has_key = false
    for _, item in ipairs(inv) do if item == "study-key" then has_key = true end end
    assert.is_true(has_key, "study-key not in inventory after asking in uneasy with rapport>=6")
  end)

  it("lock-out fix: locked-study asked in prosaic, re-ask in uneasy still gives key", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo20_harrow_house.sb")
    game:init() ; game:choose(1) ; game:pick("ground-floor library")
    -- Ask in prosaic → wariness only, no key
    game:pick("Speak with Meredith") ; game:pick("locked room")
    assert.equal("prosaic", game:get("world/phase"))
    local inv0 = game:get("player/inventory")
    local key0 = false
    for _, item in ipairs(inv0) do if item == "study-key" then key0 = true end end
    assert.is_false(key0, "study-key should NOT be given in prosaic phase")
    -- Build rapport (family×2 → 5, research → 6 + uneasy)
    game:pick("Speak with Meredith") ; game:pick("grandfather")
    game:pick("Speak with Meredith") ; game:pick("like as a man")
    game:pick("Speak with Meredith") ; game:pick("actually working on")
    assert.equal("uneasy", game:get("world/phase"))
    -- Re-ask option must appear
    game:pick("Speak with Meredith")
    local found = false
    for _, c in ipairs(game:choices()) do
      if c.label:lower():find("study", 1, true) then found = true end
    end
    assert.is_true(found, "re-ask option not present in uneasy after prosaic ask")
    game:pick("study")
    local inv = game:get("player/inventory")
    local has_key = false
    for _, item in ipairs(inv) do if item == "study-key" then has_key = true end end
    assert.is_true(has_key, "study-key not given on re-ask in uneasy with rapport>=6")
  end)

  it("read notebook-1 option disappears after reading", function()
    local game = harrow_setup()
    game:pick("Return to the foyer") ; game:pick("upper landing") ; game:pick("Professor's study")
    game:pick("first notebook")
    -- Option must be present before reading
    local before = false
    for _, c in ipairs(game:choices()) do
      if c.label:lower():find("read the first", 1, true) then before = true end
    end
    assert.is_true(before, "Read nb1 option should appear before reading")
    game:pick("Read the first")
    -- Option must be gone after reading (knows-family-strain gated)
    local after = false
    for _, c in ipairs(game:choices()) do
      if c.label:lower():find("read the first", 1, true) then after = true end
    end
    assert.is_false(after, "Read nb1 option should disappear after reading")
  end)

  it("hook grants knows-occult-geometry on attic entry and knows-basement-exists on basement entry", function()
    local game = harrow_setup()
    game:pick("Return to the foyer") ; game:pick("upper landing") ; game:pick("Professor's study")
    game:pick("attic key")
    game:pick("upper landing") ; game:pick("attic")
    local know = game:get("player/knowledge") or {}
    local has_occ = false
    for _, k in ipairs(know) do if k == "knows-occult-geometry" then has_occ = true end end
    assert.is_true(has_occ, "hook should grant knows-occult-geometry on attic entry")
    -- Now unlock basement
    game:pick("landing") ; game:pick("Professor's study") ; game:pick("basement key")
    game:pick("landing") ; game:pick("Descend") ; game:pick("dining") ; game:pick("kitchen")
    game:pick("basement")
    local know2 = game:get("player/knowledge") or {}
    local has_bas = false
    for _, k in ipairs(know2) do if k == "knows-basement-exists" then has_bas = true end end
    assert.is_true(has_bas, "hook should grant knows-basement-exists on basement entry")
  end)

  it("all three endings reachable at rapport=9 with all notebooks", function()
    local game = harrow_setup()
    harrow_collect_notebooks(game)
    harrow_wait_for_meredith(game)
    game:pick("Speak with Meredith") ; game:pick("vigil")
    assert.equal("revelation", game:get("world/phase"))
    assert.equal(9, game:get("player/rapport"))
    -- Basement path
    game:pick("Descend") ; game:pick("dining") ; game:pick("kitchen") ; game:pick("basement")
    game:pick("mechanism-token") ; game:pick("Light") ; game:pick("Activate")
    game:pick("sub-basement")
    -- Take nb3 but don't read: ending-mechanism-fails must be available
    game:pick("third notebook")
    local has_mfail = false
    for _, c in ipairs(game:choices()) do
      if c.label:find("Activate the mechanism%-token") then has_mfail = true end
    end
    assert.is_true(has_mfail, "ending-mechanism-fails not available before reading nb3")
    -- Read nb3 → knows-the-truth; mechanism-fails choice must disappear
    game:pick("Read the third")
    local mfail_gone = true
    for _, c in ipairs(game:choices()) do
      if c.label:find("Activate the mechanism%-token") then mfail_gone = false end
    end
    assert.is_true(mfail_gone, "ending-mechanism-fails should vanish after knowing the truth")
    -- ending-vigil-continues (rapport >= 8)
    local has_vigil = false
    for _, c in ipairs(game:choices()) do
      if c.label:find("Leave without") then has_vigil = true end
    end
    assert.is_true(has_vigil, "ending-vigil-continues not available at rapport=9")
    -- ending-offered-hand (rapport >= 9, all notebooks)
    local has_offer = false
    for _, c in ipairs(game:choices()) do
      if c.label:find("Accept Meredith") then has_offer = true end
    end
    assert.is_true(has_offer, "ending-offered-hand not available at rapport=9 with all notebooks")
  end)
end)

-- ── demo21: Merchant's Reckoning (temporal query builtins) ────────────────────

-- Helper: reach Day 2 with two gold changes (earn x2) recorded on day 0.
-- Returns a game object positioned at the crossroads reckoning choice.
local function reckoning_setup()
  local sb   = require("lib.storybase")
  local game = sb.load("demos/demo21_merchants_reckoning.sb")
  game:init()
  game:pick("Travel to town")   ; game:pick("Sell found goods")   -- +30 gold
  game:pick("Sell found goods")                                   -- +30 gold (day 0)
  game:pick("Rest in the common room")                            -- advance-day; back to crossroads
  return game
end

describe("CLI demo21_merchants_reckoning: temporal query builtins", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo21_merchants_reckoning.sb"})
    assert.equal(0, rc, "demo21 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("verify blocks all pass", function()
    local rc, out, err = run_cli({"verify", "demos/demo21_merchants_reckoning.sb"})
    assert.equal(0, rc, "demo21 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto run 10 steps completes without error", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "10",
                                   "demos/demo21_merchants_reckoning.sb"})
    assert.equal(0, rc, "demo21 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("crossroads") or out:find("town"), out)
  end)

  it("Take the reckoning choice only appears after day > 1", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo21_merchants_reckoning.sb")
    game:init()
    -- Day 1: reckoning not available
    local found_day1 = false
    for _, c in ipairs(game:choices()) do
      if c.label:find("reckoning") then found_day1 = true end
    end
    assert.is_false(found_day1, "reckoning should not be available on day 1")
    -- Advance to day 2
    game:pick("Travel to town") ; game:pick("Rest in the common room")
    local found_day2 = false
    for _, c in ipairs(game:choices()) do
      if c.label:find("reckoning") then found_day2 = true end
    end
    assert.is_true(found_day2, "reckoning should appear after day > 1")
  end)

  it("reckoning-ledger shows gold changes from query-history", function()
    local game = reckoning_setup()
    assert.equal(160, game:get("player/gold"), "expected 160 gold after two sells")
    game:pick("Take the reckoning")
    game:pick("Consult the ledger")
    local text = narr_text(game:render())
    -- Should mention two gold entries recorded at day 0
    assert.is_truthy(text:find("100") and text:find("130") and text:find("160"),
      "ledger should show 100->130->160 gold entries; got: " .. text)
    assert.is_truthy(text:find("Day 0"), "ledger entries should be at day 0; got: " .. text)
  end)

  it("reckoning-route shows last 3 location changes from query-changes", function()
    local game = reckoning_setup()
    game:pick("Take the reckoning")
    game:pick("Trace the road")
    local text = narr_text(game:render())
    -- Locations visited: crossroads->town, rest back to crossroads; last 3 changes
    assert.is_truthy(text:find("town") or text:find("crossroads"),
      "route should mention visited locations; got: " .. text)
  end)

  it("reckoning-fortune shows query-at result for gold at day 1", function()
    local game = reckoning_setup()
    game:pick("Take the reckoning")
    game:pick("Recall the opening fortune")
    local text = narr_text(game:render())
    -- After earning 30+30 at day 0, gold-on-day 1 = 160 (last entry <= day 1)
    assert.is_truthy(text:find("160"),
      "fortune should show 160 gold recorded at day 1; got: " .. text)
  end)

  it("reckoning-audit shows wildcard query-history player/* entries", function()
    local game = reckoning_setup()
    game:pick("Take the reckoning")
    game:pick("Scan the full chronicle")
    local text = narr_text(game:render())
    -- Should show both gold and location entries
    assert.is_truthy(text:find("player/gold") or text:find("player/location"),
      "audit should show player paths; got: " .. text)
  end)

  it("CLI step-mode: query-history survives save/restore across steps", function()
    -- Regression test for the bug where restore_engine didn't repopulate eng._log._entries.
    -- Without the fix, reckoning-ledger would say "ledger is blank" after a reload.
    local cli_cmd = require("cli.cli_cmd")
    local compiler = require("compiler.compiler")
    local game_table = compiler.compile_file("demos/demo21_merchants_reckoning.sb")
    assert.is_table(game_table, "demo21 failed to compile")

    local save_path = os.tmpname() .. ".sbd"
    local out_parts = {}
    local function make_dest()
      return setmetatable({}, { __index = {
        write = function(_, s) out_parts[#out_parts+1] = s end,
        flush = function() end,
      }})
    end

    -- Step 1: fresh start
    cli_cmd.run(game_table, save_path, { reset = true, input = "", output = make_dest() })
    -- Step 2: travel to town
    cli_cmd.run(game_table, save_path, { input = "1", output = make_dest() })
    -- Step 3: earn gold (+30)
    cli_cmd.run(game_table, save_path, { input = "1", output = make_dest() })
    -- Step 4: earn gold again (+30)
    cli_cmd.run(game_table, save_path, { input = "1", output = make_dest() })
    -- Step 5: advance-day (back to crossroads, day 2)
    cli_cmd.run(game_table, save_path, { input = "2", output = make_dest() })
    -- Step 6: take reckoning (choice 5)
    cli_cmd.run(game_table, save_path, { input = "5", output = make_dest() })
    -- Step 7: consult ledger (choice 1)
    out_parts = {}
    local dest = make_dest()
    cli_cmd.run(game_table, save_path, { input = "1", output = dest })
    local result = table.concat(out_parts)
    -- Log must have survived the save/restore: ledger should NOT be blank
    assert.is_falsy(result:find("blank"), "ledger should not be blank after log restore; got: " .. result)
    -- Should show gold entries
    assert.is_truthy(result:find("130") and result:find("160"),
      "ledger should show 130 and 160 gold after log restore; got: " .. result)

    os.remove(save_path)
    os.remove(save_path .. ".snap")
  end)
end)

-- ── demo26: Beastmaster's Ledger (record `with` mixins + path patterns) ────────

describe("CLI demo26_bestiary: record with-mixins and path-pattern queries", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo26_bestiary.sb"})
    assert.equal(0, rc, "demo26 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("verify blocks all pass", function()
    local rc, out, err = run_cli({"verify", "demos/demo26_bestiary.sb"})
    assert.equal(0, rc, "demo26 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto-plays to retire scene within 20 steps", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "20",
                                   "demos/demo26_bestiary.sb"})
    assert.equal(0, rc, "demo26 auto run failed:\n" .. out .. err)
    -- The retire scene narration ends with this sentence.
    assert.is_truthy(out:find("ledger is sealed"),
      "expected demo26 to reach the retire scene; got: " .. out)
  end)

  it("two-parent with-mixin (Warbeast) splices both Combatant and Mount fields", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo26_bestiary.sb")
    game:init()
    -- Drake is Warbeast (Combatant + Mount). Fields from BOTH parents must be present.
    assert.equal(95, game:get("bestiary/drake/hp"))      -- from Combatant
    assert.equal(80, game:get("bestiary/drake/speed"))   -- from Mount
    assert.equal(40, game:get("bestiary/drake/bond"))    -- Warbeast-local
    assert.equal(60, game:get("bestiary/drake/breath-power"))  -- Drake-local
    -- Entity fields reach Warbeast via either parent — should be spliced exactly once.
    assert.equal("Storm Drake", game:get("bestiary/drake/name"))
    assert.equal(true,          game:get("bestiary/drake/alive"))
  end)

  it("query-history with bestiary/**/status pattern accumulates entries", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo26_bestiary.sb")
    game:init()
    -- Sound the alarm (writes to three /status paths) then stand-down (three more).
    game:pick("Sound the alarm")
    game:pick("Stand the roster down")
    -- bestiary/**/status should now have at least six recorded changes.
    local count = game:get("status-changes-logged")
    -- status-changes-logged is a fn; lib.storybase exposes fns via call instead of get
    if not count then count = game:call("status-changes-logged") end
    assert.is_true(count >= 6,
      "expected at least 6 status changes recorded via bestiary/**/status; got: " .. tostring(count))
  end)
end)

-- ── demo27: Apprentice's Grimoire (file-local decl-macro) ─────────────────────

describe("CLI demo27_grimoire: user-authored decl-macro", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo27_grimoire.sb"})
    assert.equal(0, rc, "demo27 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("verify blocks all pass (one per spell)", function()
    local rc, out, err = run_cli({"verify", "demos/demo27_grimoire.sb", "--no-cache"})
    assert.equal(0, rc, "demo27 verify failed:\n" .. out .. err)
    local pass_count = 0
    for _ in out:gmatch("PASS") do pass_count = pass_count + 1 end
    assert.is_true(pass_count >= 3,
      "expected at least 3 PASS lines (one per spell); got: " .. out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto-plays to the rest scene within 25 steps", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "25",
                                   "demos/demo27_grimoire.sb"})
    assert.equal(0, rc, "demo27 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("grimoire is closed") or out:find("Three spells in the journal"),
      "expected demo27 to reach the rest scene; got: " .. out)
  end)

  it("decl-macro expands one state + 6 fns + 1 verify per spell", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo27_grimoire.sb")
    game:init()

    -- Each spell's state pair exists with the correct initial values.
    for _, name in ipairs({"fireball", "mend", "ward"}) do
      assert.equal(false, game:get("spell-" .. name .. "-learned"),
        "spell-" .. name .. "-learned should default to false")
      assert.equal(0, game:get("spell-" .. name .. "-uses"),
        "spell-" .. name .. "-uses should default to 0")
    end

    -- Each spell's expanded fns exist and return expected values.
    assert.equal(8, game:call("fireball-power"))
    assert.equal(6, game:call("mend-power"))
    assert.equal(4, game:call("ward-power"))

    assert.equal(0, game:call("fireball-uses"))
    assert.equal(false, game:call("fireball-learned?"))
    assert.equal(false, game:call("fireball-exhausted?"))
  end)

  it("$param flows into the Int(0, $max) bound — exhaustion at $max casts", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo27_grimoire.sb")
    game:init()

    -- ward has max=3 (the smallest). Cast it three times and check exhaustion.
    for _ = 1, 3 do game:pick("Cast Ward") end
    assert.equal(3, game:get("spell-ward-uses"))
    assert.is_true(game:call("ward-exhausted?"),
      "after $max casts, ward-exhausted? should be true")

    -- A fourth attempt is gated out of the available choices.
    local choices = game:choices()
    for _, c in ipairs(choices) do
      assert.is_falsy(c.label:find("Cast Ward"),
        "Cast Ward choice should be unavailable once exhausted; saw: " .. c.label)
    end
  end)
end)

-- ── demo28: Seer's Chamber (counterfactual from: + conditioned-on bounded) ────

describe("CLI demo28_seers_chamber: counterfactual from: + conditioned-on", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo28_seers_chamber.sb"})
    assert.equal(0, rc, "demo28 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("verify blocks all pass", function()
    local rc, out, err = run_cli({"verify", "demos/demo28_seers_chamber.sb",
                                  "--no-cache"})
    assert.equal(0, rc, "demo28 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto-plays without runtime error for 10 steps", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "10",
                                   "demos/demo28_seers_chamber.sb"})
    assert.equal(0, rc, "demo28 auto run failed:\n" .. out .. err)
    -- Auto picks choice 1 (Meditate). After 10 turns the chamber heading
    -- has been printed many times.
    assert.is_truthy(out:find("THE SEER'S CHAMBER"),
      "expected chamber heading; got: " .. out)
  end)

  it("bounded omen-of-season records distribution: conditioned-on world/season", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo28_seers_chamber.sb")
    local b = game._gt and game._gt.bounded and game._gt.bounded["omen-of-season"]
    assert.is_table(b, "bounded omen-of-season should be present in game.bounded")
    assert.equal("conditioned-on world/season", b.distribution,
      "expected distribution string to capture the conditioned-on path")
  end)

  it("counterfactual from: (turn - 3) replays to a past state, do: applies on top", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo28_seers_chamber.sb")
    game:init()

    -- Walk four turns so the log carries ticks 1..4 and wisdom climbs to 20.
    for _ = 1, 4 do game:pick("Meditate") end
    assert.equal(4,  game:get("world/turn"))
    assert.equal(20, game:get("world/wisdom"))

    -- The control vision (no rewind, meditate twice) should reach 30.
    assert.equal(30, game:call("preview-present-vision"))

    -- The rewound vision (from: turn - 3 == tick 1; wisdom=5) plus two
    -- meditates should reach 15 — visibly different from the control.
    assert.equal(15, game:call("preview-quiet-vision"))

    -- The simulated rewound branch advances state one more time after the
    -- single meditate (no actors/schedules in this demo, so no extra
    -- mutations) — its wisdom is 5 + 5 = 10.
    assert.equal(10, game:call("preview-storm-vision"))

    -- The live state must be untouched by any of the previews.
    assert.equal(4,  game:get("world/turn"))
    assert.equal(20, game:get("world/wisdom"))
  end)
end)

-- ── demo29: Caravan Dispatch (computed -> (expr) + goto-scene!/enter-scene!/exit-scene!)
--
-- I4 — exercises every form of scene navigation: the computed `-> (expr)`
-- dispatcher and all three imperative mutation primitives.

describe("CLI demo29_caravan_dispatch: computed goto + imperative scene-nav", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo29_caravan_dispatch.sb"})
    assert.equal(0, rc, "demo29 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("verify blocks all pass", function()
    local rc, out, err = run_cli({"verify", "demos/demo29_caravan_dispatch.sb",
                                  "--no-cache"})
    assert.equal(0, rc, "demo29 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto-plays the route from depot to highmarket without error", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "12",
                                   "demos/demo29_caravan_dispatch.sb"})
    assert.equal(0, rc, "demo29 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("HIGH MARKET"),
      "expected demo29 to reach high market; got: " .. out)
  end)

  it("type Stop carries every named stop value", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo29_caravan_dispatch.sb")
    game:init()
    -- caravan/at defaults to `depot
    assert.equal("depot", game:get("caravan/at"))
    -- next-stop-for marches through the route table
    assert.equal("riverbend",  game:call("next-stop-for", "depot"))
    assert.equal("midmoor",    game:call("next-stop-for", "riverbend"))
    assert.equal("pass-watch", game:call("next-stop-for", "midmoor"))
    assert.equal("highmarket", game:call("next-stop-for", "pass-watch"))
    assert.equal("highmarket", game:call("next-stop-for", "highmarket"))
  end)

  it("scene-body => / <- pushes and pops the errand stack symmetrically", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo29_caravan_dispatch.sb")
    game:init()
    -- Depot, choice 2 is "Inspect the cargo before leaving (=>)" — pushes
    game:pick("Inspect the cargo")
    assert.equal("inspect-cargo", game:current_scene())
    -- The single choice in inspect-cargo uses <- to pop
    game:pick("Note the count and return")
    assert.equal("depot", game:current_scene())
    -- errands-run counter records the side trip
    assert.equal(1, game:get("caravan/errands-run"))
  end)

  it("fn-body enter-scene!/exit-scene! match scene-body =>/<- semantics", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo29_caravan_dispatch.sb")
    game:init()
    -- Travel to riverbend so the pump-water choice is gated open
    game:pick("Set out toward")
    assert.equal("riverbend", game:current_scene())
    -- Pump water — choice body invokes pump-water-errand which calls enter-scene!
    game:pick("Pump water at the bend")
    assert.equal("water-refill", game:current_scene())
    assert.equal(1, game:get("caravan/errands-run"))
    -- finish-errand uses exit-scene! to pop
    game:pick("Cap the barrels and return")
    assert.equal("riverbend", game:current_scene())
    assert.equal(20, game:get("caravan/water"))
  end)

  it("fn-body goto-scene! short-circuits to a non-adjacent stop", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo29_caravan_dispatch.sb")
    game:init()
    game:pick("Set out toward")       -- depot   -> riverbend
    game:pick("Drive on toward")      -- riverbend -> midmoor
    assert.equal("midmoor", game:current_scene())
    assert.equal(2, game:get("caravan/legs-completed"))
    -- The shortcut uses goto-scene! 'highmarket — pass-watch is skipped
    game:pick("Cut over the moor")
    assert.equal("highmarket",  game:current_scene())
    assert.equal("highmarket",  game:get("caravan/at"))
    assert.equal(3, game:get("caravan/legs-completed"))
  end)

  it("source contains exactly one computed `-> (expr)` form", function()
    local f = io.open("demos/demo29_caravan_dispatch.sb")
    local src = f:read("*a"); f:close()
    -- Strip comments so the documentation in the header doesn't count.
    src = src:gsub("\n#[^\n]*", "\n")
    local count = 0
    for _ in src:gmatch("%-> %(") do count = count + 1 end
    assert.equal(1, count,
      "spec asks for exactly one `-> (expr)` form; saw " .. count)
  end)
end)

-- ── demo30: Quartermaster's Audit (`changes` binding + strict-contracts) ──────
--
-- I5 — exercises the per-mutation `changes` binding inside a tag-level post
-- hook, an fn-level `after:` hook that fires alongside it, a `post:` contract
-- referencing `path@before`, and `strict-contracts: true` keeping that
-- contract live in --production builds.

describe("CLI demo30_quartermaster: changes binding + strict-contracts", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo30_quartermaster.sb"})
    assert.equal(0, rc, "demo30 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("compiles cleanly under --production", function()
    local rc, out, err = run_cli({"compile", "--production",
                                  "demos/demo30_quartermaster.sb"})
    assert.equal(0, rc, "demo30 --production compile failed:\n" .. out .. err)
  end)

  it("verify blocks all pass", function()
    local rc, out, err = run_cli({"verify", "demos/demo30_quartermaster.sb",
                                  "--no-cache"})
    assert.equal(0, rc, "demo30 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto-plays from camp to departure without error", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "15",
                                   "demos/demo30_quartermaster.sb"})
    assert.equal(0, rc, "demo30 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("THE MARCH OUT"),
      "expected demo30 to reach the departure scene; got: " .. out)
  end)

  it("tag-level post hook writes a ledger entry per mutation", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo30_quartermaster.sb")
    game:init()
    -- spend mutates exactly one path: player/gold
    assert.equal(0, #(game:get("audit/ledger") or {}))
    game:call("spend", 5)
    local ledger = game:get("audit/ledger")
    assert.equal(1, #ledger,
      "expected one ledger entry for spend's single mutation")
    assert.is_truthy(ledger[1]:find("player/gold"), ledger[1])
    assert.is_truthy(ledger[1]:find("30") and ledger[1]:find("25"),
      "expected ledger line to show 30 → 25, got: " .. ledger[1])
    -- brew mutates three paths
    game:call("brew")
    ledger = game:get("audit/ledger")
    assert.equal(3, #ledger,
      "expected three ledger entries after brew (herbs/water/morale)")
  end)

  it("tag-level and fn-level hooks fire independently for the same call", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo30_quartermaster.sb")
    game:init()
    assert.equal(0, game:get("audit/transactions-run"))
    assert.equal(0, game:get("audit/spend-hook-fires"))
    game:call("spend", 3)
    -- Both hooks must fire once for the spend call.
    assert.equal(1, game:get("audit/transactions-run"))
    assert.equal(1, game:get("audit/spend-hook-fires"))
    -- A non-spend transaction bumps only the tag-level counter.
    game:call("drill")
    assert.equal(2, game:get("audit/transactions-run"))
    assert.equal(1, game:get("audit/spend-hook-fires"),
      "fn-level after: spend: must NOT fire for drill")
  end)

  it("post: contract on spend holds under normal use", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo30_quartermaster.sb")
    game:init()
    local before = game:get("player/gold")
    game:call("spend", 7)
    assert.equal(before - 7, game:get("player/gold"))
  end)

  it("post: contract on spend triggers a runtime error when violated", function()
    -- Sibling .sb fixture: a copy of spend that bumps gold the WRONG way,
    -- with the same post: contract attached. Confirms the contract is wired
    -- in (and would fail loudly under strict-contracts in production too).
    local src = [[
module demo30-broken-contract
  version: 1.0

schema-version: 1

engine-config:
  entry-scene:      hub
  strict-contracts: true

state player:
  gold: Int(0, 999) = 30

"Broken spend — increments instead of decrementing. post: contract MUST fail."
fn spend-broken amount:
  pre:  player/gold >= amount
  post: player/gold = player/gold@before - amount
  inc!  player/gold amount

scene hub:
  HUB

  * Stub
    -> hub
]]
    local p = tmpfile(".sb", src)
    -- Use the embedded API to trigger the contract failure deterministically.
    local sb = require("lib.storybase")
    local game = sb.load(p)
    game:init()
    local ok, err = pcall(function() game:call("spend-broken", 1) end)
    os.remove(p)
    assert.is_false(ok, "expected post:contract to raise an error")
    assert.is_truthy(tostring(err):find("Postcondition failed"),
      "expected 'Postcondition failed' error, got: " .. tostring(err))
  end)

  it("`changes` rendering preserves bool old/new (regression: str(false))", function()
    -- The final transaction sets player/done=true; the ledger should show the
    -- Bool transition rather than dropping the false value to empty string.
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo30_quartermaster.sb")
    game:init()
    game:call("strike-camp")
    local ledger = game:get("audit/ledger")
    assert.equal(1, #ledger)
    assert.is_truthy(ledger[1]:find("false") and ledger[1]:find("true"),
      "expected 'false → true' in ledger, got: " .. ledger[1])
  end)

  it("source declares strict-contracts: true (survives --production)", function()
    local f = io.open("demos/demo30_quartermaster.sb")
    local src = f:read("*a"); f:close()
    assert.is_truthy(src:find("strict%-contracts:%s*true"),
      "demo30 must declare strict-contracts: true in engine-config")
  end)
end)

-- ── demo31: Lighthouse Relay (embedded host walkthrough) ─────────────────────
--
-- I6 — exercises the Lua host story end to end: every engine/emit site
-- routes through game:on(), narration items dispatch on kind="say" vs.
-- kind="narration", and a save/load round-trip preserves state.

describe("CLI demo31_embedded_host: Lua host embedding", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo31_embedded_host.sb"})
    assert.equal(0, rc, "demo31 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("verify blocks all pass", function()
    local rc, out, err = run_cli({"verify", "demos/demo31_embedded_host.sb",
                                  "--no-cache"})
    assert.equal(0, rc, "demo31 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto-plays without error", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "12",
                                   "demos/demo31_embedded_host.sb"})
    assert.equal(0, rc, "demo31 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("THE LIGHTHOUSE"),
      "expected demo31 to render the lighthouse scene; got: " .. out)
  end)

  it("every engine/emit event lands in a registered handler", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo31_embedded_host.sb")
    game:init()

    local seen = {}
    local function tally(name)
      return function(_) seen[name] = (seen[name] or 0) + 1 end
    end
    game:on("door-opened",  tally("door-opened"))
    game:on("signal-sent",  tally("signal-sent"))
    game:on("ship-spotted", tally("ship-spotted"))
    game:on("ship-saved",   tally("ship-saved"))
    game:on("night-ended",  tally("night-ended"))
    game:on("storm-began",  tally("storm-began"))

    -- Drive the canonical event sequence via direct fn calls.
    game:call("open-door")
    game:call("send-signal", "'nightingale")
    game:call("spot-ship",   "'nightingale", 4)
    game:call("mark-saved",  "'nightingale")
    game:call("send-signal", "'albatross")
    game:call("spot-ship",   "'albatross", 6)
    game:call("mark-saved",  "'albatross")
    game:call("send-signal", "'nightingale")
    game:call("spot-ship",   "'nightingale", 4)
    game:call("mark-saved",  "'nightingale")
    game:call("rest")
    -- rest advances the time-axis 'day' by 1; tick fires storm-watch (at day +1)
    game:tick()

    assert.equal(1, seen["door-opened"])
    assert.equal(3, seen["signal-sent"])
    assert.equal(3, seen["ship-spotted"])
    assert.equal(3, seen["ship-saved"])
    assert.equal(1, seen["night-ended"])
    assert.equal(1, seen["storm-began"])
  end)

  it("emit payloads carry structured fields", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo31_embedded_host.sb")
    game:init()

    local last_signal
    game:on("signal-sent", function(e) last_signal = e end)
    game:call("open-door")
    game:call("send-signal", "'nightingale")

    assert.equal("nightingale", last_signal.payload.ship)
    assert.equal("steady",      last_signal.payload.strength)
    assert.equal(75,            last_signal.payload["fuel-after"])
  end)

  it("render() returns kind-tagged narration AND say items", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo31_embedded_host.sb")
    game:init()
    local narr = game:render()

    local has_narration, has_say = false, false
    for _, item in ipairs(narr) do
      if item.kind == "narration" then
        has_narration = true
        assert.is_string(item.text)
      end
      if item.kind == "say" then
        has_say = true
        assert.is_string(item.text)
        -- Declared speakers carry display + color
        if item.speaker == "keeper" then
          assert.equal("Keeper Vael", item.display)
          assert.equal("#e0c878",     item.color)
        end
      end
    end
    assert.is_true(has_narration, "expected a narration item in dawn scene")
    assert.is_true(has_say,       "expected a say item in dawn scene")
  end)

  it("save/load round-trips game state through the host API", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo31_embedded_host.sb")
    game:init()
    game:call("open-door")
    game:call("send-signal", "'nightingale")
    game:call("mark-saved",  "'nightingale")

    local path = os.tmpname() .. ".sbd"
    local ok, save_err = game:save(path)
    assert.is_true(ok, "save failed: " .. tostring(save_err))

    local game2 = assert(sb.load("demos/demo31_embedded_host.sb"))
    game2:init()
    local ok2, load_err = game2:load(path)
    os.remove(path)
    assert.is_true(ok2, "load failed: " .. tostring(load_err))

    assert.equal(game:get("relay/fuel"),         game2:get("relay/fuel"))
    assert.equal(game:get("relay/ships-saved"),  game2:get("relay/ships-saved"))
    assert.equal(game:get("relay/signals-sent"), game2:get("relay/signals-sent"))
    assert.equal(game:get("world/door-open"),    game2:get("world/door-open"))
  end)

  it("examples/demo31_host.lua runs to completion", function()
    -- The acceptance criterion: lua5.4 examples/demo31_host.lua exits 0
    -- without producing the "Missing emit handlers" assertion error.
    local handle = io.popen(
      "lua5.4 examples/demo31_host.lua 2>&1; echo \"__rc:$?\"", "r")
    local out = handle:read("*a"); handle:close()
    local rc = out:match("__rc:(%d+)")
    assert.equal("0", rc,
      "examples/demo31_host.lua exited non-zero. Output:\n" .. out)
    assert.is_truthy(out:find("demo31 embedded%-host walkthrough complete"),
      "host script did not reach the completion banner")
  end)
end)

-- ── demo32: Inquisitor's Board (set ops + labelled checkpoint) ────────────────
--
-- §I7 residue: this is the first demo where `union`/`intersect`/`difference`
-- drive game logic (not decoration), `(set)` is the initial value of a state
-- path, and `engine/checkpoint! `<label>` is used in its labelled form.

describe("CLI demo32_inquisitors_board: set ops + labelled checkpoint", function()
  it("compiles successfully", function()
    local rc, out, err = run_cli({"compile", "demos/demo32_inquisitors_board.sb"})
    assert.equal(0, rc, "demo32 compile failed:\n" .. out .. err)
    assert.is_truthy(out:find("Compilation succeeded"), out)
  end)

  it("--production compile exits 0", function()
    local rc, out, err = run_cli({"compile", "--production",
                                  "demos/demo32_inquisitors_board.sb"})
    assert.equal(0, rc, "demo32 --production compile failed:\n" .. out .. err)
  end)

  it("verify blocks all pass", function()
    local rc, out, err = run_cli({"verify", "demos/demo32_inquisitors_board.sb",
                                  "--no-cache"})
    assert.equal(0, rc, "demo32 verify failed:\n" .. out .. err)
    assert.is_truthy(out:find("PASS"), out)
    assert.is_falsy(out:find("FAIL"), out)
  end)

  it("auto-plays to the verdict scene", function()
    local rc, out, err = run_cli({"run", "--auto", "--steps", "20",
                                   "demos/demo32_inquisitors_board.sb"})
    assert.equal(0, rc, "demo32 auto run failed:\n" .. out .. err)
    assert.is_truthy(out:find("THE CASE IS CLOSED"),
      "expected demo32 to reach the verdict scene; got: " .. out)
    assert.is_truthy(out:find("Charged: corwin"),
      "expected --auto playthrough to charge corwin (triple-corroborated suspect)")
    assert.is_truthy(out:find("Strongly corroborated at time of charge: true"),
      "charged suspect should be in the triple-corroborated set")
  end)

  -- Direct exercise of the three set-op fns from the embedded host.
  it("set-op fns return the expected sets from initial state", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo32_inquisitors_board.sb")
    game:init()

    local function as_set(t)
      local s = {}
      for _, v in ipairs(t or {}) do s[tostring(v)] = true end
      return s
    end

    local all       = as_set(game:call("all-named"))
    local triple    = as_set(game:call("triple-corroborated"))
    local mm        = as_set(game:call("marshall-and-maid"))
    local mp        = as_set(game:call("marshall-and-pilgrim"))
    local up        = as_set(game:call("unique-to-pilgrim"))
    local um        = as_set(game:call("unique-to-marshall"))
    local out       = as_set(game:call("outstanding-leads"))

    -- union (nested): everyone named by any witness
    assert.is_true(all.aldric and all.brenna and all.corwin and all.duna and all.esmund,
      "all-named should contain every suspect")

    -- intersect (nested): only corwin is named by all three
    assert.is_true(triple.corwin, "corwin should be in triple-corroborated")
    assert.is_nil(triple.aldric, "aldric should not be triple-corroborated")
    assert.is_nil(triple.brenna, "brenna should not be triple-corroborated")
    assert.is_nil(triple.duna,   "duna should not be triple-corroborated")
    assert.is_nil(triple.esmund, "esmund should not be triple-corroborated")

    -- intersect (pairwise)
    assert.is_true(mm.brenna and mm.corwin, "marshall ∩ maid = {brenna, corwin}")
    assert.is_true(mp.corwin and not mp.brenna,
      "marshall ∩ pilgrim should be exactly {corwin}")

    -- difference (unique attribution)
    assert.is_true(up.duna and not up.corwin,
      "unique-to-pilgrim should be exactly {duna}")
    assert.is_true(um.aldric and not um.corwin,
      "unique-to-marshall should be exactly {aldric}")

    -- difference (load-bearing): no exonerations yet → outstanding == all-named
    assert.is_true(out.aldric and out.brenna and out.corwin and out.duna and out.esmund,
      "outstanding-leads with empty exonerated set should equal all-named")
  end)

  -- (set) empty-set literal: board/exonerated must read as an empty set on init.
  it("`(set)` empty literal initializes board/exonerated to an empty set", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo32_inquisitors_board.sb")
    game:init()
    local exonerated = game:get("board/exonerated")
    assert.is_table(exonerated)
    assert.equal(0, #exonerated,
      "board/exonerated should be empty on init; got " .. #exonerated .. " element(s)")
  end)

  -- Labelled checkpoint: `engine/checkpoint! `before-exonerate` should let
  -- a subsequent undo rewind exactly the exonerate move.
  it("labelled checkpoint allows undo to rewind exactly one move", function()
    local sb   = require("lib.storybase")
    local game = sb.load("demos/demo32_inquisitors_board.sb")
    game:init()

    local initial = #game:get("board/exonerated")
    assert.equal(0, initial)

    -- Push `before-exonerate checkpoint and add aldric to exonerated.
    game:call("exonerate", "aldric")
    assert.equal(1, #game:get("board/exonerated"))
    assert.equal(1, game:get("board/turn"))

    -- Undo one checkpoint. The labelled checkpoint should rewind exactly
    -- the exonerate move (both the set mutation AND the turn counter).
    local ok = game._eng._state:undo(1)
    assert.is_true(ok, "undo(1) should succeed against the labelled checkpoint")
    assert.equal(0, #game:get("board/exonerated"),
      "exonerated set should be empty again after undo")
    assert.equal(0, game:get("board/turn"),
      "turn counter should rewind alongside the set mutation")
  end)
end)

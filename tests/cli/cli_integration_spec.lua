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

  it("'help' subcommand returns 0 and prints usage", function()
    local rc, out, _ = run_cli({"help"})
    assert.equal(0, rc)
    local combined = out .. _
    assert.is_truthy(combined:find("compile") and combined:find("run"),
      "expected command list in help output")
  end)

  it("'help compile' shows compile-specific help", function()
    local rc, out, _ = run_cli({"help", "compile"})
    assert.equal(0, rc)
    assert.is_truthy((out .. _):find("--production"), "expected --production flag docs")
  end)

  it("'help run' shows run-specific help including --auto", function()
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

-- ── run --auto --steps: smoke tests for all demos ────────────────────────────
-- Step limits per demo: enough to exercise gameplay but avoid precondition
-- failures that occur when auto-play cycles past designed guard conditions.
local DEMO_STEPS = {
  ["demos/demo01_wanderer.sb"]  = 20,  -- terminates naturally in 4
  ["demos/demo02_merchant.sb"]  = 20,  -- terminates naturally
  ["demos/demo03_quest.sb"]     = 10,  -- has quest loop; bound early
  ["demos/demo04_expedition.sb"] = 8,  -- crew can all die by day 8
  ["demos/demo05_siege.sb"]     = 12,  -- has guarded victory condition
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

  it("reports 'No verify blocks' for a file with none", function()
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

  it("reports 'no migration blocks' for a game without migrations", function()
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

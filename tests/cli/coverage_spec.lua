-- tests/cli/coverage_spec.lua
-- Unit tests for cli/coverage_cmd.lua (storybase coverage subcommand).

local coverage_cmd = require("cli.coverage_cmd")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function capture_run(args)
  local out_path = os.tmpname()
  local err_path = os.tmpname()
  local saved_out, saved_err = io.stdout, io.stderr
  io.stdout = assert(io.open(out_path, "w"))
  io.stderr = assert(io.open(err_path, "w"))
  local ok, code = pcall(coverage_cmd.run, args)
  io.stdout:close(); io.stderr:close()
  io.stdout, io.stderr = saved_out, saved_err
  local of = io.open(out_path, "r"); local out = of:read("*a"); of:close()
  local ef = io.open(err_path, "r"); local err = ef:read("*a"); ef:close()
  os.remove(out_path); os.remove(err_path)
  if not ok then error(code) end
  return code, out, err
end

local function tmpfile(src)
  local p = os.tmpname() .. ".sb"
  local f = io.open(p, "w"); f:write(src); f:close()
  return p
end

-- ── Minimal reusable game ─────────────────────────────────────────────────────

local SIMPLE_GAME = [[
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 100

fn earn amount:
  inc! world/gold amount

fn spend amount:
  dec! world/gold amount

scene main:
  "You are in the village."
  * Earn 10 gold
    earn 10
    -> main
  * Spend 20 gold
    spend 20
    -> main
]]

-- ── Argument / error handling ─────────────────────────────────────────────────

describe("coverage_cmd — argument errors", function()

  it("exits 1 when no file is supplied", function()
    local code, _, err = capture_run({})
    assert.equals(1, code)
    assert.is_truthy(err:find("no input file"), "stderr should mention no input file")
  end)

  it("exits 1 when the file does not exist", function()
    local code, _, err = capture_run({ "/nonexistent/no_such_file_" .. os.time() .. ".sb" })
    assert.equals(1, code)
    assert.is_truthy(err:find("cannot open"), "stderr should say cannot open")
  end)

  it("exits 1 on a compile error", function()
    local path = tmpfile("this is not valid storybase syntax !!!!")
    local code, _, err = capture_run({ path })
    os.remove(path)
    assert.equals(1, code)
    assert.is_truthy(err:find("Compilation failed"), "stderr should mention compilation failure")
  end)

end)

-- ── Basic scene coverage ──────────────────────────────────────────────────────

describe("coverage_cmd — scene coverage", function()

  it("exits 0 on a valid game", function()
    local path = tmpfile(SIMPLE_GAME)
    local code = capture_run({ path })
    os.remove(path)
    assert.equals(0, code)
  end)

  it("reports 100% scene coverage when all scenes are reachable", function()
    local path = tmpfile(SIMPLE_GAME)
    local code, out = capture_run({ path })
    os.remove(path)
    assert.equals(0, code)
    -- main is the only scene and is the entry point → always reached
    assert.is_truthy(out:find("100%%"), "should show 100% coverage")
  end)

  it("marks the entry scene as reached", function()
    local path = tmpfile(SIMPLE_GAME)
    local code, out = capture_run({ path })
    os.remove(path)
    assert.equals(0, code)
    -- [x] prefix means reached
    assert.is_truthy(out:find("%[x%].*main") or out:find("main.*%[x%]"),
      "entry scene 'main' should appear as reached")
  end)

  it("flags an unreachable scene in the report", function()
    local path = tmpfile(SIMPLE_GAME .. [[

scene secret:
  "Nobody ever comes here."
  * Return -> main
]])
    local code, out = capture_run({ path })
    os.remove(path)
    assert.equals(0, code)
    -- 'secret' is declared but never navigated to
    assert.is_truthy(out:find("secret"), "unreachable scene 'secret' should appear")
    assert.is_truthy(out:find("Unreachable scenes") or out:find("%[ %].*secret"),
      "should flag 'secret' as unreachable")
  end)

  it("shows 50% scene coverage when one of two scenes is unreachable", function()
    local path = tmpfile(SIMPLE_GAME .. [[

scene dead_end:
  "A dead end."
  * Back -> main
]])
    local code, out = capture_run({ path })
    os.remove(path)
    assert.equals(0, code)
    -- 1 of 2 scenes reachable → 50%
    assert.is_truthy(out:find("50%%") or out:find("1 / 2"), "should show 50% or '1 / 2'")
  end)

end)

-- ── Function coverage ─────────────────────────────────────────────────────────

describe("coverage_cmd — function coverage", function()

  it("reports both earn and spend as reached when both choices exist", function()
    local path = tmpfile(SIMPLE_GAME)
    local code, out = capture_run({ path })
    os.remove(path)
    assert.equals(0, code)
    -- Both fns are called from choices at depth 1
    assert.is_truthy(out:find("earn"), "earn should appear in report")
    assert.is_truthy(out:find("spend"), "spend should appear in report")
  end)

  it("flags an unused function as uncovered", function()
    local path = tmpfile(SIMPLE_GAME .. [[

fn unused-helper:
  inc! world/gold 1
]])
    local code, out = capture_run({ path })
    os.remove(path)
    assert.equals(0, code)
    assert.is_truthy(out:find("unused%-helper"),
      "unused-helper should appear in report")
    assert.is_truthy(
      out:find("Uncovered functions") or out:find("%[ %].*unused%-helper"),
      "should flag unused-helper as uncovered")
  end)

  it("reports 100%% fn coverage when all fns are called", function()
    -- SIMPLE_GAME has two fns (earn, spend), both called from choices
    local path = tmpfile(SIMPLE_GAME)
    local code, out = capture_run({ path })
    os.remove(path)
    assert.equals(0, code)
    -- Fns section should show 100%
    assert.is_truthy(out:find("100%%"), "should report 100% coverage overall")
  end)

end)

-- ── JSON format ───────────────────────────────────────────────────────────────

describe("coverage_cmd — JSON format", function()

  it("emits valid JSON with --format json", function()
    local path = tmpfile(SIMPLE_GAME)
    local code, out = capture_run({ path, "--format", "json" })
    os.remove(path)
    assert.equals(0, code)
    -- JSON object starts with { and ends with }
    assert.is_truthy(out:match("^{"), "output should start with {")
    assert.is_truthy(out:match("}%s*\n?$"), "output should end with }")
  end)

  it("JSON output contains scenes and fns keys", function()
    local path = tmpfile(SIMPLE_GAME)
    local code, out = capture_run({ path, "--format", "json" })
    os.remove(path)
    assert.equals(0, code)
    assert.is_truthy(out:find('"scenes"'), "JSON should have scenes key")
    assert.is_truthy(out:find('"fns"'),    "JSON should have fns key")
  end)

  it("JSON scenes.total equals declared scene count", function()
    local path = tmpfile(SIMPLE_GAME)
    local code, out = capture_run({ path, "--format", "json" })
    os.remove(path)
    assert.equals(0, code)
    -- SIMPLE_GAME has 1 scene
    assert.is_truthy(out:find('"total":1') or out:find('"total": 1'),
      "scenes.total should be 1")
  end)

  it("JSON includes truncated flag", function()
    local path = tmpfile(SIMPLE_GAME)
    local code, out = capture_run({ path, "--format", "json", "--depth", "2" })
    os.remove(path)
    assert.equals(0, code)
    assert.is_truthy(out:find('"truncated"'), "JSON should have truncated field")
  end)

end)

-- ── CLI integration via main dispatcher ──────────────────────────────────────

describe("coverage_cmd — via main dispatcher", function()

  it("main dispatches 'coverage' to coverage_cmd", function()
    local main_mod = require("cli.main")
    local path = tmpfile(SIMPLE_GAME)

    -- Capture output
    local out_path = os.tmpname()
    local err_path = os.tmpname()
    local saved_out, saved_err = io.stdout, io.stderr
    io.stdout = assert(io.open(out_path, "w"))
    io.stderr = assert(io.open(err_path, "w"))
    local ok, code = pcall(main_mod.main, { "coverage", path })
    io.stdout:close(); io.stderr:close()
    io.stdout, io.stderr = saved_out, saved_err
    local of = io.open(out_path, "r"); local out = of:read("*a"); of:close()
    os.remove(out_path); os.remove(err_path); os.remove(path)

    assert.is_true(ok, "main should not throw")
    assert.equals(0, code)
    assert.is_truthy(out:find("Coverage"), "output should mention Coverage")
  end)

end)

-- ── --depth flag ─────────────────────────────────────────────────────────────

describe("coverage_cmd — depth flag", function()

  it("accepts --depth flag without error", function()
    local path = tmpfile(SIMPLE_GAME)
    local code = capture_run({ path, "--depth", "4" })
    os.remove(path)
    assert.equals(0, code)
  end)

end)

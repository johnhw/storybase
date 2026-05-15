-- tests/cli/fuzz_spec.lua
-- Unit tests for cli/fuzz_cmd.lua (storybase fuzz subcommand).

local fuzz_cmd = require("cli.fuzz_cmd")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function capture_run(args)
  local out_path = os.tmpname()
  local err_path = os.tmpname()
  local saved_out, saved_err = io.stdout, io.stderr
  io.stdout = assert(io.open(out_path, "w"))
  io.stderr = assert(io.open(err_path, "w"))
  local ok, code = pcall(fuzz_cmd.run, args)
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

local function tmpdir()
  local p = os.tmpname()
  os.remove(p)
  os.execute(string.format('mkdir -p "%s"', p))
  return p
end

local function rmdir(p)
  os.execute(string.format('rm -rf "%s"', p))
end

-- ── Test games ────────────────────────────────────────────────────────────────

-- Game with no verify blocks — fuzz should always pass
local NO_VERIFY_GAME = [[
engine-config:
  entry-scene: loop

state world:
  x: Int(0, 100) = 10

fn add:
  inc! world/x 5

fn sub:
  dec! world/x 5

scene loop:
  "Looping."
  * Add
    add
    -> loop
  * Sub
    sub
    -> loop
]]

-- Game with a passing verify-always invariant.
-- Uses inline Int(0, 10) so clamping is guaranteed at the type level.
local PASSING_VERIFY_GAME = [[
engine-config:
  entry-scene: safe

state world:
  count: Int(0, 10) = 5

fn plus-one:
  inc! world/count 1

fn minus-one:
  dec! world/count 1

scene safe:
  "Safe."
  * Plus
    plus-one
    -> safe
  * Minus
    minus-one
    -> safe

verify "count in bounds":
  verify-always world/count >= 0 and world/count <= 10
]]

-- Game with a verify-always that will quickly be violated
-- After 3 "tick" choices, count=3 which is not < 3.
local FAILING_VERIFY_GAME = [[
engine-config:
  entry-scene: counting

state world:
  count: Int(0, 1000) = 0

fn tick:
  inc! world/count 1

scene counting:
  "Counting."
  * Next
    tick
    -> counting

verify "count stays small":
  verify-always world/count < 3
]]

-- ── Argument / error handling ─────────────────────────────────────────────────

describe("fuzz_cmd — argument errors", function()

  it("exits 1 when no file is supplied", function()
    local code, _, err = capture_run({})
    assert.equals(1, code)
    assert.is_truthy(err:find("no input file"), "stderr should mention no input file")
  end)

  it("exits 1 when the file does not exist", function()
    local code, _, err = capture_run({ "/nonexistent/no_such_" .. os.time() .. ".sb" })
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

-- ── No verify blocks ──────────────────────────────────────────────────────────

describe("fuzz_cmd — no verify blocks", function()

  it("exits 0 when there are no verify-always blocks", function()
    local path = tmpfile(NO_VERIFY_GAME)
    local code = capture_run({ path, "--runs", "5", "--steps", "10" })
    os.remove(path)
    assert.equals(0, code)
  end)

  it("mentions crash-detection-only mode when no verify blocks exist", function()
    local path = tmpfile(NO_VERIFY_GAME)
    local _, out = capture_run({ path, "--runs", "3", "--steps", "5" })
    os.remove(path)
    assert.is_truthy(out:find("no verify%-always"), "should mention no verify-always blocks")
  end)

  it("shows 100% pass rate when no verify blocks", function()
    local path = tmpfile(NO_VERIFY_GAME)
    local _, out = capture_run({ path, "--runs", "5", "--steps", "5" })
    os.remove(path)
    assert.is_truthy(out:find("100%%"), "should show 100% pass rate")
  end)

end)

-- ── Passing invariants ────────────────────────────────────────────────────────

describe("fuzz_cmd — passing invariants", function()

  it("exits 0 when all verify-always invariants pass", function()
    local path = tmpfile(PASSING_VERIFY_GAME)
    local code = capture_run({ path, "--runs", "20", "--steps", "20" })
    os.remove(path)
    assert.equals(0, code)
  end)

  it("shows 100% pass rate when invariants hold", function()
    local path = tmpfile(PASSING_VERIFY_GAME)
    local _, out = capture_run({ path, "--runs", "10", "--steps", "10" })
    os.remove(path)
    assert.is_truthy(out:find("100%%"), "should show 100% pass rate")
  end)

  it("output mentions the filepath", function()
    local path = tmpfile(PASSING_VERIFY_GAME)
    local _, out = capture_run({ path, "--runs", "5", "--steps", "5" })
    os.remove(path)
    assert.is_truthy(out:find("Fuzz:"), "should mention Fuzz:")
  end)

end)

-- ── Failing invariants ────────────────────────────────────────────────────────

describe("fuzz_cmd — failing invariants", function()

  it("exits 1 when a verify-always invariant is violated", function()
    local path = tmpfile(FAILING_VERIFY_GAME)
    local d = tmpdir()
    local code = capture_run({ path, "--runs", "10", "--steps", "20",
                               "--failures-dir", d })
    os.remove(path); rmdir(d)
    assert.equals(1, code)
  end)

  it("prints FAIL lines when invariant is violated", function()
    local path = tmpfile(FAILING_VERIFY_GAME)
    local d = tmpdir()
    local _, out = capture_run({ path, "--runs", "10", "--steps", "20",
                                 "--failures-dir", d })
    os.remove(path); rmdir(d)
    assert.is_truthy(out:find("FAIL"), "should print FAIL line")
  end)

  it("mentions the violated verify label", function()
    local path = tmpfile(FAILING_VERIFY_GAME)
    local d = tmpdir()
    local _, out = capture_run({ path, "--runs", "10", "--steps", "20",
                                 "--failures-dir", d })
    os.remove(path); rmdir(d)
    assert.is_truthy(out:find("count stays small"), "should mention the verify label")
  end)

  it("saves a .sbd failure log to the failures dir", function()
    local path = tmpfile(FAILING_VERIFY_GAME)
    local d = tmpdir()
    capture_run({ path, "--runs", "10", "--steps", "20",
                  "--failures-dir", d })
    os.remove(path)
    -- At least one .sbd file should exist in d
    local found = false
    local ls = io.popen(string.format('ls "%s"/*.sbd 2>/dev/null', d))
    if ls then
      local result = ls:read("*a")
      ls:close()
      found = result ~= nil and result ~= ""
    end
    rmdir(d)
    assert.is_true(found, "a .sbd failure log should be saved")
  end)

  it("the saved .sbd log is a valid Lua file", function()
    local path = tmpfile(FAILING_VERIFY_GAME)
    local d = tmpdir()
    capture_run({ path, "--runs", "10", "--steps", "20",
                  "--failures-dir", d })
    os.remove(path)
    -- Find the first .sbd file and load it
    local ls = io.popen(string.format('ls "%s"/*.sbd 2>/dev/null', d))
    local sbd_path = nil
    if ls then
      local result = ls:read("*a")
      ls:close()
      sbd_path = result:match("([^\n]+%.sbd)")
    end
    local valid = false
    if sbd_path then
      local fn, err = loadfile(sbd_path)
      if fn then
        local ok, data = pcall(fn)
        valid = ok and type(data) == "table" and data.version == 1
      end
    end
    rmdir(d)
    assert.is_true(valid, "saved .sbd should be a valid save file with version=1")
  end)

  it("shows pass rate less than 100% when failures occur", function()
    local path = tmpfile(FAILING_VERIFY_GAME)
    local d = tmpdir()
    local _, out = capture_run({ path, "--runs", "10", "--steps", "20",
                                 "--failures-dir", d })
    os.remove(path); rmdir(d)
    -- Should NOT be 10/10 since failures will occur
    assert.is_falsy(out:find("^10 / 10.*100%%"),
      "pass rate should be less than 100% with failing invariant")
  end)

  it("mentions replay instructions when failures are found", function()
    local path = tmpfile(FAILING_VERIFY_GAME)
    local d = tmpdir()
    local _, out = capture_run({ path, "--runs", "10", "--steps", "20",
                                 "--failures-dir", d })
    os.remove(path); rmdir(d)
    assert.is_truthy(out:find("Replay"), "should show replay instructions")
  end)

end)

-- ── Flags ─────────────────────────────────────────────────────────────────────

describe("fuzz_cmd — flags", function()

  it("respects --runs N", function()
    local path = tmpfile(NO_VERIFY_GAME)
    local _, out = capture_run({ path, "--runs", "7", "--steps", "3" })
    os.remove(path)
    -- Summary should mention 7 runs
    assert.is_truthy(out:find("7 / 7") or out:find("7 runs"),
      "should run exactly 7 times")
  end)

  it("accepts --steps N without error", function()
    local path = tmpfile(NO_VERIFY_GAME)
    local code = capture_run({ path, "--runs", "3", "--steps", "5" })
    os.remove(path)
    assert.equals(0, code)
  end)

  it("accepts --seed N without error", function()
    local path = tmpfile(NO_VERIFY_GAME)
    local code = capture_run({ path, "--runs", "3", "--steps", "5", "--seed", "42" })
    os.remove(path)
    assert.equals(0, code)
  end)

  it("two runs with same --seed produce same pass/fail result", function()
    local path = tmpfile(FAILING_VERIFY_GAME)
    local d1 = tmpdir(); local d2 = tmpdir()
    local code1 = capture_run({ path, "--runs", "10", "--steps", "20",
                                 "--seed", "12345", "--failures-dir", d1 })
    local code2 = capture_run({ path, "--runs", "10", "--steps", "20",
                                 "--seed", "12345", "--failures-dir", d2 })
    os.remove(path); rmdir(d1); rmdir(d2)
    assert.equals(code1, code2, "same seed should produce same exit code")
  end)

end)

-- ── JSON format ───────────────────────────────────────────────────────────────

describe("fuzz_cmd — JSON format", function()

  it("emits valid JSON with --format json", function()
    local path = tmpfile(NO_VERIFY_GAME)
    local code, out = capture_run({ path, "--runs", "3", "--steps", "5",
                                    "--format", "json" })
    os.remove(path)
    assert.equals(0, code)
    assert.is_truthy(out:match("^{"), "output should start with {")
    assert.is_truthy(out:match("}%s*\n?$"), "output should end with }")
  end)

  it("JSON contains runs, failures, pass_rate keys", function()
    local path = tmpfile(NO_VERIFY_GAME)
    local _, out = capture_run({ path, "--runs", "3", "--steps", "5",
                                  "--format", "json" })
    os.remove(path)
    assert.is_truthy(out:find('"runs"'),      "JSON should have runs key")
    assert.is_truthy(out:find('"failures"'),  "JSON should have failures key")
    assert.is_truthy(out:find('"pass_rate"'), "JSON should have pass_rate key")
  end)

  it("JSON runs equals the requested --runs count", function()
    local path = tmpfile(NO_VERIFY_GAME)
    local _, out = capture_run({ path, "--runs", "5", "--steps", "3",
                                  "--format", "json" })
    os.remove(path)
    assert.is_truthy(out:find('"runs":5') or out:find('"runs": 5'),
      "JSON runs should equal 5")
  end)

  it("JSON failure_list is an array", function()
    local path = tmpfile(NO_VERIFY_GAME)
    local _, out = capture_run({ path, "--runs", "3", "--steps", "5",
                                  "--format", "json" })
    os.remove(path)
    assert.is_truthy(out:find('"failure_list"'), "JSON should have failure_list key")
  end)

  it("JSON failure_list contains entries on violation", function()
    local path = tmpfile(FAILING_VERIFY_GAME)
    local d = tmpdir()
    local _, out = capture_run({ path, "--runs", "10", "--steps", "20",
                                  "--format", "json", "--failures-dir", d })
    os.remove(path); rmdir(d)
    assert.is_truthy(out:find('"run"'), "failure entries should have run field")
  end)

end)

-- ── Main dispatcher integration ──────────────────────────────────────────────

describe("fuzz_cmd — via main dispatcher", function()

  it("main dispatches 'fuzz' to fuzz_cmd", function()
    local main_mod = require("cli.main")
    local path = tmpfile(NO_VERIFY_GAME)

    local out_path = os.tmpname()
    local err_path = os.tmpname()
    local saved_out, saved_err = io.stdout, io.stderr
    io.stdout = assert(io.open(out_path, "w"))
    io.stderr = assert(io.open(err_path, "w"))
    local ok, code = pcall(main_mod.main, { "fuzz", path, "--runs", "3", "--steps", "5" })
    io.stdout:close(); io.stderr:close()
    io.stdout, io.stderr = saved_out, saved_err
    local of = io.open(out_path, "r"); local out = of:read("*a"); of:close()
    os.remove(out_path); os.remove(err_path); os.remove(path)

    assert.is_true(ok, "main should not throw")
    assert.equals(0, code)
    assert.is_truthy(out:find("Fuzz:") or out:find("runs"), "output should mention fuzz")
  end)

end)

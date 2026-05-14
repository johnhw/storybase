-- tests/cli/verify_cmd_spec.lua
-- Unit tests for cli/verify_cmd.lua.
--
-- Drives verify_cmd.M.run directly. Captures stdout/stderr.

local verify_cmd = require("cli.verify_cmd")

local function capture_run(args)
  local out_path = os.tmpname()
  local err_path = os.tmpname()
  local saved_out, saved_err = io.stdout, io.stderr
  io.stdout = assert(io.open(out_path, "w"))
  io.stderr = assert(io.open(err_path, "w"))
  local ok, code = pcall(verify_cmd.run, args)
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

-- ── tests ──────────────────────────────────────────────────────

describe("verify_cmd — usage errors", function()
  it("exits 1 when no file is supplied", function()
    local code, _, err = capture_run({})
    assert.equals(1, code)
    assert.is_truthy(err:find("no input file"))
  end)

  it("exits 1 when the file does not exist", function()
    local code, _, err = capture_run({"/tmp/no-such-" .. os.time() .. ".sb"})
    assert.equals(1, code)
    assert.is_truthy(err:find("cannot open"))
  end)
end)

describe("verify_cmd — compilation failure", function()
  it("exits 1 and prints a diagnostic on a malformed source", function()
    local path = tmpfile([[
this is not valid storybase
]])
    local code, _, err = capture_run({path})
    os.remove(path)
    assert.equals(1, code)
    assert.is_truthy(err:find("Compilation failed"))
  end)
end)

describe("verify_cmd — no verify blocks", function()
  it("exits 0 with 'No verify blocks found' if none declared", function()
    local path = tmpfile([[
engine-config:
  entry-scene: main

state world/x: Int(0,9) = 0

scene main:
  * Go -> main
]])
    local code, out, _ = capture_run({path})
    os.remove(path)
    assert.equals(0, code)
    assert.is_truthy(out:find("No verify blocks"))
  end)
end)

describe("verify_cmd — passing verify", function()
  it("exits 0 and prints PASS for a trivially-true predicate", function()
    local path = tmpfile([[
engine-config:
  entry-scene: main

state world:
  x: Int(0,9) = 0

verify "x always non-negative":
  verify-always world/x >= 0

scene main:
  * Go -> main
]])
    local code, out, _ = capture_run({path})
    os.remove(path)
    assert.equals(0, code)
    assert.is_truthy(out:find("PASS"))
    assert.is_truthy(out:find("1 passed"))
    assert.is_truthy(out:find("0 failed"))
  end)
end)

describe("verify_cmd — failing verify", function()
  it("exits 1 and prints FAIL with the verify label", function()
    -- world/x starts at 5 → "world/x = 0" is false at the initial state
    local path = tmpfile([[
engine-config:
  entry-scene: main

state world:
  x: Int(0,9) = 5

verify "x must always be zero":
  verify-always world/x = 0

scene main:
  * Go -> main
]])
    local code, out, _ = capture_run({path})
    os.remove(path)
    assert.equals(1, code)
    assert.is_truthy(out:find("FAIL"))
    assert.is_truthy(out:find("x must always be zero"))
    assert.is_truthy(out:find("1 failed"))
  end)
end)

describe("verify_cmd — summary line", function()
  it("reports counts of passed/failed/skipped in the summary", function()
    local path = tmpfile([[
engine-config:
  entry-scene: main

state world:
  x: Int(0,9) = 1

verify "trivially true":
  verify-always world/x >= 0

verify "trivially false":
  verify-always world/x = 99

scene main:
  * Go -> main
]])
    local code, out, _ = capture_run({path})
    os.remove(path)
    assert.equals(1, code)
    assert.is_truthy(out:find("1 passed"))
    assert.is_truthy(out:find("1 failed"))
  end)
end)

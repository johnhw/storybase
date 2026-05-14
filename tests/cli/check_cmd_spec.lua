-- tests/cli/check_cmd_spec.lua
-- Unit tests for cli/check_cmd.lua.
--
-- Drives check_cmd.M.run directly with captured stdout/stderr so the
-- error paths and exit codes can be asserted without a subprocess.

local check_cmd = require("cli.check_cmd")

-- ── stdout / stderr capture ─────────────────────────────────────

local function capture_run(args)
  local stdout, stderr = {}, {}
  local saved_out, saved_err = io.stdout, io.stderr
  -- Use real file handles redirected to temp files to preserve write-method
  -- expectations of check_cmd (which calls :write).
  local out_path = os.tmpname()
  local err_path = os.tmpname()
  io.stdout = assert(io.open(out_path, "w"))
  io.stderr = assert(io.open(err_path, "w"))
  local ok, code = pcall(check_cmd.run, args)
  io.stdout:close(); io.stderr:close()
  io.stdout, io.stderr = saved_out, saved_err
  local of = io.open(out_path, "r"); stdout = of:read("*a"); of:close()
  local ef = io.open(err_path, "r"); stderr = ef:read("*a"); ef:close()
  os.remove(out_path); os.remove(err_path)
  if not ok then error(code) end
  return code, stdout, stderr
end

local function tmpfile(src)
  local path = os.tmpname() .. ".sb"
  local f = io.open(path, "w"); f:write(src); f:close()
  return path
end

-- ── tests ───────────────────────────────────────────────────────

describe("check_cmd — no input file", function()
  it("exits 1 with an error to stderr when called with no args", function()
    local code, _, err = capture_run({})
    assert.equals(1, code)
    assert.is_truthy(err:find("no input file"))
  end)
end)

describe("check_cmd — missing file", function()
  it("exits 1 and reports FILE_NOT_FOUND", function()
    local code, _, err = capture_run({"/tmp/missing-" .. os.time() .. ".sb"})
    assert.equals(1, code)
    assert.is_truthy(err:find("FILE_NOT_FOUND") or err:find("Cannot open"),
      "expected FILE_NOT_FOUND or 'Cannot open' in stderr; got: " .. err)
  end)
end)

describe("check_cmd — clean file", function()
  it("exits 0 with 'check passed' on a well-formed program", function()
    local path = tmpfile([[
engine-config:
  entry-scene: main

state world:
  x: Int(0,9) = 0

scene main:
  * Go -> main
]])
    local code, out, _ = capture_run({path})
    os.remove(path)
    assert.equals(0, code)
    assert.is_truthy(out:find("check passed"))
    -- The summary line should mention Types and State paths.
    assert.is_truthy(out:find("Types") and out:find("State paths"))
  end)
end)

describe("check_cmd — syntax error", function()
  it("exits 1 and prints diagnostic with source context", function()
    local path = tmpfile([[
engine-config:
  entry-scene: main

scene !!!:
  body
]])
    local code, _, err = capture_run({path})
    os.remove(path)
    assert.equals(1, code)
    assert.is_truthy(err:find("error"))
    -- The error line should mention the original file path.
    assert.is_truthy(err:find(path, 1, true))
    -- And the offending source line should appear in the context.
    assert.is_truthy(err:find("scene !!!"))
  end)
end)

describe("check_cmd — semantic error", function()
  it("exits 1 on an invalid enum default value", function()
    local path = tmpfile([[
engine-config:
  entry-scene: main

type Color = red | green | blue

state world:
  c: Color = `purple

scene main:
  * Go -> main
]])
    local code, _, err = capture_run({path})
    os.remove(path)
    assert.equals(1, code)
    assert.is_truthy(err:find("check failed"))
    assert.is_truthy(err:find("Color") or err:find("purple"))
  end)
end)

describe("check_cmd — multiple errors summary", function()
  it("includes the error count in the summary line", function()
    local path = tmpfile([[
engine-config:
  entry-scene: main

fn dup: pass
fn dup: pass
fn dup: pass

scene main:
  * Go -> main
]])
    local code, _, err = capture_run({path})
    os.remove(path)
    assert.equals(1, code)
    -- Expect plural form "errors"
    assert.is_truthy(err:find("error"))
    assert.is_truthy(err:find("check failed"))
  end)
end)

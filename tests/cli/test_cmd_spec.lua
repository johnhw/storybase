-- tests/cli/test_cmd_spec.lua
-- Unit tests for cli/test_cmd.lua (storybase test subcommand).

local test_cmd = require("cli.test_cmd")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local TMP_DIR = os.tmpname():match("^(.*)[/\\]") or "/tmp"

local function write_tmp(name, content)
  local path = TMP_DIR .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

local function capture_output(fn)
  local saved_stdout = io.output()
  local saved_stderr = io.stderr
  local out_parts = {}
  local err_parts = {}

  -- We can't easily redirect io.stdout in pure Lua, so use a subprocess approach
  -- for integration tests. Here we just call run() directly and check exit codes.
  return fn()
end

-- ── Usage / error tests ───────────────────────────────────────────────────────

describe("test cmd — argument handling", function()

  it("returns 1 when no file given", function()
    local code = test_cmd.run({})
    assert.equal(1, code)
  end)

  it("returns 1 when file does not exist", function()
    local code = test_cmd.run({ "/nonexistent/file.sb" })
    assert.equal(1, code)
  end)

end)

-- ── Integration tests ─────────────────────────────────────────────────────────

describe("test cmd — integration", function()

  local GAME = [[
module tmod
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0,9999) = 100
  flag: Bool = false

fn spend amount:
  dec! world/gold amount

scene main:
  * Done
    -> main

]]

  it("returns 0 when all tests pass", function()
    local path = write_tmp("tc_pass.sb", GAME .. [[
test "defaults hold":
  expect:
    world/gold = 100
    world/flag = false
]])
    local code = test_cmd.run({ path })
    assert.equal(0, code)
    os.remove(path)
  end)

  it("returns 1 when a test fails", function()
    local path = write_tmp("tc_fail.sb", GAME .. [[
test "wrong assertion":
  expect:
    world/gold = 0
]])
    local code = test_cmd.run({ path })
    assert.equal(1, code)
    os.remove(path)
  end)

  it("returns 0 when no test blocks found", function()
    local path = write_tmp("tc_none.sb", GAME)
    local code = test_cmd.run({ path })
    assert.equal(0, code)
    os.remove(path)
  end)

  it("returns 1 on compile error", function()
    local path = write_tmp("tc_err.sb", "this is not valid sb syntax !!!!")
    local code = test_cmd.run({ path })
    assert.equal(1, code)
    os.remove(path)
  end)

  it("runs setup and run sections correctly", function()
    local path = write_tmp("tc_setup_run.sb", GAME .. [[
test "spend 30":
  setup:
    set! world/gold 100
  run:
    spend 30
  expect:
    world/gold = 70
]])
    local code = test_cmd.run({ path })
    assert.equal(0, code)
    os.remove(path)
  end)

end)

-- tests/cli/bundle_spec.lua
-- Tests for `storybase bundle`: produces a self-contained Lua file that
-- runs with a stock lua5.4 binary.

-- ── Helpers ───────────────────────────────────────────────────────────────

local function run(cmd)
  local handle = io.popen(cmd .. " 2>&1", "r")
  local out = handle:read("*a")
  handle:close()
  return out
end

-- Run a command and return (stdout_combined, exit_code).
-- Uses a temp file to capture the exit code.
local function run_ex(cmd)
  local stamp = tostring(math.random(1, 999999))
  local flag  = os.tmpname() .. stamp
  local out   = run(cmd .. "; echo $? > " .. flag)
  local f     = io.open(flag, "r")
  local code  = f and tonumber(f:read("*l")) or -1
  if f then f:close() end
  os.remove(flag)
  return out, code
end

local LUA   = "lua5.4"
local MAIN  = LUA .. " cli/main.lua"
local BUNDLE = MAIN .. " bundle"

-- Minimal .sb source for tests that don't need a real game file.
local MINIMAL_SB = [[
module bundle-test
  version: 1.0
engine-config:
  entry-scene: start

state counter: Int(0,99) = 0

scene start:
  Counter is {counter} .
  * Increment
    inc! counter 1
    -> start
  * Reset
    set! counter 0
    -> start
]]

local function write_tmp_sb(src)
  local path = os.tmpname() .. ".sb"
  local f = io.open(path, "w"); f:write(src); f:close()
  return path
end

-- ── Basic bundle creation ─────────────────────────────────────────────────

describe("storybase bundle: basic", function()
  it("creates output file and reports success", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    local result, code = run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)

    assert.equal(0, code, "bundle should exit 0:\n" .. result)
    assert.is_true(result:find("Bundle written") ~= nil,
      "expected 'Bundle written' in output:\n" .. result)
    assert.is_true(result:find(out, 1, true) ~= nil,
      "output path should appear in result:\n" .. result)

    local f = io.open(out, "r")
    assert.is_not_nil(f, "output file should exist")
    if f then f:close() end
    os.remove(out)
  end)

  it("default output path strips .sb and adds .lua", function()
    local sb = write_tmp_sb(MINIMAL_SB)
    -- The default output will be same path with .lua extension
    local expected_out = sb:gsub("%.sb$", "") .. ".lua"
    local result, code = run_ex(BUNDLE .. " " .. sb)
    os.remove(sb)

    assert.equal(0, code, "bundle should exit 0:\n" .. result)
    local f = io.open(expected_out, "r")
    assert.is_not_nil(f, "default output file should exist at " .. expected_out)
    if f then f:close() end
    os.remove(expected_out)
  end)

  it("output file is valid Lua (loads without error)", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)

    -- Load the bundle without executing the runner
    local fn, err = loadfile(out)
    os.remove(out)
    -- loadfile parses the file as Lua; a syntax error would return nil
    -- Note: the bundle's runner calls engine.run which is interactive,
    -- so we only check parse-validity here (loadfile, not pcall(fn))
    assert.is_not_nil(fn, "bundle output should be valid Lua: " .. tostring(err))
  end)

  it("output contains package.preload entries for runtime modules", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)

    local f = io.open(out, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(out)

    assert.is_true(content:find('package.preload%["runtime.engine"%]') ~= nil,
      "bundle should preload runtime.engine")
    assert.is_true(content:find('package.preload%["runtime.eval"%]') ~= nil,
      "bundle should preload runtime.eval")
    assert.is_true(content:find('package.preload%["compiler.ast"%]') ~= nil,
      "bundle should preload compiler.ast (needed by migrate)")
  end)

  it("output contains BUNDLED_ASSETS table for future asset support", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)

    local f = io.open(out, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(out)

    assert.is_true(content:find("BUNDLED_ASSETS") ~= nil,
      "bundle should contain BUNDLED_ASSETS table")
    assert.is_true(content:find("asset_load") ~= nil,
      "bundle should contain asset_load() helper")
  end)

  it("output contains GAME_TABLE definition", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)

    local f = io.open(out, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(out)

    assert.is_true(content:find("local GAME_TABLE") ~= nil,
      "bundle should define GAME_TABLE")
  end)
end)

-- ── Bundle runs correctly ─────────────────────────────────────────────────

describe("storybase bundle: execution", function()
  it("bundled game runs in auto mode", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)

    local result, code = run_ex(LUA .. " " .. out .. " --auto --steps 2")
    os.remove(out)

    assert.equal(0, code, "bundled game should exit 0:\n" .. result)
    assert.is_true(result:find("Counter") ~= nil,
      "bundled game should produce output:\n" .. result)
  end)

  it("bundled game supports --seed flag for reproducible runs", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)

    -- Run twice with same seed; output should be identical
    local r1, c1 = run_ex(LUA .. " " .. out .. " --seed 42 --auto --steps 3")
    local r2, c2 = run_ex(LUA .. " " .. out .. " --seed 42 --auto --steps 3")
    os.remove(out)

    assert.equal(0, c1); assert.equal(0, c2)
    assert.equal(r1, r2, "runs with the same seed should produce identical output")
  end)

  it("bundled game supports --save and --load", function()
    local sb      = write_tmp_sb(MINIMAL_SB)
    local out     = os.tmpname() .. ".lua"
    local savelog = os.tmpname() .. ".log"
    run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)

    -- Save
    local _, sc = run_ex(LUA .. " " .. out .. " --auto --steps 2 --save " .. savelog)
    assert.equal(0, sc, "save run should exit 0")

    local f = io.open(savelog, "r")
    assert.is_not_nil(f, "save file should be created")
    if f then f:close() end

    -- Load
    local rload, lc = run_ex(LUA .. " " .. out .. " --load " .. savelog
                              .. " --auto --steps 1")
    assert.equal(0, lc, "load run should exit 0:\n" .. rload)
    assert.is_true(rload:find("Loaded") ~= nil or rload:find("Counter") ~= nil,
      "loaded game should produce output")

    os.remove(out); os.remove(savelog)
  end)

  it("bundled game of demo01 runs correctly", function()
    local result, code = run_ex(BUNDLE
      .. " demos/demo01_wanderer.sb --output /tmp/_demo01_bundle.lua")
    assert.equal(0, code, "bundle of demo01 should succeed:\n" .. result)

    local rrun, rcode = run_ex(LUA .. " /tmp/_demo01_bundle.lua --auto --steps 3")
    os.remove("/tmp/_demo01_bundle.lua")
    assert.equal(0, rcode, "bundled demo01 should run:\n" .. rrun)
    assert.is_true(rrun:find("village") ~= nil or rrun:find("forest") ~= nil,
      "demo01 output expected:\n" .. rrun)
  end)

  it("bundled game of demo06 (complex features) runs correctly", function()
    local result, code = run_ex(BUNDLE
      .. " demos/demo06_buried_keep.sb --output /tmp/_demo06_bundle.lua")
    assert.equal(0, code, "bundle of demo06 should succeed:\n" .. result)

    local rrun, rcode = run_ex(LUA .. " /tmp/_demo06_bundle.lua --auto --steps 3")
    os.remove("/tmp/_demo06_bundle.lua")
    assert.equal(0, rcode, "bundled demo06 should run:\n" .. rrun)
  end)
end)

-- ── Production mode ───────────────────────────────────────────────────────

describe("storybase bundle: --production", function()
  it("production bundle exits 0 and runs", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    local _, bc = run_ex(BUNDLE .. " --production " .. sb .. " --output " .. out)
    os.remove(sb)
    assert.equal(0, bc, "production bundle should succeed")

    local result, rc = run_ex(LUA .. " " .. out .. " --auto --steps 2")
    os.remove(out)
    assert.equal(0, rc, "production bundled game should run:\n" .. result)
  end)

  it("production bundle marks game table with production flag", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    run_ex(BUNDLE .. " --production " .. sb .. " --output " .. out)
    os.remove(sb)

    local f = io.open(out, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(out)

    -- Production mode is noted in header comment
    assert.is_true(content:find("production") ~= nil,
      "production bundle should note mode in header")
  end)
end)

-- ── Error cases ───────────────────────────────────────────────────────────

describe("storybase bundle: errors", function()
  it("missing input file exits non-zero", function()
    local _, code = run_ex(BUNDLE)
    assert.is_true(code ~= 0, "bundle with no args should fail")
  end)

  it("compile error exits non-zero", function()
    local sb = write_tmp_sb("module broken\n  version: 1.0\nBAD SYNTAX !!!")
    local out = os.tmpname() .. ".lua"
    local result, code = run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)
    os.remove(out)
    assert.is_true(code ~= 0, "bundle of broken source should fail:\n" .. result)
  end)

  it("non-existent input file exits non-zero", function()
    local _, code = run_ex(BUNDLE .. " nonexistent_9999.sb")
    assert.is_true(code ~= 0, "bundle of missing file should fail")
  end)
end)

-- ── Serialiser edge cases ─────────────────────────────────────────────────

describe("storybase bundle: game table serialiser", function()
  local bundle_cmd

  setup(function()
    bundle_cmd = require("cli.bundle_cmd")
  end)

  -- Access the serialize function indirectly by bundling games with specific
  -- value types and verifying the bundle round-trips correctly.

  it("bundled game with nested record state runs correctly", function()
    local src = [[
module ser-test
  version: 1.0
engine-config:
  entry-scene: s
state player:
  name: String = "Hero"
  level: Int(1,99) = 1
scene s:
  Hello {player/name} level {player/level} .
  * Level up
    inc! player/level 1
    -> s
]]
    local sb  = write_tmp_sb(src)
    local out = os.tmpname() .. ".lua"
    local _, bc = run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)
    assert.equal(0, bc, "bundle should succeed")

    local result, rc = run_ex(LUA .. " " .. out .. " --auto --steps 2")
    os.remove(out)
    assert.equal(0, rc)
    assert.is_true(result:find("Hero") ~= nil, "player name should appear:\n" .. result)
  end)

  it("bundled game with boolean state runs correctly", function()
    local src = [[
module bool-test
  version: 1.0
engine-config:
  entry-scene: s
state flags:
  active: Bool = false
scene s:
  Active is {flags/active} .
  * Toggle
    set! flags/active true
    -> s
]]
    local sb  = write_tmp_sb(src)
    local out = os.tmpname() .. ".lua"
    local _, bc = run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)
    assert.equal(0, bc)

    local result, rc = run_ex(LUA .. " " .. out .. " --auto --steps 2")
    os.remove(out)
    assert.equal(0, rc)
    assert.is_true(result:find("Active") ~= nil)
  end)

  it("bundled game with symbol/enum state runs correctly", function()
    local src = [[
module enum-test
  version: 1.0
engine-config:
  entry-scene: s
type Color = red | green | blue
state world:
  color: Color = 'red
scene s:
  Color is {world/color} .
  * Make green
    set! world/color 'green
    -> s
]]
    local sb  = write_tmp_sb(src)
    local out = os.tmpname() .. ".lua"
    local _, bc = run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)
    assert.equal(0, bc)

    local result, rc = run_ex(LUA .. " " .. out .. " --auto --steps 2")
    os.remove(out)
    assert.equal(0, rc)
    assert.is_true(result:find("Color") ~= nil)
  end)
end)

-- ── help ──────────────────────────────────────────────────────────────────

describe("storybase bundle: help", function()
  it("storybase help bundle shows usage", function()
    local result, code = run_ex(MAIN .. " help bundle")
    assert.equal(0, code)
    assert.is_true(result:find("bundle") ~= nil)
    assert.is_true(result:find("output") ~= nil)
  end)
end)

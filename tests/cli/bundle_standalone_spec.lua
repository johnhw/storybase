-- tests/cli/bundle_standalone_spec.lua
-- Regression gate for the "no external C dependencies" property of
-- `storybase bundle`. The bundler embeds runtime modules into
-- package.preload and the resulting file is documented to run on a
-- stock lua5.4 — without lcurses, without luasocket, without anything
-- else from luarocks. These tests run a generated bundle with
-- LUA_CPATH pointed at a non-existent path so that every
-- `require()` of a C extension fails. If the bundle still runs to
-- completion, no runtime code path is unconditionally pulling in a
-- C library.

local function run_ex(cmd)
  local stamp = tostring(math.random(1, 999999))
  local flag  = os.tmpname() .. stamp
  local h = io.popen(cmd .. " 2>&1; echo $? > " .. flag, "r")
  local out = h:read("*a"); h:close()
  local f = io.open(flag, "r")
  local code = f and tonumber(f:read("*l")) or -1
  if f then f:close() end
  os.remove(flag)
  return out, code
end

local LUA    = "lua5.4"
local BUNDLE = LUA .. " cli/main.lua bundle"

-- Run a bundle with the C-extension search path disabled. Built-in
-- libraries (os, string, io, …) are linked into the lua binary and
-- are unaffected; only `require()` of a C module like lcurses or
-- luasocket fails.
local NO_CPATH = 'LUA_CPATH="/nonexistent/?.so"'

local MINIMAL_SB = [[
module standalone-test
  version: 1.0
engine-config:
  entry-scene: start

state counter: Int(0,99) = 0

scene start:
  Counter is {counter} .
  * Increment
    inc! counter 1
    -> start
]]

local function write_tmp_sb(src)
  local path = os.tmpname() .. ".sb"
  local f = io.open(path, "w"); f:write(src); f:close()
  return path
end

describe("storybase bundle: standalone (no C extensions)", function()

  it("minimal bundle runs with LUA_CPATH disabled", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    local _, bc = run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)
    assert.equal(0, bc, "bundle build should succeed")

    local result, rc = run_ex(NO_CPATH .. " " .. LUA .. " " .. out
                              .. " --auto --steps 2")
    os.remove(out)
    assert.equal(0, rc,
      "bundle should run without any C extension on LUA_CPATH:\n" .. result)
    assert.is_true(result:find("Counter") ~= nil,
      "bundled game should produce output:\n" .. result)
  end)

  it("demo01 bundle runs with LUA_CPATH disabled", function()
    local out = os.tmpname() .. ".lua"
    local _, bc = run_ex(BUNDLE
      .. " demos/demo01_wanderer.sb --output " .. out)
    assert.equal(0, bc, "bundle build should succeed")

    local result, rc = run_ex(NO_CPATH .. " " .. LUA .. " " .. out
                              .. " --auto --steps 3")
    os.remove(out)
    assert.equal(0, rc,
      "demo01 bundle should run without any C extension on LUA_CPATH:\n"
      .. result)
    assert.is_true(result:find("village") ~= nil or result:find("forest") ~= nil,
      "demo01 output expected:\n" .. result)
  end)

  -- Belt-and-braces: the bundle should never `require("curses")` or
  -- `require("socket")` outside of a pcall. The lazy-load convention
  -- across the runtime is to wrap every external module load in
  -- `pcall(require, ...)`; a regression that drops the pcall would
  -- break standalone bundles on machines without the rocks installed.
  it("bundle source has no unguarded require of curses or socket", function()
    local sb  = write_tmp_sb(MINIMAL_SB)
    local out = os.tmpname() .. ".lua"
    local _, bc = run_ex(BUNDLE .. " " .. sb .. " --output " .. out)
    os.remove(sb)
    assert.equal(0, bc)

    local f = io.open(out, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(out)

    for _, mod in ipairs({ "curses", "socket" }) do
      -- Find every `require("<mod>")` (or with single quotes) and
      -- confirm the preceding ~30 chars on the same line contain
      -- "pcall". This catches the common "swap pcall(require,…) for
      -- a plain require" mistake without false-positives on the
      -- string "require" appearing in comments or error messages.
      for line in content:gmatch("[^\n]+") do
        local s = line:find('require%s*%(?%s*["\']' .. mod .. '["\']')
        if s then
          local prefix = line:sub(math.max(1, s - 40), s - 1)
          assert.is_true(prefix:find("pcall") ~= nil,
            "unguarded require of '" .. mod .. "' in bundle: " .. line)
        end
      end
    end
  end)

end)

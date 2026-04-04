-- tests/cli/compact_spec.lua
-- Tests for cli/compact_cmd.lua

local sb         = require("lib.storybase")
local compact_cmd = require("cli.compact_cmd")

local SRC = [[
module compact-game
  version: 1.0
engine-config:
  entry-scene: main

state world:
  score: Int(0, 9999) = 0
  round: Int(0, 999)  = 1

scene main:
  * Score
    inc! world/score 10
    inc! world/round  1
    -> main
  * Quit
    -> done

scene done:
  Game over.
]]

-- Helper: silence stderr during tests
local function silence_stderr(fn)
  local old = io.stderr
  io.stderr = io.open("/dev/null", "w")
  local ok, err = pcall(fn)
  io.stderr:close(); io.stderr = old
  if not ok then error(err, 2) end
end

local function make_save(choices)
  local g = sb.from_source(SRC, "compact-game"); g:init()
  for _, c in ipairs(choices) do g:choose(c) end
  local path = os.tmpname() .. ".log"
  g:save(path)
  return path, g
end

-- ── Error cases ───────────────────────────────────────────────────────────────

describe("compact_cmd.run error cases", function()
  it("returns 1 with missing args", function()
    silence_stderr(function()
      assert.equal(1, compact_cmd.run({}))
    end)
  end)

  it("returns 1 with only one arg", function()
    silence_stderr(function()
      assert.equal(1, compact_cmd.run({"/tmp/game.sb"}))
    end)
  end)

  it("returns 1 for nonexistent save log", function()
    silence_stderr(function()
      assert.equal(1, compact_cmd.run({"tests/test01_minimal.sb", "/nonexistent.log",
                                       "--out", "/tmp/should-not-exist.log"}))
    end)
  end)
end)

-- ── Core functionality ────────────────────────────────────────────────────────

describe("compact_cmd.run core", function()
  it("compacts a valid save log successfully", function()
    local save_path = make_save({1, 1, 1})  -- 3 choices
    local out_path  = os.tmpname() .. ".compact.log"

    local captured = {}
    local old_write = io.write
    io.write = function(s) captured[#captured+1] = s end

    local rc = compact_cmd.run({"tests/test01_minimal.sb",
                                 save_path, "--out", out_path})
    io.write = old_write
    os.remove(save_path)

    -- compact_cmd uses a game file that matches the save's schema
    -- test01_minimal.sb has no state paths, so this will create a 0-entry compact
    -- Let's check the rc
    assert.equal(0, rc)
    os.remove(out_path)
  end)

  it("compact log loads and produces same state as original save", function()
    local save_path = make_save({1, 1, 1})  -- 3 points: score=30, round=4
    local out_path  = os.tmpname() .. ".compact.log"

    -- Write source to tmpfile for compact_cmd
    local sb_path = os.tmpname() .. ".sb"
    local f = io.open(sb_path, "w"); f:write(SRC); f:close()

    local captured = {}
    local old_write = io.write
    io.write = function(s) captured[#captured+1] = s end
    local rc = compact_cmd.run({sb_path, save_path, "--out", out_path})
    io.write = old_write

    os.remove(save_path)
    os.remove(sb_path)

    assert.equal(0, rc)

    -- Load compacted save and verify state
    local g2 = sb.from_source(SRC, "compact-game"); g2:init()
    local ok, err = g2:load(out_path)
    os.remove(out_path)

    assert.is_true(ok, tostring(err))
    assert.equal(30, g2:get("world/score"))
    assert.equal(4,  g2:get("world/round"))
    assert.equal("main", g2:current_scene())
  end)

  it("compacted log is smaller than original (fewer entries)", function()
    -- Build a longer log (many score increments)
    local g = sb.from_source(SRC, "compact-game"); g:init()
    for _ = 1, 10 do g:choose(1) end  -- 10 choices = ~20 log entries
    local save_path = os.tmpname() .. ".log"
    g:save(save_path)

    local sb_path = os.tmpname() .. ".sb"
    local f = io.open(sb_path, "w"); f:write(SRC); f:close()

    local out_path = os.tmpname() .. ".compact.log"
    local msg_parts = {}
    local old_write = io.write
    io.write = function(s) msg_parts[#msg_parts+1] = s end
    compact_cmd.run({sb_path, save_path, "--out", out_path})
    io.write = old_write

    os.remove(save_path)
    os.remove(sb_path)

    local msg = table.concat(msg_parts)
    -- Should say "2 snapshot entries" (world/score, world/round)
    assert.is_truthy(msg:find("2 snapshot entries"), msg)

    -- Compacted file loads correctly
    local g2 = sb.from_source(SRC, "compact-game"); g2:init()
    local ok = g2:load(out_path)
    os.remove(out_path)
    assert.is_true(ok)
    assert.equal(100, g2:get("world/score"))  -- 10 * 10
    assert.equal(11,  g2:get("world/round"))  -- 1 + 10
  end)

  it("can continue playing after loading compact save", function()
    local save_path = make_save({1, 1})  -- score=20, round=3
    local sb_path   = os.tmpname() .. ".sb"
    local f = io.open(sb_path, "w"); f:write(SRC); f:close()
    local out_path = os.tmpname() .. ".compact.log"

    local old_write = io.write; io.write = function() end
    compact_cmd.run({sb_path, save_path, "--out", out_path})
    io.write = old_write

    os.remove(save_path); os.remove(sb_path)

    local g2 = sb.from_source(SRC, "compact-game"); g2:init()
    g2:load(out_path)
    os.remove(out_path)

    -- Continue: one more score
    g2:choose(1)
    assert.equal(30, g2:get("world/score"))
  end)
end)

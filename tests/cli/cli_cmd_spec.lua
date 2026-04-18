-- tests/cli/cli_cmd_spec.lua
-- Tests for storybase run --cli single-step mode
--
-- Tests cli/cli_cmd.lua via the lib.storybase-like direct API, not via subprocess,
-- for speed.  The subprocess integration tests at the bottom verify the full pipe.

local cli_cmd  = require("cli.cli_cmd")
local compiler = require("compiler.compiler")

-- Compile a .sb file to a raw game_table
local function load_game(path)
  local gt, diags = compiler.compile_file(path)
  assert(not diags:has_errors(), "compile failed for " .. path)
  return gt
end

-- ── helpers ──────────────────────────────────────────────────────

local function tmp_save()
  return os.tmpname() .. ".sbd"
end

local function cleanup(path)
  os.remove(path)
  os.remove(path .. ".snap")
end

local ok_dbg, dbg = pcall(require, "runtime.debug")
assert(ok_dbg, "debug module required")

-- Run one CLI step and return the parsed JSON response.
-- input       = choice string (e.g. "1", "", "q")
-- extra_opts  = {reset, seed}
local function step(game_table, save_path, input, extra_opts)
  extra_opts = extra_opts or {}

  -- Capture output via a writable buffer table
  local buf = {}
  local output = { write = function(_, s) buf[#buf+1] = s end }

  local opts = {
    input  = input or "",
    reset  = extra_opts.reset,
    seed   = extra_opts.seed,
    output = output,
  }

  local rc = cli_cmd.run(game_table, save_path, opts)

  local json_str = table.concat(buf)
  local ok_json, resp = pcall(dbg.decode_json, json_str)
  assert(ok_json, "JSON decode failed: " .. tostring(json_str))
  return resp, rc
end

-- ── load test games ──────────────────────────────────────────────

local game01 = load_game("demos/demo01_wanderer.sb")
local game08 = load_game("demos/demo08_probability_engine.sb")

-- ── Basic: fresh start ──────────────────────────────────────────

describe("CLI cmd: fresh start", function()
  local path

  before_each(function()
    path = tmp_save()
  end)

  after_each(function()
    cleanup(path)
  end)

  it("returns type=state on first render", function()
    local resp = step(game01, path, "")
    assert.equal("state", resp.type)
  end)

  it("returns scene name on fresh start", function()
    local resp = step(game01, path, "")
    assert.is_truthy(resp.scene and resp.scene ~= "")
  end)

  it("returns narration array", function()
    local resp = step(game01, path, "")
    assert.is_table(resp.narration)
    assert.is_truthy(#resp.narration > 0)
  end)

  it("returns choices array", function()
    local resp = step(game01, path, "")
    assert.is_table(resp.choices)
    assert.is_truthy(#resp.choices > 0)
  end)

  it("each choice has index and label", function()
    local resp = step(game01, path, "")
    for _, c in ipairs(resp.choices) do
      assert.is_number(c.index)
      assert.is_string(c.label)
    end
  end)

  it("returns state table", function()
    local resp = step(game01, path, "")
    assert.is_table(resp.state)
  end)

  it("done=false when choices remain", function()
    local resp = step(game01, path, "")
    assert.is_false(resp.done)
  end)

  it("saved field is the save path", function()
    local resp = step(game01, path, "")
    assert.equal(path, resp.saved)
  end)

  it("creates the save file", function()
    step(game01, path, "")
    local f = io.open(path, "r")
    assert.is_not_nil(f, "save file was not created")
    if f then f:close() end
  end)

  it("creates the snapshot file", function()
    step(game01, path, "")
    local f = io.open(path .. ".snap", "r")
    assert.is_not_nil(f, "snapshot file was not created")
    if f then f:close() end
  end)

  it("initial state reflects game defaults (demo01 visited=0)", function()
    local resp = step(game01, path, "")
    assert.equal(0, resp.state["world/visited"])
  end)
end)

-- ── State persistence across steps ──────────────────────────────

describe("CLI cmd: state persistence", function()
  local path

  before_each(function()
    path = tmp_save()
  end)

  after_each(function()
    cleanup(path)
  end)

  it("state changes persist between invocations", function()
    step(game01, path, "")        -- fresh start: village, visited=0
    local resp = step(game01, path, "1")  -- make choice 1: go to forest, visited=1
    assert.equal(1, resp.state["world/visited"])
  end)

  it("scene advances after each choice", function()
    step(game01, path, "")
    local r1 = step(game01, path, "1")  -- forest
    local scene1 = r1.scene
    local r2 = step(game01, path, "1")  -- mountain-pass
    assert.not_equal(scene1, r2.scene)
  end)

  it("multiple steps accumulate state correctly", function()
    step(game01, path, "")
    step(game01, path, "1")  -- forest, visited=1
    local resp = step(game01, path, "1")  -- mountain-pass, visited=2
    assert.equal(2, resp.state["world/visited"])
  end)

  it("save file is updated each step", function()
    step(game01, path, "")
    local f1 = io.open(path, "r"); local s1 = f1:read("*a"); f1:close()
    step(game01, path, "1")
    local f2 = io.open(path, "r"); local s2 = f2:read("*a"); f2:close()
    assert.not_equal(s1, s2)
  end)
end)

-- ── Reset ────────────────────────────────────────────────────────

describe("CLI cmd: reset", function()
  local path

  before_each(function()
    path = tmp_save()
  end)

  after_each(function()
    cleanup(path)
  end)

  it("reset restores initial state after progress", function()
    step(game01, path, "")
    step(game01, path, "1")  -- advance to forest
    local resp = step(game01, path, "", { reset = true })
    assert.equal(0, resp.state["world/visited"])
  end)

  it("reset restores initial scene", function()
    step(game01, path, "")
    local r1 = step(game01, path, "1")
    assert.not_equal("village", r1.scene)
    local r2 = step(game01, path, "", { reset = true })
    assert.equal("village", r2.scene)
  end)

  it("save file is recreated after reset", function()
    step(game01, path, "")
    step(game01, path, "1")
    step(game01, path, "", { reset = true })
    local f = io.open(path, "r")
    assert.is_not_nil(f)
    if f then f:close() end
  end)
end)

-- ── Quit ─────────────────────────────────────────────────────────

describe("CLI cmd: quit", function()
  local path

  before_each(function()
    path = tmp_save()
  end)

  after_each(function()
    cleanup(path)
  end)

  it("quit returns type=quit", function()
    step(game01, path, "")  -- init
    local resp = step(game01, path, "q")
    assert.equal("quit", resp.type)
  end)

  it("quit preserves save file", function()
    step(game01, path, "")
    step(game01, path, "q")
    local f = io.open(path, "r")
    assert.is_not_nil(f, "save file should be preserved after quit")
    if f then f:close() end
  end)

  it("'quit' and 'q' and 'exit' all quit", function()
    for _, cmd in ipairs({"q", "quit", "exit"}) do
      local p = tmp_save()
      step(game01, p, "")
      local resp = step(game01, p, cmd)
      assert.equal("quit", resp.type, cmd .. " should quit")
      cleanup(p)
    end
  end)
end)

-- ── Error handling ────────────────────────────────────────────────

describe("CLI cmd: error handling", function()
  local path

  before_each(function()
    path = tmp_save()
  end)

  after_each(function()
    cleanup(path)
  end)

  it("invalid choice returns type=error", function()
    step(game01, path, "")  -- init, has 1 choice
    local resp = step(game01, path, "99")
    assert.equal("error", resp.type)
    assert.is_string(resp.message)
  end)

  it("non-numeric input returns type=error", function()
    step(game01, path, "")
    local resp = step(game01, path, "banana")
    assert.equal("error", resp.type)
  end)

  it("choice 0 is out of range", function()
    step(game01, path, "")
    local resp = step(game01, path, "0")
    assert.equal("error", resp.type)
  end)

  it("error message mentions the invalid choice", function()
    step(game01, path, "")
    local resp = step(game01, path, "99")
    assert.is_truthy(resp.message:find("99") or resp.message:find("range") or resp.message:find("choice"))
  end)
end)

-- ── Game completion ───────────────────────────────────────────────

describe("CLI cmd: game completion", function()
  local path

  before_each(function()
    path = tmp_save()
  end)

  after_each(function()
    cleanup(path)
  end)

  it("returns done=true when no choices remain (demo01 summit)", function()
    -- demo01: village(0) → forest(1) → mountain-pass(2) → summit(done, no choices)
    step(game01, path, "")   -- village: render, save
    step(game01, path, "1")  -- → forest
    step(game01, path, "1")  -- → mountain-pass
    -- mountain-pass choice 1 → summit, which has no choices
    local resp = step(game01, path, "1")
    assert.equal("done", resp.type)
    assert.is_true(resp.done)
    assert.equal(0, #resp.choices)
  end)
end)

-- ── Checkpoint + undo (demo08) ────────────────────────────────────

describe("CLI cmd: checkpoint and undo persistence", function()
  local path

  before_each(function()
    path = tmp_save()
  end)

  after_each(function()
    cleanup(path)
  end)

  it("gold increases after accepting supply contract", function()
    step(game08, path, "", { reset = true })  -- intro
    local r_shop = step(game08, path, "1")    -- open shop
    local gold_before = r_shop.state["world/gold"]
    step(game08, path, "1")                   -- consult supply (checkpoint saved)
    local r_after = step(game08, path, "1")   -- accept contract
    assert.equal(gold_before + 25, r_after.state["world/gold"])
  end)

  it("undo restores gold after accept-supply", function()
    step(game08, path, "", { reset = true })
    local r_shop = step(game08, path, "1")
    local gold_before = r_shop.state["world/gold"]
    step(game08, path, "1")   -- consult supply (checkpoint)
    step(game08, path, "1")   -- accept contract → gold += 25
    -- Back at shop: choice 4 = undo
    local r_undo = step(game08, path, "4")
    assert.equal(gold_before, r_undo.state["world/gold"])
  end)

  it("contracts count resets after undo", function()
    step(game08, path, "", { reset = true })
    step(game08, path, "1")   -- shop
    step(game08, path, "1")   -- consult supply
    step(game08, path, "1")   -- accept → contracts=1
    local r_undo = step(game08, path, "4")  -- undo
    assert.equal(0, r_undo.state["world/contracts"])
  end)

  it("checkpoints survive save/load cycle", function()
    step(game08, path, "", { reset = true })
    step(game08, path, "1")  -- open shop
    step(game08, path, "1")  -- consult supply (checkpoint created)
    step(game08, path, "1")  -- accept contract

    -- Verify save file contains checkpoint data
    local f = io.open(path, "r")
    assert.is_not_nil(f)
    local content = f:read("*a")
    f:close()
    assert.is_truthy(content:find("checkpoints"), "save file should contain checkpoints")
  end)
end)

-- ── State field completeness ──────────────────────────────────────

describe("CLI cmd: state fields", function()
  local path

  before_each(function()
    path = tmp_save()
    step(game08, path, "", { reset = true })
  end)

  after_each(function()
    cleanup(path)
  end)

  it("all demo08 state paths present on fresh start", function()
    local resp = step(game08, path, "")
    local expected = {
      "world/day", "world/gold", "world/reputation", "world/contracts",
      "supply/route", "supply/arrived",
      "gambler/tokens", "gambler/purse",
      "spy/position", "spy/caught",
    }
    for _, p in ipairs(expected) do
      assert.is_not_nil(resp.state[p], p .. " missing from state")
    end
  end)

  it("state values match initial defaults", function()
    local resp = step(game08, path, "")
    assert.equal(1,     resp.state["world/day"])
    assert.equal(80,    resp.state["world/gold"])
    assert.equal(25,    resp.state["world/reputation"])
    assert.equal(0,     resp.state["world/contracts"])
    assert.equal(false, resp.state["spy/caught"])
    assert.equal(false, resp.state["supply/arrived"])
  end)
end)

-- ── CLI subprocess integration ────────────────────────────────────
-- These tests invoke the real CLI binary via os.execute to verify
-- the flag parsing and JSON pipe work end-to-end.

local function run_cli_pipe(input, args_str)
  local save = tmp_save()
  local cmd = string.format(
    'echo %q | lua5.4 cli/main.lua run demos/demo01_wanderer.sb --cli %q %s 2>/dev/null',
    input, save, args_str or "")
  local f = io.popen(cmd, "r")
  local out = f:read("*a")
  f:close()
  cleanup(save)
  local ok, dbg = pcall(require, "runtime.debug")
  if not ok then return nil end
  local ok2, resp = pcall(dbg.decode_json, out)
  return ok2 and resp or nil
end

describe("CLI cmd: subprocess integration", function()
  it("pipe fresh start returns valid JSON with type=state", function()
    local resp = run_cli_pipe("")
    assert.is_not_nil(resp)
    assert.equal("state", resp.type)
  end)

  it("pipe choice 1 advances the game", function()
    local save = tmp_save()
    local function run(input, flags)
      local cmd = string.format(
        'echo %q | lua5.4 cli/main.lua run demos/demo01_wanderer.sb --cli %q %s 2>/dev/null',
        input, save, flags or "")
      local f = io.popen(cmd, "r")
      local out = f:read("*a")
      f:close()
      local ok, dbg = pcall(require, "runtime.debug")
      if not ok then return nil end
      local ok2, resp = pcall(dbg.decode_json, out)
      return ok2 and resp or nil
    end

    local r1 = run("", "--reset")   -- fresh: village, visited=0
    assert.is_not_nil(r1)
    assert.equal(0, r1.state["world/visited"])

    local r2 = run("1")             -- forest, visited=1
    assert.is_not_nil(r2)
    assert.equal(1, r2.state["world/visited"])

    cleanup(save)
  end)

  it("--reset flag restores initial state", function()
    local save = tmp_save()
    local function run(input, flags)
      local cmd = string.format(
        'echo %q | lua5.4 cli/main.lua run demos/demo01_wanderer.sb --cli %q %s 2>/dev/null',
        input, save, flags or "")
      local f = io.popen(cmd, "r")
      local out = f:read("*a")
      f:close()
      local ok, dbg = pcall(require, "runtime.debug")
      if not ok then return nil end
      local ok2, resp = pcall(dbg.decode_json, out)
      return ok2 and resp or nil
    end

    run("", "")        -- init
    run("1", "")       -- advance
    local r = run("", "--reset")  -- reset
    assert.is_not_nil(r)
    assert.equal(0, r.state["world/visited"])
    assert.equal("village", r.scene)
    cleanup(save)
  end)
end)

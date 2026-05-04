-- tests/cli/extract_symbols_spec.lua
-- Tests for cli/extract_cmd.lua (extract-symbols command) and
-- compiler.parse_and_check / parse_and_check_file.

local compiler    = require("compiler.compiler")
local extract_cmd = require("cli.extract_cmd")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function with_tmpfile(src, fn)
  local path = os.tmpname() .. ".sb"
  local f = io.open(path, "w"); f:write(src); f:close()
  local ok, err = pcall(fn, path)
  os.remove(path)
  if not ok then error(err, 2) end
end

-- ── compiler.parse_and_check ──────────────────────────────────────────────────

describe("compiler.parse_and_check", function()
  local SRC = [[
module pc-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  score: Int(0, 99) = 0

scene main:
  * Go
    inc! world/score 1
    -> main
]]

  it("returns typed AST with decls", function()
    local typed, diags = compiler.parse_and_check(SRC, "pc-test")
    assert.is_not_nil(typed, "expected typed AST")
    assert.is_false(diags:has_errors())
    assert.is_table(typed.decls)
    assert.is_true(#typed.decls > 0, "expected at least one decl")
  end)

  it("returns nil on parse error", function()
    local typed, diags = compiler.parse_and_check("module @@bad", "bad")
    assert.is_nil(typed)
    assert.is_true(diags:has_errors())
  end)

  it("returns nil on checker error", function()
    local src = [[
module bad-test
  version: 1.0
engine-config:
  entry-scene: main

state x: UndefinedType = 0

scene main:
  Done.
]]
    local typed, diags = compiler.parse_and_check(src, "bad-test")
    assert.is_nil(typed)
    assert.is_true(diags:has_errors())
  end)
end)

describe("compiler.parse_and_check_file", function()
  it("returns typed AST for a valid .sb file", function()
    with_tmpfile([[
module file-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  x: Int(0, 10) = 0

scene main:
  Done.
]], function(path)
      local typed, diags = compiler.parse_and_check_file(path)
      assert.is_not_nil(typed)
      assert.is_false(diags:has_errors())
    end)
  end)

  it("returns error for nonexistent file", function()
    local typed, diags = compiler.parse_and_check_file("/nonexistent/path/file.sb")
    assert.is_nil(typed)
    assert.is_true(diags:has_errors())
  end)
end)

-- ── extract_cmd.run ───────────────────────────────────────────────────────────

describe("extract_cmd.run", function()
  local SRC_WITH_SYMBOLS = [[
module sym-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  location: Symbol = `village
  mood:     Symbol = `happy

scene main:
  * Go to forest
    set! player/location `forest
    -> forest
  * Go to dungeon
    set! player/location `dungeon
    -> main
  * Feel sad
    set! player/mood `sad
    -> main

scene forest:
  * Return
    set! player/location `village
    set! player/mood `happy
    -> main
]]

  local SRC_NO_SYMBOLS = [[
module no-sym-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  score: Int(0, 99) = 0

scene main:
  * Score
    inc! world/score 1
    -> main
]]

  it("returns 1 with no arguments", function()
    -- Capture stderr
    local old_stderr = io.stderr
    io.stderr = io.open("/dev/null", "w")
    local rc = extract_cmd.run({})
    io.stderr:close(); io.stderr = old_stderr
    assert.equal(1, rc)
  end)

  it("returns 1 for nonexistent file", function()
    local old_stderr = io.stderr
    io.stderr = io.open("/dev/null", "w")
    local rc = extract_cmd.run({"/nonexistent/missing.sb"})
    io.stderr:close(); io.stderr = old_stderr
    assert.equal(1, rc)
  end)

  it("returns 0 for a valid file with symbols", function()
    with_tmpfile(SRC_WITH_SYMBOLS, function(path)
      -- Redirect stdout to capture output
      local captured = {}
      local old_write = io.write
      io.write = function(s) captured[#captured+1] = s end

      local rc = extract_cmd.run({path})

      io.write = old_write

      assert.equal(0, rc)
      local out = table.concat(captured)
      -- Should mention the path
      assert.is_truthy(out:find("player/location"))
      -- Should suggest a type for location (3 distinct values)
      assert.is_truthy(out:find("type Location"))
    end)
  end)

  it("detects multi-value paths and suggests enum type declarations", function()
    with_tmpfile(SRC_WITH_SYMBOLS, function(path)
      local captured = {}
      local old_write = io.write
      io.write = function(s) captured[#captured+1] = s end

      extract_cmd.run({path})
      io.write = old_write

      local out = table.concat(captured)
      -- location has 3 distinct values: village, forest, dungeon
      assert.is_truthy(out:find("Location"))
      assert.is_truthy(out:find("dungeon"))
      assert.is_truthy(out:find("forest"))
      assert.is_truthy(out:find("village"))
      -- mood has 2 distinct values: happy, sad
      assert.is_truthy(out:find("Mood"))
    end)
  end)

  it("reports all unique symbols found", function()
    with_tmpfile(SRC_WITH_SYMBOLS, function(path)
      local captured = {}
      local old_write = io.write
      io.write = function(s) captured[#captured+1] = s end

      extract_cmd.run({path})
      io.write = old_write

      local out = table.concat(captured)
      assert.is_truthy(out:find("All symbol literals found"))
      -- 5 unique: village, forest, dungeon, happy, sad
      assert.is_truthy(out:find("5 unique"))
    end)
  end)

  it("handles file with no symbols gracefully", function()
    with_tmpfile(SRC_NO_SYMBOLS, function(path)
      local captured = {}
      local old_write = io.write
      io.write = function(s) captured[#captured+1] = s end

      local rc = extract_cmd.run({path})
      io.write = old_write

      assert.equal(0, rc)
      local out = table.concat(captured)
      assert.is_truthy(out:find("No symbol literals found"))
    end)
  end)

  it("symbols in default values are collected", function()
    local src = [[
module default-sym-test
  version: 1.0
engine-config:
  entry-scene: main

state player:
  status: Symbol = `alive

fn update:
  set! player/status `dead

scene main:
  * Die
    update
    -> main
]]
    with_tmpfile(src, function(path)
      local captured = {}
      local old_write = io.write
      io.write = function(s) captured[#captured+1] = s end

      extract_cmd.run({path})
      io.write = old_write

      local out = table.concat(captured)
      -- 2 unique symbols: alive, dead — should trigger a type suggestion
      assert.is_truthy(out:find("alive"))
      assert.is_truthy(out:find("dead"))
    end)
  end)
end)

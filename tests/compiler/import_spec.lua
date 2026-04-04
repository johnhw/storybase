-- tests/compiler/import_spec.lua
-- Tests for the import resolver in compiler/compiler.lua.

local compiler = require("compiler.compiler")

-- Helper: write source to a temp file and return the path
local function tmpfile(src)
  local path = os.tmpname() .. ".sb"
  local f = io.open(path, "w"); f:write(src); f:close()
  return path
end

-- Helper: write multiple files to a temp directory
local function tmpdir_files(files)
  local dir = os.tmpname()  -- use as base prefix
  os.remove(dir)
  -- Can't create directory portably; use file prefix instead
  -- Write each file to /tmp with unique name, return map of short_name → path
  local paths = {}
  for name, src in pairs(files) do
    local path = dir .. "_" .. name
    local f = io.open(path, "w"); f:write(src); f:close()
    paths[name] = path
  end
  return paths
end

-- ── Basic imports ─────────────────────────────────────────────────────────────

describe("import resolver: basic", function()
  it("file with no imports compiles unchanged", function()
    local path = tmpfile([[
module no-import
  version: 1.0
engine-config:
  entry-scene: main

state x: Int(0,9) = 0

scene main:
  Done.
]])
    local gt, diags = compiler.compile_file(path)
    os.remove(path)
    assert.is_not_nil(gt)
    assert.is_false(diags:has_errors())
  end)

  it("imported types are visible in main file", function()
    -- Write lib file first
    local lib = tmpfile([[
module lib
  version: 1.0

type Color = red | green | blue

state world:
  color: Color = 'red
]])
    -- Write main file that imports the lib using its actual path
    local main = tmpfile(string.format([[
module main
  version: 1.0
engine-config:
  entry-scene: s

import %q

state player:
  fav: Color = 'blue

scene s:
  Done.
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)

    assert.is_not_nil(gt, "compilation should succeed")
    assert.is_false(diags:has_errors(), tostring(diags.errors and diags.errors[1] and diags.errors[1].message))

    -- Schema should include both world (from lib) and player (from main)
    assert.is_not_nil(gt.schema and gt.schema.states)
    -- 2 top-level state records: world (from lib) + player (from main)
    assert.equal(2, gt.schema.path_count)
    local paths = {}
    for _, s in ipairs(gt.schema.states) do paths[s.path] = true end
    assert.is_true(paths["world"],  "expected world record from imported lib")
    assert.is_true(paths["player"], "expected player record from main file")
    -- Also verify the type was imported (Color)
    assert.equal(1, gt.schema.type_count)
  end)

  it("imported functions are callable in main file", function()
    local lib = tmpfile([[
module fn-lib
  version: 1.0

state counter: Int(0, 999) = 0

fn increment:
  inc! counter 1
]])
    local main = tmpfile(string.format([[
module fn-main
  version: 1.0
engine-config:
  entry-scene: s

import %q

scene s:
  * Go
    increment
    -> s
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt)
    assert.is_false(diags:has_errors())
    -- fn should be in compiled output
    assert.is_not_nil(gt.fns and gt.fns["increment"])
  end)

  it("imported scenes are present in compiled output", function()
    local lib = tmpfile([[
module scene-lib
  version: 1.0

scene prologue:
  The prologue.
]])
    local main = tmpfile(string.format([[
module scene-main
  version: 1.0
engine-config:
  entry-scene: prologue

import %q
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt)
    assert.is_false(diags:has_errors())
    assert.is_not_nil(gt.scenes and gt.scenes["prologue"])
  end)
end)

-- ── Error cases ───────────────────────────────────────────────────────────────

describe("import resolver: errors", function()
  it("missing import file reports FILE_NOT_FOUND error", function()
    local main = tmpfile([[
module err-main
  version: 1.0
engine-config:
  entry-scene: s

import "nonexistent_9999.sb"

scene s:
  Done.
]])
    local gt, diags = compiler.compile_file(main)
    os.remove(main)
    assert.is_nil(gt)
    assert.is_true(diags:has_errors())
    -- Check for FILE_NOT_FOUND
    local found = false
    for _, e in ipairs(diags.errors) do
      if e.code == "FILE_NOT_FOUND" then found = true end
    end
    assert.is_true(found, "expected FILE_NOT_FOUND error")
  end)

  it("import cycle reports IMPORT_CYCLE error", function()
    -- a.sb imports b.sb, b.sb imports a.sb
    local a = os.tmpname() .. "_a.sb"
    local b = os.tmpname() .. "_b.sb"
    local fa = io.open(a, "w")
    fa:write(string.format("module a\n  version: 1.0\nimport %q\nstate ax: Int(0,9) = 0\n", b))
    fa:close()
    local fb = io.open(b, "w")
    fb:write(string.format("module b\n  version: 1.0\nimport %q\nstate bx: Int(0,9) = 0\n", a))
    fb:close()

    local main = tmpfile(string.format([[
module cycle-main
  version: 1.0
engine-config:
  entry-scene: s

import %q

scene s:
  Done.
]], a))
    local gt, diags = compiler.compile_file(main)
    os.remove(a); os.remove(b); os.remove(main)
    assert.is_nil(gt)
    local found = false
    for _, e in ipairs(diags.errors) do
      if e.code == "IMPORT_CYCLE" then found = true end
    end
    assert.is_true(found, "expected IMPORT_CYCLE error")
  end)
end)

-- ── Transitive imports ────────────────────────────────────────────────────────

describe("import resolver: transitive", function()
  it("a imports b which imports c; all declarations available", function()
    local c = tmpfile([[
module c-lib
  version: 1.0

type Status = alive | dead
]])
    local b = tmpfile(string.format([[
module b-lib
  version: 1.0

import %q

state enemy:
  status: Status = 'alive
]], c))
    local main = tmpfile(string.format([[
module trans-main
  version: 1.0
engine-config:
  entry-scene: s

import %q

state player:
  status: Status = 'alive

scene s:
  Done.
]], b))
    local gt, diags = compiler.compile_file(main)
    os.remove(c); os.remove(b); os.remove(main)
    assert.is_not_nil(gt)
    assert.is_false(diags:has_errors())
    -- 3 top-level records: enemy (from b-lib), player (from main)
    -- Type Status from c-lib, so type_count=1, path_count=2
    assert.equal(1, gt.schema.type_count)
    assert.equal(2, gt.schema.path_count)
    local paths = {}
    for _, s in ipairs(gt.schema.states or {}) do paths[s.path] = true end
    assert.is_true(paths["enemy"],  "expected enemy record from b-lib")
    assert.is_true(paths["player"], "expected player record from main")
  end)
end)

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

-- ── Duplicate name across import ───────────────────────────────────────────────

describe("import resolver: duplicate names", function()
  it("duplicate type name from import produces DUPLICATE_NAME error", function()
    local lib = tmpfile([[
module dup-lib
  version: 1.0
type Color = red | green
]])
    local main = tmpfile(string.format([[
module dup-main
  version: 1.0
engine-config:
  entry-scene: s
import %q
type Color = blue | yellow
scene s:
  Done.
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    local found = false
    for _, e in ipairs(diags.errors or {}) do
      if e.code == "DUPLICATE_NAME" then found = true end
    end
    assert.is_true(found, "expected DUPLICATE_NAME error for duplicate type")
  end)

  it("duplicate state path from import produces DUPLICATE_NAME error", function()
    local lib = tmpfile([[
module state-lib
  version: 1.0
state counter: Int(0,9) = 0
]])
    local main = tmpfile(string.format([[
module state-main
  version: 1.0
engine-config:
  entry-scene: s
import %q
state counter: Int(0,99) = 0
scene s:
  Done.
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    local found = false
    for _, e in ipairs(diags.errors or {}) do
      if e.code == "DUPLICATE_NAME" then found = true end
    end
    assert.is_true(found, "expected DUPLICATE_NAME for duplicate state path")
  end)
end)

-- ── Namespaced imports (`import "path" as Alias`) ────────────────────────────

describe("import resolver: namespaced import as Alias", function()
  it("plain import (no alias) still works", function()
    local lib = tmpfile([[
module plain-lib
  version: 1.0
state plain:
  x: Int(0, 9) = 0
]])
    local main = tmpfile(string.format([[
module plain-main
  version: 1.0
engine-config:
  entry-scene: s

import %q

scene s:
  Done.
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt, "plain import should compile")
    assert.is_false(diags:has_errors())
  end)

  it("type from aliased import accessible as Alias.TypeName", function()
    local lib = tmpfile([[
module ns-type-lib
  version: 1.0
type Color = red | green | blue
]])
    local main = tmpfile(string.format([[
module ns-type-main
  version: 1.0
engine-config:
  entry-scene: s

import %q as C

state world:
  color: C.Color = 'red

scene s:
  Done.
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt, "namespaced type import should compile: " ..
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    -- The type should be registered under C.Color
    local found_type = false
    for _, t in ipairs(gt.schema and gt.schema.types or {}) do
      if t.name == "C.Color" then found_type = true end
    end
    assert.is_true(found_type, "expected type C.Color in schema")
  end)

  it("function from aliased import callable as Alias.fn-name", function()
    local lib = tmpfile([[
module ns-fn-lib
  version: 1.0
state counter: Int(0, 999) = 0
fn add-ten:
  inc! counter 10
]])
    local main = tmpfile(string.format([[
module ns-fn-main
  version: 1.0
engine-config:
  entry-scene: s

import %q as L

scene s:
  * Go
    L.add-ten
    -> s
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt, "namespaced fn import should compile: " ..
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    -- Function should be stored under qualified name
    assert.is_not_nil(gt.fns and gt.fns["L.add-ten"],
      "expected fn L.add-ten in game table")
  end)

  it("state paths from aliased import remain global (no prefix)", function()
    local lib = tmpfile([[
module ns-state-lib
  version: 1.0
state world:
  hp: Int(0, 100) = 100
]])
    local main = tmpfile(string.format([[
module ns-state-main
  version: 1.0
engine-config:
  entry-scene: s

import %q as W

scene s:
  HP: {world/hp}
  * End
    -> s
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt, "state from aliased import should be global: " ..
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    -- State path must be global (no prefix)
    local paths = {}
    for _, s in ipairs(gt.schema and gt.schema.states or {}) do
      paths[s.path] = true
    end
    assert.is_true(paths["world"], "world state should be globally accessible")
  end)

  it("internal cross-references within aliased module are rewritten", function()
    -- helper-fn calls base-fn internally; both get prefixed when imported as N
    local lib = tmpfile([[
module ns-cross-lib
  version: 1.0
state x: Int(0, 999) = 0
fn base-fn:
  inc! x 5
fn helper-fn:
  base-fn
  base-fn
]])
    local main = tmpfile(string.format([[
module ns-cross-main
  version: 1.0
engine-config:
  entry-scene: s

import %q as N

scene s:
  * Run
    N.helper-fn
    -> s
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt, "cross-reference rewrite should succeed: " ..
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    assert.is_not_nil(gt.fns and gt.fns["N.base-fn"], "expected N.base-fn")
    assert.is_not_nil(gt.fns and gt.fns["N.helper-fn"], "expected N.helper-fn")
  end)

  it("scene from aliased import accessible as Alias.scene-name via ->", function()
    local lib = tmpfile([[
module ns-scene-lib
  version: 1.0
scene intro:
  The beginning.
  * Continue
    -> intro
]])
    local main = tmpfile(string.format([[
module ns-scene-main
  version: 1.0
engine-config:
  entry-scene: start

import %q as S

scene start:
  Go!
  * Enter
    -> S.intro
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt, "namespaced scene import should compile: " ..
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    assert.is_not_nil(gt.scenes and gt.scenes["S.intro"],
      "expected S.intro in game table")
  end)

  it("two different aliased imports do not conflict", function()
    local libA = tmpfile([[
module a-lib
  version: 1.0
type Color = red | blue
fn paint:
  pass
]])
    local libB = tmpfile([[
module b-lib
  version: 1.0
type Color = green | yellow
fn paint:
  pass
]])
    local main = tmpfile(string.format([[
module dual-main
  version: 1.0
engine-config:
  entry-scene: s

import %q as A
import %q as B

state world:
  ca: A.Color = 'red
  cb: B.Color = 'green

scene s:
  Done.
]], libA, libB))
    local gt, diags = compiler.compile_file(main)
    os.remove(libA); os.remove(libB); os.remove(main)
    assert.is_not_nil(gt, "two aliased imports should not conflict: " ..
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    -- Both A.Color and B.Color should exist
    local types = {}
    for _, t in ipairs(gt.schema and gt.schema.types or {}) do
      types[t.name] = true
    end
    assert.is_true(types["A.Color"], "expected A.Color")
    assert.is_true(types["B.Color"], "expected B.Color")
  end)

  it("unqualified name from aliased import not accessible (UNDEFINED_TYPE)", function()
    local lib = tmpfile([[
module ns-unq-lib
  version: 1.0
type Widget = big | small
]])
    local main = tmpfile(string.format([[
module ns-unq-main
  version: 1.0
engine-config:
  entry-scene: s

import %q as W

state world:
  w: Widget = 'big

scene s:
  Done.
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    -- Widget is not accessible unqualified; W.Widget would work
    assert.is_nil(gt, "unqualified name from aliased import should fail")
    local found = false
    for _, e in ipairs(diags.errors or {}) do
      if e.code == "UNDEFINED_TYPE" then found = true end
    end
    assert.is_true(found, "expected UNDEFINED_TYPE for unqualified Widget")
  end)
end)

-- ── module exports: filtering ─────────────────────────────────────────────────

describe("import resolver: module exports filtering", function()
  it("exported names are accessible in the importing file", function()
    local lib = tmpfile([[
module exports-lib
  version: 1.0
  exports: [Color]

type Color = red | green
type Secret = hidden | revealed
state world:
  color: Color = 'red
]])
    local main = tmpfile(string.format([[
module exports-main
  version: 1.0
engine-config:
  entry-scene: s

import %q

state player:
  color: Color = 'green

scene s:
  Done.
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt, "should compile successfully")
    assert.is_false(diags:has_errors(), table.concat(
      (function() local t={}; for _,e in ipairs(diags.errors or {}) do t[#t+1]=e.message end; return t end)(), "; "))
  end)

  it("non-exported names are not accessible in the importing file", function()
    local lib = tmpfile([[
module exports-lib2
  version: 1.0
  exports: [Color]

type Color = red | green
type Secret = hidden | revealed
]])
    local main = tmpfile(string.format([[
module exports-main2
  version: 1.0
engine-config:
  entry-scene: s

import %q

state player:
  secret: Secret = 'hidden

scene s:
  Done.
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    -- Secret is not exported → should be an error (UNDEFINED_TYPE or similar)
    assert.is_true(diags:has_errors(), "expected error: Secret is not exported")
  end)

  it("non-exported functions are not callable from importing file", function()
    local lib = tmpfile([[
module fn-exports-lib
  version: 1.0
  exports: [visible-fn]

fn visible-fn:
  -> 42

fn hidden-fn:
  -> 99
]])
    local main = tmpfile(string.format([[
module fn-exports-main
  version: 1.0
engine-config:
  entry-scene: s

import %q

scene s:
  let x = (hidden-fn):
    Done.
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    -- hidden-fn not exported → should error
    assert.is_true(diags:has_errors(), "expected error: hidden-fn is not exported")
  end)

  it("state declarations always pass through regardless of exports:", function()
    local lib = tmpfile([[
module state-exports-lib
  version: 1.0
  exports: [Color]

type Color = red | green
state world:
  color: Color = 'red
]])
    local main = tmpfile(string.format([[
module state-exports-main
  version: 1.0
engine-config:
  entry-scene: s

import %q

scene s:
  Done.
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    -- state world/color should be present even though only Color is in exports
    assert.is_not_nil(gt, "should compile")
    assert.is_false(diags:has_errors())
  end)

  it("module exports: list is parsed and stored in AST", function()
    local src = [[
module parsed-exports
  version: 1.0
  exports: [Foo, Bar]
engine-config:
  entry-scene: s
scene s:
  Done.
]]
    local typed, _ = compiler.parse_and_check(src, "x.sb")
    if typed then
      for _, decl in ipairs(typed.decls or {}) do
        if decl.kind == "module_decl" then
          assert.is_not_nil(decl.exports, "exports field should be present")
          assert.equal(2, #decl.exports)
          assert.equal("Foo", decl.exports[1])
          assert.equal("Bar", decl.exports[2])
        end
      end
    end
  end)
end)

-- ── compile() with absolute import path ──────────────────────────────────────

describe("import resolver: compile() with absolute import path", function()
  it("resolves absolute import path in source string", function()
    local lib = tmpfile([[
module abs-lib
  version: 1.0
type Rarity = common | rare
]])
    -- Build source that imports the absolute path
    local src = string.format([[
module abs-main
  version: 1.0
engine-config:
  entry-scene: s
import %q
state item:
  rarity: Rarity = 'common
scene s:
  Done.
]], lib)

    -- Compile as a string; import path is absolute so it resolves fine
    local gt, diags = compiler.compile(src, "abs-main.sb")
    os.remove(lib)
    assert.is_not_nil(gt)
    assert.is_false(diags:has_errors())
    assert.is_not_nil(gt.fns or gt.schema)
  end)

  it("imported relation is visible in main schema", function()
    local lib = tmpfile([[
module rel-lib
  version: 1.0
relation edges: Symbol -> Set(Symbol, 5)
]])
    local src = string.format([[
module rel-main
  version: 1.0
engine-config:
  entry-scene: s
import %q
scene s:
  Done.
]], lib)
    local gt, diags = compiler.compile(src, "rel-main.sb")
    os.remove(lib)
    assert.is_not_nil(gt)
    assert.is_false(diags:has_errors())
    assert.is_not_nil(gt.relations and gt.relations["edges"],
      "imported relation should be in game table")
  end)
end)

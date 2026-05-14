-- tests/compiler/compiler_spec.lua
-- Unit tests for the pipeline orchestrator (compiler/compiler.lua).
--
-- Import resolution itself is exercised in tests/compiler/import_spec.lua;
-- macro expansion in tests/compiler/macro_spec.lua. This file targets the
-- pipeline contract: stop-on-error behaviour, the parse_and_check variant,
-- compile_file file-error paths, opts propagation, and import cycle/file
-- error paths that aren't otherwise covered.

local compiler = require("compiler.compiler")

local function tmpfile(src, ext)
  local path = os.tmpname() .. (ext or ".sb")
  local f = io.open(path, "w"); f:write(src); f:close()
  return path
end

local function any_err_has_code(diags, code)
  for _, d in ipairs(diags.errors or {}) do
    if d.code == code then return true end
  end
  return false
end

local function any_err_matches(diags, pattern)
  for _, d in ipairs(diags.errors or {}) do
    if d.message and d.message:match(pattern) then return true end
  end
  return false
end

-- ============================================================
-- compile(source, filename) — happy path & stops
-- ============================================================

describe("compiler.compile — happy path", function()
  it("compiles a minimal program to a game table", function()
    local gt, diags = compiler.compile([[
engine-config:
  entry-scene: main

state world:
  x: Int(0,9) = 1

scene main:
  * Go -> main
]], "test.sb")
    assert.is_not_nil(gt)
    assert.is_false(diags:has_errors())
    assert.is_table(gt.fns)
    assert.is_table(gt.schema)
  end)

  it("returns errors=empty on a clean compile", function()
    local gt, diags = compiler.compile([[
engine-config:
  entry-scene: main

scene main:
  * Go -> main
]], "test.sb")
    assert.is_not_nil(gt)
    assert.equals(0, #(diags.errors or {}))
  end)
end)

describe("compiler.compile — error short-circuit", function()
  it("returns nil on parse error", function()
    local gt, diags = compiler.compile([[
engine-config:
  entry-scene: main

scene !!!broken!!!:
  body
]], "bad.sb")
    assert.is_nil(gt)
    assert.is_true(diags:has_errors())
  end)

  it("returns nil on checker error (invalid enum default)", function()
    local gt, diags = compiler.compile([[
engine-config:
  entry-scene: main

type Color = red | green | blue

state world:
  c: Color = `purple

scene main:
  * Go -> main
]], "bad.sb")
    assert.is_nil(gt)
    assert.is_true(diags:has_errors())
  end)

  it("checker errors are surfaced even when parsing succeeded", function()
    -- duplicate fn decl: parser is happy, checker is not
    local gt, diags = compiler.compile([[
engine-config:
  entry-scene: main

fn helper: pass
fn helper: pass

scene main:
  * Go -> main
]], "dup.sb")
    assert.is_nil(gt)
    assert.is_true(any_err_has_code(diags, "DUPLICATE_NAME"))
  end)
end)

-- ============================================================
-- parse_and_check (stops before codegen)
-- ============================================================

describe("compiler.parse_and_check", function()
  it("returns typed AST with .decls on success", function()
    local typed, diags = compiler.parse_and_check([[
engine-config:
  entry-scene: main

state world:
  x: Int(0,9) = 1

fn bump:
  inc! world/x 1

scene main:
  * Go -> main
]], "t.sb")
    assert.is_not_nil(typed)
    assert.is_false(diags:has_errors())
    assert.is_table(typed.decls)
    -- should have at least: engine-config, state, fn, scene
    assert.is_true(#typed.decls >= 4)
  end)

  it("returns nil on parse failure", function()
    local typed, diags = compiler.parse_and_check([[
engine-config:
  entry-scene: main

scene !!!:
  body
]], "t.sb")
    assert.is_nil(typed)
    assert.is_true(diags:has_errors())
  end)

  it("returns nil on check failure", function()
    local typed, diags = compiler.parse_and_check([[
engine-config:
  entry-scene: main

fn a: pass
fn a: pass

scene main:
  * Go -> main
]], "t.sb")
    assert.is_nil(typed)
    assert.is_true(any_err_has_code(diags, "DUPLICATE_NAME"))
  end)
end)

-- ============================================================
-- compile_file / parse_and_check_file
-- ============================================================

describe("compiler.compile_file", function()
  it("compiles a file from disk", function()
    local path = tmpfile([[
engine-config:
  entry-scene: main

scene main:
  * Go -> main
]])
    local gt, diags = compiler.compile_file(path)
    os.remove(path)
    assert.is_not_nil(gt)
    assert.is_false(diags:has_errors())
  end)

  it("emits FILE_NOT_FOUND for a missing path", function()
    local gt, diags = compiler.compile_file("/tmp/does-not-exist-" .. os.time() .. ".sb")
    assert.is_nil(gt)
    assert.is_true(any_err_has_code(diags, "FILE_NOT_FOUND"))
  end)
end)

describe("compiler.parse_and_check_file", function()
  it("returns typed AST for a real file", function()
    local path = tmpfile([[
engine-config:
  entry-scene: main

scene main:
  * Go -> main
]])
    local typed, diags = compiler.parse_and_check_file(path)
    os.remove(path)
    assert.is_not_nil(typed)
    assert.is_false(diags:has_errors())
  end)

  it("emits FILE_NOT_FOUND for a missing path", function()
    local typed, diags = compiler.parse_and_check_file("/tmp/missing-" .. os.time() .. ".sb")
    assert.is_nil(typed)
    assert.is_true(any_err_has_code(diags, "FILE_NOT_FOUND"))
  end)
end)

-- ============================================================
-- opts pass-through (production strips contracts)
-- ============================================================

describe("compiler.compile opts", function()
  it("passes opts.production through to codegen (drops verifies)", function()
    local src = [[
engine-config:
  entry-scene: main

state world:
  x: Int(0,9) = 0

verify "x stays non-negative":
  verify-always world/x >= 0

scene main:
  * Go -> main
]]
    local debug_gt, ddiag = compiler.compile(src, "t.sb")
    local prod_gt, pdiag  = compiler.compile(src, "t.sb", { production = true })
    assert.is_not_nil(debug_gt,
      ddiag.errors and ddiag.errors[1] and ddiag.errors[1].message)
    assert.is_not_nil(prod_gt,
      pdiag.errors and pdiag.errors[1] and pdiag.errors[1].message)
    -- production build has empty verifies, debug build has 1
    assert.is_true((debug_gt.verifies and #debug_gt.verifies or 0) >= 1,
      "debug build should retain verify blocks")
    assert.equals(0, #(prod_gt.verifies or {}),
      "production build should strip verify blocks")
  end)
end)

-- ============================================================
-- Import resolver — error paths not in import_spec
-- ============================================================

describe("compiler imports — missing file", function()
  it("emits FILE_NOT_FOUND on a non-existent import target", function()
    local main = tmpfile(string.format([[
engine-config:
  entry-scene: main

import %q

scene main:
  * Go -> main
]], "/tmp/totally-missing-" .. os.time() .. ".sb"))
    local gt, diags = compiler.compile_file(main)
    os.remove(main)
    assert.is_nil(gt)
    assert.is_true(any_err_has_code(diags, "FILE_NOT_FOUND"))
  end)
end)

describe("compiler imports — cycle detection", function()
  it("detects A → B → A as an import cycle", function()
    -- Create two files that import each other
    local a_path = os.tmpname() .. "_a.sb"
    local b_path = os.tmpname() .. "_b.sb"
    -- Need them both to exist before write so the second can refer to the first
    local fa = io.open(a_path, "w")
    fa:write(string.format([[
engine-config:
  entry-scene: main

import %q

scene main:
  * Go -> main
]], b_path))
    fa:close()
    local fb = io.open(b_path, "w")
    fb:write(string.format([[
import %q
]], a_path))
    fb:close()

    local gt, diags = compiler.compile_file(a_path)
    os.remove(a_path); os.remove(b_path)
    assert.is_nil(gt)
    assert.is_true(any_err_has_code(diags, "IMPORT_CYCLE")
                   or any_err_matches(diags, "import cycle"))
  end)
end)

describe("compiler imports — absolute vs relative resolution", function()
  it("absolute import path is used verbatim", function()
    local lib = tmpfile([[
module lib
  version: 1.0

type Mood = good | bad
]])
    local main = tmpfile(string.format([[
engine-config:
  entry-scene: main

import %q

state world:
  m: Mood = `good

scene main:
  * Go -> main
]], lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt, "absolute import should resolve")
    assert.is_false(diags:has_errors(),
      diags.errors and diags.errors[1] and diags.errors[1].message)
  end)
end)

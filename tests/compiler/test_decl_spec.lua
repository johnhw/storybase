-- tests/compiler/test_decl_spec.lua
-- Tests for `test` block parsing and codegen.

local compiler = require("compiler.compiler")
local parser   = require("compiler.parser")
local lexer    = require("compiler.lexer")
local ast      = require("compiler.ast")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local HEADER = [[
module mymod
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 100
  flag: Bool = false

fn spend gold:
  dec! world/gold gold

fn set-flag:
  set! world/flag true

scene main:
  * Done
    -> main

]]

local function compile(extra)
  return compiler.compile(HEADER .. extra, "test.sb")
end

-- ── Parser tests ──────────────────────────────────────────────────────────────

describe("test decl — parser", function()

  it("parses a test block and produces TEST_DECL node", function()
    local tokens, _ = lexer.tokenize(HEADER .. [[
test "my test":
  setup:
    set! world/gold 50
  run:
    spend 10
  expect:
    world/gold = 40
]], "t.sb")
    local root, diags = parser.parse(tokens, "t.sb")
    assert.equal(0, #diags, "no parse errors")

    local found = nil
    for _, d in ipairs(root.decls) do
      if d.kind == ast.K.TEST_DECL then found = d end
    end
    assert.is_not_nil(found, "TEST_DECL found")
    assert.equal("my test", found.label)
    assert.equal(1, #found.setup)
    assert.equal(1, #found.run)
    assert.equal(1, #found.expect)
  end)

  it("parses a test block with no label", function()
    local tokens, _ = lexer.tokenize(HEADER .. [[
test:
  expect:
    world/gold = 100
]], "t.sb")
    local root, diags = parser.parse(tokens, "t.sb")
    assert.equal(0, #diags)
    local found = nil
    for _, d in ipairs(root.decls) do
      if d.kind == ast.K.TEST_DECL then found = d end
    end
    assert.is_not_nil(found)
    assert.is_nil(found.label)
    assert.equal(1, #found.expect)
  end)

  it("parses a test block with only expect", function()
    local tokens, _ = lexer.tokenize(HEADER .. [[
test "only expect":
  expect:
    world/gold = 100
    world/flag = false
]], "t.sb")
    local root, _ = parser.parse(tokens, "t.sb")
    local found = nil
    for _, d in ipairs(root.decls) do
      if d.kind == ast.K.TEST_DECL then found = d end
    end
    assert.is_not_nil(found)
    assert.equal(0, #found.setup)
    assert.equal(0, #found.run)
    assert.equal(2, #found.expect)
  end)

  it("parses multiple test blocks", function()
    local tokens, _ = lexer.tokenize(HEADER .. [[
test "first":
  expect:
    world/gold = 100

test "second":
  expect:
    world/flag = false
]], "t.sb")
    local root, _ = parser.parse(tokens, "t.sb")
    local count = 0
    for _, d in ipairs(root.decls) do
      if d.kind == ast.K.TEST_DECL then count = count + 1 end
    end
    assert.equal(2, count)
  end)

  it("allows 'test' as identifier in module names", function()
    -- Regression: 'test' must not break as a module or ident name
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
scene main:
  * Done
    -> main
]]
    local tokens, terr = lexer.tokenize(src, "t.sb")
    assert.equal(0, #(terr or {}))
    local _, diags = parser.parse(tokens, "t.sb")
    assert.equal(0, #diags)
  end)

end)

-- ── Codegen tests ─────────────────────────────────────────────────────────────

describe("test decl — codegen", function()

  it("emits tests table in game_table", function()
    local gt, diags = compile([[
test "check defaults":
  expect:
    world/gold = 100
]])
    assert.equal(0, #(diags.errors or {}), "no compile errors")
    assert.is_table(gt.tests, "game_table.tests should be a table")
    assert.equal(1, #gt.tests)
  end)

  it("emits correct label", function()
    local gt, _ = compile([[
test "my label":
  expect:
    world/gold = 100
]])
    assert.equal("my label", gt.tests[1].label)
  end)

  it("emits empty tests in production builds", function()
    local gt, _ = compiler.compile(HEADER .. [[
test "check":
  expect:
    world/gold = 100
]], "t.sb", { production = true })
    assert.equal(0, #(gt.tests or {}), "tests stripped in production")
  end)

  it("emits multiple tests", function()
    local gt, _ = compile([[
test "t1":
  expect:
    world/gold = 100

test "t2":
  expect:
    world/flag = false
]])
    assert.equal(2, #gt.tests)
    assert.equal("t1", gt.tests[1].label)
    assert.equal("t2", gt.tests[2].label)
  end)

  it("emits setup, run, expect sections as AST node lists", function()
    local gt, _ = compile([[
test "full":
  setup:
    set! world/gold 50
  run:
    spend 10
  expect:
    world/gold = 40
]])
    local t = gt.tests[1]
    assert.equal(1, #t.setup)
    assert.equal(1, #t.run)
    assert.equal(1, #t.expect)
  end)

end)

-- tests/compiler/generate_spec.lua
-- Tests for §F1: `generate` block parsing, checking, and codegen.

local compiler = require("compiler.compiler")
local parser   = require("compiler.parser")
local lexer    = require("compiler.lexer")
local ast      = require("compiler.ast")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local HEADER = [[
module gen
  version: 1.0
engine-config:
  entry-scene: main

state world:
  seed: Int(0, 1000000) = 7
  flag: Bool = false
  count: Int(0, 100) = 0

state rooms/{r}: Bool max: 10

scene main:
  * Done
    -> main

]]

local function compile(extra)
  return compiler.compile(HEADER .. extra, "gen.sb")
end

local function lex_parse(src)
  local toks = lexer.tokenize(src, "g.sb")
  return parser.parse(toks, "g.sb")
end

-- ── Parser ────────────────────────────────────────────────────────────────────

describe("generate decl — parser", function()

  it("parses a generate block with no seed", function()
    local root, diags = lex_parse(HEADER .. [[
generate setup:
  set! world/flag true
]])
    assert.equal(0, #diags)
    local found
    for _, d in ipairs(root.decls) do
      if d.kind == ast.K.GENERATE_DECL then found = d end
    end
    assert.is_not_nil(found, "GENERATE_DECL emitted")
    assert.equal("setup", found.name)
    assert.is_nil(found.seed_path)
    assert.equal(1, #found.body)
  end)

  it("parses a generate block with a seed path", function()
    local root, diags = lex_parse(HEADER .. [[
generate dungeon seed: world/seed:
  set! world/count 5
  spawn! rooms "alpha" true
]])
    assert.equal(0, #diags)
    local found
    for _, d in ipairs(root.decls) do
      if d.kind == ast.K.GENERATE_DECL then found = d end
    end
    assert.is_not_nil(found)
    assert.equal("dungeon", found.name)
    assert.is_not_nil(found.seed_path)
    assert.equal(ast.K.PATH_EXPR, found.seed_path.kind)
    assert.equal("world", found.seed_path.segments[1])
    assert.equal("seed", found.seed_path.segments[2])
    assert.equal(2, #found.body)
  end)

  it("emits BAD_DECLARATION when name is missing", function()
    local _, diags = lex_parse(HEADER .. [[
generate :
  pass
]])
    -- Parser sees KEYWORD generate then OP ":" — should diagnose.
    local got
    for _, d in ipairs(diags) do
      if d.code == ast.E.BAD_DECLARATION then got = d end
    end
    assert.is_not_nil(got, "missing-name diagnostic emitted")
  end)
end)

-- ── Checker / codegen ─────────────────────────────────────────────────────────

describe("generate decl — codegen", function()

  it("populates game_table.generates with body preserved", function()
    local game, diags = compile([[
generate setup:
  set! world/flag true
]])
    assert.is_false(diags:has_errors(), "no compile errors")
    assert.is_table(game.generates)
    assert.equal(1, #game.generates)
    local g = game.generates[1]
    assert.equal("setup", g.name)
    assert.equal(1, #g.body)
    assert.equal(ast.K.SET_MUT, g.body[1].kind)
  end)

  it("preserves seed_path AST in the emitted entry", function()
    local game, _ = compile([[
generate world-gen seed: world/seed:
  set! world/count 3
]])
    local g = game.generates[1]
    assert.is_not_nil(g.seed_path)
    assert.equal("world", g.seed_path.segments[1])
    assert.equal("seed",  g.seed_path.segments[2])
  end)

  it("emits duplicate-name diagnostic when two generates share a name", function()
    local _, diags = compile([[
generate dup:
  set! world/flag true

generate dup:
  set! world/flag false
]])
    local got
    for _, d in ipairs(diags.diags or diags.all or {}) do
      if d.code == ast.E.DUPLICATE_NAME and d.message:match("generate") then got = d end
    end
    -- diags object surfaces .all
    if not got and diags.all then
      for _, d in ipairs(diags.all) do
        if d.code == ast.E.DUPLICATE_NAME and d.message:match("generate") then got = d end
      end
    end
    assert.is_not_nil(got, "duplicate generate name reported")
  end)

  it("undefined path mutations inside a generate body are warned", function()
    local _, diags = compile([[
generate bad:
  set! world/nope true
]])
    local got
    local list = diags.all or diags.diags or {}
    for _, d in ipairs(list) do
      if d.code == ast.E.UNDEFINED_PATH then got = d end
    end
    assert.is_not_nil(got, "UNDEFINED_PATH warning fired in generate body")
  end)

  it("undefined fn calls inside a generate body are warned", function()
    local _, diags = compile([[
generate bad:
  no-such-fn 1
]])
    local got
    for _, d in ipairs(diags.all or {}) do
      if d.code == ast.E.UNDEFINED_FN then got = d end
    end
    assert.is_not_nil(got, "UNDEFINED_FN warning fired in generate body")
  end)
end)

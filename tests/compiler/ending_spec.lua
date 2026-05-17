-- tests/compiler/ending_spec.lua
-- Tests for §F2: `ending` declaration parsing, checking, codegen,
-- and the auto-emitted verify blocks (reachability + mutual exclusivity).

local compiler = require("compiler.compiler")
local parser   = require("compiler.parser")
local lexer    = require("compiler.lexer")
local ast      = require("compiler.ast")

local HEADER = [[
module ends
  version: 1.0
engine-config:
  entry-scene: main
state world:
  chapter: Int(0, 5) = 0
  done:    Bool      = false
  failed:  Bool      = false
scene main:
  * Advance
    inc! world/chapter 1
    -> main
  * Finish
    set! world/done true
    -> main
  * Fail
    set! world/failed true
    -> main
]]

local function compile(extra)
  return compiler.compile(HEADER .. extra, "e.sb")
end

local function lex_parse(src)
  local toks = lexer.tokenize(src, "e.sb")
  return parser.parse(toks, "e.sb")
end

-- ── Parser ────────────────────────────────────────────────────────────────────

describe("ending decl — parser", function()

  it("parses a single ending with when: cond", function()
    local root, diags = lex_parse(HEADER .. [[
ending good when: world/done:
  "Victory."
]])
    assert.equal(0, #diags)
    local found
    for _, d in ipairs(root.decls) do
      if d.kind == ast.K.ENDING_DECL then found = d end
    end
    assert.is_not_nil(found, "ENDING_DECL emitted")
    assert.equal("good", found.name)
    assert.is_not_nil(found.when_expr)
    assert.is_true(#found.body >= 1)
  end)

  it("parses multiple endings independently", function()
    local root, diags = lex_parse(HEADER .. [[
ending good when: world/done:
  "Won."

ending bad when: world/failed:
  "Lost."
]])
    assert.equal(0, #diags)
    local found = {}
    for _, d in ipairs(root.decls) do
      if d.kind == ast.K.ENDING_DECL then found[#found+1] = d end
    end
    assert.equal(2, #found)
    assert.equal("good", found[1].name)
    assert.equal("bad",  found[2].name)
  end)

  it("rejects an ending missing 'when:' clause", function()
    local _, diags = lex_parse(HEADER .. [[
ending oops:
  "Whoops."
]])
    local got
    for _, d in ipairs(diags) do
      if d.code == ast.E.BAD_DECLARATION then got = d end
    end
    assert.is_not_nil(got)
  end)
end)

-- ── Codegen ──────────────────────────────────────────────────────────────────

describe("ending decl — codegen", function()

  it("emits game_table.endings with when_expr preserved", function()
    local game, diags = compile([[
ending good when: world/done:
  "Won."
]])
    assert.is_false(diags:has_errors())
    assert.equal(1, #game.endings)
    assert.equal("good", game.endings[1].name)
    assert.is_not_nil(game.endings[1].when_expr)
  end)

  it("auto-emits one reachability verify per ending", function()
    local game, _ = compile([[
ending good when: world/done:
  "Won."

ending bad when: world/failed:
  "Lost."
]])
    -- Two reachability + 1 pairwise exclusivity = 3 auto verifies.
    local reachable_labels = {}
    for _, v in ipairs(game.verifies) do
      if v._auto and v.label:match("is reachable") then
        reachable_labels[#reachable_labels+1] = v.label
      end
    end
    table.sort(reachable_labels)
    assert.same({
      "ending 'bad' is reachable",
      "ending 'good' is reachable",
    }, reachable_labels)
  end)

  it("auto-emits pairwise mutual-exclusivity verify for >=2 endings", function()
    local game, _ = compile([[
ending good when: world/done:
  "Won."

ending bad when: world/failed:
  "Lost."
]])
    local excl
    for _, v in ipairs(game.verifies) do
      if v._auto and v.label:match("mutually exclusive") then excl = v end
    end
    assert.is_not_nil(excl, "exclusivity verify emitted")
    assert.equal(1, #excl.clauses)
    assert.equal("always", excl.clauses[1].kind)
  end)

  it("emits no exclusivity verify when only one ending exists", function()
    local game, _ = compile([[
ending solo when: world/done:
  "Won."
]])
    for _, v in ipairs(game.verifies) do
      assert.is_nil(v.label:match("mutually exclusive"),
        "no pairwise verify for a single ending")
    end
  end)

  it("strips ending verifies in production mode", function()
    local game, _ = compiler.compile(HEADER .. [[
ending good when: world/done:
  "Won."
]], "e.sb", { production = true })
    assert.equal(0, #game.verifies)
    -- Endings themselves still emitted (engine still needs them at runtime).
    assert.equal(1, #game.endings)
  end)

  it("reports duplicate ending names", function()
    local _, diags = compile([[
ending good when: world/done:
  "A."

ending good when: world/failed:
  "B."
]])
    local got
    for _, d in ipairs(diags.all or {}) do
      if d.code == ast.E.DUPLICATE_NAME and d.message:match("ending") then got = d end
    end
    assert.is_not_nil(got)
  end)
end)

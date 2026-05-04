-- tests/cli/lsp_spec.lua
-- Unit tests for the StoryBase LSP server (cli/lsp.lua).
-- Tests symbol extraction, hover, definition, diagnostics, and completions
-- by calling the exported helper functions directly.

local lsp = require("cli.lsp")

-- ── Helpers ───────────────────────────────────────────────────

local function compile(src)
  local compiler = require("compiler.compiler")
  return compiler.parse_and_check(src, "test.sb")
end

local function syms_from(src)
  local ast = compile(src)
  return lsp.build_syms(ast)
end

local function lines_of(text)
  local ls = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    ls[#ls + 1] = line
  end
  return ls
end

-- Minimal valid module header + one scene so parse_and_check succeeds.
local HEADER = [[
module test
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: start
]]

-- ── build_syms ────────────────────────────────────────────────

describe("lsp.build_syms", function()

  it("returns empty table for nil AST", function()
    local syms = lsp.build_syms(nil)
    assert.is_table(syms)
    local n = 0; for _ in pairs(syms) do n = n + 1 end
    assert.are.equal(0, n)
  end)

  it("collects type declarations", function()
    local syms = syms_from(HEADER .. [[
type Mood = happy | sad | angry
scene start:
  Hello
]])
    assert.is_not_nil(syms["Mood"])
    assert.are.equal("type", syms["Mood"].kind)
  end)

  it("collects state scalar paths", function()
    local syms = syms_from(HEADER .. [[
type Health = Int(0, 100)
state player/health: Health = 50
scene start:
  Hello
]])
    assert.is_not_nil(syms["player/health"])
    assert.are.equal("state", syms["player/health"].kind)
  end)

  it("collects scene declarations", function()
    local syms = syms_from(HEADER .. [[
scene start:
  Welcome
]])
    assert.is_not_nil(syms["start"])
    assert.are.equal("scene", syms["start"].kind)
  end)

  it("collects fn declarations with detail listing params", function()
    local syms = syms_from(HEADER .. [[
type Health = Int(0, 100)
state player/health: Health = 50
fn heal amount:
  inc! player/health amount
scene start:
  Hello
]])
    assert.is_not_nil(syms["heal"])
    assert.are.equal("fn", syms["heal"].kind)
    assert.is_truthy(syms["heal"].detail:find("amount"))
  end)

  it("fn with no params has empty-parens detail", function()
    local syms = syms_from(HEADER .. [[
fn noop:
  pass
scene start:
  Hello
]])
    assert.is_not_nil(syms["noop"])
    assert.are.equal("()", syms["noop"].detail)
  end)

  it("collects actor declarations", function()
    -- Actors use a named behavior function; inline bodies are not valid actor syntax
    local syms = syms_from(HEADER .. [[
type Health = Int(0, 100)
state player/health: Health = 50
fn guard-behavior:
  pass
actor Guard:
  state:    player/health
  behavior: guard-behavior
scene start:
  Hello
]])
    assert.is_not_nil(syms["Guard"])
    assert.are.equal("actor", syms["Guard"].kind)
  end)

  it("captures doc strings on fn", function()
    local syms = syms_from(HEADER .. [[
type Health = Int(0, 100)
state player/health: Health = 50
"Heals the player by amount."
fn heal amount:
  pass
scene start:
  Hello
]])
    assert.is_not_nil(syms["heal"])
    assert.are.equal("Heals the player by amount.", syms["heal"].doc)
  end)

  it("doc is nil when not present", function()
    local syms = syms_from(HEADER .. [[
fn noop:
  pass
scene start:
  Hello
]])
    assert.is_not_nil(syms["noop"])
    -- Should not error; doc is nil
    assert.is_nil(syms["noop"].doc)
  end)

  it("collects position info on fn", function()
    local syms = syms_from(HEADER .. [[
fn noop:
  pass
scene start:
  Hello
]])
    assert.is_not_nil(syms["noop"])
    assert.is_not_nil(syms["noop"].pos)
    assert.is_number(syms["noop"].pos.line)
    assert.is_true(syms["noop"].pos.line >= 1)
  end)

  it("collects multiple kinds at once", function()
    local syms = syms_from(HEADER .. [[
type Status = alive | dead
type Health = Int(0, 100)
state player/health: Health = 50
fn advance:
  pass
scene intro:
  Hello
scene start:
  Done
]])
    assert.is_not_nil(syms["Status"])
    assert.is_not_nil(syms["player/health"])
    assert.is_not_nil(syms["advance"])
    assert.is_not_nil(syms["intro"])
    assert.is_not_nil(syms["start"])
  end)

  it("SceneId builtin type is included from symtab", function()
    -- The checker always adds SceneId to types
    local syms = syms_from(HEADER .. "scene start:\n  Hello\n")
    assert.is_not_nil(syms["SceneId"])
    assert.are.equal("type", syms["SceneId"].kind)
  end)

end)

-- ── word_at ───────────────────────────────────────────────────

describe("lsp.word_at", function()

  it("extracts a simple identifier", function()
    local ls = lines_of("fn heal amount:")
    -- cursor on `e' of `heal' (0-based col 3)
    assert.are.equal("heal", lsp.word_at(ls, 0, 3))
  end)

  it("extracts word when cursor is at start", function()
    local ls = lines_of("heal")
    assert.are.equal("heal", lsp.word_at(ls, 0, 0))
  end)

  it("extracts word when cursor is at last char", function()
    local ls = lines_of("heal")
    assert.are.equal("heal", lsp.word_at(ls, 0, 3))
  end)

  it("extracts a hyphenated identifier", function()
    local ls = lines_of("fn-call")
    assert.are.equal("fn-call", lsp.word_at(ls, 0, 4))
  end)

  it("extracts a state path with slash", function()
    local ls = lines_of("player/health")
    assert.are.equal("player/health", lsp.word_at(ls, 0, 5))
  end)

  it("returns nil for whitespace between tokens", function()
    local ls = lines_of("fn  heal")
    -- col 2 is first space between `fn' and `heal'
    assert.is_nil(lsp.word_at(ls, 0, 2))
  end)

  it("returns nil for out-of-bounds line", function()
    local ls = lines_of("fn heal")
    assert.is_nil(lsp.word_at(ls, 5, 0))
  end)

  it("handles empty line", function()
    local ls = lines_of("fn heal\n\nscene")
    assert.is_nil(lsp.word_at(ls, 1, 0))  -- empty middle line
  end)

  it("returns nil when cursor is on space after word", function()
    -- `heal ' — col 4 is the trailing space
    local ls = lines_of("heal x")
    assert.is_nil(lsp.word_at(ls, 0, 4))
  end)

  it("extracts word on second line", function()
    local ls = lines_of("first\nsecond")
    assert.are.equal("second", lsp.word_at(ls, 1, 2))
  end)

  it("extracts `fn' keyword itself", function()
    local ls = lines_of("fn heal")
    assert.are.equal("fn", lsp.word_at(ls, 0, 1))
  end)

  it("handles underscore in identifier", function()
    local ls = lines_of("my_var")
    assert.are.equal("my_var", lsp.word_at(ls, 0, 3))
  end)

end)

-- ── make_lsp_diags ────────────────────────────────────────────

describe("lsp.make_lsp_diags", function()

  local ast_mod = require("compiler.ast")

  it("returns empty list for no diagnostics", function()
    local acc = { all = {}, errors = {}, warnings = {} }
    local result = lsp.make_lsp_diags(acc)
    assert.are.equal(0, #result)
  end)

  it("converts an error diagnostic to LSP format", function()
    local d = ast_mod.error("UNDEFINED_TYPE", "unknown type Foo",
                             ast_mod.pos("test.sb", 5, 10))
    local acc = { all = { d }, errors = { d }, warnings = {} }
    local result = lsp.make_lsp_diags(acc)
    assert.are.equal(1, #result)
    local item = result[1]
    assert.are.equal(1, item.severity)
    assert.are.equal("UNDEFINED_TYPE", item.code)
    assert.are.equal("unknown type Foo", item.message)
    assert.are.equal(4, item.range.start.line)       -- 5 - 1
    assert.are.equal(9, item.range.start.character)  -- 10 - 1
  end)

  it("error severity is 1", function()
    local d = ast_mod.error("E", "msg", ast_mod.pos("f.sb", 1, 1))
    local acc = { all = { d }, errors = { d }, warnings = {} }
    local result = lsp.make_lsp_diags(acc)
    assert.are.equal(1, result[1].severity)
  end)

  it("warning severity is 2", function()
    local d = ast_mod.warning("W", "msg", ast_mod.pos("f.sb", 1, 1))
    local acc = { all = { d }, errors = {}, warnings = { d } }
    local result = lsp.make_lsp_diags(acc)
    assert.are.equal(2, result[1].severity)
  end)

  it("handles diagnostics with missing line/col", function()
    local d = { level = "error", code = "E", message = "oops", file = "x.sb" }
    local acc = { all = { d }, errors = { d }, warnings = {} }
    local result = lsp.make_lsp_diags(acc)
    assert.are.equal(1, #result)
    assert.are.equal(0, result[1].range.start.line)
    assert.are.equal(0, result[1].range.start.character)
  end)

  it("converts multiple diagnostics preserving order", function()
    local e = ast_mod.error("E1", "msg1", ast_mod.pos("f.sb", 1, 1))
    local w = ast_mod.warning("W1", "msg2", ast_mod.pos("f.sb", 2, 5))
    local acc = { all = { e, w }, errors = { e }, warnings = { w } }
    local result = lsp.make_lsp_diags(acc)
    assert.are.equal(2, #result)
    assert.are.equal(1, result[1].severity)
    assert.are.equal(2, result[2].severity)
  end)

  it("sets source field to `storybase'", function()
    local d = ast_mod.error("E", "msg", ast_mod.pos("f.sb", 1, 1))
    local acc = { all = { d }, errors = { d }, warnings = {} }
    local result = lsp.make_lsp_diags(acc)
    assert.are.equal("storybase", result[1].source)
  end)

end)

-- ── integration: real parse + symbol lookup ───────────────────

describe("lsp symbol integration", function()

  local SRC = HEADER .. [[
"Player health points."
type Health = Int(0, 100)
state player/health: Health = 50
type Status = alive | dead
"Check player is alive."
fn is-alive:
  player/health > 0
scene main:
  You stand at the entrance.
  -> go-inside  "Enter the dungeon"
scene start:
  You enter.
]]

  local syms

  setup(function()
    syms = syms_from(SRC)
  end)

  it("finds state path", function()
    assert.is_not_nil(syms["player/health"])
    assert.are.equal("state", syms["player/health"].kind)
  end)

  it("finds type", function()
    assert.is_not_nil(syms["Status"])
    assert.are.equal("type", syms["Status"].kind)
  end)

  it("finds fn", function()
    assert.is_not_nil(syms["is-alive"])
    assert.are.equal("fn", syms["is-alive"].kind)
  end)

  it("fn has correct doc", function()
    assert.are.equal("Check player is alive.", syms["is-alive"].doc)
  end)

  it("finds scene", function()
    assert.is_not_nil(syms["main"])
    assert.are.equal("scene", syms["main"].kind)
  end)

  it("word_at extracts hyphenated fn name from source", function()
    local ls = lines_of(SRC)
    local fn_line = nil
    for i, l in ipairs(ls) do
      if l:find("^fn is%-alive") then fn_line = i - 1; break end
    end
    assert.is_not_nil(fn_line, "fn is-alive line not found")
    local word = lsp.word_at(ls, fn_line, 3)
    assert.are.equal("is-alive", word)
  end)

  it("word_at extracts state path from source line", function()
    local ls = lines_of(SRC)
    local sp_line = nil
    for i, l in ipairs(ls) do
      if l:find("player/health:") then sp_line = i - 1; break end
    end
    assert.is_not_nil(sp_line, "player/health line not found")
    local word = lsp.word_at(ls, sp_line, 10)
    assert.are.equal("player/health", word)
    assert.is_not_nil(syms[word])
  end)

  it("fn symbol has position info", function()
    assert.is_not_nil(syms["is-alive"].pos)
    assert.is_number(syms["is-alive"].pos.line)
  end)

  it("state symbol has position info", function()
    assert.is_not_nil(syms["player/health"].pos)
    assert.is_number(syms["player/health"].pos.line)
  end)

end)

-- ── diagnostics from real parse errors ───────────────────────

describe("lsp.make_lsp_diags from real compilation", function()

  it("produces error diagnostic for undefined type", function()
    local _, diags = compile(HEADER .. [[
state player/status: UnknownType
scene start:
  Hello
]])
    local lsp_diags = lsp.make_lsp_diags(diags)
    local has_error = false
    for _, d in ipairs(lsp_diags) do
      if d.severity == 1 then has_error = true end
    end
    assert.is_true(has_error)
  end)

  it("produces no errors for valid source", function()
    local _, diags = compile(HEADER .. [[
type Health = Int(0, 100)
state player/health: Health = 50
scene start:
  Hello
]])
    local lsp_diags = lsp.make_lsp_diags(diags)
    local has_error = false
    for _, d in ipairs(lsp_diags) do
      if d.severity == 1 then has_error = true end
    end
    assert.is_false(has_error)
  end)

  it("error diagnostic has valid range", function()
    local _, diags = compile(HEADER .. [[
state player/status: UnknownType
scene start:
  Hello
]])
    local lsp_diags = lsp.make_lsp_diags(diags)
    local errs = {}
    for _, d in ipairs(lsp_diags) do
      if d.severity == 1 then errs[#errs + 1] = d end
    end
    assert.is_true(#errs >= 1)
    local r = errs[1].range
    assert.is_number(r.start.line)
    assert.is_number(r.start.character)
    assert.is_true(r.start.line >= 0)
    assert.is_true(r.start.character >= 0)
  end)

end)

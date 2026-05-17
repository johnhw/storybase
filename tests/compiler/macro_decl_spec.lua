-- tests/compiler/macro_decl_spec.lua
-- §E0 Stage 1: decl-macro parsing into DECL_MACRO_DECL AST nodes.
-- No interpolation or expansion is tested here — those land in stages 2–3.

local lexer    = require("compiler.lexer")
local parser   = require("compiler.parser")
local compiler = require("compiler.compiler")
local ast      = require("compiler.ast")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function parse(src)
  local tokens, lex_diags = lexer.tokenize(src, "test")
  local tree, parse_diags = parser.parse(tokens, "test")
  local diags = {}
  for _, d in ipairs(lex_diags)   do table.insert(diags, d) end
  for _, d in ipairs(parse_diags) do table.insert(diags, d) end
  return tree, diags
end

local function parse_errors(src)
  local _, diags = parse(src)
  local errs = {}
  for _, d in ipairs(diags) do
    if d.level == "error" then table.insert(errs, d) end
  end
  return errs
end

local function find_decl(tree, kind, name)
  for _, d in ipairs(tree.decls or {}) do
    if d.kind == kind and (name == nil or d.name == name) then
      return d
    end
  end
  return nil
end

-- ── Lexer ─────────────────────────────────────────────────────────────────────

describe("lexer — decl-macro keyword", function()
  it("recognises 'decl-macro' as a KEYWORD token", function()
    local tokens = lexer.tokenize("decl-macro foo:\n  pass\n", "test")
    -- First non-whitespace token should be the keyword
    local first = tokens[1]
    assert.equal("KEYWORD", first.kind)
    assert.equal("decl-macro", first.value)
  end)
end)

-- ── Parser — basic decl-macro shapes ──────────────────────────────────────────

describe("parser — decl-macro", function()
  it("parses a zero-param decl-macro with a state-decl body", function()
    local tree, diags = parse([[
decl-macro counter:
  state world/count: Int(0, 100) = 0
]])
    assert.equal(0, #parse_errors([[
decl-macro counter:
  state world/count: Int(0, 100) = 0
]]))
    local d = find_decl(tree, ast.K.DECL_MACRO_DECL, "counter")
    assert.is_not_nil(d)
    assert.equal("counter", d.name)
    assert.same({}, d.params)
    assert.equal(1, #d.body)
    assert.equal(ast.K.STATE_SCALAR, d.body[1].kind)
  end)

  it("parses a decl-macro body containing state and two fn decls", function()
    local src = [[
decl-macro counter:
  state world/count: Int(0, 100) = 0
  fn count-inc:
    inc! world/count 1
  fn count-reset:
    set! world/count 0
]]
    local tree, _ = parse(src)
    assert.equal(0, #parse_errors(src))

    local d = find_decl(tree, ast.K.DECL_MACRO_DECL, "counter")
    assert.is_not_nil(d)
    assert.equal(3, #d.body)
    assert.equal(ast.K.STATE_SCALAR, d.body[1].kind)
    assert.equal(ast.K.FN_DECL,      d.body[2].kind)
    assert.equal("count-inc",        d.body[2].name)
    assert.equal(ast.K.FN_DECL,      d.body[3].kind)
    assert.equal("count-reset",      d.body[3].name)
  end)

  it("parses a decl-macro with one named param", function()
    local src = [[
decl-macro counter path:
  state world/count: Int(0, 100) = 0
]]
    local tree, _ = parse(src)
    assert.equal(0, #parse_errors(src))
    local d = find_decl(tree, ast.K.DECL_MACRO_DECL, "counter")
    assert.is_not_nil(d)
    assert.same({"path"}, d.params)
  end)

  it("parses a decl-macro with multiple params", function()
    local src = [[
decl-macro pair a b:
  state world/flag: Bool = false
]]
    local tree, _ = parse(src)
    assert.equal(0, #parse_errors(src))
    local d = find_decl(tree, ast.K.DECL_MACRO_DECL, "pair")
    assert.is_not_nil(d)
    assert.same({"a", "b"}, d.params)
  end)

  it("parses a decl-macro body containing a verify decl", function()
    local src = [[
decl-macro safety:
  state world/count: Int(0, 100) = 0
  verify "non-negative":
    verify-always world/count >= 0
]]
    local tree, _ = parse(src)
    assert.equal(0, #parse_errors(src))
    local d = find_decl(tree, ast.K.DECL_MACRO_DECL, "safety")
    assert.is_not_nil(d)
    assert.equal(2, #d.body)
    assert.equal(ast.K.VERIFY_DECL, d.body[2].kind)
  end)

  it("parses an empty decl-macro body (no INDENT) without errors", function()
    -- An empty body should be accepted silently — mirroring fn behaviour.
    local src = "decl-macro empty:\n"
    local _, _ = parse(src)
    assert.equal(0, #parse_errors(src))
  end)

  it("preserves a leading doc string on the decl-macro", function()
    local src = [[
"counter macro — placeholder description"
decl-macro counter:
  state world/count: Int(0, 100) = 0
]]
    local tree, _ = parse(src)
    assert.equal(0, #parse_errors(src))
    local d = find_decl(tree, ast.K.DECL_MACRO_DECL, "counter")
    assert.is_not_nil(d)
    assert.equal("counter macro — placeholder description", d.doc)
  end)

  it("decl-macro pos points at the declaration line", function()
    local src = "\n\ndecl-macro counter:\n  state world/count: Int(0, 100) = 0\n"
    local tree, _ = parse(src)
    local d = find_decl(tree, ast.K.DECL_MACRO_DECL, "counter")
    assert.is_not_nil(d)
    assert.equal(3, d.pos.line)
  end)
end)

-- ── Compile pipeline — decl-macro stripped, no downstream errors ──────────────

describe("compile — decl-macro placeholder behaviour", function()
  -- A program containing only a decl-macro (no call sites) must compile
  -- cleanly. Stage 1 strips the node before the checker runs; expansion
  -- and interpolation arrive in stages 2–3.
  it("compiles a program with a decl-macro without errors", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
state world:
  count: Int(0, 100) = 0
decl-macro counter:
  fn noop:
    pass
scene main:
  the end
]]
    local _, diags = compiler.compile(src, "test.sb")
    local errors = (diags and diags.errors) or {}
    assert.equal(0, #errors)
  end)

  it("does not register the inner fn from a decl-macro body as a top-level fn", function()
    -- The body of a decl-macro is a template; its inner decls do not exist
    -- as part of the program until a call site instantiates them (stage 3).
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
decl-macro counter:
  fn inside-the-macro:
    pass
scene main:
  the end
]]
    local gt, _ = compiler.compile(src, "test.sb")
    assert.is_not_nil(gt)
    assert.is_nil(gt.fns and gt.fns["inside-the-macro"])
  end)
end)

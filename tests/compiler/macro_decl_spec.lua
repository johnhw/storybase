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

-- ── Lexer — $param + composite identifiers (E0 Stage 2) ──────────────────────

describe("lexer — $param tokens (E0 Stage 2)", function()
  local function tokens_of(src)
    local toks, diags = lexer.tokenize(src, "test")
    return toks, diags
  end

  local function errs_of(diags)
    local out = {}
    for _, d in ipairs(diags) do
      if d.level == "error" then table.insert(out, d) end
    end
    return out
  end

  it("emits MACRO_PARAM for bare '$path'", function()
    local toks = tokens_of("$path\n")
    assert.equal("MACRO_PARAM", toks[1].kind)
    assert.equal("path", toks[1].value)
  end)

  it("emits COMPOSITE_IDENT for 'give-$path' with parts [\"give-\", {macro_param, \"path\"}]", function()
    local toks = tokens_of("give-$path\n")
    assert.equal("COMPOSITE_IDENT", toks[1].kind)
    local parts = toks[1].value
    assert.equal(2, #parts)
    assert.equal("give-", parts[1])
    assert.equal("table", type(parts[2]))
    assert.equal("macro_param", parts[2].kind)
    assert.equal("path", parts[2].name)
  end)

  it("emits COMPOSITE_IDENT for '$path-init' with parts [{macro_param, \"path\"}, \"-init\"]", function()
    local toks = tokens_of("$path-init\n")
    assert.equal("COMPOSITE_IDENT", toks[1].kind)
    local parts = toks[1].value
    assert.equal(2, #parts)
    assert.equal("table", type(parts[1]))
    assert.equal("macro_param", parts[1].kind)
    assert.equal("path", parts[1].name)
    assert.equal("-init", parts[2])
  end)

  it("emits COMPOSITE_IDENT for '$a-$b' (back-to-back) with three parts", function()
    local toks = tokens_of("$a-$b\n")
    assert.equal("COMPOSITE_IDENT", toks[1].kind)
    local parts = toks[1].value
    assert.equal(3, #parts)
    assert.equal("macro_param", parts[1].kind)
    assert.equal("a", parts[1].name)
    assert.equal("-", parts[2])
    assert.equal("macro_param", parts[3].kind)
    assert.equal("b", parts[3].name)
  end)

  it("emits COMPOSITE_IDENT for 'has-$path?' with trailing '?' folded into the last string part", function()
    local toks = tokens_of("has-$path?\n")
    assert.equal("COMPOSITE_IDENT", toks[1].kind)
    local parts = toks[1].value
    assert.equal(3, #parts)
    assert.equal("has-", parts[1])
    assert.equal("path", parts[2].name)
    assert.equal("?", parts[3])
  end)

  it("emits COMPOSITE_IDENT for 'give-thing-$path' collapsing the literal prefix", function()
    local toks = tokens_of("give-thing-$path\n")
    assert.equal("COMPOSITE_IDENT", toks[1].kind)
    local parts = toks[1].value
    -- Leading "give-thing" is one ident segment, then '-' joining, then param
    assert.equal(2, #parts)
    assert.equal("give-thing-", parts[1])
    assert.equal("path", parts[2].name)
  end)

  it("emits COMPOSITE_IDENT for '$path?' (bare param with trailing predicate marker)", function()
    local toks = tokens_of("$path?\n")
    assert.equal("COMPOSITE_IDENT", toks[1].kind)
    local parts = toks[1].value
    assert.equal(2, #parts)
    assert.equal("path", parts[1].name)
    assert.equal("?", parts[2])
  end)

  it("leaves plain 'give' as an IDENT (no composite)", function()
    local toks = tokens_of("give\n")
    assert.equal("IDENT", toks[1].kind)
    assert.equal("give", toks[1].value)
  end)

  it("leaves plain 'give-thing' as an IDENT (no composite, no $-slot)", function()
    local toks = tokens_of("give-thing\n")
    assert.equal("IDENT", toks[1].kind)
    assert.equal("give-thing", toks[1].value)
  end)

  it("does not merge across whitespace ('give -$path' is three tokens)", function()
    local toks = tokens_of("give -$path\n")
    assert.equal("IDENT", toks[1].kind)
    assert.equal("give", toks[1].value)
    assert.equal("OP", toks[2].kind)
    assert.equal("-", toks[2].value)
    assert.equal("MACRO_PARAM", toks[3].kind)
    assert.equal("path", toks[3].value)
  end)

  it("does not merge across whitespace ('$a -$b' is three tokens)", function()
    local toks = tokens_of("$a -$b\n")
    assert.equal("MACRO_PARAM", toks[1].kind)
    assert.equal("a", toks[1].value)
    assert.equal("OP", toks[2].kind)
    assert.equal("-", toks[2].value)
    assert.equal("MACRO_PARAM", toks[3].kind)
    assert.equal("b", toks[3].value)
  end)

  it("raises ILLEGAL_CHAR for bare '$' with no following identifier", function()
    local _, diags = tokens_of("$ 42\n")
    local errs = errs_of(diags)
    assert.is_true(#errs >= 1)
    assert.equal("ILLEGAL_CHAR", errs[1].code)
  end)

  it("keeps lexing after a bare '$' error (recovers to find the next token)", function()
    local toks, _ = tokens_of("$ 42\n")
    local found_int = false
    for _, t in ipairs(toks) do
      if t.kind == "INTEGER" then found_int = true end
    end
    assert.is_true(found_int)
  end)

  it("records source position on the COMPOSITE_IDENT token", function()
    local toks = tokens_of("\n\ngive-$path\n")
    assert.equal("COMPOSITE_IDENT", toks[1].kind)
    assert.equal(3, toks[1].pos.line)
    assert.equal(1, toks[1].pos.col)
  end)

  it("records source position on the MACRO_PARAM token", function()
    local toks = tokens_of("\n  $path\n")
    -- INDENT then MACRO_PARAM
    assert.equal("INDENT", toks[1].kind)
    assert.equal("MACRO_PARAM", toks[2].kind)
    assert.equal(2, toks[2].pos.line)
    assert.equal(3, toks[2].pos.col)
  end)

  it("does not treat $-slot specially across '/' boundaries (path scanner stops)", function()
    -- Path lexing with embedded $-slots is deferred (Stage 3 territory).
    -- For now `npcs/$kind` lexes as IDENT '/' MACRO_PARAM.
    local toks = tokens_of("npcs/$kind\n")
    assert.equal("IDENT", toks[1].kind)
    assert.equal("npcs", toks[1].value)
    assert.equal("OP", toks[2].kind)
    assert.equal("/", toks[2].value)
    assert.equal("MACRO_PARAM", toks[3].kind)
    assert.equal("kind", toks[3].value)
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

-- ── Parser — Stage 2b: name_parts on decl names ───────────────────────────────

describe("parser — Stage 2b (decl-macro name interpolation slots)", function()
  it("accepts MACRO_PARAM in fn-decl name and stores name_parts", function()
    local src = [[
decl-macro mk:
  fn $thing:
    pass
]]
    local tree, _ = parse(src)
    assert.equal(0, #parse_errors(src))
    local m = find_decl(tree, ast.K.DECL_MACRO_DECL, "mk")
    assert.is_not_nil(m)
    local fn = m.body[1]
    assert.equal(ast.K.FN_DECL, fn.kind)
    assert.is_not_nil(fn.name_parts)
    assert.equal(1, #fn.name_parts)
    assert.equal("macro_param", fn.name_parts[1].kind)
    assert.equal("thing", fn.name_parts[1].name)
  end)

  it("accepts COMPOSITE_IDENT in fn-decl name and preserves the parts list", function()
    local src = [[
decl-macro mk:
  fn $path-inc:
    pass
]]
    local tree, _ = parse(src)
    assert.equal(0, #parse_errors(src))
    local m = find_decl(tree, ast.K.DECL_MACRO_DECL, "mk")
    assert.is_not_nil(m)
    local fn = m.body[1]
    assert.equal(ast.K.FN_DECL, fn.kind)
    assert.is_not_nil(fn.name_parts)
    assert.equal(2, #fn.name_parts)
    assert.equal("path", fn.name_parts[1].name)
    assert.equal("-inc", fn.name_parts[2])
  end)

  it("uses a $-bearing placeholder string for the legacy fn.name field", function()
    local src = [[
decl-macro mk:
  fn $path-inc:
    pass
]]
    local tree, _ = parse(src)
    local m = find_decl(tree, ast.K.DECL_MACRO_DECL, "mk")
    local fn = m.body[1]
    assert.equal("$path-inc", fn.name)
  end)

  it("accepts MACRO_PARAM in state-decl path position", function()
    local src = [[
decl-macro mk:
  state $foo: Int(0, 10) = 0
]]
    local tree, _ = parse(src)
    assert.equal(0, #parse_errors(src))
    local m = find_decl(tree, ast.K.DECL_MACRO_DECL, "mk")
    local st = m.body[1]
    assert.equal(ast.K.STATE_SCALAR, st.kind)
    assert.equal(ast.K.PATH_EXPR, st.path.kind)
    -- The single segment is a macro_param placeholder
    assert.equal("table", type(st.path.segments[1]))
    assert.equal("macro_param", st.path.segments[1].kind)
    assert.equal("foo", st.path.segments[1].name)
  end)

  it("accepts MACRO_PARAM as mutation target (inc! $path 1)", function()
    local src = [[
decl-macro mk:
  fn touch:
    inc! $path 1
]]
    local tree, _ = parse(src)
    assert.equal(0, #parse_errors(src))
    local m = find_decl(tree, ast.K.DECL_MACRO_DECL, "mk")
    local fn = m.body[1]
    local stmt = fn.body[1]
    assert.equal(ast.K.INC_MUT, stmt.kind)
    assert.equal(ast.K.PATH_EXPR, stmt.path.kind)
    assert.equal("macro_param", stmt.path.segments[1].kind)
    assert.equal("path", stmt.path.segments[1].name)
  end)

  it("parses a top-level macro-call decl with one argument", function()
    local src = [[
decl-macro mk:
  fn noop:
    pass
mk player-health
]]
    local tree, _ = parse(src)
    assert.equal(0, #parse_errors(src))
    local call
    for _, d in ipairs(tree.decls) do
      if d.kind == ast.K.MACRO_CALL_DECL then call = d; break end
    end
    assert.is_not_nil(call)
    assert.equal("mk", call.name)
    assert.equal(1, #call.args)
  end)
end)

-- ── Stage 3 — decl-level expansion ───────────────────────────────────────────

describe("compile — Stage 3 decl-macro expansion", function()
  local function compile_ok(src)
    local gt, diags = compiler.compile(src, "test.sb")
    local errs = (diags and diags.errors) or {}
    if #errs > 0 then
      for _, e in ipairs(errs) do
        print("ERR", e.code, e.message, e.line)
      end
    end
    return gt, errs
  end

  local function has_state_path(gt, path)
    for _, st in ipairs(gt.schema.states or {}) do
      if st.path == path then return true end
    end
    return false
  end

  it("expands a zero-arg decl-macro at a call site", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
decl-macro counter:
  state world/count: Int(0, 100) = 0
  fn count-inc:
    inc! world/count 1
counter
scene main:
  the end
]]
    local gt, errs = compile_ok(src)
    assert.equal(0, #errs)
    assert.is_not_nil(gt)
    -- The state path emitted by the macro should now be present
    assert.is_true(has_state_path(gt, "world/count"))
    -- The fn emitted by the macro should be registered
    assert.is_not_nil(gt.fns["count-inc"])
  end)

  it("substitutes a $path macro param into a state path", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
decl-macro counter $path:
  state $path: Int(0, 100) = 0
counter player-health
scene main:
  the end
]]
    local gt, errs = compile_ok(src)
    assert.equal(0, #errs)
    assert.is_not_nil(gt)
    -- The expanded state path is "player-health" (the macro's $path slot)
    assert.is_true(has_state_path(gt, "player-health"))
  end)

  it("substitutes a $path macro param into a composite fn name", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
decl-macro counter $path:
  state $path: Int(0, 100) = 0
  fn $path-inc:
    inc! $path 1
counter player-health
scene main:
  the end
]]
    local gt, errs = compile_ok(src)
    assert.equal(0, #errs)
    assert.is_not_nil(gt)
    -- The composite ident `$path-inc` becomes `player-health-inc`
    assert.is_not_nil(gt.fns["player-health-inc"])
    -- The inc! body inside it should target the expanded path
    -- (we can't easily introspect body here without re-checking AST shape,
    --  but the fact that it compiles + runs proves substitution worked)
  end)

  it("expands two call sites with different params without collision", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
decl-macro counter $path:
  state $path: Int(0, 100) = 0
  fn $path-inc:
    inc! $path 1
counter player-health
counter monster-rage
scene main:
  the end
]]
    local gt, errs = compile_ok(src)
    assert.equal(0, #errs)
    assert.is_not_nil(gt)
    assert.is_true(has_state_path(gt, "player-health"))
    assert.is_true(has_state_path(gt, "monster-rage"))
    assert.is_not_nil(gt.fns["player-health-inc"])
    assert.is_not_nil(gt.fns["monster-rage-inc"])
  end)

  it("expanded fn body actually mutates the substituted path at runtime", function()
    local engine = require("runtime.engine")
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
decl-macro counter $path:
  state $path: Int(0, 100) = 0
  fn $path-inc:
    inc! $path 1
counter player-health
scene main:
  -> main
]]
    local gt, errs = compile_ok(src)
    assert.equal(0, #errs)
    assert.is_not_nil(gt)
    local eng = engine.new(gt, {})
    eng:init()
    assert.equal(0, eng._state:get("player-health"))
    -- Invoke the expanded function and verify the state moves
    local eval = require("runtime.eval")
    local ctx  = eng:make_ctx("player-health-inc")
    eval.call_fn("player-health-inc", {}, ctx)
    assert.equal(1, eng._state:get("player-health"))
  end)

  it("reports UNDEFINED_NAME when a call site references no decl-macro", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
no-such-macro foo
scene main:
  the end
]]
    local _, diags = compiler.compile(src, "test.sb")
    local errs = (diags and diags.errors) or {}
    assert.is_true(#errs >= 1)
    local found
    for _, e in ipairs(errs) do
      if e.code == "UNDEFINED_NAME" then found = e; break end
    end
    assert.is_not_nil(found)
  end)

  it("reports MACRO_DECL_EMIT when arg count mismatches param count", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
decl-macro counter $path:
  state $path: Int(0, 100) = 0
counter
scene main:
  the end
]]
    local _, diags = compiler.compile(src, "test.sb")
    local errs = (diags and diags.errors) or {}
    local found
    for _, e in ipairs(errs) do
      if e.code == "MACRO_DECL_EMIT" then found = e; break end
    end
    assert.is_not_nil(found)
  end)

  it("reports MACRO_DECL_EMIT when substituting multi-segment path into composite name", function()
    -- `counter player/health` substitutes $path with PATH_EXPR{"player","health"}.
    -- That's fine for `state $path:` (multi-segment path) but `$path-inc` is a
    -- composite fn name — the substitution would yield "player/health-inc"
    -- which is not a legal identifier; we must reject.
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
decl-macro counter $path:
  state $path: Int(0, 100) = 0
  fn $path-inc:
    inc! $path 1
counter player/health
scene main:
  the end
]]
    local _, diags = compiler.compile(src, "test.sb")
    local errs = (diags and diags.errors) or {}
    local found
    for _, e in ipairs(errs) do
      if e.code == "MACRO_DECL_EMIT" then found = e; break end
    end
    assert.is_not_nil(found)
  end)

  it("does not break the existing stmt-level macro system", function()
    -- A program that uses ONLY the legacy stmt-level `macro` should be
    -- unaffected by the new decl-level pass.
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
state world/count: Int(0, 100) = 0
macro count-twice body:
  body
  body
fn tick:
  count-twice:
    inc! world/count 1
scene main:
  the end
]]
    local gt, errs = compile_ok(src)
    assert.equal(0, #errs)
    assert.is_not_nil(gt)
    assert.is_not_nil(gt.fns["tick"])
  end)

  it("call-site pos is propagated onto expanded decls", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
decl-macro counter $path:
  state $path: Int(0, 100) = 0
counter player-health
scene main:
  the end
]]
    local typed, _ = compiler.parse_and_check(src, "test.sb")
    assert.is_not_nil(typed)
    -- Find the expanded state decl and check its pos points at the call line.
    -- The call is on the 7th line of the source; the state decl in the macro
    -- body is on line 6. After Stage 4-style pos stamping, the emitted decl
    -- must carry the call-site position.
    local found
    for _, d in ipairs(typed.decls) do
      if d.kind == ast.K.STATE_SCALAR
         and d.path and d.path.segments
         and d.path.segments[1] == "player-health" then
        found = d; break
      end
    end
    assert.is_not_nil(found)
    assert.equal(7, found.pos.line)
    -- And we preserve the macro-body source position for error notes.
    assert.is_not_nil(found.expanded_from)
    assert.equal(6, found.expanded_from.line)
  end)
end)

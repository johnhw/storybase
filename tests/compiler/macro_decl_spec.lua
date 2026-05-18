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

-- ── §E0 Stage 4: checker diagnostics on expanded nodes ───────────────────────

describe("compile — Stage 4 expanded_from diag decoration", function()
  local function compile_errs(src)
    local _, diags = compiler.compile(src, "test.sb")
    return (diags and diags.errors) or {}
  end

  local function find_err(errs, code)
    for _, e in ipairs(errs) do
      if e.code == code then return e end
    end
    return nil
  end

  it("checker UNDEFINED_TYPE in expanded decl points at the call site", function()
    -- `BadType` is not declared. The expanded `state $path: BadType = 0`
    -- triggers UNDEFINED_TYPE during type resolution. Its pos should be
    -- stamped to the call-site line (line 8), not the macro body (line 6).
    local src = table.concat({
      "module test",                       -- 1
      "  version: 1.0",                    -- 2
      "engine-config:",                    -- 3
      "  entry-scene: main",               -- 4
      "decl-macro counter $path:",         -- 5
      "  state $path: BadType = 0",        -- 6
      "",                                  -- 7
      "counter player-health",             -- 8
      "scene main:",                       -- 9
      "  the end",                         -- 10
    }, "\n") .. "\n"

    local errs = compile_errs(src)
    local e = find_err(errs, "UNDEFINED_TYPE")
    assert.is_not_nil(e)
    assert.equal(8, e.line)
  end)

  it("checker diag on expanded node has 'expanded from macro' note", function()
    local src = table.concat({
      "module test",
      "  version: 1.0",
      "engine-config:",
      "  entry-scene: main",
      "decl-macro counter $path:",
      "  state $path: BadType = 0",
      "",
      "counter player-health",
      "scene main:",
      "  the end",
    }, "\n") .. "\n"

    local errs = compile_errs(src)
    local e = find_err(errs, "UNDEFINED_TYPE")
    assert.is_not_nil(e)
    assert.is_not_nil(e.note)
    -- The note must mention the macro by name and point at its definition line.
    assert.is_truthy(e.note:match("expanded from macro 'counter'"))
    assert.is_truthy(e.note:match("test%.sb:5"))
  end)

  it("DUPLICATE_NAME on a clashing expansion points at the second call", function()
    -- Two macro calls expand to the same state path → the second one is
    -- the duplicate. Its diagnostic should point at the second call site,
    -- and the note should contain *both* the original "previous declaration"
    -- text and the "expanded from" decoration.
    local src = table.concat({
      "module test",                         -- 1
      "  version: 1.0",                      -- 2
      "engine-config:",                      -- 3
      "  entry-scene: main",                 -- 4
      "decl-macro counter $path:",           -- 5
      "  state $path: Int(0, 100) = 0",      -- 6
      "",                                    -- 7
      "counter player-health",               -- 8
      "counter player-health",               -- 9  ← duplicate call
      "scene main:",                         -- 10
      "  the end",                           -- 11
    }, "\n") .. "\n"

    local errs = compile_errs(src)
    local e = find_err(errs, "DUPLICATE_NAME")
    assert.is_not_nil(e)
    -- Points at the *second* call site.
    assert.equal(9, e.line)
    assert.is_not_nil(e.note)
    assert.is_truthy(e.note:match("previous declaration"))
    assert.is_truthy(e.note:match("expanded from macro 'counter'"))
  end)

  it("clean expansion produces no expanded_from note on unrelated diagnostics", function()
    -- A program that fully type-checks should have no errors; if any
    -- warnings are emitted from non-expanded nodes, they must not carry
    -- a spurious `expanded from` note.
    local src = table.concat({
      "module test",
      "  version: 1.0",
      "engine-config:",
      "  entry-scene: main",
      "decl-macro counter $path:",
      "  state $path: Int(0, 100) = 0",
      "",
      "counter player-health",
      "scene main:",
      "  the end",
    }, "\n") .. "\n"

    local _, diags = compiler.compile(src, "test.sb")
    local all = (diags and diags.errors) or {}
    for _, w in ipairs((diags and diags.warnings) or {}) do
      all[#all + 1] = w
    end
    for _, d in ipairs(all) do
      if d.note then
        assert.is_falsy(d.note:match("expanded from macro"))
      end
    end
  end)

  it("legacy stmt-level macro errors carry no 'expanded from' note", function()
    -- Regression guard: only decl-level expansion sets expanded_from on
    -- pos tables. The old MACRO_CALL_STMT path does not (yet) get this
    -- decoration — confirm no leakage.
    local src = table.concat({
      "module test",                                -- 1
      "  version: 1.0",                             -- 2
      "engine-config:",                             -- 3
      "  entry-scene: main",                        -- 4
      "state world/count: Int(0, 100) = 0",         -- 5
      "macro count-twice body:",                    -- 6
      "  body",                                     -- 7
      "  body",                                     -- 8
      "fn tick:",                                   -- 9
      "  inc! BadPath 1",                           -- 10  ← bad ident
      "  count-twice:",                             -- 11
      "    inc! world/count 1",                     -- 12
      "scene main:",                                -- 13
      "  the end",                                  -- 14
    }, "\n") .. "\n"

    local _, diags = compiler.compile(src, "test.sb")
    local all = (diags and diags.errors) or {}
    for _, w in ipairs((diags and diags.warnings) or {}) do
      all[#all + 1] = w
    end
    -- Whatever the legacy macro emits, no diagnostic should claim it was
    -- "expanded from macro 'count-twice'"-style (that's strictly Stage 4
    -- decoration, which is scoped to decl-level expansion).
    for _, d in ipairs(all) do
      if d.note then
        assert.is_falsy(d.note:match("expanded from macro 'count%-twice'"))
      end
    end
  end)

  it("format_expanded_from helper produces the documented string", function()
    local s = ast.format_expanded_from({
      macro_name = "counter",
      macro_pos  = ast.pos("foo.sb", 42, 1),
    })
    assert.equal("expanded from macro 'counter' at foo.sb:42", s)
  end)

  it("format_expanded_from helper tolerates missing fields", function()
    assert.is_nil(ast.format_expanded_from(nil))
    -- Missing macro_pos → "?" file, line 0
    local s = ast.format_expanded_from({ macro_name = "x" })
    assert.is_truthy(s:match("expanded from macro 'x' at %?:0"))
  end)
end)

-- ── §E0 Stage 5: cross-import wiring ─────────────────────────────────────────
--
-- A `decl-macro` declared in an imported module can be called from the
-- importing file: unaliased (plain `import "..."`), namespaced
-- (`import "..." as Foo`), or via the `@stdlib/...` resolver.  Diagnostics
-- on the expanded decls still point at the call site in the *importing*
-- file (call-site pos stamping is preserved across files).

describe("E0 Stage 5 — cross-import decl-macro", function()
  local engine = require("runtime.engine")
  local eval   = require("runtime.eval")

  -- Write source to a temp .sb file; caller is responsible for os.remove.
  local function tmpfile(src)
    local path = os.tmpname() .. ".sb"
    local f = io.open(path, "w"); f:write(src); f:close()
    return path
  end

  -- Same dir for both files so the relative import in `main` reaches `lib`.
  local function tmp_pair(lib_src, main_src_fmt)
    local lib  = tmpfile(lib_src)
    local main = tmpfile(string.format(main_src_fmt, lib))
    return lib, main
  end

  it("plain import: imported decl-macro is callable in the importing file", function()
    local lib, main = tmp_pair([[
module counter-lib
  version: 1.0
decl-macro counter $path:
  state $path: Int(0, 100) = 0
  fn $path-inc:
    inc! $path 1
]], [[
module counter-main
  version: 1.0
engine-config:
  entry-scene: s

import %q

counter player-health

scene s:
  -> s
]])
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt,
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    -- State path emitted by the macro must exist
    local found = false
    for _, s in ipairs(gt.schema and gt.schema.states or {}) do
      if s.path == "player-health" then found = true end
    end
    assert.is_true(found, "expected state 'player-health' emitted by imported decl-macro")
    -- And the composite fn name
    assert.is_not_nil(gt.fns and gt.fns["player-health-inc"])
  end)

  it("plain import: expanded fn runs and mutates the state at runtime", function()
    local lib, main = tmp_pair([[
module counter-lib
  version: 1.0
decl-macro counter $path:
  state $path: Int(0, 100) = 0
  fn $path-inc:
    inc! $path 1
]], [[
module counter-main
  version: 1.0
engine-config:
  entry-scene: s

import %q

counter player-health

scene s:
  -> s
]])
    local gt = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt)
    local eng = engine.new(gt, {})
    eng:init()
    assert.equal(0, eng._state:get("player-health"))
    local ctx = eng:make_ctx("player-health-inc")
    eval.call_fn("player-health-inc", {}, ctx)
    assert.equal(1, eng._state:get("player-health"))
  end)

  it("namespaced import: imported decl-macro callable as Alias.name", function()
    local lib, main = tmp_pair([[
module counter-lib
  version: 1.0
decl-macro counter $path:
  state $path: Int(0, 100) = 0
  fn $path-inc:
    inc! $path 1
]], [[
module counter-main
  version: 1.0
engine-config:
  entry-scene: s

import %q as C

C.counter player-health

scene s:
  -> s
]])
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt,
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    -- State paths remain global even under namespaced import
    local found = false
    for _, s in ipairs(gt.schema and gt.schema.states or {}) do
      if s.path == "player-health" then found = true end
    end
    assert.is_true(found, "expected state 'player-health' from C.counter")
    -- Fn names emitted from the macro body are *unqualified* — the
    -- macro body's `fn $path-inc:` resolves before namespace rename
    -- would apply (rename is on the imported module's own decls, not
    -- on the substituted output of its decl-macro).
    assert.is_not_nil(gt.fns and gt.fns["player-health-inc"])
  end)

  it("two different aliased imports of the same decl-macro do not conflict", function()
    local lib = tmpfile([[
module counter-lib
  version: 1.0
decl-macro counter $path:
  state $path: Int(0, 100) = 0
]])
    local main = tmpfile(string.format([[
module counter-main
  version: 1.0
engine-config:
  entry-scene: s

import %q as A
import %q as B

A.counter player-health
B.counter monster-rage

scene s:
  -> s
]], lib, lib))
    local gt, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_not_nil(gt,
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    local paths = {}
    for _, s in ipairs(gt.schema and gt.schema.states or {}) do
      paths[s.path] = true
    end
    assert.is_true(paths["player-health"])
    assert.is_true(paths["monster-rage"])
  end)

  it("exports: filter allows whitelisting a decl-macro", function()
    -- `counter` is exported, `secret` is not.  The main file may only call
    -- `counter`; calling `secret` produces UNDEFINED_NAME.
    local lib = tmpfile([[
module exp-lib
  version: 1.0
  exports: [counter]

decl-macro counter $path:
  state $path: Int(0, 100) = 0

decl-macro secret $path:
  state $path: Int(0, 100) = 0
]])
    -- Positive case: `counter` is whitelisted and works.
    local main_ok = tmpfile(string.format([[
module exp-ok
  version: 1.0
engine-config:
  entry-scene: s

import %q

counter player-health

scene s:
  -> s
]], lib))
    local gt, diags = compiler.compile_file(main_ok)
    os.remove(main_ok)
    assert.is_not_nil(gt,
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())

    -- Negative case: `secret` is filtered out → call site fails.
    local main_bad = tmpfile(string.format([[
module exp-bad
  version: 1.0
engine-config:
  entry-scene: s

import %q

secret monster-rage

scene s:
  -> s
]], lib))
    local _, diags2 = compiler.compile_file(main_bad)
    os.remove(lib); os.remove(main_bad)
    assert.is_true(diags2:has_errors())
    local found
    for _, e in ipairs(diags2.errors or {}) do
      if e.code == "UNDEFINED_NAME" then found = e end
    end
    assert.is_not_nil(found, "expected UNDEFINED_NAME for filtered-out 'secret'")
  end)

  it("checker errors on expanded decl from imported macro point at call site", function()
    local lib, main = tmp_pair([[
module bad-counter-lib
  version: 1.0
decl-macro counter $path:
  state $path: BadType = 0
]], [[
module bad-counter-main
  version: 1.0
engine-config:
  entry-scene: s

import %q

counter player-health

scene s:
  -> s
]])
    local _, diags = compiler.compile_file(main)
    -- Capture filenames before deletion for assertions
    local main_basename = main
    os.remove(lib); os.remove(main)
    assert.is_true(diags:has_errors())
    local e
    for _, x in ipairs(diags.errors or {}) do
      if x.code == "UNDEFINED_TYPE" then e = x end
    end
    assert.is_not_nil(e, "expected UNDEFINED_TYPE on expanded decl")
    -- The diagnostic must be stamped at the call site (line 8 of the main
    -- file, which is the `counter player-health` line).
    assert.equal(8, e.line)
    -- And it must originate in the main file, not the lib.
    assert.equal(main_basename, e.file)
    -- The "expanded from macro" note carries the lib's file/line.
    assert.is_not_nil(e.note)
    assert.is_truthy(e.note:match("expanded from macro 'counter'"))
  end)

  it("@stdlib/ resolver respects the override hook (fixture stdlib)", function()
    -- Build an isolated fixture directory and a `counter.sb` inside it,
    -- then point compiler._stdlib_dir_override at that dir.  We use a
    -- *different* macro shape so we can confirm the resolver picked the
    -- fixture (not the shipped stdlib/counter.sb).
    local tmpdir = os.tmpname()
    os.remove(tmpdir)
    os.execute('mkdir -p "' .. tmpdir .. '"')
    local fixture_path = tmpdir .. "/counter.sb"
    local f = io.open(fixture_path, "w")
    f:write([[
module counter-lib
  version: 1.0
decl-macro counter $path:
  state $path: Int(0, 50) = 7
]])
    f:close()

    local prev = compiler._stdlib_dir_override
    compiler._stdlib_dir_override = tmpdir

    local main = tmpfile([[
module counter-main
  version: 1.0
engine-config:
  entry-scene: s

import "@stdlib/counter"

counter player-health

scene s:
  -> s
]])
    local gt, diags = compiler.compile_file(main)
    os.remove(main)
    os.remove(fixture_path)
    os.execute('rmdir "' .. tmpdir .. '"')

    compiler._stdlib_dir_override = prev

    assert.is_not_nil(gt,
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    -- Confirm the *fixture* macro was used: its state initialises to 7
    -- (shipped stdlib/counter.sb initialises to 0).
    local eng = engine.new(gt, {})
    eng:init()
    assert.equal(7, eng._state:get("player-health"))
  end)

  it("@stdlib/ resolver falls back to <repo>/stdlib/ when no override is set", function()
    -- Confirm the shipped stdlib/counter.sb resolves cleanly without any
    -- override.  This depends on the shipped fixture; if it ever changes
    -- shape (e.g. adds required params), update this test.
    local prev = compiler._stdlib_dir_override
    compiler._stdlib_dir_override = nil

    local main = tmpfile([[
module stdlib-counter-main
  version: 1.0
engine-config:
  entry-scene: s

import "@stdlib/counter"

counter player-score

scene s:
  -> s
]])
    local gt, diags = compiler.compile_file(main)
    os.remove(main)

    compiler._stdlib_dir_override = prev

    assert.is_not_nil(gt,
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    -- Shipped stdlib/counter.sb emits `$path-inc` / `$path-dec` /
    -- `$path-reset` fns; sanity-check that at least one exists.
    assert.is_not_nil(gt.fns and gt.fns["player-score-inc"])
  end)
end)

-- ── §E0 Stage 6: acceptance criteria + single-pass restriction ────────────────
--
-- Stage 6 is mostly docs + code-map; the only new behaviour is the
-- "decl-macro body may not invoke another decl-macro" check. The
-- acceptance criteria themselves are re-stated here as a self-contained
-- triplet so a future reader can verify §E0 against the spec without
-- crawling the per-stage describes above.

describe("E0 Stage 6 — acceptance + single-pass restriction", function()
  local engine = require("runtime.engine")
  local eval   = require("runtime.eval")

  local function tmpfile(src)
    local path = os.tmpname() .. ".sb"
    local f = io.open(path, "w"); f:write(src); f:close()
    return path
  end

  -- Acceptance #1: shipped stdlib/counter.sb emits a working state path,
  --                $path-inc / $path-dec / $path-reset fns, compiles,
  --                type-checks, and runs end-to-end.
  it("acceptance #1: stdlib/counter.sb compiles, type-checks, and runs", function()
    local main = tmpfile([[
module main
  version: 1.0
engine-config:
  entry-scene: s

import "@stdlib/counter"

counter player-health

scene s:
  -> s
]])
    local gt, diags = compiler.compile_file(main)
    os.remove(main)
    assert.is_not_nil(gt,
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())

    -- State + three fns all emitted
    local state_found = false
    for _, s in ipairs(gt.schema and gt.schema.states or {}) do
      if s.path == "player-health" then state_found = true end
    end
    assert.is_true(state_found)
    assert.is_not_nil(gt.fns["player-health-inc"])
    assert.is_not_nil(gt.fns["player-health-dec"])
    assert.is_not_nil(gt.fns["player-health-reset"])

    -- And they actually mutate state when called.
    local eng = engine.new(gt, {})
    eng:init()
    assert.equal(0, eng._state:get("player-health"))
    eval.call_fn("player-health-inc", {}, eng:make_ctx("player-health-inc"))
    assert.equal(1, eng._state:get("player-health"))
    eval.call_fn("player-health-reset", {}, eng:make_ctx("player-health-reset"))
    assert.equal(0, eng._state:get("player-health"))
  end)

  -- Acceptance #2: a checker error on a node emitted by an imported
  --                decl-macro points at the call site (not the macro body)
  --                and carries an "expanded from macro" note.
  it("acceptance #2: checker error on imported decl-macro decl points at call site", function()
    local lib = tmpfile([[
module lib
  version: 1.0
decl-macro broken $path:
  state $path: NotARealType = 0
]])
    local main = tmpfile(string.format([[
module main
  version: 1.0
engine-config:
  entry-scene: s

import %q

broken player-score

scene s:
  -> s
]], lib))
    local _, diags = compiler.compile_file(main)
    os.remove(lib); os.remove(main)
    assert.is_true(diags:has_errors())

    -- Find the UNDEFINED_TYPE diag from the expansion.
    local d
    for _, e in ipairs(diags.errors or {}) do
      if e.code == ast.E.UNDEFINED_TYPE then d = e; break end
    end
    assert.is_not_nil(d, "expected UNDEFINED_TYPE diag")
    -- file must be the importing file (call site), not the lib
    assert.equal(main, d.file)
    assert.is_truthy(d.note and d.note:find("expanded from macro 'broken'", 1, true))
  end)

  -- Acceptance #3: nested decl-macro calls are forbidden, emit
  --                MACRO_DECL_EMIT at the nested call site.
  it("acceptance #3: nested decl-macro call raises MACRO_DECL_EMIT", function()
    local main = tmpfile([[
module main
  version: 1.0
engine-config:
  entry-scene: s

decl-macro inner $p:
  state $p: Int(0, 10) = 0

decl-macro outer $p:
  inner $p

outer player-score

scene s:
  -> s
]])
    local _, diags = compiler.compile_file(main)
    os.remove(main)
    assert.is_true(diags:has_errors())

    local d
    for _, e in ipairs(diags.errors or {}) do
      if e.code == ast.E.MACRO_DECL_EMIT
         and tostring(e.message):find("nested decl-macro", 1, true) then
        d = e; break
      end
    end
    assert.is_not_nil(d, "expected MACRO_DECL_EMIT for nested decl-macro call")
    -- Message should name both the enclosing and the inner macro.
    assert.is_truthy(d.message:find("outer", 1, true))
    assert.is_truthy(d.message:find("inner", 1, true))
  end)

  -- Regression: the stmt-level `macro` keyword still works (no
  -- false-positive nested-call diag for stmt-level macro calls).
  it("regression: stmt-level macro inside a decl-macro body works", function()
    local main = tmpfile([[
module main
  version: 1.0
engine-config:
  entry-scene: s

macro bump amount:
  inc! score amount

decl-macro counter-with-bump $path:
  state $path: Int(0, 100) = 0
  fn $path-bump:
    bump 1

state score: Int(0, 100) = 0
counter-with-bump player-health

scene s:
  -> s
]])
    local gt, diags = compiler.compile_file(main)
    os.remove(main)
    assert.is_not_nil(gt,
      tostring(diags.errors and diags.errors[1] and diags.errors[1].message))
    assert.is_false(diags:has_errors())
    assert.is_not_nil(gt.fns["player-health-bump"])
  end)
end)

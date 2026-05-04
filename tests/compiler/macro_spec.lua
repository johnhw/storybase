-- tests/compiler/macro_spec.lua
-- Tests for the hygienic macro system: parsing, expansion, and error cases.
--
-- NOTE: Macro calls use the code-body (fn body) context for expansion.
-- Scene bodies treat `name:' as narration text, so macro calls must
-- be placed inside fn bodies (or macro bodies themselves).

local compiler = require("compiler.compiler")
local ast      = require("compiler.ast")

-- ── helpers ──────────────────────────────────────────────────────────────────

local BASE = [[
module macro-test
  version: 1.0
engine-config:
  entry-scene: main
state world:
  count: Int(0, 100) = 0
  flag:  Bool = false
]]

local function compile(extra)
  local src = BASE .. extra
  local gt, diags = compiler.compile(src, "macro-test.sb")
  -- diags is an accumulator object: {errors=[...], warnings=[...], all=[...]}
  local errors = diags and diags.errors or {}
  return gt, errors, diags
end

local function has_diag(diags, code)
  for _, d in ipairs(diags and diags.all or {}) do
    if d.code == code then return true end
  end
  return false
end

-- ── parsing ───────────────────────────────────────────────────────────────────

describe("macro — parsing", function()
  it("parses a no-param macro declaration", function()
    local gt, errors = compile([[
macro greet:
  pass
fn do-greet:
  greet:
scene main:
  do-greet()
]])
    assert.equal(0, #errors)
  end)

  it("parses a macro with one named-arg param", function()
    local gt, errors = compile([[
macro log-msg txt:
  pass
fn run:
  log-msg txt: "hello"
scene main:
  run()
]])
    assert.equal(0, #errors)
  end)

  it("parses a macro with a body block param", function()
    local gt, errors = compile([[
macro with-block body:
  pass
  body
fn run:
  with-block:
    pass
scene main:
  run()
]])
    assert.equal(0, #errors)
  end)
end)

-- ── expansion — no-param macro ────────────────────────────────────────────────

describe("macro — no-param expansion", function()
  it("macro with pass expands into fn body", function()
    local gt, errors = compile([[
macro do-nothing:
  pass
fn run:
  do-nothing:
scene main:
  run()
]])
    assert.equal(0, #errors)
    assert.is_not_nil(gt.fns["run"])
  end)

  it("macro with set! expands and fn compiles", function()
    local gt, errors = compile([[
macro reset:
  set! world/count 0
fn run:
  reset:
scene main:
  run()
]])
    assert.equal(0, #errors)
    assert.is_not_nil(gt.fns["run"])
  end)
end)

-- ── expansion — body block splicing ──────────────────────────────────────────

describe("macro — body block splicing", function()
  it("body stmts are spliced at body-param reference", function()
    local gt, errors = compile([[
macro wrap body:
  set! world/count 1
  body
  set! world/count 0
fn run:
  wrap:
    set! world/flag true
scene main:
  run()
]])
    assert.equal(0, #errors)
    assert.is_not_nil(gt.fns["run"])
  end)

  it("macro without body param compiles with bare call form", function()
    local gt, errors = compile([[
macro stamp:
  set! world/flag true
fn run:
  stamp:
scene main:
  run()
]])
    assert.equal(0, #errors)
  end)
end)

-- ── expansion — parameter substitution ───────────────────────────────────────

describe("macro — parameter substitution", function()
  it("named-arg param is substituted in macro body (inc! form)", function()
    local gt, errors = compile([[
macro add-n amount:
  inc! world/count amount
fn run:
  add-n amount: 3
scene main:
  run()
]])
    assert.equal(0, #errors)
    assert.is_not_nil(gt.fns["run"])
  end)

  it("multiple params are all substituted", function()
    local gt, errors = compile([[
macro set-both a b:
  set! world/count a
  set! world/flag  b
fn run:
  set-both a: 5 b: true
scene main:
  run()
]])
    assert.equal(0, #errors)
  end)
end)

-- ── hygiene ───────────────────────────────────────────────────────────────────

describe("macro — hygiene", function()
  it("let-binding in macro gets hygienic prefix (no name collision)", function()
    -- Both the macro and the caller use a let-bound name `tmp'.
    -- Hygiene should prevent collision so the fn compiles cleanly.
    local gt, errors = compile([[
macro safe-inc:
  let tmp = world/count + 1:
    set! world/count tmp
fn run:
  let tmp = 42:
    set! world/count tmp
  safe-inc:
scene main:
  run()
]])
    assert.equal(0, #errors)
  end)
end)

-- ── expansion in nested fn bodies ────────────────────────────────────────────

describe("macro — expansion in fn bodies", function()
  it("macro call inside fn body expands correctly", function()
    local gt, errors = compile([[
macro bump:
  inc! world/count 1
fn advance:
  bump:
scene main:
  advance()
]])
    assert.equal(0, #errors)
    assert.is_not_nil(gt.fns["advance"])
  end)
end)

-- ── error cases ───────────────────────────────────────────────────────────────

describe("macro — error: undefined macro", function()
  it("calling an undefined macro (body-block form) in fn is a compile error", function()
    local _, errs = compile([[
fn run:
  no-such-macro:
    Some stmt.
scene main:
  run()
]])
    -- The expander emits UNDEFINED_NAME for `no-such-macro' in the fn body.
    assert.is_true(#errs > 0, "expected compile error for undefined macro")
  end)
end)

describe("macro — error: recursive invocation", function()
  it("direct recursive macro invocation is a compile error", function()
    -- `loop-forever' calls itself with a body block → MACRO_CALL_STMT in body
    -- When expanded from a fn, walk_and_expand detects the cycle.
    local src = BASE .. [[
macro loop-forever body:
  loop-forever:
    body
fn run:
  loop-forever:
    pass
scene main:
  run()
]]
    local _, diags = compiler.compile(src, "t.sb")
    assert.is_true(has_diag(diags, ast.E.MACRO_RECURSIVE),
      "expected MACRO_RECURSIVE error")
  end)
end)

describe("macro — error: cross-unit macro expansion", function()
  it("macro body calling another macro with body block is a compile error", function()
    -- `inner' is a macro; `outer' calls `inner' with a body block → MACRO_CALL_STMT
    -- The cross-unit check fires at collect time (before expansion).
    local src = BASE .. [[
macro inner body:
  set! world/count 1
  body
macro outer body:
  inner:
    body
scene main:
  pass
]]
    local _, diags = compiler.compile(src, "t.sb")
    assert.is_true(has_diag(diags, ast.E.MACRO_CROSS_UNIT),
      "expected MACRO_CROSS_UNIT error")
  end)
end)

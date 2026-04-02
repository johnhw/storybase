-- tests/runtime/eval_spec.lua
-- Unit tests for runtime/eval.lua
--
-- Run with:  busted tests/

local eval      = require("runtime.eval")
local state_mod = require("runtime.state")
local log_mod   = require("runtime.log")

-- ============================================================
-- Helpers
-- ============================================================

local function make_store(vals)
  local l = log_mod.new()
  local s = state_mod.new({types={}, states={}}, l)
  for k, v in pairs(vals or {}) do
    s:set(k, v)
  end
  return s
end

local function ctx(vals, fns)
  local s = make_store(vals)
  return eval.new_ctx(s, fns or {}, "test")
end

-- AST node shorthands
local function bool_lit(v)   return { kind="bool_lit",   value=v } end
local function int_lit(n)    return { kind="int_lit",    value=n } end
local function sym_lit(n)    return { kind="symbol_lit", name=n  } end
local function str_lit(s)    return { kind="string_lit", value=s } end
local function path(...)
  return { kind="path_expr", segments={...} }
end
local function interp_path(...)
  return { kind="interp_path", segments={...} }
end
local function binop(op, l, r) return { kind="binary_op", op=op, left=l, right=r } end
local function unop(op, e)     return { kind="unary_op",  op=op, expr=e } end
local function fn_call(name, ...) return { kind="fn_call", name=name, args={...} } end
local function if_expr(cond, tb, eb) return { kind="if_expr", condition=cond, then_body=tb, else_body=eb } end

local function set_mut(p, v)     return { kind="set_mut",  path=path(table.unpack(p)), value=v } end
local function inc_mut(p, v)     return { kind="inc_mut",  path=path(table.unpack(p)), amount=v } end
local function dec_mut(p, v)     return { kind="dec_mut",  path=path(table.unpack(p)), amount=v } end
local function when_stmt(c, b)   return { kind="when_stmt", condition=c, body=b } end

-- ============================================================
-- Expression evaluation
-- ============================================================

describe("eval_expr: literals", function()
  it("bool_lit true", function()
    assert.is_true(eval.eval_expr(bool_lit(true), ctx()))
  end)

  it("bool_lit false", function()
    assert.is_false(eval.eval_expr(bool_lit(false), ctx()))
  end)

  it("int_lit", function()
    assert.equal(42, eval.eval_expr(int_lit(42), ctx()))
  end)

  it("symbol_lit", function()
    assert.equal("alive", eval.eval_expr(sym_lit("alive"), ctx()))
  end)

  it("string_lit", function()
    assert.equal("hello", eval.eval_expr(str_lit("hello"), ctx()))
  end)
end)

describe("eval_expr: path read", function()
  it("path_expr reads from state", function()
    local c = ctx({ ["player/health"] = 42 })
    assert.equal(42, eval.eval_expr(path("player", "health"), c))
  end)

  it("single-segment path checks vars first", function()
    local c = ctx({})
    c.vars["x"] = 99
    assert.equal(99, eval.eval_expr(path("x"), c))
  end)

  it("interp_path substitutes var", function()
    local c = ctx({ ["party/fighter/health"] = 80 })
    c.vars["m"] = "fighter"
    local node = interp_path("party", {interp="m"}, "health")
    assert.equal(80, eval.eval_expr(node, c))
  end)
end)

describe("eval_expr: binary operators", function()
  it("= equality true", function()
    assert.is_true(eval.eval_expr(binop("=", int_lit(5), int_lit(5)), ctx()))
  end)

  it("= equality false", function()
    assert.is_false(eval.eval_expr(binop("=", int_lit(5), int_lit(6)), ctx()))
  end)

  it("!= inequality", function()
    assert.is_true(eval.eval_expr(binop("!=", int_lit(1), int_lit(2)), ctx()))
  end)

  it("> greater than", function()
    assert.is_true(eval.eval_expr(binop(">", int_lit(5), int_lit(3)), ctx()))
  end)

  it("< less than", function()
    assert.is_false(eval.eval_expr(binop("<", int_lit(5), int_lit(3)), ctx()))
  end)

  it(">= greater or equal", function()
    assert.is_true(eval.eval_expr(binop(">=", int_lit(5), int_lit(5)), ctx()))
  end)

  it("<= less or equal", function()
    assert.is_true(eval.eval_expr(binop("<=", int_lit(3), int_lit(5)), ctx()))
  end)

  it("+ addition", function()
    assert.equal(7, eval.eval_expr(binop("+", int_lit(3), int_lit(4)), ctx()))
  end)

  it("- subtraction", function()
    assert.equal(1, eval.eval_expr(binop("-", int_lit(4), int_lit(3)), ctx()))
  end)

  it("* multiplication", function()
    assert.equal(12, eval.eval_expr(binop("*", int_lit(3), int_lit(4)), ctx()))
  end)

  it("and: true and true", function()
    assert.is_true(eval.eval_expr(binop("and", bool_lit(true), bool_lit(true)), ctx()))
  end)

  it("and: true and false", function()
    assert.is_false(eval.eval_expr(binop("and", bool_lit(true), bool_lit(false)), ctx()))
  end)

  it("or: false or true", function()
    assert.is_true(eval.eval_expr(binop("or", bool_lit(false), bool_lit(true)), ctx()))
  end)
end)

describe("eval_expr: unary not", function()
  it("not true = false", function()
    assert.is_false(eval.eval_expr(unop("not", bool_lit(true)), ctx()))
  end)

  it("not false = true", function()
    assert.is_true(eval.eval_expr(unop("not", bool_lit(false)), ctx()))
  end)
end)

describe("eval_expr: if_expr", function()
  it("returns then branch when condition true", function()
    -- if true: body-with-set  else: other-body
    -- We verify the side effect of the branch
    local c = ctx({})
    local node = if_expr(
      bool_lit(true),
      { set_mut({"x"}, int_lit(1)) },
      { set_mut({"x"}, int_lit(2)) }
    )
    eval.eval_expr(node, c)
    assert.equal(1, c.state:get("x"))
  end)

  it("returns else branch when condition false", function()
    local c = ctx({})
    local node = if_expr(
      bool_lit(false),
      { set_mut({"x"}, int_lit(1)) },
      { set_mut({"x"}, int_lit(2)) }
    )
    eval.eval_expr(node, c)
    assert.equal(2, c.state:get("x"))
  end)
end)

describe("eval_expr: nil coalesce", function()
  it("returns left if not nil", function()
    local node = { kind="nil_coalesce", left=int_lit(5), right=int_lit(99) }
    assert.equal(5, eval.eval_expr(node, ctx()))
  end)

  it("returns right if left is nil (missing path)", function()
    local node = { kind="nil_coalesce", left=path("missing"), right=int_lit(99) }
    assert.equal(99, eval.eval_expr(node, ctx()))
  end)
end)

-- ============================================================
-- Statement evaluation
-- ============================================================

describe("eval_stmt: set_mut", function()
  it("writes value to state", function()
    local c = ctx({})
    eval.eval_stmt(set_mut({"player", "hp"}, int_lit(42)), c)
    assert.equal(42, c.state:get("player/hp"))
  end)

  it("logs the change", function()
    local l = log_mod.new()
    local s = state_mod.new({types={},states={}}, l)
    local c = eval.new_ctx(s, {}, "fn1")
    eval.eval_stmt(set_mut({"player", "hp"}, int_lit(10)), c)
    assert.equal(1, #l:entries())
    assert.equal("player/hp", l:entries()[1].path)
  end)
end)

describe("eval_stmt: inc_mut / dec_mut", function()
  it("inc increments the value", function()
    local c = ctx({ ["score"] = 10 })
    eval.eval_stmt(inc_mut({"score"}, int_lit(5)), c)
    assert.equal(15, c.state:get("score"))
  end)

  it("dec decrements the value", function()
    local c = ctx({ ["score"] = 10 })
    eval.eval_stmt(dec_mut({"score"}, int_lit(3)), c)
    assert.equal(7, c.state:get("score"))
  end)
end)

describe("eval_stmt: when_stmt", function()
  it("executes body when condition true", function()
    local c = ctx({})
    eval.eval_stmt(when_stmt(bool_lit(true), { set_mut({"x"}, int_lit(1)) }), c)
    assert.equal(1, c.state:get("x"))
  end)

  it("skips body when condition false", function()
    local c = ctx({})
    eval.eval_stmt(when_stmt(bool_lit(false), { set_mut({"x"}, int_lit(1)) }), c)
    assert.is_nil(c.state:get("x"))
  end)
end)

-- ============================================================
-- Scene navigation signals
-- ============================================================

describe("eval_stmt: scene navigation", function()
  it("scene_goto sets signal", function()
    local c = ctx({})
    eval.eval_stmt({ kind="scene_goto", target="room" }, c)
    assert.is_table(c.signal)
    assert.equal("goto", c.signal.type)
    assert.equal("room", c.signal.target)
  end)

  it("scene_enter sets signal", function()
    local c = ctx({})
    eval.eval_stmt({ kind="scene_enter", target="dungeon" }, c)
    assert.equal("enter", c.signal.type)
    assert.equal("dungeon", c.signal.target)
  end)

  it("scene_exit sets signal", function()
    local c = ctx({})
    eval.eval_stmt({ kind="scene_exit" }, c)
    assert.equal("exit", c.signal.type)
  end)

  it("eval_stmts stops after scene_goto signal", function()
    local c = ctx({})
    eval.eval_stmts({
      set_mut({"a"}, int_lit(1)),
      { kind="scene_goto", target="next" },
      set_mut({"b"}, int_lit(2)),  -- should NOT execute
    }, c)
    assert.equal(1, c.state:get("a"))
    assert.is_nil(c.state:get("b"))
  end)
end)

-- ============================================================
-- Function calls
-- ============================================================

describe("eval: fn calls", function()
  it("calls a user-defined function", function()
    local fns = {
      ["double-hp"] = {
        name = "double-hp",
        params = {},
        pre = {},
        post = {},
        body = { inc_mut({"player", "hp"}, path("player", "hp")) },
        is_transaction = true,
      }
    }
    local l = log_mod.new()
    local s = state_mod.new({types={},states={}}, l)
    s:set("player/hp", 10)
    local c = eval.new_ctx(s, fns, "test")
    eval.eval_expr(fn_call("double-hp"), c)
    assert.equal(20, c.state:get("player/hp"))
  end)

  it("pre-condition failure raises error", function()
    local fns = {
      ["safe-fn"] = {
        name = "safe-fn",
        params = {},
        pre = { bool_lit(false) },  -- always fails
        post = {},
        body = {},
        is_transaction = false,
      }
    }
    local c = ctx({}, fns)
    assert.has_error(function()
      eval.eval_expr(fn_call("safe-fn"), c)
    end)
  end)

  it("min() built-in", function()
    assert.equal(3, eval.eval_expr(fn_call("min", int_lit(3), int_lit(7)), ctx()))
  end)

  it("max() built-in", function()
    assert.equal(7, eval.eval_expr(fn_call("max", int_lit(3), int_lit(7)), ctx()))
  end)
end)

-- ============================================================
-- match_expr
-- ============================================================

describe("eval: match_expr", function()
  local function match_expr(subj, arms_tbl)
    -- arms_tbl: list of {pattern_node, body_node}
    local arms = {}
    for _, a in ipairs(arms_tbl) do
      arms[#arms+1] = { kind="match_arm", pattern=a[1], body=a[2] }
    end
    return { kind="match_expr", expr=subj, arms=arms }
  end

  it("matches first matching arm", function()
    local c = ctx({})
    local node = match_expr(sym_lit("b"), {
      { sym_lit("a"), int_lit(1) },
      { sym_lit("b"), int_lit(2) },
      { sym_lit("c"), int_lit(3) },
    })
    assert.equal(2, eval.eval_expr(node, c))
  end)

  it("wildcard arm matches anything", function()
    local c = ctx({})
    local node = match_expr(sym_lit("x"), {
      { sym_lit("a"), int_lit(1) },
      { "_", int_lit(99) },
    })
    assert.equal(99, eval.eval_expr(node, c))
  end)

  it("returns nil when no arm matches", function()
    local c = ctx({})
    local node = match_expr(sym_lit("z"), {
      { sym_lit("a"), int_lit(1) },
    })
    assert.is_nil(eval.eval_expr(node, c))
  end)
end)

-- ============================================================
-- cond_expr
-- ============================================================

describe("eval: cond_expr", function()
  local function cond_expr(arms_tbl)
    local arms = {}
    for _, a in ipairs(arms_tbl) do
      arms[#arms+1] = { kind="cond_arm", condition=a[1], body=a[2] }
    end
    return { kind="cond_expr", arms=arms }
  end

  it("picks first true branch", function()
    local c = ctx({ ["x"] = 5 })
    c.vars["x"] = 5
    local node = cond_expr({
      { binop(">", path("x"), int_lit(10)), int_lit(1) },
      { binop(">", path("x"), int_lit(3)),  int_lit(2) },
      { "_", int_lit(3) },
    })
    assert.equal(2, eval.eval_expr(node, c))
  end)

  it("wildcard branch is fallback", function()
    local c = ctx({})
    local node = cond_expr({
      { bool_lit(false), int_lit(1) },
      { "_", int_lit(42) },
    })
    assert.equal(42, eval.eval_expr(node, c))
  end)
end)

-- ============================================================
-- for_stmt / while_stmt / let_stmt
-- ============================================================

describe("eval_stmt: for_stmt", function()
  it("iterates over a list and accumulates", function()
    local c = ctx({ ["sum"] = 0 })
    -- for x in [1,2,3]: sum = sum + x
    local iter_node = { kind="list_lit", elements={ int_lit(1), int_lit(2), int_lit(3) } }
    local body = { { kind="inc_mut", path=path("sum"), amount=path("x") } }
    local node = { kind="for_stmt", var="x", iter=iter_node, body=body }
    eval.eval_stmt(node, c)
    assert.equal(6, c.state:get("sum"))
  end)
end)

describe("eval_stmt: while_stmt", function()
  it("runs until condition false", function()
    local c = ctx({ ["n"] = 0 })
    -- while n < 5: n = n + 1
    local cond_node = binop("<", path("n"), int_lit(5))
    local body = { { kind="inc_mut", path=path("n"), amount=int_lit(1) } }
    local node = { kind="while_stmt", condition=cond_node, body=body }
    eval.eval_stmt(node, c)
    assert.equal(5, c.state:get("n"))
  end)
end)

describe("eval_stmt: let_stmt", function()
  it("binds value and executes body", function()
    local c = ctx({ ["y"] = 0 })
    -- let x = 10: set y = x
    local binding = { kind="let_binding", name="x", expr=int_lit(10) }
    local body = { set_mut({"y"}, path("x")) }
    local node = { kind="let_stmt", bindings={binding}, body=body }
    eval.eval_stmt(node, c)
    assert.equal(10, c.state:get("y"))
  end)
end)

-- ============================================================
-- render_text
-- ============================================================

describe("eval: render_text", function()
  it("renders plain string segments", function()
    local c = ctx({})
    local text = { "Hello", "world" }
    assert.equal("Hello world", eval.render_text(text, c))
  end)

  it("renders inline_expr", function()
    local c = ctx({ ["player/hp"] = 42 })
    local text = { "HP:", { kind="inline_expr", expr=path("player", "hp") } }
    assert.equal("HP: 42", eval.render_text(text, c))
  end)
end)

-- ============================================================
-- time-inc! via eval
-- ============================================================

describe("eval_stmt: time_inc_mut", function()
  local log_mod   = require("runtime.log")
  local state_mod = require("runtime.state")
  local compiler  = require("compiler.compiler")

  it("advances the engine time clock via time-inc!", function()
    local gt, diags = compiler.compile([[
module t
  version: 1.0
schema-version: 1
time-model:
  axes: [day, tick]
  wrap: [none, none]
fn advance:
  time-inc! tick: 3
scene start:
  .
  * Go
    advance
    -> start
]], "test")
    assert.equal(0, #diags.errors)
    local log   = log_mod.new()
    local store = state_mod.new(gt.schema, log)
    store:init_defaults(gt.schema)
    -- time starts at 0
    assert.equal(0, store:get_time().tick)
    assert.equal(0, store:get_time().day)
    -- call advance fn
    local fn = gt.fns["advance"]
    local c = eval.new_ctx(store, gt.fns, "advance")
    eval.eval_stmts(fn.body, c)
    assert.equal(3, store:get_time().tick)
    assert.equal(0, store:get_time().day)
  end)

  it("wraps time axis at configured wrap value", function()
    local gt, diags = compiler.compile([[
module t
  version: 1.0
schema-version: 1
time-model:
  axes: [hour]
  wrap: [24]
fn tick:
  time-inc! hour: 5
scene start:
  .
  * Go
    tick
    -> start
]], "test")
    assert.equal(0, #diags.errors)
    local log   = log_mod.new()
    local store = state_mod.new(gt.schema, log)
    store:init_defaults(gt.schema)
    store:inc_time("hour", 22)  -- set to 22
    local fn = gt.fns["tick"]
    local c = eval.new_ctx(store, gt.fns, "tick")
    eval.eval_stmts(fn.body, c)
    -- 22 + 5 = 27 → wraps to 3
    assert.equal(3, store:get_time().hour)
  end)
end)

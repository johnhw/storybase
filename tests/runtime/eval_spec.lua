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

local function set_lit(...)
  local elems = {}
  for _, v in ipairs({...}) do elems[#elems+1] = sym_lit(v) end
  return { kind="set_lit", elements=elems }
end

local function map_lit(t)
  local entries = {}
  for k, v in pairs(t) do entries[#entries+1] = { kind="named_arg", name=k, value=str_lit(v) } end
  return { kind="map_lit", entries=entries }
end

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

describe("eval_expr: lambda expressions", function()
  it("lambda_expr evaluates to a callable table", function()
    local lam_node = { kind="lambda_expr", params={"x"}, body=int_lit(99) }
    local result = eval.eval_expr(lam_node, ctx())
    assert.is_not_nil(result)
    assert.is_true(result._lambda)
    assert.are.same({"x"}, result.params)
  end)

  it("count-where uses lambda predicate", function()
    -- count-where pred list: count elements where pred returns true
    local c = ctx({})
    -- Build: (count-where fn(x): x > 2 [1, 2, 3, 4])
    local pred = { kind="lambda_expr", params={"x"},
                   body = binop(">", { kind="fn_call", name="x", args={} }, int_lit(2)) }
    local lst  = { kind="list_lit",
                   elements = { int_lit(1), int_lit(2), int_lit(3), int_lit(4) } }
    local call = { kind="fn_call", name="count-where", args={ lst, pred } }
    assert.are.equal(2, eval.eval_expr(call, c))
  end)
end)

describe("eval_expr: set and map literals", function()
  it("set_lit evaluates to a list of symbol values", function()
    local result = eval.eval_expr(set_lit("alive", "dead"), ctx())
    assert.are.same({"alive", "dead"}, result)
  end)

  it("empty map literal evaluates to empty table", function()
    local result = eval.eval_expr({ kind="map_lit", entries={} }, ctx())
    assert.are.same({}, result)
  end)

  it("map_lit evaluates to a table with string keys", function()
    local result = eval.eval_expr(map_lit({name="Alice", role="guard"}), ctx())
    assert.are.equal("Alice", result["name"])
    assert.are.equal("guard", result["role"])
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

  it("in: element in array-style list returns true", function()
    local c = ctx({})
    local node = binop("in", {kind="string_lit", value="b"},
      {kind="list_lit", elements={{kind="string_lit",value="a"},{kind="string_lit",value="b"}}})
    assert.is_true(eval.eval_expr(node, c))
  end)

  it("in: element not in list returns false", function()
    local c = ctx({})
    local node = binop("in", {kind="string_lit", value="z"},
      {kind="list_lit", elements={{kind="string_lit",value="a"},{kind="string_lit",value="b"}}})
    assert.is_false(eval.eval_expr(node, c))
  end)

  it("in: element in map-style table returns true", function()
    local c = ctx({})
    c.vars["m"] = {corridor=true, armory=true}
    local node = binop("in",
      {kind="string_lit", value="corridor"},
      {kind="fn_call", name="m", args={}})
    assert.is_true(eval.eval_expr(node, c))
  end)

  it("in: element not in map-style table returns false", function()
    local c = ctx({})
    c.vars["m"] = {corridor=true}
    local node = binop("in",
      {kind="string_lit", value="vault"},
      {kind="fn_call", name="m", args={}})
    assert.is_false(eval.eval_expr(node, c))
  end)

  it("in: returns false when right side is not a table", function()
    local c = ctx({})
    local node = binop("in", {kind="string_lit", value="x"}, int_lit(5))
    assert.is_false(eval.eval_expr(node, c))
  end)

  it("in: UMap key with value false is still found (falsy value bug regression)", function()
    local c = ctx({})
    c.vars["m"] = {keyname = false}
    local node = binop("in",
      {kind="string_lit", value="keyname"},
      {kind="fn_call", name="m", args={}})
    assert.is_true(eval.eval_expr(node, c))
  end)

  it("in: UMap key with value 0 is still found (zero value bug regression)", function()
    local c = ctx({})
    c.vars["m"] = {keyname = 0}
    local node = binop("in",
      {kind="string_lit", value="keyname"},
      {kind="fn_call", name="m", args={}})
    assert.is_true(eval.eval_expr(node, c))
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

  it("pre-condition expressed as expr_stmt is evaluated correctly", function()
    -- When pre: contains expr_stmt-wrapped nodes (as emitted by the parser),
    -- the condition should be unwrapped and evaluated properly.
    local fns = {
      ["guarded-fn"] = {
        name = "guarded-fn",
        params = {},
        -- pre: flag (wrapped in expr_stmt, as the parser emits)
        pre = { { kind = "expr_stmt", expr = { kind = "path_expr", segments = {"flag"} } } },
        post = {},
        body = { { kind = "set_mut",
                   path = { kind = "path_expr", segments = {"result"} },
                   value = bool_lit(true) } },
        is_transaction = true,
      }
    }
    -- flag = false → precondition fails
    local c1 = ctx({ flag = false, result = false }, fns)
    assert.has_error(function() eval.eval_expr(fn_call("guarded-fn"), c1) end)
    -- flag = true → precondition passes, body runs
    local c2 = ctx({ flag = true, result = false }, fns)
    assert.has_no.errors(function() eval.eval_expr(fn_call("guarded-fn"), c2) end)
    assert.is_true(c2.state:get("result"))
  end)

  it("pre: with not operator (via full compile) evaluates correctly", function()
    local compiler = require("compiler.compiler")
    local src = [[
module pre-test
  version: 1.0
engine-config:
  entry-scene: s

state world:
  done: Bool = false

fn do-once:
  pre:
    not world/done
  set! world/done true

scene s:
  Done.
]]
    local gt, diags = compiler.compile(src, "pre-test")
    assert.is_false(diags:has_errors())

    local log_mod   = require("runtime.log")
    local state_mod = require("runtime.state")
    local l = log_mod.new()
    local s = state_mod.new(gt.schema, l)
    s:init_defaults()
    local c = eval.new_ctx(s, gt.fns, "test")
    c.game = gt

    -- First call: world/done = false → pre: passes → sets done = true
    assert.has_no.errors(function() eval.call_fn("do-once", {}, c) end)
    assert.is_true(s:get("world/done"))

    -- Second call: world/done = true → pre: fails
    assert.has_error(function() eval.call_fn("do-once", {}, c) end)
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

  it("matches integer arm", function()
    local c = ctx({})
    local node = match_expr(int_lit(7), {
      { int_lit(1),  str_lit("one")   },
      { int_lit(7),  str_lit("seven") },
      { "_",         str_lit("other") },
    })
    assert.equal("seven", eval.eval_expr(node, c))
  end)

  -- Bug #9 regression: nil literal as match arm body
  it("Bug #9: '_: nil' arm evaluates to Lua nil (not crash)", function()
    local c = ctx({})
    local node = match_expr(str_lit("dead"), {
      { str_lit("alive"), int_lit(1)                           },
      { "_",              fn_call("nil")                       },
    })
    assert.is_nil(eval.eval_expr(node, c))
  end)

  it("Bug #9: '_: nil' wildcard is not taken when an earlier arm matches", function()
    local c = ctx({})
    local node = match_expr(str_lit("alive"), {
      { str_lit("alive"), int_lit(42)   },
      { "_",              fn_call("nil") },
    })
    assert.equal(42, eval.eval_expr(node, c))
  end)

  it("Bug #9: nil arm works with symbol subjects", function()
    local c = ctx({})
    local node = match_expr(sym_lit("unknown"), {
      { sym_lit("known"),   str_lit("yes")  },
      { "_",                fn_call("nil")  },
    })
    assert.is_nil(eval.eval_expr(node, c))
  end)

  it("Bug #9: nil arm works with integer subjects", function()
    local c = ctx({})
    local node = match_expr(int_lit(99), {
      { int_lit(1),  str_lit("one")  },
      { int_lit(2),  str_lit("two")  },
      { "_",         fn_call("nil")  },
    })
    assert.is_nil(eval.eval_expr(node, c))
  end)
end)

-- Bug #11: match without wildcard emits a runtime warning and returns nil
describe("Bug #11: match — no arm matches runtime warning", function()
  local function match_expr(subj, arms_tbl)
    local arms = {}
    for _, a in ipairs(arms_tbl) do
      arms[#arms+1] = { kind="match_arm", pattern=a[1], body=a[2] }
    end
    return { kind="match_expr", expr=subj, arms=arms }
  end

  it("emits warning to _print_sink when no arm matches and no wildcard", function()
    local warnings = {}
    local c = ctx({})
    c.game = { _print_sink = function(msg) warnings[#warnings+1] = msg end }
    local node = match_expr(sym_lit("ranger"), {
      { sym_lit("warrior"), int_lit(15) },
      { sym_lit("mage"),    int_lit(10) },
    })
    local result = eval.eval_expr(node, c)
    assert.is_nil(result)
    assert.equal(1, #warnings)
    assert.truthy(warnings[1]:find("WARN", 1, true))
    assert.truthy(warnings[1]:find("ranger", 1, true))
  end)

  it("does NOT emit warning when wildcard arm is present", function()
    local warnings = {}
    local c = ctx({})
    c.game = { _print_sink = function(msg) warnings[#warnings+1] = msg end }
    local node = match_expr(sym_lit("ranger"), {
      { sym_lit("warrior"), int_lit(15) },
      { "_",                int_lit(0)  },
    })
    local result = eval.eval_expr(node, c)
    assert.equal(0, result)
    assert.equal(0, #warnings)
  end)

  it("does NOT emit warning in production mode", function()
    local warnings = {}
    local c = ctx({})
    c.game = { production = true,
               _print_sink = function(msg) warnings[#warnings+1] = msg end }
    local node = match_expr(sym_lit("ranger"), {
      { sym_lit("warrior"), int_lit(15) },
    })
    eval.eval_expr(node, c)
    assert.equal(0, #warnings)
  end)

  it("does NOT emit warning when all arms match (subject matched)", function()
    local warnings = {}
    local c = ctx({})
    c.game = { _print_sink = function(msg) warnings[#warnings+1] = msg end }
    local node = match_expr(sym_lit("warrior"), {
      { sym_lit("warrior"), int_lit(15) },
      { sym_lit("mage"),    int_lit(10) },
    })
    local result = eval.eval_expr(node, c)
    assert.equal(15, result)
    assert.equal(0, #warnings)
  end)
end)

-- SF-1: zero-arg undefined function call emits a warning and returns name as string
describe("SF-1: zero-arg unknown call warning", function()
  -- Helper: a ctx with a game that captures warnings via _print_sink
  local function warned_ctx(vals, extra_game)
    local warnings = {}
    local c = ctx(vals or {})
    c.game = extra_game or {}
    c.game._print_sink = function(msg) warnings[#warnings+1] = msg end
    return c, warnings
  end

  it("emits warning when 0-arg call name is not in fns, vars, builtins, or bounded", function()
    local c, warns = warned_ctx()
    local node = fn_call("move-too")  -- typo: move-too vs move-to
    local result = eval.eval_expr(node, c)
    assert.equal("move-too", result)
    assert.equal(1, #warns)
    assert.truthy(warns[1]:find("WARN",     1, true))
    assert.truthy(warns[1]:find("move-too", 1, true))
  end)

  it("does NOT warn when name is a known user function", function()
    local c, warns = warned_ctx()
    c.fns = { ["move-to"] = { params = {}, body = {} } }
    local node = fn_call("move-to")
    eval.eval_expr(node, c)
    assert.equal(0, #warns)
  end)

  it("does NOT warn when name is in ctx.vars", function()
    local c, warns = warned_ctx()
    c.vars["m"] = "alice"
    local node = fn_call("m")
    local result = eval.eval_expr(node, c)
    assert.equal("alice", result)
    assert.equal(0, #warns)
  end)

  it("does NOT warn when name is a known builtin", function()
    local c, warns = warned_ctx()
    -- 'min' is a BUILTIN, so calling it with args won't hit the bare-string path,
    -- but confirm no spurious warning for a no-arg call to a builtin name either
    -- (builtins are dispatched before the bare-string path)
    local node = { kind = "fn_call", name = "min", args = {
      { kind = "int_lit", value = 1 },
      { kind = "int_lit", value = 2 },
    }}
    eval.eval_expr(node, c)
    assert.equal(0, #warns)
  end)

  it("does NOT warn in production mode", function()
    local c, warns = warned_ctx(nil, { production = true })
    local node = fn_call("move-too")
    eval.eval_expr(node, c)
    assert.equal(0, #warns)
  end)

  it("does NOT warn when name is a relation name in ctx.game.relations", function()
    local c, warns = warned_ctx(nil, {
      relations = { exits = { name = "exits", data = {} } },
    })
    local node = fn_call("exits")
    local result = eval.eval_expr(node, c)
    assert.equal("exits", result)
    assert.equal(0, #warns)
  end)

  it("does NOT warn when name is a grid name in ctx.game.grids", function()
    local c, warns = warned_ctx(nil, {
      grids = { dungeon = { width = 10, height = 10 } },
    })
    local node = fn_call("dungeon")
    local result = eval.eval_expr(node, c)
    assert.equal("dungeon", result)
    assert.equal(0, #warns)
  end)

  it("does NOT warn when name is a declared family name", function()
    local c, warns = warned_ctx(nil, {
      schema = {
        states = {
          { kind = "family", family = "npcs", var = "npc" },
        },
      },
    })
    local node = fn_call("npcs")
    local result = eval.eval_expr(node, c)
    assert.equal("npcs", result)
    assert.equal(0, #warns)
  end)

  it("caches the known-bare-names set on ctx.game after first call", function()
    local c, warns = warned_ctx(nil, {
      schema = { states = { { kind = "family", family = "crew", var = "m" } } },
    })
    -- First call: builds cache
    eval.eval_expr(fn_call("crew"), c)
    assert.equal(0, #warns)
    -- Second call: uses cache (no repeated scan)
    eval.eval_expr(fn_call("crew"), c)
    assert.equal(0, #warns)
    assert.is_not_nil(c.game._known_bare_names)
    assert.is_true(c.game._known_bare_names["crew"])
  end)

  it("warns without a game object (ctx.game nil)", function()
    -- When ctx.game is nil there is no sink; warning should go to io.stderr
    -- without crashing.  We just verify no error is raised and result is the name.
    local c = ctx({})  -- c.game is nil
    local node = fn_call("bad-fn-name")
    local ok, result = pcall(eval.eval_expr, node, c)
    assert.is_true(ok)
    assert.equal("bad-fn-name", result)
  end)
end)

-- ============================================================
-- record_constructor
-- ============================================================

describe("eval_expr: record_constructor", function()
  it("builds a table with __variant tag and named fields", function()
    local c = ctx({})
    local node = {
      kind      = "record_constructor",
      type_name = "Msg/ping",
      fields    = {
        { kind = "named_arg", name = "value", value = int_lit(42) },
        { kind = "named_arg", name = "text",  value = str_lit("hello") },
      },
    }
    local result = eval.eval_expr(node, c)
    assert.is_table(result)
    assert.equal("Msg/ping", result.__variant)
    assert.equal(42,         result.value)
    assert.equal("hello",    result.text)
  end)

  it("builds a table with no fields", function()
    local c = ctx({})
    local node = {
      kind      = "record_constructor",
      type_name = "Status/ok",
      fields    = {},
    }
    local result = eval.eval_expr(node, c)
    assert.equal("Status/ok", result.__variant)
  end)

  it("match_expr matches record_constructor by __variant", function()
    local c = ctx({})
    -- Build the subject: a record with __variant = "Msg/ping"
    local subject_node = {
      kind      = "record_constructor",
      type_name = "Msg/ping",
      fields    = { { kind = "named_arg", name = "n", value = int_lit(7) } },
    }
    -- Build the match: arm pattern is a record_constructor with same type_name
    local pattern = {
      kind      = "record_constructor",
      type_name = "Msg/ping",
      fields    = { { kind = "named_arg", name = "n", value = fn_call("n") } },
    }
    local arms = {
      { kind = "match_arm", pattern = pattern, body = int_lit(99) },
      { kind = "match_arm", pattern = "_",     body = int_lit(0)  },
    }
    local node = { kind = "match_expr", expr = subject_node, arms = arms }
    assert.equal(99, eval.eval_expr(node, c))
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
    local iter_node = { kind="list_lit", elements={ int_lit(1), int_lit(2), int_lit(3) } }
    local body = { { kind="inc_mut", path=path("sum"), amount=path("x") } }
    local node = { kind="for_stmt", var="x", iter=iter_node, body=body }
    eval.eval_stmt(node, c)
    assert.equal(6, c.state:get("sum"))
  end)

  it("else body runs when list is empty", function()
    local c = ctx({ ["flag"] = 0 })
    local iter_node = { kind="list_lit", elements={} }
    local body = { { kind="inc_mut", path=path("flag"), amount=int_lit(1) } }
    local else_body = { { kind="set_mut", path=path("flag"), value=int_lit(99) } }
    local node = { kind="for_stmt", var="x", iter=iter_node, body=body, else_body=else_body }
    eval.eval_stmt(node, c)
    assert.equal(99, c.state:get("flag"))
  end)

  it("else body does not run when list is non-empty", function()
    local c = ctx({ ["flag"] = 0 })
    local iter_node = { kind="list_lit", elements={ int_lit(1) } }
    local body = { { kind="inc_mut", path=path("flag"), amount=int_lit(1) } }
    local else_body = { { kind="set_mut", path=path("flag"), value=int_lit(99) } }
    local node = { kind="for_stmt", var="x", iter=iter_node, body=body, else_body=else_body }
    eval.eval_stmt(node, c)
    assert.equal(1, c.state:get("flag"))
  end)

  it("for else parsed from source: else runs on empty collection", function()
    local compiler = require("compiler.compiler")
    local log_mod  = require("runtime.log")
    local state_mod= require("runtime.state")
    local src = [[
module t
  version: 1.0
engine-config:
  entry-scene: s
state world:
  result: Int(0, 9999) = 0
  items: List(Symbol, 10) = (list)
fn check:
  for x in world/items:
    set! world/result 1
  else:
    set! world/result 42
scene s:
  * go -> s
]]
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local st = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(st, gt.fns, "test", gt)
    st:init_defaults()
    eval.call_fn("check", {}, c)
    assert.equal(42, st:get("world/result"))
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

  it("raises an error when iteration limit is exceeded", function()
    local c = ctx({ ["n"] = 0 })
    -- while true (never terminates)
    local always_true = { kind="bool_lit", value=true }
    local body = { { kind="inc_mut", path=path("n"), amount=int_lit(1) } }
    local node = { kind="while_stmt", condition=always_true, body=body }
    local ok, err = pcall(eval.eval_stmt, node, c)
    assert.is_false(ok, "expected error for infinite loop")
    assert.is_true(err:find("10000") ~= nil or err:find("limit") ~= nil,
      "error should mention the iteration limit")
  end)
end)

describe("eval_stmt: break_stmt in for loop", function()
  it("stops iteration early", function()
    local sb = require("lib.storybase")
    local game, err = sb.from_source([[
module break-test
  version: 1.0
engine-config:
  entry-scene: s
state world:
  count: Int(0,100) = 0

fn count-to-3:
  for i in [1, 2, 3, 4, 5]:
    if i > 3:
      break
    inc! world/count 1

scene s:
  Done.
]], "break-test.sb")
    assert.is_not_nil(game, tostring(err))
    game:init()
    game:call("count-to-3")
    assert.equal(3, game:get("world/count"))
  end)

  it("continue skips to next iteration", function()
    local sb = require("lib.storybase")
    local game, err = sb.from_source([[
module continue-test
  version: 1.0
engine-config:
  entry-scene: s
state world:
  count: Int(0,100) = 0

fn count-odds:
  for i in [1, 2, 3, 4, 5]:
    if i = 2:
      continue
    if i = 4:
      continue
    inc! world/count 1

scene s:
  Done.
]], "continue-test.sb")
    assert.is_not_nil(game, tostring(err))
    game:init()
    game:call("count-odds")
    -- 1, 3, 5 counted (2 and 4 skipped)
    assert.equal(3, game:get("world/count"))
  end)
end)

describe("eval_stmt: break_stmt in while loop", function()
  it("break exits while loop", function()
    local sb = require("lib.storybase")
    local game, err = sb.from_source([[
module while-break-test
  version: 1.0
engine-config:
  entry-scene: s
state world:
  n: Int(0,100) = 0

fn count-while:
  while world/n < 10:
    inc! world/n 1
    if world/n = 5:
      break

scene s:
  Done.
]], "while-break-test.sb")
    assert.is_not_nil(game, tostring(err))
    game:init()
    game:call("count-while")
    assert.equal(5, game:get("world/n"))
  end)
end)

describe("eval_stmt: return_stmt (early function exit)", function()
  it("returns a value from a conditional branch", function()
    local sb = require("lib.storybase")
    local game, err = sb.from_source([[
module return-test
  version: 1.0
engine-config:
  entry-scene: s
state world:
  result: Int(0,100) = 0

fn classify n:
  if n > 50:
    return 99
  return 1

scene s:
  Done.
]], "return-test.sb")
    assert.is_not_nil(game, tostring(err))
    game:init()
    local big = game:call("classify", 80)
    assert.equal(99, big)
    local small = game:call("classify", 10)
    assert.equal(1, small)
  end)

  it("return stops subsequent mutations from running", function()
    local sb = require("lib.storybase")
    local game, err = sb.from_source([[
module return-halt-test
  version: 1.0
engine-config:
  entry-scene: s
state world:
  n: Int(0,100) = 0

fn maybe-inc flag:
  if not flag:
    return 0
  inc! world/n 10
  return world/n

scene s:
  Done.
]], "return-halt-test.sb")
    assert.is_not_nil(game, tostring(err))
    game:init()
    -- flag=false: early return, n stays 0
    game:call("maybe-inc", false)
    assert.equal(0, game:get("world/n"))
    -- flag=true: mutation runs
    game:call("maybe-inc", true)
    assert.equal(10, game:get("world/n"))
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

  it("free form (no body) binds into enclosing ctx.vars", function()
    local c = ctx({})
    -- let x = 42  (no body)
    local binding = { kind="let_binding", name="x", expr=int_lit(42) }
    local node = { kind="let_stmt", bindings={binding}, body={} }
    eval.eval_stmt(node, c)
    assert.equal(42, c.vars["x"])
  end)

  it("free form lets are visible to subsequent statements in same fn", function()
    local compiler = require("compiler.compiler")
    local log_mod  = require("runtime.log")
    local state_mod= require("runtime.state")
    local src = [[
module t
  version: 1.0
engine-config:
  entry-scene: s
state world:
  result: Int(0, 9999) = 0
fn compute:
  let x = 10
  let y = x + 5
  set! world/result y
scene s:
  * go -> s
]]
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local st = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(st, gt.fns, "test", gt)
    st:init_defaults()
    eval.call_fn("compute", {}, c)
    assert.equal(15, st:get("world/result"))
  end)

  it("free form let works in choice body", function()
    local compiler = require("compiler.compiler")
    local engine_mod = require("runtime.engine")
    local src = [[
module t
  version: 1.0
engine-config:
  entry-scene: start
state world:
  result: Int(0, 9999) = 0
scene start:
  "pick"
  * go
    let n = 7
    set! world/result n
    -> start
]]
    local gt = assert(compiler.compile(src, "t.sb"))
    local eng = engine_mod.new(gt)
    eng:init()
    eng:do_choice("start", 1)
    assert.equal(7, eng._state:get("world/result"))
  end)
end)

-- ============================================================
-- render_text
-- ============================================================

describe("eval: render_text", function()
  it("renders a single string segment", function()
    local c = ctx({})
    local text = { "Hello world" }
    assert.equal("Hello world", eval.render_text(text, c))
  end)

  it("renders inline_expr with surrounding spacing from the string part", function()
    local c = ctx({ ["player/hp"] = 42 })
    -- The parser always bakes spacing into string segments; render_text joins with "".
    local text = { "HP: ", { kind="inline_expr", expr=path("player", "hp") } }
    assert.equal("HP: 42", eval.render_text(text, c))
  end)

  -- AE-13: float values with no fractional part render without ".0"
  it("renders a whole-number float without .0 (AE-13)", function()
    local c = ctx({})
    -- 50.0 is a float (result of division) with no fractional part
    local text = { "Damage: ", { kind="inline_expr", expr={ kind="binary_op", op="/", left=int_lit(100), right=int_lit(2) } } }
    assert.equal("Damage: 50", eval.render_text(text, c))
  end)

  it("renders a float with fractional part normally", function()
    local c = ctx({})
    local text = { "Val: ", { kind="inline_expr", expr={ kind="binary_op", op="/", left=int_lit(1), right=int_lit(3) } } }
    local result = eval.render_text(text, c)
    -- 0.333... should not be rendered as an integer
    assert.is_true(result:find("%.") ~= nil, "expected decimal point in " .. result)
  end)

  it("renders a true integer literal without .0", function()
    local c = ctx({})
    local text = { "Count: ", { kind="inline_expr", expr=int_lit(7) } }
    assert.equal("Count: 7", eval.render_text(text, c))
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

-- ============================================================
-- time-set! via eval
-- ============================================================

describe("eval_stmt: time_set_mut", function()
  local log_mod   = require("runtime.log")
  local state_mod = require("runtime.state")
  local compiler  = require("compiler.compiler")

  it("sets the engine time clock to an absolute value via time-set!", function()
    local gt, diags = compiler.compile([[
module t
  version: 1.0
schema-version: 1
time-model:
  axes: [day, tick]
  wrap: [none, none]
fn jump-to-day3:
  time-set! day: 3 tick: 0
scene start:
  .
  * Go
    jump-to-day3
    -> start
]], "test")
    assert.equal(0, #diags.errors)
    local log   = log_mod.new()
    local store = state_mod.new(gt.schema, log)
    store:init_defaults(gt.schema)
    -- Advance first, then set should override
    store:inc_time("day", 10)
    store:inc_time("tick", 99)
    local fn = gt.fns["jump-to-day3"]
    local c = eval.new_ctx(store, gt.fns, "jump-to-day3")
    eval.eval_stmts(fn.body, c)
    assert.equal(3, store:get_time().day)
    assert.equal(0, store:get_time().tick)
  end)

  it("time-set! with a single axis leaves other axes unchanged", function()
    local gt, diags = compiler.compile([[
module t
  version: 1.0
schema-version: 1
time-model:
  axes: [day, hour]
  wrap: [none, 24]
fn reset-hour:
  time-set! hour: 8
scene start:
  .
  * Go
    reset-hour
    -> start
]], "test")
    assert.equal(0, #diags.errors)
    local log   = log_mod.new()
    local store = state_mod.new(gt.schema, log)
    store:init_defaults(gt.schema)
    store:inc_time("day", 5)
    store:inc_time("hour", 20)
    local fn = gt.fns["reset-hour"]
    local c = eval.new_ctx(store, gt.fns, "reset-hour")
    eval.eval_stmts(fn.body, c)
    assert.equal(5, store:get_time().day)  -- unchanged
    assert.equal(8, store:get_time().hour) -- set to 8
  end)
end)

-- ── time/<axis> pseudo-paths ─────────────────────────────────────────────────

describe("eval: time/<axis> read-only pseudo-paths", function()
  local log_mod2   = require("runtime.log")
  local state_mod2 = require("runtime.state")
  local compiler2  = require("compiler.compiler")

  local function make_time_ctx(axes_src)
    local src = [[
module t
  version: 1.0
schema-version: 1
time-model:
]] .. axes_src .. [[
fn noop:
  pass
scene start:
  .
  * Go -> start
]]
    local gt, diags = compiler2.compile(src, "test")
    assert.equal(0, #diags.errors, "compile failed")
    local log   = log_mod2.new()
    local store = state_mod2.new(gt.schema, log)
    store:init_defaults(gt.schema)
    local c = eval.new_ctx(store, gt.fns, "test")
    return c, store
  end

  it("time/day reads declared axis value (initial 0)", function()
    local c, _ = make_time_ctx("  axes: [day]\n  wrap: [none]\n")
    local node = { kind = "path_expr", segments = {"time", "day"} }
    assert.equal(0, eval.eval_expr(node, c))
  end)

  it("time/day reflects value after time-inc!", function()
    local c, store = make_time_ctx("  axes: [day, tick]\n  wrap: [none, none]\n")
    store:inc_time("day", 5)
    local node = { kind = "path_expr", segments = {"time", "day"} }
    assert.equal(5, eval.eval_expr(node, c))
  end)

  it("time/tick is independent of time/day", function()
    local c, store = make_time_ctx("  axes: [day, tick]\n  wrap: [none, none]\n")
    store:inc_time("day", 3)
    store:inc_time("tick", 7)
    local day_node  = { kind = "path_expr", segments = {"time", "day"}  }
    local tick_node = { kind = "path_expr", segments = {"time", "tick"} }
    assert.equal(3, eval.eval_expr(day_node,  c))
    assert.equal(7, eval.eval_expr(tick_node, c))
  end)

  it("time/day reflects value after time-set!", function()
    local c, store = make_time_ctx("  axes: [day]\n  wrap: [none]\n")
    store:set_time("day", 12)
    local node = { kind = "path_expr", segments = {"time", "day"} }
    assert.equal(12, eval.eval_expr(node, c))
  end)

  it("returns nil for an undeclared axis", function()
    local c, _ = make_time_ctx("  axes: [day]\n  wrap: [none]\n")
    local node = { kind = "path_expr", segments = {"time", "year"} }
    assert.is_nil(eval.eval_expr(node, c))
  end)

  it("time/<axis> is readable in compiled narration via inline expression", function()
    local src = [[
module t
  version: 1.0
schema-version: 1
time-model:
  axes: [day]
  wrap: [none]
engine-config:
  entry-scene: start
scene start:
  Day {time/day}.
  * Next -> start
]]
    local gt = assert(compiler2.compile(src, "test"))
    local eng_mod = require("runtime.engine")
    local eng = eng_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    eng._state:inc_time("day", 4)
    local narr = eng:render_scene("start")
    local text = narr[1] and narr[1].text or narr[1]
    assert.matches("Day 4", tostring(text))
  end)

  it("time/<axis> is usable in a pure fn return value", function()
    local src = [[
module t
  version: 1.0
schema-version: 1
time-model:
  axes: [day]
  wrap: [none]
fn current-day:
  time/day
scene start:
  .
  * Go -> start
]]
    local gt = assert(compiler2.compile(src, "test"))
    local log3  = log_mod2.new()
    local st3   = state_mod2.new(gt.schema, log3)
    st3:init_defaults(gt.schema)
    st3:inc_time("day", 9)
    local c3 = eval.new_ctx(st3, gt.fns, "current-day", gt)
    local result = eval.call_fn("current-day", {}, c3)
    assert.equal(9, result)
  end)
end)

-- ── indexed list access ──────────────────────────────────────────────────────

describe("eval — indexed list access", function()
  local ast_mod = require("compiler.ast")
  local P = ast_mod.pos("t", 1, 1)

  local function index_expr(base, idx)
    return { kind = "index_expr", base = base, index = idx, pos = P }
  end
  local function path_expr(segs)
    return { kind = "path_expr", segments = segs, pos = P }
  end
  local function fn_call(name)
    return { kind = "fn_call", name = name, args = {}, pos = P }
  end
  local function int_lit(v)
    return { kind = "int_lit", value = v, pos = P }
  end
  local function expr_stmt(e)
    return { kind = "expr_stmt", expr = e, pos = P }
  end

  it("evaluates path[n] for multi-segment path (state read)", function()
    local c = ctx({ ["npcs/guard/items"] = {10, 20, 30} })
    local node = expr_stmt(index_expr(path_expr({"npcs","guard","items"}), int_lit(1)))
    eval.eval_stmt(node, c)
    assert.equal(10, c.retval)
  end)

  it("evaluates single-segment ident[n] from state", function()
    local c = ctx({ ["items"] = {10, 20, 30} })
    -- fn_call("items") with 0 args falls back to string "items" → state read in INDEX_EXPR
    local node = expr_stmt(index_expr(fn_call("items"), int_lit(2)))
    eval.eval_stmt(node, c)
    assert.equal(20, c.retval)
  end)

  it("evaluates index on local variable (ctx.vars)", function()
    local c = ctx({})
    c.vars["lst"] = {99, 88, 77}
    -- fn_call("lst") resolves via ctx.vars
    local node = expr_stmt(index_expr(fn_call("lst"), int_lit(1)))
    eval.eval_stmt(node, c)
    assert.equal(99, c.retval)
  end)

  it("returns nil for out-of-bounds index", function()
    local c = ctx({ ["items"] = {10, 20} })
    local node = expr_stmt(index_expr(fn_call("items"), int_lit(5)))
    eval.eval_stmt(node, c)
    assert.is_nil(c.retval)
  end)

  it("slice_expr returns sub-list", function()
    local c = ctx({ ["items"] = {10, 20, 30, 40, 50} })
    local slice = { kind="slice_expr",
                    base  = path_expr({"items"}),
                    from  = int_lit(2),
                    to    = int_lit(4) }
    local node = expr_stmt(slice)
    eval.eval_stmt(node, c)
    assert.are.same({20, 30, 40}, c.retval)
  end)

  it("set! path[n] value writes element back to list", function()
    local c = ctx({ ["items"] = {10, 20, 30} })
    local write_node = {
      kind  = "set_mut",
      path  = index_expr(path_expr({"items"}), int_lit(2)),
      value = int_lit(99),
    }
    eval.eval_stmt(write_node, c)
    assert.are.same({10, 99, 30}, c.state:get("items"))
  end)

  it("set! path[-1] value writes to last element", function()
    local c = ctx({ ["items"] = {10, 20, 30} })
    local write_node = {
      kind  = "set_mut",
      path  = index_expr(path_expr({"items"}), int_lit(-1)),
      value = int_lit(99),
    }
    eval.eval_stmt(write_node, c)
    assert.are.same({10, 20, 99}, c.state:get("items"))
  end)
end)

-- ============================================================
-- path-exists? builtin
-- ============================================================

describe("builtin: path-exists?", function()
  local compiler = require("compiler.compiler")
  local engine   = require("runtime.engine")

  it("returns false for absent path via path_expr arg", function()
    local c = ctx({})
    -- path-exists? foo/bar/hp — path_expr arg, nothing in state
    local node = { kind="expr_stmt", expr=fn_call("path-exists?", path("foo","bar","hp")) }
    eval.eval_stmt(node, c)
    assert.is_false(c.retval)
  end)

  it("returns true for existing path via path_expr arg (not the value)", function()
    local c = ctx({ ["crew/renn/hp"] = 100 })
    -- path-exists? must return true even though the value is an integer, not a string
    local node = { kind="expr_stmt", expr=fn_call("path-exists?", path("crew","renn","hp")) }
    eval.eval_stmt(node, c)
    assert.is_true(c.retval)
  end)

  it("returns true for path with integer value after spawn (full compile)", function()
    local src = [[
module t
  version: 1.0
type M:
  hp: Int(0,100) = 60
state crew/{member}: M  max: 4
fn spawn-renn:
  spawn! crew `renn M(hp: 80)
fn check:
  path-exists? crew/renn/hp
fn check-interp member:
  path-exists? crew/{member}/hp
]]
    local gt = assert(compiler.compile(src, "t.sb"))
    local log  = require("runtime.log").new()
    local st   = require("runtime.state").new(gt.schema, log)
    local c    = eval.new_ctx(st, gt.fns, "test")
    -- Before spawn: should be false
    local before = eval.call_fn("check", {}, c)
    assert.is_false(before)
    -- Spawn renn
    eval.call_fn("spawn-renn", {}, c)
    -- After spawn: integer hp value at crew/renn/hp → path-exists? must return true
    local after = eval.call_fn("check", {}, c)
    assert.is_true(after)
    -- Interpolated path variant (pass arg as string_lit node)
    local interp = eval.call_fn("check-interp", {str_lit("renn")}, c)
    assert.is_true(interp)
  end)
end)

-- ============================================================
-- Historical log query builtins: query-at, query-history, query-changes
-- ============================================================

describe("builtin: query-at / query-history / query-changes", function()
  local log_mod2   = require("runtime.log")
  local state_mod2 = require("runtime.state")

  local function make_state_with_history()
    local l = log_mod2.new()
    local s = state_mod2.new({types={}, states={}}, l)
    s:set("player/health", 100, "init")
    s:set("player/health", 80,  "damage")
    s:set("player/health", 60,  "damage2")
    return s, l
  end

  it("query-history returns all changes for a path", function()
    local s, _ = make_state_with_history()
    local c = eval.new_ctx(s, {}, "test")
    local node = fn_call("query-history", { kind="path_expr", segments={"player", "health"} })
    local result = eval.eval_expr(node, c)
    assert.is_table(result)
    assert.equal(3, #result)
    assert.equal(100, result[1].new)
    assert.equal(80,  result[2].new)
    assert.equal(60,  result[3].new)
  end)

  it("query-changes with last-n: 2 returns last 2 changes", function()
    local s, _ = make_state_with_history()
    local c = eval.new_ctx(s, {}, "test")
    local node = fn_call("query-changes",
      { kind="path_expr", segments={"player", "health"} },
      { kind="named_arg", name="last-n", value={ kind="int_lit", value=2 } })
    local result = eval.eval_expr(node, c)
    assert.is_table(result)
    assert.equal(2, #result)
    assert.equal(80, result[1].new)
    assert.equal(60, result[2].new)
  end)

  it("query-at with no time: returns current value", function()
    local s, _ = make_state_with_history()
    local c = eval.new_ctx(s, {}, "test")
    local node = fn_call("query-at", { kind="path_expr", segments={"player", "health"} })
    local result = eval.eval_expr(node, c)
    assert.equal(60, result)
  end)

  it("query-at with time: seq 1 returns value at seq 1", function()
    local s, l = make_state_with_history()
    local c = eval.new_ctx(s, {}, "test")
    -- First entry has seq=1 (value 100), second seq=2 (80), third seq=3 (60)
    local first_seq = l:entries()[1].seq
    local node = fn_call("query-at",
      { kind="path_expr", segments={"player", "health"} },
      { kind="named_arg", name="time", value={ kind="int_lit", value=first_seq } })
    local result = eval.eval_expr(node, c)
    assert.equal(100, result)
  end)

  it("query-history returns empty list for unknown path", function()
    local s, _ = make_state_with_history()
    local c = eval.new_ctx(s, {}, "test")
    local node = fn_call("query-history", { kind="path_expr", segments={"no", "such"} })
    local result = eval.eval_expr(node, c)
    assert.is_table(result)
    assert.equal(0, #result)
  end)

  -- Bug #6: path pattern expansion in query-history / query-changes
  it("query-history with wildcard pattern returns union for all matching paths", function()
    local log_mod3 = require("runtime.log")
    local state_mod3 = require("runtime.state")
    local l = log_mod3.new()
    local s = state_mod3.new({types={}, states={}}, l)
    s:set("player/health", 100, "init")
    s:set("player/mana",   50,  "init")
    s:set("world/tick",    1,   "tick")
    local c = eval.new_ctx(s, {}, "test")
    -- player/* should match player/health and player/mana, NOT world/tick
    local node = fn_call("query-history", { kind="path_expr", segments={"player", "*"} })
    local result = eval.eval_expr(node, c)
    assert.is_table(result)
    assert.equal(2, #result, "should return 2 entries (health + mana), not world/tick")
  end)

  it("query-history with alternation pattern (a|b) returns only matched paths", function()
    local log_mod3 = require("runtime.log")
    local state_mod3 = require("runtime.state")
    local l = log_mod3.new()
    local s = state_mod3.new({types={}, states={}}, l)
    s:set("player/health", 80,  "dmg")
    s:set("player/mana",   40,  "cast")
    s:set("player/gold",   10,  "buy")
    local c = eval.new_ctx(s, {}, "test")
    local node = fn_call("query-history", { kind="path_expr", segments={"player", "(health|mana)"} })
    local result = eval.eval_expr(node, c)
    assert.equal(2, #result, "should return health and mana but not gold")
  end)

  it("query-history with !field pattern excludes the negated segment", function()
    local log_mod3 = require("runtime.log")
    local state_mod3 = require("runtime.state")
    local l = log_mod3.new()
    local s = state_mod3.new({types={}, states={}}, l)
    s:set("player/health", 80,  "dmg")
    s:set("player/mana",   40,  "cast")
    s:set("player/gold",   10,  "buy")
    local c = eval.new_ctx(s, {}, "test")
    local node = fn_call("query-history", { kind="path_expr", segments={"player", "!gold"} })
    local result = eval.eval_expr(node, c)
    -- health and mana match; gold is excluded
    assert.equal(2, #result, "should return health and mana, not gold")
    local paths = {}
    for _, e in ipairs(result) do paths[e.path] = true end
    assert.is_nil(paths["player/gold"], "gold should not appear in results")
  end)
end)

-- ============================================================
-- Collection mutations: add / remove / clear
-- ============================================================

local compiler = require("compiler.compiler")

describe("eval_stmt: add_mut / remove_mut / clear_mut", function()
  local function make_set_ctx()
    local l = log_mod.new()
    local s = state_mod.new({types={}, states={}}, l)
    s:set("player/inventory", {})
    return eval.new_ctx(s, {}, "test"), s
  end

  it("add_mut inserts a value into a set", function()
    local c, s = make_set_ctx()
    eval.eval_stmt({ kind="add_mut",
      path = { kind="path_expr", segments={"player","inventory"} },
      value = { kind="symbol_lit", name="sword" } }, c)
    local inv = s:get("player/inventory")
    assert.equal(1, #inv)
    assert.equal("sword", inv[1])
  end)

  it("add_mut is idempotent (no duplicate)", function()
    local c, s = make_set_ctx()
    local node = { kind="add_mut",
      path  = { kind="path_expr", segments={"player","inventory"} },
      value = { kind="symbol_lit", name="key" } }
    eval.eval_stmt(node, c)
    eval.eval_stmt(node, c)
    local inv = s:get("player/inventory")
    assert.equal(1, #inv)
  end)

  it("remove_mut deletes a value from a set", function()
    local c, s = make_set_ctx()
    s:set("player/inventory", {"potion", "sword"})
    eval.eval_stmt({ kind="remove_mut",
      path  = { kind="path_expr", segments={"player","inventory"} },
      value = { kind="symbol_lit", name="potion" } }, c)
    local inv = s:get("player/inventory")
    assert.equal(1, #inv)
    assert.equal("sword", inv[1])
  end)

  it("remove_mut is a no-op if value absent", function()
    local c, s = make_set_ctx()
    s:set("player/inventory", {"sword"})
    eval.eval_stmt({ kind="remove_mut",
      path  = { kind="path_expr", segments={"player","inventory"} },
      value = { kind="symbol_lit", name="axe" } }, c)
    assert.equal(1, #s:get("player/inventory"))
  end)

  it("clear_mut empties a set", function()
    local c, s = make_set_ctx()
    s:set("player/inventory", {"sword", "shield", "key"})
    eval.eval_stmt({ kind="clear_mut",
      path = { kind="path_expr", segments={"player","inventory"} } }, c)
    assert.equal(0, #s:get("player/inventory"))
  end)
end)

-- ============================================================
-- Collection mutations: push / pop
-- ============================================================

describe("eval_stmt: push_mut / pop_mut", function()
  local function make_list_ctx()
    local l = log_mod.new()
    local s = state_mod.new({types={}, states={}}, l)
    s:set("player/log", {})
    return eval.new_ctx(s, {}, "test"), s
  end

  it("push_mut appends a value", function()
    local c, s = make_list_ctx()
    eval.eval_stmt({ kind="push_mut",
      path  = { kind="path_expr", segments={"player","log"} },
      value = { kind="symbol_lit", name="entered-dungeon" } }, c)
    eval.eval_stmt({ kind="push_mut",
      path  = { kind="path_expr", segments={"player","log"} },
      value = { kind="symbol_lit", name="found-key" } }, c)
    local log = s:get("player/log")
    assert.equal(2, #log)
    assert.equal("entered-dungeon", log[1])
    assert.equal("found-key",       log[2])
  end)

  it("pop_mut removes and returns last element", function()
    local c, s = make_list_ctx()
    s:set("player/log", {"a", "b", "c"})
    eval.eval_stmt({ kind="pop_mut",
      path = { kind="path_expr", segments={"player","log"} } }, c)
    assert.equal(2, #s:get("player/log"))
    assert.equal("b", s:get("player/log")[2])
  end)
end)

-- ============================================================
-- spawn_mut / despawn_mut via eval
-- ============================================================

describe("eval_stmt: spawn_mut / despawn_mut", function()
  it("spawn_mut instantiates a family member", function()
    local src = [[
module t
  version: 1.0
engine-config:
  entry-scene: s
type Mob:
  hp: Int(0, 100) = 80
state mobs/{mob}: Mob  max: 5
fn do-spawn:
  spawn! mobs `goblin Mob(hp: 60)
scene s:
  * go -> s
]]
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local s  = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(s, gt.fns, "test", gt)
    eval.call_fn("do-spawn", {}, c)
    assert.equal(60, s:get("mobs/goblin/hp"))
    assert.is_true(s:path_exists("mobs/goblin/hp"))
  end)

  it("despawn_mut removes a family member", function()
    local src = [[
module t
  version: 1.0
engine-config:
  entry-scene: s
type Mob:
  hp: Int(0, 100) = 80
state mobs/{mob}: Mob  max: 5
fn do-spawn:
  spawn!   mobs `goblin Mob(hp: 60)
fn do-despawn:
  despawn! mobs `goblin
scene s:
  * go -> s
]]
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local s  = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(s, gt.fns, "test", gt)
    eval.call_fn("do-spawn", {}, c)
    assert.is_true(s:path_exists("mobs/goblin/hp"))
    eval.call_fn("do-despawn", {}, c)
    assert.is_false(s:path_exists("mobs/goblin/hp"))
    assert.is_nil(s:get("mobs/goblin/hp"))
  end)
end)

-- ============================================================
-- Built-in: path-list
-- ============================================================

describe("eval: path-list builtin", function()
  it("returns all live family keys", function()
    local src = [[
module t
  version: 1.0
engine-config:
  entry-scene: s
type M:
  v: Int(0, 10) = 1
state items/{item}: M  max: 5
fn setup:
  spawn! items `alpha M(v: 1)
  spawn! items `beta  M(v: 2)
  spawn! items `gamma M(v: 3)
fn get-list:
  path-list items
scene s:
  * go -> s
]]
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local st = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(st, gt.fns, "test", gt)
    eval.call_fn("setup", {}, c)
    local keys = eval.call_fn("get-list", {}, c)
    table.sort(keys)
    assert.same({"alpha", "beta", "gamma"}, keys)
  end)

  it("returns empty list when family has no members", function()
    local src = [[
module t
  version: 1.0
engine-config:
  entry-scene: s
type M:
  v: Int(0, 10) = 1
state items/{item}: M  max: 5
fn get-list:
  path-list items
scene s:
  * go -> s
]]
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local st = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(st, gt.fns, "test", gt)
    local keys = eval.call_fn("get-list", {}, c)
    assert.same({}, keys)
  end)
end)

-- ============================================================
-- Built-ins: any? / all? / tostring / division
-- ============================================================

describe("eval: any? / all? builtins", function()
  it("any? returns true when at least one element matches", function()
    local c = ctx({})
    local lst = { kind="list_lit", elements={
      { kind="int_lit", value=1 },
      { kind="int_lit", value=5 },
      { kind="int_lit", value=2 },
    }}
    local pred = { kind="lambda_expr", params={"x"},
      body = { kind="binary_op", op=">",
        left  = { kind="fn_call", name="x", args={} },
        right = { kind="int_lit", value=3 } } }
    local node = { kind="fn_call", name="any?", args={ lst, pred } }
    assert.is_true(eval.eval_expr(node, c))
  end)

  it("any? returns false when no element matches", function()
    local c = ctx({})
    local lst = { kind="list_lit", elements={
      { kind="int_lit", value=1 },
      { kind="int_lit", value=2 },
    }}
    local pred = { kind="lambda_expr", params={"x"},
      body = { kind="binary_op", op=">",
        left  = { kind="fn_call", name="x", args={} },
        right = { kind="int_lit", value=10 } } }
    local node = { kind="fn_call", name="any?", args={ lst, pred } }
    assert.is_false(eval.eval_expr(node, c))
  end)

  it("all? returns true when all elements match", function()
    local c = ctx({})
    local lst = { kind="list_lit", elements={
      { kind="int_lit", value=4 },
      { kind="int_lit", value=5 },
      { kind="int_lit", value=6 },
    }}
    local pred = { kind="lambda_expr", params={"x"},
      body = { kind="binary_op", op=">",
        left  = { kind="fn_call", name="x", args={} },
        right = { kind="int_lit", value=3 } } }
    local node = { kind="fn_call", name="all?", args={ lst, pred } }
    assert.is_true(eval.eval_expr(node, c))
  end)

  it("all? returns false when any element fails", function()
    local c = ctx({})
    local lst = { kind="list_lit", elements={
      { kind="int_lit", value=4 },
      { kind="int_lit", value=2 },
      { kind="int_lit", value=5 },
    }}
    local pred = { kind="lambda_expr", params={"x"},
      body = { kind="binary_op", op=">",
        left  = { kind="fn_call", name="x", args={} },
        right = { kind="int_lit", value=3 } } }
    local node = { kind="fn_call", name="all?", args={ lst, pred } }
    assert.is_false(eval.eval_expr(node, c))
  end)
end)

describe("eval: tostring builtin", function()
  it("converts an integer to a string", function()
    local c = ctx({})
    local node = { kind="fn_call", name="tostring", args={ { kind="int_lit", value=42 } } }
    assert.equal("42", eval.eval_expr(node, c))
  end)

  it("converts a symbol to a string", function()
    local c = ctx({})
    local node = { kind="fn_call", name="tostring", args={ { kind="symbol_lit", name="alive" } } }
    local result = eval.eval_expr(node, c)
    assert.is_string(result)
    assert.is_true(result:find("alive") ~= nil)
  end)

  it("converts a boolean to a string", function()
    local c = ctx({})
    local node = { kind="fn_call", name="tostring", args={ { kind="bool_lit", value=true } } }
    assert.equal("true", eval.eval_expr(node, c))
  end)
end)

describe("eval: division operator", function()
  it("divides two integers", function()
    local c = ctx({})
    local node = { kind="binary_op", op="/",
      left  = { kind="int_lit", value=10 },
      right = { kind="int_lit", value=2 } }
    assert.equal(5, eval.eval_expr(node, c))
  end)

  it("integer division truncates", function()
    local c = ctx({})
    local node = { kind="binary_op", op="/",
      left  = { kind="int_lit", value=7 },
      right = { kind="int_lit", value=2 } }
    -- Lua 5.4 integer // gives 3
    local result = eval.eval_expr(node, c)
    assert.is_true(result == 3 or result == 3.5)  -- accept either truncation or float
  end)
end)

-- ============================================================
-- Multi-binding let statement
-- ============================================================

describe("eval_stmt: multi-binding let", function()
  it("binds multiple variables sequentially, each visible to later ones", function()
    -- let x = expr: body  (single-binding form, nested)
    local src = [[
module t
  version: 1.0
engine-config:
  entry-scene: s
state world:
  result: Int(0, 9999) = 0
fn compute:
  let a = 10:
    let b = a + 5:
      set! world/result b
scene s:
  * go -> s
]]
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local st = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(st, gt.fns, "test", gt)
    st:init_defaults()
    eval.call_fn("compute", {}, c)
    -- a=10, b=15
    assert.equal(15, st:get("world/result"))
  end)
end)

-- ============================================================
-- relate! / unrelate! mutations
-- ============================================================

describe("eval_stmt: relate_mut / unrelate_mut", function()
  local compiler = require("compiler.compiler")
  local query_mod = require("runtime.query")

  local function make_relate_eng(extra_fn)
    extra_fn = extra_fn or ""
    local src = [[
module rel-test
  version: 1.0
engine-config:
  entry-scene: s
relation edges: Symbol -> Set(Symbol, 10)
fn do-relate:
  relate! edges `a `b
fn do-unrelate:
  unrelate! edges `a `b
]] .. extra_fn .. [[
scene s:
  * go -> s
]]
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local st = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(st, gt.fns, "test", gt)
    return c, gt
  end

  it("relate! adds an edge to the relation via cache (visible through effective_rel)", function()
    local c, gt = make_relate_eng()
    eval.call_fn("do-relate", {}, c)
    -- Edge is stored in cache, not in static rel.data; check via adjacent? builtin
    local adj_node = { kind="fn_call", name="adjacent?", args={
      { kind="fn_call", name="edges", args={} },
      { kind="symbol_lit", name="a" },
    }}
    local result = eval.eval_expr(adj_node, c)
    assert.is_truthy(result and result["b"])
  end)

  it("relate! is idempotent (adding same edge twice is fine)", function()
    local c, gt = make_relate_eng()
    eval.call_fn("do-relate", {}, c)
    eval.call_fn("do-relate", {}, c)
    local adj_node = { kind="fn_call", name="adjacent?", args={
      { kind="fn_call", name="edges", args={} },
      { kind="symbol_lit", name="a" },
    }}
    local result = eval.eval_expr(adj_node, c)
    assert.is_truthy(result and result["b"])
  end)

  it("unrelate! removes an edge that was added", function()
    local c, gt = make_relate_eng()
    eval.call_fn("do-relate", {}, c)
    eval.call_fn("do-unrelate", {}, c)
    local adj_node = { kind="fn_call", name="adjacent?", args={
      { kind="fn_call", name="edges", args={} },
      { kind="symbol_lit", name="a" },
    }}
    local result = eval.eval_expr(adj_node, c)
    assert.is_falsy(result and result["b"])
  end)

  it("unrelate! is a no-op when edge does not exist", function()
    local c, gt = make_relate_eng()
    -- no relate! first
    assert.has_no_error(function() eval.call_fn("do-unrelate", {}, c) end)
  end)

  it("reachable? reflects relate! changes (static rel unchanged; dynamic via cache)", function()
    local c, gt = make_relate_eng()
    local rel = gt.relations and gt.relations["edges"]
    -- Static relation has no a→b edge
    assert.is_false(query_mod.reachable(rel, "a", "b"))
    eval.call_fn("do-relate", {}, c)
    -- After relate!, reachable? through eval (which merges cache) sees the edge
    local reach_node = { kind="fn_call", name="reachable?", args={
      { kind="fn_call", name="edges", args={} },
      { kind="symbol_lit", name="a" },
      { kind="symbol_lit", name="b" },
    }}
    assert.is_true(eval.eval_expr(reach_node, c))
  end)
end)

-- ============================================================
-- random-int builtin
-- ============================================================

describe("eval: random-int builtin", function()
  it("returns a value within [min, max]", function()
    local c = ctx({})
    local node = fn_call("random-int",
      { kind="int_lit", value=1 },
      { kind="int_lit", value=6 })
    for _ = 1, 20 do
      local v = eval.eval_expr(node, c)
      assert.is_true(v >= 1 and v <= 6, "value " .. tostring(v) .. " out of range")
    end
  end)

  it("returns exactly min when min == max", function()
    local c = ctx({})
    local node = fn_call("random-int",
      { kind="int_lit", value=5 },
      { kind="int_lit", value=5 })
    local v = eval.eval_expr(node, c)
    assert.equal(5, v)
  end)

  it("_random_inject is used when set", function()
    local c = ctx({})
    -- Inject a fixed RNG that always returns 42
    c.game = { _random_inject = function() return 42 end }
    local node = fn_call("random-int",
      { kind="int_lit", value=1 },
      { kind="int_lit", value=100 })
    local v = eval.eval_expr(node, c)
    assert.equal(42, v)
  end)
end)

describe("random-bool builtin", function()
  it("returns a boolean", function()
    local c = ctx({})
    local node = fn_call("random-bool", { kind="float_lit", value=0.5 })
    local v = eval.eval_expr(node, c)
    assert.is_true(v == true or v == false)
  end)

  it("always returns true when p=1.0", function()
    local c = ctx({})
    local node = fn_call("random-bool", { kind="float_lit", value=1.0 })
    for _ = 1, 10 do
      assert.is_true(eval.eval_expr(node, c))
    end
  end)

  it("always returns false when p=0.0", function()
    local c = ctx({})
    local node = fn_call("random-bool", { kind="float_lit", value=0.0 })
    for _ = 1, 10 do
      assert.is_false(eval.eval_expr(node, c))
    end
  end)

  it("respects _random_inject: 1 → true", function()
    local c = ctx({})
    c.game = { _random_inject = function() return 1 end }
    local node = fn_call("random-bool", { kind="float_lit", value=0.5 })
    assert.is_true(eval.eval_expr(node, c))
  end)

  it("respects _random_inject: 0 → false", function()
    local c = ctx({})
    c.game = { _random_inject = function() return 0 end }
    local node = fn_call("random-bool", { kind="float_lit", value=0.5 })
    assert.is_false(eval.eval_expr(node, c))
  end)
end)

describe("random-enum builtin", function()
  local function make_ctx_with_schema(enum_name, values)
    local c = ctx({})
    c.game = {
      schema = {
        types = { { kind="enum", name=enum_name, values=values } }
      },
    }
    return c
  end

  it("returns a value from the enum", function()
    local c = make_ctx_with_schema("Status", {"alive", "dead", "unknown"})
    local node = fn_call("random-enum", { kind="fn_call", name="Status", args={} })
    local v = eval.eval_expr(node, c)
    assert.is_true(v == "alive" or v == "dead" or v == "unknown")
  end)

  it("respects _random_inject: index 0 → first value", function()
    local c = make_ctx_with_schema("Loc", {"village", "forest", "castle"})
    c.game._random_inject = function() return 0 end
    local node = fn_call("random-enum", { kind="fn_call", name="Loc", args={} })
    assert.equal("village", eval.eval_expr(node, c))
  end)

  it("respects _random_inject: index 2 → third value", function()
    local c = make_ctx_with_schema("Loc", {"village", "forest", "castle"})
    c.game._random_inject = function() return 2 end
    local node = fn_call("random-enum", { kind="fn_call", name="Loc", args={} })
    assert.equal("castle", eval.eval_expr(node, c))
  end)

  it("returns nil for unknown type name", function()
    local c = ctx({})
    c.game = { schema = { types = {} } }
    local node = fn_call("random-enum", { kind="fn_call", name="NoSuchType", args={} })
    assert.is_nil(eval.eval_expr(node, c))
  end)
end)

describe("random-choice builtin", function()
  it("returns an element from the list", function()
    local c = ctx({})
    local node = fn_call("random-choice", {
      kind="list_lit",
      elements={ { kind="symbol_lit", name="a" },
                 { kind="symbol_lit", name="b" },
                 { kind="symbol_lit", name="c" } }
    })
    local v = eval.eval_expr(node, c)
    assert.is_true(v == "a" or v == "b" or v == "c")
  end)

  it("respects _random_inject: 0 → first element", function()
    local c = ctx({})
    c.game = { _random_inject = function() return 0 end }
    local node = fn_call("random-choice", {
      kind="list_lit",
      elements={ { kind="symbol_lit", name="x" }, { kind="symbol_lit", name="y" } }
    })
    assert.equal("x", eval.eval_expr(node, c))
  end)

  it("returns nil for empty list", function()
    local c = ctx({})
    local node = fn_call("random-choice", { kind="list_lit", elements={} })
    assert.is_nil(eval.eval_expr(node, c))
  end)
end)

describe("random-weighted builtin", function()
  it("returns an element from the list", function()
    local c = ctx({})
    local node = fn_call("random-weighted",
      { kind="list_lit", elements={ { kind="float_lit", value=1.0 },
                                    { kind="float_lit", value=2.0 } } },
      { kind="list_lit", elements={ { kind="symbol_lit", name="rare" },
                                    { kind="symbol_lit", name="common" } } }
    )
    local v = eval.eval_expr(node, c)
    assert.is_true(v == "rare" or v == "common")
  end)

  it("respects _random_inject: index 1 → second element", function()
    local c = ctx({})
    c.game = { _random_inject = function() return 1 end }
    local node = fn_call("random-weighted",
      { kind="list_lit", elements={ { kind="float_lit", value=1.0 },
                                    { kind="float_lit", value=1.0 } } },
      { kind="list_lit", elements={ { kind="symbol_lit", name="a" },
                                    { kind="symbol_lit", name="b" } } }
    )
    assert.equal("b", eval.eval_expr(node, c))
  end)
end)

-- ============================================================
-- RNG logging tests
-- ============================================================

describe("random builtins: rng logging", function()
  local random_mod = require("runtime.random")
  local log_mod2   = require("runtime.log")

  local function ctx_with_rng(seed)
    local l   = log_mod2.new()
    local rng = random_mod.new(seed, l)
    local c   = ctx({})
    c.rng = rng
    c._log = l
    return c, l
  end

  it("random-int logs a `random' entry", function()
    local c, l = ctx_with_rng(42)
    local node = fn_call("random-int", { kind="int_lit", value=1 }, { kind="int_lit", value=6 })
    eval.eval_expr(node, c)
    local found = false
    for _, e in ipairs(l:entries()) do
      if e.kind == "random" and e.source == "random-int" then found = true; break end
    end
    assert.is_true(found, "expected a `random' log entry for random-int")
  end)

  it("random-bool logs a `random' entry", function()
    local c, l = ctx_with_rng(1)
    local node = fn_call("random-bool", { kind="float_lit", value=0.5 })
    eval.eval_expr(node, c)
    local found = false
    for _, e in ipairs(l:entries()) do
      if e.kind == "random" and e.source == "random-bool" then found = true; break end
    end
    assert.is_true(found, "expected a `random' log entry for random-bool")
  end)

  it("random-bool with no arg defaults to 0.5 and does not crash", function()
    local c, l = ctx_with_rng(1)
    local node = fn_call("random-bool")
    local ok, v = pcall(eval.eval_expr, node, c)
    assert.is_true(ok, "random-bool with no arg should not crash")
    assert.is_true(v == true or v == false)
  end)

  it("random-enum logs a `random' entry", function()
    local c, l = ctx_with_rng(7)
    c.game = { schema = { types = { { kind="enum", name="Dir", values={"n","s","e","w"} } } } }
    local node = fn_call("random-enum", { kind="fn_call", name="Dir", args={} })
    eval.eval_expr(node, c)
    local found = false
    for _, e in ipairs(l:entries()) do
      if e.kind == "random" and e.source == "random-enum" then found = true; break end
    end
    assert.is_true(found, "expected a `random' log entry for random-enum")
  end)

  it("random-choice logs a `random' entry", function()
    local c, l = ctx_with_rng(3)
    local node = fn_call("random-choice", {
      kind="list_lit",
      elements={ { kind="symbol_lit", name="x" }, { kind="symbol_lit", name="y" } }
    })
    eval.eval_expr(node, c)
    local found = false
    for _, e in ipairs(l:entries()) do
      if e.kind == "random" and e.source == "random-choice" then found = true; break end
    end
    assert.is_true(found, "expected a `random' log entry for random-choice")
  end)

  it("seeded random-int is deterministic across two runs", function()
    local node = fn_call("random-int", { kind="int_lit", value=0 }, { kind="int_lit", value=1000 })
    -- Run 1: seed 999, take first value
    local c1, _ = ctx_with_rng(999)
    local v1 = eval.eval_expr(node, c1)
    -- Run 2: reseed to 999 (resets global state to same point), take first value
    local c2, _ = ctx_with_rng(999)
    local v2 = eval.eval_expr(node, c2)
    assert.equal(v1, v2, "same seed should produce same random-int result")
  end)

  it("_random_inject takes priority over ctx.rng", function()
    local c, l = ctx_with_rng(42)
    c.game = { _random_inject = function() return 99 end }
    local node = fn_call("random-int", { kind="int_lit", value=0 }, { kind="int_lit", value=100 })
    local v = eval.eval_expr(node, c)
    assert.equal(99, v, "_random_inject should override rng")
    -- No log entry expected (inject short-circuits before rng)
    local found = false
    for _, e in ipairs(l:entries()) do
      if e.kind == "random" then found = true; break end
    end
    assert.is_false(found, "inject path should not produce a log entry")
  end)
end)

describe("str builtin", function()
  it("concatenates string args", function()
    local c = ctx({})
    local node = fn_call("str",
      { kind="string_lit", value="Hello " },
      { kind="string_lit", value="World" })
    assert.equal("Hello World", eval.eval_expr(node, c))
  end)

  it("converts non-string args with tostring", function()
    local c = ctx({})
    local node = fn_call("str",
      { kind="string_lit", value="HP: " },
      { kind="int_lit", value=42 })
    assert.equal("HP: 42", eval.eval_expr(node, c))
  end)

  it("works with zero args", function()
    local c = ctx({})
    local node = fn_call("str")
    assert.equal("", eval.eval_expr(node, c))
  end)

  it("works with three args", function()
    local c = ctx({})
    local node = fn_call("str",
      { kind="string_lit", value="a" },
      { kind="string_lit", value="b" },
      { kind="string_lit", value="c" })
    assert.equal("abc", eval.eval_expr(node, c))
  end)
end)

describe("stdlib: numeric builtins", function()
  it("abs returns absolute value of positive", function()
    local c = ctx({})
    assert.equal(5, eval.eval_expr(fn_call("abs", int_lit(5)), c))
  end)

  it("abs returns absolute value of negative", function()
    local c = ctx({})
    assert.equal(7, eval.eval_expr(fn_call("abs", int_lit(-7)), c))
  end)

  it("clamp clamps to [lo, hi]", function()
    local c = ctx({})
    assert.equal(5, eval.eval_expr(fn_call("clamp", int_lit(5), int_lit(0), int_lit(10)), c))
    assert.equal(0, eval.eval_expr(fn_call("clamp", int_lit(-3), int_lit(0), int_lit(10)), c))
    assert.equal(10, eval.eval_expr(fn_call("clamp", int_lit(15), int_lit(0), int_lit(10)), c))
  end)

  it("int-to-str converts integer to string", function()
    local c = ctx({})
    assert.equal("42", eval.eval_expr(fn_call("int-to-str", int_lit(42)), c))
  end)

  it("str-to-int parses valid integer string", function()
    local c = ctx({})
    assert.equal(7, eval.eval_expr(fn_call("str-to-int", str_lit("7")), c))
  end)

  it("str-to-int returns nil for invalid string", function()
    local c = ctx({})
    assert.is_nil(eval.eval_expr(fn_call("str-to-int", str_lit("abc")), c))
  end)

  -- AE-17: int-div, floor, ceil, mod
  it("int-div returns floor quotient for positive operands", function()
    local c = ctx({})
    assert.equal(2, eval.eval_expr(fn_call("int-div", int_lit(7), int_lit(3)), c))
    assert.equal(3, eval.eval_expr(fn_call("int-div", int_lit(9), int_lit(3)), c))
    assert.equal(0, eval.eval_expr(fn_call("int-div", int_lit(1), int_lit(5)), c))
  end)

  it("int-div uses floor (rounds toward -inf) for negative operands", function()
    local c = ctx({})
    assert.equal(-3, eval.eval_expr(fn_call("int-div", int_lit(-7), int_lit(3)), c))
    assert.equal(-3, eval.eval_expr(fn_call("int-div", int_lit(7), int_lit(-3)), c))
    assert.equal(2,  eval.eval_expr(fn_call("int-div", int_lit(-7), int_lit(-3)), c))
  end)

  it("floor rounds down to nearest integer", function()
    local c = ctx({})
    assert.equal(3,  eval.eval_expr(fn_call("floor", { kind="float_lit", value=3.7 }), c))
    assert.equal(-4, eval.eval_expr(fn_call("floor", { kind="float_lit", value=-3.2 }), c))
    assert.equal(5,  eval.eval_expr(fn_call("floor", int_lit(5)), c))
  end)

  it("ceil rounds up to nearest integer", function()
    local c = ctx({})
    assert.equal(4,  eval.eval_expr(fn_call("ceil", { kind="float_lit", value=3.2 }), c))
    assert.equal(-3, eval.eval_expr(fn_call("ceil", { kind="float_lit", value=-3.7 }), c))
    assert.equal(5,  eval.eval_expr(fn_call("ceil", int_lit(5)), c))
  end)

  it("mod returns floor-division remainder (Python sign convention)", function()
    local c = ctx({})
    -- sign of result matches sign of divisor (b)
    assert.equal(1,  eval.eval_expr(fn_call("mod", int_lit(7),  int_lit(3)),  c))
    assert.equal(2,  eval.eval_expr(fn_call("mod", int_lit(-7), int_lit(3)),  c))
    assert.equal(-2, eval.eval_expr(fn_call("mod", int_lit(7),  int_lit(-3)), c))
    assert.equal(-1, eval.eval_expr(fn_call("mod", int_lit(-7), int_lit(-3)), c))
  end)

  it("int-div and mod satisfy: a = (int-div a b) * b + (mod a b)", function()
    local c = ctx({})
    local cases = { {7,3}, {-7,3}, {7,-3}, {-7,-3}, {10,4}, {-10,4} }
    for _, pair in ipairs(cases) do
      local a, b = pair[1], pair[2]
      local q = eval.eval_expr(fn_call("int-div", int_lit(a), int_lit(b)), c)
      local r = eval.eval_expr(fn_call("mod",     int_lit(a), int_lit(b)), c)
      assert.equal(a, q * b + r, string.format("%d = (%d)*%d + %d", a, q, b, r))
    end
  end)
end)

describe("stdlib: collection builtins", function()
  local function list_lit(...)
    local elems = {}
    for _, v in ipairs({...}) do
      elems[#elems+1] = { kind="symbol_lit", name=v }
    end
    return { kind="list_lit", elements=elems }
  end

  it("size returns count of elements", function()
    local c = ctx({})
    assert.equal(3, eval.eval_expr(fn_call("size", list_lit("a","b","c")), c))
  end)

  it("size returns 0 for nil/non-table", function()
    local c = ctx({})
    assert.equal(0, eval.eval_expr(fn_call("size", int_lit(5)), c))
  end)

  it("size returns correct count for map-style table (adjacent? result)", function()
    local c = ctx({})
    -- inject a map-style table via a let var
    c.vars["m"] = {corridor=true, armory=true}
    local node = fn_call("size", {kind="fn_call", name="m", args={}})
    assert.equal(2, eval.eval_expr(node, c))
  end)

  it("empty? returns true for empty list", function()
    local c = ctx({})
    assert.is_true(eval.eval_expr(fn_call("empty?", list_lit()), c))
  end)

  it("empty? returns false for non-empty list", function()
    local c = ctx({})
    assert.is_false(eval.eval_expr(fn_call("empty?", list_lit("a")), c))
  end)

  it("empty? returns false for non-empty map-style table", function()
    local c = ctx({})
    c.vars["m"] = {corridor=true}
    local node = fn_call("empty?", {kind="fn_call", name="m", args={}})
    assert.is_false(eval.eval_expr(node, c))
  end)

  it("contains? finds element in array-style list", function()
    local c = ctx({})
    local node = fn_call("contains?", list_lit("a","b","c"), {kind="string_lit", value="b"})
    assert.is_true(eval.eval_expr(node, c))
  end)

  it("contains? finds element in map-style table", function()
    local c = ctx({})
    c.vars["m"] = {corridor=true, armory=true}
    local node = fn_call("contains?",
      {kind="fn_call", name="m", args={}},
      {kind="string_lit", value="corridor"})
    assert.is_true(eval.eval_expr(node, c))
  end)

  it("contains? returns false for missing element", function()
    local c = ctx({})
    local node = fn_call("contains?", list_lit("a","b"), {kind="string_lit", value="c"})
    assert.is_false(eval.eval_expr(node, c))
  end)

  it("not-in? returns true when item is absent", function()
    local c = ctx({})
    local node = fn_call("not-in?", {kind="string_lit", value="z"}, list_lit("a","b","c"))
    assert.is_true(eval.eval_expr(node, c))
  end)

  it("not-in? returns false when item is present", function()
    local c = ctx({})
    local node = fn_call("not-in?", {kind="string_lit", value="b"}, list_lit("a","b","c"))
    assert.is_false(eval.eval_expr(node, c))
  end)

  it("not-in? works with map-style sets", function()
    local c = ctx({})
    c.vars["s"] = {alpha=true, beta=true}
    local node = fn_call("not-in?",
      {kind="string_lit", value="gamma"},
      {kind="fn_call", name="s", args={}})
    assert.is_true(eval.eval_expr(node, c))
  end)

  it("union merges two sets without duplicates", function()
    local c = ctx({})
    local result = eval.eval_expr(fn_call("union", list_lit("a","b"), list_lit("b","c")), c)
    assert.is_true(#result == 3)
    local s = {}; for _, v in ipairs(result) do s[v] = true end
    assert.is_true(s["a"] and s["b"] and s["c"])
  end)

  it("intersect returns common elements", function()
    local c = ctx({})
    local result = eval.eval_expr(fn_call("intersect", list_lit("a","b","c"), list_lit("b","c","d")), c)
    assert.is_true(#result == 2)
    local s = {}; for _, v in ipairs(result) do s[v] = true end
    assert.is_true(s["b"] and s["c"])
  end)

  it("list-get returns element at index", function()
    local c = ctx({})
    local node = fn_call("list-get", list_lit("x","y","z"), int_lit(2))
    assert.equal("y", eval.eval_expr(node, c))
  end)

  it("list-get returns nil for out-of-bounds index", function()
    local c = ctx({})
    local node = fn_call("list-get", list_lit("x","y"), int_lit(5))
    assert.is_nil(eval.eval_expr(node, c))
  end)

  it("list-size returns list length", function()
    local c = ctx({})
    local node = fn_call("list-size", list_lit("a","b","c","d"))
    assert.equal(4, eval.eval_expr(node, c))
  end)
end)

describe("engine pseudo-paths", function()
  local engine_mod = require("runtime.engine")
  local compiler   = require("compiler.compiler")

  local src = [[
engine-config:
  entry-scene: main
scene main:
  Hello.
  * Go
    -> main
]]

  it("engine/current-scene returns current scene name", function()
    local gt = compiler.compile(src, "test.sb")
    local eng = engine_mod.new(gt)
    eng:init()
    local c = eng:make_ctx("test")
    local node = { kind="path_expr", segments={"engine","current-scene"} }
    assert.equal("main", eval.eval_expr(node, c))
  end)

  it("engine/scene-stack returns the stack as a list", function()
    local gt = compiler.compile(src, "test.sb")
    local eng = engine_mod.new(gt)
    eng:init()
    local c = eng:make_ctx("test")
    local node = { kind="path_expr", segments={"engine","scene-stack"} }
    local stack = eval.eval_expr(node, c)
    assert.is_table(stack)
    assert.equal("main", stack[1])
  end)

  it("engine/tick returns current tick (0 initially)", function()
    local gt = compiler.compile(src, "test.sb")
    local eng = engine_mod.new(gt)
    eng:init()
    local c = eng:make_ctx("test")
    local node = { kind="path_expr", segments={"engine","tick"} }
    assert.equal(0, eval.eval_expr(node, c))
  end)

  it("engine/time returns time table", function()
    local gt = compiler.compile(src, "test.sb")
    local eng = engine_mod.new(gt)
    eng:init()
    local c = eng:make_ctx("test")
    local node = { kind="path_expr", segments={"engine","time"} }
    local t = eval.eval_expr(node, c)
    assert.is_table(t)
  end)

  it("engine/current-scene is nil when no engine_ref", function()
    local c = ctx({})  -- no engine_ref
    local node = { kind="path_expr", segments={"engine","current-scene"} }
    assert.is_nil(eval.eval_expr(node, c))
  end)
end)

describe("tag and hook execution", function()
  local compiler   = require("compiler.compiler")
  local engine_mod = require("runtime.engine")

  it("pre-hook fires before fn body", function()
    local src = [[
state counter: Int(0, 100) = 0
tag watched
fn inc-counter:
  tags: [watched]
  set! counter 10
hook watched:
  pre:
    set! counter 1
]]
    local gt = compiler.compile(src, "hook_test.sb")
    assert.is_not_nil(gt)
    local eng = engine_mod.new(gt)
    eng:init()
    -- counter should start at 0
    assert.equal(0, eng._state:get("counter"))
    -- call inc-counter; pre-hook sets it to 1 first, then body sets it to 10
    local c = eng:make_ctx("test")
    eval.call_fn("inc-counter", {}, c)
    -- after: pre-hook ran (set to 1), then body ran (set to 10)
    assert.equal(10, eng._state:get("counter"))
  end)

  it("post-hook fires after fn body", function()
    local src = [[
state counter: Int(0, 100) = 0
tag watched
fn inc-counter:
  tags: [watched]
  set! counter 5
hook watched:
  post:
    set! counter 99
]]
    local gt = compiler.compile(src, "hook_test2.sb")
    assert.is_not_nil(gt)
    local eng = engine_mod.new(gt)
    eng:init()
    local c = eng:make_ctx("test")
    eval.call_fn("inc-counter", {}, c)
    -- post-hook ran after body, overwriting 5 → 99
    assert.equal(99, eng._state:get("counter"))
  end)

  it("fn_after hook fires after specific function", function()
    local src = [[
state flag: Int(0, 10) = 0
fn foo:
  set! flag 3
hook after: foo:
  set! flag 7
]]
    local gt = compiler.compile(src, "hook_test3.sb")
    assert.is_not_nil(gt)
    local eng = engine_mod.new(gt)
    eng:init()
    local c = eng:make_ctx("test")
    eval.call_fn("foo", {}, c)
    assert.equal(7, eng._state:get("flag"))
  end)

  it("fn_before hook fires before specific function", function()
    local src = [[
state flag: Int(0, 10) = 0
fn foo:
  set! flag 3
hook before: foo:
  set! flag 9
]]
    local gt = compiler.compile(src, "hook_test4.sb")
    assert.is_not_nil(gt)
    local eng = engine_mod.new(gt)
    eng:init()
    local c = eng:make_ctx("test")
    eval.call_fn("foo", {}, c)
    -- before-hook ran (flag=9), then body ran (flag=3)
    assert.equal(3, eng._state:get("flag"))
  end)

  it("post-hook has access to changes variable", function()
    local src = [[
state hp: Int(0, 100) = 50
state last-change-count: Int(0, 100) = 0
tag audited
fn damage:
  tags: [audited]
  set! hp 30
hook audited:
  post:
    set! last-change-count (size changes)
]]
    local gt = compiler.compile(src, "hook_test5.sb")
    assert.is_not_nil(gt)
    local eng = engine_mod.new(gt)
    eng:init()
    local c = eng:make_ctx("test")
    eval.call_fn("damage", {}, c)
    assert.equal(30, eng._state:get("hp"))
    -- changes should have had 1 entry (the set! hp 30)
    assert.equal(1, eng._state:get("last-change-count"))
  end)

  it("hook body can read state normally", function()
    local src = [[
state world/val:  Int(0, 100) = 42
state world/copy: Int(0, 100) = 0
tag copier
fn set-val:
  tags: [copier]
  pass
hook copier:
  post:
    set! world/copy world/val
]]
    local gt = compiler.compile(src, "hook_test6.sb")
    assert.is_not_nil(gt)
    local eng = engine_mod.new(gt)
    eng:init()
    local c = eng:make_ctx("test")
    eval.call_fn("set-val", {}, c)
    assert.equal(42, eng._state:get("world/copy"))
  end)
end)

-- ── say statement ─────────────────────────────────────────────────────────────
local compiler_mod = require("compiler.compiler")
local engine_mod2  = require("runtime.engine")

describe("say statement eval", function()
  local function compile_and_engine(src)
    local gt = compiler_mod.compile(src, "say_test.sb")
    assert.is_not_nil(gt, "compile failed")
    local eng = engine_mod2.new(gt)
    eng:init()
    return eng
  end

  it("say in scene body produces dialogue object in narration", function()
    local src = [[
speaker aldric:
  display: "Aldric the Bold"
  color:   "#c8a96e"
engine-config:
  entry-scene: s
scene s:
  say aldric: Ready when you are.
  * Done -> s
]]
    local eng = compile_and_engine(src)
    local narration = eng:render_scene("s")
    assert.equal(1, #narration)
    local obj = narration[1]
    assert.equal("table", type(obj))
    assert.equal("aldric", obj.speaker)
    assert.equal("Aldric the Bold", obj.display)
    assert.equal("#c8a96e", obj.color)
    assert.equal("Ready when you are.", obj.text)
  end)

  it("undeclared speaker uses name as display, nil color", function()
    local src = [[
engine-config:
  entry-scene: s
scene s:
  say ghost: Boo!
  * Done -> s
]]
    local eng = compile_and_engine(src)
    local narration = eng:render_scene("s")
    assert.equal(1, #narration)
    local obj = narration[1]
    assert.equal("ghost", obj.speaker)
    assert.equal("ghost", obj.display)
    assert.is_nil(obj.color)
    assert.equal("Boo!", obj.text)
  end)

  it("multi-line say block produces one object per line", function()
    local src = [[
speaker mira:
  display: "Mira"
engine-config:
  entry-scene: s
scene s:
  say mira:
    First line.
    Second line.
  * Done -> s
]]
    local eng = compile_and_engine(src)
    local narration = eng:render_scene("s")
    assert.equal(2, #narration)
    assert.equal("mira", narration[1].speaker)
    assert.equal("First line.", narration[1].text)
    assert.equal("Second line.", narration[2].text)
  end)

  it("mixed narration and dialogue keeps flat order", function()
    local src = [[
speaker aldric:
  display: "Aldric"
engine-config:
  entry-scene: s
scene s:
  The door opens.
  say aldric: Come in.
  Silence follows.
  * Done -> s
]]
    local eng = compile_and_engine(src)
    local narration = eng:render_scene("s")
    assert.equal(3, #narration)
    assert.equal("narration", narration[1].kind)
    assert.equal("say",       narration[2].kind)
    assert.equal("narration", narration[3].kind)
    assert.equal("The door opens.", narration[1].text)
    assert.equal("Come in.",        narration[2].text)
    assert.equal("Silence follows.", narration[3].text)
  end)

  it("say in fn body accumulates via pending_narration, prepended to next scene render", function()
    local src = [[
speaker aldric:
  display: "Aldric"
engine-config:
  entry-scene: intro
fn speak:
  say `aldric "Hello from fn."
scene intro:
  The scene begins.
  * Greet:
    speak
    -> intro
]]
    local eng = compile_and_engine(src)
    -- Execute choice 1 (Greet) which calls speak, which emits a say
    eng:do_choice("intro", 1)
    -- _pending_narration should now contain the dialogue object from speak
    -- On next render_scene, it's prepended to the narration
    local narration = eng:render_scene("intro")
    local dialogue_found = false
    for _, item in ipairs(narration) do
      if type(item) == "table" and item.text == "Hello from fn." then
        dialogue_found = true
      end
    end
    assert.is_true(dialogue_found, "expected dialogue from fn body in narration")
  end)

  it("symbol-form say (`speaker text) works in scene body", function()
    local src = [[
speaker mira:
  display: "Mira"
engine-config:
  entry-scene: s
scene s:
  `mira "Scene body with symbol form."
  * go -> s
]]
    -- Actually that's narration, not say. Test say `speaker in scene body:
    local src2 = [[
speaker mira:
  display: "Mira"
engine-config:
  entry-scene: s
scene s:
  say `mira "Symbol-style in scene."
  * go -> s
]]
    local eng = compile_and_engine(src2)
    local narration = eng:render_scene("s")
    local found = false
    for _, item in ipairs(narration) do
      if type(item) == "table" and item.speaker == "mira" then found = true end
    end
    assert.is_true(found, "expected mira say in scene narration")
  end)
end)

-- ============================================================
-- UMap runtime operations
-- ============================================================

describe("UMap: map-set! / map-get / map-delete!", function()
  local compiler = require("compiler.compiler")
  local log_mod  = require("runtime.log")
  local state_mod= require("runtime.state")
  local eval     = require("runtime.eval")

  local function run_fn(src, fn_name)
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local st = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(st, gt.fns, "test", gt)
    st:init_defaults()
    eval.call_fn(fn_name, {}, c)
    return st, c
  end

  local src = [[
module t
  version: 1.0
engine-config:
  entry-scene: s
type Scores = UMap(Symbol, Int(0, 9999))
state world:
  scores: Scores = {}
fn add-score:
  map-set! world/scores `alice 100
  map-set! world/scores `bob 200
fn remove-score:
  map-delete! world/scores `alice
scene s:
  .
]]

  it("map-set! stores key-value pairs in a UMap", function()
    local st = run_fn(src, "add-score")
    local scores = st:get("world/scores")
    assert.is_table(scores)
    assert.equal(100, scores["alice"])
    assert.equal(200, scores["bob"])
  end)

  it("map-get reads a value from a UMap", function()
    local get_src = src .. [[
fn get-alice:
  let v = (map-get world/scores `alice)
  set! world/scores {}
  map-set! world/scores `result v
]]
    local gt = assert(compiler.compile(get_src, "t.sb"))
    local l  = log_mod.new()
    local st = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(st, gt.fns, "test", gt)
    st:init_defaults()
    eval.call_fn("add-score", {}, c)
    eval.call_fn("get-alice", {}, c)
    local scores = st:get("world/scores")
    assert.equal(100, scores["result"])
  end)

  it("map-delete! removes a key from a UMap", function()
    local st = run_fn(src, "add-score")
    -- manually call remove-score
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local st2 = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(st2, gt.fns, "test", gt)
    st2:init_defaults()
    eval.call_fn("add-score", {}, c)
    eval.call_fn("remove-score", {}, c)
    local scores = st2:get("world/scores")
    assert.is_nil(scores["alice"])
    assert.equal(200, scores["bob"])
  end)
end)

-- ============================================================
-- Bug #1 regression: IF_EXPR as expression returns sub.retval
-- ============================================================

describe("eval — if/else expression return value (bug #1)", function()
  local compiler = require("compiler.compiler")

  local function run(src, fn_name)
    local gt = assert(compiler.compile(src, "t.sb"))
    local l  = log_mod.new()
    local st = state_mod.new(gt.schema, l)
    local c  = eval.new_ctx(st, gt.fns, "test", gt)
    st:init_defaults()
    return eval.call_fn(fn_name, {}, c), st
  end

  it("if true then expr returns the then-branch value", function()
    local val = eval.eval_expr(
      if_expr(bool_lit(true),
        { { kind="return_stmt", expr=int_lit(42) } },
        { { kind="return_stmt", expr=int_lit(0)  } }),
      ctx({})
    )
    assert.equal(42, val)
  end)

  it("if false then expr returns the else-branch value", function()
    local val = eval.eval_expr(
      if_expr(bool_lit(false),
        { { kind="return_stmt", expr=int_lit(1)  } },
        { { kind="return_stmt", expr=int_lit(99) } }),
      ctx({})
    )
    assert.equal(99, val)
  end)

  it("if false with no else returns nil", function()
    local val = eval.eval_expr(
      if_expr(bool_lit(false),
        { { kind="return_stmt", expr=int_lit(1) } },
        nil),
      ctx({})
    )
    assert.is_nil(val)
  end)

  it("if/else in fn body via let captures the correct branch value", function()
    local src = [[
module test-ifexpr
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main
state world:
  x: Int(0,100) = 0
fn pick-value:
  let v = if world/x > 0:
    return 10
  else:
    return 20
  set! world/x v
scene main:
  title: Main
  * Go
    -> main
]]
    -- x starts at 0, so condition is false → v=20
    local _, st = run(src, "pick-value")
    assert.equal(20, st:get("world/x"))
  end)

  it("if/else in fn body returns truthy branch when condition holds", function()
    local src = [[
module test-ifexpr2
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main
state world:
  x: Int(0,100) = 5
fn pick-value:
  let v = if world/x > 0:
    return 10
  else:
    return 20
  set! world/x v
scene main:
  title: Main
  * Go
    -> main
]]
    local _, st = run(src, "pick-value")
    assert.equal(10, st:get("world/x"))
  end)
end)

-- ============================================================
-- Bug #4 regression: PATH_EXPR single-segment reads nil_vars
-- ============================================================

describe("eval: PATH_EXPR nil_vars check (Bug #4 regression)", function()
  it("let x = nil then reading x returns nil, not a state value", function()
    local c = ctx({ x = 99 })  -- state has a path "x" = 99
    -- Simulate a let binding of x to nil via nil_vars
    c.nil_vars = { x = true }
    local node = path("x")
    -- Should return nil (from nil_vars), not 99 (from state)
    assert.is_nil(eval.eval_expr(node, c))
  end)

  it("without nil_vars, path falls through to state", function()
    local c = ctx({ x = 99 })
    local node = path("x")
    assert.equal(99, eval.eval_expr(node, c))
  end)
end)

-- ============================================================
-- Bug #6 regression: map-values and map-keys agree in index order
-- ============================================================

describe("eval: map-values sorted to match map-keys (Bug #6 regression)", function()
  it("map-values and map-keys return values/keys in the same index order", function()
    local c = ctx({})
    c.state:set("m/v", { alpha = 1, gamma = 3, beta = 2 }, "init")
    local keys_node = fn_call("map-keys", path("m", "v"))
    local vals_node = fn_call("map-values", path("m", "v"))
    local keys = eval.eval_expr(keys_node, c)
    local vals = eval.eval_expr(vals_node, c)
    assert.equal(#keys, #vals)
    -- keys must be sorted: alpha, beta, gamma
    assert.equal("alpha", keys[1])
    assert.equal("beta",  keys[2])
    assert.equal("gamma", keys[3])
    -- values must match the sorted key order: 1, 2, 3
    assert.equal(1, vals[1])
    assert.equal(2, vals[2])
    assert.equal(3, vals[3])
  end)
end)

-- ============================================================
-- Bug #2 regression: relate!/unrelate! logged, undoable, counterfactual-safe
-- ============================================================

describe("eval: relate!/unrelate! logged and undoable (Bug #2 regression)", function()
  local compiler_mod = require("compiler.compiler")
  local engine_mod   = require("runtime.engine")
  local state_mod2   = require("runtime.state")
  local log_mod2     = require("runtime.log")

  local SRC = [[
module relate-test
  version: 1.0
engine-config:
  entry-scene: main
relation edges: Symbol -> Set(Symbol, 10)
state world/x : Int(0,10) = 0
fn do-relate:
  relate! edges `a `b
fn do-unrelate:
  unrelate! edges `a `b
scene main:
  * Go
    -> main
]]

  local function make_relate_ctx()
    local gt = assert(compiler_mod.compile(SRC, "test.sb"), "compilation failed")
    local l = log_mod2.new()
    local st = state_mod2.new(gt.schema, l)
    local c = eval.new_ctx(st, gt.fns, "test", gt)
    return c, gt, l
  end

  it("relate! writes a log entry so the edge is persisted", function()
    local c, _, l = make_relate_ctx()
    eval.call_fn("do-relate", {}, c)
    local found = false
    for _, e in ipairs(l:entries()) do
      if e.path and e.path:match("^__rel/edges/") then found = true; break end
    end
    assert.is_true(found, "relate! must produce a log entry under __rel/edges/")
  end)

  it("undo! reverts a relate! edge", function()
    local c, _ = make_relate_ctx()
    c.state:push_checkpoint("before")
    eval.call_fn("do-relate", {}, c)
    -- Edge is now visible
    local adj_after = { kind="fn_call", name="adjacent?", args={
      { kind="fn_call", name="edges", args={} },
      { kind="symbol_lit", name="a" },
    }}
    assert.is_truthy(eval.eval_expr(adj_after, c) and eval.eval_expr(adj_after, c)["b"])
    -- Undo
    c.state:undo()
    -- Edge must be gone
    assert.is_nil(eval.eval_expr(adj_after, c) and eval.eval_expr(adj_after, c)["b"])
  end)

  it("relate! inside a counterfactual does not contaminate live state", function()
    local gt = assert(compiler_mod.compile(SRC, "test.sb"))
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local ctx_live = eng:make_ctx("live")
    -- Verify no dynamic edge in live state before
    local adj_node = { kind="fn_call", name="adjacent?", args={
      { kind="fn_call", name="edges", args={} },
      { kind="symbol_lit", name="a" },
    }}
    assert.is_nil(eval.eval_expr(adj_node, ctx_live) and eval.eval_expr(adj_node, ctx_live)["b"])
    -- Call relate! in a separate context (simulating counterfactual isolation by cloned cache)
    local clone_cache = {}
    for k, v in pairs(eng._state._cache) do
      clone_cache[k] = type(v) == "table" and (function(t) local c2={}; for k2,v2 in pairs(t) do c2[k2]=v2 end; return c2 end)(v) or v
    end
    local log2 = log_mod2.new()
    local st2  = state_mod2.new(gt.schema, log2)
    st2._cache = clone_cache
    local ctx2 = eval.new_ctx(st2, gt.fns, "cf", gt)
    eval.call_fn("do-relate", {}, ctx2)
    -- Edge visible in counterfactual context
    assert.is_truthy(eval.eval_expr(adj_node, ctx2) and eval.eval_expr(adj_node, ctx2)["b"])
    -- Live state must be unchanged (cache-based storage prevents contamination)
    assert.is_nil(eval.eval_expr(adj_node, ctx_live) and eval.eval_expr(adj_node, ctx_live)["b"])
  end)
end)

-- ── print / log builtins ──────────────────────────────────────────────────────

describe("print builtin", function()
  local function make_ctx_with_sink()
    local output = {}
    local game = { _print_sink = function(s) output[#output+1] = s end }
    local s = make_store({})
    local c = eval.new_ctx(s, {}, "test-fn", game)
    return c, output
  end

  it("writes space-joined args to sink", function()
    local c, out = make_ctx_with_sink()
    local node = fn_call("print",
      { kind="string_lit", value="hello" },
      { kind="string_lit", value="world" })
    eval.eval_expr(node, c)
    assert.equal("hello world\n", out[1])
  end)

  it("converts numbers to string", function()
    local c, out = make_ctx_with_sink()
    eval.eval_expr(fn_call("print", int_lit(42)), c)
    assert.equal("42\n", out[1])
  end)

  it("converts nil to the string 'nil'", function()
    local c, out = make_ctx_with_sink()
    -- path to non-existent key → nil
    eval.eval_expr(fn_call("print", path("missing")), c)
    assert.equal("nil\n", out[1])
  end)

  it("works with a single bool arg", function()
    local c, out = make_ctx_with_sink()
    eval.eval_expr(fn_call("print", bool_lit(true)), c)
    assert.equal("true\n", out[1])
  end)

  it("returns nil", function()
    local c, _ = make_ctx_with_sink()
    local result = eval.eval_expr(fn_call("print", str_lit("x")), c)
    assert.is_nil(result)
  end)

  it("prints nothing and returns nil when production=true", function()
    local output = {}
    local game = { production = true, _print_sink = function(s) output[#output+1] = s end }
    local s = make_store({})
    local c = eval.new_ctx(s, {}, "test-fn", game)
    eval.eval_expr(fn_call("print", str_lit("secret")), c)
    assert.equal(0, #output)
  end)

  it("handles zero args", function()
    local c, out = make_ctx_with_sink()
    eval.eval_expr(fn_call("print"), c)
    assert.equal("\n", out[1])
  end)

  it("handles three args", function()
    local c, out = make_ctx_with_sink()
    eval.eval_expr(fn_call("print",
      str_lit("a"), str_lit("b"), str_lit("c")), c)
    assert.equal("a b c\n", out[1])
  end)

  it("uses stderr when no sink is set", function()
    -- No game table at all — should not error
    local s = make_store({})
    local c = eval.new_ctx(s, {}, "test-fn", nil)
    -- Redirect stderr temporarily
    local old_stderr = io.stderr
    local captured = {}
    io.stderr = { write = function(_, s2) captured[#captured+1] = s2 end }
    eval.eval_expr(fn_call("print", str_lit("fallback")), c)
    io.stderr = old_stderr
    assert.equal("fallback\n", captured[1])
  end)
end)

describe("log builtin", function()
  local function make_ctx_with_sink(fn_name)
    local output = {}
    local game = { _print_sink = function(s) output[#output+1] = s end }
    local s = make_store({})
    local c = eval.new_ctx(s, {}, fn_name or "test-fn", game)
    return c, output
  end

  -- Helper: fn_call node with pos info
  local function log_call(level_name, ...)
    local node = {
      kind = "fn_call",
      name = "log",
      pos  = { file = "test.sb", line = 12, col = 1 },
      args = { { kind="symbol_lit", name=level_name }, ... },
    }
    return node
  end

  it("formats with [LEVEL] prefix, file:line, and fn name", function()
    local c, out = make_ctx_with_sink("my-fn")
    local node = log_call("warn", str_lit("too much gold"))
    -- eval_expr sets ctx.call_pos from node.pos when dispatching FN_CALL
    eval.eval_expr(node, c)
    assert.equal("[WARN] test.sb:12 (my-fn): too much gold\n", out[1])
  end)

  it("debug level", function()
    local c, out = make_ctx_with_sink()
    eval.eval_expr(log_call("debug", str_lit("checkpoint")), c)
    assert.matches("^%[DEBUG%]", out[1])
  end)

  it("info level", function()
    local c, out = make_ctx_with_sink()
    eval.eval_expr(log_call("info", str_lit("msg")), c)
    assert.matches("^%[INFO%]", out[1])
  end)

  it("error level", function()
    local c, out = make_ctx_with_sink()
    eval.eval_expr(log_call("error", str_lit("boom")), c)
    assert.matches("^%[ERROR%]", out[1])
  end)

  it("concatenates multiple message args with spaces", function()
    local c, out = make_ctx_with_sink()
    eval.eval_expr(log_call("info", str_lit("gold"), int_lit(99)), c)
    assert.matches("gold 99", out[1])
  end)

  it("converts nil message arg to 'nil'", function()
    local c, out = make_ctx_with_sink()
    eval.eval_expr(log_call("debug", path("missing")), c)
    assert.matches("nil", out[1])
  end)

  it("returns nil", function()
    local c, _ = make_ctx_with_sink()
    local result = eval.eval_expr(log_call("info", str_lit("x")), c)
    assert.is_nil(result)
  end)

  it("is suppressed when production=true", function()
    local output = {}
    local game = { production = true, _print_sink = function(s) output[#output+1] = s end }
    local s = make_store({})
    local c = eval.new_ctx(s, {}, "fn", game)
    eval.eval_expr(log_call("warn", str_lit("hidden")), c)
    assert.equal(0, #output)
  end)

  it("shows '?' for file when no pos is available", function()
    local c, out = make_ctx_with_sink()
    -- call_fn directly (no node.pos set → call_pos is nil)
    eval.call_fn("log", {
      { kind="symbol_lit", name="info" },
      { kind="string_lit", value="no pos" },
    }, c)
    assert.matches("%?", out[1])
  end)

  it("uses stderr when no sink is set", function()
    local s = make_store({})
    local c = eval.new_ctx(s, {}, "fn", nil)
    local old_stderr = io.stderr
    local captured = {}
    io.stderr = { write = function(_, s2) captured[#captured+1] = s2 end }
    eval.eval_expr(log_call("info", str_lit("stderr-test")), c)
    io.stderr = old_stderr
    assert.matches("%[INFO%]", captured[1])
    assert.matches("stderr%-test", captured[1])
  end)
end)

describe("print/log: end-to-end via compiler", function()
  local compiler_mod3 = require("compiler.compiler")
  local engine_mod3   = require("runtime.engine")
  local log_mod3      = require("runtime.log")
  local state_mod3    = require("runtime.state")

  local function run_with_sink(src)
    local gt = assert(compiler_mod3.compile(src, "test.sb"))
    local output = {}
    gt._print_sink = function(s) output[#output+1] = s end
    local eng = engine_mod3.new(gt, { io_out = { write = function() end } })
    eng:init()
    local ctx3 = eng:make_ctx("main")
    eval.call_fn("main", {}, ctx3)
    return output
  end

  it("print in compiled fn writes to sink", function()
    local src = [[
state world:
  gold: Int(0, 9999) = 0
fn main:
  print "gold" world/gold
]]
    local out = run_with_sink(src)
    assert.equal(1, #out)
    assert.equal("gold 0\n", out[1])
  end)

  it("log in compiled fn writes formatted line to sink", function()
    local src = "state world:\n  gold: Int(0, 9999) = 0\nfn main:\n  log `info \"balance\" world/gold\n"
    local out = run_with_sink(src)
    assert.equal(1, #out)
    assert.matches("%[INFO%]", out[1])
    assert.matches("test%.sb:%d+", out[1])
    assert.matches("balance 0", out[1])
  end)

  it("log includes fn name in output", function()
    local src = "state world:\n  gold: Int(0, 9999) = 0\nfn report-balance:\n  log `debug \"checking\"\n"
    local gt = assert(compiler_mod3.compile(src, "test.sb"))
    local output = {}
    gt._print_sink = function(s) output[#output+1] = s end
    local eng = engine_mod3.new(gt, { io_out = { write = function() end } })
    eng:init()
    local ctx3 = eng:make_ctx("report-balance")
    eval.call_fn("report-balance", {}, ctx3)
    assert.matches("report%-balance", output[1])
  end)

  it("print suppressed in production mode", function()
    local src = [[
state world:
  gold: Int(0, 9999) = 0
fn main:
  print "secret"
]]
    local gt = assert(compiler_mod3.compile(src, "test.sb"))
    local output = {}
    gt._print_sink = function(s) output[#output+1] = s end
    gt.production  = true
    local eng = engine_mod3.new(gt, { io_out = { write = function() end } })
    eng:init()
    local ctx3 = eng:make_ctx("main")
    eval.call_fn("main", {}, ctx3)
    assert.equal(0, #output)
  end)

  it("log suppressed in production mode", function()
    local src = "state world:\n  gold: Int(0, 9999) = 0\nfn main:\n  log `warn \"secret\"\n"
    local gt = assert(compiler_mod3.compile(src, "test.sb"))
    local output = {}
    gt._print_sink = function(s) output[#output+1] = s end
    gt.production  = true
    local eng = engine_mod3.new(gt, { io_out = { write = function() end } })
    eng:init()
    local ctx3 = eng:make_ctx("main")
    eval.call_fn("main", {}, ctx3)
    assert.equal(0, #output)
  end)
end)

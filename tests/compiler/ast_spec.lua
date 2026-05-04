-- tests/compiler/ast_spec.lua
-- Tests for compiler/ast.lua: node constructors, kind constants, predicates,
-- diagnostic constructors, and the diagnostic accumulator.
--
-- Run with:  busted tests/

local ast = require("compiler.ast")

-- ============================================================
-- Helpers
-- ============================================================

local function is_table(v) return type(v) == "table" end

-- ============================================================
-- Source position
-- ============================================================

describe("ast.pos", function()
  it("creates a position table with file, line, col", function()
    local p = ast.pos("game.sb", 10, 5)
    assert.equal("game.sb", p.file)
    assert.equal(10, p.line)
    assert.equal(5, p.col)
  end)

  it("defaults line and col to 0 when omitted", function()
    local p = ast.pos("x.sb")
    assert.equal(0, p.line)
    assert.equal(0, p.col)
  end)

  it("returns a plain table", function()
    assert.is_true(is_table(ast.pos("f", 1, 1)))
  end)
end)

-- ============================================================
-- Diagnostic constructors
-- ============================================================

describe("ast.error", function()
  it("creates an error diagnostic with level = `error'", function()
    local d = ast.error("SOME_CODE", "bad thing happened", ast.pos("f.sb", 3, 7))
    assert.equal("error", d.level)
    assert.equal("SOME_CODE", d.code)
    assert.equal("bad thing happened", d.message)
    assert.equal("f.sb", d.file)
    assert.equal(3, d.line)
    assert.equal(7, d.col)
  end)

  it("accepts an optional note", function()
    local d = ast.error("CODE", "msg", ast.pos("f.sb", 1, 1), "extra context")
    assert.equal("extra context", d.note)
  end)

  it("works without a pos argument (uses fallback position)", function()
    local d = ast.error("CODE", "msg")
    assert.equal("error", d.level)
    assert.equal("CODE", d.code)
    assert.is_not_nil(d.file)
    assert.is_not_nil(d.line)
    assert.is_not_nil(d.col)
  end)
end)

describe("ast.warning", function()
  it("creates a warning diagnostic with level = `warning'", function()
    local d = ast.warning("WARN_CODE", "be careful", ast.pos("f.sb", 1, 1))
    assert.equal("warning", d.level)
    assert.equal("WARN_CODE", d.code)
    assert.equal("be careful", d.message)
  end)
end)

-- ============================================================
-- Error and Warning code tables
-- ============================================================

describe("ast.E (error codes)", function()
  it("is a table", function()
    assert.is_true(is_table(ast.E))
  end)

  it("contains SUPERFICIAL_IN_COND", function()
    assert.equal("SUPERFICIAL_IN_COND", ast.E.SUPERFICIAL_IN_COND)
  end)

  it("contains UNTERMINATED_STRING", function()
    assert.equal("UNTERMINATED_STRING", ast.E.UNTERMINATED_STRING)
  end)

  it("contains ILLEGAL_CHAR", function()
    assert.equal("ILLEGAL_CHAR", ast.E.ILLEGAL_CHAR)
  end)

  it("contains MIXED_INDENT", function()
    assert.equal("MIXED_INDENT", ast.E.MIXED_INDENT)
  end)

  it("contains IMPORT_CYCLE", function()
    assert.equal("IMPORT_CYCLE", ast.E.IMPORT_CYCLE)
  end)

  it("contains DUPLICATE_NAME", function()
    assert.equal("DUPLICATE_NAME", ast.E.DUPLICATE_NAME)
  end)

  it("contains UNDEFINED_TYPE", function()
    assert.equal("UNDEFINED_TYPE", ast.E.UNDEFINED_TYPE)
  end)

  it("contains TYPE_MISMATCH", function()
    assert.equal("TYPE_MISMATCH", ast.E.TYPE_MISMATCH)
  end)

  it("contains PURE_CALLS_MUT", function()
    assert.equal("PURE_CALLS_MUT", ast.E.PURE_CALLS_MUT)
  end)

  it("contains WRITE_UNTYPED_VAR", function()
    assert.equal("WRITE_UNTYPED_VAR", ast.E.WRITE_UNTYPED_VAR)
  end)

  it("contains RANDOM_SUPERFICIAL", function()
    assert.equal("RANDOM_SUPERFICIAL", ast.E.RANDOM_SUPERFICIAL)
  end)

  it("contains PERCEIVES_VIOLATION", function()
    assert.equal("PERCEIVES_VIOLATION", ast.E.PERCEIVES_VIOLATION)
  end)

  it("contains FILE_NOT_FOUND", function()
    assert.equal("FILE_NOT_FOUND", ast.E.FILE_NOT_FOUND)
  end)

  it("contains MIGRATION_MISSING", function()
    assert.equal("MIGRATION_MISSING", ast.E.MIGRATION_MISSING)
  end)

  it("all values are UPPER_SNAKE strings", function()
    for k, v in pairs(ast.E) do
      assert.is_string(v, "E." .. k .. " should be a string")
      assert.matches("^[A-Z_]+$", v, "E." .. k .. " should be UPPER_SNAKE")
    end
  end)
end)

describe("ast.W (warning codes)", function()
  it("contains UNTYPED_SYMBOL", function()
    assert.is_not_nil(ast.W.UNTYPED_SYMBOL)
  end)

  it("all values are strings", function()
    for k, v in pairs(ast.W) do
      assert.is_string(v, "W." .. k .. " should be a string")
    end
  end)
end)

-- ============================================================
-- Kind constants
-- ============================================================

describe("ast.K (kind constants)", function()
  it("is a table", function()
    assert.is_true(is_table(ast.K))
  end)

  it("has PROGRAM", function()
    assert.equal("program", ast.K.PROGRAM)
  end)

  it("has all major declaration kinds", function()
    local expected = {
      "MODULE_DECL", "IMPORT_DECL", "SCHEMA_VERSION", "ENGINE_CONFIG",
      "TIME_MODEL", "TYPE_ENUM", "TYPE_ALIAS", "TYPE_RECORD", "TYPE_VARIANT",
      "STATE_SCALAR", "STATE_RECORD", "STATE_FAMILY",
      "RELATION_DECL", "FN_DECL", "ACTOR_DECL", "SCHEDULE_DECL",
      "BOUNDED_DECL", "VERIFY_DECL", "WATCH_DECL", "WATCH_WHEN_DECL",
      "SCENE_DECL", "MACRO_DECL", "MIGRATION_DECL",
    }
    for _, name in ipairs(expected) do
      assert.is_not_nil(ast.K[name], "K." .. name .. " should exist")
      assert.is_string(ast.K[name], "K." .. name .. " should be a string")
    end
  end)

  it("has all type expression kinds", function()
    local expected = {
      "TYPE_BOOL", "TYPE_INT", "TYPE_ENUM_INLINE", "TYPE_OPTION",
      "TYPE_SET", "TYPE_LIST", "TYPE_SYMBOL", "TYPE_SYMBOL_OF",
      "TYPE_STRING", "TYPE_FLOAT", "TYPE_ULIST", "TYPE_UMAP",
      "TYPE_NAMED", "TYPE_FN",
    }
    for _, name in ipairs(expected) do
      assert.is_not_nil(ast.K[name], "K." .. name .. " should exist")
    end
  end)

  it("has all literal kinds", function()
    local expected = {
      "INT_LIT", "FLOAT_LIT", "BOOL_LIT", "STRING_LIT",
      "MULTILINE_STRING", "SYMBOL_LIT",
    }
    for _, name in ipairs(expected) do
      assert.is_not_nil(ast.K[name], "K." .. name .. " should exist")
    end
  end)

  it("has all mutation primitive kinds", function()
    local expected = {
      "SET_MUT", "INC_MUT", "DEC_MUT", "ADD_MUT", "REMOVE_MUT",
      "CLEAR_MUT", "PUSH_MUT", "POP_MUT", "RELATE_MUT", "UNRELATE_MUT",
      "SPAWN_MUT", "DESPAWN_MUT", "SEND_MUT", "TIME_INC_MUT", "UNDO_MUT",
      "GOTO_SCENE_MUT", "ENTER_SCENE_MUT", "EXIT_SCENE_MUT",
      "SCHEDULE_MUT", "CANCEL_SCHEDULE_MUT",
    }
    for _, name in ipairs(expected) do
      assert.is_not_nil(ast.K[name], "K." .. name .. " should exist")
    end
  end)

  it("has all control flow kinds", function()
    local expected = {
      "IF_EXPR", "WHEN_STMT", "MATCH_EXPR", "COND_EXPR",
      "FOR_STMT", "WHILE_STMT", "LET_STMT", "LAMBDA_EXPR",
      "PASS_STMT", "EXPR_STMT",
    }
    for _, name in ipairs(expected) do
      assert.is_not_nil(ast.K[name], "K." .. name .. " should exist")
    end
  end)

  it("has all collection literal kinds", function()
    local expected = { "SET_LIT", "LIST_LIT", "MAP_LIT", "EMPTY_SET", "EMPTY_LIST", "EMPTY_MAP" }
    for _, name in ipairs(expected) do
      assert.is_not_nil(ast.K[name], "K." .. name .. " should exist")
    end
  end)

  it("has all scene-specific kinds", function()
    local expected = {
      "NARRATION_LINE", "COND_NARRATION", "CHOICE",
      "SCENE_GOTO", "SCENE_ENTER", "SCENE_EXIT", "INLINE_EXPR",
    }
    for _, name in ipairs(expected) do
      assert.is_not_nil(ast.K[name], "K." .. name .. " should exist")
    end
  end)

  it("has all query / search kinds", function()
    local expected = {
      "FIND_EXPR", "QUERY_AT_EXPR", "QUERY_HISTORY_EXPR", "QUERY_CHANGES_EXPR",
      "COUNTERFACTUAL_EXPR", "IN_STATE_EXPR",
    }
    for _, name in ipairs(expected) do
      assert.is_not_nil(ast.K[name], "K." .. name .. " should exist")
    end
  end)

  it("has no duplicate values", function()
    local seen = {}
    for k, v in pairs(ast.K) do
      assert.is_nil(seen[v], "K." .. k .. " value '" .. v .. "' is duplicate")
      seen[v] = k
    end
  end)
end)

-- ============================================================
-- Base node constructor
-- ============================================================

describe("ast.node", function()
  it("returns a table with the given kind", function()
    local n = ast.node("my_kind", {})
    assert.equal("my_kind", n.kind)
  end)

  it("copies fields into the node", function()
    local n = ast.node("k", { foo = 42, bar = "hello" })
    assert.equal(42, n.foo)
    assert.equal("hello", n.bar)
  end)

  it("attaches the supplied pos", function()
    local p = ast.pos("f.sb", 5, 3)
    local n = ast.node("k", {}, p)
    assert.equal("f.sb", n.pos.file)
    assert.equal(5, n.pos.line)
    assert.equal(3, n.pos.col)
  end)

  it("uses a default pos when none is supplied", function()
    local n = ast.node("k", {})
    assert.is_not_nil(n.pos)
    assert.is_string(n.pos.file)
  end)

  it("does not share the fields table with the caller", function()
    local fields = { x = 1 }
    local n = ast.node("k", fields)
    fields.x = 999
    -- The node's x should still be 1 because we copied, not referenced
    assert.equal(1, n.x)
  end)
end)

-- ============================================================
-- Program node
-- ============================================================

describe("ast.program", function()
  it("creates a program node with decls list", function()
    local decls = { ast.node("x", {}) }
    local n = ast.program(decls)
    assert.equal(ast.K.PROGRAM, n.kind)
    assert.equal(1, #n.decls)
  end)

  it("defaults decls to empty list", function()
    local n = ast.program()
    assert.is_true(is_table(n.decls))
    assert.equal(0, #n.decls)
  end)
end)

-- ============================================================
-- Declaration constructors
-- ============================================================

describe("ast.module_decl", function()
  it("stores name and version", function()
    local n = ast.module_decl("combat", "1.2")
    assert.equal(ast.K.MODULE_DECL, n.kind)
    assert.equal("combat", n.name)
    assert.equal("1.2", n.version)
  end)
end)

describe("ast.import_decl", function()
  it("flat import has nil alias", function()
    local n = ast.import_decl("combat.sb", nil)
    assert.equal(ast.K.IMPORT_DECL, n.kind)
    assert.equal("combat.sb", n.path)
    assert.is_nil(n.alias)
  end)

  it("namespaced import stores alias", function()
    local n = ast.import_decl("enemies.sb", "E")
    assert.equal("E", n.alias)
  end)
end)

describe("ast.schema_version", function()
  it("stores version number", function()
    local n = ast.schema_version(3)
    assert.equal(ast.K.SCHEMA_VERSION, n.kind)
    assert.equal(3, n.version)
  end)
end)

describe("ast.engine_config", function()
  it("stores keys table", function()
    local keys = { { key = "entry-scene", value = "main" } }
    local n = ast.engine_config(keys)
    assert.equal(ast.K.ENGINE_CONFIG, n.kind)
    assert.equal(1, #n.keys)
  end)

  it("defaults to empty keys", function()
    local n = ast.engine_config()
    assert.equal(0, #n.keys)
  end)
end)

describe("ast.time_model", function()
  it("stores axes and wrap lists", function()
    local n = ast.time_model({"day", "tick"}, {"none", "none"})
    assert.equal(ast.K.TIME_MODEL, n.kind)
    assert.equal(2, #n.axes)
    assert.equal(2, #n.wrap)
  end)
end)

describe("ast.type_enum", function()
  it("stores name and values", function()
    local n = ast.type_enum("Status", {"alive", "dead"})
    assert.equal(ast.K.TYPE_ENUM, n.kind)
    assert.equal("Status", n.name)
    assert.equal(2, #n.values)
    assert.equal("alive", n.values[1])
  end)

  it("stores optional doc string", function()
    local n = ast.type_enum("S", {}, "Player status enum")
    assert.equal("Player status enum", n.doc)
  end)
end)

describe("ast.type_alias", function()
  it("stores name and type_expr", function()
    local te = ast.type_int(0, 100)
    local n  = ast.type_alias("Health", te)
    assert.equal(ast.K.TYPE_ALIAS, n.kind)
    assert.equal("Health", n.name)
    assert.equal(ast.K.TYPE_INT, n.type_expr.kind)
  end)
end)

describe("ast.type_record", function()
  it("stores name and fields", function()
    local fields = { ast.record_field("hp", ast.type_int(0, 100), nil, nil) }
    local n = ast.type_record("Entity", fields)
    assert.equal(ast.K.TYPE_RECORD, n.kind)
    assert.equal("Entity", n.name)
    assert.equal(1, #n.fields)
  end)
end)

describe("ast.type_variant", function()
  it("stores name and branches", function()
    local branches = { ast.variant_branch("alert", {}) }
    local n = ast.type_variant("ActorMsg", branches)
    assert.equal(ast.K.TYPE_VARIANT, n.kind)
    assert.equal("ActorMsg", n.name)
    assert.equal(1, #n.branches)
  end)
end)

describe("ast.record_field", function()
  it("stores name, type_expr, and default", function()
    local te = ast.type_bool()
    local n  = ast.record_field("active", te, ast.bool_lit(false))
    assert.equal(ast.K.RECORD_FIELD, n.kind)
    assert.equal("active", n.name)
    assert.equal(ast.K.TYPE_BOOL, n.type_expr.kind)
    assert.equal(ast.K.BOOL_LIT, n.default.kind)
  end)

  it("allows nil default", function()
    local n = ast.record_field("x", ast.type_int(0, 10), nil)
    assert.is_nil(n.default)
  end)
end)

describe("ast.with_mixin", function()
  it("stores type_name", function()
    local n = ast.with_mixin("Entity")
    assert.equal(ast.K.WITH_MIXIN, n.kind)
    assert.equal("Entity", n.type_name)
  end)
end)

describe("ast.variant_branch", function()
  it("stores name and fields list", function()
    local fields = { ast.record_field("damage", ast.type_int(0, 999), nil) }
    local n = ast.variant_branch("attack", fields)
    assert.equal(ast.K.VARIANT_BRANCH, n.kind)
    assert.equal("attack", n.name)
    assert.equal(1, #n.fields)
  end)
end)

describe("ast.state_scalar", function()
  it("stores path, type_expr, default, doc", function()
    local te = ast.type_named("Player")
    local n  = ast.state_scalar("player", te, nil, "The player character")
    assert.equal(ast.K.STATE_SCALAR, n.kind)
    assert.equal("player", n.path)
    assert.equal("Player", n.type_expr.name)
    assert.equal("The player character", n.doc)
  end)
end)

describe("ast.state_family", function()
  it("stores family, var, type_expr, and max", function()
    local te = ast.type_named("Npc")
    local n  = ast.state_family("npcs", "npc", te, 20)
    assert.equal(ast.K.STATE_FAMILY, n.kind)
    assert.equal("npcs", n.family)
    assert.equal("npc", n.var)
    assert.equal(20, n.max)
  end)
end)

describe("ast.relation_decl", function()
  it("stores relation metadata", function()
    local to_te = ast.type_set(ast.type_named("Location"), 6)
    local n = ast.relation_decl("exits", "Location", to_te, {})
    assert.equal(ast.K.RELATION_DECL, n.kind)
    assert.equal("exits", n.name)
    assert.equal("Location", n.from_type)
  end)
end)

describe("ast.fn_decl", function()
  it("stores name, params, pre, post, tags, body", function()
    local body = { ast.pass_stmt() }
    local n = ast.fn_decl("move-to", {}, {}, {}, {"checkpoint"}, body)
    assert.equal(ast.K.FN_DECL, n.kind)
    assert.equal("move-to", n.name)
    assert.equal(1, #n.tags)
    assert.equal("checkpoint", n.tags[1])
    assert.equal(1, #n.body)
  end)

  it("defaults all list fields to empty lists", function()
    local n = ast.fn_decl("foo", nil, nil, nil, nil, nil)
    assert.equal(0, #n.params)
    assert.equal(0, #n.pre)
    assert.equal(0, #n.post)
    assert.equal(0, #n.tags)
    assert.equal(0, #n.body)
  end)
end)

describe("ast.scene_decl", function()
  it("stores name and body", function()
    local body = { ast.narration_line({"Hello"}) }
    local n = ast.scene_decl("village", body)
    assert.equal(ast.K.SCENE_DECL, n.kind)
    assert.equal("village", n.name)
    assert.equal(1, #n.body)
  end)
end)

-- ============================================================
-- Type expression constructors
-- ============================================================

describe("type expression constructors", function()
  it("type_bool has correct kind", function()
    assert.equal(ast.K.TYPE_BOOL, ast.type_bool().kind)
  end)

  it("type_int stores min and max", function()
    local n = ast.type_int(0, 100)
    assert.equal(ast.K.TYPE_INT, n.kind)
    assert.equal(0, n.min)
    assert.equal(100, n.max)
  end)

  it("type_enum_inline stores values", function()
    local n = ast.type_enum_inline({"alive", "dead"})
    assert.equal(ast.K.TYPE_ENUM_INLINE, n.kind)
    assert.equal(2, #n.values)
  end)

  it("type_option stores inner type", function()
    local n = ast.type_option(ast.type_int(0, 10))
    assert.equal(ast.K.TYPE_OPTION, n.kind)
    assert.equal(ast.K.TYPE_INT, n.inner.kind)
  end)

  it("type_set stores inner and max", function()
    local n = ast.type_set(ast.type_named("ItemKind"), 10)
    assert.equal(ast.K.TYPE_SET, n.kind)
    assert.equal(10, n.max)
  end)

  it("type_list stores inner and max", function()
    local n = ast.type_list(ast.type_named("Location"), 5)
    assert.equal(ast.K.TYPE_LIST, n.kind)
    assert.equal(5, n.max)
  end)

  it("type_symbol has correct kind", function()
    assert.equal(ast.K.TYPE_SYMBOL, ast.type_symbol().kind)
  end)

  it("type_symbol_of stores family", function()
    local n = ast.type_symbol_of("npcs")
    assert.equal(ast.K.TYPE_SYMBOL_OF, n.kind)
    assert.equal("npcs", n.family)
  end)

  it("type_string has correct kind", function()
    assert.equal(ast.K.TYPE_STRING, ast.type_string().kind)
  end)

  it("type_float has correct kind", function()
    assert.equal(ast.K.TYPE_FLOAT, ast.type_float().kind)
  end)

  it("type_ulist stores inner", function()
    local n = ast.type_ulist(ast.type_string())
    assert.equal(ast.K.TYPE_ULIST, n.kind)
    assert.equal(ast.K.TYPE_STRING, n.inner.kind)
  end)

  it("type_umap stores key and val", function()
    local n = ast.type_umap(ast.type_string(), ast.type_int(0, 100))
    assert.equal(ast.K.TYPE_UMAP, n.kind)
    assert.equal(ast.K.TYPE_STRING, n.key.kind)
    assert.equal(ast.K.TYPE_INT, n.val.kind)
  end)

  it("type_named stores name", function()
    local n = ast.type_named("Player")
    assert.equal(ast.K.TYPE_NAMED, n.kind)
    assert.equal("Player", n.name)
  end)

  it("type_fn stores param_types and return_type", function()
    local n = ast.type_fn({ ast.type_int(0, 10) }, ast.type_bool())
    assert.equal(ast.K.TYPE_FN, n.kind)
    assert.equal(1, #n.param_types)
    assert.equal(ast.K.TYPE_BOOL, n.return_type.kind)
  end)
end)

-- ============================================================
-- Literal constructors
-- ============================================================

describe("literal constructors", function()
  it("int_lit stores integer value", function()
    local n = ast.int_lit(42)
    assert.equal(ast.K.INT_LIT, n.kind)
    assert.equal(42, n.value)
  end)

  it("int_lit stores negative value", function()
    local n = ast.int_lit(-7)
    assert.equal(-7, n.value)
  end)

  it("float_lit stores float value", function()
    local n = ast.float_lit(3.14)
    assert.equal(ast.K.FLOAT_LIT, n.kind)
    assert.near(3.14, n.value, 0.0001)
  end)

  it("bool_lit stores true", function()
    local n = ast.bool_lit(true)
    assert.equal(ast.K.BOOL_LIT, n.kind)
    assert.is_true(n.value)
  end)

  it("bool_lit stores false", function()
    local n = ast.bool_lit(false)
    assert.is_false(n.value)
  end)

  it("string_lit stores value", function()
    local n = ast.string_lit("hello, world")
    assert.equal(ast.K.STRING_LIT, n.kind)
    assert.equal("hello, world", n.value)
  end)

  it("multiline_string stores value", function()
    local n = ast.multiline_string("line one\nline two")
    assert.equal(ast.K.MULTILINE_STRING, n.kind)
    assert.equal("line one\nline two", n.value)
  end)

  it("symbol_lit stores name", function()
    local n = ast.symbol_lit("sword")
    assert.equal(ast.K.SYMBOL_LIT, n.kind)
    assert.equal("sword", n.name)
  end)
end)

-- ============================================================
-- Path expression constructors
-- ============================================================

describe("path constructors", function()
  it("path_expr stores segments list", function()
    local n = ast.path_expr({"player", "health"})
    assert.equal(ast.K.PATH_EXPR, n.kind)
    assert.equal(2, #n.segments)
    assert.equal("player", n.segments[1])
    assert.equal("health", n.segments[2])
  end)

  it("interp_path stores mixed segments", function()
    local segs = {"npcs", {interp = "npc"}, "health"}
    local n = ast.interp_path(segs)
    assert.equal(ast.K.INTERP_PATH, n.kind)
    assert.equal(3, #n.segments)
    assert.equal("npc", n.segments[2].interp)
  end)

  it("path_at_before stores path node", function()
    local path = ast.path_expr({"player", "gold"})
    local n = ast.path_at_before(path)
    assert.equal(ast.K.PATH_AT_BEFORE, n.kind)
    assert.equal(ast.K.PATH_EXPR, n.path.kind)
  end)

  it("index_expr stores base and index", function()
    local base = ast.path_expr({"player", "waypoints"})
    local idx  = ast.int_lit(0)
    local n = ast.index_expr(base, idx)
    assert.equal(ast.K.INDEX_EXPR, n.kind)
    assert.equal(ast.K.PATH_EXPR, n.base.kind)
    assert.equal(0, n.index.value)
  end)

  it("slice_expr stores base, from, to", function()
    local base = ast.path_expr({"player", "waypoints"})
    local n = ast.slice_expr(base, ast.int_lit(1), ast.int_lit(4))
    assert.equal(ast.K.SLICE_EXPR, n.kind)
    assert.equal(1, n.from.value)
    assert.equal(4, n.to.value)
  end)

  it("slice_expr allows nil from/to (open slice)", function()
    local base = ast.path_expr({"p", "q"})
    local n = ast.slice_expr(base, nil, nil)
    assert.is_nil(n.from)
    assert.is_nil(n.to)
  end)
end)

-- ============================================================
-- Operator constructors
-- ============================================================

describe("operator constructors", function()
  it("binary_op stores op and operands", function()
    local left  = ast.path_expr({"player", "health"})
    local right = ast.int_lit(0)
    local n = ast.binary_op(">", left, right)
    assert.equal(ast.K.BINARY_OP, n.kind)
    assert.equal(">", n.op)
    assert.equal(ast.K.PATH_EXPR, n.left.kind)
    assert.equal(ast.K.INT_LIT, n.right.kind)
  end)

  it("binary_op works for all comparison operators", function()
    local ops = {"=", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "and", "or"}
    for _, op in ipairs(ops) do
      local n = ast.binary_op(op, ast.int_lit(1), ast.int_lit(2))
      assert.equal(op, n.op)
    end
  end)

  it("unary_op stores op and expr", function()
    local n = ast.unary_op("not", ast.bool_lit(true))
    assert.equal(ast.K.UNARY_OP, n.kind)
    assert.equal("not", n.op)
  end)

  it("nil_coalesce stores left and right", function()
    local n = ast.nil_coalesce(
      ast.path_expr({"player", "companion"}),
      ast.symbol_lit("none"))
    assert.equal(ast.K.NIL_COALESCE, n.kind)
    assert.equal(ast.K.PATH_EXPR, n.left.kind)
    assert.equal(ast.K.SYMBOL_LIT, n.right.kind)
  end)

  it("fn_call stores name and args", function()
    local n = ast.fn_call("can-afford?", { ast.int_lit(40) })
    assert.equal(ast.K.FN_CALL, n.kind)
    assert.equal("can-afford?", n.name)
    assert.equal(1, #n.args)
  end)

  it("fn_call defaults args to empty list", function()
    local n = ast.fn_call("foo")
    assert.equal(0, #n.args)
  end)

  it("named_arg stores name and value", function()
    local n = ast.named_arg("depth", ast.int_lit(20))
    assert.equal(ast.K.NAMED_ARG, n.kind)
    assert.equal("depth", n.name)
    assert.equal(20, n.value.value)
  end)
end)

-- ============================================================
-- Control flow constructors
-- ============================================================

describe("control flow constructors", function()
  it("if_expr stores condition, then_body, else_body", function()
    local cond = ast.bool_lit(true)
    local then_b = { ast.pass_stmt() }
    local else_b = { ast.pass_stmt() }
    local n = ast.if_expr(cond, then_b, else_b)
    assert.equal(ast.K.IF_EXPR, n.kind)
    assert.equal(ast.K.BOOL_LIT, n.condition.kind)
    assert.equal(1, #n.then_body)
    assert.equal(1, #n.else_body)
  end)

  it("if_expr allows nil else_body", function()
    local n = ast.if_expr(ast.bool_lit(true), {}, nil)
    assert.is_nil(n.else_body)
  end)

  it("when_stmt stores condition and body", function()
    local n = ast.when_stmt(ast.bool_lit(false), { ast.pass_stmt() })
    assert.equal(ast.K.WHEN_STMT, n.kind)
    assert.equal(1, #n.body)
  end)

  it("match_expr stores expr and arms", function()
    local arm = ast.match_arm(ast.symbol_lit("alive"), nil, { ast.pass_stmt() })
    local n = ast.match_expr(ast.path_expr({"player", "status"}), { arm })
    assert.equal(ast.K.MATCH_EXPR, n.kind)
    assert.equal(1, #n.arms)
  end)

  it("match_arm stores pattern, fields, and body", function()
    local n = ast.match_arm("_", nil, { ast.pass_stmt() })
    assert.equal(ast.K.MATCH_ARM, n.kind)
    assert.equal("_", n.pattern)
    assert.is_nil(n.fields)
  end)

  it("cond_expr stores arms", function()
    local arm = ast.cond_arm(ast.bool_lit(true), { ast.pass_stmt() })
    local n = ast.cond_expr({ arm })
    assert.equal(ast.K.COND_EXPR, n.kind)
    assert.equal(1, #n.arms)
  end)

  it("for_stmt stores var, iter, body", function()
    local n = ast.for_stmt("npc", ast.fn_call("path-list", {}), { ast.pass_stmt() })
    assert.equal(ast.K.FOR_STMT, n.kind)
    assert.equal("npc", n.var)
    assert.equal(ast.K.FN_CALL, n.iter.kind)
  end)

  it("while_stmt stores condition and body", function()
    local n = ast.while_stmt(ast.bool_lit(true), { ast.pass_stmt() })
    assert.equal(ast.K.WHILE_STMT, n.kind)
  end)

  it("let_stmt stores bindings and body", function()
    local bindings = { ast.let_binding("x", ast.int_lit(5)) }
    local n = ast.let_stmt(bindings, { ast.pass_stmt() })
    assert.equal(ast.K.LET_STMT, n.kind)
    assert.equal(1, #n.bindings)
    assert.equal(1, #n.body)
  end)

  it("let_binding stores name and expr", function()
    local n = ast.let_binding("total", ast.int_lit(10))
    assert.equal(ast.K.LET_BINDING, n.kind)
    assert.equal("total", n.name)
    assert.equal(10, n.expr.value)
  end)

  it("lambda_expr stores params and body", function()
    local n = ast.lambda_expr({"x", "y"}, ast.binary_op("+", ast.int_lit(1), ast.int_lit(2)))
    assert.equal(ast.K.LAMBDA_EXPR, n.kind)
    assert.equal(2, #n.params)
  end)

  it("pass_stmt has correct kind", function()
    assert.equal(ast.K.PASS_STMT, ast.pass_stmt().kind)
  end)

  it("expr_stmt wraps an expression", function()
    local n = ast.expr_stmt(ast.fn_call("do-thing", {}))
    assert.equal(ast.K.EXPR_STMT, n.kind)
    assert.equal(ast.K.FN_CALL, n.expr.kind)
  end)
end)

-- ============================================================
-- Collection literal constructors
-- ============================================================

describe("collection literal constructors", function()
  it("set_lit stores elements", function()
    local n = ast.set_lit({ ast.symbol_lit("sword"), ast.symbol_lit("key") })
    assert.equal(ast.K.SET_LIT, n.kind)
    assert.equal(2, #n.elements)
  end)

  it("list_lit stores elements", function()
    local n = ast.list_lit({ ast.symbol_lit("north"), ast.symbol_lit("south") })
    assert.equal(ast.K.LIST_LIT, n.kind)
    assert.equal(2, #n.elements)
  end)

  it("map_lit stores entries", function()
    local entries = { { key = ast.string_lit("name"), value = ast.string_lit("Aldric") } }
    local n = ast.map_lit(entries)
    assert.equal(ast.K.MAP_LIT, n.kind)
    assert.equal(1, #n.entries)
  end)

  it("empty_set has correct kind", function()
    assert.equal(ast.K.EMPTY_SET, ast.empty_set().kind)
  end)

  it("empty_list has correct kind", function()
    assert.equal(ast.K.EMPTY_LIST, ast.empty_list().kind)
  end)

  it("empty_map has correct kind", function()
    assert.equal(ast.K.EMPTY_MAP, ast.empty_map().kind)
  end)
end)

-- ============================================================
-- Mutation primitive constructors
-- ============================================================

describe("mutation primitive constructors", function()
  local path = ast.path_expr({"player", "health"})

  it("set_mut stores path and value", function()
    local n = ast.set_mut(path, ast.int_lit(100))
    assert.equal(ast.K.SET_MUT, n.kind)
    assert.equal(ast.K.PATH_EXPR, n.path.kind)
    assert.equal(100, n.value.value)
  end)

  it("inc_mut stores path and amount", function()
    local n = ast.inc_mut(path, ast.int_lit(10))
    assert.equal(ast.K.INC_MUT, n.kind)
    assert.equal(10, n.amount.value)
  end)

  it("dec_mut stores path and amount", function()
    local n = ast.dec_mut(path, ast.int_lit(5))
    assert.equal(ast.K.DEC_MUT, n.kind)
    assert.equal(5, n.amount.value)
  end)

  it("add_mut stores path and value", function()
    local n = ast.add_mut(path, ast.symbol_lit("sword"))
    assert.equal(ast.K.ADD_MUT, n.kind)
  end)

  it("remove_mut stores path and value", function()
    local n = ast.remove_mut(path, ast.symbol_lit("potion"))
    assert.equal(ast.K.REMOVE_MUT, n.kind)
  end)

  it("clear_mut stores path", function()
    local n = ast.clear_mut(path)
    assert.equal(ast.K.CLEAR_MUT, n.kind)
    assert.equal(ast.K.PATH_EXPR, n.path.kind)
  end)

  it("push_mut stores path and value", function()
    local n = ast.push_mut(path, ast.int_lit(1))
    assert.equal(ast.K.PUSH_MUT, n.kind)
  end)

  it("pop_mut stores path", function()
    local n = ast.pop_mut(path)
    assert.equal(ast.K.POP_MUT, n.kind)
  end)

  it("relate_mut stores rel, a, b", function()
    local n = ast.relate_mut("exits", ast.symbol_lit("village"), ast.symbol_lit("forest"))
    assert.equal(ast.K.RELATE_MUT, n.kind)
    assert.equal("exits", n.rel)
  end)

  it("unrelate_mut stores rel, a, b", function()
    local n = ast.unrelate_mut("exits", ast.symbol_lit("village"), ast.symbol_lit("forest"))
    assert.equal(ast.K.UNRELATE_MUT, n.kind)
  end)

  it("spawn_mut stores family, key, record", function()
    local n = ast.spawn_mut("npcs", ast.symbol_lit("blacksmith"), ast.record_constructor("Npc", {}))
    assert.equal(ast.K.SPAWN_MUT, n.kind)
    assert.equal("npcs", n.family)
  end)

  it("despawn_mut stores family and key", function()
    local n = ast.despawn_mut("npcs", ast.symbol_lit("blacksmith"))
    assert.equal(ast.K.DESPAWN_MUT, n.kind)
    assert.equal("npcs", n.family)
  end)

  it("send_mut stores actor and msg", function()
    local n = ast.send_mut("guard", ast.record_constructor("ActorMsg", {}))
    assert.equal(ast.K.SEND_MUT, n.kind)
    assert.equal("guard", n.actor)
  end)

  it("time_inc_mut stores axes", function()
    local axes = { { name = "tick", value = 1, relative = true } }
    local n = ast.time_inc_mut(axes)
    assert.equal(ast.K.TIME_INC_MUT, n.kind)
    assert.equal(1, #n.axes)
  end)

  it("undo_mut stores steps (may be nil)", function()
    local n1 = ast.undo_mut(nil)
    assert.equal(ast.K.UNDO_MUT, n1.kind)
    assert.is_nil(n1.steps)

    local n2 = ast.undo_mut(3)
    assert.equal(3, n2.steps)
  end)

  it("goto_scene_mut stores target", function()
    local n = ast.goto_scene_mut("combat")
    assert.equal(ast.K.GOTO_SCENE_MUT, n.kind)
    assert.equal("combat", n.target)
  end)

  it("enter_scene_mut stores target", function()
    local n = ast.enter_scene_mut("talk-blacksmith")
    assert.equal(ast.K.ENTER_SCENE_MUT, n.kind)
    assert.equal("talk-blacksmith", n.target)
  end)

  it("exit_scene_mut has correct kind", function()
    assert.equal(ast.K.EXIT_SCENE_MUT, ast.exit_scene_mut().kind)
  end)

  it("schedule_mut stores name, opts, fn", function()
    local n = ast.schedule_mut("patrol", { every = "tick" }, "patrol-route")
    assert.equal(ast.K.SCHEDULE_MUT, n.kind)
    assert.equal("patrol", n.name)
  end)

  it("cancel_schedule_mut stores name", function()
    local n = ast.cancel_schedule_mut("patrol")
    assert.equal(ast.K.CANCEL_SCHEDULE_MUT, n.kind)
    assert.equal("patrol", n.name)
  end)
end)

-- ============================================================
-- Scene element constructors
-- ============================================================

describe("scene element constructors", function()
  it("narration_line stores text list", function()
    local n = ast.narration_line({"You are in the ", ast.inline_expr(ast.path_expr({"player","loc"}))})
    assert.equal(ast.K.NARRATION_LINE, n.kind)
    assert.equal(2, #n.text)
  end)

  it("cond_narration stores condition and text", function()
    local n = ast.cond_narration(ast.bool_lit(true), {"Watch out!"})
    assert.equal(ast.K.COND_NARRATION, n.kind)
    assert.equal(ast.K.BOOL_LIT, n.condition.kind)
  end)

  it("choice stores guard, label, body", function()
    local n = ast.choice(
      ast.fn_call("can-afford?", { ast.int_lit(40) }),
      {"Buy potion (40 gold)"},
      { ast.pass_stmt() })
    assert.equal(ast.K.CHOICE, n.kind)
    assert.equal(ast.K.FN_CALL, n.guard.kind)
    assert.equal(1, #n.body)
  end)

  it("choice allows nil guard", function()
    local n = ast.choice(nil, {"Enter the forest"}, { ast.pass_stmt() })
    assert.is_nil(n.guard)
  end)

  it("scene_goto with string target", function()
    local n = ast.scene_goto("forest")
    assert.equal(ast.K.SCENE_GOTO, n.kind)
    assert.equal("forest", n.target)
  end)

  it("scene_goto with expression target (computed goto)", function()
    local expr = ast.match_expr(ast.path_expr({"player", "location"}), {})
    local n = ast.scene_goto(expr)
    assert.equal(ast.K.MATCH_EXPR, n.target.kind)
  end)

  it("scene_enter stores target", function()
    local n = ast.scene_enter("talk-blacksmith")
    assert.equal(ast.K.SCENE_ENTER, n.kind)
    assert.equal("talk-blacksmith", n.target)
  end)

  it("scene_exit has correct kind", function()
    assert.equal(ast.K.SCENE_EXIT, ast.scene_exit().kind)
  end)

  it("inline_expr stores expression", function()
    local n = ast.inline_expr(ast.path_expr({"player", "health"}))
    assert.equal(ast.K.INLINE_EXPR, n.kind)
    assert.equal(ast.K.PATH_EXPR, n.expr.kind)
  end)
end)

-- ============================================================
-- Query / search constructors
-- ============================================================

describe("query and search constructors", function()
  it("find_expr stores family and clauses", function()
    local n = ast.find_expr("npc", { { kind = "where" } })
    assert.equal(ast.K.FIND_EXPR, n.kind)
    assert.equal("npc", n.family)
    assert.equal(1, #n.clauses)
  end)

  it("query_at_expr stores path and time", function()
    local n = ast.query_at_expr(
      ast.path_expr({"player", "location"}),
      ast.named_arg("tick", ast.int_lit(5)))
    assert.equal(ast.K.QUERY_AT_EXPR, n.kind)
  end)

  it("counterfactual_expr stores from_tick, transitions, simulate", function()
    local n = ast.counterfactual_expr(ast.int_lit(3), { ast.pass_stmt() }, true)
    assert.equal(ast.K.COUNTERFACTUAL_EXPR, n.kind)
    assert.is_true(n.simulate)
    assert.equal(3, n.from_tick.value)
  end)

  it("in_state_expr stores state_expr and inner_expr", function()
    local gs = ast.symbol_lit("alt")
    local inner = ast.path_expr({"player", "health"})
    local n = ast.in_state_expr(gs, inner)
    assert.equal(ast.K.IN_STATE_EXPR, n.kind)
    assert.equal(ast.K.SYMBOL_LIT, n.state_expr.kind)
    assert.equal(ast.K.PATH_EXPR, n.inner_expr.kind)
  end)
end)

-- ============================================================
-- Record constructor
-- ============================================================

describe("ast.record_constructor", function()
  it("stores type_name and fields", function()
    local fields = { ast.named_arg("name", ast.string_lit("Aldric")) }
    local n = ast.record_constructor("Npc", fields)
    assert.equal(ast.K.RECORD_CONSTRUCTOR, n.kind)
    assert.equal("Npc", n.type_name)
    assert.equal(1, #n.fields)
  end)
end)

-- ============================================================
-- Predicates
-- ============================================================

describe("ast.is_decl", function()
  it("returns true for declaration nodes", function()
    assert.is_true(ast.is_decl(ast.fn_decl("f", nil, nil, nil, nil, nil)))
    assert.is_true(ast.is_decl(ast.scene_decl("s", {})))
    assert.is_true(ast.is_decl(ast.type_enum("E", {})))
    assert.is_true(ast.is_decl(ast.state_scalar("p", ast.type_bool(), nil)))
    assert.is_true(ast.is_decl(ast.module_decl("m", "1")))
    assert.is_true(ast.is_decl(ast.schema_version(1)))
  end)

  it("returns false for non-declaration nodes", function()
    assert.is_false(ast.is_decl(ast.int_lit(1)))
    assert.is_false(ast.is_decl(ast.binary_op("+", ast.int_lit(1), ast.int_lit(2))))
    assert.is_false(ast.is_decl(ast.set_mut(ast.path_expr({"p"}), ast.int_lit(0))))
    assert.is_false(ast.is_decl(ast.type_bool()))
  end)

  it("returns false for nil", function()
    assert.is_false(ast.is_decl(nil))
  end)
end)

describe("ast.is_mut", function()
  it("returns true for mutation primitive nodes", function()
    local path = ast.path_expr({"player", "health"})
    assert.is_true(ast.is_mut(ast.set_mut(path, ast.int_lit(0))))
    assert.is_true(ast.is_mut(ast.inc_mut(path, ast.int_lit(1))))
    assert.is_true(ast.is_mut(ast.dec_mut(path, ast.int_lit(1))))
    assert.is_true(ast.is_mut(ast.add_mut(path, ast.symbol_lit("x"))))
    assert.is_true(ast.is_mut(ast.remove_mut(path, ast.symbol_lit("x"))))
    assert.is_true(ast.is_mut(ast.clear_mut(path)))
    assert.is_true(ast.is_mut(ast.push_mut(path, ast.int_lit(1))))
    assert.is_true(ast.is_mut(ast.pop_mut(path)))
    assert.is_true(ast.is_mut(ast.spawn_mut("f", ast.symbol_lit("k"), ast.record_constructor("T", {}))))
    assert.is_true(ast.is_mut(ast.despawn_mut("f", ast.symbol_lit("k"))))
    assert.is_true(ast.is_mut(ast.send_mut("actor", ast.record_constructor("M", {}))))
    assert.is_true(ast.is_mut(ast.time_inc_mut({})))
    assert.is_true(ast.is_mut(ast.undo_mut(nil)))
    assert.is_true(ast.is_mut(ast.goto_scene_mut("s")))
    assert.is_true(ast.is_mut(ast.enter_scene_mut("s")))
    assert.is_true(ast.is_mut(ast.exit_scene_mut()))
  end)

  it("returns false for non-mutation nodes", function()
    assert.is_false(ast.is_mut(ast.int_lit(1)))
    assert.is_false(ast.is_mut(ast.fn_call("foo", {})))
    assert.is_false(ast.is_mut(ast.pass_stmt()))
    assert.is_false(ast.is_mut(ast.fn_decl("f", nil, nil, nil, nil, nil)))
  end)

  it("returns false for nil", function()
    assert.is_false(ast.is_mut(nil))
  end)
end)

describe("ast.is_type_expr", function()
  it("returns true for type expression nodes", function()
    assert.is_true(ast.is_type_expr(ast.type_bool()))
    assert.is_true(ast.is_type_expr(ast.type_int(0, 10)))
    assert.is_true(ast.is_type_expr(ast.type_string()))
    assert.is_true(ast.is_type_expr(ast.type_float()))
    assert.is_true(ast.is_type_expr(ast.type_named("Foo")))
    assert.is_true(ast.is_type_expr(ast.type_symbol()))
    assert.is_true(ast.is_type_expr(ast.type_symbol_of("npcs")))
    assert.is_true(ast.is_type_expr(ast.type_option(ast.type_bool())))
    assert.is_true(ast.is_type_expr(ast.type_set(ast.type_named("X"), 5)))
    assert.is_true(ast.is_type_expr(ast.type_list(ast.type_named("X"), 5)))
    assert.is_true(ast.is_type_expr(ast.type_ulist(ast.type_string())))
    assert.is_true(ast.is_type_expr(ast.type_umap(ast.type_string(), ast.type_bool())))
  end)

  it("returns false for non-type-expression nodes", function()
    assert.is_false(ast.is_type_expr(ast.int_lit(1)))
    assert.is_false(ast.is_type_expr(ast.fn_decl("f", nil, nil, nil, nil, nil)))
  end)

  it("returns false for nil", function()
    assert.is_false(ast.is_type_expr(nil))
  end)
end)

-- ============================================================
-- Diagnostic accumulator
-- ============================================================

describe("ast.new_accum", function()
  it("returns a table with empty errors, warnings, all lists", function()
    local acc = ast.new_accum()
    assert.is_true(is_table(acc.errors))
    assert.is_true(is_table(acc.warnings))
    assert.is_true(is_table(acc.all))
    assert.equal(0, #acc.errors)
    assert.equal(0, #acc.warnings)
    assert.equal(0, #acc.all)
  end)

  it("push adds an error to .errors and .all", function()
    local acc = ast.new_accum()
    local d = ast.error("CODE", "msg", ast.pos("f", 1, 1))
    acc:push(d)
    assert.equal(1, #acc.errors)
    assert.equal(0, #acc.warnings)
    assert.equal(1, #acc.all)
    assert.equal(d, acc.errors[1])
    assert.equal(d, acc.all[1])
  end)

  it("push adds a warning to .warnings and .all", function()
    local acc = ast.new_accum()
    local d = ast.warning("W_CODE", "beware", ast.pos("f", 1, 1))
    acc:push(d)
    assert.equal(0, #acc.errors)
    assert.equal(1, #acc.warnings)
    assert.equal(1, #acc.all)
  end)

  it("has_errors returns false when no errors", function()
    local acc = ast.new_accum()
    assert.is_false(acc:has_errors())
  end)

  it("has_errors returns true when at least one error is present", function()
    local acc = ast.new_accum()
    acc:push(ast.error("E", "e", ast.pos("f", 1, 1)))
    assert.is_true(acc:has_errors())
  end)

  it("has_errors remains false when only warnings are present", function()
    local acc = ast.new_accum()
    acc:push(ast.warning("W", "w", ast.pos("f", 1, 1)))
    assert.is_false(acc:has_errors())
  end)

  it("push_all adds all diagnostics from a list", function()
    local acc = ast.new_accum()
    local diags = {
      ast.error("E1", "e1", ast.pos("f", 1, 1)),
      ast.warning("W1", "w1", ast.pos("f", 2, 1)),
      ast.error("E2", "e2", ast.pos("f", 3, 1)),
    }
    acc:push_all(diags)
    assert.equal(3, #acc.all)
    assert.equal(2, #acc.errors)
    assert.equal(1, #acc.warnings)
  end)

  it("push_all is a no-op on an empty list", function()
    local acc = ast.new_accum()
    acc:push_all({})
    assert.equal(0, #acc.all)
  end)

  it("push_all is a no-op on nil", function()
    local acc = ast.new_accum()
    acc:push_all(nil)
    assert.equal(0, #acc.all)
  end)

  it("merge copies all diagnostics from another accumulator", function()
    local acc1 = ast.new_accum()
    acc1:push(ast.error("E1", "e1", ast.pos("f", 1, 1)))

    local acc2 = ast.new_accum()
    acc2:push(ast.warning("W1", "w1", ast.pos("f", 2, 1)))

    acc1:merge(acc2)
    assert.equal(2, #acc1.all)
    assert.equal(1, #acc1.errors)
    assert.equal(1, #acc1.warnings)
  end)

  it("merge is a no-op on nil", function()
    local acc = ast.new_accum()
    acc:push(ast.error("E", "e", ast.pos("f", 1, 1)))
    acc:merge(nil)
    assert.equal(1, #acc.all)
  end)

  it("push_error convenience method works", function()
    local acc = ast.new_accum()
    acc:push_error("CODE", "message", ast.pos("f", 1, 1), "note text")
    assert.equal(1, #acc.errors)
    assert.equal("CODE", acc.errors[1].code)
    assert.equal("note text", acc.errors[1].note)
  end)

  it("push_warning convenience method works", function()
    local acc = ast.new_accum()
    acc:push_warning("W_CODE", "be careful", ast.pos("f", 5, 3))
    assert.equal(1, #acc.warnings)
    assert.equal("W_CODE", acc.warnings[1].code)
    assert.equal(5, acc.warnings[1].line)
  end)

  it("preserves ordering of pushes", function()
    local acc = ast.new_accum()
    local codes = { "A", "B", "C", "D" }
    for _, c in ipairs(codes) do
      acc:push(ast.error(c, c, ast.pos("f", 1, 1)))
    end
    for i, c in ipairs(codes) do
      assert.equal(c, acc.all[i].code)
    end
  end)

  it("independent accumulators do not share state", function()
    local acc1 = ast.new_accum()
    local acc2 = ast.new_accum()
    acc1:push(ast.error("E", "e", ast.pos("f", 1, 1)))
    assert.equal(0, #acc2.all)
  end)
end)

-- ============================================================
-- Verify and watch constructors
-- ============================================================

describe("ast.verify_decl", function()
  it("stores label and clauses", function()
    local clause = ast.verify_clause("from_any_state", nil, {})
    local n = ast.verify_decl("health is non-negative", { clause })
    assert.equal(ast.K.VERIFY_DECL, n.kind)
    assert.equal("health is non-negative", n.label)
    assert.equal(1, #n.clauses)
  end)
end)

describe("ast.verify_clause", function()
  it("stores clause_kind, condition, body", function()
    local cond = ast.binary_op(">=", ast.path_expr({"player", "health"}), ast.int_lit(0))
    local n = ast.verify_clause("when", cond, {})
    assert.equal(ast.K.VERIFY_CLAUSE, n.kind)
    assert.equal("when", n.clause_kind)
    assert.equal(ast.K.BINARY_OP, n.condition.kind)
  end)
end)

describe("ast.watch_decl", function()
  it("stores path and label", function()
    local n = ast.watch_decl(ast.path_expr({"player", "health"}), "HP")
    assert.equal(ast.K.WATCH_DECL, n.kind)
    assert.equal("HP", n.label)
  end)
end)

describe("ast.watch_when_decl", function()
  it("stores condition and label", function()
    local cond = ast.binary_op("=", ast.path_expr({"player", "status"}), ast.symbol_lit("dead"))
    local n = ast.watch_when_decl(cond, "Player died")
    assert.equal(ast.K.WATCH_WHEN_DECL, n.kind)
    assert.equal("Player died", n.label)
    assert.equal(ast.K.BINARY_OP, n.condition.kind)
  end)
end)

-- ============================================================
-- Additional edge cases
-- ============================================================

describe("node pos attachment", function()
  it("every constructor preserves pos when given", function()
    local p = ast.pos("edge.sb", 99, 42)
    local nodes = {
      ast.int_lit(1, p),
      ast.string_lit("x", p),
      ast.symbol_lit("s", p),
      ast.bool_lit(true, p),
      ast.type_bool(p),
      ast.fn_decl("f", nil, nil, nil, nil, nil, nil, p),
      ast.scene_decl("s", {}, nil, p),
      ast.pass_stmt(p),
    }
    for i, n in ipairs(nodes) do
      assert.equal(99, n.pos.line, "Node #" .. i .. " should have line 99")
      assert.equal(42, n.pos.col,  "Node #" .. i .. " should have col 42")
    end
  end)
end)

describe("doc string storage", function()
  it("type_enum stores doc string", function()
    local n = ast.type_enum("S", {}, "A status enum")
    assert.equal("A status enum", n.doc)
  end)

  it("fn_decl stores doc string", function()
    local n = ast.fn_decl("move-to", nil, nil, nil, nil, nil, "Move the player")
    assert.equal("Move the player", n.doc)
  end)

  it("state_scalar stores doc string", function()
    local n = ast.state_scalar("player", ast.type_bool(), nil, "Player state root")
    assert.equal("Player state root", n.doc)
  end)
end)

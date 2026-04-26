-- tests/runtime/query_spec.lua
-- Tests for runtime/query.lua (find queries and relation queries).
--
-- Run with: busted tests/

local query     = require("runtime.query")
local eval_mod  = require("runtime.eval")
local state_mod = require("runtime.state")
local log_mod   = require("runtime.log")
local compiler  = require("compiler.compiler")

-- ============================================================
-- Helpers
-- ============================================================

local function make_store(vals)
  local l = log_mod.new()
  local s = state_mod.new({ types = {}, states = {} }, l)
  for k, v in pairs(vals or {}) do
    s:set(k, v)
  end
  return s
end

local function make_ctx(vals)
  local s = make_store(vals)
  return eval_mod.new_ctx(s, {}, "test")
end

-- AST helpers
local function path(...)   return { kind = "path_expr",  segments = { ... } } end
local function interp(...)
  local segs = {}
  for _, v in ipairs({ ... }) do
    if type(v) == "table" then segs[#segs+1] = v
    else segs[#segs+1] = v end
  end
  return { kind = "interp_path", segments = segs }
end
local function int_lit(n) return { kind = "int_lit", value = n } end
local function binop(op, l, r) return { kind = "binary_op", op = op, left = l, right = r } end
local function fn_call(name, ...) return { kind = "fn_call", name = name, args = { ... } } end

-- ============================================================
-- find query: basic
-- ============================================================

describe("find query: basic", function()
  it("returns all family keys when no clauses", function()
    local c = make_ctx({
      ["npcs/guard/hp"] = 100,
      ["npcs/mage/hp"]  = 80,
    })
    local result = query.find(c, "npcs", {})
    table.sort(result)
    assert.same({ "guard", "mage" }, result)
  end)

  it("returns empty list when family has no members", function()
    local c = make_ctx({})
    local result = query.find(c, "npcs", {})
    assert.same({}, result)
  end)
end)

-- ============================================================
-- find query: where clause
-- ============================================================

describe("find query: where clause", function()
  it("filters members by condition", function()
    local c = make_ctx({
      ["npcs/guard/hp"] = 100,
      ["npcs/mage/hp"]  = 30,
      ["npcs/thief/hp"] = 50,
    })
    -- where: npcs/{npcs}/hp > 40
    local where_cond = binop(">",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "hp" } },
      int_lit(40))
    local result = query.find(c, "npcs", {
      { kind = "where", condition = where_cond }
    })
    table.sort(result)
    assert.same({ "guard", "thief" }, result)
  end)

  it("handles multiple where clauses (AND)", function()
    local c = make_ctx({
      ["npcs/guard/hp"]     = 100,
      ["npcs/guard/alive"]  = true,
      ["npcs/mage/hp"]      = 80,
      ["npcs/mage/alive"]   = false,
      ["npcs/thief/hp"]     = 50,
      ["npcs/thief/alive"]  = true,
    })
    -- where npcs/{npcs}/hp > 60 and npcs/{npcs}/alive = true
    local cond1 = binop(">",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "hp" } },
      int_lit(60))
    local cond2 = binop("=",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "alive" } },
      { kind = "bool_lit", value = true })
    local result = query.find(c, "npcs", {
      { kind = "where", condition = cond1 },
      { kind = "where", condition = cond2 },
    })
    assert.same({ "guard" }, result)
  end)
end)

-- ============================================================
-- find query: or-where clause
-- ============================================================

describe("find query: or-where clause", function()
  it("or-where ORs with preceding where clause", function()
    local c = make_ctx({
      ["npcs/guard/hp"]  = 100,
      ["npcs/mage/hp"]   = 30,
      ["npcs/thief/hp"]  = 50,
      ["npcs/boss/hp"]   = 10,
      ["npcs/boss/boss"] = true,
    })
    -- where hp > 60 or-where boss = true
    local cond_hp = binop(">",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "hp" } },
      int_lit(60))
    local cond_boss = binop("=",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "boss" } },
      { kind = "bool_lit", value = true })
    local result = query.find(c, "npcs", {
      { kind = "where",    condition = cond_hp },
      { kind = "or_where", condition = cond_boss },
    })
    table.sort(result)
    -- guard (hp=100 passes first branch) and boss (boss=true passes second branch)
    assert.same({ "boss", "guard" }, result)
  end)

  it("multiple where before or-where ANDs them together", function()
    local c = make_ctx({
      ["npcs/guard/hp"]     = 100,
      ["npcs/guard/alive"]  = true,
      ["npcs/mage/hp"]      = 80,
      ["npcs/mage/alive"]   = false,
      ["npcs/boss/hp"]      = 10,
      ["npcs/boss/alive"]   = false,
      ["npcs/boss/special"] = true,
    })
    -- where hp > 60 where alive = true or-where special = true
    -- = (hp>60 AND alive) OR special
    local cond_hp = binop(">",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "hp" } },
      int_lit(60))
    local cond_alive = binop("=",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "alive" } },
      { kind = "bool_lit", value = true })
    local cond_special = binop("=",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "special" } },
      { kind = "bool_lit", value = true })
    local result = query.find(c, "npcs", {
      { kind = "where",    condition = cond_hp },
      { kind = "where",    condition = cond_alive },
      { kind = "or_where", condition = cond_special },
    })
    table.sort(result)
    -- guard: hp=100 AND alive=true → passes first branch
    -- boss:  special=true → passes second branch
    -- mage:  hp=80 but alive=false → fails first; special=nil → fails second
    assert.same({ "boss", "guard" }, result)
  end)

  it("multiple or-where clauses independently OR", function()
    local c = make_ctx({
      ["npcs/a/tag"] = "friendly",
      ["npcs/b/tag"] = "hostile",
      ["npcs/c/tag"] = "neutral",
      ["npcs/d/tag"] = "boss",
    })
    local function tag_eq(v)
      return binop("=",
        { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "tag" } },
        { kind = "string_lit", value = v })
    end
    -- where tag=friendly or-where tag=hostile or-where tag=boss
    local result = query.find(c, "npcs", {
      { kind = "where",    condition = tag_eq("friendly") },
      { kind = "or_where", condition = tag_eq("hostile") },
      { kind = "or_where", condition = tag_eq("boss") },
    })
    table.sort(result)
    assert.same({ "a", "b", "d" }, result)
  end)

  it("or-where followed by where ANDs into the new branch", function()
    local c = make_ctx({
      ["npcs/a/type"]  = "fighter",
      ["npcs/a/elite"] = true,
      ["npcs/b/type"]  = "fighter",
      ["npcs/b/elite"] = false,
      ["npcs/c/type"]  = "mage",
      ["npcs/c/elite"] = true,
    })
    -- where type=fighter or-where type=mage where elite=true
    -- = (type=fighter) OR (type=mage AND elite=true)
    local cond_fighter = binop("=",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "type" } },
      { kind = "string_lit", value = "fighter" })
    local cond_mage = binop("=",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "type" } },
      { kind = "string_lit", value = "mage" })
    local cond_elite = binop("=",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "elite" } },
      { kind = "bool_lit", value = true })
    local result = query.find(c, "npcs", {
      { kind = "where",    condition = cond_fighter },
      { kind = "or_where", condition = cond_mage },
      { kind = "where",    condition = cond_elite },
    })
    table.sort(result)
    -- a: fighter → passes first branch
    -- b: fighter → passes first branch
    -- c: mage AND elite=true → passes second branch
    assert.same({ "a", "b", "c" }, result)
  end)
end)

-- ============================================================
-- find query: order-by
-- ============================================================

describe("find query: order-by", function()
  it("orders by numeric path ascending", function()
    local c = make_ctx({
      ["npcs/a/hp"] = 30,
      ["npcs/b/hp"] = 10,
      ["npcs/c/hp"] = 20,
    })
    local order_path = { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "hp" } }
    local result = query.find(c, "npcs", {
      { kind = "order_by", path = order_path, dir = "asc" }
    })
    assert.same({ "b", "c", "a" }, result)
  end)

  it("orders by numeric path descending", function()
    local c = make_ctx({
      ["npcs/a/hp"] = 30,
      ["npcs/b/hp"] = 10,
      ["npcs/c/hp"] = 20,
    })
    local order_path = { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "hp" } }
    local result = query.find(c, "npcs", {
      { kind = "order_by", path = order_path, dir = "desc" }
    })
    assert.same({ "a", "c", "b" }, result)
  end)
end)

-- ============================================================
-- find query: limit
-- ============================================================

describe("find query: limit", function()
  it("limits the result set", function()
    local c = make_ctx({
      ["npcs/a/hp"] = 1,
      ["npcs/b/hp"] = 2,
      ["npcs/c/hp"] = 3,
    })
    local order_path = { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "hp" } }
    local result = query.find(c, "npcs", {
      { kind = "order_by", path = order_path, dir = "asc" },
      { kind = "limit", value = 2 },
    })
    assert.equal(2, #result)
    assert.equal("a", result[1])
    assert.equal("b", result[2])
  end)
end)

-- ============================================================
-- find query: count
-- ============================================================

describe("find query: count", function()
  it("returns integer count of matching members", function()
    local c = make_ctx({
      ["npcs/a/hp"] = 100,
      ["npcs/b/hp"] = 50,
      ["npcs/c/hp"] = 80,
    })
    local where_cond = binop(">",
      { kind = "interp_path", segments = { "npcs", { interp = "npcs" }, "hp" } },
      int_lit(60))
    local result = query.find(c, "npcs", {
      { kind = "where",  condition = where_cond },
      { kind = "count" },
    })
    assert.equal(2, result)
  end)

  it("count with no where returns total members", function()
    local c = make_ctx({
      ["npcs/a/hp"] = 1,
      ["npcs/b/hp"] = 2,
    })
    local result = query.find(c, "npcs", { { kind = "count" } })
    assert.equal(2, result)
  end)
end)

-- ============================================================
-- relation queries
-- ============================================================

describe("query.adjacent", function()
  it("returns adjacent set for a source", function()
    local rel = { data = { a = { b = true, c = true }, b = { c = true } } }
    local adj = query.adjacent(rel, "a")
    assert.is_true(adj["b"])
    assert.is_true(adj["c"])
    assert.is_nil(adj["a"])
  end)

  it("returns empty table for unknown source", function()
    local rel = { data = { a = { b = true } } }
    local adj = query.adjacent(rel, "z")
    assert.same({}, adj)
  end)
end)

describe("query.reachable", function()
  it("returns true for directly connected nodes", function()
    local rel = { data = { a = { b = true } } }
    assert.is_true(query.reachable(rel, "a", "b"))
  end)

  it("returns true for multi-hop path", function()
    local rel = { data = { a = { b = true }, b = { c = true } } }
    assert.is_true(query.reachable(rel, "a", "c"))
  end)

  it("returns false when no path", function()
    local rel = { data = { a = { b = true }, c = { d = true } } }
    assert.is_false(query.reachable(rel, "a", "d"))
  end)

  it("respects max_hops", function()
    local rel = { data = { a = { b = true }, b = { c = true }, c = { d = true } } }
    assert.is_false(query.reachable(rel, "a", "d", 1))
    assert.is_true(query.reachable(rel, "a", "d", 3))
  end)

  it("returns false for nil relation", function()
    assert.is_false(query.reachable(nil, "a", "b"))
  end)
end)

describe("query.shortest_path", function()
  it("returns single-element path for same source and target", function()
    local rel = { data = {} }
    local path_result = query.shortest_path(rel, "a", "a")
    assert.same({ "a" }, path_result)
  end)

  it("returns direct path", function()
    local rel = { data = { a = { b = true } } }
    local path_result = query.shortest_path(rel, "a", "b")
    assert.same({ "a", "b" }, path_result)
  end)

  it("returns BFS-shortest path", function()
    local rel = {
      data = {
        a = { b = true, c = true },
        b = { d = true },
        c = { d = true },
      }
    }
    local path_result = query.shortest_path(rel, "a", "d")
    assert.equal(3, #path_result)
    assert.equal("a", path_result[1])
    assert.equal("d", path_result[3])
  end)

  it("returns nil when unreachable", function()
    local rel = { data = { a = { b = true } } }
    assert.is_nil(query.shortest_path(rel, "a", "z"))
  end)
end)

describe("query.reachable_set", function()
  it("returns all reachable nodes from source", function()
    local rel = { data = { a = { b = true, c = true }, b = { d = true } } }
    local rset = query.reachable_set(rel, "a")
    assert.is_true(rset["b"])
    assert.is_true(rset["c"])
    assert.is_true(rset["d"])
    assert.is_nil(rset["a"])  -- source excluded
  end)

  it("respects max_hops", function()
    local rel = { data = { a = { b = true }, b = { c = true } } }
    local rset = query.reachable_set(rel, "a", 1)
    assert.is_true(rset["b"])
    assert.is_nil(rset["c"])
  end)
end)

describe("query.inverse_adjacent", function()
  it("returns nodes that point to target", function()
    local rel = { data = { a = { c = true }, b = { c = true }, d = { e = true } } }
    local inv = query.inverse_adjacent(rel, "c")
    assert.is_true(inv["a"])
    assert.is_true(inv["b"])
    assert.is_nil(inv["d"])
  end)

  it("returns empty for unknown target", function()
    local rel = { data = { a = { b = true } } }
    assert.same({}, query.inverse_adjacent(rel, "z"))
  end)
end)

-- ============================================================
-- Relation builtins via eval (language-level integration)
-- ============================================================

-- Helper: build a ctx with a compiled game that has an "exits" relation
-- exits: village→[forest,cave], forest→[village,mountain], cave→[village]
local function make_ctx_with_game(extra_state)
  local src = [[
state world:
  day: Int(0,100) = 0

type Place = village | forest | cave | mountain

relation exits: Place -> Set(Place, 4):
  'village: ['forest, 'cave]
  'forest:  ['village, 'mountain]
  'cave:    ['village]
]]
  local gt, diags = compiler.compile(src, "relation-test")
  assert.is_false(diags:has_errors(), table.concat(
    (function() local t={}; for _,e in ipairs(diags.errors) do t[#t+1]=e.message end; return t end)(), "; "))
  local l = log_mod.new()
  local s = state_mod.new(gt.schema, l)
  s:init_defaults()
  for k, v in pairs(extra_state or {}) do s:set(k, v) end
  local c = eval_mod.new_ctx(s, gt.fns, "test")
  c.game = gt
  return c
end

local K = require("compiler.ast").K

local function fn_call_node(name, ...)
  return { kind = K.FN_CALL, name = name, args = { ... } }
end

local function sym_node(v)
  return { kind = K.SYMBOL_LIT, name = v }
end

local function str_node(v)
  return { kind = K.STRING_LIT, value = v }
end

local function named_arg_node(name, val)
  return { kind = K.NAMED_ARG, name = name, value = val }
end

local function int_node(n)
  return { kind = K.INT_LIT, value = n }
end

-- Bare ident node (0-arg fn_call → returns name as string)
local function ident_node(name)
  return { kind = K.FN_CALL, name = name, args = {} }
end

describe("eval: adjacent? builtin", function()
  it("returns adjacent set as table with bool values", function()
    local c = make_ctx_with_game()
    local node = fn_call_node("adjacent?", ident_node("exits"), sym_node("village"))
    local result = eval_mod.eval_expr(node, c)
    assert.is_table(result)
    assert.is_true(result["forest"])
    assert.is_true(result["cave"])
    assert.is_nil(result["village"])
  end)

  it("returns empty table for node with no outgoing edges", function()
    local c = make_ctx_with_game()
    -- 'mountain has no outgoing exits in this relation
    local node = fn_call_node("adjacent?", ident_node("exits"), sym_node("mountain"))
    local result = eval_mod.eval_expr(node, c)
    assert.same({}, result)
  end)
end)

describe("eval: reachable? builtin", function()
  it("returns true for direct connection", function()
    local c = make_ctx_with_game()
    local node = fn_call_node("reachable?", ident_node("exits"), sym_node("village"), sym_node("forest"))
    assert.is_true(eval_mod.eval_expr(node, c))
  end)

  it("returns true for multi-hop path", function()
    local c = make_ctx_with_game()
    -- village → forest → mountain
    local node = fn_call_node("reachable?", ident_node("exits"), sym_node("village"), sym_node("mountain"))
    assert.is_true(eval_mod.eval_expr(node, c))
  end)

  it("returns false when no path exists", function()
    local c = make_ctx_with_game()
    -- mountain has no outgoing edges, so mountain → village is false
    local node = fn_call_node("reachable?", ident_node("exits"), sym_node("mountain"), sym_node("village"))
    assert.is_false(eval_mod.eval_expr(node, c))
  end)

  it("respects max-hops: named arg", function()
    local c = make_ctx_with_game()
    -- village → forest → mountain needs 2 hops; max-hops: 1 should fail
    local node_1hop = fn_call_node("reachable?",
      ident_node("exits"), sym_node("village"), sym_node("mountain"),
      named_arg_node("max-hops", int_node(1)))
    local node_2hop = fn_call_node("reachable?",
      ident_node("exits"), sym_node("village"), sym_node("mountain"),
      named_arg_node("max-hops", int_node(2)))
    assert.is_false(eval_mod.eval_expr(node_1hop, c))
    assert.is_true(eval_mod.eval_expr(node_2hop, c))
  end)
end)

describe("eval: shortest-path builtin", function()
  it("returns path list including endpoints", function()
    local c = make_ctx_with_game()
    local node = fn_call_node("shortest-path", ident_node("exits"), sym_node("village"), sym_node("mountain"))
    local result = eval_mod.eval_expr(node, c)
    assert.equal(3, #result)
    assert.equal("village", result[1])
    assert.equal("mountain", result[3])
    assert.equal("forest", result[2])
  end)

  it("returns nil when no path", function()
    local c = make_ctx_with_game()
    local node = fn_call_node("shortest-path", ident_node("exits"), sym_node("mountain"), sym_node("village"))
    assert.is_nil(eval_mod.eval_expr(node, c))
  end)
end)

describe("eval: reachable-set builtin", function()
  it("returns all reachable nodes from source", function()
    local c = make_ctx_with_game()
    local node = fn_call_node("reachable-set", ident_node("exits"), sym_node("cave"))
    local result = eval_mod.eval_expr(node, c)
    -- cave → village → forest → mountain, cave
    assert.is_true(result["village"])
    assert.is_true(result["forest"])
    assert.is_true(result["mountain"])
    assert.is_nil(result["cave"])  -- source excluded
  end)

  it("respects max-hops: named arg", function()
    local c = make_ctx_with_game()
    local node = fn_call_node("reachable-set", ident_node("exits"), sym_node("village"),
      named_arg_node("max-hops", int_node(1)))
    local result = eval_mod.eval_expr(node, c)
    assert.is_true(result["forest"])
    assert.is_true(result["cave"])
    assert.is_nil(result["mountain"])  -- 2 hops away
  end)
end)

describe("eval: inverse-adjacent? builtin", function()
  it("returns set of nodes pointing to target", function()
    local c = make_ctx_with_game()
    -- village is pointed to by: forest and cave
    local node = fn_call_node("inverse-adjacent?", ident_node("exits"), sym_node("village"))
    local result = eval_mod.eval_expr(node, c)
    assert.is_true(result["forest"])
    assert.is_true(result["cave"])
    assert.is_nil(result["village"])
  end)

  it("returns empty for node not pointed to by anyone", function()
    local c = make_ctx_with_game()
    -- 'village is pointed to by forest and cave; 'unknown has no incoming edges
    local node = fn_call_node("inverse-adjacent?", ident_node("exits"), sym_node("unknown"))
    local result = eval_mod.eval_expr(node, c)
    assert.same({}, result)
  end)
end)

-- ============================================================
-- find: within N hops / connected-to clauses
-- (uses make_ctx with manually-set state paths + injected game.relations)
-- ============================================================

-- Build a ctx with places family members set and exits relation injected
local function make_places_ctx(state_vals, rel_data)
  local c = make_ctx(state_vals)
  c.game = {
    relations = {
      exits = { name = "exits", data = rel_data }
    }
  }
  return c
end

describe("find: within N hops clause", function()
  it("filters family members within N hops of source", function()
    -- places family: village, forest, cave, mountain, dungeon (set via state paths)
    -- exits: village→[forest,cave], forest→[village,mountain], cave→[village]
    -- dungeon has no connections → unreachable from village
    local c = make_places_ctx({
      ["places/village/name"] = "village",
      ["places/forest/name"]  = "forest",
      ["places/cave/name"]    = "cave",
      ["places/mountain/name"] = "mountain",
      ["places/dungeon/name"] = "dungeon",
    }, {
      village = { forest = true, cave = true },
      forest  = { village = true, mountain = true },
      cave    = { village = true },
    })

    -- within 1 hop of village: directly forest and cave
    local src_expr = sym_node("village")
    local clauses = {
      { kind = "within", relation_name = "exits", hops = 1, from = src_expr }
    }
    local result = query.find(c, "places", clauses)
    table.sort(result)
    assert.same({ "cave", "forest" }, result)
  end)

  it("within 2 hops includes transitively reachable members", function()
    -- village → forest → mountain; dungeon unreachable
    local c = make_places_ctx({
      ["places/village/name"]  = "village",
      ["places/forest/name"]   = "forest",
      ["places/mountain/name"] = "mountain",
      ["places/dungeon/name"]  = "dungeon",
    }, {
      village = { forest = true },
      forest  = { mountain = true },
    })

    local src_expr = sym_node("village")
    local clauses2 = { { kind = "within", relation_name = "exits", hops = 2, from = src_expr } }
    local result2 = query.find(c, "places", clauses2)
    table.sort(result2)
    assert.same({ "forest", "mountain" }, result2)

    local clauses1 = { { kind = "within", relation_name = "exits", hops = 1, from = src_expr } }
    local result1 = query.find(c, "places", clauses1)
    table.sort(result1)
    assert.same({ "forest" }, result1)
  end)
end)

describe("find: connected-to clause", function()
  it("filters to members connected in either direction", function()
    -- village → forest; cave → village; dungeon isolated
    local c = make_places_ctx({
      ["places/village/name"] = "village",
      ["places/forest/name"]  = "forest",
      ["places/cave/name"]    = "cave",
      ["places/dungeon/name"] = "dungeon",
    }, {
      village = { forest = true },
      cave    = { village = true },
    })

    -- connected-to village: forest (village→forest) and cave (cave→village)
    local target_expr = sym_node("village")
    local clauses = { { kind = "connected_to", relation_name = "exits", path = target_expr } }
    local result = query.find(c, "places", clauses)
    table.sort(result)
    assert.same({ "cave", "forest" }, result)
  end)
end)

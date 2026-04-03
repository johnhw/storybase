-- tests/runtime/query_spec.lua
-- Tests for runtime/query.lua (find queries and relation queries).
--
-- Run with: busted tests/

local query     = require("runtime.query")
local eval_mod  = require("runtime.eval")
local state_mod = require("runtime.state")
local log_mod   = require("runtime.log")

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

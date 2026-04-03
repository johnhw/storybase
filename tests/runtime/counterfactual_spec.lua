-- tests/runtime/counterfactual_spec.lua
-- Tests for the counterfactual expression form and (in-state gs) path reads.
--
-- Run with:  busted tests/

local compiler_mod = require("compiler.compiler")
local state_mod    = require("runtime.state")
local log_mod      = require("runtime.log")
local eval_mod     = require("runtime.eval")

-- ============================================================
-- Helpers
-- ============================================================

local function compile(src)
  local result, diags = compiler_mod.compile(src, "test.sb")
  local errors = {}
  for _, d in ipairs(diags or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return result, errors
end

--- Build a minimal eval context from a game_table.
local function make_ctx(gt, cache_values)
  local l     = log_mod.new()
  local store = state_mod.new(gt.schema, l)
  store:init_defaults()
  for k, v in pairs(cache_values or {}) do
    store._cache[k] = v
  end
  return eval_mod.new_ctx(store, gt.fns, "test")
end

-- ============================================================
-- Basic counterfactual isolation
-- ============================================================

describe("counterfactual expr", function()
  local src = [[
module cft
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main

state world:
  gold: Int(0,9999) = 100

fn spend:
  dec! world/gold 30

scene main:
  * Go
    -> main
]]

  it("returns a GameState table with _cache and get", function()
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    -- Build a counterfactual_expr node manually and eval it
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {},
      simulate    = false,
    }
    local gs = eval_mod.eval_expr(node, ctx)
    assert.is_table(gs)
    assert.is_table(gs._cache)
    assert.is_function(gs.get)
  end)

  it("branched state starts with live values", function()
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt, { ["world/gold"] = 200 })
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {},
      simulate    = false,
    }
    local gs = eval_mod.eval_expr(node, ctx)
    assert.equals(200, gs:get("world/gold"))
  end)

  it("mutations in branch do NOT affect live state", function()
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt, { ["world/gold"] = 100 })
    -- counterfactual that calls spend (−30)
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {
        { kind = "fn_call", name = "spend", args = {} },
      },
      simulate    = false,
    }
    local gs = eval_mod.eval_expr(node, ctx)
    -- branch has 70
    assert.equals(70, gs:get("world/gold"))
    -- live state still 100
    assert.equals(100, ctx.state._cache["world/gold"])
  end)

  it("multiple transitions are applied in order", function()
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt, { ["world/gold"] = 100 })
    -- apply spend twice → 100 - 30 - 30 = 40
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {
        { kind = "fn_call", name = "spend", args = {} },
        { kind = "fn_call", name = "spend", args = {} },
      },
      simulate    = false,
    }
    local gs = eval_mod.eval_expr(node, ctx)
    assert.equals(40, gs:get("world/gold"))
    -- live unchanged
    assert.equals(100, ctx.state._cache["world/gold"])
  end)
end)

-- ============================================================
-- (in-state gs) path reads
-- ============================================================

describe("(in-state gs) path reads", function()
  local src = [[
module cft
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main

state world:
  gold: Int(0,9999) = 100

fn spend:
  dec! world/gold 30

fn after-spend-gold:
  pure
  let branch = counterfactual do:
    spend
  (in-state branch) world/gold

scene main:
  * Go
    -> main
]]

  it("(in-state gs) reads from the branched cache", function()
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt, { ["world/gold"] = 100 })
    local result = eval_mod.call_fn("after-spend-gold", {}, ctx)
    assert.equals(70, result)
    -- live unchanged
    assert.equals(100, ctx.state._cache["world/gold"])
  end)

  it("path_exists? on GameState returns false for absent path", function()
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {},
      simulate    = false,
    }
    local gs = eval_mod.eval_expr(node, ctx)
    assert.is_false(gs:path_exists("world/nonexistent"))
    assert.is_true(gs:path_exists("world/gold"))
  end)
end)

-- ============================================================
-- Full compile + run: counterfactual in .sb source
-- ============================================================

describe("counterfactual in .sb source", function()
  it("counterfactual without transitions preserves live values", function()
    local src = [[
module cft
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main

state world:
  mana: Int(0,100) = 50

fn peek-mana:
  pure
  let snap = counterfactual do:
  (in-state snap) world/mana

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    local result = eval_mod.call_fn("peek-mana", {}, ctx)
    assert.equals(50, result)
  end)

  it("counterfactual branch reflects transition fn effects", function()
    local src = [[
module cft
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main

state world:
  mana: Int(0,100) = 50

fn drain:
  dec! world/mana 20

fn peek-after-drain:
  pure
  let snap = counterfactual do:
    drain
  (in-state snap) world/mana

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    local result = eval_mod.call_fn("peek-after-drain", {}, ctx)
    assert.equals(30, result)
    -- live untouched
    assert.equals(50, ctx.state._cache["world/mana"])
  end)

  it("counterfactual can be used in a conditional expression", function()
    local src = [[
module cft
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main

state world:
  mana: Int(0,100) = 15

fn drain:
  dec! world/mana 20

fn can-afford-drain:
  pure
  let snap = counterfactual do:
    drain
  (in-state snap) world/mana >= 0

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    -- 15 - 20: Dec clamps at Int min (0), so result is 0 (>= 0 is true).
    -- The important assertion is live mana is unchanged.
    eval_mod.call_fn("can-afford-drain", {}, ctx)
    assert.equals(15, ctx.state._cache["world/mana"])
  end)
end)

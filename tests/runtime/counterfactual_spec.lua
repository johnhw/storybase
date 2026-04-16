-- tests/runtime/counterfactual_spec.lua
-- Tests for the counterfactual expression form and (in-state gs) path reads.
--
-- Run with:  busted tests/

local compiler_mod = require("compiler.compiler")
local state_mod    = require("runtime.state")
local log_mod      = require("runtime.log")
local eval_mod     = require("runtime.eval")
local actors_mod   = require("runtime.actors")

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

-- ============================================================
-- Nesting depth limit
-- ============================================================

describe("counterfactual nesting depth", function()
  -- The depth limit is tested directly by pre-setting counterfactual_depth on ctx,
  -- because transitions inside a counterfactual are evaluated inside pcall and
  -- errors would be silently swallowed.

  it("raises an error when depth exceeds max-counterfactual-depth", function()
    local src = [[
engine-config:
  entry-scene: main
  max-counterfactual-depth: 1

state world:
  hp: Int(0,100) = 50

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    ctx.game = gt
    -- Simulate being already at depth 1 (inside an outer counterfactual)
    ctx.counterfactual_depth = 1
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {},
      simulate    = false,
    }
    -- Trying to create depth 2 (1+1 > limit 1) must error
    local ok, err = pcall(eval_mod.eval_expr, node, ctx)
    assert.is_false(ok, "expected error from depth limit")
    assert.is_truthy(tostring(err):find("max%-counterfactual%-depth"), tostring(err))
  end)

  it("allows nesting exactly at the configured limit", function()
    local src = [[
engine-config:
  entry-scene: main
  max-counterfactual-depth: 2

state world:
  hp: Int(0,100) = 50

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    ctx.game = gt
    -- At depth 1, limit is 2 → depth 2 (1+1) is allowed
    ctx.counterfactual_depth = 1
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {},
      simulate    = false,
    }
    local ok, gs = pcall(eval_mod.eval_expr, node, ctx)
    assert.is_true(ok, tostring(gs))
    assert.is_table(gs)
    assert.equals(50, gs:get("world/hp"))
  end)
end)

-- ============================================================
-- Counterfactual log entry
-- ============================================================

describe("counterfactual log entry", function()
  it("appends a counterfactual entry to the live log", function()
    local src = [[
module cft
  version: 1.0
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
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    -- Trigger a counterfactual with one transition (spend)
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {
        { kind = "fn_call", name = "spend", args = {} },
      },
      simulate    = false,
    }
    eval_mod.eval_expr(node, ctx)
    -- The live log should have exactly one entry with kind="counterfactual"
    local found = false
    for _, entry in ipairs(ctx.state._log._entries) do
      if entry.kind == "counterfactual" then
        found = true
        assert.is_true(type(entry.transitions) == "table")
        assert.equals("spend", entry.transitions[1])
        assert.is_false(entry.simulate)
      end
    end
    assert.is_true(found, "expected counterfactual log entry")
  end)

  it("log entry records simulate=true when simulate flag set", function()
    local src = [[
engine-config:
  entry-scene: main

state world:
  gold: Int(0,9999) = 100

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    ctx.game = gt
    -- simulate requires ctx.actors to be truthy
    ctx.actors = actors_mod.new(ctx.state, ctx.state._log)
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {},
      simulate    = true,
    }
    eval_mod.eval_expr(node, ctx)
    local found = false
    for _, entry in ipairs(ctx.state._log._entries) do
      if entry.kind == "counterfactual" then
        found = true
        assert.is_true(entry.simulate)
      end
    end
    assert.is_true(found, "expected counterfactual log entry with simulate=true")
  end)
end)

-- ============================================================
-- simulate: true includes actor steps
-- ============================================================

describe("counterfactual simulate: true", function()
  it("actor behavior runs on branched state, live state unchanged", function()
    local src = [[
module cft
  version: 1.0
engine-config:
  entry-scene: main

state world:
  enemy_hp: Int(0,100) = 50

actor enemy:
  state: world/enemy_hp
  behavior: enemy-tick
  priority: 1

fn enemy-tick:
  inc! world/enemy_hp 5

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    ctx.game = gt
    ctx.actors = actors_mod.new(ctx.state, ctx.state._log)
    for _, a in pairs(gt.actors or {}) do ctx.actors:register(a) end

    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {},
      simulate    = true,
    }
    local gs = eval_mod.eval_expr(node, ctx)
    -- Enemy behavior inc! world/enemy_hp 5 should have run on branch
    assert.equals(55, gs:get("world/enemy_hp"))
    -- Live state unchanged
    assert.equals(50, ctx.state._cache["world/enemy_hp"])
  end)

  it("without actors, simulate: true still returns valid GameState", function()
    local src = [[
engine-config:
  entry-scene: main

state world:
  gold: Int(0,9999) = 100

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    -- ctx.actors is nil → simulate block is skipped
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = nil,
      transitions = {},
      simulate    = true,
    }
    local gs = eval_mod.eval_expr(node, ctx)
    assert.is_table(gs)
    assert.equals(100, gs:get("world/gold"))
  end)
end)

-- ============================================================
-- find ... in-state: gs
-- ============================================================

describe("find ... in-state: gs", function()
  it("find query redirected to snapshot returns entities from that snapshot", function()
    -- Use single-value entity family (the multi-field record form has a known
    -- codegen limitation with template path segments and table.concat).
    local src = [[
module cft
  version: 1.0
engine-config:
  entry-scene: main

state npcs/{npc}: Int(0,100) max: 8

fn spawn-npc name:
  spawn! npcs name

fn count-npcs-in-snap:
  pure
  let snap = counterfactual do:
    spawn-npc "hero"
  find npcs in-state: snap

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)
    ctx.game = gt
    local result = eval_mod.call_fn("count-npcs-in-snap", {}, ctx)
    -- The snapshot should contain "hero"; live state should not
    assert.is_table(result)
    local found_hero = false
    for _, k in ipairs(result) do
      if k == "hero" then found_hero = true end
    end
    assert.is_true(found_hero, "expected 'hero' in snapshot find results")
    -- Live state still has no npc "hero"
    assert.is_nil(ctx.state._cache["npcs/hero"])
  end)
end)

-- ============================================================
-- counterfactual from: tick  (log replay to historical state)
-- ============================================================

describe("counterfactual from: tick", function()
  local src = [[
module cft-from
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0,9999) = 100

fn earn amount:
  inc! world/gold amount

scene main:
  * Go -> main
]]

  it("from: 0 starts from the state at tick 0 (schema defaults), ignoring later mutations", function()
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)

    -- Apply two mutations with explicit time stamps to the live log
    ctx.state._log:append({
      path = "world/gold", old = 100, ["new"] = 150,
      time = { tick = 1 }, fn = "earn",
    })
    ctx.state._cache["world/gold"] = 150
    ctx.state._log:append({
      path = "world/gold", old = 150, ["new"] = 200,
      time = { tick = 2 }, fn = "earn",
    })
    ctx.state._cache["world/gold"] = 200

    -- from: 0 → should replay only entries with tick <= 0 (none)
    -- so the state starts from init_defaults (gold = 100)
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = { kind = "int_lit", value = 0 },
      transitions = {},
      simulate    = false,
    }
    local gs = eval_mod.eval_expr(node, ctx)
    assert.equals(100, gs:get("world/gold"),
      "from:0 should give default value (100), not current (200)")
    -- Live state unchanged
    assert.equals(200, ctx.state._cache["world/gold"])
  end)

  it("from: 1 includes mutations up to tick 1 only", function()
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)

    ctx.state._log:append({
      path = "world/gold", old = 100, ["new"] = 150,
      time = { tick = 1 }, fn = "earn",
    })
    ctx.state._cache["world/gold"] = 150
    ctx.state._log:append({
      path = "world/gold", old = 150, ["new"] = 200,
      time = { tick = 2 }, fn = "earn",
    })
    ctx.state._cache["world/gold"] = 200

    local node = {
      kind        = "counterfactual_expr",
      from_tick   = { kind = "int_lit", value = 1 },
      transitions = {},
      simulate    = false,
    }
    local gs = eval_mod.eval_expr(node, ctx)
    assert.equals(150, gs:get("world/gold"),
      "from:1 should give state after tick-1 mutation (150)")
    assert.equals(200, ctx.state._cache["world/gold"])
  end)

  it("from: tick + transitions: mutations apply on top of historical state", function()
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt)

    ctx.state._log:append({
      path = "world/gold", old = 100, ["new"] = 150,
      time = { tick = 1 }, fn = "earn",
    })
    ctx.state._cache["world/gold"] = 150

    -- from: 1, then apply earn 25 → 150 + 25 = 175
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = { kind = "int_lit", value = 1 },
      transitions = {
        { kind = "fn_call", name = "earn", args = {
          { kind = "int_lit", value = 25 }
        }},
      },
      simulate    = false,
    }
    local gs = eval_mod.eval_expr(node, ctx)
    assert.equals(175, gs:get("world/gold"),
      "from:1 + earn(25): 150 + 25 = 175")
    -- Live state unchanged
    assert.equals(150, ctx.state._cache["world/gold"])
  end)

  it("from: with non-number expression falls back to current state gracefully", function()
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local ctx = make_ctx(gt, { ["world/gold"] = 999 })

    -- Use a nil-producing expression (path that doesn't exist) as from_tick
    local node = {
      kind        = "counterfactual_expr",
      from_tick   = { kind = "path_expr", segments = {"world", "nonexistent"} },
      transitions = {},
      simulate    = false,
    }
    -- Should not error; falls back to copying current state
    local ok, gs = pcall(eval_mod.eval_expr, node, ctx)
    assert.is_true(ok, "from: with non-number should not raise an error")
    if ok then
      assert.equals(999, gs:get("world/gold"),
        "fallback: counterfactual from non-number from_tick uses current state")
    end
  end)
end)

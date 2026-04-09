-- tests/fuzz/counterfactual_fuzz_spec.lua
-- Fuzz/property tests for counterfactual isolation.
--
-- Invariant: no matter how many transitions are applied inside a
-- counterfactual branch, the live engine state is NEVER mutated.
--
-- Also tests:
--   - Nested counterfactuals do not leak into each other
--   - Multiple independent branches from the same state are isolated

local compiler_mod = require("compiler.compiler")
local engine_mod   = require("runtime.engine")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function compile(src)
  local result, diags = compiler_mod.compile(src, "fuzz.sb")
  local errors = {}
  if diags and diags.errors then
    errors = diags.errors
  end
  return result, errors
end

local function snapshot(eng)
  local s = {}
  for k, v in pairs(eng._state._cache) do s[k] = v end
  return s
end

local function snapshots_equal(a, b)
  for k, v in pairs(a) do
    if b[k] ~= v then return false, k, v, b[k] end
  end
  for k, v in pairs(b) do
    if a[k] ~= v then return false, k, a[k], v end
  end
  return true
end

-- ── Shared game source ────────────────────────────────────────────────────────

local game_src = [[
module cft-fuzz
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main

state world:
  gold:   Int(0, 9999) = 100
  health: Int(0, 100)  = 50
  step:   Int(0, 200)  = 0

fn spend-ten:
  dec! world/gold 10

fn heal-five:
  inc! world/health 5

fn advance:
  inc! world/step 1

scene main:
  * Go
    advance
    -> main
]]

-- ── Tests ──────────────────────────────────────────────────────────────────

describe("counterfactual fuzz — isolation invariant", function()

  it("live state is unchanged after counterfactual with many mutations", function()
    local gt, errs = compile(game_src)
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    -- Record live state before any counterfactual
    local before = snapshot(eng)

    -- Execute a deep chain of mutations inside a counterfactual from Lua.
    -- We simulate this by calling eval directly with a counterfactual expression
    -- that runs spend-ten 10 times (total -100 gold in the branch).
    local eval_mod  = require("runtime.eval")
    local state_mod = require("runtime.state")
    local log_mod   = require("runtime.log")

    local log   = log_mod.new()
    local store = state_mod.new(gt.schema, log)
    store:init_defaults()
    -- Set state to match engine
    for k, v in pairs(eng._state._cache) do store._cache[k] = v end

    local ctx = eval_mod.new_ctx(store, gt.fns, "fuzz")
    ctx.game = gt

    -- Build a counterfactual AST node: counterfactual from: 0 do: [spend-ten x10]
    local ast = require("compiler.ast")
    local K   = ast.K

    local transitions = {}
    for _ = 1, 10 do
      transitions[#transitions + 1] = ast.node(K.FN_CALL, { name = "spend-ten", args = {} })
    end
    local cf_node = ast.node(K.COUNTERFACTUAL_EXPR, {
      from_tick   = ast.node(K.NUMBER_LIT, { value = 0 }),
      transitions = transitions,
      simulate    = false,
    })

    local gs = eval_mod.eval_expr(cf_node, ctx)
    assert.is_not_nil(gs, "counterfactual returned nil")
    assert.is_not_nil(gs._cache, "GameState has no _cache")

    -- Branch should have reduced gold by 100
    local branch_gold = gs._cache["world/gold"] or 0
    assert.is_true(branch_gold <= 0 or branch_gold == 0,
      "expected branch gold = 0, got " .. tostring(branch_gold))

    -- Live state must be unchanged
    local after = snapshot(eng)
    local ok, key, exp, got = snapshots_equal(before, after)
    assert.is_true(ok,
      string.format("live state mutated! key=%s expected=%s got=%s", tostring(key), tostring(exp), tostring(got)))
  end)

  it("two independent branches from same state are isolated from each other", function()
    local gt, errs = compile(game_src)
    assert.equal(0, #errs)

    local eval_mod  = require("runtime.eval")
    local state_mod = require("runtime.state")
    local log_mod   = require("runtime.log")
    local ast       = require("compiler.ast")
    local K         = ast.K

    local log   = log_mod.new()
    local store = state_mod.new(gt.schema, log)
    store:init_defaults()
    local ctx = eval_mod.new_ctx(store, gt.fns, "fuzz")
    ctx.game = gt

    -- Branch A: spend-ten × 5  → gold = 50
    local trans_a = {}
    for _ = 1, 5 do
      trans_a[#trans_a + 1] = ast.node(K.FN_CALL, { name = "spend-ten", args = {} })
    end
    local cf_a = ast.node(K.COUNTERFACTUAL_EXPR, {
      from_tick   = ast.node(K.NUMBER_LIT, { value = 0 }),
      transitions = trans_a,
      simulate    = false,
    })

    -- Branch B: heal-five × 5  → health = 75
    local trans_b = {}
    for _ = 1, 5 do
      trans_b[#trans_b + 1] = ast.node(K.FN_CALL, { name = "heal-five", args = {} })
    end
    local cf_b = ast.node(K.COUNTERFACTUAL_EXPR, {
      from_tick   = ast.node(K.NUMBER_LIT, { value = 0 }),
      transitions = trans_b,
      simulate    = false,
    })

    local gs_a = eval_mod.eval_expr(cf_a, ctx)
    local gs_b = eval_mod.eval_expr(cf_b, ctx)

    -- Branch A modified gold, B modified health; they must not cross-contaminate
    assert.equal(50,  gs_a._cache["world/gold"],   "branch A gold")
    assert.equal(50,  gs_a._cache["world/health"], "branch A health unchanged")
    assert.equal(100, gs_b._cache["world/gold"],   "branch B gold unchanged")
    assert.equal(75,  gs_b._cache["world/health"], "branch B health")

    -- Live state still pristine
    assert.equal(100, store._cache["world/gold"],   "live gold")
    assert.equal(50,  store._cache["world/health"], "live health")
  end)

  it("live state is unchanged after N engine turns with interleaved counterfactuals", function()
    local gt, errs = compile(game_src)
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local eval_mod  = require("runtime.eval")
    local state_mod = require("runtime.state")
    local log_mod   = require("runtime.log")
    local ast       = require("compiler.ast")
    local K         = ast.K

    -- Run 5 engine turns interleaved with counterfactuals
    for i = 1, 5 do
      -- Advance live state one turn
      eng:do_choice("main", 1)
      local live_step = eng._state:get("world/step")
      assert.equal(i, live_step, "live step after turn " .. i)

      -- Create a counterfactual that does 3 more advance steps
      local log   = log_mod.new()
      local store = state_mod.new(gt.schema, log)
      store:init_defaults()
      for k, v in pairs(eng._state._cache) do store._cache[k] = v end

      local ctx = eval_mod.new_ctx(store, gt.fns, "fuzz")
      ctx.game = gt

      local trans = {}
      for _ = 1, 3 do
        trans[#trans + 1] = ast.node(K.FN_CALL, { name = "advance", args = {} })
      end
      local cf = ast.node(K.COUNTERFACTUAL_EXPR, {
        from_tick   = ast.node(K.NUMBER_LIT, { value = 0 }),
        transitions = trans,
        simulate    = false,
      })
      local gs = eval_mod.eval_expr(cf, ctx)

      -- Branch has 3 extra steps
      assert.equal(i + 3, gs._cache["world/step"],
        "branch step after cf at turn " .. i)
      -- Live state still at i
      assert.equal(i, eng._state:get("world/step"),
        "live step unchanged after cf at turn " .. i)
    end
  end)

end)

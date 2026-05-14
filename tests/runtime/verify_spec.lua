-- tests/runtime/verify_spec.lua
-- Tests for runtime/verify.lua: verify block runner.
--
-- Run with:  busted tests/

local verify_mod   = require("runtime.verify")
local compiler_mod = require("compiler.compiler")

local function compile(src)
  local result, diags = compiler_mod.compile(src, "test.sb")
  local errors = {}
  for _, d in ipairs(diags or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return result, errors
end

-- ============================================================
-- verify-always tests
-- ============================================================

describe("verify-always", function()

  it("passes when invariant is always true across BFS states", function()
    local src = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 10

scene main:
  * Earn
    inc! world/gold 5
  * Spend
    dec! world/gold 5

verify "gold is non-negative":
  verify-always world/gold >= 0
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    assert.is_true(results[1].pass)
    assert.equals("gold is non-negative", results[1].label)
    assert.is_truthy(results[1].states_checked)
    assert.is_true(results[1].states_checked > 0)
  end)

  it("fails when invariant is violated in a reachable state", function()
    local src = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

type Gold = Int(0, 9999)

state world:
  gold: Gold = 5

fn borrow:
  dec! world/gold 10

scene main:
  * Borrow
    borrow
    -> main

verify "gold never negative":
  verify-always world/gold >= 0
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    assert.is_false(results[1].pass)
    assert.is_truthy(results[1].fail_msg)
  end)

  it("includes counterexample_path when invariant is violated", function()
    local src = [[
engine-config:
  entry-scene: main

state world:
  count: Int(0, 100) = 0

fn step:
  inc! world/count 50

scene main:
  * Step
    step
    -> main

verify "count stays small":
  verify-always world/count < 50
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.is_false(results[1].pass)
    -- counterexample_path should be a list of {scene, label} steps
    local path = results[1].counterexample_path
    assert.is_not_nil(path, "expected counterexample_path to be present")
    assert.is_true(type(path) == "table", "counterexample_path should be a table")
    -- The path involves at least one Step choice
    assert.is_true(#path >= 1, "counterexample_path should have at least one step")
    assert.equals("main", path[1].scene)
    assert.equals("Step", path[1].label)
  end)

end)

-- ============================================================
-- after-check tests
-- ============================================================

describe("verify after", function()

  it("passes when path@before assertion holds after function call", function()
    local src = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 100

fn earn amount:
  inc! world/gold amount

scene main:
  * Go
    -> main

verify "earn increases gold":
  after (earn 50):
    world/gold > world/gold@before
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    assert.is_true(results[1].pass, results[1].fail_msg)
  end)

  it("fails when assertion does not hold after function call", function()
    local src = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 100

fn earn amount:
  inc! world/gold amount

scene main:
  * Go
    -> main

verify "earn decreases gold (wrong)":
  after (earn 50):
    world/gold < world/gold@before
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    assert.is_false(results[1].pass)
  end)

end)

-- ============================================================
-- requires (skip) tests
-- ============================================================

describe("verify requires", function()

  it("skips block when requires is not satisfied at initial state", function()
    local src = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 0

fn spend amount:
  dec! world/gold amount

scene main:
  * Go
    -> main

verify "spend only when rich":
  requires world/gold >= 100
  after (spend 30):
    world/gold >= 0
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    assert.is_true(results[1].skipped)
  end)

  it("runs block when requires is satisfied", function()
    local src = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 200

fn spend amount:
  dec! world/gold amount

scene main:
  * Go
    -> main

verify "can afford 30":
  requires world/gold >= 100
  after (spend 30):
    world/gold = world/gold@before - 30
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    assert.is_true(results[1].pass, results[1].fail_msg)
    assert.is_nil(results[1].skipped)
  end)

end)

-- ============================================================
-- verify: errors in requires / when / from-any-state surfaced
-- ============================================================
--
-- Previously, an evaluation error inside a `requires:` clause was caught by
-- pcall and silently treated as "requires not met" — the block reported as
-- skipped, the assertion never ran. Same for `when:` filters in
-- `from-any-state` blocks. A typo or removed-path reference disabled the
-- verify without anyone noticing.

describe("verify: evaluation errors are surfaced (A7)", function()

  local eval_mod = require("runtime.eval")

  -- Build a minimal compiled game with one requires/after verify block, then
  -- monkey-patch eval.eval_expr to raise for the requires evaluation.
  local function with_eval_error_in(fn_name, body)
    local original = eval_mod.eval_expr
    local fired = false
    eval_mod.eval_expr = function(node, ctx)
      if not fired and ctx and ctx.fn_name == fn_name then
        fired = true
        error("synthetic error in " .. fn_name)
      end
      return original(node, ctx)
    end
    local ok, results = pcall(body)
    eval_mod.eval_expr = original
    assert(ok, results)
    return results
  end

  it("reports failure when `requires:` evaluation errors (not skipped)", function()
    local src = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 200

fn spend amount:
  dec! world/gold amount

scene main:
  * Go
    -> main

verify "requires errors":
  requires world/gold >= 100
  after (spend 30):
    world/gold = world/gold@before - 30
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local results = with_eval_error_in("verify-requires", function()
      return verify_mod.run_all(gt)
    end)

    assert.equals(1, #results)
    -- Must NOT be silently skipped — that was the bug.
    assert.is_nil(results[1].skipped)
    assert.is_false(results[1].pass)
    assert.is_truthy(results[1].fail_msg,
      "expected a fail_msg describing the requires error")
    assert.is_truthy(results[1].fail_msg:find("requires clause errored"),
      "fail_msg should mention 'requires clause errored', got: "
        .. tostring(results[1].fail_msg))
  end)

  it("reports failure when `when:` evaluation errors in from-any-state", function()
    local src = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 0

scene main:
  * Wait
    -> main

verify "when errors":
  when world/gold >= 0:
  from-any-state:
    world/gold >= 0
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local results = with_eval_error_in("verify-when", function()
      return verify_mod.run_all(gt)
    end)

    assert.equals(1, #results)
    assert.is_false(results[1].pass)
    assert.is_truthy(results[1].fail_msg)
    assert.is_truthy(results[1].fail_msg:find("when clause errored"),
      "fail_msg should mention 'when clause errored', got: "
        .. tostring(results[1].fail_msg))
  end)

  it("distinguishes 'condition errored' from 'condition failed' in from-any-state", function()
    local src = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 0

scene main:
  * Wait
    -> main

verify "from-any-state errors":
  from-any-state:
    world/gold >= 0
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local results = with_eval_error_in("verify-from-any", function()
      return verify_mod.run_all(gt)
    end)

    assert.equals(1, #results)
    assert.is_false(results[1].pass)
    assert.is_truthy(results[1].fail_msg:find("condition errored"),
      "fail_msg should distinguish errored from failed, got: "
        .. tostring(results[1].fail_msg))
  end)

end)

-- ============================================================
-- multiple verify blocks
-- ============================================================

describe("multiple verify blocks", function()

  it("reports each block independently", function()
    local src = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  hp: Int(0, 999) = 100

fn damage amount:
  dec! world/hp amount

scene main:
  * Go
    -> main

verify "hp positive after small damage":
  after (damage 10):
    world/hp > 0

verify "damage reduces hp":
  after (damage 10):
    world/hp < world/hp@before
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(2, #results)
    assert.is_true(results[1].pass, results[1].fail_msg)
    assert.is_true(results[2].pass, results[2].fail_msg)
  end)

end)

-- ── counterexample detail ────────────────────────────────────────────────────

describe("verify: counterexample detail in failure", function()
  it("includes counterexample table when verify-always fails", function()
    local src = [[
module ce-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 100) = 0

scene main:
  * Earn
    inc! world/gold 10
    -> main

verify "gold stays zero":
  verify-always world/gold = 0
]]
    local gt, errs = compile(src)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equal(1, #results)
    assert.is_false(results[1].pass)
    -- Should have counterexample detail
    assert.is_not_nil(results[1].counterexample,
      "expected counterexample table in failure result")
    -- The counterexample should show gold > 0
    local ce = results[1].counterexample
    assert.is_true((ce["world/gold"] or 0) > 0)
  end)

  it("includes BFS state detail in fail_msg", function()
    local src = [[
module ce-test2
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 100) = 0

scene main:
  * Earn
    inc! world/gold 10
    -> main

verify "gold zero always":
  verify-always world/gold = 0
]]
    local gt, errs = compile(src)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.is_false(results[1].pass)
    -- fail_msg should contain state details
    local msg = results[1].fail_msg or ""
    assert.is_true(msg:find("world/gold") ~= nil or msg:find("BFS state") ~= nil,
      "fail_msg should include state info: " .. msg)
  end)
end)

-- ============================================================
-- match_path_pattern (§4.3)
-- ============================================================

describe("verify: match_path_pattern", function()
  local mpp = verify_mod.match_path_pattern

  it("exact path matches itself", function()
    assert.is_true(mpp("player/health", "player/health"))
    assert.is_false(mpp("player/health", "player/mana"))
  end)

  it("bare * matches any path", function()
    assert.is_true(mpp("*", "player/health"))
    assert.is_true(mpp("*", "world/tick"))
  end)

  it("* single-segment wildcard matches one segment", function()
    assert.is_true(mpp("player/*",  "player/health"))
    assert.is_true(mpp("player/*",  "player/mana"))
    assert.is_false(mpp("player/*", "player/items/0"), "* should not cross /")
    assert.is_false(mpp("player/*", "world/tick"))
  end)

  it("** multi-segment wildcard matches any number of segments", function()
    assert.is_true(mpp("player/**",  "player/health"))
    assert.is_true(mpp("player/**",  "player/items/0"))
    assert.is_true(mpp("player/**",  "player/a/b/c"))
    assert.is_false(mpp("player/**", "world/tick"))
  end)

  it("npcs/*/location matches only location under any direct NPC", function()
    assert.is_true(mpp("npcs/*/location",  "npcs/knight/location"))
    assert.is_true(mpp("npcs/*/location",  "npcs/mage/location"))
    assert.is_false(mpp("npcs/*/location", "npcs/knight/health"))
    assert.is_false(mpp("npcs/*/location", "npcs/knight/items/0"))
  end)

  it("alternation (a|b) expands to two exact matches", function()
    assert.is_true(mpp("player/(health|mana)",  "player/health"))
    assert.is_true(mpp("player/(health|mana)",  "player/mana"))
    assert.is_false(mpp("player/(health|mana)", "player/gold"))
  end)

  it("alternation with three branches", function()
    assert.is_true(mpp("world/(a|b|c)", "world/a"))
    assert.is_true(mpp("world/(a|b|c)", "world/b"))
    assert.is_true(mpp("world/(a|b|c)", "world/c"))
    assert.is_false(mpp("world/(a|b|c)", "world/d"))
  end)
end)

-- ============================================================
-- Bug 2/3 regression: verify-always must see UMap mutations
-- ============================================================
-- Bug 3: clone_cache used ipairs on hash-keyed tables (UMap), so every BFS
-- snapshot had an empty UMap regardless of mutations.  Bug 2: hash_cache had
-- the same problem, collapsing all states with the same scene into one.
-- Together, verify-always would never detect invariant violations caused by
-- UMap mutations and would falsely report pass.

describe("verify-always — detects UMap invariant violation (Bug 2/3 regression)", function()
  it("fails when a choice mutates a UMap in a way that violates the invariant", function()
    local src = [[
module umap-verify-regression
  version: 1.0
engine-config:
  entry-scene: start
state world:
  scores: UMap(String, Int(0,999)) = {}
fn add-bob:
  map-set! world/scores "bob" 99
scene start:
  * Add Bob
    add-bob
    -> done
scene done:
  * Loop
    -> done
verify "bob never in scores":
  verify-always not ("bob" in world/scores)
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    -- The invariant is violated once "Add Bob" executes: "bob" is now in the map.
    -- With the clone/hash bugs the UMap was always cloned as empty, so verify
    -- never saw the mutation and falsely reported pass.  With the fix the
    -- violation is correctly detected and the counterexample shows {bob:99}.
    assert.is_false(results[1].pass,
      "verify-always must detect the UMap mutation that violates the invariant")
    assert.is_truthy(results[1].fail_msg and
      results[1].fail_msg:find("bob:99"),
      "counterexample message should show the UMap contents")
  end)
end)

-- ============================================================
-- after + requires: BFS-state semantics
-- ============================================================

describe("verify after + requires: checks across BFS-reachable states", function()

  -- Game where gold starts at 0 but can be incremented via "Earn" choices.
  -- After earning, gold may satisfy requires; spend must then reduce it correctly.
  local BASE_SRC = [[
module verify-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 0

fn earn:
  inc! world/gold 50

fn spend:
  pre:  world/gold >= 30
  dec!  world/gold 30

scene main:
  * Earn
    earn
    -> main
  * Done
    -> main
]]

  it("passes when assertion holds in all reachable states satisfying requires", function()
    local src = BASE_SRC .. [[
verify "spend reduces gold by 30":
  requires world/gold >= 30
  after (spend):
    world/gold = world/gold@before - 30
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    assert.is_true(results[1].pass, results[1].fail_msg)
    assert.is_truthy((results[1].states_checked or 0) > 0,
      "should have checked at least one reachable state")
  end)

  it("fails when assertion is violated in a reachable state satisfying requires", function()
    -- earn gives +50, but we claim spend subtracts 99 — which is wrong
    local src = BASE_SRC .. [[
verify "spend reduces gold by 99 (wrong)":
  requires world/gold >= 30
  after (spend):
    world/gold = world/gold@before - 99
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    assert.is_false(results[1].pass)
    assert.is_truthy(results[1].fail_msg)
    assert.is_truthy(results[1].counterexample,
      "should provide a counterexample state")
  end)

  it("skips when requires is never satisfied in any reachable state", function()
    -- gold starts at 0 and can only earn 50; requires >= 9000 is unreachable
    local src = BASE_SRC .. [[
verify "unreachable requires":
  requires world/gold >= 9000
  after (spend):
    world/gold >= 0
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    assert.is_true(results[1].pass)
    assert.is_true(results[1].skipped)
    assert.matches("requires not met", results[1].reason)
  end)

  it("without requires: still runs from fresh initial state only", function()
    -- gold starts at 0; spend has pre: gold >= 30 so this will error from initial state
    local src = BASE_SRC .. [[
verify "no requires — initial state only":
  after (earn):
    world/gold = world/gold@before + 50
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.equals(1, #results)
    assert.is_true(results[1].pass, results[1].fail_msg)
    -- states_checked is nil for the single-state path
    assert.is_nil(results[1].states_checked)
  end)

  it("fail message includes the state that violated the assertion", function()
    local src = BASE_SRC .. [[
verify "wrong assertion":
  requires world/gold >= 30
  after (spend):
    world/gold = 9999
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.is_false(results[1].pass)
    -- fail_msg should mention the state (contains gold=...)
    assert.is_truthy(results[1].fail_msg:find("gold"),
      "fail_msg should mention the state key")
  end)

end)

-- ============================================================
-- B2: Counterexample minimisation — shrink_path API
-- ============================================================

describe("verify: shrink_path (B2)", function()

  it("shrink_path is exported from verify_mod", function()
    assert.is_function(verify_mod.shrink_path)
  end)

  it("returns a 1-step path unchanged", function()
    -- gold starts at 5; dec! by 10 clamps to 0 (Int(0,9999)); 0 is NOT > 0 → violation
    local src = [[
engine-config:
  entry-scene: main
state world:
  gold: Int(0, 9999) = 5
fn bust:
  dec! world/gold 10
scene main:
  * Bust
    bust
    -> main
verify "gold positive":
  verify-always world/gold > 0
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local always_expr = gt.verifies[1].clauses[1].condition
    local path = { { scene = "main", label = "Bust", index = 1 } }
    local shrunk, exceeded = verify_mod.shrink_path(gt, path, always_expr, 5.0)
    assert.equals(1, #shrunk)
    assert.equals("Bust", shrunk[1].label)
    assert.is_false(exceeded)
  end)

  it("shrink_path reduces a redundant multi-step path to its minimum", function()
    -- [Pass, Pass, Trigger] can be reduced to [Trigger] because Pass is a no-op
    local src = [[
engine-config:
  entry-scene: main
state world:
  triggered: Bool = false
fn trigger:
  set! world/triggered true
scene main:
  * Pass
    -> main
  * Trigger
    trigger
    -> main
verify "not triggered":
  verify-always not world/triggered
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs)
    local always_expr = gt.verifies[1].clauses[1].condition

    local long_path = {
      { scene = "main", label = "Pass",    index = 1 },
      { scene = "main", label = "Pass",    index = 1 },
      { scene = "main", label = "Trigger", index = 2 },
    }

    local shrunk, exceeded = verify_mod.shrink_path(gt, long_path, always_expr, 5.0)
    assert.is_false(exceeded)
    assert.equals(1, #shrunk, "expected path reduced to 1 step")
    assert.equals("Trigger", shrunk[1].label)
  end)

  it("shrink_path leaves a path unchanged when every step is necessary", function()
    -- 'Finish' is guarded by world/unlocked; Unlock must come first
    local src = [[
engine-config:
  entry-scene: setup
state world:
  unlocked: Bool = false
  done:     Bool = false
scene setup:
  * Unlock
    set! world/unlocked true
    -> main
scene main:
  * Finish (when world/unlocked)
    set! world/done true
    -> main
verify "not done":
  verify-always not world/done
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs)
    local always_expr = gt.verifies[1].clauses[1].condition

    local path = {
      { scene = "setup", label = "Unlock", index = 1 },
      { scene = "main",  label = "Finish", index = 1 },
    }

    local shrunk, exceeded = verify_mod.shrink_path(gt, path, always_expr, 5.0)
    assert.is_false(exceeded)
    assert.equals(2, #shrunk, "both steps are necessary; path must stay at length 2")
    assert.equals("Unlock", shrunk[1].label)
    assert.equals("Finish", shrunk[2].label)
  end)

  it("shrink_path removes the redundant middle step from a 3-step path", function()
    -- gold starts at 5; Earn→15; Waste→15 (no-op); Bust→0 (clamped, violates >0).
    -- The Waste step is redundant: [Earn, Bust] produces the same violation.
    local src = [[
engine-config:
  entry-scene: main
state world:
  gold: Int(0, 9999) = 5
fn earn:
  inc! world/gold 10
fn waste:
  inc! world/gold 0
fn bust:
  dec! world/gold 20
scene main:
  * Earn
    earn
    -> main
  * Waste
    waste
    -> main
  * Bust
    bust
    -> main
verify "gold positive":
  verify-always world/gold > 0
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local always_expr = gt.verifies[1].clauses[1].condition

    local path = {
      { scene = "main", label = "Earn",  index = 1 },
      { scene = "main", label = "Waste", index = 2 },
      { scene = "main", label = "Bust",  index = 3 },
    }

    local shrunk, exceeded = verify_mod.shrink_path(gt, path, always_expr, 5.0)
    assert.is_false(exceeded)
    assert.is_true(#shrunk <= 2, "shrinker must remove the redundant Waste step")
    local found_bust = false
    for _, s in ipairs(shrunk) do
      if s.label == "Bust" then found_bust = true end
    end
    assert.is_true(found_bust, "Bust step must remain in the minimised path")
  end)

  it("run_all counterexample_path is set for a failing verify-always", function()
    -- gold=5; Bust clamps to 0; invariant >0 violated in 1 step.
    local src = [[
engine-config:
  entry-scene: main
state world:
  gold: Int(0, 9999) = 5
fn bust:
  dec! world/gold 10
scene main:
  * Bust
    bust
    -> main
verify "gold positive":
  verify-always world/gold > 0
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    local results = verify_mod.run_all(gt)
    assert.is_false(results[1].pass)
    assert.is_not_nil(results[1].counterexample_path,
      "counterexample_path must be present")
    assert.equals(1, #results[1].counterexample_path,
      "BFS gives the minimum 1-step path [Bust]")
    assert.equals("Bust", results[1].counterexample_path[1].label)
    -- Already minimal — shrinker should not populate original_len
    assert.is_nil(results[1].counterexample_path_original_len,
      "original_len must be nil when path was not shortened")
  end)

  it("shrink_path reports a shorter path than the manually supplied overlong one", function()
    local src = [[
engine-config:
  entry-scene: main
state world:
  triggered: Bool = false
fn trigger:
  set! world/triggered true
scene main:
  * Pass
    -> main
  * Trigger
    trigger
    -> main
verify "not triggered":
  verify-always not world/triggered
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs)

    local always_expr = gt.verifies[1].clauses[1].condition
    local long_path = {
      { scene = "main", label = "Pass",    index = 1 },
      { scene = "main", label = "Pass",    index = 1 },
      { scene = "main", label = "Trigger", index = 2 },
    }
    local shrunk, exceeded = verify_mod.shrink_path(gt, long_path, always_expr, 5.0)
    assert.is_false(exceeded)
    assert.equals(1, #shrunk, "overlong path should be minimised to 1 step")
    assert.is_true(#long_path > #shrunk, "caller can detect minimisation via length comparison")
  end)

end)

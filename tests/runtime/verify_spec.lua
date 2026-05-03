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

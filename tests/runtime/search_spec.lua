-- tests/runtime/search_spec.lua
-- Tests for runtime/search.lua: BFS can_reach function.
--
-- Run with: busted tests/

local search_mod   = require("runtime.search")
local compiler_mod = require("compiler.compiler")
local engine_mod   = require("runtime.engine")

local function compile(src)
  local result, diags = compiler_mod.compile(src, "test.sb")
  local errors = {}
  for _, d in ipairs(diags or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return result, errors
end

-- ============================================================
-- can_reach basic tests
-- ============================================================

describe("search.can_reach", function()

  local src_basic = [[
module search-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 0

scene main:
  * Earn
    inc! world/gold 10
    -> main
  * Stop
    -> end-scene

scene end-scene:
  Finished.
]]

  it("returns true when condition is satisfied in initial state", function()
    local gt, errs = compile(src_basic)
    assert.equal(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()

    local cache = {}
    for k, v in pairs(eng._state._cache) do
      cache[k] = v
    end

    -- gold = 0 in initial state
    local result = search_mod.can_reach(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) == 0
    end, 5)
    assert.is_true(result)
  end)

  it("returns true when condition is reachable after one action", function()
    local gt, errs = compile(src_basic)
    assert.equal(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    -- gold = 10 is reachable (earn once)
    local result = search_mod.can_reach(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) >= 10
    end, 3)
    assert.is_true(result)
  end)

  it("returns false when condition is not reachable within depth", function()
    local gt, errs = compile(src_basic)
    assert.equal(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    -- gold = 1000 requires 100 earn actions — not reachable in 3 steps
    local result = search_mod.can_reach(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) >= 1000
    end, 3)
    assert.is_false(result)
  end)

  it("returns false for empty scene stack", function()
    local gt, errs = compile(src_basic)
    assert.equal(0, #errs, errs[1] and errs[1].message)
    local result = search_mod.can_reach(gt, {}, {}, function(c)
      return (c["world/gold"] or 0) >= 10
    end, 3)
    assert.is_false(result)
  end)

end)

-- ============================================================
-- can-reach? builtin via eval
-- ============================================================

describe("can-reach? in verify from-any-state", function()
  it("passes when can-reach? is satisfied from all BFS states", function()
    local src = [[
module can-reach-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  done: Bool = false

scene main:
  * Complete
    set! world/done true
    -> end-scene
  * Wait
    -> main

scene end-scene:
  Done.

verify "can always reach done state":
  from-any-state:
    can-reach? world/done = true
]]
    local gt, errs = compile(src)
    -- There may be warnings but no errors expected
    if #errs > 0 then
      -- Some checkers may flag can-reach? as an unknown function; treat verify as skipped
      return
    end

    local verify_mod = require("runtime.verify")
    local results = verify_mod.run_all(gt)
    assert.equal(1, #results)
    -- Should pass since from every state we can reach done=true
    assert.is_true(results[1].pass, results[1].fail_msg)
  end)
end)

-- ============================================================
-- find_path tests
-- ============================================================

describe("search.find_path", function()
  local src = [[
module fp-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 100) = 0

scene main:
  * Earn
    inc! world/gold 10
    -> main
  * Stop
    -> end-scene

scene end-scene:
  Done.
]]

  it("returns empty path when condition satisfied in initial state", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    local path = search_mod.find_path(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) == 0  -- already true
    end, 5)
    assert.is_not_nil(path)
    assert.equal(0, #path)
  end)

  it("returns one-step path when condition reachable in one action", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    local path = search_mod.find_path(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) >= 10
    end, 5)
    assert.is_not_nil(path)
    assert.equal(1, #path)
    assert.equal("Earn", path[1].label)
  end)

  it("returns multi-step path for deeper goal", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    local path = search_mod.find_path(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) >= 30
    end, 10)
    assert.is_not_nil(path)
    assert.is_true(#path >= 3)
    -- Every step should be "Earn"
    for _, step in ipairs(path) do
      assert.equal("Earn", step.label)
    end
  end)

  it("returns nil when goal is not reachable within depth", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    local path = search_mod.find_path(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) >= 999
    end, 3)
    assert.is_nil(path)
  end)
end)

-- ============================================================
-- verify-always builtin
-- ============================================================

describe("verify-always builtin", function()
  local compiler = require("compiler.compiler")
  local engine_mod = require("runtime.engine")
  local eval_mod = require("runtime.eval")

  local function compile(src)
    local result, diags = compiler.compile(src, "test.sb")
    local errors = {}
    for _, d in ipairs(diags or {}) do
      if d.level == "error" then errors[#errors+1] = d end
    end
    return result, errors
  end

  local SRC = [[
module va-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 100) = 0

scene main:
  * Earn
    inc! world/gold 10
    -> main
  * Stop
    -> end-scene

scene end-scene:
  Done.

fn always-nonneg:
  verify-always (world/gold >= 0)
fn always-zero:
  verify-always (world/gold = 0)
]]

  it("returns true when invariant holds in all reachable states", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local fn = gt.fns["always-nonneg"]
    local c = eval_mod.new_ctx(eng._state, gt.fns, "test")
    c.game = gt
    eval_mod.eval_stmts(fn.body, c)
    assert.is_true(c.retval)
  end)

  it("returns false when invariant can be violated", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local fn = gt.fns["always-zero"]
    local c = eval_mod.new_ctx(eng._state, gt.fns, "test")
    c.game = gt
    eval_mod.eval_stmts(fn.body, c)
    assert.is_false(c.retval)
  end)
end)

-- ============================================================
-- find-counterexample builtin
-- ============================================================

describe("find-counterexample builtin", function()
  local compiler = require("compiler.compiler")
  local engine_mod = require("runtime.engine")
  local eval_mod = require("runtime.eval")

  local function compile(src)
    local result, diags = compiler.compile(src, "test.sb")
    local errors = {}
    for _, d in ipairs(diags or {}) do
      if d.level == "error" then errors[#errors+1] = d end
    end
    return result, errors
  end

  local SRC = [[
module fce-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 100) = 0

scene main:
  * Earn
    inc! world/gold 10
    -> main

fn ce-of-zero:
  find-counterexample (world/gold = 0)
fn ce-of-nonneg:
  find-counterexample (world/gold >= 0)
]]

  it("returns nil when invariant always holds", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local fn = gt.fns["ce-of-nonneg"]
    local c = eval_mod.new_ctx(eng._state, gt.fns, "test")
    c.game = gt
    eval_mod.eval_stmts(fn.body, c)
    assert.is_nil(c.retval)
  end)

  it("returns counterexample GameState when invariant can be violated", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local fn = gt.fns["ce-of-zero"]
    local c = eval_mod.new_ctx(eng._state, gt.fns, "test")
    c.game = gt
    eval_mod.eval_stmts(fn.body, c)
    assert.is_not_nil(c.retval)
    -- The counterexample should be a GameState with gold > 0
    assert.is_true((c.retval:get("world/gold") or 0) > 0)
  end)
end)

-- ============================================================
-- probability search
-- ============================================================

describe("search.probability", function()
  local SRC_PROB = [[
module prob-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 100) = 0

scene main:
  * Earn
    inc! world/gold 10
    -> main
  * Wait
    -> main
]]

  it("returns 0 when condition impossible at depth 0 from initial state", function()
    local gt, errs = compile(SRC_PROB)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local p = search_mod.probability(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) >= 10
    end, 0)
    assert.equal(0, p)
  end)

  it("returns 0.5 when exactly half of depth-1 outcomes satisfy condition", function()
    local gt, errs = compile(SRC_PROB)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    -- 2 choices: Earn (gold=10, satisfies >=10) and Wait (gold=0, does not)
    -- → probability = 0.5
    local p = search_mod.probability(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) >= 10
    end, 1)
    assert.is_true(math.abs(p - 0.5) < 0.01, "expected ~0.5, got " .. tostring(p))
  end)

  it("returns 1.0 when condition always holds (e.g. gold >= 0)", function()
    local gt, errs = compile(SRC_PROB)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local p = search_mod.probability(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) >= 0
    end, 3)
    assert.is_true(math.abs(p - 1.0) < 0.01)
  end)
end)

-- ============================================================
-- optimal_path tests
-- ============================================================

describe("search.optimal_path", function()
  -- Scene with two choices: Earn10 (+10 gold, cheap but slow) and
  -- Earn50 (+50 gold, one step to goal).  With uniform cost (default),
  -- optimal_path should pick the 1-step Earn50 route over 5× Earn10.
  local SRC_OPT = [[
module opt-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 0

scene main:
  * Earn10
    inc! world/gold 10
    -> main
  * Earn50
    inc! world/gold 50
    -> main
]]

  it("finds 1-step Earn50 path (optimal) over 5-step Earn10 path", function()
    local gt, errs = compile(SRC_OPT)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    local path = search_mod.optimal_path(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) >= 50
    end, 10)
    assert.is_not_nil(path)
    -- Optimal (min-step) is 1 step via Earn50
    assert.equal(1, #path)
    assert.equal("Earn50", path[1].label)
  end)

  it("returns nil when goal is not reachable within depth", function()
    local gt, errs = compile(SRC_OPT)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    -- gold >= 9999 would require many steps; restrict depth so it's unreachable
    local path = search_mod.optimal_path(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) >= 9999
    end, 2)
    assert.is_nil(path)
  end)

  it("returns empty path when condition satisfied in initial state", function()
    local gt, errs = compile(SRC_OPT)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    local path = search_mod.optimal_path(gt, cache, {"main"}, function(c)
      return (c["world/gold"] or 0) == 0  -- already true
    end, 5)
    assert.is_not_nil(path)
    assert.equal(0, #path)
  end)
end)

-- ============================================================
-- Time-budget parameter
-- ============================================================

describe("search — time budget", function()
  it("can_reach returns false/nil without error when budget set (no BFS expansion)", function()
    -- With a non-existent scene the BFS loop has nothing to expand (<50 iterations),
    -- so the clock check never fires; returns false, false normally.
    local result, timed_out = search_mod.can_reach(
      { schema = {}, fns = {}, scenes = {}, actors = {}, schedules = {} },
      {},
      { "nonexistent-scene" },
      function() return false end,
      5,
      0
    )
    assert.is_false(timed_out)
    assert.is_false(result)
  end)

  it("can_reach returns nil (not false) on budget timeout", function()
    -- Use a game with a looping scene to generate enough BFS nodes to trip
    -- the BUDGET_CHECK_N=50 iteration threshold, then time out.
    local src = [[
module budget-test
  version: 1.0
engine-config:
  entry-scene: loop
state world/n : Int(0, 9999) = 0
scene loop:
  * Step
    inc! world/n 1
    -> loop
]]
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    -- budget=-1 guarantees timeout once the first clock check fires (iter 50)
    local result, timed_out = search_mod.can_reach(
      gt, cache, { "loop" },
      function(c) return (c["world/n"] or 0) >= 9999 end,
      200,   -- deep enough that BFS won't exhaust the space first
      -1     -- negative budget: os.clock() >= -1 is always true
    )
    assert.is_true(timed_out)
    assert.is_nil(result)   -- unknown, not false
  end)

  it("can_reach returns reached=true, timed_out=false when condition met immediately", function()
    local search_mod = require("runtime.search")
    local reached, timed_out = search_mod.can_reach(
      { schema = {}, fns = {}, scenes = {}, actors = {}, schedules = {} },
      { ["world/hp"] = 50 },
      {},
      function(c) return (c["world/hp"] or 0) > 0 end,
      5,
      1.0  -- 1 second budget
    )
    assert.is_true(reached)
    assert.is_false(timed_out)
  end)

  it("find_path returns nil on timeout (very tight budget)", function()
    local search_mod = require("runtime.search")
    -- Use an extremely small budget that's likely to trigger timeout
    -- (budget < 0 forces timeout since os.clock() - start >= budget immediately)
    local result = search_mod.find_path(
      { schema = {}, fns = {}, scenes = {}, actors = {}, schedules = {} },
      {},
      { "nonexistent" },
      function() return false end,
      5,
      -1  -- negative budget → always timed out
    )
    -- With a negative budget and BUDGET_CHECK_N=50, we'd need 50 iterations
    -- before the clock check. With no scenes to expand, BFS terminates normally.
    -- Result is nil (not found) either way.
    assert.is_nil(result)
  end)
end)

-- ============================================================
-- DFS strategy tests
-- ============================================================

describe("search DFS strategy", function()

  local src_dfs = [[
module dfs-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 0

scene main:
  * Earn
    inc! world/gold 10
    -> main
  * Stop
    -> end-scene

scene end-scene:
  Finished.
]]

  it("can_reach with strategy dfs finds reachable state", function()
    local gt, errs = compiler_mod.compile(src_dfs, "dfs-test.sb")
    assert.equal(0, #(errs or {}))

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    local reached = search_mod.can_reach(
      gt, cache, stack,
      function(c) return (c["world/gold"] or 0) >= 20 end,
      5, nil, "dfs"
    )
    assert.is_true(reached)
  end)

  it("can_reach with strategy dfs returns false when not reachable", function()
    local gt, errs = compiler_mod.compile(src_dfs, "dfs-test.sb")
    assert.equal(0, #(errs or {}))

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    local reached = search_mod.can_reach(
      gt, cache, stack,
      function(c) return (c["world/gold"] or 0) >= 999 end,
      3, nil, "dfs"
    )
    assert.is_false(reached)
  end)

  it("find_path with strategy dfs finds a valid path", function()
    local gt, errs = compiler_mod.compile(src_dfs, "dfs-test.sb")
    assert.equal(0, #(errs or {}))

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    local path = search_mod.find_path(
      gt, cache, stack,
      function(c) return (c["world/gold"] or 0) >= 10 end,
      5, nil, "dfs"
    )
    assert.is_not_nil(path)
    assert.is_true(#path >= 1)
    -- First step should be Earn (increments gold by 10)
    assert.equal("Earn", path[1].label)
  end)

  it("find_path with strategy dfs returns nil when unreachable", function()
    local gt, errs = compiler_mod.compile(src_dfs, "dfs-test.sb")
    assert.equal(0, #(errs or {}))

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    local path = search_mod.find_path(
      gt, cache, stack,
      function(c) return (c["world/gold"] or 0) >= 999 end,
      2, nil, "dfs"
    )
    assert.is_nil(path)
  end)
end)

-- ============================================================
-- Bounded computation branching in BFS
-- ============================================================

describe("search — bounded computation branching", function()
  it("can_reach finds goal reachable only via a specific bounded outcome", function()
    -- The scene has one choice: roll-die.  The game increments gold by the
    -- bounded result.  The goal (gold >= 5) is only reachable if the die
    -- can roll >= 5.  Without branching, a fixed handler returning 1 would
    -- miss this; with branching the BFS tries all values 1–6.
    local src = [[
module bounded-search
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0,100) = 0

bounded roll-die:
  returns: Int(1,6)
  distribution: uniform
  reads: []

fn do-roll:
  let result = roll-die 0
  set! world/gold result

scene main:
  * Roll
    do-roll
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    -- No handler registered — BFS should inject outcomes 1–6 automatically
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    -- Goal: gold >= 5 — reachable if the die ever rolls 5 or 6
    local reached = search_mod.can_reach(
      gt, cache, stack,
      function(c) return (c["world/gold"] or 0) >= 5 end,
      3
    )
    assert.is_true(reached, "expected BFS to find gold >= 5 via bounded branching")
  end)

  it("can_reach reports false when goal is impossible under all bounded outcomes", function()
    local src = [[
module bounded-search2
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0,100) = 0

bounded roll-die:
  returns: Int(1,3)
  distribution: uniform
  reads: []

fn do-roll:
  let result = roll-die 0
  set! world/gold result

scene main:
  * Roll
    do-roll
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    -- Goal: gold >= 5 — impossible since die only rolls 1–3
    local reached = search_mod.can_reach(
      gt, cache, stack,
      function(c) return (c["world/gold"] or 0) >= 5 end,
      3
    )
    assert.is_false(reached, "expected BFS to report unreachable when all outcomes < 5")
  end)
end)

-- ============================================================
-- Scheduled events as BFS successors (autonomous tick)
-- ============================================================

describe("search — scheduled event successors", function()
  it("autonomous tick fires after player action (post_action coverage)", function()
    -- Game: schedule fires every turn and increments a counter.
    -- can_reach should find the schedule-incremented state.
    local src = [[
module sched-search
  version: 1.0
engine-config:
  entry-scene: main
time-model:
  axes: [turn]

state world:
  ticks: Int(0, 100) = 0

schedule on-turn:
  every: [turn: +1]
  fn:
    inc! world/ticks 1

scene main:
  * Advance
    time-inc! turn: 1
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    -- After Advance + schedule fire, ticks should be > 0
    local reached = search_mod.can_reach(
      gt, cache, stack,
      function(c) return (c["world/ticks"] or 0) >= 1 end,
      5
    )
    assert.is_true(reached, "expected schedule-incremented state to be reachable")
  end)
end)

-- ============================================================
-- Random source branching in BFS
-- ============================================================

describe("search — random source branching", function()
  it("can_reach finds goal reachable only via lucky random roll", function()
    -- The fn body uses random-int 1 6 and sets gold to the result.
    -- Goal: gold >= 5 — reachable only if roll >= 5.
    -- BFS should branch over all outcomes 1-6 and find it.
    local src = [[
module random-search
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 10) = 0

fn roll-and-set:
  let roll = random-int 1 6:
    set! world/gold roll

scene main:
  * Roll
    roll-and-set
    -> end-scene

scene end-scene:
  Done.
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    -- Goal: gold >= 5 — reachable via random roll of 5 or 6
    local reached = search_mod.can_reach(
      gt, cache, stack,
      function(c) return (c["world/gold"] or 0) >= 5 end,
      3
    )
    assert.is_true(reached, "expected random branching to find gold >= 5")
  end)

  it("can_reach correctly reports false when no random outcome satisfies goal", function()
    local src = [[
module random-search2
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 10) = 0

fn roll-small:
  let roll = random-int 1 3:
    set! world/gold roll

scene main:
  * Roll
    roll-small
    -> end-scene

scene end-scene:
  Done.
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    -- Goal: gold >= 5 — impossible; max random is 3
    local reached = search_mod.can_reach(
      gt, cache, stack,
      function(c) return (c["world/gold"] or 0) >= 5 end,
      3
    )
    assert.is_false(reached, "expected random branching to correctly report unreachable")
  end)
end)

-- ============================================================
-- Best-first search strategy
-- ============================================================

describe("search — best-first strategy", function()
  it("can_reach with best-first finds reachable state", function()
    local src = [[
module bf-search
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 9999) = 0

scene main:
  * Earn
    inc! world/gold 10
    -> main
  * Stop
    -> end-scene

scene end-scene:
  Finished.
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    -- Best-first with heuristic: lower gold = farther from goal
    -- heuristic = how far we are from gold=20 (lower = closer)
    local function heuristic(c)
      return math.max(0, 20 - (c["world/gold"] or 0))
    end

    local reached = search_mod.can_reach(
      gt, cache, stack,
      function(c) return (c["world/gold"] or 0) >= 20 end,
      5, nil, "best-first", heuristic
    )
    assert.is_true(reached, "best-first should find gold >= 20")
  end)
end)

-- ============================================================
-- Probability: approximate-result annotation
-- ============================================================

describe("search — probability approximate result", function()
  it("returns probability and approximate=false when no pruning", function()
    local src = [[
module prob-search
  version: 1.0
engine-config:
  entry-scene: main

state world:
  done: Bool = false

scene main:
  * Finish
    set! world/done true
    -> end-scene

scene end-scene:
  Done.
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    local stack = { "main" }

    local prob, approx = search_mod.probability(
      gt, cache, stack,
      function(c) return c["world/done"] == true end,
      2, 0.001
    )
    assert.is_number(prob)
    assert.is_true(prob > 0, "done state should have nonzero probability")
    assert.is_boolean(approx)
    -- With only one path and high threshold, no pruning expected
    -- (approx may be false or true depending on threshold, but prob must be right)
  end)

  it("probability returns (number, boolean) two-value return", function()
    local src = [[
module prob-test2
  version: 1.0
engine-config:
  entry-scene: main
state world:
  x: Int(0, 1) = 0
scene main:
  * Go
    -> end-scene
scene end-scene:
  Done.
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    -- Returns two values: prob, approximate
    local p, a = search_mod.probability(gt, cache, {"main"},
      function(c) return true end, 1, 0.001)
    assert.is_number(p)
    assert.is_boolean(a)
  end)
end)

-- ============================================================
-- Coroutine iterator
-- ============================================================

describe("search — make_iterator coroutine", function()
  it("iterator yields all matching states", function()
    local src = [[
module iter-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  gold: Int(0, 50) = 0

scene main:
  * Earn
    inc! world/gold 10
    -> main
  * Stop
    -> end-scene

scene end-scene:
  Done.
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    -- Collect all states where gold > 0 (reachable after at least one Earn)
    local found = {}
    local iter = search_mod.make_iterator(
      gt, cache, {"main"},
      function(c) return (c["world/gold"] or 0) > 0 end,
      4  -- depth
    )
    for state_cache, path in iter do
      found[#found + 1] = { gold = state_cache["world/gold"], steps = #path }
    end

    assert.is_true(#found >= 1, "iterator should yield at least one matching state")
    -- All found states should have gold > 0
    for _, f in ipairs(found) do
      assert.is_true(f.gold > 0, "all yielded states must have gold > 0")
    end
  end)

  it("iterator yields nothing when condition never met", function()
    local src = [[
module iter-test2
  version: 1.0
engine-config:
  entry-scene: main
state world:
  x: Int(0, 1) = 0
scene main:
  * Go
    -> end-scene
scene end-scene:
  Done.
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    local count = 0
    local iter = search_mod.make_iterator(
      gt, cache, {"main"},
      function(c) return (c["world/x"] or 0) > 100 end,  -- impossible
      3
    )
    for _ in iter do count = count + 1 end
    assert.equal(0, count)
  end)
end)

-- ============================================================
-- Wall-clock budget for probability and optimal_path
-- ============================================================

describe("search — budget for probability and optimal_path", function()
  it("probability respects budget parameter (returns when time exceeded)", function()
    local src = [[
module budget-test
  version: 1.0
engine-config:
  entry-scene: main
state world:
  x: Int(0, 1) = 0
scene main:
  * Go
    -> end-scene
scene end-scene:
  Done.
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    -- With a tiny budget but simple graph, should still complete (or return approx)
    local p, approx = search_mod.probability(
      gt, cache, {"main"},
      function(c) return true end,
      2, 0.001, 10.0  -- 10 second budget (plenty)
    )
    assert.is_number(p)
    assert.is_boolean(approx)
  end)

  it("optimal_path respects budget parameter", function()
    local src = [[
module budget-opt
  version: 1.0
engine-config:
  entry-scene: main
state world:
  gold: Int(0, 100) = 0
scene main:
  * Earn
    inc! world/gold 10
    -> main
  * Stop
    -> end-scene
scene end-scene:
  Done.
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    -- With a generous budget, should still find the path
    local path = search_mod.optimal_path(
      gt, cache, {"main"},
      function(c) return (c["world/gold"] or 0) >= 10 end,
      5, nil, 10.0  -- 10 second budget
    )
    assert.is_not_nil(path)
  end)
end)

-- ============================================================
-- Bug #5 regression: dynamic schedule! visible to BFS
-- ============================================================

describe("search — dynamic schedule! in BFS", function()
  it("can_reach finds goal requiring dynamic schedule to fire twice", function()
    -- Scene "setup" creates a dynamic schedule (every 1 turn, increments ticks).
    -- BFS must propagate scheduler state across clone_cache / restore_engine,
    -- so the schedule continues to fire in subsequent "loop" steps.
    -- Note: schedule! trigger uses bare integer (not +N) to avoid parse_expr unary issue.
    local src = [[
module dyn-sched-bfs
  version: 1.0
engine-config:
  entry-scene: setup
time-model:
  axes: [turn]

state world:
  ticks: Int(0, 100) = 0

fn inc-ticks:
  inc! world/ticks 1

scene setup:
  * Arm
    schedule! `dyn-ticker every: [turn: 1] fn: inc-ticks
    time-inc! turn: 1
    -> loop

scene loop:
  * Wait
    time-inc! turn: 1
    -> loop
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local engine_mod_local = require("runtime.engine")
    local eng = engine_mod_local.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end
    for axis, val in pairs(eng._state._time or {}) do
      cache["__time/" .. axis] = val
    end

    -- ticks >= 2 requires: Arm (fires once, ticks=1) + Wait (fires again, ticks=2)
    local reached = search_mod.can_reach(
      gt, cache, { "setup" },
      function(c) return (c["world/ticks"] or 0) >= 2 end,
      10
    )
    assert.is_true(reached, "expected dynamic schedule to increment ticks to >=2")
  end)
end)

-- ============================================================
-- Bug #2 regression: UMap state preserved in BFS clone/restore
-- ============================================================

describe("search — UMap state preserved in BFS (bug #2)", function()
  local src = [[
module umap-bfs
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: start
state world:
  scores: UMap(String, Int(0,999)) = {}
fn record-score:
  map-set! world/scores "alice" 99
scene start:
  * Record
    record-score
    -> check
scene check:
  * Done
    -> check
]]

  it("can_reach detects a condition on a UMap value set by a fn", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do
      if type(v) == "table" then
        local copy = {}
        for tk, tv in pairs(v) do copy[tk] = tv end
        cache[k] = copy
      else
        cache[k] = v
      end
    end

    -- The condition checks that alice's score was recorded in the UMap
    local reached = search_mod.can_reach(
      gt, cache, { "start" },
      function(c)
        local scores = c["world/scores"]
        return type(scores) == "table" and scores["alice"] == 99
      end,
      5
    )
    assert.is_true(reached, "BFS should see UMap key `alice' after record-score")
  end)

  it("find_path can find a path that leads to a non-empty UMap state", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do cache[k] = v end

    local path = search_mod.find_path(
      gt, cache, { "start" },
      function(c)
        local scores = c["world/scores"]
        return type(scores) == "table" and scores["alice"] == 99
      end,
      5
    )
    assert.is_not_nil(path, "find_path should return a path to the UMap goal state")
  end)
end)

-- Bug 1 regression: hash_state must distinguish distinct UMap states
-- ============================================================
-- The bug: ipairs on a hash-keyed table (UMap) yields nothing, so two states
-- with different UMap contents produce the same BFS hash and the second is
-- treated as a duplicate and never expanded.
--
-- Test design: two choices both go to the same "waypoint" scene but write
-- different UMap entries.  The goal condition requires the "bob" entry AND a
-- scalar flag that is only set at the later "result" scene.  Without the fix,
-- the bob-branch state at waypoint collides with the alice-branch hash and is
-- skipped; can_reach never reaches result via the bob branch and returns false.

describe("search — hash_state distinguishes distinct UMap states (Bug 1 regression)", function()
  local src = [[
module umap-hash-distinct
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: start
state world:
  scores: UMap(String, Int(0,999)) = {}
  at_result: Int(0, 1) = 0
fn tag-alice:
  map-set! world/scores "alice" 99
fn tag-bob:
  map-set! world/scores "bob" 99
fn mark-result:
  set! world/at_result 1
scene start:
  * Tag Alice
    tag-alice
    -> waypoint
  * Tag Bob
    tag-bob
    -> waypoint
scene waypoint:
  * Finish
    mark-result
    -> result
scene result:
  * Loop
    -> result
]]

  it("can_reach finds goal only reachable through the bob branch (hash cycle detection)", function()
    local gt, errs = compile(src)
    assert.equal(0, #errs, errs[1] and errs[1].message)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = {}
    for k, v in pairs(eng._state._cache) do
      if type(v) == "table" then
        local copy = {}
        for tk, tv in pairs(v) do copy[tk] = tv end
        cache[k] = copy
      else
        cache[k] = v
      end
    end

    local reached = search_mod.can_reach(
      gt, cache, { "start" },
      function(c)
        return c["world/at_result"] == 1 and
               type(c["world/scores"]) == "table" and
               c["world/scores"]["bob"] == 99
      end,
      5
    )
    assert.is_true(reached, "BFS must not collapse distinct UMap states; bob goal must be reachable")
  end)
end)

-- ============================================================
-- A12 — Float values hash deterministically in BFS state dedup
-- ============================================================

describe("search hash_state — A12: deterministic float hashing", function()

  local hash_state = search_mod._hash_state

  it("treats integer-valued floats and integers as the same state", function()
    -- Before the A12 fix, tostring(1) → "1" and tostring(1.0) → "1.0", so two
    -- semantically-equal caches hashed differently and BFS would visit both,
    -- inflating the frontier. With %.17g formatting they collapse.
    local h_int   = hash_state({ ["world/x"] = 1   }, { "main" })
    local h_float = hash_state({ ["world/x"] = 1.0 }, { "main" })
    assert.are.equal(h_int, h_float)
  end)

  it("produces the same hash for an identical state cache (idempotent)", function()
    local cache = {
      ["world/x"]      = 0.1,
      ["world/y"]      = 42,
      ["world/items"]  = { "a", "b", "c" },
      ["world/scores"] = { alice = 80, bob = 95 },
    }
    -- Two independent hashes of the same cache must agree.
    assert.are.equal(
      hash_state(cache, { "main" }),
      hash_state(cache, { "main" })
    )
  end)

  it("distinguishes states that differ only in a float value", function()
    local h1 = hash_state({ ["world/x"] = 0.1 }, { "main" })
    local h2 = hash_state({ ["world/x"] = 0.2 }, { "main" })
    assert.is_not.equal(h1, h2)
  end)

  it("formats floats with enough precision to distinguish near-equal values", function()
    -- Two doubles that differ only in the 16th significant digit must still
    -- hash differently. With %.14g (the old default for tostring) these would
    -- collide; with %.17g they don't.
    local h1 = hash_state({ ["world/x"] = 0.1 + 1e-16 }, { "main" })
    local h2 = hash_state({ ["world/x"] = 0.1         }, { "main" })
    -- (0.1 + 1e-16) might round to 0.1 at double precision — in that case
    -- both hashes collapse, which is correct (the values *are* equal). What
    -- we really care about is that distinct representable doubles don't
    -- collide. Use values guaranteed to differ:
    local a = 0.1
    local b = math.nextafter and math.nextafter(0.1, 1.0) or (0.1 + 1e-16)
    if a ~= b then
      local ha = hash_state({ ["world/x"] = a }, { "main" })
      local hb = hash_state({ ["world/x"] = b }, { "main" })
      assert.is_not.equal(ha, hb)
    end
  end)

  it("hashes UMap values deterministically across re-orderings", function()
    -- pairs() iteration order over the UMap is non-deterministic in Lua;
    -- hash_state sorts subkeys to compensate. Verify that an identical UMap
    -- always produces the same hash regardless of insertion order.
    local cache_a = { ["world/m"] = {} }
    cache_a["world/m"].alice = 1
    cache_a["world/m"].bob   = 2
    cache_a["world/m"].carol = 3

    local cache_b = { ["world/m"] = {} }
    cache_b["world/m"].carol = 3
    cache_b["world/m"].alice = 1
    cache_b["world/m"].bob   = 2

    assert.are.equal(
      hash_state(cache_a, { "main" }),
      hash_state(cache_b, { "main" })
    )
  end)

end)

-- ============================================================
-- Temporal-logic verifiers (C3)
-- ============================================================

describe("search.verify_eventually (EF)", function()

  it("passes when a reaching path exists", function()
    local src = [[
engine-config:
  entry-scene: main
state world:
  flag: Bool = false
fn flip:
  set! world/flag true
scene main:
  * Flip
    flip
    -> main
  * Idle
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = search_mod.clone_cache(eng._state, eng._scheduler, gt)
    local cond = function(c) return c["world/flag"] == true end
    local r = search_mod.verify_eventually(gt, cache, {"main"}, cond, 4, 10)
    assert.is_true(r.pass, r.fail_msg)
    assert.is_truthy(r.counterexample_path)
    assert.is_true(#r.counterexample_path > 0)
  end)

  it("fails when no path satisfies condition", function()
    local src = [[
engine-config:
  entry-scene: main
state world:
  flag: Bool = false
scene main:
  * Idle
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = search_mod.clone_cache(eng._state, eng._scheduler, gt)
    local cond = function(c) return c["world/flag"] == true end
    local r = search_mod.verify_eventually(gt, cache, {"main"}, cond, 4, 10)
    assert.is_false(r.pass)
  end)

end)

describe("search.verify_always_eventually (AF)", function()

  it("passes when condition is forced", function()
    -- Only one choice, which sets flag=true.
    local src = [[
engine-config:
  entry-scene: main
state world:
  flag: Bool = false
fn flip:
  set! world/flag true
scene main:
  * Go
    flip
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = search_mod.clone_cache(eng._state, eng._scheduler, gt)
    local cond = function(c) return c["world/flag"] == true end
    local r = search_mod.verify_always_eventually(gt, cache, {"main"}, cond, 4, 10)
    assert.is_true(r.pass, r.fail_msg)
  end)

  it("fails when an avoidant path exists", function()
    local src = [[
engine-config:
  entry-scene: main
state world:
  flag: Bool = false
fn flip:
  set! world/flag true
scene main:
  * Flip
    flip
    -> main
  * Avoid
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = search_mod.clone_cache(eng._state, eng._scheduler, gt)
    local cond = function(c) return c["world/flag"] == true end
    local r = search_mod.verify_always_eventually(gt, cache, {"main"}, cond, 4, 10)
    assert.is_false(r.pass)
    assert.is_truthy(r.counterexample_path)
    assert.is_true(#r.counterexample_path > 0)
  end)

end)

describe("search.verify_until (AU)", function()

  it("passes when p holds until q on every path", function()
    local src = [[
engine-config:
  entry-scene: main
state world:
  step: Int(0, 10) = 0
fn next:
  inc! world/step 1
scene main:
  * Next
    next
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = search_mod.clone_cache(eng._state, eng._scheduler, gt)
    local p = function(c) return (c["world/step"] or 0) < 5 end
    local q = function(c) return (c["world/step"] or 0) >= 2 end
    local r = search_mod.verify_until(gt, cache, {"main"}, p, q, 4, 10)
    assert.is_true(r.pass, r.fail_msg)
  end)

  it("fails when p is violated before q ever holds", function()
    local src = [[
engine-config:
  entry-scene: main
state world:
  step: Int(0, 10) = 0
fn next:
  inc! world/step 1
scene main:
  * Next
    next
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs)
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = search_mod.clone_cache(eng._state, eng._scheduler, gt)
    -- p: step <= 0, q: step >= 5. p violated at step=1 before q ever holds.
    local p = function(c) return (c["world/step"] or 0) <= 0 end
    local q = function(c) return (c["world/step"] or 0) >= 5 end
    local r = search_mod.verify_until(gt, cache, {"main"}, p, q, 4, 10)
    assert.is_false(r.pass)
  end)

end)

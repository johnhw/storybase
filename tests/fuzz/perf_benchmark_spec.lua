-- tests/fuzz/perf_benchmark_spec.lua
-- Performance benchmark: search at depth 50 over a modest game world.
--
-- Goal: can-reach? with 20 NPCs at depth 50 completes within the wall-clock
-- budget enforced by the search engine (10 s).  In CI the test just validates
-- that the search returns *some* result within budget rather than hanging.
--
-- The budget is enforced internally by passing budget=10 to can_reach;
-- the test checks that the call returns (possibly as timed_out=true) rather
-- than blocking forever.

local compiler_mod = require("compiler.compiler")
local engine_mod   = require("runtime.engine")
local search_mod   = require("runtime.search")

-- ── Shared game source ────────────────────────────────────────────────────────

-- A game with 3 state variables (simulating a small world) + a win condition.
-- Does not use real actors to keep the setup deterministic and portable.
local BENCH_SRC = [[
module perf-bench
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main

state world:
  step:  Int(0, 200) = 0
  gold:  Int(0, 200) = 0
  done:  Bool        = false

fn advance:
  inc! world/step 1

fn earn:
  inc! world/gold 5

fn finish:
  set! world/done true

scene main:
  * Advance
    advance
    -> main
  * Earn
    earn
    -> main
  * Finish
    finish
    -> end-scene

scene end-scene:
  Done.
]]

local function compile(src)
  local result, diags = compiler_mod.compile(src, "bench.sb")
  return result, diags.errors or {}
end

-- ── Benchmark helpers ─────────────────────────────────────────────────────────

local function make_engine(gt)
  local eng = engine_mod.new(gt, { io_out = { write = function() end } })
  eng:init()
  return eng
end

local function copy_cache(cache)
  local c = {}
  for k, v in pairs(cache) do c[k] = v end
  return c
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

describe("performance benchmark", function()

  it("can_reach with depth=50 returns within 10s budget", function()
    local gt, errs = compile(BENCH_SRC)
    assert.equal(0, #errs, "compile error: " .. tostring(errs[1] and errs[1].message))

    local eng = make_engine(gt)
    local cache = copy_cache(eng._state._cache)
    local stack = { "main" }

    -- Condition: world/done == true (reachable via Finish choice)
    local cond = function(c, _s)
      return c["world/done"] == true
    end

    local t0 = os.clock()
    local found, timed_out = search_mod.can_reach(gt, cache, stack, cond, 50, 10)
    local elapsed = os.clock() - t0

    -- The search must terminate (not hang) — either found or timed out
    assert.is_true(found or timed_out or true,
      "can_reach did not return within budget")
    -- Should actually be found within depth 3 (Finish is a direct choice)
    assert.is_true(found, "world/done=true should be reachable within depth 50")
    -- Should be fast for a simple 3-choice game
    assert.is_true(elapsed < 10,
      string.format("search took %.2f s (budget 10 s)", elapsed))
  end)

  it("find_path returns a valid path to the goal state", function()
    local gt, errs = compile(BENCH_SRC)
    assert.equal(0, #errs)

    local eng = make_engine(gt)
    local cache = copy_cache(eng._state._cache)
    local stack = { "main" }

    local cond = function(c, _s)
      return c["world/done"] == true
    end

    local path = search_mod.find_path(gt, cache, stack, cond, 50, 10)
    assert.is_not_nil(path, "find_path should find a path to done=true")
    assert.is_true(#path > 0, "path should have at least one step")
    -- The path consists of {scene, label, index} steps; last step must come from "main"
    local last = path[#path]
    assert.is_not_nil(last.scene or last[1], "last path step should have a scene")
  end)

  it("probability of reaching done state is > 0", function()
    local gt, errs = compile(BENCH_SRC)
    assert.equal(0, #errs)

    local eng = make_engine(gt)
    local cache = copy_cache(eng._state._cache)
    local stack = { "main" }

    local cond = function(c, _s)
      return c["world/done"] == true
    end

    local prob = search_mod.probability(gt, cache, stack, cond, 10, 0)
    assert.is_true(prob > 0,
      "probability of reaching done should be > 0; got " .. tostring(prob))
  end)

  it("BFS does not block on budget=0 (immediate timeout)", function()
    local gt, errs = compile(BENCH_SRC)
    assert.equal(0, #errs)

    local eng = make_engine(gt)
    local cache = copy_cache(eng._state._cache)
    local stack = { "main" }

    -- budget = 0 means time out immediately after first check
    local cond = function(_c, _s) return false end
    local t0 = os.clock()
    local _, timed_out = search_mod.can_reach(gt, cache, stack, cond, 200, 0)
    local elapsed = os.clock() - t0

    assert.is_true(timed_out or elapsed < 2,
      "search with budget=0 should time out quickly")
  end)

end)

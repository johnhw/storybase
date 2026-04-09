-- tests/fuzz/search_fuzz_spec.lua
-- Fuzz/property tests for the search engine.
--
-- Invariant: for any finite state graph, the number of unique states found
-- by BFS make_iterator is >= the number of states reachable by BFS can_reach
-- exploration (i.e. the iterator visits at least as many states as can_reach).
--
-- Also tests:
--   - BFS and DFS find the same reachable set
--   - can_reach(cond) == (find_path(cond) ~= nil) for all conditions tested

local search_mod   = require("runtime.search")
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

local function make_cache(eng)
  local c = {}
  for k, v in pairs(eng._state._cache) do c[k] = v end
  return c
end

-- ── Shared game source: linear chain of states ────────────────────────────────

-- A linear chain: state 0 → 1 → 2 → ... → N (one choice per step).
-- This is a deterministic graph with exactly N+1 reachable states.
local function chain_src(n)
  local lines = {
    "module fuzz-chain",
    "  version: 1.0",
    "engine-config:",
    "  entry-scene: main",
    "",
    "state world:",
    "  step: Int(0, " .. n .. ") = 0",
    "",
    "scene main:",
    "  * Next",
    "    inc! world/step 1",
    "    -> main",
  }
  return table.concat(lines, "\n")
end

-- A branching tree: each step has 2 choices (+ or −), reaching 0..2^N unique values.
-- Uses base value 50 so decrement doesn't go negative.
local function branch_src(n)
  local _ = n  -- unused; depth controls branching
  local lines = {
    "module fuzz-branch",
    "  version: 1.0",
    "engine-config:",
    "  entry-scene: main",
    "",
    "state world:",
    "  val: Int(0, 100) = 50",
    "",
    "scene main:",
    "  * Up",
    "    inc! world/val 1",
    "    -> main",
    "  * Down",
    "    dec! world/val 1",
    "    -> main",
  }
  return table.concat(lines, "\n")
end

-- ── Tests ──────────────────────────────────────────────────────────────────

describe("search fuzz — state-space coverage", function()

  it("make_iterator visits all states BFS can_reach would explore (chain)", function()
    local src = chain_src(8)
    local gt, errs = compile(src)
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = make_cache(eng)
    local stack = { "main" }
    local depth = 8

    -- Count unique states via make_iterator (condition: always true = collect all)
    local visited_by_iter = {}
    local iter = search_mod.make_iterator(gt, cache, stack,
      function(c) return true end,  -- collect every reachable state
      depth)
    for state_cache, _ in iter do
      local key = tostring(state_cache["world/step"] or 0)
      visited_by_iter[key] = true
    end

    -- Count how many step values can_reach finds reachable
    local reachable_by_bfs = {}
    for step = 1, 8 do
      local found = search_mod.can_reach(gt, cache, stack,
        function(c) return (c["world/step"] or 0) == step end,
        depth)
      if found then reachable_by_bfs[tostring(step)] = true end
    end

    -- Every state reachable by BFS should have been visited by make_iterator
    local bfs_count = 0
    for k in pairs(reachable_by_bfs) do
      bfs_count = bfs_count + 1
      assert.is_true(visited_by_iter[k] ~= nil,
        "make_iterator missed state step=" .. k)
    end

    assert.is_true(bfs_count >= 1, "BFS should find at least one reachable state")
  end)

  it("BFS and DFS find the same states reachable (chain)", function()
    local src = chain_src(5)
    local gt, errs = compile(src)
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = make_cache(eng)
    local stack = { "main" }

    for target_step = 1, 5 do
      local cond = function(c) return (c["world/step"] or 0) == target_step end

      local bfs_result = search_mod.can_reach(gt, cache, stack, cond, 5, nil, "bfs")
      local dfs_result = search_mod.can_reach(gt, cache, stack, cond, 5, nil, "dfs")

      assert.equal(bfs_result, dfs_result,
        "BFS and DFS disagree for step=" .. target_step)
    end
  end)

  it("can_reach(cond) == (find_path(cond) ~= nil) for branching graph", function()
    local src = branch_src(3)
    local gt, errs = compile(src)
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = make_cache(eng)
    local stack = { "main" }
    local depth = 4

    -- Test various target values (base is 50, so 51=+1, 49=-1, 60=unreachable at depth 4)
    local targets = { 51, 52, 53, 49, 48, 60 }  -- 60 is unreachable at depth 4

    for _, target in ipairs(targets) do
      local cond = function(c) return (c["world/val"] or 0) == target end
      local reached  = search_mod.can_reach(gt, cache, stack, cond, depth)
      local path_res = search_mod.find_path(gt, cache, stack, cond, depth)

      -- They must agree
      assert.equal(
        reached,
        path_res ~= nil,
        string.format("can_reach and find_path disagree for val=%d (reached=%s, path=%s)",
          target, tostring(reached), tostring(path_res))
      )
    end
  end)

  it("best-first and BFS agree on reachability for chain", function()
    local src = chain_src(5)
    local gt, errs = compile(src)
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = make_cache(eng)
    local stack = { "main" }

    -- Heuristic: inverse of how close we are to the goal step
    local function make_heuristic(target_step)
      return function(c)
        return math.abs((c["world/step"] or 0) - target_step)
      end
    end

    for target_step = 1, 5 do
      local cond = function(c) return (c["world/step"] or 0) == target_step end
      local bfs_result  = search_mod.can_reach(gt, cache, stack, cond, 5, nil, "bfs")
      local bf_result   = search_mod.can_reach(gt, cache, stack, cond, 5, nil,
                            "best-first", make_heuristic(target_step))
      assert.equal(bfs_result, bf_result,
        "best-first and BFS disagree for step=" .. target_step)
    end
  end)

  it("probability sums to 1 when all paths satisfy condition (trivial game)", function()
    local src = [[
module prob-fuzz
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
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = make_cache(eng)

    -- Condition: always true → probability should be ~1.0 at depth >= 1
    local prob, approx = search_mod.probability(
      gt, cache, {"main"},
      function(c) return true end,
      1, 0.0001
    )
    assert.is_number(prob)
    -- With only one path "Go → end-scene", probability should be 1.0
    assert.is_true(math.abs(prob - 1.0) < 0.01,
      "expected probability ≈ 1.0, got " .. tostring(prob))
    assert.is_boolean(approx)
  end)

  it("time budget does not cause incorrect results on simple graph", function()
    -- With a generous budget on a tiny graph, results should be same as no budget
    local src = chain_src(3)
    local gt, errs = compile(src)
    assert.equal(0, #errs)

    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local cache = make_cache(eng)
    local stack = { "main" }
    local cond = function(c) return (c["world/step"] or 0) >= 2 end

    local r_no_budget  = search_mod.can_reach(gt, cache, stack, cond, 5)
    local r_with_budget = search_mod.can_reach(gt, cache, stack, cond, 5, 30.0)

    -- Results must agree (30 second budget is plenty for a 3-step chain)
    assert.equal(r_no_budget, r_with_budget,
      "budget parameter should not affect result on tiny graph")
  end)

end)

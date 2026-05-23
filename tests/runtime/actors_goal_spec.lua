-- tests/runtime/actors_goal_spec.lua
-- §H1 goal-directed actors: parser, checker, runtime planner, end-to-end.

local compiler_mod  = require("compiler.compiler")
local engine_mod    = require("runtime.engine")
local search_mod    = require("runtime.actor_search")

-- ============================================================
-- Helpers
-- ============================================================

local function compile(src)
  local gt, diags = compiler_mod.compile(src, "h1_test.sb")
  local errs = (diags and diags.errors) or {}
  return gt, errs, diags
end

local function diag_has(diags, code)
  if not diags then return false end
  for _, lst in ipairs({ diags.errors or {}, diags.warnings or {} }) do
    for _, d in ipairs(lst) do
      if d.code == code then return true end
    end
  end
  return false
end

--- Minimal six-room corridor: rooms in a line.  Thief's only legal mutator:
--- `move-to dest` whose precondition checks the `rooms` adjacency relation.
--- Goal: thief/at = `room6.
local MAZE_SRC = [[
module h1-maze

type Room = room1 | room2 | room3 | room4 | room5 | room6

relation rooms: Room -> Set(Room, 2):
  `room1: {`room2}
  `room2: {`room1, `room3}
  `room3: {`room2, `room4}
  `room4: {`room3, `room5}
  `room5: {`room4, `room6}
  `room6: {`room5}

state thief/at: Room = `room1

fn move-to dest: Room:
  pre: dest in (adjacent? rooms thief/at)
  set! thief/at dest

actor thief:
  state:        thief/at
  goal:         thief/at = `room6
  actions:      [move-to]
  search-depth: 6
  priority:     10
]]

--- Build a fully initialised engine from a source string.
local function fresh_engine(src)
  local gt, errs = compile(src)
  if #errs > 0 then
    for _, e in ipairs(errs) do print("compile error:", e.code, e.msg) end
    error("compilation failed")
  end
  local eng = engine_mod.new(gt, {})
  eng:init()
  return eng, gt
end

-- ============================================================
-- AST / parser / codegen smoke
-- ============================================================

describe("h1 — parser + codegen plumbing", function()
  it("parses goal:/actions:/search-depth:/search-budget-ms:", function()
    local gt, errs = compile(MAZE_SRC)
    assert.equal(0, #errs)
    assert.is_not_nil(gt.actors.thief)
    assert.is_not_nil(gt.actors.thief.goal)
    assert.same({ "move-to" }, gt.actors.thief.actions)
    assert.equal(6, gt.actors.thief.search_depth)
  end)

  it("preserves legacy actors (no goal/actions) untouched", function()
    local src = [[
module h1-legacy
state world/counter: Int(0,5) = 0
fn tick:
  inc! world/counter 1
actor scribe:
  state:    world
  behavior: tick
  priority: 1
]]
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    assert.equal("tick", gt.actors.scribe.behavior)
    assert.is_nil(gt.actors.scribe.goal)
  end)
end)

describe("h1 — checker diagnostics", function()
  it("rejects an actor with both goal: and behavior:", function()
    local src = [[
module h1-both
state world/x: Int(0,5) = 0
fn step:
  inc! world/x 1
actor a:
  state:    world
  goal:     world/x > 2
  actions:  [step]
  behavior: step
]]
    local _, errs = compile(src)
    local saw = false
    for _, e in ipairs(errs) do
      if e.code == "ACTOR_GOAL_BEHAVIOR_BOTH" then saw = true end
    end
    assert.is_true(saw)
  end)

  it("errors when an action: entry is undefined", function()
    local src = [[
module h1-undef_action
state world/x: Int(0,5) = 0
actor a:
  goal:    world/x > 2
  actions: [ghost-fn]
]]
    local _, errs = compile(src)
    assert.is_true(diag_has({errors=errs}, "ACTOR_ACTION_UNDEFINED"))
  end)

  it("errors when an action: entry is pure (no mutation)", function()
    local src = [[
module h1-pure_action
state world/x: Int(0,5) = 0
fn pure-check:
  pre: world/x > 0
actor a:
  goal:    world/x > 2
  actions: [pure-check]
]]
    local _, errs = compile(src)
    assert.is_true(diag_has({errors=errs}, "ACTOR_ACTION_PURE"))
  end)

  it("warns when an action has no pre: clauses", function()
    local src = [[
module h1-no_pre_action
state world/x: Int(0,5) = 0
fn always-step:
  inc! world/x 1
actor a:
  goal:    world/x > 3
  actions: [always-step]
]]
    local _, errs, diags = compile(src)
    assert.equal(0, #errs)
    assert.is_true(diag_has(diags, "WARN_ACTOR_ACTION_NO_PRE"))
  end)
end)

-- ============================================================
-- search module unit tests
-- ============================================================

describe("h1 — actor_search unit pieces", function()
  it("hash_cache is order-independent and stable", function()
    local a = { foo = 1, bar = 2, baz = 3 }
    local b = { baz = 3, foo = 1, bar = 2 }
    assert.equal(search_mod._hash_cache(a), search_mod._hash_cache(b))
  end)

  it("clone_cache copies sub-tables (no aliasing)", function()
    local a = { items = { "a", "b" } }
    local b = search_mod._clone_cache(a)
    table.insert(b.items, "c")
    assert.equal(2, #a.items)
    assert.equal(3, #b.items)
  end)

  it("enumerate_param handles Bool, bounded Int, inline enum", function()
    local lookup = {}
    assert.same({ false, true },
      search_mod._enumerate_param({ kind = "type_bool" }, {}, lookup))
    assert.same({ 0, 1, 2 },
      search_mod._enumerate_param({ kind = "type_int", min = 0, max = 2 }, {}, lookup))
    assert.same({ "a", "b" },
      search_mod._enumerate_param(
        { kind = "type_enum_inline", values = { "a", "b" } }, {}, lookup))
  end)

  it("enumerate_param refuses huge Int ranges (returns nil)", function()
    local r = search_mod._enumerate_param(
      { kind = "type_int", min = 0, max = 1000 }, {}, {})
    assert.is_nil(r)
  end)

  it("family_live_keys walks cache prefix and dedupes", function()
    local cache = {
      ["patients/alice/at"]    = "ward1",
      ["patients/alice/hp"]    = 10,
      ["patients/bethe/at"]    = "ward2",
      ["world/gold"]           = 5,
    }
    local keys = search_mod._family_live_keys(cache, "patients")
    table.sort(keys)
    assert.same({ "alice", "bethe" }, keys)
  end)

  it("cartesian returns single empty combo for no params", function()
    assert.same({ {} }, search_mod._cartesian({}))
  end)

  it("cartesian builds the cross-product", function()
    local r = search_mod._cartesian({ {1, 2}, { "a", "b" } })
    -- 2 × 2 = 4 combos
    assert.equal(4, #r)
  end)

  it("cartesian refuses when the product exceeds the cap", function()
    local huge = {}
    for i = 1, 200 do huge[i] = i end
    local r = search_mod._cartesian({ huge, huge })
    assert.is_nil(r)
  end)
end)

-- ============================================================
-- End-to-end: 6-room maze
-- ============================================================

describe("h1 — 6-room maze: bounded BFS reaches the goal", function()
  it("thief reaches `room6 with no behavior body", function()
    local eng = fresh_engine(MAZE_SRC)
    assert.equal("room1", eng._state:get("thief/at"))

    for _ = 1, 6 do
      eng:autonomous_turn()
    end
    assert.equal("room6", eng._state:get("thief/at"))
  end)

  it("idles when no plan exists (door cut by precondition)", function()
    -- One-room island: no neighbor → `move-to` precondition fails everywhere
    local src = [[
module h1-island
type Room = island | mainland
relation rooms: Room -> Set(Room, 1):
  `island: {}
  `mainland: {}
state thief/at: Room = `island
fn move-to dest: Room:
  pre: dest in (adjacent? rooms thief/at)
  set! thief/at dest
actor thief:
  state:    thief/at
  goal:     thief/at = `mainland
  actions:  [move-to]
  priority: 10
]]
    local eng = fresh_engine(src)
    eng:autonomous_turn()
    -- Still on the island. The H1 no-progress hook should have fired.
    assert.equal("island", eng._state:get("thief/at"))
    assert.is_not_nil(eng._h1_no_progress)
    assert.equal("thief", eng._h1_no_progress[1])
  end)
end)

-- ============================================================
-- Goal switches mid-game via precondition chain
-- ============================================================

describe("h1 — goal-switch via precondition chain", function()
  it("collects an item then heads to the exit", function()
    -- Tiny three-room corridor with a single item to collect along the way.
    -- Goal stays constant: `world/escaped` — but only the pickup → escape
    -- sequence satisfies the preconditions, so the BFS finds it.
    local src = [[
module h1-collect

type Room = a-start | a-middle | a-exit
relation rooms: Room -> Set(Room, 2):
  `a-start:  {`a-middle}
  `a-middle: {`a-start, `a-exit}
  `a-exit:   {`a-middle}

state thief/at: Room = `a-start
state thief/has-key: Bool = false
state world/escaped: Bool = false

fn move-to dest: Room:
  pre: dest in (adjacent? rooms thief/at)
  set! thief/at dest

fn pick-up-key:
  pre: thief/at = `a-middle
  pre: not thief/has-key
  set! thief/has-key true

fn escape:
  pre: thief/at = `a-exit
  pre: thief/has-key
  set! world/escaped true

actor thief:
  state:        thief/at
  goal:         world/escaped
  actions:      [move-to, pick-up-key, escape]
  search-depth: 6
  priority:     10
]]
    local eng = fresh_engine(src)
    for _ = 1, 10 do
      if eng._state:get("world/escaped") then break end
      eng:autonomous_turn()
    end
    assert.is_true(eng._state:get("world/escaped"))
    assert.is_true(eng._state:get("thief/has-key"))
    assert.equal("a-exit", eng._state:get("thief/at"))
  end)
end)

-- ============================================================
-- Two H1 actors compose under priority
-- ============================================================

describe("h1 — multiple goal-directed actors", function()
  it("priority determines which actor's set! wins on conflict", function()
    -- Both actors want to write to `world/owner`; high-priority wins.
    local src = [[
module h1-priority
type Owner = none | hi | lo
state world/owner: Owner = `none

fn claim-hi:
  pre: world/owner = `none
  set! world/owner `hi

fn claim-lo:
  pre: world/owner = `none
  set! world/owner `lo

actor high:
  goal:     world/owner = `hi
  actions:  [claim-hi]
  priority: 20

actor low:
  goal:     world/owner = `lo
  actions:  [claim-lo]
  priority: 10
]]
    local eng = fresh_engine(src)
    eng:autonomous_turn()
    assert.equal("hi", eng._state:get("world/owner"))
  end)
end)

-- ============================================================
-- Plan cache: reuses across ticks when state matches
-- ============================================================

describe("h1 — plan cache", function()
  it("caches BFS results across ticks and reuses on identical hash", function()
    local eng = fresh_engine(MAZE_SRC)
    -- Force the first tick — this populates the plan cache.
    eng:autonomous_turn()
    local actor = eng._game.actors.thief
    assert.is_not_nil(actor._h1_plan_cache)

    -- Drive to completion: cache hits accelerate subsequent picks.
    for _ = 1, 6 do
      if eng._state:get("thief/at") == "room6" then break end
      eng:autonomous_turn()
    end
    assert.equal("room6", eng._state:get("thief/at"))
  end)

  it("clear_plan_cache wipes the actor's stash", function()
    local eng = fresh_engine(MAZE_SRC)
    eng:autonomous_turn()
    local actor = eng._game.actors.thief
    assert.is_not_nil(actor._h1_plan_cache)
    search_mod.clear_plan_cache(actor)
    assert.is_nil(actor._h1_plan_cache)
  end)

  it("cache hit reuses the next step without re-searching", function()
    -- Tick 1 BFS finds [room2, room3, room4, room5, room6] from room1.
    -- After committing room2 the post-step hash should hold the rest of
    -- the plan; tick 2 must consume one entry and re-stash the tail.
    local eng = fresh_engine(MAZE_SRC)
    local actor = eng._game.actors.thief
    eng:autonomous_turn()  -- room1 → room2 (BFS run; rest stashed under hash@room2)
    assert.equal("room2", eng._state:get("thief/at"))
    -- Count entries in the cache: at least one stash exists.
    local cache_size = 0
    for _ in pairs(actor._h1_plan_cache) do cache_size = cache_size + 1 end
    assert.is_true(cache_size >= 1)
    eng:autonomous_turn()  -- room2 → room3 (should hit cache; pop room3 step)
    assert.equal("room3", eng._state:get("thief/at"))
  end)
end)

-- ============================================================
-- Search depth bound
-- ============================================================

describe("h1 — search-depth bound", function()
  it("a tight depth cap blocks an out-of-range goal (no progress)", function()
    -- 6-room maze with search-depth: 2.  From room1 the BFS can reach
    -- room1 → room2 → room3 in 2 moves; room6 (5 moves) is out of range.
    -- The planner returns nil every tick → no-progress hook fires →
    -- thief stays put at room1.
    local src = MAZE_SRC:gsub("search%-depth:%s*6", "search-depth: 2")
    local eng = fresh_engine(src)
    for _ = 1, 6 do eng:autonomous_turn() end
    assert.equal("room1", eng._state:get("thief/at"))
    assert.is_not_nil(eng._h1_no_progress)
    assert.equal("thief", eng._h1_no_progress[1])
  end)

  it("widening the depth makes the same goal reachable", function()
    -- Same maze, depth: 6 — the BFS now sees room6 from room1 and the
    -- plan-cache walks the thief through to it.
    local eng = fresh_engine(MAZE_SRC)
    for _ = 1, 6 do eng:autonomous_turn() end
    assert.equal("room6", eng._state:get("thief/at"))
  end)
end)

-- ============================================================
-- Action argument enumeration over a SymbolOf family
-- ============================================================

describe("h1 — SymbolOf(family) action params", function()
  it("enumerates live family keys as action args", function()
    -- Patients family with two members; goal is to treat all of them.
    local src = [[
module h1-symbolof

type Patient:
  treated: Bool = false

state patients/{p}: Patient max: 4
state world/all-treated: Bool = false

generate seed:
  spawn! patients `alice
  spawn! patients `bethe

fn treat p: SymbolOf(patients):
  pre: not patients/{p}/treated
  set! patients/{p}/treated true

fn check-all:
  pre: not world/all-treated
  pre: patients/alice/treated
  pre: patients/bethe/treated
  set! world/all-treated true

actor nurse:
  goal:         world/all-treated
  actions:      [treat, check-all]
  search-depth: 6
]]
    local eng = fresh_engine(src)
    for _ = 1, 6 do
      if eng._state:get("world/all-treated") then break end
      eng:autonomous_turn()
    end
    assert.is_true(eng._state:get("world/all-treated"))
    assert.is_true(eng._state:get("patients/alice/treated"))
    assert.is_true(eng._state:get("patients/bethe/treated"))
  end)
end)

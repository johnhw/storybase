-- tests/runtime/log_spec.lua
-- Unit tests for runtime/log.lua: append, query, serialise/deserialise.
--
-- Run with:  busted tests/

local log_mod = require("runtime.log")

-- ============================================================
-- Append / query basics
-- ============================================================

describe("transaction log: append", function()
  it("starts empty", function()
    local l = log_mod.new()
    assert.same({}, l:entries())
    assert.equal(0, l:seq())
  end)

  it("assigns sequential numbers", function()
    local l = log_mod.new()
    l:append({ path = "a", old = nil, new = 1, fn = "f" })
    l:append({ path = "b", old = nil, new = 2, fn = "f" })
    local es = l:entries()
    assert.equal(1, es[1].seq)
    assert.equal(2, es[2].seq)
    assert.equal(2, l:seq())
  end)
end)

-- ============================================================
-- Serialise / deserialise round-trip
-- ============================================================

describe("transaction log: serialise / deserialise", function()
  local function make_log()
    local l = log_mod.new()
    l:append({ path = "player/health", old = nil,  new = 100,     fn = "init" })
    l:append({ path = "player/alive",  old = nil,  new = true,    fn = "init" })
    l:append({ path = "player/name",   old = nil,  new = "Hero",  fn = "init" })
    l:append({ path = "player/health", old = 100,  new = 75,      fn = "hurt" })
    l:append({ path = "world/phase",   old = nil,  new = "setup", fn = "init" })
    return l
  end

  it("serialise produces a non-empty string", function()
    local l = make_log()
    local s = l:serialise()
    assert.is_string(s)
    assert.is_true(#s > 0)
    assert.is_true(s:sub(1, 6) == "return")
  end)

  it("round-trip preserves entry count", function()
    local l = make_log()
    local s = l:serialise()
    local l2 = log_mod.deserialise(s)
    assert.equal(#l:entries(), #l2:entries())
  end)

  it("round-trip preserves seq numbers", function()
    local l = make_log()
    local l2 = log_mod.deserialise(l:serialise())
    local e1 = l:entries()
    local e2 = l2:entries()
    for i = 1, #e1 do
      assert.equal(e1[i].seq, e2[i].seq)
    end
  end)

  it("round-trip preserves string values", function()
    local l = make_log()
    local l2 = log_mod.deserialise(l:serialise())
    local e2 = l2:entries()
    assert.equal("Hero",    e2[3]["new"])
    assert.equal("setup",   e2[5]["new"])
    assert.equal("init",    e2[1].fn)
    assert.equal("player/health", e2[1].path)
  end)

  it("round-trip preserves numeric values", function()
    local l = make_log()
    local l2 = log_mod.deserialise(l:serialise())
    local e2 = l2:entries()
    assert.equal(100, e2[1]["new"])
    assert.equal(75,  e2[4]["new"])
    assert.equal(100, e2[4].old)
  end)

  it("round-trip preserves boolean values", function()
    local l = make_log()
    local l2 = log_mod.deserialise(l:serialise())
    assert.equal(true, l2:entries()[2]["new"])
  end)

  it("round-trip preserves nil old/new values", function()
    local l = make_log()
    local l2 = log_mod.deserialise(l:serialise())
    assert.is_nil(l2:entries()[1].old)
  end)

  it("round-trip preserves max seq number", function()
    local l = make_log()
    local l2 = log_mod.deserialise(l:serialise())
    assert.equal(l:seq(), l2:seq())
  end)

  it("serialise handles strings with special characters", function()
    local l = log_mod.new()
    l:append({ path = "p", old = nil, new = 'say "hello"\n', fn = "f" })
    local l2 = log_mod.deserialise(l:serialise())
    assert.equal('say "hello"\n', l2:entries()[1]["new"])
  end)

  it("serialise handles table (list) values", function()
    local l = log_mod.new()
    l:append({ path = "inventory", old = {}, new = {"sword", "shield"}, fn = "f" })
    local l2 = log_mod.deserialise(l:serialise())
    local new_val = l2:entries()[1]["new"]
    assert.is_table(new_val)
    assert.equal("sword",  new_val[1])
    assert.equal("shield", new_val[2])
  end)

  -- Special entry kinds: verify round-trip preserves kind + relevant extra fields

  it("checkpoint entry round-trips with kind and fn", function()
    local l = log_mod.new()
    l:checkpoint("save-game")
    local l2 = log_mod.deserialise(l:serialise())
    local e = l2:entries()[1]
    assert.equal("checkpoint", e.kind)
    assert.equal("save-game",  e.fn)
  end)

  it("schedule_fired entry round-trips with schedule_name, next_fire, fired_axes", function()
    local l = log_mod.new()
    l:append({
      kind          = "schedule_fired",
      fn            = "schedule:daily-news",
      schedule_name = "daily-news",
      path          = nil, old = nil, ["new"] = nil,
      time          = { tick = 10, day = 1 },
      next_fire     = { tick = 20, day = 2 },
      fired_axes    = { "tick" },
    })
    local l2 = log_mod.deserialise(l:serialise())
    local e = l2:entries()[1]
    assert.equal("schedule_fired",  e.kind)
    assert.equal("daily-news",      e.schedule_name)
    assert.equal(20,                e.next_fire and e.next_fire.tick)
    assert.equal("tick",            e.fired_axes and e.fired_axes[1])
  end)

  it("schedule_created entry round-trips with schedule_name", function()
    local l = log_mod.new()
    l:append({
      kind          = "schedule_created",
      fn            = "setup",
      schedule_name = "weekly-event",
      path          = nil, old = nil, ["new"] = nil,
      next_fire     = { tick = 7 },
    })
    local l2 = log_mod.deserialise(l:serialise())
    local e = l2:entries()[1]
    assert.equal("schedule_created", e.kind)
    assert.equal("weekly-event",     e.schedule_name)
    assert.equal(7,                  e.next_fire and e.next_fire.tick)
  end)

  it("conflict entry round-trips with kind preserved", function()
    local l = log_mod.new()
    l:append({
      kind  = "conflict",
      fn    = "actor-a",
      path  = "world/count",
      old   = 5, ["new"] = 5,
    })
    local l2 = log_mod.deserialise(l:serialise())
    local e = l2:entries()[1]
    assert.equal("conflict", e.kind)
    assert.equal("world/count", e.path)
  end)

  it("inbox_overflow entry round-trips with kind preserved", function()
    local l = log_mod.new()
    l:append({
      kind  = "inbox_overflow",
      fn    = "actor-b",
      path  = nil, old = nil, ["new"] = nil,
    })
    local l2 = log_mod.deserialise(l:serialise())
    local e = l2:entries()[1]
    assert.equal("inbox_overflow", e.kind)
  end)
end)

-- ============================================================
-- serialise_entries (module-level)
-- ============================================================

describe("log_mod.serialise_entries", function()
  it("produces a table expression (no leading return)", function()
    local s = log_mod.serialise_entries({})
    assert.equal("{", s:sub(1, 1))
  end)

  it("empty entries yields empty table", function()
    local s = log_mod.serialise_entries({})
    local fn = load("return " .. s)
    assert.is_function(fn)
    local t = fn()
    assert.same({}, t)
  end)
end)

-- ============================================================
-- Round-trip: serialise → deserialise → identical cache
-- ============================================================

describe("log round-trip: serialise → deserialise", function()
  local state_mod = require("runtime.state")

  it("integer and symbol values survive round-trip", function()
    local l = log_mod.new()
    l:append({ path = "player/gold", old = 0,  new = 42,        fn = "earn" })
    l:append({ path = "player/mood", old = nil, new = "happy",  fn = "cheer" })
    local l2 = log_mod.deserialise(l:serialise())
    local es = l2:entries()
    assert.equal(42,      es[1]["new"])
    assert.equal("happy", es[2]["new"])
    assert.equal(2,       #es)
  end)

  it("boolean values survive round-trip", function()
    local l = log_mod.new()
    l:append({ path = "flags/alive", old = false, new = true, fn = "spawn" })
    local l2 = log_mod.deserialise(l:serialise())
    assert.equal(true, l2:entries()[1]["new"])
  end)

  it("replay over state reproduces same cache values", function()
    local schema = { types = {}, states = {}, relations = {} }
    local l = log_mod.new()
    local store = state_mod.new(schema, l)
    store:set("hero/hp", 100, "init")
    store:set("hero/hp", 75,  "damage")
    store:set("hero/name", "Aria", "init")

    -- Serialise and replay into a fresh store
    local entries = l:entries()
    local serialised = log_mod.serialise_entries(entries)
    local fn = load("return " .. serialised)
    local restored_entries = fn()

    local l2    = log_mod.new()
    local store2 = state_mod.new(schema, l2)
    state_mod.replay(store2, restored_entries)

    assert.equal(75,     store2:get("hero/hp"))
    assert.equal("Aria", store2:get("hero/name"))
  end)
end)

-- ============================================================
-- query_at
-- ============================================================

describe("transaction log: query_at", function()
  local function make_log_with_entries()
    local l = log_mod.new()
    -- seq 1: path "hp" = 100 at time {day=1}
    l:append({ path = "hp", old = nil, new = 100, fn = "init", time = {day=1} })
    -- seq 2: path "hp" = 80 at time {day=2}
    l:append({ path = "hp", old = 100, new = 80,  fn = "fight", time = {day=2} })
    -- seq 3: path "gold" = 5 at time {day=2}
    l:append({ path = "gold", old = nil, new = 5, fn = "init", time = {day=2} })
    -- seq 4: path "hp" = 50 at time {day=3}
    l:append({ path = "hp", old = 80,  new = 50,  fn = "fight", time = {day=3} })
    return l
  end

  it("nil time returns current (latest) value", function()
    local l = make_log_with_entries()
    assert.equal(50, l:query_at("hp", nil))
    assert.equal(5,  l:query_at("gold", nil))
  end)

  it("seq bound returns value at that sequence number", function()
    local l = make_log_with_entries()
    assert.equal(100, l:query_at("hp", 1))   -- after seq 1
    assert.equal(80,  l:query_at("hp", 2))   -- after seq 2
    assert.equal(80,  l:query_at("hp", 3))   -- seq 3 is gold, hp still 80
    assert.equal(50,  l:query_at("hp", 4))   -- after seq 4
    assert.equal(5,   l:query_at("gold", 3)) -- after seq 3
  end)

  it("seq bound before first entry returns nil", function()
    local l = make_log_with_entries()
    assert.is_nil(l:query_at("hp", 0))
  end)

  it("seq bound beyond last entry returns latest value", function()
    local l = make_log_with_entries()
    assert.equal(50, l:query_at("hp", 999))
  end)

  it("axis bound filters by time axis", function()
    local l = make_log_with_entries()
    assert.equal(100, l:query_at("hp", {day=1}))  -- only day=1 entry
    assert.equal(80,  l:query_at("hp", {day=2}))  -- day<=2 entries; last hp is 80
    assert.equal(50,  l:query_at("hp", {day=3}))  -- all entries; last hp is 50
  end)

  it("axis bound with no matching entries returns nil", function()
    local l = make_log_with_entries()
    assert.is_nil(l:query_at("hp", {day=0}))
  end)

  it("multi-axis bound requires all specified axes <= entry values", function()
    local l = log_mod.new()
    -- Two independent axes (both increase monotonically together)
    l:append({ path = "x", old = nil, new = 1, fn = "f", time = {day=1, hour=6} })
    l:append({ path = "x", old = 1,   new = 2, fn = "f", time = {day=1, hour=12} })
    l:append({ path = "x", old = 2,   new = 3, fn = "f", time = {day=2, hour=18} })

    -- At day=1, hour=10: include first (hour=6<=10) but not second (hour=12>10)
    assert.equal(1, l:query_at("x", {day=1, hour=10}))
    -- At day=1, hour=12: include both day=1 entries
    assert.equal(2, l:query_at("x", {day=1, hour=12}))
    -- At day=2, hour=18: all entries included
    assert.equal(3, l:query_at("x", {day=2, hour=18}))
    -- At day=2, hour=10: third entry (hour=18>10) and second (hour=12>10) excluded
    assert.equal(1, l:query_at("x", {day=2, hour=10}))
  end)
end)

-- ============================================================
-- Snapshot: serialise / deserialise
-- ============================================================

describe("snapshot: serialise / deserialise", function()
  it("round-trips a simple cache and time", function()
    local cache = { ["player/hp"] = 80, ["player/gold"] = 5 }
    local time  = { day = 3, tick = 12 }
    local str   = log_mod.serialise_snapshot(42, cache, time)
    assert.is_string(str)
    local snap = log_mod.deserialise_snapshot(str)
    assert.equal(42, snap.seq)
    assert.equal(3,  snap.time.day)
    assert.equal(12, snap.time.tick)
    assert.equal(80, snap.cache["player/hp"])
    assert.equal(5,  snap.cache["player/gold"])
  end)

  it("round-trips an empty cache", function()
    local str  = log_mod.serialise_snapshot(0, {}, {})
    local snap = log_mod.deserialise_snapshot(str)
    assert.equal(0, snap.seq)
    assert.same({}, snap.cache)
    assert.same({}, snap.time)
  end)

  it("round-trips a cache with list values", function()
    local cache = { ["bag"] = {"sword", "potion"} }
    local str  = log_mod.serialise_snapshot(5, cache, {})
    local snap = log_mod.deserialise_snapshot(str)
    assert.same({"sword", "potion"}, snap.cache["bag"])
  end)
end)

-- ============================================================
-- checkpoint / entries_after / entries_up_to / last_checkpoint_seq
-- ============================================================

describe("transaction log: checkpoint markers", function()
  it("checkpoint appends an entry with kind=`checkpoint'", function()
    local l = log_mod.new()
    l:checkpoint("my_fn")
    local entries = l:entries()
    assert.equal(1, #entries)
    assert.equal("checkpoint", entries[1].kind)
    assert.equal("my_fn",      entries[1].fn)
  end)

  it("checkpoint entry has a seq number", function()
    local l = log_mod.new()
    l:append({ kind = "set", path = "x", old = nil, ["new"] = 1, fn = "f" })
    l:checkpoint("cp")
    local entries = l:entries()
    assert.equal(2, entries[2].seq)
  end)
end)

describe("transaction log: last_checkpoint_seq", function()
  it("returns nil when no checkpoint exists", function()
    local l = log_mod.new()
    l:append({ kind = "set", path = "x", old = nil, ["new"] = 1, fn = "f" })
    assert.is_nil(l:last_checkpoint_seq())
  end)

  it("returns seq of most recent checkpoint", function()
    local l = log_mod.new()
    l:append({ kind = "set", path = "x", old = nil, ["new"] = 1, fn = "f" })
    l:checkpoint("cp1")
    local seq1 = l:last_checkpoint_seq()
    l:append({ kind = "set", path = "x", old = 1, ["new"] = 2, fn = "g" })
    l:checkpoint("cp2")
    local seq2 = l:last_checkpoint_seq()
    assert.is_true(seq2 > seq1)
  end)

  it("steps=2 goes two checkpoints back", function()
    local l = log_mod.new()
    l:checkpoint("cp1")
    local seq1 = l:last_checkpoint_seq()
    l:checkpoint("cp2")
    assert.equal(seq1, l:last_checkpoint_seq(2))
  end)

  it("returns nil when steps exceed checkpoint count", function()
    local l = log_mod.new()
    l:checkpoint("cp1")
    assert.is_nil(l:last_checkpoint_seq(99))
  end)
end)

describe("transaction log: entries_after", function()
  it("returns entries strictly after the given seq", function()
    local l = log_mod.new()
    l:append({ kind = "set", path = "a", old = nil, ["new"] = 1, fn = "f" })
    l:append({ kind = "set", path = "b", old = nil, ["new"] = 2, fn = "g" })
    l:append({ kind = "set", path = "c", old = nil, ["new"] = 3, fn = "h" })
    local after = l:entries_after(1)
    assert.equal(2, #after)
    assert.equal("b", after[1].path)
    assert.equal("c", after[2].path)
  end)

  it("excludes checkpoint and undo entries", function()
    local l = log_mod.new()
    l:append({ kind = "set", path = "a", old = nil, ["new"] = 1, fn = "f" })
    local seq1 = l:seq()
    l:checkpoint("cp")
    l:append({ kind = "set", path = "b", old = nil, ["new"] = 2, fn = "g" })
    local after = l:entries_after(seq1 - 1)
    local paths = {}
    for _, e in ipairs(after) do paths[#paths+1] = e.path end
    assert.same({"a", "b"}, paths)
  end)

  it("returns empty table when seq_from is at the end", function()
    local l = log_mod.new()
    l:append({ kind = "set", path = "x", old = nil, ["new"] = 1, fn = "f" })
    assert.same({}, l:entries_after(l:seq()))
  end)
end)

describe("transaction log: entries_up_to", function()
  it("returns only entries up to and including seq_to", function()
    local l = log_mod.new()
    l:append({ kind = "set", path = "a", old = nil, ["new"] = 1, fn = "f" })
    l:append({ kind = "set", path = "b", old = nil, ["new"] = 2, fn = "g" })
    l:append({ kind = "set", path = "c", old = nil, ["new"] = 3, fn = "h" })
    local up = l:entries_up_to(2)
    assert.equal(2, #up)
    assert.equal("a", up[1].path)
    assert.equal("b", up[2].path)
  end)

  it("excludes checkpoint entries", function()
    local l = log_mod.new()
    l:checkpoint("cp")
    l:append({ kind = "set", path = "x", old = nil, ["new"] = 1, fn = "f" })
    local up = l:entries_up_to(l:seq())
    assert.equal(1, #up)
    assert.equal("x", up[1].path)
  end)
end)

-- ============================================================
-- Design #2 regression: serialise/deserialise preserves extra fields
-- ============================================================

describe("log: serialise_entries preserves extra fields (Design #2 regression)", function()
  local log_mod2 = require("runtime.log")

  it("random draw entry survives round-trip with result field intact", function()
    local l = log_mod2.new()
    l:append({
      path    = "player/choice",
      old     = nil,
      ["new"] = "sword",
      fn      = "pick-weapon",
      result  = "sword",
      source  = "random",
      reads   = { "player/class" },
    })
    local entries = l:entries()
    local ser  = log_mod2.serialise_entries(entries)
    local fn   = assert(load("return " .. ser))
    local back = fn()
    assert.equal(1, #back)
    assert.equal("sword",  back[1].result)
    assert.equal("random", back[1].source)
    assert.is_table(back[1].reads)
    assert.equal("player/class", back[1].reads[1])
  end)

  it("counterfactual entry preserves transitions and simulate fields", function()
    local l = log_mod2.new()
    l:append({
      path        = nil,
      old         = nil,
      ["new"]     = nil,
      fn          = "what-if",
      kind        = "counterfactual",
      transitions = { "buy", "sell" },
      simulate    = true,
    })
    local entries = l:entries()
    local ser  = log_mod2.serialise_entries(entries)
    local fn   = assert(load("return " .. ser))
    local back = fn()
    assert.equal(1, #back)
    assert.equal(true, back[1].simulate)
    assert.is_table(back[1].transitions)
    assert.equal(2, #back[1].transitions)
  end)
end)

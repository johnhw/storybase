-- tests/runtime/state_spec.lua
-- Unit tests for runtime/state.lua
--
-- Run with:  busted tests/

local state_mod = require("runtime.state")
local log_mod   = require("runtime.log")

-- ============================================================
-- Helpers
-- ============================================================

--- Build a minimal schema with an int scalar and a record.
local function make_schema()
  return {
    types = {
      { kind = "enum", name = "Status", values = { "alive", "dead" } },
      {
        kind   = "record",
        name   = "Member",
        fields = {
          { name = "health", type_desc = { tag = "int", min = 0, max = 100 },
            default = { tag = "int", value = 60 } },
          { name = "status", type_desc = { tag = "named", name = "Status" },
            default = { tag = "symbol", name = "alive" } },
        },
      },
    },
    states = {
      { kind = "scalar", path = "player/health",
        type_desc = { tag = "int", min = 0, max = 100 },
        default   = { tag = "int", value = 50 } },
      { kind = "scalar", path = "player/alive",
        type_desc = { tag = "bool" },
        default   = { tag = "bool", value = true } },
      { kind = "record", path = "player",
        fields = {
          { name = "hp", type_desc = { tag = "int", min = 0, max = 100 },
            default = { tag = "int", value = 100 } },
        } },
      { kind = "family", family = "party", var = "m",
        type_desc = { tag = "named", name = "Member" },
        max = 4 },
    },
  }
end

--- Create a store with the minimal schema.
local function new_store(schema)
  local l = log_mod.new()
  return state_mod.new(schema or make_schema(), l), l
end

-- ============================================================
-- Basic read / write
-- ============================================================

describe("state store: get / set", function()
  it("returns nil for uninstantiated path", function()
    local s = new_store()
    assert.is_nil(s:get("player/health"))
  end)

  it("set stores value and get retrieves it", function()
    local s = new_store()
    s:set("player/health", 42, "test")
    assert.equal(42, s:get("player/health"))
  end)

  it("path_exists returns false before set, true after", function()
    local s = new_store()
    assert.is_false(s:path_exists("player/health"))
    s:set("player/health", 10, "test")
    assert.is_true(s:path_exists("player/health"))
  end)

  it("set appends a log entry", function()
    local s, l = new_store()
    s:set("player/health", 30, "fn1")
    local entries = l:entries()
    assert.equal(1, #entries)
    assert.equal("player/health", entries[1].path)
    assert.equal(30, entries[1].new)
    assert.is_nil(entries[1].old)
    assert.equal("fn1", entries[1].fn)
    assert.equal(1, entries[1].seq)
  end)

  it("sequential set increments seq numbers", function()
    local s, l = new_store()
    s:set("player/health", 10, "fn1")
    s:set("player/health", 20, "fn1")
    local entries = l:entries()
    assert.equal(1, entries[1].seq)
    assert.equal(2, entries[2].seq)
    assert.equal(10, entries[2].old)
    assert.equal(20, entries[2].new)
  end)
end)

-- ============================================================
-- inc / dec with clamping
-- ============================================================

describe("state store: inc / dec clamping", function()
  it("inc adds amount normally within range", function()
    local s = new_store()
    s:set("player/health", 50)
    s:inc("player/health", 20)
    assert.equal(70, s:get("player/health"))
  end)

  it("inc clamps to max", function()
    local s = new_store()
    s:set("player/health", 90)
    s:inc("player/health", 30)  -- would be 120, clamp to 100
    assert.equal(100, s:get("player/health"))
  end)

  it("dec subtracts amount normally within range", function()
    local s = new_store()
    s:set("player/health", 50)
    s:dec("player/health", 10)
    assert.equal(40, s:get("player/health"))
  end)

  it("dec clamps to min", function()
    local s = new_store()
    s:set("player/health", 5)
    s:dec("player/health", 20)  -- would be -15, clamp to 0
    assert.equal(0, s:get("player/health"))
  end)

  it("inc on unknown path does not clamp", function()
    local s = new_store()
    s:set("unknown/counter", 10)
    s:inc("unknown/counter", 9999)
    assert.equal(10009, s:get("unknown/counter"))
  end)
end)

-- ============================================================
-- Set (collection) mutations
-- ============================================================

describe("state store: add / remove / clear (Set)", function()
  it("add inserts a value", function()
    local s = new_store()
    s:add("tags", "brave")
    local set = s:get("tags")
    assert.equal(1, #set)
    assert.equal("brave", set[1])
  end)

  it("add is idempotent (no duplicate)", function()
    local s = new_store()
    s:add("tags", "brave")
    s:add("tags", "brave")
    assert.equal(1, #s:get("tags"))
  end)

  it("remove deletes a value", function()
    local s = new_store()
    s:add("tags", "brave")
    s:add("tags", "fast")
    s:remove("tags", "brave")
    local set = s:get("tags")
    assert.equal(1, #set)
    assert.equal("fast", set[1])
  end)

  it("remove is a no-op if value absent", function()
    local s = new_store()
    s:add("tags", "brave")
    s:remove("tags", "unknown")
    assert.equal(1, #s:get("tags"))
  end)

  it("clear empties a set", function()
    local s = new_store()
    s:add("tags", "a"); s:add("tags", "b")
    s:clear("tags")
    assert.equal(0, #s:get("tags"))
  end)
end)

-- ============================================================
-- List mutations
-- ============================================================

describe("state store: push / pop (List)", function()
  it("push appends a value", function()
    local s = new_store()
    s:push("history", "move1")
    s:push("history", "move2")
    local list = s:get("history")
    assert.equal(2, #list)
    assert.equal("move1", list[1])
    assert.equal("move2", list[2])
  end)

  it("pop removes and returns last element", function()
    local s = new_store()
    s:push("history", "move1")
    s:push("history", "move2")
    local val = s:pop("history")
    assert.equal("move2", val)
    assert.equal(1, #s:get("history"))
  end)

  it("pop on empty list errors", function()
    local s = new_store()
    assert.has_error(function() s:pop("history") end)
  end)

  it("push on full bounded list raises LIST_OVERFLOW", function()
    local schema = {
      types  = {},
      states = {
        { kind = "scalar", path = "history",
          type_desc = { tag = "list", max = 2, inner = { tag = "string" } } },
      },
    }
    local s = new_store(schema)
    s:push("history", "a")
    s:push("history", "b")
    local ok, err = pcall(function() s:push("history", "c") end)
    assert.is_false(ok, "push beyond max should error")
    assert.is_truthy(tostring(err):find("LIST_OVERFLOW"), "error should mention LIST_OVERFLOW")
  end)
end)

-- ============================================================
-- Entity family: spawn / despawn
-- ============================================================

describe("state store: spawn / despawn", function()
  it("spawn writes family member fields", function()
    local s = new_store()
    s:spawn("party", "fighter", { health = 80, status = "alive" })
    assert.equal(80,      s:get("party/fighter/health"))
    assert.equal("alive", s:get("party/fighter/status"))
  end)

  it("spawn creates a sentinel key", function()
    local s = new_store()
    s:spawn("party", "scout", {})
    assert.is_true(s:path_exists("party/scout"))
  end)

  it("spawn errors if key already exists", function()
    local s = new_store()
    s:spawn("party", "fighter", {})
    assert.has_error(function()
      s:spawn("party", "fighter", {})
    end)
  end)

  it("despawn removes all family member paths", function()
    local s = new_store()
    s:spawn("party", "fighter", { health = 80, status = "alive" })
    s:despawn("party", "fighter")
    assert.is_nil(s:get("party/fighter"))
    assert.is_nil(s:get("party/fighter/health"))
  end)

  it("path_list returns all instantiated family keys", function()
    local s = new_store()
    s:spawn("party", "fighter", {})
    s:spawn("party", "scout", {})
    local keys = s:path_list("party")
    table.sort(keys)
    assert.same({ "fighter", "scout" }, keys)
  end)

  it("spawn applies type field defaults for omitted fields", function()
    local s = new_store()
    -- Only specify health; status should default to "alive" from Member type
    s:spawn("party", "fighter", { health = 80 })
    assert.equal(80,      s:get("party/fighter/health"))
    assert.equal("alive", s:get("party/fighter/status"))
  end)

  it("spawn does not override explicitly provided fields with defaults", function()
    local s = new_store()
    s:spawn("party", "ghost", { health = 1, status = "dead" })
    assert.equal(1,      s:get("party/ghost/health"))
    assert.equal("dead", s:get("party/ghost/status"))
  end)

  it("path_list returns empty for uninstantiated family", function()
    local s = new_store()
    assert.same({}, s:path_list("party"))
  end)
end)

-- ============================================================
-- Default initialisation
-- ============================================================

describe("state store: init_defaults", function()
  it("initialises scalar defaults", function()
    local s = new_store()
    s:init_defaults()
    assert.equal(50, s:get("player/health"))
    assert.is_true(s:get("player/alive"))
  end)

  it("initialises record field defaults", function()
    local s = new_store()
    s:init_defaults()
    assert.equal(100, s:get("player/hp"))
  end)

  it("does not instantiate family members", function()
    local s = new_store()
    s:init_defaults()
    assert.same({}, s:path_list("party"))
  end)
end)

-- ============================================================
-- Log: query_at / query_history
-- ============================================================

describe("transaction log: query", function()
  it("query_history returns ordered change list", function()
    local s, l = new_store()
    s:set("player/health", 10)
    s:set("player/health", 20)
    s:set("player/health", 30)
    local hist = l:query_history("player/health")
    assert.equal(3, #hist)
    assert.equal(10, hist[1].new)
    assert.equal(20, hist[2].new)
    assert.equal(30, hist[3].new)
  end)

  it("query_changes returns last N changes", function()
    local s, l = new_store()
    s:set("player/health", 10)
    s:set("player/health", 20)
    s:set("player/health", 30)
    local recent = l:query_changes("player/health", 2)
    assert.equal(2, #recent)
    assert.equal(20, recent[1].new)
    assert.equal(30, recent[2].new)
  end)
end)

-- ============================================================
-- Time model: inc_time / get_time
-- ============================================================

describe("state store: time model", function()
  local function make_timed_store()
    local schema = {
      types = {}, states = {},
      time_model = {
        axes = { "day", "hour", "tick" },
        wrap = { "none", 24, "none" },
      },
    }
    local l = log_mod.new()
    return state_mod.new(schema, l), l
  end

  it("starts at zero for all declared axes", function()
    local s = make_timed_store()
    local t = s:get_time()
    assert.equal(0, t.day)
    assert.equal(0, t.hour)
    assert.equal(0, t.tick)
  end)

  it("inc_time advances a non-wrapping axis", function()
    local s = make_timed_store()
    s:inc_time("tick", 5)
    assert.equal(5, s:get_time().tick)
    s:inc_time("tick", 3)
    assert.equal(8, s:get_time().tick)
  end)

  it("inc_time wraps the hour axis at 24", function()
    local s = make_timed_store()
    s:inc_time("hour", 20)
    s:inc_time("hour", 6)   -- 20 + 6 = 26 → wraps to 2
    assert.equal(2, s:get_time().hour)
  end)

  it("inc_time does not wrap non-wrap axes", function()
    local s = make_timed_store()
    s:inc_time("day", 100)
    assert.equal(100, s:get_time().day)
  end)

  it("log entries include time snapshot", function()
    local s, l = make_timed_store()
    s:inc_time("tick", 5)
    s:set("player/health", 80, "hurt")
    local entries = l:entries()
    local last = entries[#entries]
    assert.is_table(last.time)
    assert.equal(5, last.time.tick)
  end)
end)

-- ============================================================
-- Snapshot-accelerated replay
-- ============================================================

describe("state: replay_from_snapshot", function()
  local function make_store()
    local l = log_mod.new()
    local s = state_mod.new({}, l)
    return s, l
  end

  it("restores cache from snapshot without replaying earlier entries", function()
    local s, l = make_store()
    -- Simulate first 3 mutations
    s:set("player/hp",   100, "init")
    s:set("player/gold", 50,  "init")
    s:set("player/hp",   80,  "fight")  -- seq 3

    -- Create snapshot at seq 3
    local snap_str = log_mod.serialise_snapshot(l:seq(), s._cache, s._time)
    local snap     = log_mod.deserialise_snapshot(snap_str)

    -- More mutations after snapshot
    s:set("player/hp",   60, "fight2")  -- seq 4
    s:set("player/gold", 45, "buy")    -- seq 5

    -- Fresh store; replay from snapshot + only entries 4-5
    local s2, l2 = make_store()
    state_mod.replay_from_snapshot(s2, snap, l:entries())

    assert.equal(60, s2:get("player/hp"))
    assert.equal(45, s2:get("player/gold"))
  end)

  it("snapshot with no delta entries restores snapshot state exactly", function()
    local s, l = make_store()
    s:set("x", 7, "f")

    local snap = log_mod.deserialise_snapshot(
      log_mod.serialise_snapshot(l:seq(), s._cache, s._time))

    local s2 = make_store()
    state_mod.replay_from_snapshot(s2, snap, {})
    assert.equal(7, s2:get("x"))
  end)

  it("restores time from snapshot then advances via delta", function()
    local schema = { time_model = { axes = {"tick"}, wrap = {} } }
    local l = log_mod.new()
    local s = state_mod.new(schema, l)
    s:inc_time("tick", 10)
    s:set("x", 1, "f")

    local snap = log_mod.deserialise_snapshot(
      log_mod.serialise_snapshot(l:seq(), s._cache, s._time))

    s:inc_time("tick", 5)
    s:set("x", 2, "g")

    local l2 = log_mod.new()
    local s2 = state_mod.new(schema, l2)
    state_mod.replay_from_snapshot(s2, snap, l:entries())

    assert.equal(2,  s2:get("x"))
    assert.equal(15, s2:get_time().tick)
  end)
end)

-- ============================================================
-- Checkpoint / undo
-- ============================================================

describe("state store: push_checkpoint / undo", function()
  it("undo with no checkpoints returns false", function()
    local s = new_store()
    assert.is_false(s:undo())
  end)

  it("undo restores state to checkpoint", function()
    local s = new_store()
    s:set("player/health", 80, "f")
    s:push_checkpoint("before_battle")
    s:set("player/health", 30, "damage")
    assert.equal(30, s:get("player/health"))
    assert.is_true(s:undo())
    assert.equal(80, s:get("player/health"))
  end)

  it("undo drops the used checkpoint so a second undo fails", function()
    local s = new_store()
    s:set("player/health", 80, "f")
    s:push_checkpoint("cp")
    s:set("player/health", 10, "g")
    s:undo()
    assert.is_false(s:undo())
  end)

  it("undo steps=2 reverts two checkpoints back", function()
    local s = new_store()
    s:set("player/health", 100, "f")
    s:push_checkpoint("cp1")
    s:set("player/health", 70, "g")
    s:push_checkpoint("cp2")
    s:set("player/health", 40, "h")
    assert.is_true(s:undo(2))
    assert.equal(100, s:get("player/health"))
  end)

  it("push_checkpoint writes a checkpoint marker to the log", function()
    local s, l = new_store()
    s:push_checkpoint("my_fn")
    local found = false
    for _, e in ipairs(l:entries()) do
      if e.kind == "checkpoint" and e.fn == "my_fn" then found = true end
    end
    assert.is_true(found)
  end)
end)

-- ============================================================
-- Hook callbacks
-- ============================================================

describe("state store: _clamp_hook", function()
  it("fires when inc saturates at max", function()
    local s = new_store()
    s:init_defaults()
    local fired_path, fired_attempted, fired_clamped
    s._clamp_hook = function(path, attempted, clamped)
      fired_path      = path
      fired_attempted = attempted
      fired_clamped   = clamped
    end
    s:inc("player/health", 999, "f")
    assert.equal("player/health", fired_path)
    assert.equal(1049,            fired_attempted) -- 50 + 999
    assert.equal(100,             fired_clamped)
  end)

  it("fires when dec saturates at min", function()
    local s = new_store()
    s:init_defaults()
    local fired_clamped
    s._clamp_hook = function(_, _, clamped) fired_clamped = clamped end
    s:dec("player/health", 999, "f")
    assert.equal(0, fired_clamped)
  end)

  it("does not fire when no saturation occurs", function()
    local s = new_store()
    s:init_defaults()
    local fired = false
    s._clamp_hook = function() fired = true end
    s:inc("player/health", 10, "f")
    assert.is_false(fired)
  end)
end)

describe("state store: _spawn_hook / _despawn_hook", function()
  it("_spawn_hook fires after spawn with family / key / record", function()
    local s = new_store()
    local fam, key_s, rec
    s._spawn_hook = function(f, k, r) fam = f; key_s = k; rec = r end
    s:spawn("party", "hero", { health = 90, status = "alive" }, "f")
    assert.equal("party",  fam)
    assert.equal("hero",   key_s)
    assert.equal(90, rec.health)
  end)

  it("_despawn_hook fires after despawn with family / key", function()
    local s = new_store()
    s:spawn("party", "hero", { health = 90, status = "alive" }, "f")
    local fam, key_s
    s._despawn_hook = function(f, k) fam = f; key_s = k end
    s:despawn("party", "hero", "g")
    assert.equal("party", fam)
    assert.equal("hero",  key_s)
  end)
end)

-- ============================================================
-- Bug #1 regression: deep_copy_cache / undo preserve UMap (hash-keyed) values
-- ============================================================

describe("state store: undo preserves UMap values (Bug #1 regression)", function()
  it("checkpoint + undo restores a UMap (hash-keyed table) intact", function()
    local l = log_mod.new()
    local s = state_mod.new({}, l)
    -- Store a UMap-style value (string keys → string values)
    s:set("notes/map", { alpha = "a", beta = "b", gamma = "c" }, "init")
    s:push_checkpoint("before_mutate")
    -- Overwrite with a different table
    s:set("notes/map", { delta = "d" }, "mutate")
    assert.equal("d", s:get("notes/map").delta)
    assert.is_true(s:undo())
    -- After undo the original UMap must be intact, not emptied
    local restored = s:get("notes/map")
    assert.equal("a", restored.alpha)
    assert.equal("b", restored.beta)
    assert.equal("c", restored.gamma)
  end)
end)

-- ============================================================
-- Bug #5 regression: set_time ignores undeclared axes
-- ============================================================

describe("state store: set_time ignores undeclared axes (Bug #5 regression)", function()
  it("set_time on a declared axis updates it", function()
    local schema = { time_model = { axes = { "day", "hour" }, wrap = {} } }
    local l = log_mod.new()
    local s = state_mod.new(schema, l)
    s:inc_time("hour", 10)
    s:set_time("hour", 8)
    assert.equal(8, s:get_time().hour)
  end)

  it("set_time on an undeclared axis is silently ignored", function()
    local schema = { time_model = { axes = { "day", "hour" }, wrap = {} } }
    local l = log_mod.new()
    local s = state_mod.new(schema, l)
    -- `tick' is not declared; calling set_time on it must not install a new key
    s:set_time("tick", 99)
    local t = s:get_time()
    assert.is_nil(t.tick, "undeclared axis must not be added to _time")
  end)
end)

-- ============================================================
-- Bug #7 regression: path_list returns sorted keys
-- ============================================================

describe("state store: path_list returns deterministic sorted order (Bug #7 regression)", function()
  it("path_list is sorted lexicographically regardless of insertion order", function()
    local l = log_mod.new()
    local s = state_mod.new({}, l)
    -- Insert in deliberately non-alphabetical order
    s:set("crew/zara/hp", 10, "f")
    s:set("crew/alice/hp", 20, "f")
    s:set("crew/mike/hp", 30, "f")
    local keys = s:path_list("crew")
    assert.same({ "alice", "mike", "zara" }, keys)
  end)
end)

-- ============================================================
-- Design #1 regression: spawn O(1) uniqueness check still errors on duplicate
-- ============================================================

describe("state store: spawn rejects duplicate key (Design #1 regression)", function()
  it("spawning the same key twice raises SPAWN_EXISTS", function()
    local l = log_mod.new()
    local s = state_mod.new({}, l)
    s:spawn("crew", "alice", { hp = 50 }, "f")
    assert.error_matches(function()
      s:spawn("crew", "alice", { hp = 50 }, "g")
    end, "SPAWN_EXISTS")
  end)

  it("spawning different keys does not error", function()
    local l = log_mod.new()
    local s = state_mod.new({}, l)
    s:spawn("crew", "alice", { hp = 50 }, "f")
    assert.has_no_error(function()
      s:spawn("crew", "bob", { hp = 40 }, "g")
    end)
  end)
end)

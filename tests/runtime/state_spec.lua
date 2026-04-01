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
          { name = "health", type_desc = { tag = "int", min = 0, max = 100 } },
          { name = "status", type_desc = { tag = "named", name = "Status" } },
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

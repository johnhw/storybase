-- tests/fuzz/log_fuzz_spec.lua
-- Property tests for log serialisation / deserialisation.
--
-- Invariants:
--   1. serialise → deserialise is a round-trip for any valid entry list.
--   2. replay of a serialised log produces the same cache as the original.
--   3. log:query_at and log:query_history are consistent after random mutations.

local log_mod   = require("runtime.log")
local state_mod = require("runtime.state")

-- ── Helpers ──────────────────────────────────────────────────────────────────

math.randomseed(123)

local PATHS  = { "world/gold", "world/health", "player/level", "npcs/count" }
local VALUES = { 0, 1, 5, 10, 42, 99, true, false }

--- Generate N random mutation entries for paths in PATHS.
local function random_entries(n, seed)
  math.randomseed(seed or 1)
  local entries = {}
  for i = 1, n do
    local path = PATHS[math.random(1, #PATHS)]
    local val  = VALUES[math.random(1, #VALUES)]
    entries[#entries+1] = {
      seq  = i,
      path = path,
      old  = nil,
      ["new"] = val,
      fn   = "fuzz",
      time = { tick = i },
      op   = "set",
    }
  end
  return entries
end

--- Build a minimal schema with the fuzz paths.
local function minimal_schema()
  return {
    states = {
      { kind = "scalar", path = "world/gold",   type_desc = { tag = "int", min = 0, max = 9999 }, default = { tag = "int", value = 0 } },
      { kind = "scalar", path = "world/health", type_desc = { tag = "int", min = 0, max = 100  }, default = { tag = "int", value = 0 } },
      { kind = "scalar", path = "player/level", type_desc = { tag = "int", min = 1, max = 99   }, default = { tag = "int", value = 1 } },
      { kind = "scalar", path = "npcs/count",   type_desc = { tag = "int", min = 0, max = 999  }, default = { tag = "int", value = 0 } },
    },
    types = {},
    engine_config = {},
    time_model = { axes = { "tick" }, wrap = {} },
  }
end

--- Replay entries onto a fresh store and return its cache snapshot.
local function replay_to_cache(entries, schema)
  local lg    = log_mod.new()
  local store = state_mod.new(schema, lg)
  store:init_defaults()
  state_mod.replay(store, entries)
  local snap = {}
  for k, v in pairs(store._cache) do snap[k] = v end
  return snap
end

-- ── Tests ────────────────────────────────────────────────────────────────────

describe("log fuzz — serialise/deserialise round-trip", function()

  it("empty log serialises and deserialises", function()
    local lg = log_mod.new()
    local s = lg:serialise()
    assert.is_string(s)
    local restored_lg = log_mod.deserialise(s)
    assert.is_table(restored_lg)
    assert.equal(0, #restored_lg:entries())
  end)

  it("single entry round-trips correctly", function()
    local lg = log_mod.new()
    lg:append({ path = "world/gold", old = 0, ["new"] = 42, fn = "earn", op = "set" })
    local restored_lg = log_mod.deserialise(lg:serialise())
    local entries = restored_lg:entries()
    assert.equal(1, #entries)
    assert.equal("world/gold", entries[1].path)
    assert.equal(42,           entries[1]["new"])
    assert.equal("earn",       entries[1].fn)
  end)

  it("N random entries survive serialise/deserialise", function()
    for _, n in ipairs({ 1, 5, 20, 100 }) do
      local entries = random_entries(n, n * 7)
      local lg = log_mod.new()
      for _, e in ipairs(entries) do lg:append(e) end
      local restored = log_mod.deserialise(lg:serialise()):entries()
      assert.equal(#entries, #restored,
        "entry count mismatch for n=" .. n)
      for i, e in ipairs(entries) do
        assert.equal(e.path,      restored[i].path,
          "path mismatch at entry " .. i .. " for n=" .. n)
        assert.equal(e["new"],    restored[i]["new"],
          "value mismatch at entry " .. i .. " for n=" .. n)
      end
    end
  end)

  it("serialise_entries / deserialise round-trip", function()
    local entries = random_entries(30, 777)
    -- serialise_entries returns a table literal without "return"; deserialise needs "return ..."
    local s        = "return " .. log_mod.serialise_entries(entries)
    local restored = log_mod.deserialise(s):entries()
    assert.equal(#entries, #restored)
    for i, e in ipairs(entries) do
      assert.equal(e.path,   restored[i].path)
      assert.equal(e["new"], restored[i]["new"])
    end
  end)

end)

describe("log fuzz — replay determinism", function()

  it("replaying same entries twice produces identical caches", function()
    local schema  = minimal_schema()
    local entries = random_entries(50, 2024)

    local cache1 = replay_to_cache(entries, schema)
    local cache2 = replay_to_cache(entries, schema)

    for k, v in pairs(cache1) do
      assert.equal(v, cache2[k], "cache mismatch at key " .. tostring(k))
    end
    for k, v in pairs(cache2) do
      assert.equal(v, cache1[k], "cache mismatch at key " .. tostring(k))
    end
  end)

  it("serialise + deserialise + replay produces same cache as direct replay", function()
    local schema  = minimal_schema()
    local entries = random_entries(40, 31415)

    -- Direct replay
    local cache_direct = replay_to_cache(entries, schema)

    -- Via serialise/deserialise
    local lg = log_mod.new()
    for _, e in ipairs(entries) do lg:append(e) end
    local restored_entries = log_mod.deserialise(lg:serialise()):entries()
    local cache_via_serde  = replay_to_cache(restored_entries, schema)

    for k, v in pairs(cache_direct) do
      assert.equal(v, cache_via_serde[k],
        "serde replay mismatch at key " .. tostring(k))
    end
  end)

  it("appending checkpoint entries does not affect state replay", function()
    local schema = minimal_schema()
    local lg     = log_mod.new()
    lg:append({ path = "world/gold", old = 0,  ["new"] = 10, fn = "earn", op = "set" })
    lg:checkpoint("test-fn")
    lg:append({ path = "world/gold", old = 10, ["new"] = 20, fn = "earn", op = "set" })

    local store = state_mod.new(schema, log_mod.new())
    store:init_defaults()
    state_mod.replay(store, lg:entries())

    assert.equal(20, store:get("world/gold"))
  end)

end)

describe("log fuzz — query_at consistency", function()

  it("query_at returns last value at or before requested tick", function()
    local lg = log_mod.new()
    lg:append({ path = "world/gold", old = 0,  ["new"] = 10, fn = "a",
                time = { tick = 1 }, op = "set" })
    lg:append({ path = "world/gold", old = 10, ["new"] = 20, fn = "b",
                time = { tick = 2 }, op = "set" })
    lg:append({ path = "world/gold", old = 20, ["new"] = 30, fn = "c",
                time = { tick = 3 }, op = "set" })

    assert.equal(10, lg:query_at("world/gold", 1))
    assert.equal(20, lg:query_at("world/gold", 2))
    assert.equal(30, lg:query_at("world/gold", 3))
    assert.equal(30, lg:query_at("world/gold", 99))
  end)

  it("random set operations: query_at reflects last-write-wins per tick", function()
    local lg   = log_mod.new()
    local last = {}
    for tick = 1, 20 do
      local path = PATHS[math.random(1, 2)]  -- only first two paths
      local val  = math.random(0, 99)
      lg:append({ path = path, ["new"] = val, fn = "f",
                  time = { tick = tick }, op = "set" })
      last[path] = val
    end
    for _, path in ipairs({ PATHS[1], PATHS[2] }) do
      if last[path] then
        local got = lg:query_at(path, 20)
        assert.equal(last[path], got,
          "query_at mismatch for " .. path)
      end
    end
  end)

end)

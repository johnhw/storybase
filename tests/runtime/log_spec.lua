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

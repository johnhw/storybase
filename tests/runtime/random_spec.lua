-- tests/runtime/random_spec.lua
-- Covers the per-instance PCG32 RNG. The key invariants we test are:
--   * No mutation of Lua's global math.random state
--   * Two RNG instances with the same seed produce identical streams
--   * Two RNG instances with different seeds produce different streams,
--     and remain independent even when interleaved
--   * save_state / load_state round-trip exactly
--   * The provider hook can intercept any draw kind
--   * Logging is fired when a log instance is attached

local random_mod = require("runtime.random")
local log_mod    = require("runtime.log")

describe("runtime.random PCG32", function()

  it("does not mutate the global math.random state", function()
    -- Pin Lua's global RNG to a known seed, draw a value, then construct
    -- several RNG instances and draw heavily from them. The global state
    -- must still produce the same next value.
    math.randomseed(42)
    local expected_next = math.random()

    math.randomseed(42)  -- reset
    local _ = math.random()  -- consume the same first draw
    local before_state = math.random()  -- record the next expected value

    -- Re-pin and stress the PCG instances
    math.randomseed(42)
    local _ = math.random()  -- consume first
    for s = 1, 5 do
      local r = random_mod.new(s * 1000)
      for _ = 1, 100 do r:int(0, 9999) end
    end
    local after_state = math.random()

    assert.are.equal(before_state, after_state)
    -- Also: in a fresh process this would be expected_next; here just
    -- assert the values match between the two probes.
    assert.is_number(expected_next)
  end)

  it("two instances with the same seed produce identical streams", function()
    local a = random_mod.new(12345)
    local b = random_mod.new(12345)
    for _ = 1, 50 do
      assert.are.equal(a:int(0, 999999), b:int(0, 999999))
    end
  end)

  it("two instances with different seeds produce different first draws", function()
    -- Probability of collision on a single 32-bit draw is ~2^-32, so this is
    -- safe as a deterministic check.
    local a = random_mod.new(1)
    local b = random_mod.new(2)
    assert.is_not.equal(a:int(0, 0xFFFFFFFF), b:int(0, 0xFFFFFFFF))
  end)

  it("two instances remain independent under interleaved draws", function()
    -- Reference streams: run each in isolation
    local ref_a = random_mod.new(7)
    local ref_b = random_mod.new(13)
    local stream_a, stream_b = {}, {}
    for i = 1, 20 do
      stream_a[i] = ref_a:int(0, 999)
      stream_b[i] = ref_b:int(0, 999)
    end

    -- Interleaved: each call to A must not affect B and vice versa
    local a = random_mod.new(7)
    local b = random_mod.new(13)
    for i = 1, 20 do
      assert.are.equal(stream_a[i], a:int(0, 999))
      assert.are.equal(stream_b[i], b:int(0, 999))
    end
  end)

  it("save_state / load_state round-trip exactly", function()
    local r = random_mod.new(99)
    -- Burn some draws
    for _ = 1, 17 do r:int(0, 999) end
    local snap = r:save_state()

    -- Capture the next 10 draws
    local forecast = {}
    for i = 1, 10 do forecast[i] = r:int(0, 999) end

    -- Restore and re-roll: must match forecast exactly
    r:load_state(snap)
    for i = 1, 10 do
      assert.are.equal(forecast[i], r:int(0, 999))
    end
  end)

  it("uniform() stays in [0, 1)", function()
    local r = random_mod.new(2024)
    for _ = 1, 5000 do
      local u = r:uniform()
      assert.is_true(u >= 0 and u < 1)
    end
  end)

  it("uniform() has approximately correct mean", function()
    local r = random_mod.new(1)
    local sum = 0
    local N = 20000
    for _ = 1, N do sum = sum + r:uniform() end
    assert.is_true(math.abs(sum / N - 0.5) < 0.01)
  end)

  it("int(min, max) covers the inclusive range", function()
    local r = random_mod.new(3)
    local seen_min, seen_max = false, false
    for _ = 1, 1000 do
      local v = r:int(1, 4)
      assert.is_true(v >= 1 and v <= 4)
      if v == 1 then seen_min = true end
      if v == 4 then seen_max = true end
    end
    assert.is_true(seen_min)
    assert.is_true(seen_max)
  end)

  it("bool(p) reflects probability roughly", function()
    local r = random_mod.new(5)
    local hits = 0
    local N = 5000
    for _ = 1, N do if r:bool(0.3) then hits = hits + 1 end end
    local rate = hits / N
    assert.is_true(rate > 0.27 and rate < 0.33)
  end)

  it("enum / choice / weighted return valid values", function()
    local r = random_mod.new(11)
    local enum_values = { "a", "b", "c" }
    for _ = 1, 100 do
      local v = r:enum(enum_values)
      assert.is_true(v == "a" or v == "b" or v == "c")
    end
    for _ = 1, 100 do
      local v = r:choice({ 10, 20, 30 })
      assert.is_true(v == 10 or v == 20 or v == 30)
    end
    for _ = 1, 100 do
      local v = r:weighted({ 1, 1, 1 }, { "x", "y", "z" })
      assert.is_true(v == "x" or v == "y" or v == "z")
    end
  end)

  it("provider intercepts all draw kinds", function()
    local r = random_mod.new(0)
    local seen = {}
    r:set_provider(function(kind, ...)
      seen[#seen + 1] = kind
      if kind == "int"      then return 42 end
      if kind == "bool"     then return true end
      if kind == "enum"     then return "INJECTED" end
      if kind == "choice"   then return "INJECTED" end
      if kind == "weighted" then return "INJECTED" end
      if kind == "uniform"  then return 0.5 end
      return nil
    end)

    assert.are.equal(42, r:int(0, 999))
    assert.is_true(r:bool(0.1))
    assert.are.equal("INJECTED", r:enum({ "a", "b" }))
    assert.are.equal("INJECTED", r:choice({ "x", "y" }))
    assert.are.equal("INJECTED", r:weighted({ 1, 1 }, { "p", "q" }))
    assert.are.equal(0.5, r:uniform())

    -- All five draw kinds should have been observed (uniform first, then the
    -- four logged kinds — order may vary depending on call order above).
    assert.is_true(#seen == 6)
  end)

  it("provider returning nil delegates to the default PCG", function()
    local a = random_mod.new(2026)
    local b = random_mod.new(2026)
    b:set_provider(function() return nil end)
    for _ = 1, 10 do
      assert.are.equal(a:int(0, 999), b:int(0, 999))
    end
  end)

  it("appends log entries when a log is attached", function()
    local log = log_mod.new()
    local r   = random_mod.new(1, log)
    r:int(0, 9)
    r:bool(0.5)
    r:choice({ "a", "b" })
    local entries = log:entries()
    assert.are.equal(3, #entries)
    assert.are.equal("random", entries[1].kind)
    assert.are.equal("random-int",   entries[1].source)
    assert.are.equal("random-bool",  entries[2].source)
    assert.are.equal("random-choice", entries[3].source)
  end)

  it("seed() re-initialises the stream", function()
    local a = random_mod.new(0)
    local b = random_mod.new(0)
    -- Burn some draws on a, then re-seed; must match a freshly-seeded b
    for _ = 1, 10 do a:int(0, 999) end
    a:seed(0)
    for _ = 1, 5 do
      assert.are.equal(a:int(0, 999), b:int(0, 999))
    end
  end)

end)

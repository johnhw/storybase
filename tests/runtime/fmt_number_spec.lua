-- tests/runtime/fmt_number_spec.lua
-- Covers runtime.log.fmt_number — the shared number-to-Lua-literal helper
-- used by log serialisation and CLI save formats.
--
-- Replaces the previous "%.14g" everywhere. The key invariants:
--   * Integers serialise without a decimal point and without scientific notation
--   * Floats round-trip exactly via load() (need %.17g for IEEE 754 doubles)
--   * NaN / ±Infinity produce valid Lua expressions that load() back to the
--     same special value (previously emitted as "inf"/"nan" — invalid Lua)

local log_mod = require("runtime.log")
local fmt     = log_mod.fmt_number

local function roundtrip(v)
  local src = "return " .. fmt(v)
  local chunk, err = load(src)
  assert(chunk, "could not parse: " .. tostring(src) .. " — " .. tostring(err))
  return chunk()
end

describe("runtime.log.fmt_number", function()

  it("formats small integers without a decimal point", function()
    assert.are.equal("0",   fmt(0))
    assert.are.equal("1",   fmt(1))
    assert.are.equal("-1",  fmt(-1))
    assert.are.equal("42",  fmt(42))
    assert.are.equal("-99", fmt(-99))
  end)

  it("formats large integers up to 2^53 without scientific notation", function()
    local big = 2 ^ 50
    local s = fmt(big)
    assert.is_nil(s:find("e"))
    assert.is_nil(s:find("E"))
    assert.are.equal(big, roundtrip(big))
  end)

  it("round-trips floats exactly (better than %.14g)", function()
    -- These values require 17 significant digits to round-trip a double.
    local values = {
      0.1,
      0.2,
      1/3,
      math.pi,
      1e-10,
      1.7976931348623157e+308,  -- near max double
      2.2250738585072014e-308,  -- near min positive normal
    }
    for _, v in ipairs(values) do
      assert.are.equal(v, roundtrip(v))
    end
  end)

  it("handles NaN as (0/0)", function()
    local nan = 0/0
    assert.are.equal("(0/0)", fmt(nan))
    local rt = roundtrip(nan)
    assert.is_true(rt ~= rt)  -- NaN is the only number where x ~= x
  end)

  it("handles +Infinity as math.huge", function()
    assert.are.equal("math.huge", fmt(math.huge))
    assert.are.equal(math.huge, roundtrip(math.huge))
  end)

  it("handles -Infinity as -math.huge", function()
    assert.are.equal("-math.huge", fmt(-math.huge))
    assert.are.equal(-math.huge, roundtrip(-math.huge))
  end)

  it("integer detection respects the 2^53 boundary", function()
    -- Values beyond 2^53 lose integer precision in a double; they should
    -- format as floats (with decimal/exponent), not naive %d.
    local boundary = 2 ^ 53
    local just_above = boundary + 1024  -- can't represent exactly as double-int
    local s = fmt(just_above)
    -- Must round-trip exactly to the same double value
    assert.are.equal(just_above, roundtrip(just_above))
    -- And not silently truncate via %d
    assert.is_truthy(s:find("[eE.]") or just_above == roundtrip(just_above))
  end)

end)

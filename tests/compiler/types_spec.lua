-- tests/compiler/types_spec.lua
-- Unit tests for compiler/types.lua state-space arithmetic.
--
-- compiler/types.lua exposes pure helpers over the small resolved-type
-- representation (`{tag, kind, ...}`). The production state-space sizer
-- lives in compiler/codegen.lua; these tests exercise the standalone
-- helpers as a public API.

local types = require("compiler.types")

describe("types.is_discrete / is_superficial", function()
  it("returns true for matching tag", function()
    assert.is_true(types.is_discrete({tag = types.DISCRETE}))
    assert.is_true(types.is_superficial({tag = types.SUPERFICIAL}))
  end)

  it("returns false for opposite tag", function()
    assert.is_false(types.is_discrete({tag = types.SUPERFICIAL}))
    assert.is_false(types.is_superficial({tag = types.DISCRETE}))
  end)

  it("returns nil/false for nil or missing tag", function()
    assert.is_falsy(types.is_discrete(nil))
    assert.is_falsy(types.is_superficial(nil))
    assert.is_falsy(types.is_discrete({}))
    assert.is_falsy(types.is_superficial({}))
  end)
end)

describe("types.state_space_size — primitives", function()
  it("nil → 0", function()
    assert.equals(0, types.state_space_size(nil))
  end)

  it("bool → 2", function()
    assert.equals(2, types.state_space_size({kind = "bool"}))
  end)

  it("unknown kind → 0", function()
    assert.equals(0, types.state_space_size({kind = "totally-made-up"}))
  end)
end)

describe("types.state_space_size — int", function()
  it("Int(0, 10) → 11 (inclusive range)", function()
    assert.equals(11, types.state_space_size({kind = "int", min = 0, max = 10}))
  end)

  it("Int(5, 5) → 1 (single point)", function()
    assert.equals(1, types.state_space_size({kind = "int", min = 5, max = 5}))
  end)

  it("Int(-3, 3) → 7 (spanning zero)", function()
    assert.equals(7, types.state_space_size({kind = "int", min = -3, max = 3}))
  end)

  it("Int(10, 0) — inverted bounds clamp to 0", function()
    assert.equals(0, types.state_space_size({kind = "int", min = 10, max = 0}))
  end)
end)

describe("types.state_space_size — enum", function()
  it("counts enum values", function()
    assert.equals(3, types.state_space_size({
      kind = "enum", values = {"a", "b", "c"},
    }))
  end)

  it("empty / missing values → 0", function()
    assert.equals(0, types.state_space_size({kind = "enum", values = {}}))
    assert.equals(0, types.state_space_size({kind = "enum"}))
  end)
end)

describe("types.state_space_size — symbols", function()
  it("plain symbol is unbounded", function()
    assert.equals(math.huge, types.state_space_size({kind = "symbol"}))
  end)

  it("symbol_of uses family size", function()
    assert.equals(8, types.state_space_size({
      kind = "symbol_of", family_size = 8,
    }))
  end)

  it("symbol_of with no family_size → unbounded", function()
    assert.equals(math.huge, types.state_space_size({kind = "symbol_of"}))
  end)
end)

describe("types.state_space_size — option", function()
  it("Option(T) adds one for None", function()
    assert.equals(4, types.state_space_size({
      kind = "option", inner_size = 3,
    }))
  end)

  it("Option with missing inner_size still has at least 2 (None + 1)", function()
    -- defaults inner_size to 1 → returns 2
    assert.equals(2, types.state_space_size({kind = "option"}))
  end)
end)

describe("types.state_space_size — set", function()
  it("Set(T, 0) — only the empty set", function()
    assert.equals(1, types.state_space_size({
      kind = "set", elem_size = 5, max = 0,
    }))
  end)

  it("Set(T, 1) over |T|=3 → C(3,0) + C(3,1) = 1 + 3 = 4", function()
    assert.equals(4, types.state_space_size({
      kind = "set", elem_size = 3, max = 1,
    }))
  end)

  it("Set(T, 2) over |T|=4 → 1 + 4 + 6 = 11", function()
    assert.equals(11, types.state_space_size({
      kind = "set", elem_size = 4, max = 2,
    }))
  end)

  it("Set(T, 5) over |T|=3 — max clamped to |T| → 1+3+3+1 = 8", function()
    -- Σ C(3,i) for i=0..3 = 8 (only first 4 terms in the sum)
    assert.equals(8, types.state_space_size({
      kind = "set", elem_size = 3, max = 5,
    }))
  end)

  it("missing elem_size → only the empty set fits", function()
    assert.equals(1, types.state_space_size({kind = "set", max = 3}))
  end)
end)

describe("types.state_space_size — list", function()
  it("List(T, 0) → 1 (only empty list)", function()
    assert.equals(1, types.state_space_size({
      kind = "list", elem_size = 5, max = 0,
    }))
  end)

  it("List(T, 1) over |T|=3 → (3+1)^1 = 4 (absent or any of 3)", function()
    assert.equals(4, types.state_space_size({
      kind = "list", elem_size = 3, max = 1,
    }))
  end)

  it("List(T, 3) over |T|=2 → (2+1)^3 = 27", function()
    assert.equals(27, types.state_space_size({
      kind = "list", elem_size = 2, max = 3,
    }))
  end)

  it("List(T, 4) over |T|=4 → (4+1)^4 = 625", function()
    assert.equals(625, types.state_space_size({
      kind = "list", elem_size = 4, max = 4,
    }))
  end)
end)

describe("types.state_space_size — record / variant", function()
  it("record uses product_size", function()
    assert.equals(42, types.state_space_size({
      kind = "record", product_size = 42,
    }))
  end)

  it("record with no product_size → 1", function()
    assert.equals(1, types.state_space_size({kind = "record"}))
  end)

  it("variant uses sum_size", function()
    assert.equals(7, types.state_space_size({
      kind = "variant", sum_size = 7,
    }))
  end)

  it("variant with no sum_size → 1", function()
    assert.equals(1, types.state_space_size({kind = "variant"}))
  end)
end)

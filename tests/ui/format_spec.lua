-- tests/ui/format_spec.lua
-- Display formatter unit tests (ui/format.lua).

local fmt = require("ui.format")

describe("ui.format.bool", function()
  it("yes/no by default", function()
    assert.equals("yes", fmt.bool(true))
    assert.equals("no",  fmt.bool(false))
  end)

  it("overridable via opts.bool_labels", function()
    assert.equals("Y", fmt.bool(true,  { bool_labels = { yes = "Y", no = "N" } }))
    assert.equals("N", fmt.bool(false, { bool_labels = { yes = "Y", no = "N" } }))
  end)
end)

describe("ui.format.int", function()
  it("bare integer when no bounds", function()
    assert.equals("7", fmt.int(7))
  end)

  it("'cur/max' when type has a max bound", function()
    assert.equals("7/10",  fmt.int(7,  { tag = "int", min = 0, max = 10 }))
    assert.equals("0/100", fmt.int(0,  { tag = "int", min = 0, max = 100 }))
  end)

  it("bare integer when type has only a min bound", function()
    assert.equals("5", fmt.int(5, { tag = "int", min = 0 }))
  end)
end)

describe("ui.format.float", function()
  it("uses %g (concise)", function()
    assert.equals("7.5", fmt.float(7.5))
    assert.equals("0",   fmt.float(0.0))
    assert.equals("3.14159", fmt.float(3.14159))
  end)
end)

describe("ui.format.value (dispatch on td.tag)", function()
  it("dispatches int through td", function()
    assert.equals("7/10", fmt.value(7,  { tag = "int", max = 10 }))
  end)

  it("dispatches bool through td", function()
    assert.equals("yes", fmt.value(true,  { tag = "bool" }))
    assert.equals("no",  fmt.value(false, { tag = "bool" }))
  end)

  it("dispatches symbol/enum through td (bare name)", function()
    assert.equals("red", fmt.value("red", { tag = "symbol" }))
    assert.equals("red", fmt.value("red", { tag = "enum", values = { "red", "blue" } }))
  end)

  it("renders lists with [ ]", function()
    assert.equals("[a, b, c]", fmt.value({"a","b","c"}, { tag = "list" }))
    assert.equals("(empty)",   fmt.value({},            { tag = "list" }))
  end)

  it("renders sets with ( )", function()
    assert.equals("(a, b)",  fmt.value({"a","b"}, { tag = "set" }))
    assert.equals("(empty)", fmt.value({},        { tag = "set" }))
  end)

  it("resolves named/alias chains against the schema", function()
    local schema = {
      types = {
        { name = "Color", kind = "enum", values = { "red", "blue" } },
        { name = "Hue",   kind = "alias", type_desc = { tag = "named", name = "Color" } },
      },
    }
    assert.equals("red", fmt.value("red", { tag = "named", name = "Hue" }, schema))
  end)

  it("falls back to type-of-value heuristics when td is nil", function()
    assert.equals("yes", fmt.value(true))
    assert.equals("hello", fmt.value("hello"))
    assert.equals("42", fmt.value(42))
  end)

  it("returns '-' for nil", function()
    assert.equals("-", fmt.value(nil))
    assert.equals("-", fmt.value(nil, { tag = "int", max = 10 }))
  end)
end)

describe("ui.format.path (schema lookup)", function()
  it("looks up a scalar state's type descriptor", function()
    local schema = {
      states = {
        { path = "player/hp", kind = "scalar",
          type_desc = { tag = "int", min = 0, max = 10 } },
      },
    }
    assert.equals("7/10", fmt.path(schema, "player/hp", 7))
  end)

  it("falls back to value heuristics when the path is not in schema", function()
    assert.equals("yes", fmt.path({ states = {} }, "missing/path", true))
  end)
end)

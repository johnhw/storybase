-- tests/ui/text_widget_spec.lua
--
-- Unit tests for the §M8 text widget. Covers template parsing
-- (including literal-brace escapes), `paths()` enumeration, `render()`
-- substitution with schema-driven type-descriptor lookup, and paint
-- (multi-line + clipping).

local screen_mod = require("cli.drivers.curses.screen")
local text_mod   = require("cli.drivers.curses.widgets.text")

local function fake_kernel(values)
  return {
    _v = values,
    get_state = function(self, path) return self._v[path] end,
  }
end

local function row_string(scr, y)
  local out = {}
  for x = 0, scr.cols - 1 do
    out[#out + 1] = (scr._cells[y][x] and scr._cells[y][x].ch) or " "
  end
  return table.concat(out)
end

describe("text widget: parsing", function()
  it("requires a template", function()
    assert.has_error(function() text_mod.new({}) end)
  end)

  it("a static template has no paths", function()
    local w = text_mod.new({ template = "hello" })
    assert.are.same({}, w:paths())
  end)

  it("collects placeholder paths in encounter order", function()
    local w = text_mod.new({
      template = "{a} and {b} and {a}",   -- duplicate stays single
    })
    assert.are.same({ "a", "b" }, w:paths())
  end)

  it("rejects unterminated '{'", function()
    assert.has_error(function() text_mod.new({ template = "x = {a" }) end)
  end)

  it("rejects empty placeholder", function()
    assert.has_error(function() text_mod.new({ template = "{}" }) end)
  end)

  it("treats {{ and }} as literal braces", function()
    local w = text_mod.new({ template = "{{a}} = {a}" })
    assert.are.same({ "a" }, w:paths())
    assert.equal("{a} = 5", w:render(fake_kernel({ a = 5 })))
  end)
end)

describe("text widget: render", function()
  it("substitutes a single placeholder", function()
    local w = text_mod.new({ template = "Gold: {player/gold}" })
    assert.equal("Gold: 7", w:render(fake_kernel({ ["player/gold"] = 7 })))
  end)

  it("substitutes multiple placeholders", function()
    local w = text_mod.new({ template = "{a}/{b}" })
    assert.equal("12/34", w:render(fake_kernel({ a = 12, b = 34 })))
  end)

  it("renders nil as '-' (via the formatter)", function()
    local w = text_mod.new({ template = "x={x}" })
    assert.equal("x=-", w:render(fake_kernel({})))
  end)

  it("uses the schema's type descriptor when present", function()
    local schema = {
      states = {
        { kind = "scalar", path = "p",
          type_desc = { tag = "int", min = 0, max = 10 } },
      },
    }
    local w = text_mod.new({ template = "{p}", schema = schema })
    assert.equal("7/10", w:render(fake_kernel({ p = 7 })))
  end)

  it("formats a bool via the formatter (yes/no)", function()
    local schema = {
      states = {
        { kind = "scalar", path = "open", type_desc = { tag = "bool" } },
      },
    }
    local w = text_mod.new({ template = "open: {open}", schema = schema })
    assert.equal("open: yes", w:render(fake_kernel({ open = true })))
  end)
end)

describe("text widget: paint", function()
  it("paints a static line into a one-row window", function()
    local scr = screen_mod.new(1, 20)
    local win = scr:add_window({ x = 0, y = 0, w = 20, h = 1 })
    local w   = text_mod.new({ template = "hello" })
    w:paint(scr, win, fake_kernel({}))
    assert.is_truthy(row_string(scr, 0):find("^hello"))
  end)

  it("substitutes placeholders into a paint", function()
    local scr = screen_mod.new(1, 20)
    local win = scr:add_window({ x = 0, y = 0, w = 20, h = 1 })
    local w   = text_mod.new({ template = "g={g}" })
    w:paint(scr, win, fake_kernel({ g = 99 }))
    assert.is_truthy(row_string(scr, 0):find("^g=99"))
  end)

  it("honours \\n newlines in the rendered string", function()
    local scr = screen_mod.new(3, 12)
    local win = scr:add_window({ x = 0, y = 0, w = 12, h = 3 })
    local w   = text_mod.new({ template = "line1\nline2\nline3" })
    w:paint(scr, win, fake_kernel({}))
    assert.is_truthy(row_string(scr, 0):find("^line1"))
    assert.is_truthy(row_string(scr, 1):find("^line2"))
    assert.is_truthy(row_string(scr, 2):find("^line3"))
  end)

  it("truncates long lines on the right edge", function()
    local scr = screen_mod.new(1, 5)
    local win = scr:add_window({ x = 0, y = 0, w = 5, h = 1 })
    local w   = text_mod.new({ template = "hello world" })
    w:paint(scr, win, fake_kernel({}))
    assert.equal("hello", row_string(scr, 0))
  end)

  it("is a no-op for a zero-width / zero-height window", function()
    local scr = screen_mod.new(2, 10)
    local w   = text_mod.new({ template = "x" })
    assert.has_no_errors(function()
      w:paint(scr, { x = 0, y = 0, w = 10, h = 0 }, fake_kernel({}))
    end)
    assert.has_no_errors(function()
      w:paint(scr, { x = 0, y = 0, w = 0,  h = 1 }, fake_kernel({}))
    end)
  end)
end)

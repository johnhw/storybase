-- tests/ui/stat_widget_spec.lua
--
-- Unit tests for the §M8 stat widget (cli/drivers/curses/widgets/stat.lua).
-- The widget is the most general read-only state display: it renders a
-- single state path as "Label: <value>", formatting the value through
-- `ui/format.lua` so bounded ints / bools / enums / sets all flow
-- through the shared formatter.

local screen_mod = require("cli.drivers.curses.screen")
local stat_mod   = require("cli.drivers.curses.widgets.stat")

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

describe("stat widget: construction", function()
  it("requires a path", function()
    assert.has_error(function() stat_mod.new({}) end)
  end)

  it("defaults the label to the path's tail segment", function()
    local w = stat_mod.new({ path = "player/hp" })
    assert.equal("hp", w.label)
  end)

  it("uses the path verbatim when there is no '/'", function()
    local w = stat_mod.new({ path = "gold" })
    assert.equal("gold", w.label)
  end)

  it("honours an explicit label", function()
    local w = stat_mod.new({ path = "player/hp", label = "Health" })
    assert.equal("Health", w.label)
  end)
end)

describe("stat widget: format", function()
  it("formats a bounded int as 'cur/max'", function()
    local w = stat_mod.new({
      path = "p", label = "HP",
      type_desc = { tag = "int", min = 0, max = 10 },
    })
    assert.equal("HP: 7/10", w:format(7))
  end)

  it("formats an unbounded int as the bare number", function()
    local w = stat_mod.new({
      path = "p", label = "Gold", type_desc = { tag = "int" },
    })
    assert.equal("Gold: 5", w:format(5))
  end)

  it("formats a bool as yes/no by default", function()
    local w = stat_mod.new({
      path = "p", label = "Open", type_desc = { tag = "bool" },
    })
    assert.equal("Open: yes", w:format(true))
    assert.equal("Open: no",  w:format(false))
  end)

  it("formats an enum as the symbol", function()
    local w = stat_mod.new({
      path = "p", label = "Mood",
      type_desc = { tag = "enum", values = { "happy", "sad" } },
    })
    assert.equal("Mood: happy", w:format("happy"))
  end)

  it("formats nil values as '-'", function()
    local w = stat_mod.new({ path = "p", label = "X" })
    assert.equal("X: -", w:format(nil))
  end)

  it("resolves a named alias through the schema", function()
    local schema = {
      types = {
        { name = "Mood", kind = "enum", values = { "happy", "sad" } },
      },
    }
    local w = stat_mod.new({
      path = "p", label = "Mood", schema = schema,
      type_desc = { tag = "named", name = "Mood" },
    })
    assert.equal("Mood: sad", w:format("sad"))
  end)
end)

describe("stat widget: paint", function()
  local function paint_into(width, value, td)
    local scr = screen_mod.new(1, width)
    local win = scr:add_window({ x = 0, y = 0, w = width, h = 1 })
    local k   = fake_kernel({ ["p"] = value })
    local w   = stat_mod.new({ path = "p", label = "X", type_desc = td })
    w:paint(scr, win, k)
    return row_string(scr, 0)
  end

  it("paints 'X: 7/10' for a bounded int", function()
    local row = paint_into(20, 7, { tag = "int", min = 0, max = 10 })
    assert.equal("X: 7/10             ", row)
  end)

  it("paints 'X: -' when the path has no value", function()
    local row = paint_into(10, nil)
    assert.is_truthy(row:find("^X: %-"))
  end)

  it("truncates a long value to fit the window", function()
    local scr = screen_mod.new(1, 6)
    local win = scr:add_window({ x = 0, y = 0, w = 6, h = 1 })
    local k   = fake_kernel({ ["p"] = "1234567890" })
    local w   = stat_mod.new({ path = "p", label = "X" })
    w:paint(scr, win, k)
    -- "X: 12345..." truncated to width 6 → "X: 123"
    local row = row_string(scr, 0)
    assert.equal(6, #row)
    assert.is_truthy(row:find("^X:"))
  end)

  it("erases the trailing region when a value shrinks", function()
    local scr = screen_mod.new(1, 20)
    local win = scr:add_window({ x = 0, y = 0, w = 20, h = 1 })
    local k   = fake_kernel({ ["p"] = "longvalue" })
    local w   = stat_mod.new({ path = "p", label = "X" })
    w:paint(scr, win, k)
    local long = row_string(scr, 0)
    k._v["p"] = "x"
    w:paint(scr, win, k)
    local short = row_string(scr, 0)
    assert.is_truthy(long:find("X: longvalue"))
    assert.is_truthy(short:find("^X: x"))
    assert.is_nil(short:find("longvalue"))
  end)

  it("is a no-op for a zero-height window", function()
    local scr = screen_mod.new(2, 10)
    local win = { x = 0, y = 0, w = 10, h = 0 }
    local k   = fake_kernel({ ["p"] = 1 })
    local w   = stat_mod.new({ path = "p" })
    assert.has_no_errors(function() w:paint(scr, win, k) end)
    assert.equal(string.rep(" ", 10), row_string(scr, 0))
  end)
end)

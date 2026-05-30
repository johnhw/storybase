-- tests/ui/statbar_widget_spec.lua
--
-- Unit tests for the §M5 stat-bar widget (cli/drivers/curses/widgets/statbar.lua).
-- The widget is tested in isolation against a fresh screen + a small
-- fake kernel — the driver-level wiring is covered in
-- tests/ui/integration/statbar_reactive_spec.lua.

local screen_mod  = require("cli.drivers.curses.screen")
local statbar_mod = require("cli.drivers.curses.widgets.statbar")

--- Cheap kernel stub: just a path → value table accessible via
--- `kernel:get_state(path)`.
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

describe("statbar widget: construction", function()
  it("requires a path", function()
    assert.has_error(function() statbar_mod.new({}) end)
  end)

  it("defaults the label to the path's tail segment", function()
    local w = statbar_mod.new({ path = "player/hp" })
    assert.equal("hp", w.label)
  end)

  it("uses the path verbatim when there is no '/'", function()
    local w = statbar_mod.new({ path = "gold" })
    assert.equal("gold", w.label)
  end)

  it("honours an explicit label", function()
    local w = statbar_mod.new({ path = "player/hp", label = "Health" })
    assert.equal("Health", w.label)
  end)
end)

describe("statbar widget: format_head", function()
  local td = { tag = "int", min = 0, max = 10 }

  it("renders 'Label: cur/max ' for a bounded int", function()
    local w = statbar_mod.new({ path = "player/hp", label = "HP", type_desc = td })
    assert.equal("HP: 7/10 ", w:format_head(7))
  end)

  it("renders the bare number for an unbounded int", function()
    local w = statbar_mod.new({
      path = "x", label = "X", type_desc = { tag = "int" },
    })
    assert.equal("X: 5 ", w:format_head(5))
  end)

  it("renders '-' when the path has no value", function()
    local w = statbar_mod.new({
      path = "x", label = "X", type_desc = td,
    })
    assert.equal("X: - ", w:format_head(nil))
  end)
end)

describe("statbar widget: paint", function()
  local td = { tag = "int", min = 0, max = 10 }

  local function paint_into(width, value)
    local scr = screen_mod.new(1, width)
    local win = scr:add_window({ x = 0, y = 0, w = width, h = 1 })
    local k = fake_kernel({ ["player/hp"] = value })
    local w = statbar_mod.new({
      path = "player/hp", label = "Health", type_desc = td,
    })
    w:paint(scr, win, k)
    return row_string(scr, 0)
  end

  it("renders 'Health: 7/10 [#######   ]' at a typical width", function()
    local row = paint_into(30, 7)
    assert.is_truthy(row:find("Health: 7/10 %["), row)
    local inside = row:match("%[(.-)%]")
    assert.is_truthy(inside, row)
    -- 70% of inner_w cells should be `#`. inner_w = 30 - len("Health: 7/10 ") - 2.
    local hashes = select(2, inside:gsub("#", ""))
    local spaces = select(2, inside:gsub(" ", ""))
    assert.is_true(hashes > 0, "expected some `#` glyphs: " .. row)
    assert.is_true(spaces > 0, "expected some ` ` glyphs: " .. row)
    assert.equal(hashes + spaces, #inside)
  end)

  it("renders a fully empty bar when value = 0", function()
    local row = paint_into(30, 0)
    local inside = row:match("%[(.-)%]")
    assert.is_truthy(inside)
    assert.is_nil(inside:find("#"))
  end)

  it("renders a fully filled bar when value = max", function()
    local row = paint_into(30, 10)
    local inside = row:match("%[(.-)%]")
    assert.is_truthy(inside)
    assert.is_nil(inside:find(" "))
  end)

  it("clamps values below min and above max", function()
    local row_under = paint_into(30, -5)
    local row_over  = paint_into(30, 999)
    -- clamped under → empty inside; clamped over → fully filled.
    assert.is_nil(row_under:match("%[(.-)%]"):find("#"))
    assert.is_nil(row_over :match("%[(.-)%]"):find(" "))
  end)

  it("erases the trailing region when a value shrinks", function()
    local scr = screen_mod.new(1, 30)
    local win = scr:add_window({ x = 0, y = 0, w = 30, h = 1 })
    local k = fake_kernel({ ["player/hp"] = 10 })
    local w = statbar_mod.new({
      path = "player/hp", label = "Health", type_desc = td,
    })
    w:paint(scr, win, k)
    local long = row_string(scr, 0)
    -- Shrink value, repaint. The row should be shorter overall (the
    -- "10/10" → "1/10" change leaves no leftover digit from the prior
    -- frame).
    k._v["player/hp"] = 1
    w:paint(scr, win, k)
    local short = row_string(scr, 0)
    assert.is_truthy(long:find("Health: 10/10"))
    assert.is_truthy(short:find("Health: 1/10"))
    assert.is_nil(short:find("Health: 10/10"))
  end)

  it("truncates the head fragment when the window is very narrow", function()
    local row = paint_into(8, 7)  -- < #("Health: 7/10 ") + 2
    -- We can't fit head + brackets — only head, truncated.
    assert.equal(8, #row)
    assert.is_truthy(row:find("^Health"))
    assert.is_nil(row:find("%["))
  end)

  it("does not paint anything for a zero-height window", function()
    local scr = screen_mod.new(2, 20)
    local win = { x = 0, y = 0, w = 20, h = 0 }
    local k = fake_kernel({ ["player/hp"] = 5 })
    local w = statbar_mod.new({
      path = "player/hp", label = "Health", type_desc = td,
    })
    assert.has_no_errors(function() w:paint(scr, win, k) end)
    -- Row 0 should still be all spaces (the window was zero-height).
    assert.equal(string.rep(" ", 20), row_string(scr, 0))
  end)
end)

describe("statbar widget: color attrs", function()
  it("passes color_good as the fg attr on filled cells", function()
    local td = { tag = "int", min = 0, max = 10 }
    local scr = screen_mod.new(1, 30)
    local win = scr:add_window({ x = 0, y = 0, w = 30, h = 1 })
    local k = fake_kernel({ ["player/hp"] = 5 })
    local w = statbar_mod.new({
      path = "player/hp", label = "Health", type_desc = td,
      color_good = "green", color_bad = "red",
    })
    w:paint(scr, win, k)
    -- Walk the bar cells; assert filled ones carry green, empty carry red.
    local saw_green, saw_red = false, false
    for x = 0, 29 do
      local c = scr._cells[0][x]
      if c.ch == "#" and c.fg == "green" then saw_green = true end
      if c.ch == " " and c.fg == "red"   then saw_red   = true end
    end
    assert.is_true(saw_green)
    assert.is_true(saw_red)
  end)
end)

-- tests/ui/toggle_widget_spec.lua
--
-- Unit tests for the §M8 toggle widget. Covers construction, paint
-- (display only), and the optional focus-handler activation path (SPACE
-- / Enter flips the value via fn_name -> kernel:call_fn or on_toggle).

local screen_mod = require("cli.drivers.curses.screen")
local toggle_mod = require("cli.drivers.curses.widgets.toggle")
local K          = require("cli.drivers.curses.keys")

local function fake_kernel(values, on_call_fn)
  return {
    _v = values,
    get_state = function(self, path) return self._v[path] end,
    call_fn   = function(self, name, ...) if on_call_fn then on_call_fn(name, ...) end end,
  }
end

local function row_string(scr, y)
  local out = {}
  for x = 0, scr.cols - 1 do
    out[#out + 1] = (scr._cells[y][x] and scr._cells[y][x].ch) or " "
  end
  return table.concat(out)
end

describe("toggle: construction", function()
  it("requires a path", function()
    assert.has_error(function() toggle_mod.new({}) end)
  end)

  it("defaults the label to the path's tail segment", function()
    local w = toggle_mod.new({ path = "player/visible" })
    assert.equal("visible", w.label)
  end)

  it("honours an explicit label", function()
    local w = toggle_mod.new({ path = "p", label = "Visible" })
    assert.equal("Visible", w.label)
  end)

  it("defaults glyphs to 'x' and ' '", function()
    local w = toggle_mod.new({ path = "p" })
    assert.equal("x", w.on_glyph)
    assert.equal(" ", w.off_glyph)
  end)

  it("accepts custom glyphs (first char only)", function()
    local w = toggle_mod.new({ path = "p", on_glyph = "Y", off_glyph = "N" })
    assert.equal("Y", w.on_glyph)
    assert.equal("N", w.off_glyph)
  end)
end)

describe("toggle: format", function()
  it("renders '[x] Label' when value is truthy", function()
    local w = toggle_mod.new({ path = "p", label = "Foo" })
    assert.equal("[x] Foo", w:format(true))
  end)

  it("renders '[ ] Label' when value is falsy", function()
    local w = toggle_mod.new({ path = "p", label = "Foo" })
    assert.equal("[ ] Foo", w:format(false))
    assert.equal("[ ] Foo", w:format(nil))
  end)
end)

describe("toggle: paint", function()
  local function paint_into(width, value)
    local scr = screen_mod.new(1, width)
    local win = scr:add_window({ x = 0, y = 0, w = width, h = 1 })
    local k   = fake_kernel({ ["p"] = value })
    local w   = toggle_mod.new({ path = "p", label = "Visible" })
    w:paint(scr, win, k)
    return row_string(scr, 0)
  end

  it("paints '[x] Visible' for true", function()
    local row = paint_into(15, true)
    assert.is_truthy(row:find("^%[x%] Visible"))
  end)

  it("paints '[ ] Visible' for false", function()
    local row = paint_into(15, false)
    assert.is_truthy(row:find("^%[ %] Visible"))
  end)

  it("paints '[ ] Visible' for nil", function()
    local row = paint_into(15, nil)
    assert.is_truthy(row:find("^%[ %] Visible"))
  end)

  it("truncates a long label", function()
    local scr = screen_mod.new(1, 5)
    local win = scr:add_window({ x = 0, y = 0, w = 5, h = 1 })
    local k   = fake_kernel({ ["p"] = true })
    local w   = toggle_mod.new({ path = "p", label = "LongLabelHere" })
    w:paint(scr, win, k)
    assert.equal(5, #row_string(scr, 0))
  end)
end)

describe("toggle: activate", function()
  it("flips the kernel value through fn_name when set", function()
    local seen = {}
    local k = fake_kernel({ ["p"] = false },
      function(name, value) seen.name = name; seen.value = value end)
    local driver = { _kernel = k }
    local w = toggle_mod.new({ path = "p", fn_name = "set-p" })
    local new = w:activate(driver)
    assert.is_true(new)
    assert.equal("set-p", seen.name)
    assert.is_true(seen.value)
  end)

  it("calls on_toggle with the new value", function()
    local got
    local k = fake_kernel({ ["p"] = true })
    local driver = { _kernel = k }
    local w = toggle_mod.new({
      path = "p",
      on_toggle = function(_, v) got = v end,
    })
    w:activate(driver)
    assert.is_false(got)
  end)

  it("invokes both fn_name and on_toggle when set", function()
    local seen = { fn_called = false, on_toggle_called = false }
    local k = fake_kernel({ ["p"] = false },
      function() seen.fn_called = true end)
    local driver = { _kernel = k }
    local w = toggle_mod.new({
      path = "p", fn_name = "set-p",
      on_toggle = function() seen.on_toggle_called = true end,
    })
    w:activate(driver)
    assert.is_true(seen.fn_called)
    assert.is_true(seen.on_toggle_called)
  end)
end)

describe("toggle: focus on_key", function()
  it("SPACE activates", function()
    local seen
    local k = fake_kernel({ ["p"] = false })
    local driver = { _kernel = k }
    local w = toggle_mod.new({
      path = "p", on_toggle = function(_, v) seen = v end,
    })
    assert.is_true(w:on_key(K.SPACE, driver))
    assert.is_true(seen)
  end)

  it("Enter activates (CR / LF / KEY_ENTER all)", function()
    for _, key in ipairs({ K.CR, K.LF, K.KEY_ENTER }) do
      local seen
      local driver = { _kernel = fake_kernel({ ["p"] = false }) }
      local w = toggle_mod.new({
        path = "p", on_toggle = function(_, v) seen = v end,
      })
      assert.is_true(w:on_key(key, driver))
      assert.is_true(seen)
    end
  end)

  it("ignores unrelated keys (returns false, no callback fires)", function()
    local fired = false
    local driver = { _kernel = fake_kernel({ ["p"] = false }) }
    local w = toggle_mod.new({
      path = "p", on_toggle = function() fired = true end,
    })
    assert.is_false(w:on_key(string.byte("a"), driver))
    assert.is_false(fired)
  end)
end)

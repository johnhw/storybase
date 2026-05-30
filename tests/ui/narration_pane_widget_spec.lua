-- tests/ui/narration_pane_widget_spec.lua
--
-- Unit tests for the §M8 scrollable narration pane widget
-- (cli/drivers/curses/widgets/narration.lua). Covers buffer mutation
-- (append / extend / clear / max_lines trim), scroll math (stick to
-- bottom by default; pinning when the user pages up), paint (border /
-- title / scroll offset / clipping), and the focus on_key surface.

local screen_mod   = require("cli.drivers.curses.screen")
local narration_mod = require("cli.drivers.curses.widgets.narration")
local K             = require("cli.drivers.curses.keys")

local function row_string(scr, y)
  local out = {}
  for x = 0, scr.cols - 1 do
    out[#out + 1] = (scr._cells[y][x] and scr._cells[y][x].ch) or " "
  end
  return table.concat(out)
end

describe("narration pane: buffer", function()
  it("starts with an empty buffer", function()
    local w = narration_mod.new({})
    assert.equal(0, w:size())
  end)

  it("seeds the buffer from opts.lines", function()
    local w = narration_mod.new({ lines = { "a", "b" } })
    assert.equal(2, w:size())
    assert.are.same({ "a", "b" }, w:lines())
  end)

  it("append / extend / clear behave as expected", function()
    local w = narration_mod.new({})
    w:append("a")
    w:append("b")
    w:extend({ "c", "d" })
    assert.are.same({ "a", "b", "c", "d" }, w:lines())
    w:clear()
    assert.equal(0, w:size())
  end)

  it("max_lines trims the front of the buffer", function()
    local w = narration_mod.new({ max_lines = 3 })
    w:extend({ "a", "b", "c", "d", "e" })
    assert.are.same({ "c", "d", "e" }, w:lines())
  end)
end)

describe("narration pane: paint", function()
  it("paints the tail of the buffer when shorter than the window", function()
    local w = narration_mod.new({ lines = { "one", "two" } })
    local scr = screen_mod.new(4, 10)
    local win = scr:add_window({ x = 0, y = 0, w = 10, h = 4 })
    w:paint(scr, win)
    -- stick_to_bottom: scroll computed so the tail is at the bottom
    -- only when #lines > body_h. Two lines fit in 4 rows → starts at row 0.
    assert.is_truthy(row_string(scr, 0):find("^one"))
    assert.is_truthy(row_string(scr, 1):find("^two"))
  end)

  it("scrolls to keep the bottom in view when buffer exceeds body_h",
  function()
    local w = narration_mod.new({ lines = { "a", "b", "c", "d", "e" } })
    local scr = screen_mod.new(3, 10)
    local win = scr:add_window({ x = 0, y = 0, w = 10, h = 3 })
    w:paint(scr, win)
    -- Three rows of body, 5 lines → tail = c, d, e.
    assert.is_truthy(row_string(scr, 0):find("^c"))
    assert.is_truthy(row_string(scr, 1):find("^d"))
    assert.is_truthy(row_string(scr, 2):find("^e"))
  end)

  it("draws a border when opts.border is true", function()
    local w = narration_mod.new({
      lines = { "x" }, border = true, title = "Log",
    })
    local scr = screen_mod.new(4, 10)
    local win = scr:add_window({ x = 0, y = 0, w = 10, h = 4 })
    w:paint(scr, win)
    -- corners + title.
    assert.equal("+", scr._cells[0][0].ch)
    assert.equal("+", scr._cells[0][9].ch)
    assert.equal("+", scr._cells[3][0].ch)
    assert.equal("+", scr._cells[3][9].ch)
    assert.is_truthy(row_string(scr, 0):find(" Log "))
  end)

  it("clips long lines to inner_w", function()
    local w = narration_mod.new({ lines = { "0123456789ABC" } })
    local scr = screen_mod.new(2, 5)
    local win = scr:add_window({ x = 0, y = 0, w = 5, h = 2 })
    w:paint(scr, win)
    assert.equal("01234", row_string(scr, 0))
  end)
end)

describe("narration pane: scroll", function()
  it("scroll(-1) pins the view (disables stick_to_bottom)", function()
    local w = narration_mod.new({ lines = { "a", "b", "c", "d", "e" } })
    local scr = screen_mod.new(2, 10)
    local win = scr:add_window({ x = 0, y = 0, w = 10, h = 2 })
    w:paint(scr, win)
    -- stick_to_bottom: scroll = 3 (#lines - body_h = 5 - 2).
    w:scroll(-1)
    assert.is_false(w.stick_to_bottom)
    assert.equal(2, w._scroll)
    -- Paint reflects the pinned position.
    w:paint(scr, win)
    assert.is_truthy(row_string(scr, 0):find("^c"))
    assert.is_truthy(row_string(scr, 1):find("^d"))
  end)

  it("scroll back to bottom re-enables stick_to_bottom", function()
    local w = narration_mod.new({ lines = { "a", "b", "c", "d" } })
    local scr = screen_mod.new(2, 10)
    local win = scr:add_window({ x = 0, y = 0, w = 10, h = 2 })
    w:paint(scr, win)
    w:scroll(-1)
    assert.is_false(w.stick_to_bottom)
    w:scroll(1)
    assert.is_true(w.stick_to_bottom)
  end)

  it("scroll_to(false / true) jumps to ends", function()
    local w = narration_mod.new({ lines = { "a", "b", "c", "d", "e" } })
    local scr = screen_mod.new(2, 10)
    w:paint(scr, scr:add_window({ x = 0, y = 0, w = 10, h = 2 }))
    w:scroll_to(false)
    assert.equal(0, w._scroll)
    assert.is_false(w.stick_to_bottom)
    w:scroll_to(true)
    assert.is_true(w.stick_to_bottom)
  end)
end)

describe("narration pane: on_key", function()
  it("Up/Down scroll by one line", function()
    local w = narration_mod.new({ lines = { "a", "b", "c", "d", "e" } })
    local scr = screen_mod.new(2, 10)
    w:paint(scr, scr:add_window({ x = 0, y = 0, w = 10, h = 2 }))
    assert.is_true(w:on_key(K.KEY_UP))
    assert.equal(2, w._scroll)
    assert.is_true(w:on_key(K.KEY_DOWN))
    assert.equal(3, w._scroll)
  end)

  it("PgUp/PgDn scroll by body_h", function()
    local w = narration_mod.new({ lines = { "a","b","c","d","e","f","g" } })
    local scr = screen_mod.new(3, 10)
    w:paint(scr, scr:add_window({ x = 0, y = 0, w = 10, h = 3 }))
    -- body_h = 3, max_scroll = 4, current = 4 (stick_to_bottom).
    assert.is_true(w:on_key(K.KEY_PPAGE))
    assert.equal(1, w._scroll)
  end)

  it("Home / End jump to extremes", function()
    local w = narration_mod.new({ lines = { "a", "b", "c" } })
    local scr = screen_mod.new(2, 10)
    w:paint(scr, scr:add_window({ x = 0, y = 0, w = 10, h = 2 }))
    w:on_key(K.KEY_HOME)
    assert.equal(0, w._scroll)
    w:on_key(K.KEY_END)
    assert.is_true(w.stick_to_bottom)
  end)

  it("returns false on unrelated keys", function()
    local w = narration_mod.new({})
    assert.is_false(w:on_key(string.byte("z")))
  end)
end)

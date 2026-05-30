-- tests/ui/dialog_widget_spec.lua
--
-- Tests for §M6 modal dialog widget
-- (cli/drivers/curses/widgets/dialog.lua). The dialog is both a view
-- (it gets painted into the screen) and a focus handler (it owns key
-- dispatch while it's on the focus stack). These specs exercise each
-- surface in isolation against the buffer screen model — no real
-- ncurses involved.

local screen_mod = require("cli.drivers.curses.screen")
local dialog_mod = require("cli.drivers.curses.widgets.dialog")

--- Helper: take the as_lines() snapshot and return it without trailing
--- whitespace so assertions read more like a picture.
local function dump(screen)
  local lines = screen:as_lines()
  local out = {}
  for i, l in ipairs(lines) do out[i] = (l:gsub("%s+$", "")) end
  return out
end

--- Find the y row index (0-based) and column offset where `needle`
--- first appears in the snapshot. Returns nil when absent.
local function find(screen, needle)
  local lines = screen:as_lines()
  for i, line in ipairs(lines) do
    local s = line:find(needle, 1, true)
    if s then return i - 1, s - 1 end
  end
  return nil
end

describe("dialog: construction", function()
  it("requires a body string", function()
    assert.has_error(function() dialog_mod.new({ body = 123 }) end)
  end)

  it("buttons defaults to empty list", function()
    local d = dialog_mod.new({ body = "x" })
    assert.same({}, d.buttons)
  end)

  it("z defaults to 100 (over the base game view's z=0)", function()
    local d = dialog_mod.new({ body = "x" })
    assert.equal(100, d.z)
  end)

  it("z is overridable", function()
    assert.equal(7, dialog_mod.new({ body = "x", z = 7 }).z)
  end)
end)

describe("dialog: paint", function()
  it("draws a bordered box centred on the screen", function()
    local s = screen_mod.new(10, 30)
    local d = dialog_mod.new({
      title   = "Quit?",
      body    = "Really quit?",
      buttons = {{ key = "y", label = "Yes" }, { key = "n", label = "No" }},
    })
    d:paint(s)
    local row, col = find(s, "Quit?")
    assert.is_not_nil(row, "title 'Quit?' should be painted")
    -- Centred-ish: dialog top edge should be neither at 0 nor at the bottom.
    assert.is_true(row > 0 and row < 9, "dialog top should be inside the screen")
    assert.is_true(col > 0)
    -- The body and buttons should appear too.
    assert.is_not_nil(find(s, "Really quit?"))
    assert.is_not_nil(find(s, "[Yes]"))
    assert.is_not_nil(find(s, "[No]"))
  end)

  it("renders title, body, and buttons in expected vertical order", function()
    local s = screen_mod.new(10, 30)
    dialog_mod.new({
      title = "Quit?",
      body  = "Really quit?",
      buttons = {{ key = "y", label = "Yes" }, { key = "n", label = "No" }},
    }):paint(s)
    local ry_title = find(s, "Quit?")
    local ry_body  = find(s, "Really quit?")
    local ry_btn   = find(s, "[Yes]")
    assert.is_true(ry_title < ry_body)
    assert.is_true(ry_body  < ry_btn)
  end)

  it("renders a body-only dialog (no buttons) cleanly", function()
    local s = screen_mod.new(8, 20)
    dialog_mod.new({ body = "Hello" }):paint(s)
    assert.is_not_nil(find(s, "Hello"))
    -- No button row → no '[' chars.
    for _, line in ipairs(dump(s)) do
      assert.is_nil(line:find("[", 1, true))
    end
  end)

  it("wraps multi-line bodies on '\\n'", function()
    local s = screen_mod.new(10, 30)
    dialog_mod.new({ body = "Line one\nLine two" }):paint(s)
    local r1 = find(s, "Line one")
    local r2 = find(s, "Line two")
    assert.is_not_nil(r1)
    assert.is_not_nil(r2)
    assert.equal(r1 + 1, r2)
  end)

  it("clips a too-wide body to the dialog's inner width", function()
    local s = screen_mod.new(10, 20)
    -- max_w=10 means inner=10, dialog total width = 12.
    dialog_mod.new({ body = "A really long body line", max_w = 10 }):paint(s)
    -- The full body string must not appear unclipped anywhere.
    assert.is_nil(find(s, "A really long body line"))
  end)

  it("draws a closed box on top + bottom and side rails", function()
    local s = screen_mod.new(10, 30)
    dialog_mod.new({ body = "x" }):paint(s)
    -- Find the dialog's top-left corner '+'.
    local row, col = find(s, "+")
    assert.is_not_nil(row)
    assert.is_not_nil(col)
    -- The same row should contain another '+' (top-right corner).
    local _, top_right = s:as_lines()[row + 1]:find("+", col + 2, true)
    assert.is_not_nil(top_right, "top-right corner missing")
    -- The corresponding bottom row should also start with a '+'.
    local bot_line = s:as_lines()[row + 1 + 2]
    assert.is_not_nil(bot_line and bot_line:sub(col + 1, col + 1) == "+",
      "bottom-left corner missing")
  end)
end)

describe("dialog: on_key", function()
  it("returns false for keys that don't match a button or cancel", function()
    local d = dialog_mod.new({
      body = "x",
      buttons = {{ key = "y", label = "Yes" }, { key = "n", label = "No" }},
    })
    assert.is_false(d:on_key(string.byte("a")))
  end)

  it("fires button.action + on_select when a button key matches", function()
    local fired_action = nil
    local fired_select = nil
    local d = dialog_mod.new({
      body = "x",
      buttons = {
        { key = "y", label = "Yes",
          action = function(drv) fired_action = "y:" .. tostring(drv) end },
        { key = "n", label = "No",
          action = function(drv) fired_action = "n:" .. tostring(drv) end },
      },
      on_select = function(self, btn, drv) fired_select = btn.label end,
    })
    assert.is_true(d:on_key(string.byte("y"), "drv"))
    assert.equal("y:drv", fired_action)
    assert.equal("Yes", fired_select)
  end)

  it("matches a button key case-insensitively", function()
    local hit = nil
    local d = dialog_mod.new({
      body = "x",
      buttons = {{ key = "y", label = "Yes",
                   action = function() hit = "yes" end }},
    })
    assert.is_true(d:on_key(string.byte("Y")))
    assert.equal("yes", hit)
  end)

  it("fires on_cancel for ESC", function()
    local fired = nil
    local d = dialog_mod.new({
      body = "x",
      buttons = {{ key = "y", label = "Yes" }},
      on_cancel = function(self, drv) fired = "esc:" .. tostring(drv) end,
    })
    assert.is_true(d:on_key(27, "drv"))
    assert.equal("esc:drv", fired)
  end)

  it("fires on_cancel for q/Q even when a button is bound to other keys", function()
    local count = 0
    local d = dialog_mod.new({
      body = "x",
      buttons = {{ key = "n", label = "No" }},
      on_cancel = function() count = count + 1 end,
    })
    assert.is_true(d:on_key(string.byte("q")))
    assert.is_true(d:on_key(string.byte("Q")))
    assert.equal(2, count)
  end)

  it("returns true for ESC even without an on_cancel handler", function()
    -- ESC must always be consumed by a modal — otherwise it falls through
    -- to the driver's base quit handling, which would close the game.
    local d = dialog_mod.new({ body = "x" })
    assert.is_true(d:on_key(27))
  end)

  it("rejects non-numeric keys (defensive)", function()
    local d = dialog_mod.new({ body = "x",
      buttons = {{ key = "y", label = "Yes" }} })
    assert.is_false(d:on_key("y"))
    assert.is_false(d:on_key(nil))
  end)
end)

describe("dialog: zero-button degenerate case", function()
  it("paints with no button row, on_key only handles ESC/q", function()
    local s = screen_mod.new(8, 20)
    local d = dialog_mod.new({ body = "info" })
    assert.has_no.errors(function() d:paint(s) end)
    assert.is_not_nil(find(s, "info"))
    assert.is_true(d:on_key(27))
  end)
end)

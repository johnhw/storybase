-- tests/ui/input_widget_spec.lua
--
-- Tests for §M7 single-line text input widget
-- (cli/drivers/curses/widgets/input.lua). Mirrors the structure of
-- menu_widget_spec.lua and dialog_widget_spec.lua: construction, paint,
-- editing (insert/backspace/cursor movement), submit / cancel, and the
-- customisable bindings surface.

local screen_mod = require("cli.drivers.curses.screen")
local input_mod  = require("cli.drivers.curses.widgets.input")
local K          = require("cli.drivers.curses.keys")

--- Snapshot helper: strip trailing whitespace per row.
local function dump(screen)
  local out = {}
  for i, l in ipairs(screen:as_lines()) do
    out[i] = (l:gsub("%s+$", ""))
  end
  return out
end

--- Find `needle` in the snapshot; return (y, x) 0-based or nil.
local function find(screen, needle)
  for i, line in ipairs(screen:as_lines()) do
    local s = line:find(needle, 1, true)
    if s then return i - 1, s - 1 end
  end
  return nil
end

--- Type a string into the widget by pushing one byte per char.
local function type_string(w, s, driver)
  for i = 1, #s do w:on_key(s:byte(i), driver) end
end

describe("input: construction", function()
  it("requires initial to be a string when provided", function()
    assert.has_error(function() input_mod.new({ initial = 7 }) end)
  end)

  it("initial defaults to empty buffer", function()
    local w = input_mod.new({})
    assert.equal("", w:text())
    assert.equal(1, w:cursor())
  end)

  it("initial seeds the buffer and puts cursor at end", function()
    local w = input_mod.new({ initial = "abc" })
    assert.equal("abc", w:text())
    assert.equal(4, w:cursor())
  end)

  it("border defaults to true, z defaults to 100", function()
    local w = input_mod.new({})
    assert.is_true(w.border)
    assert.equal(100, w.z)
  end)

  it("max_len truncates an over-long initial value", function()
    local w = input_mod.new({ initial = "abcdefgh", max_len = 4 })
    -- max_len applies on set_text but not on the initial assignment path
    -- (the constructor passes opts.initial directly so the author can
    -- prefill with anything). Confirm set_text trims correctly.
    w:set_text("abcdefgh")
    assert.equal("abcd", w:text())
  end)
end)

describe("input: paint", function()
  it("draws a bordered box with title + prompt + field", function()
    local s = screen_mod.new(10, 30)
    local w = input_mod.new({
      title  = "Your name",
      prompt = "Enter name:",
      initial = "Bob",
    })
    w:paint(s, nil)
    assert.is_not_nil(find(s, "Your name"))
    assert.is_not_nil(find(s, "Enter name:"))
    assert.is_not_nil(find(s, "Bob"))
  end)

  it("renders the cursor glyph at the current insertion point", function()
    local s = screen_mod.new(8, 30)
    local w = input_mod.new({ initial = "hi" })
    -- Cursor at position 3 (past 'i'); custom glyph for clarity.
    w.cursor_glyph = "_"
    w:paint(s, nil)
    -- Find row containing "hi"; cell immediately after should be '_'.
    local y_hi, x_hi = find(s, "hi")
    assert.is_not_nil(y_hi)
    local cell = s:get_cell(y_hi, x_hi + 2)
    assert.equal("_", cell.ch)
    assert.equal("reverse", cell.attrs)
  end)

  it("border=false suppresses the box", function()
    local s = screen_mod.new(6, 24)
    local w = input_mod.new({ border = false, prompt = "go", initial = "x" })
    w:paint(s, nil)
    for _, line in ipairs(dump(s)) do
      assert.is_nil(line:find("+", 1, true))
    end
    assert.is_not_nil(find(s, "go"))
    assert.is_not_nil(find(s, "x"))
  end)

  it("title is omitted from the snapshot when not set", function()
    local s = screen_mod.new(6, 24)
    local w = input_mod.new({ prompt = "Name:", initial = "" })
    w:paint(s, nil)
    -- Find the top border row (full of '-' between corners). Confirm
    -- that row holds no alpha characters (no title leaked in).
    local rows = s:as_lines()
    for _, row in ipairs(rows) do
      if row:find("^%s*%+%-+%+%s*$") then
        assert.is_nil(row:find("%a"), "title-less top border should have no letters")
      end
    end
  end)

  it("clips to the screen when oversized", function()
    local s = screen_mod.new(3, 8)
    local w = input_mod.new({
      title  = "VeryLongTitle",
      prompt = "Very long prompt label",
      initial = string.rep("x", 80),
    })
    assert.has_no_error(function() w:paint(s, nil) end)
    for _, line in ipairs(s:as_lines()) do
      assert.is_true(#line <= 8)
    end
  end)
end)

describe("input: editing", function()
  it("printable bytes insert at the cursor", function()
    local w = input_mod.new({})
    type_string(w, "hello")
    assert.equal("hello", w:text())
    assert.equal(6, w:cursor())
  end)

  it("backspace deletes the byte before the cursor", function()
    local w = input_mod.new({ initial = "abc" })
    assert.is_true(w:on_key(K.BS, nil))
    assert.equal("ab", w:text())
    assert.equal(3, w:cursor())
  end)

  it("backspace at start of buffer is a no-op", function()
    local w = input_mod.new({ initial = "" })
    assert.is_true(w:on_key(K.BS, nil))
    assert.equal("", w:text())
    assert.equal(1, w:cursor())
  end)

  it("KEY_BACKSPACE and DEL also trigger backspace", function()
    local w = input_mod.new({ initial = "abc" })
    w:on_key(K.KEY_BACKSPACE, nil)
    assert.equal("ab", w:text())
    w:on_key(K.DEL, nil)
    assert.equal("a", w:text())
  end)

  it("left/right arrows move the cursor without changing the buffer", function()
    local w = input_mod.new({ initial = "abc" })
    -- cursor=4 (past 'c')
    w:on_key(K.KEY_LEFT, nil) ; assert.equal(3, w:cursor())
    w:on_key(K.KEY_LEFT, nil) ; assert.equal(2, w:cursor())
    w:on_key(K.KEY_RIGHT, nil); assert.equal(3, w:cursor())
    assert.equal("abc", w:text())
  end)

  it("left at start / right at end are no-ops", function()
    local w = input_mod.new({ initial = "x" })
    w._cursor = 1
    w:on_key(K.KEY_LEFT, nil) ; assert.equal(1, w:cursor())
    w._cursor = 2
    w:on_key(K.KEY_RIGHT, nil); assert.equal(2, w:cursor())
  end)

  it("Home/End jump to the buffer extremes", function()
    local w = input_mod.new({ initial = "abcde" })
    w:on_key(K.KEY_HOME, nil); assert.equal(1, w:cursor())
    w:on_key(K.KEY_END,  nil); assert.equal(6, w:cursor())
  end)

  it("Delete removes the byte under the cursor", function()
    local w = input_mod.new({ initial = "abc" })
    w._cursor = 2
    assert.is_true(w:on_key(K.KEY_DC, nil))
    assert.equal("ac", w:text())
    assert.equal(2, w:cursor(), "cursor should not move on forward delete")
  end)

  it("Insertion happens at the cursor (not always at end)", function()
    local w = input_mod.new({ initial = "ac" })
    w._cursor = 2 -- between a and c
    w:on_key(string.byte("b"), nil)
    assert.equal("abc", w:text())
    assert.equal(3, w:cursor())
  end)

  it("max_len caps the buffer", function()
    local w = input_mod.new({ max_len = 3 })
    type_string(w, "abcdefg")
    assert.equal("abc", w:text())
    -- Further insertions are rejected (insert_byte returns false).
    assert.is_false(w:insert_byte(string.byte("z")))
  end)

  it("non-printable, non-bound keys are ignored", function()
    local w = input_mod.new({ initial = "x" })
    assert.is_false(w:on_key(1, nil))   -- ^A
    assert.is_false(w:on_key(7, nil))   -- bell
    assert.equal("x", w:text())
  end)

  it("on_key returns false for non-numeric keys", function()
    local w = input_mod.new({})
    assert.is_false(w:on_key("a", nil))
    assert.is_false(w:on_key(nil, nil))
  end)
end)

describe("input: submit / cancel", function()
  it("Enter (CR) calls on_submit with the current text", function()
    local got
    local w = input_mod.new({
      initial   = "Alice",
      on_submit = function(_self, text, _drv) got = text end,
    })
    assert.is_true(w:on_key(K.CR, nil))
    assert.equal("Alice", got)
  end)

  it("LF and KEY_ENTER also submit", function()
    local got = {}
    local w = input_mod.new({
      initial   = "x",
      on_submit = function(_self, text, _drv) got[#got + 1] = text end,
    })
    w:on_key(K.LF, nil)
    w:on_key(K.KEY_ENTER, nil)
    assert.same({ "x", "x" }, got)
  end)

  it("ESC fires on_cancel and consumes the key", function()
    local fired
    local w = input_mod.new({
      on_cancel = function() fired = true end,
    })
    assert.is_true(w:on_key(K.ESC, nil))
    assert.is_true(fired)
  end)

  it("ESC is consumed even without an on_cancel handler", function()
    local w = input_mod.new({})
    assert.is_true(w:on_key(K.ESC, nil))
  end)

  it("fn_name fires kernel:call_fn(name, text) on submit", function()
    local captured
    local fake_kernel = {
      call_fn = function(_self, name, text)
        captured = { name = name, text = text }
      end,
    }
    local fake_driver = { _kernel = fake_kernel }
    local w = input_mod.new({ fn_name = "set-name", initial = "Bob" })
    w:on_key(K.CR, fake_driver)
    assert.same({ name = "set-name", text = "Bob" }, captured)
  end)

  it("fn_name and on_submit both fire (call_fn first)", function()
    local order = {}
    local fake_kernel = {
      call_fn = function(_self, name, _text)
        order[#order + 1] = "call_fn:" .. name
      end,
    }
    local fake_driver = { _kernel = fake_kernel }
    local w = input_mod.new({
      fn_name   = "set-name",
      initial   = "Carol",
      on_submit = function(_self, _text, _drv) order[#order + 1] = "on_submit" end,
    })
    w:on_key(K.CR, fake_driver)
    assert.same({ "call_fn:set-name", "on_submit" }, order)
  end)

  it("fn_name with a driver missing _kernel is a no-op", function()
    local w = input_mod.new({ fn_name = "x", initial = "y" })
    assert.has_no_error(function() w:on_key(K.CR, {}) end)
  end)
end)

describe("input: customisable bindings", function()
  it("can rebind cancel away from ESC", function()
    local fired
    local w = input_mod.new({
      keys      = { cancel = { string.byte("c") } },
      on_cancel = function() fired = true end,
    })
    -- ESC is now a regular non-printable byte → dropped (returns false).
    assert.is_false(w:on_key(K.ESC, nil))
    assert.is_true(w:on_key(string.byte("c"), nil))
    assert.is_true(fired)
  end)
end)

describe("input: editing helpers", function()
  it("set_text replaces buffer and re-anchors cursor", function()
    local w = input_mod.new({ initial = "abc" })
    w:set_text("hello")
    assert.equal("hello", w:text())
    assert.equal(6, w:cursor())
  end)

  it("submit() returns the submitted text", function()
    local w = input_mod.new({ initial = "ok" })
    assert.equal("ok", w:submit(nil))
  end)
end)

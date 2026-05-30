-- tests/ui/choice_widget_spec.lua
--
-- Unit tests for the §M8 choice (radio-group) widget. Covers
-- construction (including enum resolution from the schema), paint
-- (selected glyph mirrors kernel state; cursor highlight independent),
-- activate (fn_name → kernel:call_fn / on_select), and focus on_key.

local screen_mod = require("cli.drivers.curses.screen")
local choice_mod = require("cli.drivers.curses.widgets.choice")
local K          = require("cli.drivers.curses.keys")

local function fake_kernel(values, on_call_fn)
  return {
    _v = values,
    get_state = function(self, path) return self._v[path] end,
    call_fn   = function(_, name, ...) if on_call_fn then on_call_fn(name, ...) end end,
  }
end

local function row_string(scr, y)
  local out = {}
  for x = 0, scr.cols - 1 do
    out[#out + 1] = (scr._cells[y][x] and scr._cells[y][x].ch) or " "
  end
  return table.concat(out)
end

describe("choice: construction", function()
  it("requires a path", function()
    assert.has_error(function() choice_mod.new({ values = { "a" } }) end)
  end)

  it("requires values (or a schema that resolves them)", function()
    assert.has_error(function() choice_mod.new({ path = "p" }) end)
  end)

  it("accepts an explicit values list", function()
    local w = choice_mod.new({ path = "p", values = { "a", "b", "c" } })
    assert.are.same({ "a", "b", "c" }, w.values)
  end)

  it("resolves enum values from the schema (inline enum)", function()
    local schema = {
      states = {
        { kind = "scalar", path = "p",
          type_desc = { tag = "enum", values = { "happy", "sad" } } },
      },
      types  = {},
    }
    local w = choice_mod.new({ path = "p", schema = schema })
    assert.are.same({ "happy", "sad" }, w.values)
  end)

  it("resolves enum values through a named alias chain", function()
    local schema = {
      states = {
        { kind = "scalar", path = "p",
          type_desc = { tag = "named", name = "MyMood" } },
      },
      types  = {
        { name = "MyMood", kind = "alias",
          type_desc = { tag = "named", name = "Mood" } },
        { name = "Mood", kind = "enum", values = { "ok", "bad" } },
      },
    }
    local w = choice_mod.new({ path = "p", schema = schema })
    assert.are.same({ "ok", "bad" }, w.values)
  end)
end)

describe("choice: paint", function()
  local function paint_with(value, cursor)
    local scr = screen_mod.new(4, 20)
    local win = scr:add_window({ x = 0, y = 0, w = 20, h = 4 })
    local k   = fake_kernel({ p = value })
    local w   = choice_mod.new({
      path = "p", values = { "a", "b", "c" }, label = "Pick",
    })
    if cursor then w._cursor = cursor; w._cursor_seeded = true end
    w:paint(scr, win, k)
    return scr, w
  end

  it("paints the label as the header row", function()
    local scr = paint_with("a")
    assert.is_truthy(row_string(scr, 0):find("^Pick"))
  end)

  it("marks the selected value with the on_glyph", function()
    local scr = paint_with("b")
    -- Row 0 = label; rows 1..3 = options.
    assert.is_truthy(row_string(scr, 1):find("^%( %) a"))
    assert.is_truthy(row_string(scr, 2):find("^%(%*%) b"))
    assert.is_truthy(row_string(scr, 3):find("^%( %) c"))
  end)

  it("renders all-off when value is nil", function()
    local scr = paint_with(nil)
    for y = 1, 3 do
      assert.is_truthy(row_string(scr, y):find("^%( %) "))
    end
  end)

  it("highlights the cursor row independently of the selection", function()
    local _, _ = paint_with("a", 3)
    local scr, _ = paint_with("a", 3)
    -- Cursor at row 3 (option 3 = "c") gets reverse attrs.
    local cell = scr._cells[3][0]
    assert.equal("reverse", cell.attrs)
    -- Selected row 1 ("a") is not highlighted (no reverse).
    assert.is_nil(scr._cells[1][0].attrs)
  end)
end)

describe("choice: activate", function()
  it("dispatches fn_name via kernel:call_fn with the chosen value", function()
    local seen
    local k = fake_kernel({ p = "a" },
      function(name, v) seen = { name = name, v = v } end)
    local w = choice_mod.new({
      path = "p", values = { "a", "b", "c" }, fn_name = "set-p",
    })
    -- Move cursor to 'b' and activate.
    w._cursor, w._cursor_seeded = 2, true
    local v = w:activate({ _kernel = k })
    assert.equal("b", v)
    assert.are.same({ name = "set-p", v = "b" }, seen)
  end)

  it("calls on_select with the chosen value", function()
    local got
    local k = fake_kernel({ p = "a" })
    local w = choice_mod.new({
      path = "p", values = { "a", "b" },
      on_select = function(_, v) got = v end,
    })
    w:activate({ _kernel = k })
    assert.equal("a", got)
  end)
end)

describe("choice: on_key", function()
  it("Up/Down move the highlight cursor", function()
    local k = fake_kernel({ p = "a" })
    local w = choice_mod.new({ path = "p", values = { "a", "b", "c" } })
    w._cursor, w._cursor_seeded = 1, true
    assert.is_true(w:on_key(K.KEY_DOWN, { _kernel = k }))
    assert.equal(2, w._cursor)
    assert.is_true(w:on_key(K.KEY_DOWN, { _kernel = k }))
    assert.equal(3, w._cursor)
    -- Clamp: one more DOWN does nothing.
    assert.is_true(w:on_key(K.KEY_DOWN, { _kernel = k }))
    assert.equal(3, w._cursor)
    assert.is_true(w:on_key(K.KEY_UP, { _kernel = k }))
    assert.equal(2, w._cursor)
  end)

  it("Home/End jump to extremes", function()
    local k = fake_kernel({ p = "a" })
    local w = choice_mod.new({ path = "p", values = { "a", "b", "c" } })
    w._cursor, w._cursor_seeded = 2, true
    w:on_key(K.KEY_END, { _kernel = k })
    assert.equal(3, w._cursor)
    w:on_key(K.KEY_HOME, { _kernel = k })
    assert.equal(1, w._cursor)
  end)

  it("Enter / SPACE activates", function()
    local k = fake_kernel({ p = "a" })
    for _, key in ipairs({ K.CR, K.LF, K.KEY_ENTER, K.SPACE }) do
      local got
      local w = choice_mod.new({
        path = "p", values = { "a", "b" },
        on_select = function(_, v) got = v end,
      })
      w._cursor, w._cursor_seeded = 2, true
      assert.is_true(w:on_key(key, { _kernel = k }))
      assert.equal("b", got)
    end
  end)

  it("returns false on unrelated keys", function()
    local w = choice_mod.new({ path = "p", values = { "a", "b" } })
    assert.is_false(w:on_key(string.byte("z"), {}))
  end)
end)

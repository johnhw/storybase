-- tests/ui/inventory_widget_spec.lua
--
-- Unit tests for the §M8 inventory widget. Covers construction, paint
-- (empty / non-empty / scroll / cursor highlight), scroll navigation
-- via the focus-handler API, and the optional select callbacks.

local screen_mod    = require("cli.drivers.curses.screen")
local inventory_mod = require("cli.drivers.curses.widgets.inventory")
local K             = require("cli.drivers.curses.keys")

local function fake_kernel(values, on_call_fn)
  return {
    _v = values,
    get_state = function(self, path) return self._v[path] end,
    call_fn   = function(_, name, ...) if on_call_fn then on_call_fn(name, ...) end end,
  }
end

local function rows(scr)
  return scr:as_lines()
end

local function strip_trailing(s) return (s:gsub("%s+$", "")) end

describe("inventory: construction", function()
  it("requires a path", function()
    assert.has_error(function() inventory_mod.new({}) end)
  end)

  it("defaults bullet to '-' and empty_text to '(empty)'", function()
    local w = inventory_mod.new({ path = "inv" })
    assert.equal("-", w.bullet)
    assert.equal("(empty)", w.empty_text)
  end)

  it("accepts a single-char bullet override", function()
    assert.equal("*", inventory_mod.new({ path = "i", bullet = "*"  }).bullet)
    assert.equal(">", inventory_mod.new({ path = "i", bullet = ">!" }).bullet)
  end)
end)

describe("inventory: paint (empty list)", function()
  it("renders empty_text when the bound value is missing", function()
    local scr = screen_mod.new(3, 20)
    local win = scr:add_window({ x = 0, y = 0, w = 20, h = 3 })
    local k   = fake_kernel({})
    local w   = inventory_mod.new({ path = "inv", label = "Inventory" })
    w:paint(scr, win, k)
    local r = rows(scr)
    assert.is_truthy(r[1]:find("^Inventory"))
    assert.is_truthy(r[2]:find("^%(empty%)"))
  end)

  it("renders empty_text when the bound value is an empty table", function()
    local scr = screen_mod.new(2, 20)
    local win = scr:add_window({ x = 0, y = 0, w = 20, h = 2 })
    local k   = fake_kernel({ inv = {} })
    local w   = inventory_mod.new({ path = "inv" })
    w:paint(scr, win, k)
    assert.is_truthy(rows(scr)[1]:find("^%(empty%)"))
  end)
end)

describe("inventory: paint (non-empty list)", function()
  it("renders bullets and items", function()
    local scr = screen_mod.new(4, 20)
    local win = scr:add_window({ x = 0, y = 0, w = 20, h = 4 })
    local k   = fake_kernel({ inv = { "sword", "shield", "potion" } })
    local w   = inventory_mod.new({ path = "inv", label = "Items" })
    w:paint(scr, win, k)
    local r = rows(scr)
    assert.is_truthy(r[1]:find("^Items"))
    assert.is_truthy(r[2]:find("^%- sword"))
    assert.is_truthy(r[3]:find("^%- shield"))
    assert.is_truthy(r[4]:find("^%- potion"))
  end)

  it("highlights the cursor row with the reverse attribute", function()
    local scr = screen_mod.new(3, 20)
    local win = scr:add_window({ x = 0, y = 0, w = 20, h = 3 })
    local k   = fake_kernel({ inv = { "a", "b", "c" } })
    local w   = inventory_mod.new({ path = "inv" })
    w:paint(scr, win, k)
    -- Cursor defaults to row 1 ("a"); the entire row pads to inner_w
    -- and is drawn with reverse attrs.
    local cell = scr._cells[0][0]
    assert.equal("-", cell.ch)
    assert.equal("reverse", cell.attrs)
  end)

  it("scrolls when the cursor moves past the visible body", function()
    local scr = screen_mod.new(2, 20)
    local win = scr:add_window({ x = 0, y = 0, w = 20, h = 2 })
    local k   = fake_kernel({ inv = { "a", "b", "c", "d", "e" } })
    local w   = inventory_mod.new({ path = "inv" })
    w:paint(scr, win, k)
    -- Move past the visible window (body_h = 2, items 1..2 visible).
    w:move_cursor(2, k)  -- cursor now at 3
    w:paint(scr, win, k)
    local r = rows(scr)
    -- After scroll, rows show items 2..3 (since cursor reached 3, body
    -- height 2, scroll = cursor - body_h = 1, so visible idx 2..3).
    assert.is_truthy(r[1]:find("^%- b"))
    assert.is_truthy(r[2]:find("^%- c"))
  end)
end)

describe("inventory: activate", function()
  it("fires on_select with the item, index, driver", function()
    local k = fake_kernel({ inv = { "sword", "shield" } })
    local got
    local w = inventory_mod.new({
      path = "inv",
      on_select = function(self, item, idx) got = { item = item, idx = idx } end,
    })
    w:activate({ _kernel = k })
    assert.are.same({ item = "sword", idx = 1 }, got)
  end)

  it("fires fn_name through the kernel", function()
    local seen
    local k = fake_kernel({ inv = { "sword" } },
      function(name, item) seen = { name = name, item = item } end)
    local w = inventory_mod.new({ path = "inv", fn_name = "use" })
    w:activate({ _kernel = k })
    assert.are.same({ name = "use", item = "sword" }, seen)
  end)

  it("returns false when the list is empty", function()
    local k = fake_kernel({ inv = {} })
    local w = inventory_mod.new({ path = "inv" })
    assert.is_false(w:activate({ _kernel = k }))
  end)
end)

describe("inventory: on_key", function()
  it("Up/Down move the cursor", function()
    local k = fake_kernel({ inv = { "a", "b", "c" } })
    local driver = { _kernel = k }
    local w = inventory_mod.new({ path = "inv" })
    -- Need a paint to seed _last_body_h.
    local scr = screen_mod.new(3, 10)
    w:paint(scr, scr:add_window({ x=0, y=0, w=10, h=3 }), k)
    assert.is_true(w:on_key(K.KEY_DOWN, driver))
    assert.equal(2, w._cursor)
    assert.is_true(w:on_key(K.KEY_DOWN, driver))
    assert.equal(3, w._cursor)
    assert.is_true(w:on_key(K.KEY_UP, driver))
    assert.equal(2, w._cursor)
  end)

  it("Home/End jump to extremes", function()
    local k = fake_kernel({ inv = { "a", "b", "c", "d" } })
    local driver = { _kernel = k }
    local w = inventory_mod.new({ path = "inv" })
    local scr = screen_mod.new(4, 10)
    w:paint(scr, scr:add_window({ x=0, y=0, w=10, h=4 }), k)
    w:on_key(K.KEY_END, driver)
    assert.equal(4, w._cursor)
    w:on_key(K.KEY_HOME, driver)
    assert.equal(1, w._cursor)
  end)

  it("Enter activates", function()
    local seen
    local k = fake_kernel({ inv = { "a", "b" } })
    local driver = { _kernel = k }
    local w = inventory_mod.new({
      path = "inv", on_select = function(_, item) seen = item end,
    })
    assert.is_true(w:on_key(K.CR, driver))
    assert.equal("a", seen)
  end)

  it("ignores unrelated keys", function()
    local w = inventory_mod.new({ path = "inv" })
    assert.is_false(w:on_key(string.byte("a"), {}))
  end)
end)

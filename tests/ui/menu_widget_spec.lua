-- tests/ui/menu_widget_spec.lua
--
-- Tests for §M7 menu widget (cli/drivers/curses/widgets/menu.lua). The
-- menu is both a view (paints into a screen on every compose) and a
-- focus handler (consumes keys via on_key). These specs exercise each
-- surface against the buffer screen model — no ncurses involved.
--
-- The menu deliberately separates "what the cursor is on" from "what
-- gets activated" so navigation and activation can be tested in
-- isolation.

local screen_mod = require("cli.drivers.curses.screen")
local menu_mod   = require("cli.drivers.curses.widgets.menu")
local K          = require("cli.drivers.curses.keys")

--- Helper: take an as_lines() snapshot trimmed on the right.
local function dump(screen)
  local lines = screen:as_lines()
  local out = {}
  for i, l in ipairs(lines) do out[i] = (l:gsub("%s+$", "")) end
  return out
end

--- Find the y row (0-based) and column offset where `needle` first
--- appears in the snapshot.
local function find(screen, needle)
  local lines = screen:as_lines()
  for i, line in ipairs(lines) do
    local s = line:find(needle, 1, true)
    if s then return i - 1, s - 1 end
  end
  return nil
end

describe("menu: construction", function()
  it("requires items", function()
    assert.has_error(function() menu_mod.new({}) end)
  end)

  it("border defaults to true", function()
    local m = menu_mod.new({ items = { { label = "x" } } })
    assert.is_true(m.border)
  end)

  it("wrap defaults to true", function()
    local m = menu_mod.new({ items = { { label = "x" } } })
    assert.is_true(m.wrap)
  end)

  it("z defaults to 100 (over the base game view)", function()
    local m = menu_mod.new({ items = { { label = "x" } } })
    assert.equal(100, m.z)
  end)

  it("z is overridable", function()
    assert.equal(7, menu_mod.new({ items = { { label = "x" } }, z = 7 }).z)
  end)

  it("cursor starts on the first selectable item", function()
    local m = menu_mod.new({ items = {
      { kind = "header",  label = "Group" },
      { kind = "divider" },
      { kind = "item",    label = "First" },
      { kind = "item",    label = "Second" },
    } })
    assert.equal(3, m:cursor())
    assert.equal("First", m:selected().label)
  end)

  it("cursor is 0 when no items are selectable", function()
    local m = menu_mod.new({ items = {
      { kind = "header",  label = "Group A" },
      { kind = "divider" },
      { kind = "header",  label = "Group B" },
    } })
    assert.equal(0, m:cursor())
    assert.is_nil(m:selected())
  end)
end)

describe("menu: paint", function()
  it("draws a bordered box centred on screen", function()
    local s = screen_mod.new(10, 30)
    local m = menu_mod.new({ items = {
      { label = "Alpha"   },
      { label = "Beta"    },
      { label = "Gamma"   },
    } })
    m:paint(s, nil)
    local out = dump(s)
    -- A corner glyph appears somewhere.
    local has_corner = false
    for _, line in ipairs(out) do
      if line:find("+", 1, true) then has_corner = true; break end
    end
    assert.is_true(has_corner, "border corners should be drawn")
    -- All three labels appear.
    assert.is_not_nil(find(s, "Alpha"))
    assert.is_not_nil(find(s, "Beta"))
    assert.is_not_nil(find(s, "Gamma"))
  end)

  it("renders a title in the top border", function()
    local s = screen_mod.new(10, 30)
    local m = menu_mod.new({
      title = "Game Menu",
      items = { { label = "Resume" }, { label = "Quit" } },
    })
    m:paint(s, nil)
    assert.is_not_nil(find(s, "Game Menu"),
      "title should appear on the top border")
  end)

  it("renders divider items as a row of glyphs", function()
    local s = screen_mod.new(10, 30)
    local m = menu_mod.new({ items = {
      { label = "New Game"    },
      { kind  = "divider"     },
      { label = "Load Game"   },
    } })
    m:paint(s, nil)
    -- The divider row should contain a run of '-' that's strictly
    -- longer than a stray border character. The simplest check: find
    -- a row containing both "New Game" and a row below it containing
    -- a '-' run; and a row below *that* containing "Load Game".
    local rows = s:as_lines()
    local y_new, y_load
    for i, line in ipairs(rows) do
      if line:find("New Game",  1, true) then y_new  = i end
      if line:find("Load Game", 1, true) then y_load = i end
    end
    assert.is_not_nil(y_new)
    assert.is_not_nil(y_load)
    assert.is_true(y_load - y_new >= 2,
      "load game should be at least 2 rows below new game (divider in between)")
    local mid = rows[y_new + 1]
    assert.is_truthy(mid:find("%-%-%-"), "divider row should contain a run of -")
  end)

  it("uses a custom divider glyph when set", function()
    local s = screen_mod.new(10, 30)
    local m = menu_mod.new({
      divider_glyph = "=",
      items = {
        { label = "Above"   },
        { kind  = "divider" },
        { label = "Below"   },
      },
    })
    m:paint(s, nil)
    local rows = s:as_lines()
    local y_above
    for i, line in ipairs(rows) do
      if line:find("Above", 1, true) then y_above = i end
    end
    assert.is_truthy(rows[y_above + 1]:find("==="),
      "custom divider glyph should appear")
  end)

  it("renders an item's hotkey as [k] Label", function()
    local s = screen_mod.new(10, 30)
    local m = menu_mod.new({ items = {
      { label = "Save", hotkey = "s" },
      { label = "Quit", hotkey = "q" },
    } })
    m:paint(s, nil)
    assert.is_not_nil(find(s, "[s] Save"))
    assert.is_not_nil(find(s, "[q] Quit"))
  end)

  it("border=false suppresses the box (items still painted)", function()
    local s = screen_mod.new(8, 24)
    local m = menu_mod.new({
      border = false,
      items  = { { label = "First" }, { label = "Second" } },
    })
    m:paint(s, nil)
    assert.is_not_nil(find(s, "First"))
    assert.is_not_nil(find(s, "Second"))
    -- No border corners drawn anywhere.
    for _, line in ipairs(dump(s)) do
      assert.is_nil(line:find("+", 1, true),
        "border=false should not paint any '+' corners")
    end
  end)

  it("clips the menu to the screen when oversized", function()
    -- Tiny 5x10 screen with a too-wide title and too-many items.
    local s = screen_mod.new(5, 10)
    local items = {}
    for i = 1, 12 do items[i] = { label = "Item " .. i } end
    local m = menu_mod.new({
      title = "VeryLongTitleHere",
      items = items,
    })
    assert.has_no_error(function() m:paint(s, nil) end)
    -- All rows are at most 10 chars wide (the screen width).
    for _, line in ipairs(s:as_lines()) do
      assert.is_true(#line <= 10)
    end
  end)
end)

describe("menu: navigation", function()
  it("Down moves the cursor to the next selectable item", function()
    local m = menu_mod.new({ items = {
      { label = "A" }, { label = "B" }, { label = "C" },
    } })
    assert.equal(1, m:cursor())
    assert.is_true(m:on_key(K.KEY_DOWN, nil))
    assert.equal(2, m:cursor())
    m:on_key(K.KEY_DOWN, nil)
    assert.equal(3, m:cursor())
  end)

  it("Up moves the cursor to the previous selectable item", function()
    local m = menu_mod.new({ items = {
      { label = "A" }, { label = "B" }, { label = "C" },
    } })
    m:on_key(K.KEY_DOWN, nil) -- 2
    m:on_key(K.KEY_DOWN, nil) -- 3
    m:on_key(K.KEY_UP,   nil)
    assert.equal(2, m:cursor())
  end)

  it("Down skips over dividers and headers", function()
    local m = menu_mod.new({ items = {
      { label = "Resume" },                       -- 1
      { kind  = "divider" },                      -- 2
      { kind  = "header", label = "Settings" },   -- 3
      { kind  = "divider" },                      -- 4
      { label = "Audio"  },                       -- 5
      { label = "Video"  },                       -- 6
    } })
    assert.equal(1, m:cursor())
    m:on_key(K.KEY_DOWN, nil)
    assert.equal(5, m:cursor(), "cursor should skip past header + dividers")
  end)

  it("Down wraps to the first item by default", function()
    local m = menu_mod.new({ items = {
      { label = "A" }, { label = "B" },
    } })
    m:on_key(K.KEY_DOWN, nil) -- 2
    m:on_key(K.KEY_DOWN, nil) -- wraps to 1
    assert.equal(1, m:cursor())
  end)

  it("Up wraps to the last item by default", function()
    local m = menu_mod.new({ items = {
      { label = "A" }, { label = "B" }, { label = "C" },
    } })
    m:on_key(K.KEY_UP, nil)
    assert.equal(3, m:cursor())
  end)

  it("wrap=false clamps at the ends", function()
    local m = menu_mod.new({
      wrap  = false,
      items = { { label = "A" }, { label = "B" } },
    })
    m:on_key(K.KEY_UP, nil)
    assert.equal(1, m:cursor(), "cursor should stay at top when wrap is off")
    m:on_key(K.KEY_DOWN, nil)
    m:on_key(K.KEY_DOWN, nil)
    assert.equal(2, m:cursor(), "cursor should stay at bottom when wrap is off")
  end)

  it("Home jumps to first selectable, End to last", function()
    local m = menu_mod.new({ items = {
      { kind = "header", label = "Group" },
      { label = "A" }, { label = "B" }, { label = "C" },
    } })
    m:on_key(K.KEY_END,  nil)
    assert.equal(4, m:cursor())
    m:on_key(K.KEY_HOME, nil)
    assert.equal(2, m:cursor(), "Home should land on the first selectable item")
  end)

  it("set_cursor snaps to the nearest selectable item", function()
    local m = menu_mod.new({ items = {
      { label = "A" },
      { kind  = "divider" },
      { kind  = "header", label = "Group" },
      { label = "B" },
    } })
    m:set_cursor(3) -- header → snap forward
    assert.equal(4, m:cursor())
    m:set_cursor(2) -- divider → snap forward, lands on header (also unsel.) → forward → 4
    assert.equal(4, m:cursor())
  end)
end)

describe("menu: highlight", function()
  it("paints the current item with the highlight attrs", function()
    local s = screen_mod.new(8, 24)
    local m = menu_mod.new({ items = {
      { label = "Alpha" }, { label = "Beta" },
    } })
    m:on_key(K.KEY_DOWN, nil) -- cursor now on Beta
    m:paint(s, nil)
    -- Find the row holding "Beta" and inspect its first non-space cell.
    local y_beta
    for i, line in ipairs(s:as_lines()) do
      if line:find("Beta", 1, true) then y_beta = i - 1 end
    end
    assert.is_not_nil(y_beta)
    -- Scan the row for a cell whose attrs contains "reverse".
    local found_reverse = false
    for x = 0, s.cols - 1 do
      local c = s:get_cell(y_beta, x)
      if c and c.attrs == "reverse" then found_reverse = true; break end
    end
    assert.is_true(found_reverse,
      "the highlighted row should contain at least one cell with attrs=reverse")
  end)

  it("highlight_attrs can be overridden", function()
    local s = screen_mod.new(8, 24)
    local m = menu_mod.new({
      highlight_attrs = { attrs = "bold" },
      items = { { label = "Only" } },
    })
    m:paint(s, nil)
    local y_only
    for i, line in ipairs(s:as_lines()) do
      if line:find("Only", 1, true) then y_only = i - 1 end
    end
    local found_bold = false
    for x = 0, s.cols - 1 do
      local c = s:get_cell(y_only, x)
      if c and c.attrs == "bold" then found_bold = true; break end
    end
    assert.is_true(found_bold)
  end)
end)

describe("menu: activation", function()
  it("Enter invokes item.action and on_activate", function()
    local fired = {}
    local m = menu_mod.new({
      items = {
        { label = "Go",
          action = function(_drv, item)
            fired[#fired + 1] = "action:" .. item.label
          end },
      },
      on_activate = function(_self, item, _drv)
        fired[#fired + 1] = "on_activate:" .. item.label
      end,
    })
    assert.is_true(m:on_key(K.CR, nil))
    assert.same({ "action:Go", "on_activate:Go" }, fired)
  end)

  it("Enter does nothing when there are no selectable items", function()
    local m = menu_mod.new({ items = {
      { kind = "header", label = "Nothing here" },
    } })
    -- Returns true (Enter consumed) but no activation happens.
    assert.is_true(m:on_key(K.CR, nil))
  end)

  it("activate() returns false when cursor is on nothing", function()
    local m = menu_mod.new({ items = {
      { kind = "header", label = "Only header" },
    } })
    assert.is_false(m:activate(nil))
  end)
end)

describe("menu: hotkeys", function()
  it("matching hotkey jumps to the item and activates it", function()
    local fired = {}
    local m = menu_mod.new({
      items = {
        { label = "Save", hotkey = "s",
          action = function() fired[#fired + 1] = "save" end },
        { label = "Quit", hotkey = "q",
          action = function() fired[#fired + 1] = "quit" end },
      },
    })
    assert.is_true(m:on_key(string.byte("q"), nil))
    assert.equal(2, m:cursor())
    assert.same({ "quit" }, fired)
  end)

  it("items without a hotkey are not reachable by random keys", function()
    local fired = {}
    local m = menu_mod.new({
      items = {
        { label = "Hidden",
          action = function() fired[#fired + 1] = "hidden" end },
      },
      on_cancel = function() end,
    })
    -- Send 'x' — no item has hotkey 'x', no cancel binding matches 'x'.
    assert.is_false(m:on_key(string.byte("x"), nil))
    assert.same({}, fired)
  end)

  it("hotkey on a non-selectable item is ignored", function()
    local m = menu_mod.new({ items = {
      { kind = "header", label = "Header", hotkey = "h" },
      { label = "Other" },
    } })
    assert.is_false(m:on_key(string.byte("h"), nil))
  end)
end)

describe("menu: cancel", function()
  it("ESC fires on_cancel and consumes the key", function()
    local fired
    local m = menu_mod.new({
      items     = { { label = "x" } },
      on_cancel = function() fired = true end,
    })
    assert.is_true(m:on_key(K.ESC, nil))
    assert.is_true(fired)
  end)

  it("ESC is consumed even without on_cancel", function()
    local m = menu_mod.new({ items = { { label = "x" } } })
    assert.is_true(m:on_key(K.ESC, nil))
  end)

  it("custom cancel key works", function()
    local fired
    local m = menu_mod.new({
      items     = { { label = "x" } },
      keys      = { cancel = { string.byte("c") } },
      on_cancel = function() fired = true end,
    })
    assert.is_false(m:on_key(K.ESC, nil),
      "ESC should no longer cancel once overridden")
    assert.is_true(m:on_key(string.byte("c"), nil))
    assert.is_true(fired)
  end)
end)

describe("menu: customisable bindings", function()
  it("vim-style j/k can be wired as down/up", function()
    local m = menu_mod.new({
      items = { { label = "A" }, { label = "B" }, { label = "C" } },
      keys  = {
        up   = { K.KEY_UP,   string.byte("k") },
        down = { K.KEY_DOWN, string.byte("j") },
      },
    })
    assert.equal(1, m:cursor())
    assert.is_true(m:on_key(string.byte("j"), nil))
    assert.equal(2, m:cursor())
    assert.is_true(m:on_key(string.byte("k"), nil))
    assert.equal(1, m:cursor())
    -- The original arrow keys still work too.
    m:on_key(K.KEY_DOWN, nil)
    assert.equal(2, m:cursor())
  end)
end)

describe("menu: on_key non-numeric", function()
  it("returns false for non-numeric keys", function()
    local m = menu_mod.new({ items = { { label = "x" } } })
    assert.is_false(m:on_key("a", nil))
    assert.is_false(m:on_key(nil,  nil))
  end)
end)

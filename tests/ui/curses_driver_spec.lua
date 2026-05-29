-- tests/ui/curses_driver_spec.lua
--
-- Headless tests for the §M2 curses driver. ncurses requires a TTY,
-- which busted does not provide, so these tests inject a stub `curses`
-- module via `opts.curses` and exercise the backend's paint + input
-- logic against a buffer snapshot.
--
-- Covers:
--   * backend lifecycle (init/close, idempotency, endwin on close)
--   * narration → text-line conversion (narration + say + multi-line)
--   * paint regions (narration tail, separator, choices, prompt)
--   * read_choice (digit dispatch, q/Q/ESC quit, key filtering)
--   * driver-level pull-mode (render then prompt) round-trip
--   * driver is_driver() conformance with a stub curses module

local backend_mod = require("cli.drivers.curses.backend_curses")
local driver_mod  = require("cli.drivers.curses")
local protocol    = require("cli.drivers.driver")

-- ── Stub curses module ──────────────────────────────────────────────

--- Build a fake `curses` module that captures lifecycle calls and
--- maintains a deterministic 2D character grid for snapshotting.
---
--- @param opts table?  { rows, cols, keys }
---     rows : integer (default 24)
---     cols : integer (default 80)
---     keys : integer[]  preprogrammed getch return values
local function fake_curses(opts)
  opts = opts or {}
  local rows = opts.rows or 24
  local cols = opts.cols or 80
  local keys = opts.keys or {}
  local key_idx = 0

  local calls = {
    initscr   = 0,
    cbreak    = 0,
    echo      = 0,
    curs_set  = {},
    endwin    = 0,
  }
  local end_called = false

  local stdscr = {
    _grid = {},
    _calls = { keypad = 0, clear = 0, refresh = 0, mvaddstr = {} },
  }

  function stdscr:keypad(_v)
    self._calls.keypad = self._calls.keypad + 1
  end
  function stdscr:getmaxyx() return rows, cols end
  function stdscr:clear()
    self._calls.clear = self._calls.clear + 1
    self._grid = {}
    for y = 0, rows - 1 do
      self._grid[y] = string.rep(" ", cols)
    end
  end
  function stdscr:refresh()
    self._calls.refresh = self._calls.refresh + 1
  end
  function stdscr:mvaddstr(y, x, s)
    self._calls.mvaddstr[#self._calls.mvaddstr + 1] = { y = y, x = x, s = s }
    local row = self._grid[y]
    if not row then return end
    if x < 0 then return end
    local L = #s
    if x + L > cols then
      s = s:sub(1, cols - x)
      L = #s
    end
    if L <= 0 then return end
    local prefix = row:sub(1, x)
    local suffix = row:sub(x + L + 1)
    self._grid[y] = prefix .. s .. suffix
  end
  function stdscr:getch()
    key_idx = key_idx + 1
    return keys[key_idx]
  end

  local fake = {}
  fake.initscr  = function() calls.initscr = calls.initscr + 1; return stdscr end
  fake.cbreak   = function() calls.cbreak = calls.cbreak + 1 end
  fake.echo     = function() calls.echo = calls.echo + 1 end
  fake.curs_set = function(v) calls.curs_set[#calls.curs_set + 1] = v end
  fake.endwin   = function() calls.endwin = calls.endwin + 1; end_called = true end
  fake.isendwin = function() return end_called end

  -- Introspection helpers (prefixed `_` so they don't collide with the
  -- real curses surface).
  fake._calls = calls
  fake._stdscr = stdscr
  fake._snapshot = function()
    local lines = {}
    for y = 0, rows - 1 do
      lines[#lines + 1] = (stdscr._grid[y] or ""):gsub(" +$", "")
    end
    return table.concat(lines, "\n")
  end
  fake._snapshot_row = function(y)
    return (stdscr._grid[y] or ""):gsub(" +$", "")
  end
  fake._end_called = function() return end_called end

  return fake
end

-- Fixtures.
local narr_items = {
  { kind = "narration", text = "The cave is dark." },
  { kind = "say",       speaker = "ghost", display = "Ghost", text = "Boo!" },
  { kind = "narration", text = "" },  -- empty: should be skipped
}

local choices = {
  { index = 1, label = "Run away" },
  { index = 2, label = "Stay put" },
  { index = 3, label = "Investigate" },
}

-- ── Backend lifecycle ───────────────────────────────────────────────

describe("curses backend: lifecycle", function()
  it("init() calls initscr, cbreak, echo, curs_set, keypad", function()
    local c = fake_curses()
    local b = backend_mod.new({ curses = c })
    assert.is_true(b:init())
    assert.equal(1, c._calls.initscr)
    assert.equal(1, c._calls.cbreak)
    assert.equal(1, c._calls.echo)
    assert.is_true(#c._calls.curs_set >= 1, "should hide cursor (curs_set 0)")
    assert.equal(0, c._calls.curs_set[1])
    assert.equal(1, c._stdscr._calls.keypad)
  end)

  it("init() is idempotent", function()
    local c = fake_curses()
    local b = backend_mod.new({ curses = c })
    b:init(); b:init(); b:init()
    assert.equal(1, c._calls.initscr)
  end)

  it("close() calls endwin and is idempotent", function()
    local c = fake_curses()
    local b = backend_mod.new({ curses = c })
    b:init()
    b:close(); b:close()
    assert.equal(1, c._calls.endwin)
    assert.is_true(c._end_called())
  end)

  it("close() before init() is safe and is a no-op", function()
    local c = fake_curses()
    local b = backend_mod.new({ curses = c })
    assert.has_no_errors(function() b:close() end)
    assert.equal(0, c._calls.endwin)
  end)

  it("returns (false, reason) when curses is unavailable", function()
    -- No `opts.curses` injection AND the package.loaded["curses"] is
    -- whatever the host has — but the backend's resolve path uses
    -- pcall(require, "curses"); we can simulate absence by injecting
    -- a sentinel that fails on first use only if we don't supply one.
    -- Instead we rely on this dev env having lcurses; cover the
    -- failure path by patching the backend's internal resolver via
    -- the injection seam: pass a table that lacks initscr — the call
    -- pattern is exercised below in "init handles missing functions
    -- gracefully" instead. Here we just confirm that when no curses
    -- can be resolved, init returns false. Achievable by overriding
    -- package.loaded["curses"] temporarily.
    local saved = package.loaded["curses"]
    package.loaded["curses"] = nil
    -- Force pcall(require) to fail by removing the loader entry too.
    local saved_searchers = {}
    for i, fn in ipairs(package.searchers or {}) do saved_searchers[i] = fn end
    package.searchers = {
      function(_) return "module 'curses' not found (test stub)" end,
    }
    local ok, reason = backend_mod.new({}):init()
    package.searchers = saved_searchers
    package.loaded["curses"] = saved
    assert.is_false(ok)
    assert.is_string(reason)
    assert.is_truthy(reason:lower():find("lcurses"))
  end)
end)

-- ── Narration accumulation ──────────────────────────────────────────

describe("curses backend: narration accumulation", function()
  it("renders say items as `Speaker: text`", function()
    -- rows=10 leaves narr_h = 10 - 3 choices - 1 sep - 1 prompt = 5 lines,
    -- enough room for both the narration and say items in the fixture.
    local c = fake_curses({ rows = 10, cols = 40 })
    local b = backend_mod.new({ curses = c })
    b:init()
    b:append_narration(narr_items)
    b:paint(choices, false)
    local snap = c._snapshot()
    assert.is_truthy(snap:find("Ghost: Boo!"), snap)
    assert.is_truthy(snap:find("The cave is dark."), snap)
  end)

  it("skips empty-text items", function()
    local c = fake_curses({ rows = 6, cols = 40 })
    local b = backend_mod.new({ curses = c })
    b:init()
    b:append_narration({ { kind = "narration", text = "" } })
    -- No paint required — internal history should still be empty.
    assert.equal(0, #b._narr_lines,
      "empty narration items should not be added to history")
  end)

  it("splits multi-line text on newlines", function()
    local c = fake_curses({ rows = 6, cols = 80 })
    local b = backend_mod.new({ curses = c })
    b:init()
    b:append_narration({ { kind = "narration", text = "line one\nline two" } })
    assert.equal(2, #b._narr_lines)
    assert.equal("line one", b._narr_lines[1])
    assert.equal("line two", b._narr_lines[2])
  end)

  it("accumulates narration across multiple appends", function()
    local c = fake_curses({ rows = 6, cols = 80 })
    local b = backend_mod.new({ curses = c })
    b:init()
    b:append_narration({ { kind = "narration", text = "first" } })
    b:append_narration({ { kind = "narration", text = "second" } })
    assert.equal(2, #b._narr_lines)
  end)
end)

-- ── Paint layout ────────────────────────────────────────────────────

describe("curses backend: paint layout", function()
  it("places choices below the narration with a separator", function()
    local c = fake_curses({ rows = 10, cols = 40 })
    local b = backend_mod.new({ curses = c })
    b:init()
    b:append_narration({ { kind = "narration", text = "Welcome." } })
    b:paint(choices, true)

    -- rows=10, choices=3, prompt=1, sep=1 → narr=5
    -- Narration tail occupies rows 0..4; separator at row 5; choices 6..8; prompt 9.
    assert.is_truthy(c._snapshot_row(0):find("Welcome%."))
    -- Separator row is all dashes.
    local sep = c._snapshot_row(5)
    assert.is_truthy(sep:find("^%-+$"), "separator row should be all dashes: " .. sep)
    assert.is_truthy(c._snapshot_row(6):find("^1%. Run away"))
    assert.is_truthy(c._snapshot_row(7):find("^2%. Stay put"))
    assert.is_truthy(c._snapshot_row(8):find("^3%. Investigate"))
  end)

  it("active prompt asks for a choice index", function()
    local c = fake_curses({ rows = 10, cols = 80 })
    local b = backend_mod.new({ curses = c })
    b:init()
    b:paint(choices, true)
    local last = c._snapshot_row(9)
    assert.is_truthy(last:find("Choice %(1%-3, q to quit%):"), last)
  end)

  it("inactive prompt shows the quit hint instead", function()
    local c = fake_curses({ rows = 10, cols = 80 })
    local b = backend_mod.new({ curses = c })
    b:init()
    b:paint(choices, false)
    local last = c._snapshot_row(9)
    assert.is_truthy(last:find("press q or ESC to quit"), last)
  end)

  it("tail-clips narration that exceeds the available rows", function()
    local c = fake_curses({ rows = 8, cols = 40 })
    local b = backend_mod.new({ curses = c })
    b:init()
    -- 10 lines into a region that only fits a few; oldest scroll off.
    for i = 1, 10 do
      b:append_narration({ { kind = "narration", text = "line " .. i } })
    end
    b:paint({}, false)
    local snap = c._snapshot()
    -- Last line should always be visible (most recent).
    assert.is_truthy(snap:find("line 10"), snap)
    -- Very first line should NOT be visible (scrolled off).
    assert.is_falsy(snap:find("line 1\n") or snap:find("^line 1$"),
      "earliest line should have scrolled off-screen")
  end)

  it("clips wide labels to fit the terminal width", function()
    local c = fake_curses({ rows = 8, cols = 20 })
    local b = backend_mod.new({ curses = c })
    b:init()
    b:paint({ { index = 1, label = string.rep("X", 100) } }, false)
    -- No row may exceed 20 chars after the paint.
    for y = 0, 7 do
      local row = c._stdscr._grid[y] or ""
      assert.equal(20, #row, "row " .. y .. " width should be exactly cols")
    end
  end)

  it("paint() on uninitialised backend is a silent no-op", function()
    local c = fake_curses()
    local b = backend_mod.new({ curses = c })
    -- No init() yet — paint should do nothing without erroring.
    assert.has_no_errors(function() b:paint(choices, true) end)
    assert.equal(0, c._stdscr._calls.refresh)
  end)
end)

-- ── Input dispatch ─────────────────────────────────────────────────

describe("curses backend: read_choice", function()
  local function with_keys(keys)
    local c = fake_curses({ keys = keys })
    local b = backend_mod.new({ curses = c })
    b:init()
    return b, c
  end

  it("returns the digit value for valid choice keys", function()
    local b = with_keys({ string.byte("2") })
    assert.equal(2, b:read_choice(3))
  end)

  it("returns nil for ESC", function()
    local b = with_keys({ 27 })
    assert.is_nil(b:read_choice(3))
  end)

  it("returns nil for q", function()
    local b = with_keys({ string.byte("q") })
    assert.is_nil(b:read_choice(3))
  end)

  it("returns nil for Q (capital)", function()
    local b = with_keys({ string.byte("Q") })
    assert.is_nil(b:read_choice(3))
  end)

  it("ignores out-of-range digits and waits for a valid one", function()
    -- '9' is out-of-range (only 3 choices); '2' should be accepted.
    local b = with_keys({ string.byte("9"), string.byte("2") })
    assert.equal(2, b:read_choice(3))
  end)

  it("ignores unrelated keys (letters, arrows) and waits", function()
    -- 'x', KEY_DOWN (258 typical), then '1'.
    local b = with_keys({ string.byte("x"), 258, string.byte("1") })
    assert.equal(1, b:read_choice(3))
  end)

  it("returns nil on EOF (getch returns nil)", function()
    local b = with_keys({ nil })
    assert.is_nil(b:read_choice(3))
  end)

  it("returns nil when called before init()", function()
    local c = fake_curses({ keys = { string.byte("1") } })
    local b = backend_mod.new({ curses = c })
    -- No init.
    assert.is_nil(b:read_choice(3))
  end)
end)

-- ── Driver-level wiring ────────────────────────────────────────────

describe("curses driver: render+prompt round-trip", function()
  it("renders narration then prompts and returns the chosen index", function()
    local c = fake_curses({ rows = 12, cols = 60, keys = { string.byte("2") } })
    local d = driver_mod.new({ curses = c })
    d:render({ narration = narr_items, choices = choices })
    local idx = d:prompt(choices)
    assert.equal(2, idx)
    local snap = c._snapshot()
    assert.is_truthy(snap:find("Ghost: Boo!"), snap)
    assert.is_truthy(snap:find("Choice %(1%-3"), snap)
  end)

  it("returns nil from prompt on q (quit)", function()
    local c = fake_curses({ keys = { string.byte("q") } })
    local d = driver_mod.new({ curses = c })
    d:render({ narration = {}, choices = choices })
    assert.is_nil(d:prompt(choices))
  end)

  it("renders end-of-game narration without prompting (choices empty)", function()
    local c = fake_curses({ rows = 10, cols = 60 })
    local d = driver_mod.new({ curses = c })
    d:render({ narration = { { kind = "narration", text = "Goodbye." } },
               choices = {} })
    local snap = c._snapshot()
    assert.is_truthy(snap:find("Goodbye%."), snap)
    -- No active "Choice" prompt should appear when render is called
    -- with an empty choice list (engine emits this for endings).
    assert.is_falsy(snap:find("Choice %(1"), snap)
  end)

  it("detach() cleans up curses", function()
    local c = fake_curses()
    local d = driver_mod.new({ curses = c })
    d:render({ narration = {}, choices = {} })  -- forces init
    d:detach()
    assert.equal(1, c._calls.endwin)
  end)

  it("satisfies the driver contract", function()
    local d = driver_mod.new({ curses = fake_curses() })
    assert.is_true(protocol.is_driver(d))
  end)
end)

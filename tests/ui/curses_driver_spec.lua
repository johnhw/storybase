-- tests/ui/curses_driver_spec.lua
--
-- Headless tests for the curses driver after the §M3 screen-model
-- split. The driver now composes a 2D cell grid (`screen.lua`),
-- diff-paints into either backend (`backend_curses.lua` or
-- `backend_buffer.lua`), and reads keys via the backend's `read_key`.
--
-- Coverage:
--   * ncurses backend lifecycle (init/close/flush/read_key) via a stub
--     `curses` module — no TTY required
--   * driver round-trip (render → prompt → choice index) against the
--     buffer backend
--   * driver protocol conformance
--   * end-of-game (no choices) rendering
--   * detach cleans up the backend
--   * lazy initialisation (M.new is safe in any environment)

local backend_curses_mod = require("cli.drivers.curses.backend_curses")
local driver_mod         = require("cli.drivers.curses")
local protocol           = require("cli.drivers.driver")
local fake_curses_mod    = require("tests.ui.helpers.fake_curses")

-- Backward-compatible local alias: the bulk of the spec uses the
-- helper as `fake_curses(opts)` directly.
local fake_curses = fake_curses_mod.new

-- ── Fixtures ───────────────────────────────────────────────────────

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

-- ── ncurses backend lifecycle ──────────────────────────────────────

describe("curses backend (ncurses): lifecycle", function()
  it("init() calls initscr, cbreak, echo, curs_set, keypad", function()
    local c = fake_curses()
    local b = backend_curses_mod.new({ curses = c })
    assert.is_true(b:init(24, 80))
    assert.equal(1, c._calls.initscr)
    assert.equal(1, c._calls.cbreak)
    assert.equal(1, c._calls.echo)
    assert.is_true(#c._calls.curs_set >= 1, "should hide cursor (curs_set 0)")
    assert.equal(0, c._calls.curs_set[1])
    assert.equal(1, c._stdscr._calls.keypad)
  end)

  it("init() is idempotent", function()
    local c = fake_curses()
    local b = backend_curses_mod.new({ curses = c })
    b:init(); b:init(); b:init()
    assert.equal(1, c._calls.initscr)
  end)

  it("size() reports the terminal geometry after init()", function()
    local c = fake_curses({ rows = 12, cols = 40 })
    local b = backend_curses_mod.new({ curses = c })
    b:init()
    local r, cols = b:size()
    assert.equal(12, r)
    assert.equal(40, cols)
  end)

  it("size() returns (0, 0) before init()", function()
    local c = fake_curses({ rows = 10, cols = 30 })
    local b = backend_curses_mod.new({ curses = c })
    local r, cols = b:size()
    assert.equal(0, r)
    assert.equal(0, cols)
  end)

  it("close() calls endwin and is idempotent", function()
    local c = fake_curses()
    local b = backend_curses_mod.new({ curses = c })
    b:init()
    b:close(); b:close()
    assert.equal(1, c._calls.endwin)
    assert.is_true(c._end_called())
  end)

  it("close() before init() is safe and is a no-op", function()
    local c = fake_curses()
    local b = backend_curses_mod.new({ curses = c })
    assert.has_no_errors(function() b:close() end)
    assert.equal(0, c._calls.endwin)
  end)

  it("returns (false, reason) when curses is unavailable", function()
    -- Force the module resolver to fail.
    local saved = package.loaded["curses"]
    package.loaded["curses"] = nil
    local saved_searchers = {}
    for i, fn in ipairs(package.searchers or {}) do saved_searchers[i] = fn end
    package.searchers = {
      function(_) return "module 'curses' not found (test stub)" end,
    }
    local ok, reason = backend_curses_mod.new({}):init()
    package.searchers = saved_searchers
    package.loaded["curses"] = saved
    assert.is_false(ok)
    assert.is_string(reason)
    assert.is_truthy(reason:lower():find("lcurses"))
  end)
end)

-- ── ncurses backend flush + read_key ───────────────────────────────

describe("curses backend (ncurses): flush + read_key", function()
  it("flush() emits one mvaddstr per dirty rect and calls refresh()", function()
    local c = fake_curses({ rows = 5, cols = 20 })
    local b = backend_curses_mod.new({ curses = c })
    b:init()
    local rects = {
      { y = 0, x = 0, cells = {{ ch = "h" }, { ch = "i" }} },
      { y = 1, x = 4, cells = {{ ch = "!" }} },
    }
    b:flush(nil, rects)
    assert.equal(2, #c._stdscr._calls.mvaddstr)
    assert.equal("hi", c._stdscr._calls.mvaddstr[1].s)
    assert.equal(1, c._stdscr._calls.refresh)
  end)

  it("flush() with an empty rect list still refreshes", function()
    local c = fake_curses()
    local b = backend_curses_mod.new({ curses = c })
    b:init()
    b:flush(nil, {})
    assert.equal(1, c._stdscr._calls.refresh)
    assert.equal(0, #c._stdscr._calls.mvaddstr)
  end)

  it("read_key() returns the integer key from getch", function()
    local c = fake_curses({ keys = { string.byte("a") } })
    local b = backend_curses_mod.new({ curses = c })
    b:init()
    assert.equal(string.byte("a"), b:read_key())
  end)

  it("read_key() returns nil on EOF (-1)", function()
    local c = fake_curses({ keys = { -1 } })
    local b = backend_curses_mod.new({ curses = c })
    b:init()
    assert.is_nil(b:read_key())
  end)

  it("read_key() returns nil when getch returns nil", function()
    local c = fake_curses({ keys = { nil } })
    local b = backend_curses_mod.new({ curses = c })
    b:init()
    assert.is_nil(b:read_key())
  end)

  it("read_key() returns nil before init()", function()
    local c = fake_curses({ keys = { 65 } })
    local b = backend_curses_mod.new({ curses = c })
    assert.is_nil(b:read_key())
  end)
end)

-- ── Driver round-trip on the buffer backend ────────────────────────

describe("curses driver: round-trip (buffer backend)", function()
  local function snap(d)
    return d:_backend_handle():snapshot()
  end

  it("renders narration then prompts and returns the chosen index", function()
    local d = driver_mod.new({
      backend = "buffer", rows = 12, cols = 60,
      keys    = { string.byte("2") },
    })
    d:render({ narration = narr_items, choices = choices })
    local idx = d:prompt(choices)
    assert.equal(2, idx)
    local s = snap(d)
    assert.is_truthy(s:find("Ghost: Boo!"), s)
    assert.is_truthy(s:find("Choice %(1%-3"), s)
  end)

  it("returns nil from prompt on q (quit)", function()
    local d = driver_mod.new({
      backend = "buffer", rows = 10, cols = 40,
      keys    = { string.byte("q") },
    })
    d:render({ narration = {}, choices = choices })
    assert.is_nil(d:prompt(choices))
  end)

  it("returns nil from prompt on ESC", function()
    local d = driver_mod.new({
      backend = "buffer", rows = 10, cols = 40,
      keys    = { 27 },
    })
    d:render({ narration = {}, choices = choices })
    assert.is_nil(d:prompt(choices))
  end)

  it("ignores out-of-range digits and waits for a valid one", function()
    local d = driver_mod.new({
      backend = "buffer", rows = 10, cols = 40,
      keys    = { string.byte("9"), string.byte("1") },
    })
    d:render({ narration = {}, choices = choices })
    assert.equal(1, d:prompt(choices))
  end)

  it("renders end-of-game narration without prompting (choices empty)", function()
    local d = driver_mod.new({
      backend = "buffer", rows = 10, cols = 60,
    })
    d:render({
      narration = { { kind = "narration", text = "Goodbye." } },
      choices   = {},
    })
    local s = snap(d)
    assert.is_truthy(s:find("Goodbye%."), s)
    assert.is_falsy(s:find("Choice %(1"), s)
  end)

  it("places choices below the narration with a separator", function()
    local d = driver_mod.new({ backend = "buffer", rows = 10, cols = 40 })
    d:render({ narration = { { kind = "narration", text = "Welcome." } },
               choices   = choices })
    -- rows=10, choices=3, prompt=1, sep=1 → narr=5
    local rs = d:_backend_handle():snapshot_rows()
    assert.is_truthy(rs[1]:find("Welcome%."))
    assert.is_truthy(rs[6]:find("^%-+"), "row 6 should be the separator: " .. rs[6])
    assert.is_truthy(rs[7]:find("^1%. Run away"))
    assert.is_truthy(rs[8]:find("^2%. Stay put"))
    assert.is_truthy(rs[9]:find("^3%. Investigate"))
  end)

  it("tail-clips narration that exceeds the available rows", function()
    local d = driver_mod.new({ backend = "buffer", rows = 8, cols = 40 })
    local items = {}
    for i = 1, 10 do
      items[i] = { kind = "narration", text = "line " .. i }
    end
    d:render({ narration = items, choices = {} })
    local s = snap(d)
    assert.is_truthy(s:find("line 10"), s)
    assert.is_falsy(s:find("line 1\n") or s:find("^line 1$"),
      "earliest line should have scrolled off-screen")
  end)

  it("clips wide labels to fit the terminal width", function()
    local d = driver_mod.new({ backend = "buffer", rows = 8, cols = 20 })
    d:render({ narration = {},
               choices = { { index = 1, label = string.rep("X", 100) } } })
    local rs = d:_backend_handle():snapshot_rows()
    for i, row in ipairs(rs) do
      assert.equal(20, #row,
        "row " .. (i - 1) .. " width should be exactly cols, got " .. #row)
    end
  end)

  it("inactive prompt shows the quit hint", function()
    local d = driver_mod.new({ backend = "buffer", rows = 10, cols = 60 })
    d:render({ narration = {}, choices = choices })
    local rs = d:_backend_handle():snapshot_rows()
    assert.is_truthy(rs[10]:find("press q or ESC to quit"), rs[10])
  end)

  it("active prompt asks for a choice index", function()
    local d = driver_mod.new({
      backend = "buffer", rows = 10, cols = 60,
      keys    = { string.byte("1") },
    })
    d:render({ narration = {}, choices = choices })
    d:prompt(choices)
    local rs = d:_backend_handle():snapshot_rows()
    assert.is_truthy(rs[10]:find("Choice %(1%-3, q to quit%):"), rs[10])
  end)

  it("detach() releases the backend", function()
    local d = driver_mod.new({ backend = "buffer", rows = 10, cols = 60 })
    d:render({ narration = {}, choices = {} })
    d:detach()
    -- After detach, the screen handle is gone and a subsequent render
    -- re-initialises cleanly.
    assert.is_nil(d:_screen_handle())
  end)
end)

-- ── Driver round-trip on the ncurses backend (stub curses) ─────────

describe("curses driver: round-trip (ncurses stub)", function()
  it("paints narration + choices via stub curses and reads the digit", function()
    local c = fake_curses({ rows = 12, cols = 60, keys = { string.byte("2") } })
    local d = driver_mod.new({ curses = c })
    d:render({ narration = narr_items, choices = choices })
    local idx = d:prompt(choices)
    assert.equal(2, idx)
    local s = c._snapshot()
    assert.is_truthy(s:find("Ghost: Boo!"), s)
    assert.is_truthy(s:find("Choice %(1%-3"), s)
  end)

  it("detach() calls endwin on the ncurses backend", function()
    local c = fake_curses()
    local d = driver_mod.new({ curses = c })
    d:render({ narration = {}, choices = {} })  -- forces init
    d:detach()
    assert.equal(1, c._calls.endwin)
  end)
end)

-- ── Driver-wide invariants ─────────────────────────────────────────

describe("curses driver: protocol + lazy init", function()
  it("satisfies the driver contract (buffer backend)", function()
    local d = driver_mod.new({ backend = "buffer", rows = 10, cols = 20 })
    assert.is_true(protocol.is_driver(d))
  end)

  it("satisfies the driver contract (ncurses stub)", function()
    local d = driver_mod.new({ curses = fake_curses() })
    assert.is_true(protocol.is_driver(d))
  end)

  it("M.new does not touch curses until first render/prompt", function()
    local touched = false
    local sentinel = setmetatable({}, { __index = function() touched = true end })
    local d = driver_mod.new({ curses = sentinel })
    assert.is_table(d)
    assert.is_true(protocol.is_driver(d))
    assert.is_false(touched, "M.new must not call into curses")
  end)

  it("rejects unknown backend names", function()
    assert.has_error(function()
      driver_mod.new({ backend = "carrier-pigeon" })
    end)
  end)

  it("M.is_available probes lcurses availability", function()
    -- Just check the type — the host environment determines the value.
    assert.is_boolean(driver_mod.is_available())
  end)
end)

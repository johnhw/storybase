-- examples/curses_smoketest.lua
--
-- Standalone lcurses capability test. Not linked to the storybase
-- engine or any UI driver — pure exercise of the curses primitives
-- the eventual curses driver (ui_idea.md §M2) will rely on:
--
--   * initscr() + clean endwin() under any exit path
--   * cbreak / noecho / keypad (raw, decoded key input)
--   * newwin() to create separate sub-windows
--   * box() borders + mvaddstr() positioned text
--   * color pairs (when the terminal supports them)
--   * non-blocking getch via win:timeout() — animation-style frame loop
--   * keyname() to translate function/arrow keys into readable labels
--
-- Run it with:
--     lua5.4 examples/curses_smoketest.lua
--
-- Press any keys; they appear in the scrolling log on the right.
-- Press 'q' or ESC to quit. Terminal is restored on every exit path.

local curses = require("curses")

-- ── Geometry ──────────────────────────────────────────────────────────
--
-- Layout (resized at startup to whatever the terminal reports):
--
--   ┌────────────────── title bar ──────────────────┐
--   │ lcurses smoketest 80x24 — q/ESC to quit       │
--   ├──────────────────────┬────────────────────────┤
--   │                      │                        │
--   │  instructions /      │   scrolling key log    │
--   │  static info pane    │   (newest at bottom)   │
--   │                      │                        │
--   ├──────────────────────┴────────────────────────┤
--   │ keys: 0  ticks: 0  last: -                    │
--   └───────────────────────────────────────────────┘

local TITLE_H  = 3
local STATUS_H = 3
local MIN_COLS, MIN_LINES = 50, 14

-- ── State ─────────────────────────────────────────────────────────────

local state = {
  total_keys  = 0,
  total_ticks = 0,
  last_label  = "-",
  log         = {},      -- list of strings; bottom is newest
  log_max     = 0,       -- set after we know the log window height
  running     = true,
}

local function push_log(msg)
  state.log[#state.log + 1] = msg
  while #state.log > state.log_max do
    table.remove(state.log, 1)
  end
end

-- ── Curses lifecycle ──────────────────────────────────────────────────

local stdscr             -- root screen
local win_title          -- title bar window
local win_info           -- left pane: instructions
local win_log            -- right pane: scrolling key log
local win_status         -- bottom status bar

-- ncurses standard color indices. lcurses doesn't re-export the
-- `curses.COLOR_*` names so we use the numeric constants directly.
local C_BLACK, C_RED, C_GREEN, C_YELLOW = 0, 1, 2, 3
local C_BLUE, C_MAGENTA, C_CYAN, C_WHITE = 4, 5, 6, 7

local PAIR_TITLE  = 1
local PAIR_INFO   = 2
local PAIR_LOG    = 3
local PAIR_STATUS = 4
local has_color   = false

local function build_color_pairs()
  if not curses.has_colors() then return end
  curses.start_color()
  curses.init_pair(PAIR_TITLE,  C_BLACK, C_CYAN)
  curses.init_pair(PAIR_INFO,   C_WHITE, C_BLACK)
  curses.init_pair(PAIR_LOG,    C_GREEN, C_BLACK)
  curses.init_pair(PAIR_STATUS, C_BLACK, C_WHITE)
  has_color = true
end

local function fill_window(win, pair_id)
  if has_color and pair_id then win:attron(curses.color_pair(pair_id)) end
  local h, w = win:getmaxyx()
  for y = 0, h - 1 do
    win:mvaddstr(y, 0, string.rep(" ", w - 1))
  end
  if has_color and pair_id then win:attroff(curses.color_pair(pair_id)) end
end

local function init_curses()
  stdscr = curses.initscr()
  curses.cbreak()
  curses.echo(false)
  curses.curs_set(0)        -- hide cursor
  stdscr:keypad(true)       -- decode arrows / function keys
  stdscr:timeout(50)        -- non-blocking getch: ~20fps frame loop

  build_color_pairs()

  local lines, cols = stdscr:getmaxyx()
  if cols < MIN_COLS or lines < MIN_LINES then
    curses.endwin()
    io.stderr:write(string.format(
      "terminal too small: need >= %dx%d, got %dx%d\n",
      MIN_COLS, MIN_LINES, cols, lines))
    os.exit(1)
  end

  local mid_h   = lines - TITLE_H - STATUS_H
  local left_w  = math.floor(cols / 2)
  local right_w = cols - left_w

  win_title  = curses.newwin(TITLE_H,   cols,    0,                    0)
  win_info   = curses.newwin(mid_h,     left_w,  TITLE_H,              0)
  win_log    = curses.newwin(mid_h,     right_w, TITLE_H,              left_w)
  win_status = curses.newwin(STATUS_H,  cols,    TITLE_H + mid_h,      0)

  state.log_max = mid_h - 2  -- minus borders
end

local function shutdown_curses()
  if stdscr and not curses.isendwin() then
    curses.curs_set(1)
    curses.endwin()
  end
end

-- ── Painting ──────────────────────────────────────────────────────────

local function paint_title()
  fill_window(win_title, PAIR_TITLE)
  win_title:box(0, 0)
  local lines, cols = stdscr:getmaxyx()
  local msg = string.format(" lcurses smoketest — %dx%d — q/ESC to quit ",
                            cols, lines)
  win_title:mvaddstr(1, 2, msg)
  win_title:noutrefresh()
end

local function paint_info()
  fill_window(win_info, PAIR_INFO)
  win_info:box(0, 0)
  win_info:mvaddstr(1, 2, "Instructions")
  win_info:mvaddstr(3, 2, "Press any keys.")
  win_info:mvaddstr(4, 2, "Try arrows, F1-F4, Tab, Enter.")
  win_info:mvaddstr(6, 2, "Quit: q or ESC")
  win_info:mvaddstr(8, 2, "Capabilities probed:")
  win_info:mvaddstr(9, 4, "colors:    " .. tostring(curses.has_colors()))
  win_info:mvaddstr(10, 4, "max pairs: " .. tostring(curses.color_pairs()))
  win_info:mvaddstr(11, 4, "term:      " .. tostring(curses.termname()))
  win_info:noutrefresh()
end

local function paint_log()
  fill_window(win_log, PAIR_LOG)
  win_log:box(0, 0)
  win_log:mvaddstr(1, 2, "Key log (newest at bottom)")
  local h, w = win_log:getmaxyx()
  local first = math.max(1, #state.log - (h - 3) + 1)
  local row = 2
  for i = first, #state.log do
    local line = state.log[i]
    if #line > w - 4 then line = line:sub(1, w - 4) end
    win_log:mvaddstr(row, 2, line)
    row = row + 1
  end
  win_log:noutrefresh()
end

local function paint_status()
  fill_window(win_status, PAIR_STATUS)
  win_status:box(0, 0)
  local msg = string.format(" keys: %d   ticks: %d   last: %s ",
                            state.total_keys, state.total_ticks,
                            state.last_label)
  win_status:mvaddstr(1, 2, msg)
  win_status:noutrefresh()
end

local function paint_all()
  paint_title()
  paint_info()
  paint_log()
  paint_status()
  curses.doupdate()
end

-- ── Input ─────────────────────────────────────────────────────────────

local KEY_ESC = 27

local function describe_key(key)
  -- keyname() handles printable + most KEY_* codes, but returns nil
  -- for some control bytes. Fall back to a numeric label so the log
  -- is never empty.
  local name = curses.keyname(key)
  if name and name ~= "" then return name end
  if key >= 32 and key < 127 then
    return string.format("'%s' (%d)", string.char(key), key)
  end
  return string.format("#%d", key)
end

local function handle_key(key)
  state.total_keys = state.total_keys + 1
  local label = describe_key(key)
  state.last_label = label
  push_log(string.format("[%04d] %s", state.total_keys, label))

  -- Quit conditions: q, Q, ESC.
  if key == KEY_ESC then state.running = false end
  if key == string.byte("q") or key == string.byte("Q") then
    state.running = false
  end
end

-- ── Main loop ─────────────────────────────────────────────────────────

local function main_loop()
  push_log("ready — press a key")
  paint_all()
  while state.running do
    local key = stdscr:getch()
    state.total_ticks = state.total_ticks + 1
    if key and key ~= -1 then handle_key(key) end
    paint_all()
  end
end

-- ── Crash-safe entry point ────────────────────────────────────────────

local ok, err = xpcall(function()
  init_curses()
  main_loop()
end, debug.traceback)

shutdown_curses()

if not ok then
  io.stderr:write("curses_smoketest crashed:\n", tostring(err), "\n")
  os.exit(1)
end

io.stdout:write(string.format(
  "smoketest ok — %d keys over %d ticks, last: %s\n",
  state.total_keys, state.total_ticks, state.last_label))

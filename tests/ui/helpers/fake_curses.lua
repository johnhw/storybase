-- tests/ui/helpers/fake_curses.lua
--
-- Shared stub of the `curses` (lcurses) module for headless tests.
--
-- Returns a fake whose surface matches the slice of lcurses that
-- `cli/drivers/curses/backend_curses.lua` actually consumes:
--
--   initscr / cbreak / echo / curs_set / endwin / isendwin
--   stdscr:keypad / getmaxyx / refresh / mvaddstr / getch
--
-- The fake captures lifecycle calls and maintains a deterministic 2D
-- character grid that tests can snapshot. Two introspection helpers
-- are exposed (prefixed `_` so they cannot collide with real lcurses):
--
--   fake._calls         -- lifecycle counters (initscr/cbreak/etc.)
--   fake._stdscr        -- the fake stdscr (with `_calls` + `_grid`)
--   fake._snapshot()    -- full grid as newline-joined string (trimmed)
--   fake._snapshot_row(y) -- single row (0-based, trimmed)
--   fake._end_called()  -- has endwin fired?
--
-- Used by `tests/ui/curses_driver_spec.lua` and (later) M5+ widget
-- specs that need to exercise the ncurses backend path without a TTY.

local M = {}

--- Build a fake `curses` module.
---@param opts table?  { rows?, cols?, keys? }
---@return table fake
function M.new(opts)
  opts = opts or {}
  local rows = opts.rows or 24
  local cols = opts.cols or 80
  local keys = opts.keys or {}
  local key_idx = 0

  local calls = {
    initscr  = 0,
    cbreak   = 0,
    echo     = 0,
    curs_set = {},
    endwin   = 0,
  }
  local end_called = false

  local stdscr = {
    _grid = {},
    _calls = { keypad = 0, refresh = 0, mvaddstr = {} },
  }

  function stdscr:keypad(_v)
    self._calls.keypad = self._calls.keypad + 1
  end
  function stdscr:getmaxyx() return rows, cols end
  function stdscr:refresh()
    self._calls.refresh = self._calls.refresh + 1
  end
  function stdscr:mvaddstr(y, x, s)
    self._calls.mvaddstr[#self._calls.mvaddstr + 1] = { y = y, x = x, s = s }
    local row = self._grid[y]
    if not row then
      row = string.rep(" ", cols)
    end
    if x < 0 or x >= cols then return end
    if x + #s > cols then s = s:sub(1, cols - x) end
    local prefix = row:sub(1, x)
    local suffix = row:sub(x + #s + 1)
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

  fake._calls = calls
  fake._stdscr = stdscr
  fake._snapshot = function()
    local lines = {}
    for y = 0, rows - 1 do
      lines[#lines + 1] = (stdscr._grid[y] or string.rep(" ", cols)):gsub(" +$", "")
    end
    return table.concat(lines, "\n")
  end
  fake._snapshot_row = function(y)
    return (stdscr._grid[y] or string.rep(" ", cols)):gsub(" +$", "")
  end
  fake._end_called = function() return end_called end

  return fake
end

return M

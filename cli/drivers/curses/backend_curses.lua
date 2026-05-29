-- cli/drivers/curses/backend_curses.lua
--
-- ncurses backend for the curses driver (ui_idea.md §8.2). This is the
-- **only** file in the project that calls `require("curses")` — every
-- other curses-driver module talks to this backend via the M3 interface.
--
-- M3 backend interface:
--
--   M.is_available()                  -> bool
--   M.new(opts)                       -> backend
--   backend:init(rows?, cols?)        -> ok, reason?         -- starts ncurses
--   backend:size()                    -> rows, cols          -- terminal size
--   backend:flush(screen, dirty_rects) -- paint dirty cells, refresh
--   backend:read_key()                -> int | nil           -- one getch
--   backend:close()                                          -- endwin
--
-- The `rows, cols` arguments to `init` are advisory; ncurses always
-- reports the real terminal size via `stdscr:getmaxyx()`. The driver
-- still passes them so the buffer backend (which is fixed-size) sees
-- the same interface.
--
-- Tests inject a stub `curses` module via `opts.curses`. See
-- `tests/ui/curses_driver_spec.lua` and `tests/ui/curses_screen_spec.lua`.

local M = {}

--- Probe lcurses availability without binding to it. Falls back path
--- for callers that want to detect the missing-package case before the
--- driver tries `init` (e.g. CLI argument validation).
---@return boolean
function M.is_available()
  local ok = pcall(require, "curses")
  return ok
end

--- Construct a new backend instance. Does not touch ncurses; that
--- happens on `init`. Tests can inject a stub via `opts.curses`.
---@param opts table?  { curses = <module>? }
---@return table backend
function M.new(opts)
  opts = opts or {}

  local backend = {
    _curses = opts.curses,  -- resolved lazily if nil
    _stdscr = nil,
    _active = false,
  }

  --- Resolve and cache the curses module. Returns nil if not loadable.
  local function resolve_curses()
    if backend._curses then return backend._curses end
    local ok, mod = pcall(require, "curses")
    if not ok then return nil end
    backend._curses = mod
    return mod
  end

  --- Initialise ncurses. The `_rows`/`_cols` arguments are accepted for
  --- interface symmetry with backend_buffer; ncurses reads the real
  --- terminal size via `stdscr:getmaxyx()`.
  ---@param _rows integer?
  ---@param _cols integer?
  ---@return boolean ok
  ---@return string? reason
  function backend:init(_rows, _cols)
    if self._active then return true end
    local curses = resolve_curses()
    if not curses then
      return false, "lcurses module not available"
    end
    self._stdscr = curses.initscr()
    pcall(function() curses.cbreak() end)
    pcall(function() curses.echo(false) end)
    pcall(function() curses.curs_set(0) end)
    if self._stdscr and self._stdscr.keypad then
      pcall(function() self._stdscr:keypad(true) end)
    end
    self._active = true
    return true
  end

  --- Report the terminal size as `(rows, cols)`. Returns (0, 0) when
  --- not yet initialised so callers can drive their own fallback.
  ---@return integer rows
  ---@return integer cols
  function backend:size()
    if not self._active or not self._stdscr then return 0, 0 end
    return self._stdscr:getmaxyx()
  end

  --- Flush a list of dirty rects from a screen to ncurses. Each rect
  --- is a {y, x, cells} record; cells are emitted via `mvaddstr` as a
  --- contiguous span. Calls `refresh()` once after all spans paint.
  ---@param _scr  table         screen (unused beyond the rect list)
  ---@param rects table[]
  function backend:flush(_scr, rects)
    if not self._active or not self._stdscr then return end
    if not rects or #rects == 0 then
      -- No-op idle frame; still call refresh so cursor positioning
      -- stays correct.
      self._stdscr:refresh()
      return
    end
    for i = 1, #rects do
      local r = rects[i]
      local s = {}
      for j = 1, #r.cells do s[j] = r.cells[j].ch or " " end
      pcall(function() self._stdscr:mvaddstr(r.y, r.x, table.concat(s)) end)
    end
    self._stdscr:refresh()
  end

  --- One blocking `getch`. Returns the integer key code, or nil on EOF
  --- / window closure. The driver translates this into choice digits,
  --- quit keys, navigation, etc.
  ---@return integer? key
  function backend:read_key()
    if not self._active or not self._stdscr then return nil end
    local key = self._stdscr:getch()
    if not key or key == -1 then return nil end
    return key
  end

  --- Restore the terminal. Idempotent — safe to call multiple times.
  function backend:close()
    if not self._active then return end
    local curses = self._curses
    if curses then
      local ended = curses.isendwin and curses.isendwin()
      if not ended then
        pcall(function() curses.curs_set(1) end)
        pcall(function() curses.endwin() end)
      end
    end
    self._active = false
  end

  return backend
end

return M

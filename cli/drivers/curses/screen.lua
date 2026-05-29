-- cli/drivers/curses/screen.lua
--
-- Retained 2D cell grid + window model shared by the ncurses and buffer
-- backends. See ui_idea.md §8.1 ("Screen model").
--
-- A screen owns a (rows × cols) grid of cells. Drivers allocate windows
-- on the screen; widgets paint into windows; the painter (paint.lua)
-- diffs the current frame against the previous frame to produce a list
-- of dirty rects which the backend then flushes.
--
-- Cell shape:
--   { ch = string,  -- single-character glyph (default " ")
--     fg = string,  -- foreground colour name or nil
--     bg = string,  -- background colour name or nil
--     attrs = string?, -- comma-separated "bold,reverse,underline" or nil
--   }
--
-- Windows are positioned in screen coordinates (0-based y/x) with width
-- and height. Compositing is z-ordered (higher z paints on top) so
-- §M6's modal dialog drops in naturally.
--
-- This module is **driver-agnostic**: it never calls into ncurses or
-- IO. Backends consume the resulting grid via `screen:cells_at(y, x)`
-- and the dirty list returned by paint.lua.

local M = {}

--- Construct a blank cell. Always returns a fresh table.
---@return table
local function blank_cell()
  return { ch = " ", fg = nil, bg = nil, attrs = nil }
end

--- Allocate a rows × cols grid of blank cells.
---@param rows integer
---@param cols integer
---@return table
local function alloc_grid(rows, cols)
  local g = {}
  for y = 0, rows - 1 do
    local row = {}
    for x = 0, cols - 1 do row[x] = blank_cell() end
    g[y] = row
  end
  return g
end

--- Are two cells visually identical? Compared field-by-field so the
--- paint diff stays cheap (no tostring round-trips).
---@param a table?
---@param b table?
---@return boolean
function M.cells_equal(a, b)
  if a == b then return true end
  if not a or not b then return false end
  return a.ch == b.ch
     and a.fg == b.fg
     and a.bg == b.bg
     and a.attrs == b.attrs
end

--- Construct a new screen of the given size. The screen owns two grids:
--- `_cells` (the next-frame target windows paint into) and `_prev`
--- (the last frame the backend flushed). Backends compare against
--- `_prev` via paint.diff and update it after flush via `screen:commit()`.
---@param rows integer
---@param cols integer
---@return table screen
function M.new(rows, cols)
  assert(type(rows) == "number" and rows > 0, "rows must be a positive integer")
  assert(type(cols) == "number" and cols > 0, "cols must be a positive integer")

  local self = {
    rows    = rows,
    cols    = cols,
    _cells  = alloc_grid(rows, cols),
    _prev   = alloc_grid(rows, cols),
    _windows = {},  -- ordered by insertion; flush composes by z asc.
  }

  --- Replace the cell at (y, x) if in-bounds. No-op otherwise.
  ---@param y integer
  ---@param x integer
  ---@param cell table
  function self:set_cell(y, x, cell)
    if y < 0 or y >= self.rows or x < 0 or x >= self.cols then return end
    self._cells[y][x] = cell
  end

  --- Read the cell at (y, x) on the current frame. Returns nil if oob.
  ---@param y integer
  ---@param x integer
  ---@return table?
  function self:get_cell(y, x)
    if y < 0 or y >= self.rows or x < 0 or x >= self.cols then return nil end
    return self._cells[y][x]
  end

  --- Reset the current frame to blank cells. Windows must repaint after.
  function self:clear()
    self._cells = alloc_grid(self.rows, self.cols)
  end

  --- Allocate a window on the screen. Window cells are screen-local
  --- (the window owns no cells of its own — painting blits directly).
  --- Returns the window descriptor; callers use `screen:write(win, ...)`
  --- to paint into it.
  ---@param spec table  { x, y, w, h, z?, title? }
  ---@return table window
  function self:add_window(spec)
    local win = {
      x     = spec.x or 0,
      y     = spec.y or 0,
      w     = spec.w or self.cols,
      h     = spec.h or self.rows,
      z     = spec.z or 0,
      title = spec.title,
    }
    self._windows[#self._windows + 1] = win
    return win
  end

  --- Remove all windows. Used when the layout needs to be recomputed
  --- (e.g. on resize).
  function self:clear_windows()
    self._windows = {}
  end

  --- Paint a single character into a window at window-local (wy, wx).
  --- Out-of-window coordinates are clipped silently.
  ---@param win table        a window returned from add_window
  ---@param wy integer       window-local row
  ---@param wx integer       window-local column
  ---@param ch string        one-character glyph
  ---@param attrs table?     { fg?, bg?, attrs? }
  function self:paint_char(win, wy, wx, ch, attrs)
    if wy < 0 or wy >= win.h or wx < 0 or wx >= win.w then return end
    local sy, sx = win.y + wy, win.x + wx
    if sy < 0 or sy >= self.rows or sx < 0 or sx >= self.cols then return end
    local cell = {
      ch    = ch,
      fg    = attrs and attrs.fg or nil,
      bg    = attrs and attrs.bg or nil,
      attrs = attrs and attrs.attrs or nil,
    }
    self._cells[sy][sx] = cell
  end

  --- Paint a string into a window starting at window-local (wy, wx).
  --- Clipped on the right edge of the window and on the right edge of
  --- the screen. Multi-byte sequences are treated as bytes (StoryBase
  --- narration is ASCII today; revisit when UTF-8 support is wanted).
  ---@param win table
  ---@param wy integer
  ---@param wx integer
  ---@param s string
  ---@param attrs table?
  function self:write(win, wy, wx, s, attrs)
    if wy < 0 or wy >= win.h then return end
    local max_x = math.min(win.w, self.cols - win.x)
    for i = 1, #s do
      local x = wx + (i - 1)
      if x >= max_x then break end
      self:paint_char(win, wy, x, s:sub(i, i), attrs)
    end
  end

  --- Fill a rectangle of the window with `ch`. Convenient for
  --- separator bars and blanking out a panel.
  ---@param win table
  ---@param wy integer
  ---@param wx integer
  ---@param w integer
  ---@param h integer
  ---@param ch string
  ---@param attrs table?
  function self:fill(win, wy, wx, w, h, ch, attrs)
    for dy = 0, h - 1 do
      for dx = 0, w - 1 do
        self:paint_char(win, wy + dy, wx + dx, ch, attrs)
      end
    end
  end

  --- Move `_cells` into `_prev` after a backend has flushed the frame.
  --- The next frame starts from a fresh blank grid that windows repaint.
  function self:commit()
    self._prev = self._cells
    self._cells = alloc_grid(self.rows, self.cols)
  end

  --- Force the next diff to treat every cell as dirty (used after a
  --- terminal resize or when the backend needs to repaint from scratch).
  function self:invalidate()
    self._prev = alloc_grid(self.rows, self.cols)
    -- Set every prev cell to a sentinel so cells_equal returns false.
    for y = 0, self.rows - 1 do
      for x = 0, self.cols - 1 do
        self._prev[y][x] = { ch = "\0" }
      end
    end
  end

  --- Return the current frame as an array of strings, one per row.
  --- Used by backend_buffer for `snapshot()` and by tests for golden
  --- diffs. Trailing spaces on each row are preserved.
  ---@return string[]
  function self:as_lines()
    local out = {}
    for y = 0, self.rows - 1 do
      local row = self._cells[y]
      local chs = {}
      for x = 0, self.cols - 1 do
        chs[#chs + 1] = (row[x] and row[x].ch) or " "
      end
      out[y + 1] = table.concat(chs)
    end
    return out
  end

  return self
end

return M

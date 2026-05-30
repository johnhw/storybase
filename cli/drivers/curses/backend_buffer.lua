-- cli/drivers/curses/backend_buffer.lua
--
-- String-buffer backend for the curses driver (ui_idea.md §8.2). Has the
-- same interface as `backend_curses.lua` but renders into an in-memory
-- (rows × cols) cell grid instead of an ncurses surface. Two uses:
--
--   1. **Tests** — busted runs without a TTY; specs paint into this
--      backend and snapshot `backend:snapshot()` against golden text.
--   2. **Fallback** — when `lcurses` isn't installed the CLI can still
--      drive the curses driver against this backend (no live painting,
--      but the layout pipeline is exercised end-to-end).
--
-- M3 backend interface:
--
--   M.new(opts)                       -> backend
--   backend:init(rows, cols)          -> ok, reason?
--   backend:size()                    -> rows, cols
--   backend:flush(screen, dirty_rects) -- updates the internal grid
--   backend:read_key()                -> int | nil
--   backend:close()
--
-- Extras specific to the buffer backend (driver-private):
--
--   backend:snapshot()         -> string           -- newline-joined rows,
--                                                     trailing spaces trimmed
--   backend:snapshot_rows()    -> string[]         -- per-row strings, raw
--   backend:script_keys(ks)                        -- enqueue keys for read_key
--   backend:snapshot_history() -> string[]         -- one snapshot per flush
--                                                     (opt-in; see frame_history)
--   backend:dirty_history()    -> table[][]        -- per-flush dirty rects
--   backend:reset_history()                        -- drop history buffers
--
-- Opt-in `frame_history`: pass `frame_history = true` to `M.new` (or
-- via the driver's `opts.frame_history`). When enabled, each `flush()`
-- pushes a `snapshot()` row-string and a deep copy of the dirty-rect
-- list onto private history buffers. Used by §M5 widget tests that
-- need to assert "frame N-1 had X, frame N has Y, dirty rects between
-- them were just the bar window" (ui_idea.md §9.1 item 2).
--
-- Stored cell shape matches `screen.lua`: `{ ch, fg, bg, attrs }`. The
-- buffer is allocated at init and resized on subsequent init() calls.

local M = {}

--- Construct a new buffer backend.
---@param opts table?  { rows?, cols?, keys?, frame_history? }
---     rows / cols   : initial buffer size if init() is not called explicitly
---     keys          : initial key queue
---     frame_history : record per-flush snapshot + dirty rects (opt-in)
---@return table backend
function M.new(opts)
  opts = opts or {}

  local backend = {
    _rows           = opts.rows or 0,
    _cols           = opts.cols or 0,
    _grid           = {},
    _active         = false,
    _keys           = {},
    _key_idx        = 0,
    _frame_history  = opts.frame_history and true or false,
    _hist_snapshots = {},
    _hist_dirty     = {},
  }

  if opts.keys then
    for i = 1, #opts.keys do backend._keys[i] = opts.keys[i] end
  end

  local function alloc(rows, cols)
    local g = {}
    for y = 0, rows - 1 do
      local row = {}
      for x = 0, cols - 1 do
        row[x] = { ch = " " }
      end
      g[y] = row
    end
    return g
  end

  --- Allocate / resize the underlying cell grid. Returns ok, reason?.
  ---@param rows integer
  ---@param cols integer
  ---@return boolean ok
  function backend:init(rows, cols)
    rows = rows or self._rows or 24
    cols = cols or self._cols or 80
    if rows <= 0 or cols <= 0 then
      return false, "buffer backend needs positive rows/cols"
    end
    self._rows = rows
    self._cols = cols
    self._grid = alloc(rows, cols)
    self._active = true
    return true
  end

  --- Report the backing buffer's size.
  ---@return integer rows
  ---@return integer cols
  function backend:size() return self._rows, self._cols end

  --- Apply a list of dirty rects to the buffer. The screen argument is
  --- accepted for interface symmetry but not consulted; rects are
  --- self-describing.
  ---@param _scr table?
  ---@param rects table[]
  function backend:flush(_scr, rects)
    if not self._active then return end
    if not rects then return end
    for i = 1, #rects do
      local r = rects[i]
      local row = self._grid[r.y]
      if row then
        for j = 1, #r.cells do
          local x = r.x + (j - 1)
          if x >= 0 and x < self._cols then
            row[x] = r.cells[j]
          end
        end
      end
    end
    -- Record per-flush snapshot + dirty rects when enabled. Snapshot
    -- after the rects have been applied so frame N's snapshot reflects
    -- frame N's contents. Dirty rects are shallow-copied (cell tables
    -- are immutable per paint.diff's contract).
    if self._frame_history then
      self._hist_snapshots[#self._hist_snapshots + 1] = self:snapshot()
      local rect_copy = {}
      for i = 1, #rects do
        local r = rects[i]
        local cells = {}
        for j = 1, #r.cells do cells[j] = r.cells[j] end
        rect_copy[i] = { y = r.y, x = r.x, cells = cells }
      end
      self._hist_dirty[#self._hist_dirty + 1] = rect_copy
    end
  end

  --- Enqueue a sequence of keys for subsequent `read_key()` calls.
  --- Strings are converted character-by-character to byte codes;
  --- integers pass through as raw key codes (KEY_UP, KEY_F1, etc.).
  --- Replaces any existing queue.
  ---@param keys table  array of strings and/or integers
  function backend:script_keys(keys)
    self._keys = {}
    self._key_idx = 0
    for _, k in ipairs(keys or {}) do
      if type(k) == "string" then
        for i = 1, #k do
          self._keys[#self._keys + 1] = k:byte(i)
        end
      else
        self._keys[#self._keys + 1] = k
      end
    end
  end

  --- Return the next scripted key, or nil if the queue is exhausted.
  ---@return integer? key
  function backend:read_key()
    self._key_idx = self._key_idx + 1
    return self._keys[self._key_idx]
  end

  --- Tear down the buffer. Idempotent.
  function backend:close()
    self._active = false
  end

  --- Return the buffer as a single newline-joined string. Trailing
  --- spaces on each row are trimmed so golden snapshots remain compact.
  ---@return string
  function backend:snapshot()
    local rows = self:snapshot_rows()
    local trimmed = {}
    for i = 1, #rows do
      trimmed[i] = rows[i]:gsub(" +$", "")
    end
    return table.concat(trimmed, "\n")
  end

  --- Return the buffer as an array of raw row strings (no trimming).
  --- Useful when tests need to assert exact width.
  ---@return string[]
  function backend:snapshot_rows()
    local out = {}
    for y = 0, self._rows - 1 do
      local row = self._grid[y]
      if row then
        local chs = {}
        for x = 0, self._cols - 1 do
          chs[#chs + 1] = (row[x] and row[x].ch) or " "
        end
        out[y + 1] = table.concat(chs)
      else
        out[y + 1] = string.rep(" ", self._cols)
      end
    end
    return out
  end

  --- Frame snapshot history (one entry per `flush` call). Empty unless
  --- `frame_history = true` was passed to `M.new`.
  ---@return string[]
  function backend:snapshot_history()
    local out = {}
    for i = 1, #self._hist_snapshots do out[i] = self._hist_snapshots[i] end
    return out
  end

  --- Per-flush dirty-rect history. Each entry is a deep-copied list of
  --- `{y, x, cells}` records produced by `paint.diff` for that frame.
  ---@return table[][]
  function backend:dirty_history()
    local out = {}
    for i = 1, #self._hist_dirty do
      local src = self._hist_dirty[i]
      local copy = {}
      for j = 1, #src do
        local r = src[j]
        local cells = {}
        for k = 1, #r.cells do cells[k] = r.cells[k] end
        copy[j] = { y = r.y, x = r.x, cells = cells }
      end
      out[i] = copy
    end
    return out
  end

  --- Drop both history buffers. Useful to slice a session into
  --- "before mutation" vs "after mutation" episodes.
  function backend:reset_history()
    self._hist_snapshots = {}
    self._hist_dirty     = {}
  end

  return backend
end

return M

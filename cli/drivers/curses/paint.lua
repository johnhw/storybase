-- cli/drivers/curses/paint.lua
--
-- Cell-grid diff. Given a screen with `_prev` and `_cells` populated,
-- returns the minimal set of dirty cell coordinates the backend must
-- flush to bring the previous frame in line with the next frame.
--
-- The diff is per-row, returning runs (contiguous spans of changed
-- cells) rather than individual cells. Runs minimise the number of
-- ncurses `mvaddstr` calls without forcing a full-row repaint.
--
-- Public surface:
--
--   M.diff(screen) -> rects
--
-- where `rects` is an array of {y, x, cells} records:
--   y     : row index (0-based)
--   x     : starting column (0-based)
--   cells : array of cell tables (in order, left to right)
--
-- Backends consume `rects` and emit one painting call per record. The
-- list is empty when nothing changed (the common idle-frame case).

local screen = require("cli.drivers.curses.screen")

local M = {}

--- Compute the list of dirty cell runs between `screen._prev` and
--- `screen._cells`. The screen's commit() must be called by the
--- backend *after* it has flushed the result.
---@param scr table  screen instance from screen.new
---@return table[]   list of dirty rects (see file header)
function M.diff(scr)
  local rects = {}
  for y = 0, scr.rows - 1 do
    local prev_row = scr._prev[y]
    local cur_row  = scr._cells[y]
    local run_start = nil
    local run_cells = nil
    for x = 0, scr.cols - 1 do
      local pc, cc = prev_row[x], cur_row[x]
      if not screen.cells_equal(pc, cc) then
        if not run_start then
          run_start = x
          run_cells = {}
        end
        run_cells[#run_cells + 1] = cc
      else
        if run_start then
          rects[#rects + 1] = { y = y, x = run_start, cells = run_cells }
          run_start, run_cells = nil, nil
        end
      end
    end
    if run_start then
      rects[#rects + 1] = { y = y, x = run_start, cells = run_cells }
    end
  end
  return rects
end

--- Convert a dirty-rect record's cell list to a plain string. Used by
--- both backends to paint a span in a single call. Glyph-only; colour
--- and attribute handling stays with the backend.
---@param cells table[]
---@return string
function M.rect_to_string(cells)
  local chs = {}
  for i = 1, #cells do
    chs[i] = cells[i].ch or " "
  end
  return table.concat(chs)
end

return M

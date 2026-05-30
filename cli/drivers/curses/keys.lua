-- cli/drivers/curses/keys.lua
--
-- Shared integer key-code constants for the curses driver's widgets and
-- tests. The backend (`backend_curses` / `backend_buffer`) hands keys
-- through as raw integers from `getch()`; this table is the one place
-- that names them.
--
-- The numeric values match ncurses (and therefore lcurses) `KEY_*`
-- constants — they're stable across platforms and standardised by the
-- ncurses headers. We hard-code the integers rather than reading them
-- from the `curses` module because lcurses does not expose `KEY_UP`
-- and friends as table fields (they're only ever returned from
-- `getch()`), so a header-style lookup is the only portable option.
--
-- Widgets that want to allow author customisation accept a key-binding
-- table that defaults to entries from here. See `widgets/menu.lua` and
-- `widgets/input.lua` for the pattern.

local M = {}

-- Control codes (ASCII).
M.ESC       = 27
M.TAB       = 9
M.CR        = 13     -- Enter on most terminals (carriage return)
M.LF        = 10     -- Enter on some terminals (line feed)
M.BS        = 8      -- Ctrl-H / classic backspace
M.DEL       = 127    -- DEL — what most modern terminals send for Backspace
M.SPACE     = 32

-- ncurses KEY_* (see /usr/include/ncurses.h). Stable values.
M.KEY_DOWN      = 258
M.KEY_UP        = 259
M.KEY_LEFT      = 260
M.KEY_RIGHT     = 261
M.KEY_HOME      = 262
M.KEY_BACKSPACE = 263
M.KEY_F1        = 265
M.KEY_F2        = 266
M.KEY_F3        = 267
M.KEY_F4        = 268
M.KEY_DC        = 330  -- Delete
M.KEY_IC        = 331  -- Insert
M.KEY_NPAGE     = 338  -- Page Down
M.KEY_PPAGE     = 339  -- Page Up
M.KEY_END       = 360
M.KEY_ENTER     = 343  -- numeric keypad Enter (most terminals send CR instead)

-- Convenience predicates ----------------------------------------------------

--- True iff `key` is one of the conventional "submit/activate" codes:
--- CR, LF, or KEY_ENTER. Widgets accepting Enter should use this so the
--- difference between terminal types doesn't leak into widget code.
---@param key any
---@return boolean
function M.is_enter(key)
  return key == M.CR or key == M.LF or key == M.KEY_ENTER
end

--- True iff `key` is one of the conventional "delete previous char" codes:
--- BS, DEL, or KEY_BACKSPACE. Mac terminals send DEL (127), Linux
--- consoles send BS (8), lcurses with `keypad(true)` sends KEY_BACKSPACE.
---@param key any
---@return boolean
function M.is_backspace(key)
  return key == M.BS or key == M.DEL or key == M.KEY_BACKSPACE
end

--- True iff `key` is a printable ASCII byte (space through tilde). Used
--- by the input widget to decide whether to append a character to its
--- buffer.
---@param key any
---@return boolean
function M.is_printable(key)
  return type(key) == "number" and key >= 32 and key <= 126
end

return M

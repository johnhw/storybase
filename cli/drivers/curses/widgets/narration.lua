-- cli/drivers/curses/widgets/narration.lua
--
-- Scrollable narration pane widget (ui_idea.md §5.3 + §M8). Closes out
-- the "always-present" narration kind from the §5.3 widget vocabulary:
-- where the curses driver's base compose paints a bottom-aligned tail of
-- the engine's scrollback into a fixed window, this widget gives authors
-- (and the driver's own future scrollback mode) an addressable scrollable
-- view of an arbitrary line buffer.
--
-- Owns its own line list: callers feed strings via `append` / `extend` /
-- `clear`. Paint writes the lines into a driver-allocated window with a
-- scroll offset; on_key (when on the focus stack) supports PgUp/PgDn,
-- Up/Down, Home/End. The bottom of the buffer is treated as the natural
-- resting position (`stick_to_bottom = true` by default) so newly
-- appended lines push older ones up — exactly like the base scrollback.
--
-- Wiring:
--   * `M.new{ lines?, max_lines?, stick_to_bottom? }` returns the widget.
--   * `widget:append(line)` / `widget:extend({l1, l2, ...})` / `widget:clear()`
--     mutate the buffer; the next paint reflects the new tail.
--   * `widget:paint(screen, win, kernel?)` writes into a driver-allocated
--     window. Like statbar, the kernel arg is optional — the narration
--     pane stays usable with no kernel attached.
--   * `widget:on_key(key, driver?)` handles scrollback keys when on the
--     focus stack; returns true iff consumed.

local keys_mod = require("cli.drivers.curses.keys")

local M = {}

--- Construct a narration pane widget.
---@param opts table  {
---   lines           : initial list of lines (default {})
---   max_lines       : optional cap; older lines drop off the front
---   stick_to_bottom : when true (default), the next paint shows the
---                     buffer tail; when false, the scroll offset is
---                     preserved across mutations so the reader can pin
---                     the view.
---   border          : draw an ASCII border around the pane (default false)
---   title           : optional title shown on the top border (border only)
--- }
---@return table widget
function M.new(opts)
  opts = opts or {}
  local self = {
    kind            = "narration",
    _lines          = {},
    max_lines       = opts.max_lines,
    stick_to_bottom = opts.stick_to_bottom ~= false,  -- default true
    border          = opts.border or false,
    title           = opts.title,
    _scroll         = 0,  -- index of the first visible line (0-based);
                          -- meaningful only when stick_to_bottom = false
  }

  -- Seed initial buffer from opts.lines.
  if type(opts.lines) == "table" then
    for i = 1, #opts.lines do self._lines[i] = tostring(opts.lines[i] or "") end
  end

  --- Drop oldest lines so the buffer fits inside `max_lines`. No-op if
  --- max_lines is unset.
  local function trim_buffer(self)
    if not self.max_lines then return end
    while #self._lines > self.max_lines do
      table.remove(self._lines, 1)
    end
  end

  --- Append one line to the buffer.
  ---@param line string
  function self:append(line)
    self._lines[#self._lines + 1] = tostring(line or "")
    trim_buffer(self)
  end

  --- Append many lines at once (faster than calling `append` in a loop
  --- because the trim runs only once at the end).
  ---@param lines string[]
  function self:extend(lines)
    for i = 1, #(lines or {}) do
      self._lines[#self._lines + 1] = tostring(lines[i] or "")
    end
    trim_buffer(self)
  end

  --- Drop every line.
  function self:clear() self._lines = {}; self._scroll = 0 end

  --- Number of lines currently in the buffer.
  ---@return integer
  function self:size() return #self._lines end

  --- Read-only snapshot of the buffer (useful for tests).
  ---@return string[]
  function self:lines()
    local out = {}
    for i = 1, #self._lines do out[i] = self._lines[i] end
    return out
  end

  --- Scroll by `delta` lines (negative = up). Disables stick_to_bottom
  --- as soon as the user pages up — pages back to the tail will re-enable
  --- it. Clamps to [0, max(0, #lines - body_h)] where body_h is the
  --- height of the body region as measured during the last paint.
  ---@param delta integer
  function self:scroll(delta)
    local body_h = self._last_body_h or 1
    local max_scroll = math.max(0, #self._lines - body_h)
    local at_bottom = self._scroll >= max_scroll
    if self.stick_to_bottom and at_bottom and delta >= 0 then return end

    local new_scroll = self._scroll + delta
    if new_scroll < 0 then new_scroll = 0 end
    if new_scroll > max_scroll then new_scroll = max_scroll end
    self._scroll = new_scroll
    self.stick_to_bottom = (new_scroll == max_scroll)
  end

  --- Jump to the first / last line. `to_end = true` parks at the tail
  --- and re-enables stick_to_bottom; `to_end = false` jumps to the top.
  ---@param to_end boolean
  function self:scroll_to(to_end)
    if to_end then
      local body_h = self._last_body_h or 1
      self._scroll = math.max(0, #self._lines - body_h)
      self.stick_to_bottom = true
    else
      self._scroll = 0
      self.stick_to_bottom = false
    end
  end

  --- Paint into a driver-allocated window. Border (when enabled) eats
  --- two rows / two cols; the body region scrolls inside. Long lines
  --- are clipped on the right edge of the inner window.
  ---@param screen table
  ---@param win    table
  ---@param _kernel table?
  function self:paint(screen, win, _kernel)
    if not win or win.h < 1 or win.w < 1 then return end
    screen:fill(win, 0, 0, win.w, win.h, " ")

    local bo = self.border and 1 or 0
    local inner_w = win.w - 2 * bo
    local body_h  = win.h - 2 * bo
    if inner_w < 1 or body_h < 1 then return end
    self._last_body_h = body_h

    if self.border then
      screen:write(win, 0, 0,         "+")
      screen:write(win, 0, win.w - 1, "+")
      screen:write(win, win.h - 1, 0,         "+")
      screen:write(win, win.h - 1, win.w - 1, "+")
      if win.w > 2 then
        screen:fill(win, 0,         1, win.w - 2, 1, "-")
        screen:fill(win, win.h - 1, 1, win.w - 2, 1, "-")
      end
      if win.h > 2 then
        screen:fill(win, 1, 0,         1, win.h - 2, "|")
        screen:fill(win, 1, win.w - 1, 1, win.h - 2, "|")
      end
      if self.title and win.w >= 6 then
        local tag = " " .. self.title .. " "
        local max_tag = win.w - 4
        if #tag > max_tag then tag = tag:sub(1, max_tag) end
        screen:write(win, 0, 2, tag)
      end
    end

    if self.stick_to_bottom then
      self._scroll = math.max(0, #self._lines - body_h)
    end
    if self._scroll > math.max(0, #self._lines - body_h) then
      self._scroll = math.max(0, #self._lines - body_h)
    end

    for row = 0, body_h - 1 do
      local idx = self._scroll + row + 1
      local line = self._lines[idx]
      if line == nil then break end
      if #line > inner_w then line = line:sub(1, inner_w) end
      screen:write(win, bo + row, bo, line)
    end
  end

  --- Optional focus-stack handler. Up/Down scroll one line, PgUp/PgDn
  --- scroll one body-height, Home/End jump to extremes.
  ---@param key    integer
  ---@param _driver table?
  ---@return boolean handled
  function self:on_key(key, _driver)
    if type(key) ~= "number" then return false end
    local K = keys_mod
    if key == K.KEY_UP    then self:scroll(-1); return true end
    if key == K.KEY_DOWN  then self:scroll( 1); return true end
    if key == K.KEY_PPAGE then self:scroll(-(self._last_body_h or 1)); return true end
    if key == K.KEY_NPAGE then self:scroll( (self._last_body_h or 1)); return true end
    if key == K.KEY_HOME  then self:scroll_to(false); return true end
    if key == K.KEY_END   then self:scroll_to(true);  return true end
    return false
  end

  return self
end

return M

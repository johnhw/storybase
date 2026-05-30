-- cli/drivers/curses/widgets/statbar.lua
--
-- Curses stat-bar widget (ui_idea.md §5.3 + §M5). Renders a bounded
-- Int as `Label: cur/max [######    ]` into a single-row window.
--
-- Wiring:
--   * `M.new{ path, label, type_desc, color_good?, color_bad? }`
--     returns a widget instance.
--   * The driver allocates a window for the widget and calls
--     `widget:paint(screen, win, kernel)` whenever the bound state
--     mutates (or on a full recompose).
--   * The widget reads `kernel:get_state(path)` for the current value.
--     Bounds come from `type_desc.min` / `type_desc.max`.
--
-- The widget is intentionally minimal — no animation, no color theming
-- beyond optional `attrs` on the bar fill — so a future themer layer
-- (§M-later) can decorate without re-implementing the layout.

local format = require("ui.format")

local M = {}

--- Construct a stat-bar widget.
---@param opts table  {
---   path        : state path bound to this widget (required)
---   label       : display label; defaults to the path's tail segment
---   type_desc   : schema type descriptor (`{tag="int", min, max}`)
---   color_good  : optional cell.fg/bg name for the bar fill
---   color_bad   : optional cell.fg/bg name for the empty portion
---   min_bar_w   : minimum width for the [bar] portion (default 8)
--- }
---@return table widget
function M.new(opts)
  opts = opts or {}
  assert(opts.path, "statbar: path is required")

  local self = {
    kind        = "stat-bar",
    path        = opts.path,
    label       = opts.label or opts.path:match("([^/]+)$") or opts.path,
    type_desc   = opts.type_desc,
    color_good  = opts.color_good,
    color_bad   = opts.color_bad,
    min_bar_w   = opts.min_bar_w or 8,
  }

  --- Compute the bar fragment for a given value/max and inner width.
  --- Inner width does not include the surrounding brackets.
  ---@param value   number?
  ---@param max     number?
  ---@param inner_w integer
  ---@return integer filled   number of cells to draw as `#`
  ---@return integer empty    number of cells to draw as ` `
  local function bar_fill(value, max, inner_w)
    if inner_w <= 0 then return 0, 0 end
    if type(value) ~= "number" or type(max) ~= "number" or max <= 0 then
      return 0, inner_w
    end
    if value < 0 then value = 0 end
    if value > max then value = max end
    local filled = math.floor((value / max) * inner_w + 0.5)
    if filled < 0 then filled = 0 end
    if filled > inner_w then filled = inner_w end
    return filled, inner_w - filled
  end

  --- Format the leading text "Label: cur/max " for a given value.
  --- Uses `ui.format.int` so unbounded ints display as the bare number
  --- (the widget then renders an empty `[]` bar). A nil value renders
  --- as "Label: - " so a state path that has never mutated still
  --- displays cleanly during the initial paint.
  ---@param value any
  ---@return string
  function self:format_head(value)
    if value == nil then return self.label .. ": - " end
    local cur_max = format.int(value, self.type_desc)
    return self.label .. ": " .. cur_max .. " "
  end

  --- Paint this widget into `win` on `screen`. Reads the current value
  --- from `kernel:get_state(path)`. The window is assumed to be a single
  --- row at least `min_bar_w + 4` cells wide; smaller windows show only
  --- the head fragment, truncated.
  ---@param screen table
  ---@param win    table
  ---@param kernel table
  function self:paint(screen, win, kernel)
    if not win or win.h < 1 or win.w < 1 then return end
    local value = kernel:get_state(self.path)
    local head = self:format_head(value)

    -- Erase the window so a shrinking value doesn't leave glyph debris.
    screen:fill(win, 0, 0, win.w, win.h, " ")

    -- Decide whether we have room for the bar. If not, only paint head.
    if win.w <= #head + 2 then
      screen:write(win, 0, 0, head:sub(1, win.w))
      return
    end
    screen:write(win, 0, 0, head)

    local bracket_open_x  = #head
    local bracket_close_x = win.w - 1
    local inner_w = bracket_close_x - bracket_open_x - 1
    if inner_w < 0 then inner_w = 0 end

    local max_v = self.type_desc and self.type_desc.max or nil
    local filled, empty = bar_fill(value, max_v, inner_w)

    screen:write(win, 0, bracket_open_x, "[")
    if filled > 0 then
      local good_attrs = self.color_good and { fg = self.color_good } or nil
      screen:fill(win, 0, bracket_open_x + 1, filled, 1, "#", good_attrs)
    end
    if empty > 0 then
      local bad_attrs = self.color_bad and { fg = self.color_bad } or nil
      screen:fill(win, 0, bracket_open_x + 1 + filled, empty, 1, " ", bad_attrs)
    end
    screen:write(win, 0, bracket_close_x, "]")
  end

  return self
end

return M

-- cli/drivers/curses/widgets/stat.lua
--
-- Curses scalar-display widget (ui_idea.md §5.3 + §M8). Renders any
-- single scalar state path as "Label: value" into a single-row window.
-- The display string is produced by `ui/format.lua:value` so bounded
-- ints show as "cur/max", bools as "yes/no", enums by their symbol, etc.
-- This is the most general read-only state widget — `stat-bar` is the
-- specialised version for bounded ints with a progress fill.
--
-- Wiring (same as `statbar.lua`):
--   * `M.new{ path, label?, type_desc?, schema? }` returns a widget.
--   * The driver allocates a one-row window and calls
--     `widget:paint(screen, win, kernel)` on initial paint and on each
--     mutation of `path`.
--   * `kernel:get_state(path)` supplies the current value;
--     `ui/format.value` formats it against `type_desc` + the schema
--     (the schema is needed to resolve `named` / alias chains).

local format = require("ui.format")

local M = {}

--- Construct a stat widget.
---@param opts table  {
---   path      : state path bound to this widget (required)
---   label     : display label; defaults to the path's tail segment
---   type_desc : schema type descriptor (optional)
---   schema    : compiled schema (optional, for named-type resolution)
---   bool_labels : optional `{yes=, no=}` override forwarded to formatter
--- }
---@return table widget
function M.new(opts)
  opts = opts or {}
  assert(opts.path, "stat: path is required")

  local self = {
    kind        = "stat",
    path        = opts.path,
    label       = opts.label or opts.path:match("([^/]+)$") or opts.path,
    type_desc   = opts.type_desc,
    schema      = opts.schema,
    bool_labels = opts.bool_labels,
  }

  --- Format the current "Label: value" string for a given value. Used by
  --- paint; exposed for tests.
  ---@param value any
  ---@return string
  function self:format(value)
    local opts_fmt = self.bool_labels and { bool_labels = self.bool_labels } or nil
    local v = format.value(value, self.type_desc, self.schema, opts_fmt)
    return self.label .. ": " .. v
  end

  --- Paint into a single-row window. Erases the window first so a value
  --- shrink doesn't leave glyph debris. Text is clipped on the right
  --- edge of the window.
  ---@param screen table
  ---@param win    table
  ---@param kernel table
  function self:paint(screen, win, kernel)
    if not win or win.h < 1 or win.w < 1 then return end
    screen:fill(win, 0, 0, win.w, win.h, " ")
    local value = kernel:get_state(self.path)
    local text  = self:format(value)
    if #text > win.w then text = text:sub(1, win.w) end
    screen:write(win, 0, 0, text)
  end

  return self
end

return M

-- cli/drivers/curses/widgets/toggle.lua
--
-- Curses toggle widget (ui_idea.md §5.3 + §M8). Renders a Bool state
-- path as `[x] Label` or `[ ] Label` in a single-row window. Acts both
-- as a *view* (paint into a driver-allocated window like `statbar`) and
-- optionally as a *focus handler* (when the author pushes it onto the
-- focus stack, SPACE / Enter flips the value).
--
-- Two modes of state mutation, in order of preference:
--   1. If `fn_name` is set, activation calls
--      `driver._kernel:call_fn(fn_name, new_value)` (per ui_idea.md §6
--      input-vocabulary — toggles go through fn calls, not direct writes).
--   2. Otherwise, if `on_toggle(self, new_value, driver)` is set, it's
--      called and the caller is expected to update state itself.
--
-- The widget is *display-only* without focus; values are always read
-- from `kernel:get_state(path)` on paint, mirroring the statbar pattern.
--
-- Wiring:
--   * `M.new{ path, label?, fn_name?, on_toggle?, on_glyph?, off_glyph?,
--             bool_labels? }`
--   * The driver allocates a one-row window and calls
--     `widget:paint(screen, win, kernel)`. The driver also subscribes
--     the bound `path` so mutations repaint the widget.

local keys_mod = require("cli.drivers.curses.keys")

local M = {}

--- Construct a toggle widget.
---@param opts table  {
---   path       : state path bound to this widget (required)
---   label      : display label; defaults to the path's tail segment
---   fn_name    : optional fn name to invoke via `kernel:call_fn`
---   on_toggle  : optional function(self, new_value, driver) callback
---   on_glyph   : glyph for the on state (default "x")
---   off_glyph  : glyph for the off state (default " ")
---   bool_labels: optional `{yes=, no=}` override (currently unused; kept
---                for symmetry with `stat.lua` and forward use in the
---                ansi/web drivers)
--- }
---@return table widget
function M.new(opts)
  opts = opts or {}
  assert(opts.path, "toggle: path is required")

  local function single_char(s, default)
    if type(s) == "string" and #s >= 1 then return s:sub(1, 1) end
    return default
  end

  local self = {
    kind        = "toggle",
    path        = opts.path,
    label       = opts.label or opts.path:match("([^/]+)$") or opts.path,
    fn_name     = opts.fn_name,
    on_toggle   = opts.on_toggle,
    on_glyph    = single_char(opts.on_glyph,  "x"),
    off_glyph   = single_char(opts.off_glyph, " "),
    bool_labels = opts.bool_labels,
  }

  --- Format the current "[x] Label" string for a given truthy/falsy value.
  ---@param value any
  ---@return string
  function self:format(value)
    local on = value and true or false
    local g  = on and self.on_glyph or self.off_glyph
    return "[" .. g .. "] " .. self.label
  end

  --- Paint into a single-row window. Erases first so a label change
  --- doesn't leave debris.
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

  --- Activate the toggle. Computes the new value (logical NOT of the
  --- current kernel state), then dispatches via `fn_name` (preferred)
  --- or `on_toggle`. Returns the new value (boolean) for callers / tests.
  ---@param driver table?
  ---@return boolean new_value
  function self:activate(driver)
    local kernel = driver and driver._kernel
    local cur    = kernel and kernel:get_state(self.path)
    local new    = not (cur and true or false)
    if self.fn_name and kernel and kernel.call_fn then
      kernel:call_fn(self.fn_name, new)
    end
    if self.on_toggle then self:on_toggle(new, driver) end
    return new
  end

  --- Focus-stack handler. Consumes SPACE / Enter to flip; everything
  --- else is ignored so the focus stack can fall through if needed.
  ---@param key    integer
  ---@param driver table?
  ---@return boolean handled
  function self:on_key(key, driver)
    if type(key) ~= "number" then return false end
    if key == keys_mod.SPACE or keys_mod.is_enter(key) then
      self:activate(driver)
      return true
    end
    return false
  end

  return self
end

return M

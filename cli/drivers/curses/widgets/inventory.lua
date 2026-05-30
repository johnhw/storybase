-- cli/drivers/curses/widgets/inventory.lua
--
-- Curses inventory widget (ui_idea.md §5.3 + §M8). Renders a Set / List /
-- UList state path as a scrollable bullet list inside a driver-allocated
-- window. Acts both as a *view* (paint into a pre-allocated window like
-- `statbar`) and optionally as a *focus handler* — when the author pushes
-- it onto the focus stack, Up/Down/PgUp/PgDn move the scroll offset and
-- highlight, Enter optionally selects (callback receives the item).
--
-- The widget assumes the runtime stores Set / List / UList values as Lua
-- sequence tables (`{ "sword", "shield", ... }`) — see `runtime/state.lua`
-- `resolve_default` and `ui/format.lua` `format_seq`. Each row renders as
-- `"- <item>"`. Items that are tables (records) render via
-- `ui/format.value`.
--
-- Wiring:
--   * `M.new{ path, label?, schema?, max_h?, on_select?, fn_name? }`
--   * The driver allocates a multi-row window (height bounded by
--     `max_h` if set, else the items count + optional header) and calls
--     `widget:paint(screen, win, kernel)` on initial paint and on each
--     mutation of `path`.
--   * Focus behaviour is opt-in: callers push the widget onto a focus
--     stack to scroll / select; the widget paints identically either way.

local keys_mod = require("cli.drivers.curses.keys")
local format   = require("ui.format")

local M = {}

--- Construct an inventory widget.
---@param opts table  {
---   path       : state path bound to this widget (required)
---   label      : optional header line; defaults to nil (no header)
---   schema     : compiled schema for value formatting (optional)
---   max_h      : optional cap on rendered rows (excluding the header)
---   bullet     : single char bullet glyph (default "-")
---   on_select  : optional function(self, item, index, driver) called on Enter
---   fn_name    : optional fn name to invoke via `kernel:call_fn(fn_name,
---                item)` when Enter is pressed (preferred over on_select)
---   empty_text : message shown when the bound value is empty / nil
---                (default "(empty)")
--- }
---@return table widget
function M.new(opts)
  opts = opts or {}
  assert(opts.path, "inventory: path is required")

  local function single_char(s, default)
    if type(s) == "string" and #s >= 1 then return s:sub(1, 1) end
    return default
  end

  local self = {
    kind       = "inventory",
    path       = opts.path,
    label      = opts.label,
    schema     = opts.schema,
    max_h      = opts.max_h,
    bullet     = single_char(opts.bullet, "-"),
    on_select  = opts.on_select,
    fn_name    = opts.fn_name,
    empty_text = opts.empty_text or "(empty)",
    _scroll    = 0,   -- index of the first visible item (0-based)
    _cursor    = 1,   -- 1-based highlighted item; 0 when list is empty
  }

  --- Look up the inventory items from the kernel. Returns a Lua sequence
  --- table; nil / non-table values yield an empty list.
  ---@param kernel table?
  ---@return table list
  function self:_items(kernel)
    local v = kernel and kernel:get_state(self.path)
    if type(v) ~= "table" then return {} end
    return v
  end

  --- Format a single item as a string for display. Scalars pass through
  --- via `ui/format.value`; records and nested lists get the same
  --- treatment so the display is consistent with `stat` / `text`.
  ---@param item any
  ---@return string
  function self:_format_item(item)
    if type(item) == "string" or type(item) == "number"
       or type(item) == "boolean" then
      return format.value(item, nil, self.schema)
    end
    return format.value(item, nil, self.schema)
  end

  --- Move the cursor by `delta` (positive = down). Clamps to [1, #items].
  --- Also adjusts `_scroll` so the cursor stays visible inside the most
  --- recently painted body height (`self._last_body_h`, set by paint).
  ---@param delta integer
  ---@param kernel table?
  function self:move_cursor(delta, kernel)
    local items = self:_items(kernel)
    local n = #items
    if n == 0 then self._cursor = 0; self._scroll = 0; return end
    local c = self._cursor + delta
    if c < 1 then c = 1 end
    if c > n then c = n end
    self._cursor = c
    local body_h = self._last_body_h or n
    if self._cursor - 1 < self._scroll then
      self._scroll = self._cursor - 1
    elseif self._cursor - 1 >= self._scroll + body_h then
      self._scroll = self._cursor - body_h
    end
    if self._scroll < 0 then self._scroll = 0 end
  end

  --- Fire the on_select callback (and/or call_fn fn) for the highlighted
  --- item. Returns true iff anything fired.
  ---@param driver table?
  ---@return boolean
  function self:activate(driver)
    local kernel = driver and driver._kernel
    local items  = self:_items(kernel)
    local idx    = self._cursor
    if idx < 1 or idx > #items then return false end
    local item = items[idx]
    if self.fn_name and kernel and kernel.call_fn then
      kernel:call_fn(self.fn_name, item)
    end
    if self.on_select then self:on_select(item, idx, driver) end
    return true
  end

  --- Paint into a driver-allocated window. Layout:
  ---   row 0          : `label` (if set; otherwise the first item)
  ---   row 1..h-1     : items, indented by 2 (`"- foo"`)
  --- The widget scrolls to keep the cursor row visible.
  ---@param screen table
  ---@param win    table
  ---@param kernel table
  function self:paint(screen, win, kernel)
    if not win or win.h < 1 or win.w < 1 then return end
    screen:fill(win, 0, 0, win.w, win.h, " ")

    local items = self:_items(kernel)
    local has_header = self.label and self.label ~= ""
    local header_h = has_header and 1 or 0
    local body_h = win.h - header_h
    if self.max_h and self.max_h < body_h then body_h = self.max_h end
    if body_h < 1 then body_h = 0 end
    self._last_body_h = body_h

    if has_header then
      local h = self.label
      if #h > win.w then h = h:sub(1, win.w) end
      screen:write(win, 0, 0, h)
    end

    if body_h == 0 then return end

    if #items == 0 then
      local t = self.empty_text
      if #t > win.w then t = t:sub(1, win.w) end
      screen:write(win, header_h, 0, t)
      return
    end

    -- Clamp the cursor inside the current item set in case the list
    -- shrank between paints.
    if self._cursor > #items then self._cursor = #items end
    if self._cursor < 1 then self._cursor = 1 end
    -- Keep the cursor visible inside the body window.
    if self._cursor - 1 < self._scroll then
      self._scroll = self._cursor - 1
    elseif self._cursor - 1 >= self._scroll + body_h then
      self._scroll = self._cursor - body_h
    end
    if self._scroll < 0 then self._scroll = 0 end
    if self._scroll > math.max(0, #items - body_h) then
      self._scroll = math.max(0, #items - body_h)
    end

    for row = 0, body_h - 1 do
      local idx = self._scroll + row + 1
      local item = items[idx]
      if item == nil then break end
      local txt = self.bullet .. " " .. self:_format_item(item)
      if #txt > win.w then txt = txt:sub(1, win.w) end
      local pad = win.w - #txt
      if pad > 0 then txt = txt .. string.rep(" ", pad) end
      local attrs = (idx == self._cursor) and { attrs = "reverse" } or nil
      screen:write(win, header_h + row, 0, txt, attrs)
    end
  end

  --- Optional focus-stack handler. Up/Down/PgUp/PgDn scroll the visible
  --- window; Home/End jump to extremes; Enter activates. Returns true
  --- iff the key was consumed.
  ---@param key    integer
  ---@param driver table?
  ---@return boolean handled
  function self:on_key(key, driver)
    if type(key) ~= "number" then return false end
    local K = keys_mod
    if key == K.KEY_UP   then self:move_cursor(-1, driver and driver._kernel); return true end
    if key == K.KEY_DOWN then self:move_cursor( 1, driver and driver._kernel); return true end
    if key == K.KEY_PPAGE then
      local h = self._last_body_h or 1
      self:move_cursor(-h, driver and driver._kernel); return true
    end
    if key == K.KEY_NPAGE then
      local h = self._last_body_h or 1
      self:move_cursor( h, driver and driver._kernel); return true
    end
    if key == K.KEY_HOME then self:move_cursor(-1e9, driver and driver._kernel); return true end
    if key == K.KEY_END  then self:move_cursor( 1e9, driver and driver._kernel); return true end
    if K.is_enter(key)   then self:activate(driver); return true end
    return false
  end

  return self
end

return M

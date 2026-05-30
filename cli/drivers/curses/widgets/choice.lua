-- cli/drivers/curses/widgets/choice.lua
--
-- Curses radio-group widget (ui_idea.md §5.3 + §M8). Renders an enum
-- state path as a vertical radio group — one row per enum value, with
-- the currently-selected value marked `(*)` and the others `( )`. Acts
-- both as a *view* (paint into a driver-allocated window like `statbar`)
-- and optionally as a *focus handler* (when pushed onto a focus stack,
-- Up/Down moves the highlight cursor, Enter selects and dispatches).
--
-- Two modes of state mutation, in order of preference:
--   1. If `fn_name` is set, activation calls
--      `driver._kernel:call_fn(fn_name, new_value)` so authors keep the
--      engine's input vocabulary (§6) as the single mutation seam.
--   2. Otherwise, if `on_select(self, value, driver)` is set, it's
--      called and the caller is expected to update state itself.
--
-- The selected value is always read from `kernel:get_state(path)` on
-- paint, mirroring the statbar pattern. The highlight cursor is a
-- separate, widget-local concept that defaults to the currently selected
-- value and only moves while the widget is on the focus stack.
--
-- Wiring:
--   * `M.new{ path, values, label?, fn_name?, on_select?, schema? }`
--   * `values` is the list of enum values, e.g. `{ "happy", "sad", "angry" }`.
--     When omitted, the widget tries to resolve them via the schema's
--     type tables (named → enum, alias chains followed).

local keys_mod = require("cli.drivers.curses.keys")
local format   = require("ui.format")

local M = {}

--- Look up an enum's value list for a given state path, following named
--- and alias chains. Returns `nil` when the path is unknown or its type
--- is not an enum / alias-to-enum.
---@param schema table?
---@param path   string
---@return any[]?
local function resolve_enum_values(schema, path)
  if not schema or not schema.states or not schema.types then return nil end
  local td
  for _, s in ipairs(schema.states) do
    if s.kind == "scalar" and s.path == path then td = s.type_desc; break end
  end
  if not td then return nil end

  if td.tag == "enum" and td.values then return td.values end

  if td.tag == "named" then
    local seen = {}
    local cur  = td.name
    while cur and not seen[cur] do
      seen[cur] = true
      local t
      for _, tt in ipairs(schema.types) do
        if tt.name == cur then t = tt; break end
      end
      if not t then return nil end
      if t.kind == "enum" then return t.values end
      if t.kind == "alias" and t.type_desc then
        if t.type_desc.tag == "enum" then return t.type_desc.values end
        if t.type_desc.tag == "named" then cur = t.type_desc.name
        else return nil end
      else
        return nil
      end
    end
  end
  return nil
end

--- Construct a radio-group widget.
---@param opts table  {
---   path      : state path bound to this widget (required)
---   values    : optional list of enum values; resolved from `schema` if absent
---   schema    : compiled schema (for resolving enums / display)
---   label     : optional header line shown above the radio rows
---   fn_name   : optional fn name to invoke via `kernel:call_fn`
---   on_select : optional function(self, value, driver) callback
---   on_glyph  : single char inside the selected `(o)` (default "*")
---   off_glyph : single char inside the deselected `( )` (default " ")
--- }
---@return table widget
function M.new(opts)
  opts = opts or {}
  assert(opts.path, "choice: path is required")

  local function single_char(s, default)
    if type(s) == "string" and #s >= 1 then return s:sub(1, 1) end
    return default
  end

  local values = opts.values
  if not values and opts.schema then
    values = resolve_enum_values(opts.schema, opts.path)
  end
  assert(type(values) == "table" and #values > 0,
         "choice: values is required when no enum can be resolved from the schema")

  local self = {
    kind       = "choice",
    path       = opts.path,
    values     = values,
    schema     = opts.schema,
    label      = opts.label,
    fn_name    = opts.fn_name,
    on_select  = opts.on_select,
    on_glyph   = single_char(opts.on_glyph,  "*"),
    off_glyph  = single_char(opts.off_glyph, " "),
    _cursor    = 1,   -- 1-based highlight position
    _cursor_seeded = false,  -- have we seeded from the kernel yet?
  }

  --- Return the 1-based index of `value` in `self.values`, or nil.
  ---@param value any
  ---@return integer?
  function self:index_of(value)
    for i, v in ipairs(self.values) do
      if v == value then return i end
    end
    return nil
  end

  --- Seed the cursor from the kernel's current value if not already done.
  --- Called from paint so the highlight defaults to the selected value
  --- even before any key has been pressed.
  ---@param kernel table?
  function self:_seed_cursor(kernel)
    if self._cursor_seeded then return end
    if not kernel then return end
    local v = kernel:get_state(self.path)
    local idx = v ~= nil and self:index_of(v)
    if idx then self._cursor = idx end
    self._cursor_seeded = true
  end

  --- Move the highlight cursor by `delta`. Clamped to [1, #values];
  --- callers may pass +/-1e9 for "jump to end".
  ---@param delta integer
  function self:move_cursor(delta)
    local n = #self.values
    if n == 0 then return end
    local c = self._cursor + delta
    if c < 1 then c = 1 end
    if c > n then c = n end
    self._cursor = c
  end

  --- Fire the on_select callback (and/or call_fn fn) for the highlighted
  --- value. Returns the chosen value (or nil if no values exist).
  ---@param driver table?
  ---@return any?
  function self:activate(driver)
    local v = self.values[self._cursor]
    if v == nil then return nil end
    local kernel = driver and driver._kernel
    if self.fn_name and kernel and kernel.call_fn then
      kernel:call_fn(self.fn_name, v)
    end
    if self.on_select then self:on_select(v, driver) end
    return v
  end

  --- Paint into a driver-allocated window. Layout:
  ---   row 0          : `label` (if set; otherwise the first option)
  ---   row 1..h-1     : "(*) value" / "( ) value" rows
  --- Each row is indented by 0 columns; selected and highlighted rows
  --- are drawn with the `reverse` attribute (cursor) and the selection
  --- marker is data-driven (`kernel:get_state(path)`).
  ---@param screen table
  ---@param win    table
  ---@param kernel table
  function self:paint(screen, win, kernel)
    if not win or win.h < 1 or win.w < 1 then return end
    screen:fill(win, 0, 0, win.w, win.h, " ")
    self:_seed_cursor(kernel)

    local has_header = self.label and self.label ~= ""
    local header_h = has_header and 1 or 0
    if has_header then
      local h = self.label
      if #h > win.w then h = h:sub(1, win.w) end
      screen:write(win, 0, 0, h)
    end

    local body_h = win.h - header_h
    if body_h <= 0 then return end

    local cur_value = kernel and kernel:get_state(self.path)
    for row = 0, body_h - 1 do
      local idx = row + 1
      local v = self.values[idx]
      if v == nil then break end
      local sel = (v == cur_value)
      local marker = "(" .. (sel and self.on_glyph or self.off_glyph) .. ")"
      local label  = format.value(v, nil, self.schema)
      local text = marker .. " " .. label
      if #text > win.w then text = text:sub(1, win.w) end
      local pad = win.w - #text
      if pad > 0 then text = text .. string.rep(" ", pad) end
      local attrs = (idx == self._cursor) and { attrs = "reverse" } or nil
      screen:write(win, header_h + row, 0, text, attrs)
    end
  end

  --- Optional focus-stack handler. Up/Down moves the highlight; Enter
  --- activates the highlighted value; Home/End jump to extremes.
  ---@param key    integer
  ---@param driver table?
  ---@return boolean handled
  function self:on_key(key, driver)
    if type(key) ~= "number" then return false end
    local K = keys_mod
    if key == K.KEY_UP   then self:move_cursor(-1); return true end
    if key == K.KEY_DOWN then self:move_cursor( 1); return true end
    if key == K.KEY_HOME then self:move_cursor(-1e9); return true end
    if key == K.KEY_END  then self:move_cursor( 1e9); return true end
    if K.is_enter(key) or key == K.SPACE then
      self:activate(driver)
      return true
    end
    return false
  end

  return self
end

return M

-- cli/drivers/curses/widgets/dialog.lua
--
-- Modal dialog widget (ui_idea.md §5.3 + §M6). Renders a centred,
-- bordered box with an optional title, a multi-line body, and a row
-- of button labels. Acts both as a *view* (paint into the screen on
-- every compose) and as a *focus handler* (intercept keys, dispatch
-- to button actions).
--
-- Wiring:
--   * `M.new{ title?, body, buttons, on_select?, on_cancel?, min_w?, max_w? }`
--     returns a dialog object.
--   * The driver pushes the dialog onto both the view stack and the
--     focus stack (modals always want both).
--   * On each paint the dialog allocates its own screen window
--     (centred, sized to its contents) and writes the frame into it.
--   * On each key the dialog walks `buttons` looking for a match; on
--     match it fires `on_select(self, button, driver)`. ESC (27) and
--     'q'/'Q' fire `on_cancel(self, driver)` if defined.
--
-- A button is `{ key = <char|byte>, label = <string>, action? = fn }`.
-- The `action` callback is preferred when defined; `on_select` is the
-- catch-all the caller uses when every button shares the same finish
-- routine.

local M = {}

local KEY_ESC = 27

--- Normalise a button's `key` field into a byte for byte-vs-byte
--- comparison in on_key. Accepts a single-char string or an integer.
---@param key any
---@return integer?
local function key_to_byte(key)
  if type(key) == "number" then return key end
  if type(key) == "string" and #key >= 1 then return string.byte(key, 1) end
  return nil
end

--- Build the button-row string: "[Y]es  [N]o". The bracket wraps the
--- first character of each label that happens to match the button's
--- key — purely cosmetic, so unmatched buttons still render fine.
---@param buttons table[]
---@return string
local function format_button_row(buttons)
  local parts = {}
  for i, b in ipairs(buttons) do
    local label = tostring(b.label or "")
    parts[i] = "[" .. label .. "]"
  end
  return table.concat(parts, "  ")
end

--- Split a body string on `\n` into individual lines. Empty body
--- returns an empty list — the caller draws no body region in that case.
---@param body string?
---@return string[]
local function split_lines(body)
  if not body or body == "" then return {} end
  local out = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  return out
end

--- Compute the window geometry. The dialog claims the minimum size that
--- fits its title, body, and button row, then centres on the screen.
--- All values are clamped to the screen bounds.
---@param dialog       table
---@param screen_rows  integer
---@param screen_cols  integer
---@return integer x
---@return integer y
---@return integer w
---@return integer h
local function compute_geometry(dialog, screen_rows, screen_cols)
  local body_lines = dialog._body_lines
  local btn_str    = dialog._btn_str

  local content_w = #btn_str
  for _, line in ipairs(body_lines) do
    if #line > content_w then content_w = #line end
  end
  if dialog.title then
    local tw = #dialog.title + 4 -- "+- Title -+" overhead
    if tw > content_w then content_w = tw end
  end

  local inner_w = math.max(dialog.min_w or 16, content_w)
  inner_w = math.min(inner_w, dialog.max_w or math.huge, screen_cols - 2)
  if inner_w < 1 then inner_w = 1 end

  local body_h = #body_lines
  local has_buttons = #dialog.buttons > 0

  local inner_h = body_h
  if has_buttons then
    -- A blank spacer row between body and buttons keeps the dialog
    -- legible even when body is one line.
    inner_h = inner_h + (body_h > 0 and 1 or 0) + 1
  end
  if inner_h < 1 then inner_h = 1 end

  local w = inner_w + 2
  local h = inner_h + 2
  if w > screen_cols then w = screen_cols end
  if h > screen_rows then h = screen_rows end

  local x = math.floor((screen_cols - w) / 2)
  local y = math.floor((screen_rows - h) / 2)
  if x < 0 then x = 0 end
  if y < 0 then y = 0 end
  return x, y, w, h
end

--- Construct a modal dialog.
---@param opts table  {
---   title?     : string                top-border title
---   body       : string                body text; may contain '\n'
---   buttons    : table[]               { {key, label, action?}, ... }
---   on_select? : function(self, btn, driver)  fires when a button matched
---   on_cancel? : function(self, driver)       fires on ESC/q/Q
---   min_w?     : integer               minimum inner width (default 16)
---   max_w?     : integer               maximum inner width (default ∞)
---   z?         : integer               view z-order (default 100)
--- }
---@return table dialog
function M.new(opts)
  opts = opts or {}
  assert(type(opts.body or "") == "string", "dialog: body must be a string")
  assert(type(opts.buttons or {}) == "table", "dialog: buttons must be a table")

  local self = {
    kind        = "dialog",
    title       = opts.title,
    body        = opts.body or "",
    buttons     = opts.buttons or {},
    on_select   = opts.on_select,
    on_cancel   = opts.on_cancel,
    min_w       = opts.min_w,
    max_w       = opts.max_w,
    z           = opts.z or 100,
    _body_lines = split_lines(opts.body),
    _btn_str    = format_button_row(opts.buttons or {}),
  }

  -- Cache normalised key bytes alongside each button for cheap dispatch.
  for _, b in ipairs(self.buttons) do
    b._key_byte = key_to_byte(b.key)
  end

  --- Paint the dialog frame into a fresh centred window. Called once
  --- per compose pass while the dialog is on the view stack.
  ---@param screen table
  ---@param _ctx   table?  driver context (kernel, etc.) — currently unused
  function self:paint(screen, _ctx)
    local x, y, w, h = compute_geometry(self, screen.rows, screen.cols)
    local win = screen:add_window({ x = x, y = y, w = w, h = h, z = self.z })

    -- Blank the box so anything underneath shows through cleanly.
    screen:fill(win, 0, 0, w, h, " ")

    -- Borders + corners. ASCII only — the screen treats strings as
    -- byte sequences (see screen.lua's `write` doc), so multi-byte
    -- glyphs would break the cell grid.
    screen:write(win, 0, 0,     "+")
    screen:write(win, 0, w - 1, "+")
    screen:write(win, h - 1, 0,     "+")
    screen:write(win, h - 1, w - 1, "+")
    if w > 2 then
      screen:fill(win, 0,     1, w - 2, 1, "-")
      screen:fill(win, h - 1, 1, w - 2, 1, "-")
    end
    if h > 2 then
      screen:fill(win, 1, 0,     1, h - 2, "|")
      screen:fill(win, 1, w - 1, 1, h - 2, "|")
    end

    -- Title: "+- Title -+" on the top border, clipped to fit.
    if self.title and w >= 6 then
      local tag = " " .. self.title .. " "
      local max_tag = w - 4
      if #tag > max_tag then tag = tag:sub(1, max_tag) end
      screen:write(win, 0, 2, tag)
    end

    -- Body: top-aligned, one line per row, clipped on the right.
    local inner_w = w - 2
    local row = 1
    for _, line in ipairs(self._body_lines) do
      if row >= h - 1 then break end
      local clipped = line
      if #clipped > inner_w then clipped = clipped:sub(1, inner_w) end
      screen:write(win, row, 1, clipped)
      row = row + 1
    end

    -- Buttons: bottom-most interior row, left-aligned inside the box.
    if #self.buttons > 0 and h >= 3 then
      local btn_row = h - 2
      local s = self._btn_str
      if #s > inner_w then s = s:sub(1, inner_w) end
      screen:write(win, btn_row, 1, s)
    end
  end

  --- Focus-stack handler. Returns true iff the key was consumed.
  --- A matched button fires its `action` callback (if any) and then
  --- the dialog-wide `on_select(self, button, driver)`. ESC / q / Q
  --- fire `on_cancel(self, driver)`.
  ---@param key    integer  key byte (per backend:read_key)
  ---@param driver table?
  ---@return boolean handled
  function self:on_key(key, driver)
    if type(key) ~= "number" then return false end
    if key == KEY_ESC
       or key == string.byte("q")
       or key == string.byte("Q") then
      if self.on_cancel then self:on_cancel(driver) end
      return true
    end
    local lk = key
    if lk >= 65 and lk <= 90 then lk = lk + 32 end
    for _, b in ipairs(self.buttons) do
      local bk = b._key_byte
      if bk then
        if bk >= 65 and bk <= 90 then bk = bk + 32 end
        if bk == lk then
          if b.action then b.action(driver) end
          if self.on_select then self:on_select(b, driver) end
          return true
        end
      end
    end
    return false
  end

  return self
end

return M

-- cli/drivers/curses/widgets/input.lua
--
-- Single-line free-text input widget (ui_idea.md §5.3 + §M7). Renders
-- a centred, optionally bordered box containing an optional prompt
-- label, a one-line text field that the player types into, and (when
-- bordered) an optional title. Acts as both a *view* (paints into the
-- screen each compose) and a *focus handler* (consumes keys via on_key).
--
-- The §M7 acceptance contract is that submitting the input fires
-- `kernel:call_fn(name, text)` so author-facing fn calls can be driven
-- from the UI. The widget itself stays UI-only: the embedding driver
-- supplies an `on_submit(self, text, driver)` callback that decides how
-- to route the text (typically straight to `driver._kernel:call_fn`).
-- A `fn_name` opt is also accepted as syntactic sugar; when both
-- `fn_name` and a kernel-bearing driver are present, the widget will
-- call `driver._kernel:call_fn(fn_name, text)` *before* the on_submit
-- callback, so authors who want the canonical wiring don't have to
-- write any glue. Tests can pass either form.
--
-- Editing model:
--   * `_buffer` is a Lua string of bytes (ASCII assumed — matches the
--     rest of the curses driver, see screen.lua note).
--   * `_cursor` is a 1-based insertion point in [1, #_buffer + 1].
--   * Printable bytes (32..126) insert at the cursor and advance it.
--   * Backspace deletes the byte before the cursor.
--   * Left/Right move the cursor; Home/End jump to ends.
--   * Enter (CR/LF/KEY_ENTER) submits.
--   * ESC cancels.
--
-- Customisation mirrors `menu.lua`:
--   * `border`, `title`, `min_w`, `max_w`, `z`, `keys` overrides.
--   * `max_len` caps the buffer length (0 = unlimited).
--   * `cursor_glyph` is a single char used to mark the cursor position
--     in the visible field (default "_"). Real ncurses doesn't render
--     a hardware cursor inside a buffer-painted cell, so we draw a
--     glyph in-band.

local keys_mod = require("cli.drivers.curses.keys")

local M = {}

-- ── helpers ────────────────────────────────────────────────────────────

--- Convert a binding value (int OR int[]) to a `set[int] = true` lookup.
---@param v any
---@return table
local function to_key_set(v)
  local out = {}
  if type(v) == "number" then
    out[v] = true
  elseif type(v) == "table" then
    for _, k in ipairs(v) do
      if type(k) == "number" then out[k] = true end
    end
  end
  return out
end

--- Overlay user-supplied bindings onto the input widget defaults.
---@param user table?
---@return table
local function resolve_bindings(user)
  user = user or {}
  local K = keys_mod
  local defaults = {
    submit    = { K.CR, K.LF, K.KEY_ENTER },
    cancel    = { K.ESC },
    backspace = { K.BS, K.DEL, K.KEY_BACKSPACE },
    left      = { K.KEY_LEFT },
    right     = { K.KEY_RIGHT },
    home      = { K.KEY_HOME },
    ["end"]   = { K.KEY_END },
    delete    = { K.KEY_DC },
  }
  local out = {}
  for name, def in pairs(defaults) do
    if user[name] ~= nil then
      out[name] = to_key_set(user[name])
    else
      out[name] = to_key_set(def)
    end
  end
  return out
end

--- Compute the box geometry. Height is fixed (1 input row + optional
--- prompt row + optional border) and width is sized to fit prompt /
--- title / a reasonable default field width, clamped to the screen.
---@param self        table
---@param screen_rows integer
---@param screen_cols integer
---@return integer x
---@return integer y
---@return integer w
---@return integer h
local function compute_geometry(self, screen_rows, screen_cols)
  local content_w = self.min_w or 24
  if self.prompt and #self.prompt > content_w then content_w = #self.prompt end
  if self.title  and (#self.title + 4) > content_w then
    content_w = #self.title + 4
  end
  -- Reserve room for the cursor glyph at end-of-buffer.
  if (#self._buffer + 1) > content_w then content_w = #self._buffer + 1 end

  local inner_w = math.min(content_w, self.max_w or math.huge,
                           screen_cols - (self.border and 2 or 0))
  if inner_w < 1 then inner_w = 1 end

  local inner_h = 1                       -- the input field row
  if self.prompt and self.prompt ~= "" then
    inner_h = inner_h + 1                 -- prompt label row
  end

  local bo = self.border and 1 or 0
  local w = inner_w + 2 * bo
  local h = inner_h + 2 * bo
  if w > screen_cols then w = screen_cols end
  if h > screen_rows then h = screen_rows end

  local x = math.floor((screen_cols - w) / 2)
  local y = math.floor((screen_rows - h) / 2)
  if x < 0 then x = 0 end
  if y < 0 then y = 0 end
  return x, y, w, h
end

-- ── public API ─────────────────────────────────────────────────────────

--- Construct an input widget.
---@param opts table  {
---   title?        : string                          top-border title
---   prompt?       : string                          label above the field
---   initial?      : string                          starting buffer
---   max_len?      : integer                         cap; 0 / nil = unlimited
---   fn_name?      : string                          if set, on submit the
---                                                   widget calls
---                                                   driver._kernel:call_fn(
---                                                       fn_name, text)
---   on_submit?    : function(self, text, driver)    called on Enter
---                                                   (after fn_name dispatch)
---   on_cancel?    : function(self, driver)          called on ESC
---   border?       : boolean                         default true
---   min_w?        : integer                         min inner width (24)
---   max_w?        : integer                         max inner width
---   z?            : integer                         view z-order (100)
---   cursor_glyph? : string                          single char (default "_")
---   keys?         : table                           binding overrides
--- }
---@return table input
function M.new(opts)
  opts = opts or {}
  assert(type(opts.initial or "") == "string",
         "input: initial must be a string")

  local self = {
    kind         = "input",
    title        = opts.title,
    prompt       = opts.prompt,
    fn_name      = opts.fn_name,
    on_submit    = opts.on_submit,
    on_cancel    = opts.on_cancel,
    border       = opts.border ~= false,           -- default true
    min_w        = opts.min_w,
    max_w        = opts.max_w,
    z            = opts.z or 100,
    max_len      = opts.max_len or 0,              -- 0 = unlimited
    cursor_glyph = (opts.cursor_glyph and #opts.cursor_glyph >= 1)
                     and opts.cursor_glyph:sub(1, 1) or "_",
    _bindings    = resolve_bindings(opts.keys),
    _buffer      = opts.initial or "",
  }
  self._cursor = #self._buffer + 1  -- 1-based insertion point past last char

  -- ── editing helpers (also useful for tests) ──────────────────────

  --- Current text content of the field.
  ---@return string
  function self:text() return self._buffer end

  --- Current 1-based cursor position (insertion point).
  ---@return integer
  function self:cursor() return self._cursor end

  --- Replace the buffer with `s` and put the cursor at the end. Honours
  --- max_len. Useful for tests, prefilling, and "clear-and-retry" flows.
  ---@param s string
  function self:set_text(s)
    s = tostring(s or "")
    if self.max_len > 0 and #s > self.max_len then s = s:sub(1, self.max_len) end
    self._buffer = s
    self._cursor = #s + 1
  end

  --- Insert a single byte at the cursor. No-op when max_len is exceeded.
  ---@param byte integer
  ---@return boolean inserted
  function self:insert_byte(byte)
    if self.max_len > 0 and #self._buffer >= self.max_len then return false end
    local ch = string.char(byte)
    local i = self._cursor
    self._buffer = self._buffer:sub(1, i - 1) .. ch .. self._buffer:sub(i)
    self._cursor = i + 1
    return true
  end

  --- Delete the byte immediately before the cursor (Backspace).
  ---@return boolean deleted
  function self:backspace()
    if self._cursor <= 1 then return false end
    local i = self._cursor
    self._buffer = self._buffer:sub(1, i - 2) .. self._buffer:sub(i)
    self._cursor = i - 1
    return true
  end

  --- Delete the byte at the cursor (forward Delete).
  ---@return boolean deleted
  function self:delete_forward()
    if self._cursor > #self._buffer then return false end
    local i = self._cursor
    self._buffer = self._buffer:sub(1, i - 1) .. self._buffer:sub(i + 1)
    return true
  end

  --- Submit the current buffer. Calls `driver._kernel:call_fn` (when
  --- `fn_name` + a kernel-bearing driver are present), then the
  --- `on_submit` callback. Returns the submitted text.
  ---@param driver table?
  ---@return string text
  function self:submit(driver)
    local text = self._buffer
    if self.fn_name and driver and driver._kernel
       and driver._kernel.call_fn then
      driver._kernel:call_fn(self.fn_name, text)
    end
    if self.on_submit then self:on_submit(text, driver) end
    return text
  end

  -- ── paint (view interface) ──────────────────────────────────────

  --- Paint into a freshly-allocated centred window.
  ---@param screen table
  ---@param _ctx   table?
  function self:paint(screen, _ctx)
    local x, y, w, h = compute_geometry(self, screen.rows, screen.cols)
    local win = screen:add_window({ x = x, y = y, w = w, h = h, z = self.z })
    screen:fill(win, 0, 0, w, h, " ")

    local bo = self.border and 1 or 0
    if self.border then
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
      if self.title and w >= 6 then
        local tag = " " .. self.title .. " "
        local max_tag = w - 4
        if #tag > max_tag then tag = tag:sub(1, max_tag) end
        screen:write(win, 0, 2, tag)
      end
    end

    local inner_w = w - 2 * bo
    local row = bo
    if self.prompt and self.prompt ~= "" then
      local p = self.prompt
      if #p > inner_w then p = p:sub(1, inner_w) end
      screen:write(win, row, bo, p)
      row = row + 1
    end

    -- The text field: render the buffer, then overlay the cursor glyph.
    -- When the cursor is past the last char, the glyph sits in the
    -- trailing empty cell — that's what tells the user the field is live.
    if row < h - bo then
      local txt = self._buffer
      if #txt > inner_w then
        -- If the buffer is wider than the field, scroll so the cursor
        -- stays in view (right-aligned to the cursor position).
        local start = math.max(1, self._cursor - inner_w)
        txt = txt:sub(start, start + inner_w - 1)
        local cur_in_view = self._cursor - start + 1
        screen:write(win, row, bo, txt)
        if cur_in_view >= 1 and cur_in_view <= inner_w then
          screen:write(win, row, bo + cur_in_view - 1, self.cursor_glyph,
                       { attrs = "reverse" })
        end
      else
        screen:write(win, row, bo, txt)
        local cx = self._cursor - 1  -- 0-based offset in the rendered text
        if cx >= 0 and cx < inner_w then
          screen:write(win, row, bo + cx, self.cursor_glyph,
                       { attrs = "reverse" })
        end
      end
    end
  end

  -- ── focus handler interface ─────────────────────────────────────

  --- Returns true iff the input consumed the key. Unknown printable
  --- bytes are inserted; everything else is dropped (returned false).
  ---@param key    integer
  ---@param driver table?
  ---@return boolean handled
  function self:on_key(key, driver)
    if type(key) ~= "number" then return false end
    local b = self._bindings

    if b.cancel[key] then
      if self.on_cancel then self:on_cancel(driver) end
      return true
    end
    if b.submit[key] then
      self:submit(driver)
      return true
    end
    if b.backspace[key] then
      self:backspace()
      return true
    end
    if b.delete[key] then
      self:delete_forward()
      return true
    end
    if b.left[key] then
      if self._cursor > 1 then self._cursor = self._cursor - 1 end
      return true
    end
    if b.right[key] then
      if self._cursor <= #self._buffer then self._cursor = self._cursor + 1 end
      return true
    end
    if b.home[key] then
      self._cursor = 1
      return true
    end
    if b["end"][key] then
      self._cursor = #self._buffer + 1
      return true
    end

    -- Printable byte → insert. Use the shared predicate from keys.lua
    -- so the rule (32..126) lives in one place.
    if keys_mod.is_printable(key) then
      self:insert_byte(key)
      return true
    end

    return false
  end

  return self
end

return M

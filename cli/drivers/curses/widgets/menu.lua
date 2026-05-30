-- cli/drivers/curses/widgets/menu.lua
--
-- Hierarchical menu widget (ui_idea.md §5.3 + §M7). Renders a centred,
-- optionally bordered box containing a list of selectable items. Acts
-- as both a *view* (paints into the screen each compose) and a *focus
-- handler* (consumes keys via on_key) so callers can push it onto both
-- the view stack and the focus stack the way the dialog does.
--
-- Item shapes — every item is a plain table; `kind` selects how it
-- renders and whether it can be highlighted:
--
--   { kind = "item",    label, hotkey?, action? }   -- selectable row
--   { kind = "divider"                          }   -- horizontal rule
--   { kind = "header",  label                   }   -- non-selectable label
--
-- `kind` defaults to "item" when absent. `hotkey` is optional per item
-- (single-char string or integer byte); a key press matching any item's
-- hotkey jumps to that item and activates it without needing an Enter.
-- Items with no hotkey are reachable only via the cursor + Enter.
--
-- Navigation: Up / Down move the cursor and automatically skip over
-- non-selectable kinds (divider, header). Wrapping is on by default —
-- moving past the last selectable item wraps to the first, and vice
-- versa. Enter (CR / LF / KEY_ENTER) activates the current item. ESC
-- (and any author-configured cancel key) closes the menu via on_cancel.
--
-- Customisation:
--   * `border`           — draw an ASCII box (default true).
--   * `title`            — string drawn on top border like the dialog.
--   * `highlight_attrs`  — attrs table passed to screen:write when
--                          painting the current item; default uses the
--                          "reverse" attribute. Pass {} to disable, or
--                          a fresh table to recolour.
--   * `divider_glyph`    — single char filled across the divider row
--                          (default "-").
--   * `header_attrs`     — attrs for header rows (default bold).
--   * `keys`             — per-widget key binding overrides, see below.
--   * `wrap`             — false to disable cursor wrap-around.
--
-- The `keys` opt overrides individual bindings. Defaults come from
-- `cli/drivers/curses/keys.lua`. Provide a table whose values are
-- either an integer key code or an array of integer key codes:
--
--   keys = { up    = K.KEY_UP,
--            down  = K.KEY_DOWN,
--            page_up   = K.KEY_PPAGE,
--            page_down = K.KEY_NPAGE,
--            activate  = { K.CR, K.LF, K.KEY_ENTER, K.SPACE },
--            cancel    = { K.ESC, string.byte("q") } }
--
-- Submenu support is intentionally *not* baked into the widget itself.
-- The recommended pattern: an item's `action` callback receives the
-- driver; if it wants to open a submenu it pushes a new menu onto the
-- driver's view + focus stacks (and pops it again when closed). This
-- keeps the widget unaware of stack semantics.

local keys_mod = require("cli.drivers.curses.keys")

local M = {}

-- ── helpers ────────────────────────────────────────────────────────────

--- Normalise a hotkey field (single-char string or integer) to a byte.
--- Returns nil when no hotkey was provided.
---@param key any
---@return integer?
local function key_to_byte(key)
  if type(key) == "number" then return key end
  if type(key) == "string" and #key >= 1 then return string.byte(key, 1) end
  return nil
end

--- Convert a binding value (int OR int[]) to a `set[int] = true` lookup
--- so `keymatch(set, code)` is a single table read.
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

--- Build the resolved key-binding table by overlaying `user` (whose
--- values may be ints or int arrays) onto the defaults. Each resolved
--- value is a set for O(1) match in on_key.
---@param user table?
---@return table bindings   { up=set, down=set, activate=set, cancel=set, ... }
local function resolve_bindings(user)
  user = user or {}
  local K = keys_mod
  local defaults = {
    up        = { K.KEY_UP },
    down      = { K.KEY_DOWN },
    page_up   = { K.KEY_PPAGE },
    page_down = { K.KEY_NPAGE },
    home      = { K.KEY_HOME },
    ["end"]   = { K.KEY_END },
    activate  = { K.CR, K.LF, K.KEY_ENTER },
    cancel    = { K.ESC },
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

--- Is the item at `idx` selectable? Dividers and headers are skipped
--- by the cursor.
---@param items table[]
---@param idx integer
---@return boolean
local function is_selectable(items, idx)
  local it = items[idx]
  if not it then return false end
  local kind = it.kind or "item"
  return kind == "item"
end

--- First selectable index starting at `start`, scanning forward (step=+1)
--- or backward (step=-1). Returns nil if none found within bounds.
---@param items table[]
---@param start integer
---@param step  integer  +1 or -1
---@return integer?
local function first_selectable_from(items, start, step)
  local i = start
  while i >= 1 and i <= #items do
    if is_selectable(items, i) then return i end
    i = i + step
  end
  return nil
end

--- Index of the *next* selectable item from `cur`, stepping by `step`.
--- Honours `wrap`. Returns `cur` if no other selectable item exists
--- (degenerate case: a one-item menu).
---@param items table[]
---@param cur   integer
---@param step  integer
---@param wrap  boolean
---@return integer
local function step_selectable(items, cur, step, wrap)
  local n = #items
  if n == 0 then return cur end
  local i = cur + step
  while i ~= cur do
    if i < 1 then
      if not wrap then return cur end
      i = n
    elseif i > n then
      if not wrap then return cur end
      i = 1
    end
    if i == cur then break end
    if is_selectable(items, i) then return i end
    i = i + step
  end
  return cur
end

--- Render one item to a single-line string for paint. Item rendering is
--- intentionally tiny — width-fitting / attribute selection happens in
--- the paint pass, this helper just produces the visible text portion.
---@param item table
---@param inner_w integer
---@return string text  the label text (no padding)
---@return string?hotkey_display  "(k)" suffix or nil
local function render_item_text(item, inner_w)
  local kind = item.kind or "item"
  if kind == "divider" then return "", nil end
  if kind == "header"  then return tostring(item.label or ""), nil end

  local label = tostring(item.label or "")
  local hk_byte = key_to_byte(item.hotkey)
  if hk_byte then
    -- Display the hotkey as "[k] Label" — matches the dialog button
    -- aesthetic and gives a visual cue. The bracket is the only
    -- decoration the menu adds on top of the author's label.
    local ch = string.char(hk_byte)
    return "[" .. ch .. "] " .. label, nil
  end
  return label, nil
end

--- Compute the box geometry given the screen size and item set.
---@param self        table
---@param screen_rows integer
---@param screen_cols integer
---@return integer x
---@return integer y
---@return integer w
---@return integer h
local function compute_geometry(self, screen_rows, screen_cols)
  -- Content width = longest rendered item line OR title (with border padding).
  local content_w = 0
  for _, item in ipairs(self.items) do
    local text = render_item_text(item, math.huge)
    if #text > content_w then content_w = #text end
  end
  if self.title then
    local tw = #self.title + 4  -- "+- Title -+" overhead
    if tw > content_w then content_w = tw end
  end

  local inner_w = math.max(self.min_w or 12, content_w)
  inner_w = math.min(inner_w, self.max_w or math.huge,
                     screen_cols - (self.border and 2 or 0))
  if inner_w < 1 then inner_w = 1 end

  local inner_h = math.max(1, #self.items)
  local w = inner_w + (self.border and 2 or 0)
  local h = inner_h + (self.border and 2 or 0)
  if w > screen_cols then w = screen_cols end
  if h > screen_rows then h = screen_rows end

  local x = math.floor((screen_cols - w) / 2)
  local y = math.floor((screen_rows - h) / 2)
  if x < 0 then x = 0 end
  if y < 0 then y = 0 end
  return x, y, w, h
end

-- ── public API ─────────────────────────────────────────────────────────

--- Construct a menu widget.
---@param opts table  {
---   title?           : string                     top-border title
---   items            : table[]                    items (see top of file)
---   on_activate?     : function(self, item, driver)
---                                                 fires after item.action
---   on_cancel?       : function(self, driver)     fires on ESC / cancel
---   border?          : boolean                    default true
---   wrap?            : boolean                    default true
---   min_w?           : integer                    minimum inner width (12)
---   max_w?           : integer                    maximum inner width
---   z?               : integer                    view z-order (default 100)
---   highlight_attrs? : table                      attrs for current item
---                                                 (default {attrs="reverse"})
---   header_attrs?    : table                      attrs for header items
---                                                 (default {attrs="bold"})
---   divider_glyph?   : string                     single char (default "-")
---   keys?            : table                      binding overrides
--- }
---@return table menu
function M.new(opts)
  opts = opts or {}
  assert(type(opts.items) == "table", "menu: items must be a table")

  local self = {
    kind          = "menu",
    title         = opts.title,
    items         = opts.items,
    on_activate   = opts.on_activate,
    on_cancel     = opts.on_cancel,
    border        = opts.border ~= false,           -- default true
    wrap          = opts.wrap ~= false,             -- default true
    min_w         = opts.min_w,
    max_w         = opts.max_w,
    z             = opts.z or 100,
    highlight_attrs = opts.highlight_attrs or { attrs = "reverse" },
    header_attrs    = opts.header_attrs    or { attrs = "bold" },
    divider_glyph   = (opts.divider_glyph and #opts.divider_glyph >= 1)
                        and opts.divider_glyph:sub(1, 1) or "-",
    _bindings = resolve_bindings(opts.keys),
  }

  -- Cache normalised hotkey bytes alongside each item for cheap dispatch.
  for _, it in ipairs(self.items) do
    if it.hotkey then it._hotkey_byte = key_to_byte(it.hotkey) end
  end

  -- Initial cursor: first selectable item, or 0 if none.
  self._cursor = first_selectable_from(self.items, 1, 1) or 0

  -- ── selection helpers (public for tests / external callers) ──────

  --- Index of the currently highlighted item (0 if none selectable).
  ---@return integer
  function self:cursor() return self._cursor end

  --- Return the item currently under the cursor, or nil.
  ---@return table?
  function self:selected()
    if self._cursor == 0 then return nil end
    return self.items[self._cursor]
  end

  --- Move the cursor explicitly. Snaps to the nearest selectable item
  --- searching forward from `idx`; if none found, searches backward.
  --- Out-of-range inputs are clamped. No-op if no items are selectable.
  ---@param idx integer
  function self:set_cursor(idx)
    if #self.items == 0 then self._cursor = 0; return end
    if idx < 1 then idx = 1 end
    if idx > #self.items then idx = #self.items end
    local fwd = first_selectable_from(self.items, idx, 1)
    if fwd then self._cursor = fwd; return end
    local bwd = first_selectable_from(self.items, idx, -1)
    self._cursor = bwd or 0
  end

  --- Fire the action / on_activate callbacks for the item at the cursor.
  --- Returns true if anything fired (i.e. cursor pointed at a selectable
  --- item), false otherwise. Public so tests can drive activation
  --- without going through on_key.
  ---@param driver table?
  ---@return boolean
  function self:activate(driver)
    local item = self:selected()
    if not item then return false end
    if item.action then item.action(driver, item) end
    if self.on_activate then self:on_activate(item, driver) end
    return true
  end

  -- ── paint (view interface) ──────────────────────────────────────

  --- Paint into a freshly-allocated centred window. Always allocates a
  --- single window — z-order handled by `self.z` (default 100, above
  --- the base game frame). Borders, title, divider rows, and the
  --- highlighted cursor row are all written here.
  ---@param screen table
  ---@param _ctx   table?
  function self:paint(screen, _ctx)
    local x, y, w, h = compute_geometry(self, screen.rows, screen.cols)
    local win = screen:add_window({ x = x, y = y, w = w, h = h, z = self.z })
    screen:fill(win, 0, 0, w, h, " ")

    -- Borders: same ASCII glyphs as the dialog widget so the two look
    -- like they were made by the same hand.
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
    for i, item in ipairs(self.items) do
      local row = bo + (i - 1)
      if row >= h - bo then break end
      local kind = item.kind or "item"
      if kind == "divider" then
        screen:fill(win, row, bo, inner_w, 1, self.divider_glyph)
      else
        local text = render_item_text(item, inner_w)
        if #text > inner_w then text = text:sub(1, inner_w) end
        local attrs = nil
        if kind == "header" then
          attrs = self.header_attrs
        elseif i == self._cursor then
          attrs = self.highlight_attrs
        end
        -- For the highlighted row we pad to inner_w so the whole row
        -- visibly inverts, not just the label text — looks correct in
        -- both ncurses and the buffer backend.
        if i == self._cursor and #text < inner_w then
          text = text .. string.rep(" ", inner_w - #text)
        end
        screen:write(win, row, bo, text, attrs)
      end
    end
  end

  -- ── focus handler interface ─────────────────────────────────────

  --- Returns true iff the menu consumed the key. The driver's focus
  --- stack relies on the returned boolean to decide whether to fall
  --- through to the base key handler.
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
    if b.up[key]   then self._cursor = step_selectable(self.items, self._cursor, -1, self.wrap); return true end
    if b.down[key] then self._cursor = step_selectable(self.items, self._cursor,  1, self.wrap); return true end
    if b.home[key] then
      local f = first_selectable_from(self.items, 1, 1)
      if f then self._cursor = f end
      return true
    end
    if b["end"][key] then
      local f = first_selectable_from(self.items, #self.items, -1)
      if f then self._cursor = f end
      return true
    end
    if b.activate[key] then
      self:activate(driver)
      return true
    end

    -- Per-item hotkey: jump and activate.
    for i, item in ipairs(self.items) do
      if item._hotkey_byte and item._hotkey_byte == key and is_selectable(self.items, i) then
        self._cursor = i
        self:activate(driver)
        return true
      end
    end

    return false
  end

  return self
end

return M

-- cli/drivers/curses/backend_curses.lua
--
-- Curses backend for the M2 hello-world driver. This is the **only** file
-- in the project that calls `require("curses")` directly; the rest of the
-- curses driver works in terms of this backend's API so the screen-model
-- split landing in §M3 has a single seam to redirect.
--
-- Public surface:
--
--   M.is_available()                       -> bool
--   M.new({ curses = <mod>? }) -> backend
--   backend:init()                         -> ok, reason?
--   backend:close()
--   backend:append_narration(items)        -- accumulate scrollback
--   backend:paint(choices, choices_active) -- repaint the full screen
--   backend:read_choice(num_choices)       -> idx | nil
--
-- The `curses` field on opts is an injection seam for tests; in normal
-- use the backend resolves it via `require("curses")` on init.
--
-- Layout (whatever the terminal reports; reflowed on each paint):
--
--   ┌──────────────────────────────────────────────────────────┐
--   │ narration scrollback (most-recent tail fits the region)  │
--   │                                                          │
--   ├──────────────────────────────────────────────────────────┤
--   │ 1. First choice                                          │
--   │ 2. Second choice                                         │
--   │ ...                                                      │
--   │ Choice (1-N, q to quit):                                 │
--   └──────────────────────────────────────────────────────────┘

local M = {}

--- Probe lcurses availability without binding to it.
--- Used by callers (driver init, smoke tests) that want to fall back to
--- the plain driver when ncurses packaging is missing.
---@return boolean
function M.is_available()
  local ok = pcall(require, "curses")
  return ok
end

--- Convert the engine's structured narration list into plain text lines,
--- one per physical line. `say` items become "Speaker: text"; narration
--- items pass through. Multi-line text is split on `\n`.
---@param items table?  narration list from engine.render_scene
---@return string[]
local function narration_to_lines(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    local text
    if item.kind == "say" then
      local label = item.display or item.speaker or "?"
      text = label .. ": " .. tostring(item.text or "")
    elseif item.text and item.text ~= "" then
      text = tostring(item.text)
    end
    if text then
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
      end
    end
  end
  return out
end

--- Truncate a string to at most `n` characters. Pure helper.
---@param s string
---@param n integer
---@return string
local function clip(s, n)
  if n <= 0 then return "" end
  if #s <= n then return s end
  return s:sub(1, n)
end

--- Construct a new backend instance.
---@param opts table?  { curses = <module>? }
---@return table backend
function M.new(opts)
  opts = opts or {}

  local backend = {
    _curses       = opts.curses,   -- nil → resolved lazily on init()
    _stdscr       = nil,
    _active       = false,
    _narr_lines   = {},
  }

  -- ── Lifecycle ──────────────────────────────────────────────

  --- Resolve the curses module (cached). Returns the module or nil.
  local function resolve_curses()
    if backend._curses then return backend._curses end
    local ok, mod = pcall(require, "curses")
    if not ok then return nil end
    backend._curses = mod
    return mod
  end

  --- Initialise the terminal. Idempotent.
  --- Returns (false, reason) if lcurses cannot be loaded.
  ---@return boolean ok
  ---@return string? reason
  function backend:init()
    if self._active then return true end
    local curses = resolve_curses()
    if not curses then
      return false, "lcurses module not available"
    end
    self._stdscr = curses.initscr()
    pcall(function() curses.cbreak() end)
    pcall(function() curses.echo(false) end)
    pcall(function() curses.curs_set(0) end)
    if self._stdscr and self._stdscr.keypad then
      pcall(function() self._stdscr:keypad(true) end)
    end
    self._active = true
    return true
  end

  --- Restore the terminal. Idempotent.
  function backend:close()
    if not self._active then return end
    local curses = self._curses
    if curses then
      local ended = curses.isendwin and curses.isendwin()
      if not ended then
        pcall(function() curses.curs_set(1) end)
        pcall(function() curses.endwin() end)
      end
    end
    self._active = false
  end

  -- ── State accumulation ─────────────────────────────────────

  --- Append the latest narration into the rolling history. The history
  --- is what the next `paint` will show in the top region.
  ---@param items table?  scene_output.narration
  function backend:append_narration(items)
    for _, l in ipairs(narration_to_lines(items)) do
      self._narr_lines[#self._narr_lines + 1] = l
    end
  end

  -- ── Painting ───────────────────────────────────────────────

  --- Repaint the full screen: scrollback narration, separator, choices,
  --- and the prompt status line at the bottom.
  ---@param choices       table?    list of {index, label}
  ---@param choices_active boolean  true to show the "Choice (1-N)" prompt
  function backend:paint(choices, choices_active)
    if not self._active then return end
    local stdscr = self._stdscr
    local rows, cols = stdscr:getmaxyx()
    choices = choices or {}

    -- Region heights: prompt(1) + separator(1) + choices(N) + narration(rest)
    local prompt_h    = 1
    local separator_h = 1
    local choices_h   = #choices
    local narr_h      = rows - prompt_h - separator_h - choices_h
    if narr_h < 1 then narr_h = 1 end

    stdscr:clear()

    -- Narration: bottom-aligned tail (most-recent fits).
    local first = math.max(1, #self._narr_lines - narr_h + 1)
    local row = 0
    for i = first, #self._narr_lines do
      stdscr:mvaddstr(row, 0, clip(self._narr_lines[i], cols - 1))
      row = row + 1
      if row >= narr_h then break end
    end

    -- Separator (drawn only if it fits).
    local sep_y = narr_h
    if sep_y < rows - prompt_h then
      stdscr:mvaddstr(sep_y, 0, string.rep("-", math.max(1, cols - 1)))
    end

    -- Choices.
    local cy = sep_y + separator_h
    for i, c in ipairs(choices) do
      if cy >= rows - prompt_h then break end
      stdscr:mvaddstr(cy, 0, clip(i .. ". " .. tostring(c.label or ""), cols - 1))
      cy = cy + 1
    end

    -- Prompt status line at the very bottom.
    local prompt
    if choices_active and #choices > 0 then
      prompt = "Choice (1-" .. #choices .. ", q to quit): "
    else
      prompt = "(press q or ESC to quit)"
    end
    stdscr:mvaddstr(rows - 1, 0, clip(prompt, cols - 1))

    stdscr:refresh()
  end

  -- ── Input ──────────────────────────────────────────────────

  local KEY_ESC = 27

  --- Block on getch and translate to a 1-based choice index. Returns
  --- nil for q/Q/ESC (quit). Ignores other keys.
  ---@param num_choices integer
  ---@return integer? idx
  function backend:read_choice(num_choices)
    if not self._active then return nil end
    while true do
      local key = self._stdscr:getch()
      if not key or key == -1 then return nil end
      if key == KEY_ESC then return nil end
      if key == string.byte("q") or key == string.byte("Q") then
        return nil
      end
      if key >= string.byte("1") and key <= string.byte("9") then
        local d = key - string.byte("0")
        if d >= 1 and d <= num_choices then return d end
      end
    end
  end

  return backend
end

return M

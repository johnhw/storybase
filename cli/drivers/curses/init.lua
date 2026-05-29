-- cli/drivers/curses/init.lua
-- Curses UI driver for StoryBase (ui_idea.md §M3: screen model + dual backends).
--
-- The driver paints into a retained 2D cell grid (`screen.lua`) and
-- flushes only dirty regions (`paint.lua`) to a backend. Two backends
-- ship with the driver:
--
--   * backend_curses : the real ncurses surface. Selected by default,
--                      and the only backend that loads `lcurses`.
--   * backend_buffer : an in-memory grid for headless tests and as a
--                      no-tty fallback when lcurses is unavailable.
--
-- Pull-mode (engine calls `driver:render(scene_output)` + `prompt(choices)`)
-- remains the dispatch path for §M3 to keep parity with §M2. §M4 wires
-- in author bindings; §M5 flips the dispatch to kernel-driven event
-- subscription for reactive widgets.
--
-- Activate with: `storybase run game.sb --ui curses`.
--
-- Headless tests pick the buffer backend via `opts.backend = "buffer"`
-- and consume the resulting grid via the backend's `snapshot()` helper.

local M = {}

local screen_mod      = require("cli.drivers.curses.screen")
local paint_mod       = require("cli.drivers.curses.paint")
local backend_curses  = require("cli.drivers.curses.backend_curses")
local backend_buffer  = require("cli.drivers.curses.backend_buffer")

-- Default geometry when the ncurses backend can't report a size yet (the
-- buffer backend always uses these). Real ncurses ignores them and uses
-- `getmaxyx` after `initscr`.
local DEFAULT_ROWS = 24
local DEFAULT_COLS = 80

--- Probe lcurses availability — the CLI uses this to decide whether to
--- print a "install lcurses" hint when `--ui curses` was requested.
---@return boolean
function M.is_available()
  return backend_curses.is_available()
end

--- Convert engine narration items into plain text lines. `say` items
--- become "Speaker: text"; narration items pass through. Multi-line
--- text is split on newline so each physical line fits one row.
---@param items table?  scene_output.narration
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

--- Create a new curses driver.
---
--- Opts:
---   backend : "ncurses" (default) | "buffer"
---   curses  : module override for the ncurses backend (test seam)
---   rows    : forced initial geometry; ncurses overrides on init.
---             defaults to 24 (ncurses) or 24 (buffer).
---   cols    : forced initial geometry; ncurses overrides on init.
---             defaults to 80.
---
--- Lifecycle: `M.new` is lightweight — no terminal is touched until
--- the first `render`/`prompt`. That keeps `is_driver()` and tests
--- without a TTY safe.
---@param opts table?
---@return table driver
function M.new(opts)
  opts = opts or {}
  local kind = opts.backend or "ncurses"

  local backend
  if kind == "buffer" then
    backend = backend_buffer.new({
      rows = opts.rows or DEFAULT_ROWS,
      cols = opts.cols or DEFAULT_COLS,
      keys = opts.keys,
    })
  elseif kind == "ncurses" then
    backend = backend_curses.new({ curses = opts.curses })
  else
    error("cli/drivers/curses: unknown backend '" .. tostring(kind) .. "'", 2)
  end

  local driver = {
    _opts        = opts,
    _kind        = kind,
    _backend     = backend,
    _kernel      = nil,
    _initialised = false,
    _screen      = nil,
    _narr_lines  = {},  -- scrollback history (engine-side text lines)
  }

  --- Lazily call backend:init on first paint. Errors with a clear
  --- message if lcurses cannot be loaded so callers can fall back to
  --- `--ui plain` rather than seeing an opaque module-load failure.
  local function ensure_init(self)
    if self._initialised then return end
    local rows = opts.rows or DEFAULT_ROWS
    local cols = opts.cols or DEFAULT_COLS
    local ok, reason = self._backend:init(rows, cols)
    if not ok then
      error("cli/drivers/curses: " .. tostring(reason)
            .. " — install lcurses or use --ui plain", 2)
    end
    -- For ncurses, the real terminal size lives in the backend after
    -- init. The buffer backend reports what we passed in.
    local br, bc = self._backend:size()
    if br > 0 and bc > 0 then rows, cols = br, bc end
    self._screen = screen_mod.new(rows, cols)
    self._initialised = true
  end

  --- Compose the screen for one frame: narration tail, separator,
  --- choices, and the prompt status line. Returns nothing — paints
  --- into the screen's `_cells` grid. The caller then flushes.
  ---@param self table
  ---@param choices table?
  ---@param choices_active boolean
  local function compose(self, choices, choices_active)
    choices = choices or {}
    local rows = self._screen.rows
    local cols = self._screen.cols
    self._screen:clear()
    self._screen:clear_windows()

    local prompt_h    = 1
    local separator_h = 1
    local choices_h   = #choices
    local narr_h      = rows - prompt_h - separator_h - choices_h
    if narr_h < 1 then narr_h = 1 end

    -- Allocate windows so §M5+ widgets can repaint regions individually.
    local narr_win = self._screen:add_window({ x = 0, y = 0, w = cols, h = narr_h })
    local sep_y = narr_h
    local sep_win = self._screen:add_window({ x = 0, y = sep_y, w = cols, h = 1 })
    local choices_y = sep_y + separator_h
    local choices_win = self._screen:add_window({
      x = 0, y = choices_y, w = cols, h = math.max(1, choices_h),
    })
    local prompt_win = self._screen:add_window({
      x = 0, y = rows - 1, w = cols, h = 1,
    })

    -- Narration: bottom-aligned tail.
    local first = math.max(1, #self._narr_lines - narr_h + 1)
    local wy = 0
    for i = first, #self._narr_lines do
      self._screen:write(narr_win, wy, 0, self._narr_lines[i])
      wy = wy + 1
      if wy >= narr_h then break end
    end

    -- Separator (only drawn if it fits below narration and above prompt).
    if sep_y < rows - prompt_h then
      self._screen:fill(sep_win, 0, 0, cols, 1, "-")
    end

    -- Choices.
    for i, c in ipairs(choices) do
      if i > choices_win.h then break end
      local label = i .. ". " .. tostring(c.label or "")
      self._screen:write(choices_win, i - 1, 0, label)
    end

    -- Prompt.
    local prompt
    if choices_active and #choices > 0 then
      prompt = "Choice (1-" .. #choices .. ", q to quit): "
    else
      prompt = "(press q or ESC to quit)"
    end
    self._screen:write(prompt_win, 0, 0, prompt)
  end

  --- Compose and flush a single frame. Only dirty cells reach the backend.
  local function flush_frame(self)
    local rects = paint_mod.diff(self._screen)
    self._backend:flush(self._screen, rects)
    self._screen:commit()
  end

  -- ── Driver protocol ───────────────────────────────────────────

  function driver:render(scene_output)
    ensure_init(self)
    scene_output = scene_output or {}
    for _, line in ipairs(narration_to_lines(scene_output.narration)) do
      self._narr_lines[#self._narr_lines + 1] = line
    end
    -- Paint without an active choice prompt; the engine will follow up
    -- with `prompt()` when it wants input.
    compose(self, scene_output.choices, false)
    flush_frame(self)
  end

  function driver:prompt(choices)
    ensure_init(self)
    compose(self, choices, true)
    flush_frame(self)
    return self:_read_choice(#(choices or {}))
  end

  function driver:notify(_event, _data)
    -- Pull-mode driver. Live event delivery via the kernel lands at §M5
    -- when the first reactive widget (stat-bar) starts subscribing.
  end

  function driver:attach(kernel)
    self._kernel = kernel
  end

  function driver:tick(_dt)
    -- §8.4 frame loop ticks live at §M5+ once reactive widgets exist.
  end

  function driver:detach()
    self._kernel = nil
    if self._backend and self._backend.close then
      pcall(function() self._backend:close() end)
    end
    self._initialised = false
    self._screen = nil
  end

  -- ── Input dispatch ────────────────────────────────────────────

  local KEY_ESC = 27

  --- Block on the backend's `read_key` and translate keypresses to a
  --- 1-based choice index. Returns nil for q/Q/ESC (quit). Ignores
  --- out-of-range digits and unrecognised keys.
  ---@param num_choices integer
  ---@return integer? idx
  function driver:_read_choice(num_choices)
    if not self._initialised then return nil end
    while true do
      local key = self._backend:read_key()
      if not key then return nil end
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

  -- ── Driver-private hooks for tests ────────────────────────────

  --- Expose the screen and backend so tests can introspect dirty rects
  --- and snapshot grids. Not part of the driver protocol.
  function driver:_screen_handle() return self._screen end
  function driver:_backend_handle() return self._backend end

  return driver
end

return M

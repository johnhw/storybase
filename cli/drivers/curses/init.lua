-- cli/drivers/curses/init.lua
-- Curses UI driver for storybase (ui_idea.md §M2 hello-world).
--
-- A pull-mode replacement for the plain driver, rendered via lcurses.
-- Implements the driver protocol declared in `cli/drivers/driver.lua`:
-- the engine still calls `render(scene_output)` + `prompt(choices)`;
-- this driver just paints into the terminal via ncurses and reads digit
-- keys for choices.
--
-- The screen-model split (§M3) replaces the simple paint here with a
-- diff-against-previous-frame buffer; the two ncurses/string backends
-- land at that milestone. For now, all curses calls live in
-- `backend_curses.lua` so M3 has a single seam.
--
-- Activate with: `storybase run game.sb --ui curses`
--
-- Tests inject a stub curses module via `opts.curses` so the driver
-- logic can be exercised headlessly. See tests/ui/curses_driver_spec.lua.

local M = {}

local backend_curses = require("cli.drivers.curses.backend_curses")

--- Probe lcurses availability via the backend.
---@return boolean
function M.is_available()
  return backend_curses.is_available()
end

--- Create a new curses driver. `M.new()` is lightweight: it does not
--- call `initscr()` until the first `render`/`prompt`, so creating a
--- driver and immediately calling `is_driver()` in a test environment
--- without a TTY is safe.
---@param opts table?  { curses = <mod>?,    -- injection for tests
---                      io_out, io_in }     -- accepted for symmetry
---@return table driver
function M.new(opts)
  opts = opts or {}

  local backend = backend_curses.new(opts)

  local driver = {
    _opts        = opts,
    _kernel      = nil,
    _backend     = backend,
    _initialised = false,
  }

  --- Lazily call backend:init on first paint. Errors with a clear
  --- message if lcurses cannot be loaded, so callers can fall back to
  --- `--ui plain` rather than seeing an opaque module-load failure.
  local function ensure_init(self)
    if self._initialised then return end
    local ok, reason = self._backend:init()
    if not ok then
      error("cli/drivers/curses: " .. tostring(reason)
            .. " — install lcurses or use --ui plain", 2)
    end
    self._initialised = true
  end

  function driver:render(scene_output)
    ensure_init(self)
    scene_output = scene_output or {}
    self._backend:append_narration(scene_output.narration)
    -- Paint without an active choice prompt; the engine will follow up
    -- with `prompt()` if it wants input. This pre-paint guarantees the
    -- player sees the latest scene even when the game ends mid-turn
    -- (engine calls render with empty choices for ending narration).
    self._backend:paint(scene_output.choices, false)
  end

  function driver:prompt(choices)
    ensure_init(self)
    self._backend:paint(choices, true)
    return self._backend:read_choice(#(choices or {}))
  end

  function driver:notify(_event, _data)
    -- Pull-mode driver: live events arrive via the kernel only once the
    -- §M3 screen-model split rewires the dispatch path. Until then this
    -- is a no-op so callers can fire events without consequence.
  end

  function driver:attach(kernel)
    -- The kernel exists (§M1); §M3 will wire subscriptions for the
    -- reactive widgets. For M2 we just store the handle so the kernel
    -- can be reached when the driver is asked to do something richer
    -- than render+prompt.
    self._kernel = kernel
  end

  function driver:tick(_dt)
    -- §8.4 frame loop ticks live at §M3 once the screen model lands.
  end

  function driver:detach()
    self._kernel = nil
    if self._backend and self._backend.close then
      pcall(function() self._backend:close() end)
    end
    self._initialised = false
  end

  return driver
end

return M

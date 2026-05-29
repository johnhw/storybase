-- cli/drivers/curses/init.lua
-- Curses UI driver for storybase (scaffold).
--
-- Implements the driver protocol declared in `cli/drivers/driver.lua`.
-- This file is the M2 scaffold per ui_idea.md §M2: a structural stub
-- that satisfies the contract so the driver registry, tests, and
-- documentation can wire against it. The functional implementation
-- (screen model, two backends, widgets, view stack, focus, paint diff)
-- is laid out in ui_idea.md §8 and ships across §M2–§M8.
--
-- Current behaviour:
--   - M.new(opts) returns a driver table that satisfies is_driver().
--   - render/prompt raise a clear "not yet implemented" error so
--     accidental wiring fails loudly rather than silently no-op'ing.
--   - attach/tick/detach are no-ops (forward-compatible with the §M1
--     kernel that will drive them).
--   - This driver is intentionally NOT yet registered in the
--     `cli.ui` enum (runtime/engine.lua). It cannot be selected via
--     `--ui curses` until a functional render path exists. The folder
--     is in place so each §8.3 file (screen.lua, backend_curses.lua,
--     backend_buffer.lua, layout.lua, focus.lua, paint.lua,
--     view_stack.lua, widgets/*) lands here without further plumbing.

local M = {}

local NOT_IMPLEMENTED = "cli/drivers/curses: not yet implemented; "
                     .. "see ui_idea.md §M2–§M8 for the milestone plan"

--- Create a new curses driver scaffold.
-- @param opts table?  reserved for future use:
--                       backend = "ncurses" | "buffer" (default ncurses)
--                       w, h    = forced dimensions for the buffer backend
-- @return table  driver scaffold (satisfies driver.lua contract)
function M.new(opts)
  opts = opts or {}

  local driver = {
    _opts    = opts,
    _kernel  = nil,
    _backend = nil,  -- placeholder for screen-model backend (§8.2)
  }

  function driver:render(_scene_output)
    error(NOT_IMPLEMENTED, 2)
  end

  function driver:prompt(_choices)
    error(NOT_IMPLEMENTED, 2)
  end

  function driver:notify(_event, _data)
    -- The kernel (§M1) will be the source of live events. Until then,
    -- pull-mode hosts may call notify; the scaffold tolerates it.
  end

  function driver:attach(kernel)
    self._kernel = kernel
    -- §M1 wiring: subscribe to kernel events, request initial full
    -- paint via kernel:get_state_all() / kernel:get_scene().
  end

  function driver:tick(_dt)
    -- §8.4 frame loop: read pending key, advance animations, flush
    -- dirty regions. No-op until the screen model lands (§M3).
  end

  function driver:detach()
    self._kernel = nil
    if self._backend and self._backend.close then
      self._backend:close()
    end
    self._backend = nil
  end

  return driver
end

return M

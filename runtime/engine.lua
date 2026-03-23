-- runtime/engine.lua
-- Turn lifecycle, scene stack, time model, and top-level run loop.
--
-- Turn lifecycle (six steps):
--   1. Player action (optional — skipped for autonomous turns)
--   2. Message delivery (pending → actor inboxes)
--   3. Actor behaviors dispatched in priority order; mutations deferred
--   4. Deferred mutations applied in priority order
--   5. Scheduled events whose trigger time has arrived are fired
--   6. Inbox clearing; time-inc! tick: if time not yet advanced this turn
--
-- Phase 3 deliverable. Not yet implemented.

local M = {}

local MAX_STACK = 16  -- default scene-stack-max

--- Run a compiled game interactively (simple text REPL).
---
---@param game_table table  Compiled game table from codegen
---@param opts       table? Options: seed, production, save_path, load_path
---@return integer          Exit code
function M.run(game_table, opts)
  opts = opts or {}
  local _ = game_table

  -- Not yet implemented.
  io.stdout:write("storybase run: runtime not yet implemented\n")
  return 0
end

--- Create a new engine instance (for programmatic / test use).
---@param game_table table  Compiled game table
---@param opts       table? Options
---@return table
function M.new(game_table, opts)
  opts = opts or {}
  local eng = {
    _game        = game_table,
    _opts        = opts,
    _scene_stack = {},
    _time        = {},
    _state       = nil,   -- runtime.state instance (set on init)
    _log         = nil,   -- runtime.log instance   (set on init)
    _tick_advanced = false,
  }

  --- Return the current scene name (top of stack).
  function eng:current_scene()
    return self._scene_stack[#self._scene_stack]
  end

  --- Push a scene onto the stack.
  function eng:push_scene(name)
    if #self._scene_stack >= MAX_STACK then
      error("scene stack overflow")
    end
    self._scene_stack[#self._scene_stack + 1] = name
  end

  --- Pop the top scene from the stack and return it.
  function eng:pop_scene()
    local top = self._scene_stack[#self._scene_stack]
    self._scene_stack[#self._scene_stack] = nil
    return top
  end

  return eng
end

return M

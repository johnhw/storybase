-- runtime/debug.lua
-- WebSocket dev server, hot reload, watches, and time-travel.
--
-- The debug server runs as a coroutine alongside the engine in dev mode.
-- It opens a TCP socket on the configured port (default 7373) and speaks
-- a newline-delimited JSON protocol.  The server is compiled out entirely
-- in production builds (debug-only tag).
--
-- Emitted events: mutation, scene-change, message-sent, schedule-fired,
--   fn-call, spawn-event, despawn-event, clamp-event, reload
--
-- Accepted commands: get-state, eval, reload, set-breakpoint,
--   clear-breakpoint, time-travel, get-log
--
-- Phase 7 deliverable. Not yet implemented.

local M = {}

local DEFAULT_PORT = 7373

--- Create a new debug server instance.
---
---@param engine  table    Engine instance
---@param port    integer? TCP port (default 7373)
---@return table
function M.new(engine, port)
  local srv = {
    _engine      = engine,
    _port        = port or DEFAULT_PORT,
    _running     = false,
    _clients     = {},
    _breakpoints = {},
    _watches     = {},
  }

  --- Start the debug server (opens the TCP socket).
  function srv:start()
    -- Not yet implemented
    self._running = true
  end

  --- Stop the debug server.
  function srv:stop()
    self._running = false
  end

  --- Emit an event to all connected clients.
  ---@param event_name string
  ---@param payload    table
  function srv:emit(event_name, payload)
    if not self._running then return end
    local _ = event_name; local _ = payload
    -- Not yet implemented
  end

  --- Register a watch declaration.
  ---@param path  string   Path to watch
  ---@param label string   Display label
  function srv:watch(path, label)
    self._watches[#self._watches + 1] = { kind = "path", path = path, label = label }
  end

  --- Register a watch-when declaration.
  ---@param condition function  Predicate over state
  ---@param label     string
  function srv:watch_when(condition, label)
    self._watches[#self._watches + 1] = { kind = "cond", condition = condition, label = label }
  end

  --- Handle an incoming command from a client.
  ---@param cmd     string  Command name
  ---@param payload table   Command payload
  ---@return table          Response payload
  function srv:handle_command(cmd, payload)
    local _ = payload
    if cmd == "get-state" then return {} end
    if cmd == "eval"       then return { value = nil } end
    if cmd == "get-log"    then return { entries = {} } end
    if cmd == "time-travel" then return {} end
    return { error = "unknown command: " .. tostring(cmd) }
  end

  return srv
end

return M

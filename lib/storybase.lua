-- lib/storybase.lua
-- Public Lua interop API for StoryBase.
--
-- Usage:
--   local sb   = require("storybase")
--   local game = sb.load("game.sb")
--   game:call("move-to", "'forest")
--   local health = game:get("player/health")
--
-- Phase 8 deliverable. Not yet implemented.

local M = {}

--- Load and compile a StoryBase file, returning a game object.
---@param filepath string  Path to the .sb file
---@return table?          Game object, or nil on compile error
function M.load(filepath)
  local ok, compiler = pcall(require, "compiler.compiler")
  if not ok then
    io.stderr:write("storybase.load: could not load compiler: " .. tostring(compiler) .. "\n")
    return nil
  end

  local game_table, diags = compiler.compile_file(filepath)
  if diags:has_errors() then
    for _, d in ipairs(diags.errors) do
      io.stderr:write(string.format("%s:%d: error [%s]: %s\n",
        d.file or filepath, d.line or 0, d.code, d.message))
    end
    return nil
  end

  return M._make_game(game_table)
end

--- Create a game object from an already-compiled game table.
---@param game_table table
---@return table
function M._make_game(game_table)
  local game = {
    _table    = game_table,
    _handlers = {},  -- bounded computation handlers
    _listeners = {}, -- event listeners
  }

  --- Call a transaction function by name.
  function game:call(fn_name, ...)
    local _ = fn_name; local _ = {...}
    -- Not yet implemented
  end

  --- Read a state path value.
  ---@param path string
  ---@return any
  function game:get(path)
    local _ = path
    return nil  -- not yet implemented
  end

  --- Execute a find query.
  ---@param family  string
  ---@param clauses table
  ---@return table
  function game:find(family, clauses)
    local _ = family; local _ = clauses
    return {}  -- not yet implemented
  end

  --- Subscribe to a debug/presentation event.
  ---@param event_name string
  ---@param handler    function
  function game:on(event_name, handler)
    if not self._listeners[event_name] then
      self._listeners[event_name] = {}
    end
    self._listeners[event_name][#self._listeners[event_name] + 1] = handler
  end

  --- Dispatch a player choice by visible index.
  ---@param index integer
  function game:choose(index)
    local _ = index
    -- Not yet implemented
  end

  --- Evaluate a pure expression string.
  ---@param expr_string string
  ---@return any
  function game:eval(expr_string)
    local _ = expr_string
    return nil  -- not yet implemented
  end

  --- Create a counterfactual GameState.
  ---@param opts table   {from=tick}
  ---@param fn   function  Called with a GameState to apply transitions
  ---@return table?
  function game:counterfactual(opts, fn)
    local _ = opts; local _ = fn
    return nil  -- not yet implemented
  end

  --- Register a bounded computation Lua handler.
  ---@param name string    Dotted Lua module path (from bounded decl lua: field)
  ---@param fn   function  Handler: fn(arg, state_snapshot) -> value
  function game:register_bounded(name, fn)
    self._handlers[name] = fn
  end

  return game
end

return M

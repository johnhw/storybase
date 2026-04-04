-- lib/storybase.lua
-- Public Lua interop API for StoryBase.
--
-- Usage:
--   local sb   = require("lib.storybase")
--   local game = sb.load("game.sb")
--   game:init()
--   local narr, choices = game:render()
--   game:choose(1)
--   local health = game:get("player/health")
--   game:call("reset-day")

local M = {}

local compiler_mod = require("compiler.compiler")
local engine_mod   = require("runtime.engine")
local eval_mod     = require("runtime.eval")

-- ============================================================
-- Internal helpers
-- ============================================================

local function silent_io()
  return { write = function() end }
end

-- ============================================================
-- sb.load / sb.from_source
-- ============================================================

--- Load and compile a StoryBase file, returning a game object.
--- Returns nil + error string on compile failure.
---@param filepath string  Path to the .sb source file
---@return table?, string?
function M.load(filepath)
  local gt, diags = compiler_mod.compile_file(filepath)
  if not gt then
    return nil, "could not read file: " .. tostring(filepath)
  end

  if diags:has_errors() then
    local msgs = {}
    for _, d in ipairs(diags.errors) do
      msgs[#msgs+1] = string.format("%s:%d [%s] %s",
        d.file or filepath, d.line or 0, d.code, d.message)
    end
    return nil, table.concat(msgs, "\n")
  end

  return M._make_game(gt)
end

--- Compile StoryBase source text, returning a game object.
--- Returns nil + error string on compile failure.
---@param source   string  StoryBase source text
---@param filename string? Optional filename for diagnostics (default "inline")
---@return table?, string?
function M.from_source(source, filename)
  filename = filename or "inline"
  local gt, diags = compiler_mod.compile(source, filename)
  if not gt or diags:has_errors() then
    local msgs = {}
    for _, d in ipairs(diags and diags.errors or {}) do
      msgs[#msgs+1] = string.format("%s:%d [%s] %s",
        d.file or filename, d.line or 0, d.code, d.message)
    end
    return nil, #msgs > 0 and table.concat(msgs, "\n") or "compile failed"
  end

  return M._make_game(gt)
end

-- ============================================================
-- Game object
-- ============================================================

--- Create a game object from an already-compiled game table.
---@param game_table table  Compiled game table from codegen
---@return table
function M._make_game(game_table)
  local self = {
    _gt        = game_table,
    _eng       = nil,   -- engine, created on init()
    _handlers  = {},    -- bounded computation handlers
    _listeners = {},    -- event listeners: event_name → list of fns
  }

  -- ── Lifecycle ─────────────────────────────────────────────

  --- Initialise the game from declared defaults and set the entry scene.
  --- Must be called once before any other method.
  function self:init()
    self._eng = engine_mod.new(self._gt, { io_out = silent_io() })
    -- Wire bounded handlers
    if next(self._handlers) then
      self._eng._game._bounded_handlers = self._handlers
    end
    self._eng:init()
    return self
  end

  --- Reset to initial state (re-init from defaults).
  function self:reset()
    return self:init()
  end

  -- ── State access ──────────────────────────────────────────

  --- Read a state path value.
  ---@param path string  e.g. "player/health"
  ---@return any
  function self:get(path)
    assert(self._eng, "call game:init() first")
    return self._eng._state:get(path)
  end

  --- Set a state path value directly (bypasses transaction log).
  --- Prefer calling a transaction fn via game:call() instead.
  ---@param path  string
  ---@param value any
  function self:set(path, value)
    assert(self._eng, "call game:init() first")
    self._eng._state:set(path, value)
  end

  -- ── Presentation ──────────────────────────────────────────

  --- Render the current scene.
  --- Returns narration (list of strings) and choices (list of {index, label}).
  ---@return table, table
  function self:render()
    assert(self._eng, "call game:init() first")
    local scene_name = self._eng:current_scene()
    if not scene_name then return {}, {} end
    local narr, choices = self._eng:render_scene(scene_name)
    return narr, choices
  end

  --- Return the name of the current top-of-stack scene.
  ---@return string?
  function self:current_scene()
    assert(self._eng, "call game:init() first")
    return self._eng:current_scene()
  end

  -- ── Player input ──────────────────────────────────────────

  --- Dispatch a player choice by 1-based visible index.
  --- Runs post-action phases (actor behaviors, scheduler) after the choice.
  ---@param index integer  1-based index into the visible choice list
  ---@return boolean  true on success, false if index out of range
  function self:choose(index)
    assert(self._eng, "call game:init() first")
    local scene_name = self._eng:current_scene()
    if not scene_name then return false end

    -- Validate index against visible choice count
    local _, choices = self._eng:render_scene(scene_name)
    if index < 1 or index > #choices then return false end

    local ok, sig = pcall(function()
      return self._eng:do_choice(scene_name, index)
    end)
    if not ok then return false end

    -- Apply navigation signal
    if sig then
      if sig.type == "goto" and sig.target then
        self._eng:goto_scene(sig.target)
      elseif sig.type == "enter" and sig.target then
        self._eng:enter_scene(sig.target)
      elseif sig.type == "exit" then
        self._eng:exit_scene()
      end
    end

    -- Post-action lifecycle
    pcall(function() self._eng:post_action() end)

    -- Fire listeners
    self:_emit("choice", { index = index, scene = scene_name })
    return true
  end

  -- ── Function calls ────────────────────────────────────────

  --- Convert a raw Lua value to a minimal AST literal node for eval.
  local function to_literal(v)
    local t = type(v)
    if t == "number" then
      if math.type(v) == "float" then
        return { kind = "float_lit", value = v }
      else
        return { kind = "int_lit",   value = v }
      end
    elseif t == "boolean" then
      return { kind = "bool_lit", value = v }
    elseif t == "string" then
      -- Symbol literal if starts with '
      if v:sub(1,1) == "'" then
        return { kind = "symbol_lit", name = v:sub(2) }
      end
      return { kind = "string_lit", value = v }
    else
      -- Pass nil for unsupported types
      return { kind = "nil_lit" }
    end
  end

  --- Call a named transaction (or pure) function.
  --- Extra arguments are passed to the function as positional params.
  ---@param fn_name string
  ---@param ...     any    positional arguments (raw Lua values)
  ---@return any    return value (or nil)
  function self:call(fn_name, ...)
    assert(self._eng, "call game:init() first")
    local ctx      = self._eng:make_ctx(fn_name)
    local raw_args = { ... }
    local ast_args = {}
    for i, v in ipairs(raw_args) do
      ast_args[i] = to_literal(v)
    end
    local ok, result = pcall(eval_mod.call_fn, fn_name, ast_args, ctx)
    if not ok then
      error("game:call('" .. fn_name .. "'): " .. tostring(result), 2)
    end
    return result
  end

  -- ── Expression evaluation ─────────────────────────────────

  --- Evaluate a StoryBase expression string in the current state.
  --- Only pure expressions are supported.
  ---@param expr_string string  e.g. "player/health + 10"
  ---@return any, string?  value (or nil), error string
  function self:eval(expr_string)
    assert(self._eng, "call game:init() first")
    -- Wrap expression in a minimal compilable snippet
    local src = "module _eval\n  version: 1.0\nengine-config:\n  entry-scene: _s\n"
              .. "scene _s:\n  * Go\n    -> _s\n"
              .. "fn _expr:\n  " .. expr_string
    local gt, diags = compiler_mod.compile(src, "eval")
    if not gt or diags:has_errors() then
      return nil, "compile error in expression"
    end
    local fn_def = gt.fns and gt.fns["_expr"]
    if not fn_def then return nil, "expression failed to compile" end
    local ctx = self._eng:make_ctx("eval")
    local ok2, err = pcall(eval_mod.eval_stmts, fn_def.body, ctx)
    if not ok2 then return nil, tostring(err) end
    return ctx.retval
  end

  -- ── Bounded computations ──────────────────────────────────

  --- Register a Lua handler for a bounded computation.
  ---@param name string    Bounded declaration name
  ---@param fn   function  Handler: fn(arg, state_snapshot) -> value
  function self:register_bounded(name, fn)
    self._handlers[name] = fn
    if self._eng and self._eng._game then
      self._eng._game._bounded_handlers = self._handlers
    end
  end

  -- ── Event subscriptions ───────────────────────────────────

  --- Subscribe to a named event.
  --- Built-in events: "choice", "mutation", "scene-change"
  ---@param event_name string
  ---@param handler    function  Called with an event-specific payload table
  function self:on(event_name, handler)
    if not self._listeners[event_name] then
      self._listeners[event_name] = {}
    end
    local lst = self._listeners[event_name]
    lst[#lst+1] = handler
  end

  --- Internal: fire all listeners for an event.
  function self:_emit(event_name, payload)
    for _, h in ipairs(self._listeners[event_name] or {}) do
      pcall(h, payload)
    end
  end

  -- ── Autonomous turns ──────────────────────────────────────

  --- Advance one autonomous turn (NPC/schedule steps only; no player choice).
  function self:tick()
    assert(self._eng, "call game:init() first")
    self._eng:autonomous_turn()
  end

  -- ── Save / load ───────────────────────────────────────────

  --- Save the current game to a file (compatible with storybase run --load).
  ---@param filepath string
  ---@return boolean, string?  success, error message
  function self:save(filepath)
    assert(self._eng, "call game:init() first")
    local log_mod = require("runtime.log")
    local f, err  = io.open(filepath, "w")
    if not f then return false, err end

    f:write("-- StoryBase save file (v1)\n")
    f:write("local save = {}\n")
    f:write("save.version = 1\n")
    -- Scene stack
    f:write("save.scene_stack = {")
    local stack_parts = {}
    for _, s in ipairs(self._eng._scene_stack) do
      stack_parts[#stack_parts+1] = string.format("%q", s)
    end
    f:write(table.concat(stack_parts, ", ") .. "}\n")
    -- Log entries
    f:write("save.entries =\n")
    f:write(log_mod.serialise_entries(self._eng._log:entries()))
    f:write("\n")
    f:write("return save\n")
    f:close()
    return true
  end

  --- Load game state from a save file (resets current state).
  ---@param filepath string
  ---@return boolean, string?  success, error message
  function self:load(filepath)
    assert(self._eng, "call game:init() first")
    local log_mod   = require("runtime.log")
    local state_mod = require("runtime.state")
    local f, err    = io.open(filepath, "r")
    if not f then return false, err end
    local src = f:read("*a"); f:close()
    local fn, perr = load(src)
    if not fn then return false, "save file parse error: " .. tostring(perr) end
    local save_data = fn()
    if not save_data then return false, "save file returned nil" end

    -- Replay log into fresh state
    self._eng._state:init_defaults()
    state_mod.replay(self._eng._state, save_data.entries or {})
    if save_data.scene_stack then
      self._eng._scene_stack = save_data.scene_stack
    end
    return true
  end

  return self
end

return M

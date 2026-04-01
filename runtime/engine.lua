-- runtime/engine.lua
-- Turn lifecycle, scene stack, time model, and top-level run loop.
--
-- Turn lifecycle (six steps):
--   1. Player action (optional — skipped for autonomous turns)
--   2. Message delivery (pending → actor inboxes)  [Phase 5]
--   3. Actor behaviors dispatched in priority order [Phase 5]
--   4. Deferred mutations applied in priority order [Phase 5]
--   5. Scheduled events fired                       [Phase 4]
--   6. Inbox clearing; time-inc! tick if not yet advanced this turn
--
-- Phase 3: steps 1 and 6 (player action + time tick) are implemented.
-- Steps 2-5 are deferred to later phases.

local state_mod = require("runtime.state")
local log_mod   = require("runtime.log")
local eval      = require("runtime.eval")

local M = {}

local DEFAULT_MAX_STACK = 16

-- ============================================================
-- Engine constructor
-- ============================================================

--- Create a new engine instance.
---@param game_table table  Compiled game table from codegen
---@param opts       table? Options: seed, max_stack, io_out, io_in
---@return table
function M.new(game_table, opts)
  opts = opts or {}
  local max_stack = game_table.schema
    and game_table.schema.engine_config
    and game_table.schema.engine_config["scene-stack-max"]
    or opts.max_stack
    or DEFAULT_MAX_STACK

  local log   = log_mod.new()
  local store = state_mod.new(game_table.schema, log)

  local eng = {
    _game        = game_table,
    _opts        = opts,
    _scene_stack = {},
    _max_stack   = max_stack,
    _log         = log,
    _state       = store,
    _fns         = game_table.fns or {},
    _scenes      = game_table.scenes or {},
    _io_out      = opts.io_out or io.stdout,
    _io_in       = opts.io_in  or io.stdin,
  }

  -- ── Scene stack ─────────────────────────────────────────────

  --- Return the current scene name (top of stack), or nil.
  function eng:current_scene()
    return self._scene_stack[#self._scene_stack]
  end

  --- Push a scene name onto the stack.
  ---@param name string
  function eng:push_scene(name)
    if #self._scene_stack >= self._max_stack then
      error("STACK_OVERFLOW: scene stack exceeded " .. self._max_stack)
    end
    self._scene_stack[#self._scene_stack + 1] = name
  end

  --- Pop the top scene from the stack and return its name.
  ---@return string?
  function eng:pop_scene()
    local top = self._scene_stack[#self._scene_stack]
    self._scene_stack[#self._scene_stack] = nil
    return top
  end

  --- Replace the top-of-stack with a new scene name (goto).
  ---@param name string
  function eng:goto_scene(name)
    if #self._scene_stack == 0 then
      self._scene_stack[1] = name
    else
      self._scene_stack[#self._scene_stack] = name
    end
  end

  --- Push caller; transition to new scene (enter).
  ---@param name string
  function eng:enter_scene(name)
    self:push_scene(name)
  end

  --- Pop stack; return to previous scene (exit).
  function eng:exit_scene()
    self:pop_scene()
  end

  -- ── Evaluation context factory ───────────────────────────────

  --- Build an eval context for the current game state.
  ---@param fn_name string  name to record in log entries
  ---@return table
  function eng:make_ctx(fn_name)
    return eval.new_ctx(self._state, self._fns, fn_name)
  end

  -- ── Narration rendering ──────────────────────────────────────

  --- Render a narration text list to a plain string.
  ---@param text table   mixed string/inline_expr list
  ---@param ctx  table   eval context
  ---@return string
  function eng:render_text(text, ctx)
    return eval.render_text(text, ctx)
  end

  --- Render a scene body and return {narration, choices}.
  --- narration — list of visible text strings
  --- choices   — list of {index, label_str} tables (visible choices only)
  ---@param scene_name string
  ---@return table, table  narration list, choices list
  function eng:render_scene(scene_name)
    local scene = self._scenes[scene_name]
    if not scene then
      return { "Unknown scene: " .. tostring(scene_name) }, {}, nil
    end

    local ctx       = self:make_ctx("scene:" .. scene_name)
    local narration = {}
    local choices   = {}
    local choice_idx = 0
    local nav_signal = nil

    for _, item in ipairs(scene.body or {}) do
      if not item then
        -- skip nil items

      elseif item.kind == "narration_line" then
        narration[#narration + 1] = self:render_text(item.text, ctx)

      elseif item.kind == "cond_narration" then
        local cond = eval.eval_expr(item.condition, ctx)
        if cond then
          narration[#narration + 1] = self:render_text(item.text, ctx)
        end

      elseif item.kind == "choice" then
        choice_idx = choice_idx + 1
        local visible = true
        if item.guard then
          visible = eval.eval_expr(item.guard, ctx)
        end
        if visible then
          local label_str = self:render_text(item.label, ctx)
          choices[#choices + 1] = { index = choice_idx, label = label_str }
        end

      elseif item.kind == "scene_goto" then
        -- Unconditional redirect in scene body — evaluate and record
        eval.eval_stmt(item, ctx)
        if ctx.signal then nav_signal = ctx.signal; break end

      elseif item.kind == "scene_enter" then
        eval.eval_stmt(item, ctx)
        if ctx.signal then nav_signal = ctx.signal; break end

      elseif item.kind == "if_expr" then
        -- if/else block at scene level (narration-only, no choice)
        local cond = eval.eval_expr(item.condition, ctx)
        local body = cond and item.then_body or item.else_body
        if body then
          for _, sub in ipairs(body) do
            if sub and sub.kind == "narration_line" then
              narration[#narration + 1] = self:render_text(sub.text, ctx)
            elseif sub and sub.kind == "cond_narration" then
              local c2 = eval.eval_expr(sub.condition, ctx)
              if c2 then narration[#narration + 1] = self:render_text(sub.text, ctx) end
            end
          end
        end
      end
    end

    return narration, choices, nav_signal
  end

  -- ── Choice execution ─────────────────────────────────────────

  --- Execute the body of the choice at the given visible-list index.
  --- Returns the scene signal (goto/enter/exit) if any.
  ---@param scene_name  string
  ---@param choice_idx  integer  1-based index into the VISIBLE choice list
  ---@return table?  signal {type, target} or nil
  function eng:do_choice(scene_name, choice_idx)
    local scene = self._scenes[scene_name]
    if not scene then return nil end

    local ctx     = self:make_ctx("scene:" .. scene_name)
    local visible = 0

    for _, item in ipairs(scene.body or {}) do
      if item and item.kind == "choice" then
        local show = true
        if item.guard then
          show = eval.eval_expr(item.guard, ctx)
        end
        if show then
          visible = visible + 1
          if visible == choice_idx then
            -- Execute choice body
            local sub = eval.new_ctx(self._state, self._fns, "choice")
            eval.eval_stmts(item.body, sub)
            return sub.signal
          end
        end
      end
    end

    return nil
  end

  -- ── State initialisation ─────────────────────────────────────

  --- Initialise the engine: load defaults, go to entry scene.
  function eng:init()
    self._state:init_defaults()
    local entry = self._game.schema
      and self._game.schema.engine_config
      and self._game.schema.engine_config["entry-scene"]
    if entry then
      self._scene_stack = { entry }
    end
  end

  -- ── Turn loop ────────────────────────────────────────────────

  --- Output a line to the configured output stream.
  ---@param s string
  function eng:out(s)
    self._io_out:write(s .. "\n")
  end

  --- Read a line from the configured input stream.
  ---@return string?
  function eng:inp()
    return self._io_in:read("*l")
  end

  --- Run one turn: display scene, get player input, execute choice.
  --- Returns false if the game should exit.
  ---@return boolean  true to continue, false to exit
  function eng:step()
    local scene_name = self:current_scene()
    if not scene_name then
      self:out("[No current scene — exiting]")
      return false
    end

    -- Render scene
    local narration, choices, nav_signal = self:render_scene(scene_name)
    self:out("")
    for _, line in ipairs(narration) do
      if line ~= "" then self:out(line) end
    end
    self:out("")

    -- Follow unconditional scene navigation (e.g. computed -> in scene body)
    if nav_signal then
      if nav_signal.type == "goto" then
        self:goto_scene(nav_signal.target)
      elseif nav_signal.type == "enter" then
        self:enter_scene(nav_signal.target)
      elseif nav_signal.type == "exit" then
        self:exit_scene()
      end
      return true
    end

    if #choices == 0 then
      self:out("[No choices available — exiting]")
      return false
    end

    for i, c in ipairs(choices) do
      self:out(i .. ". " .. c.label)
    end
    self:out("")
    self:out("Choice (1-" .. #choices .. ", q to quit): ")

    -- Get player input
    local line = self:inp()
    if not line then return false end
    line = line:match("^%s*(.-)%s*$")  -- trim
    if line == "q" or line == "quit" or line == "exit" then
      return false
    end

    local idx = tonumber(line)
    if not idx or idx < 1 or idx > #choices then
      self:out("Invalid choice.")
      return true
    end

    -- Execute choice
    local signal = self:do_choice(scene_name, idx)
    if signal then
      if signal.type == "goto" then
        self:goto_scene(signal.target)
      elseif signal.type == "enter" then
        self:enter_scene(signal.target)
      elseif signal.type == "exit" then
        self:exit_scene()
      end
    end

    return true
  end

  return eng
end

-- ============================================================
-- Top-level run entry point
-- ============================================================

--- Run a compiled game interactively (simple text REPL).
---@param game_table table  Compiled game table from codegen
---@param opts       table? Options: seed, max_stack, io_out, io_in
---@return integer          Exit code
function M.run(game_table, opts)
  opts = opts or {}
  if opts.seed then math.randomseed(opts.seed) end

  local eng = M.new(game_table, opts)
  eng:init()

  while eng:step() do
    -- loop
  end

  return 0
end

return M

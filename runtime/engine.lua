-- runtime/engine.lua
-- Turn lifecycle, scene stack, time model, and top-level run loop.
--
-- Turn lifecycle (six steps):
--   1. Player action (optional — skipped for autonomous turns)
--   2. Message delivery (pending → actor inboxes)
--   3. Actor behaviors dispatched in priority order
--   4. Deferred mutations applied in priority order
--   5. Scheduled events fired
--   6. Inbox clearing
-- Note: time-inc! tick is NOT auto-advanced; game code must call it explicitly.

local state_mod    = require("runtime.state")
local log_mod      = require("runtime.log")
local eval         = require("runtime.eval")
local actors_mod   = require("runtime.actors")
local sched_mod    = require("runtime.scheduler")
local tilegrid_mod = require("runtime.tilegrid")
local random_mod   = require("runtime.random")

-- ============================================================
-- Save / load helpers
-- ============================================================

--- Save format: a Lua table literal containing scene_stack + log entries.
local SAVE_VERSION = 1

local function write_save(path, scene_stack, log, state_store)
  local f, err = io.open(path, "w")
  if not f then
    io.stderr:write("storybase: cannot write save file: " .. tostring(err) .. "\n")
    return false
  end
  -- Header
  f:write("-- StoryBase save file (v" .. SAVE_VERSION .. ")\n")
  f:write("local save = {}\n")
  f:write("save.version = " .. SAVE_VERSION .. "\n")
  -- Scene stack
  f:write("save.scene_stack = {")
  local parts = {}
  for _, s in ipairs(scene_stack) do
    parts[#parts + 1] = string.format("%q", s)
  end
  f:write(table.concat(parts, ", ") .. "}\n")
  -- Log entries (table expression, no "return")
  f:write("save.entries =\n")
  f:write(log_mod.serialise_entries(log:entries()))
  f:write("\n")
  f:write("return save\n")
  f:close()

  -- Write snapshot alongside save file for faster future loads
  if state_store then
    local snap_path = path .. ".snap"
    local sf, serr = io.open(snap_path, "w")
    if sf then
      sf:write("-- StoryBase snapshot (v" .. SAVE_VERSION .. ")\n")
      sf:write(log_mod.serialise_snapshot(
        log:seq(), state_store._cache, state_store._time))
      sf:close()
    else
      io.stderr:write("storybase: cannot write snapshot: " .. tostring(serr) .. "\n")
    end
  end

  return true
end

local function read_save(path)
  local f, err = io.open(path, "r")
  if not f then
    io.stderr:write("storybase: cannot read save file: " .. tostring(err) .. "\n")
    return nil
  end
  local src = f:read("*a")
  f:close()
  local fn, perr = load(src)
  if not fn then
    io.stderr:write("storybase: save file parse error: " .. tostring(perr) .. "\n")
    return nil
  end
  local ok, data = pcall(fn)
  if not ok then
    io.stderr:write("storybase: save file exec error: " .. tostring(data) .. "\n")
    return nil
  end
  return data
end

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

  local log    = log_mod.new()
  local store  = state_mod.new(game_table.schema, log)
  store._production = game_table.production or false
  store._print_sink = game_table._print_sink
  -- Register actor inbox paths so SF-3 doesn't warn on engine-internal writes.
  -- deliver_messages writes to inbox_path for any actor with pending messages,
  -- regardless of whether inbox_type is declared.
  for _, actor_def in pairs(game_table.actors or {}) do
    local inbox_path = (actor_def.state_path or actor_def.name) .. "/inbox"
    store._type_index[inbox_path] = true
  end
  local rng    = random_mod.new(opts.seed, log)
  local actors = actors_mod.new(store, log)
  local sched  = sched_mod.new(store, log)

  local eng = {
    _game             = game_table,
    _opts             = opts,
    _scene_stack      = {},
    _max_stack        = max_stack,
    _log              = log,
    _state            = store,
    _rng              = rng,
    _fns              = game_table.fns    or {},
    _scenes           = game_table.scenes or {},
    _actors           = actors,
    _scheduler        = sched,
    _io_out           = opts.io_out or io.stdout,
    _io_in            = opts.io_in  or io.stdin,
    _driver           = opts.driver,  -- optional UI driver ({render,prompt,notify})
    _grids            = {},  -- name → {cells, width, height, cell_type, default_val}
    _pending_narration = {},  -- dialogue objects emitted by say in fn bodies
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
      local stack_str = table.concat(self._scene_stack, " => ")
      error("STACK_OVERFLOW: scene stack exceeded " .. self._max_stack ..
            " — check for a missing '<-' exit\n  stack: " .. stack_str ..
            " => " .. tostring(name))
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
    if not self._game.production and not self._scenes[name] then
      local sink = self._game._print_sink
      local msg = "[WARN] goto undefined scene: '" .. tostring(name) .. "'\n"
      if sink then sink(msg) else io.stderr:write(msg) end
    end
    local from = self._scene_stack[#self._scene_stack]
    if #self._scene_stack == 0 then
      self._scene_stack[1] = name
    else
      self._scene_stack[#self._scene_stack] = name
    end
    if self._debug then
      local tick = self._state and self._state._time and self._state._time.tick or 0
      self._debug:emit("scene-change", { from = from, to = name,
                                         stack = self._scene_stack, tick = tick })
      self._debug:check_watches()
    end
  end

  --- Push caller; transition to new scene (enter).
  ---@param name string
  function eng:enter_scene(name)
    if not self._game.production and not self._scenes[name] then
      local sink = self._game._print_sink
      local msg = "[WARN] enter undefined scene: '" .. tostring(name) .. "'\n"
      if sink then sink(msg) else io.stderr:write(msg) end
    end
    self:push_scene(name)
    if self._debug then
      local tick = self._state and self._state._time and self._state._time.tick or 0
      self._debug:emit("scene-change", { to = name, stack = self._scene_stack, tick = tick })
      self._debug:check_watches()
    end
  end

  --- Pop stack; return to previous scene (exit).
  function eng:exit_scene()
    local from = self._scene_stack[#self._scene_stack]
    self:pop_scene()
    if self._debug then
      local tick = self._state and self._state._time and self._state._time.tick or 0
      self._debug:emit("scene-change", { from = from, to = self:current_scene(),
                                         stack = self._scene_stack, tick = tick })
      self._debug:check_watches()
    end
  end

  -- ── Evaluation context factory ───────────────────────────────

  --- Build an eval context for the current game state.
  --- Includes actor registry so send! can enqueue messages.
  ---@param fn_name string  name to record in log entries
  ---@return table
  function eng:make_ctx(fn_name)
    local ctx          = eval.new_ctx(self._state, self._fns, fn_name, self._game)
    ctx.actors         = self._actors
    ctx.scheduler      = self._scheduler
    ctx.rng            = self._rng     -- seeded, logged RNG (never use math.random directly)
    ctx.debug          = self._debug   -- may be nil (no debug server attached)
    ctx.grids          = self._grids   -- tile grid data (may be empty table)
    ctx.engine_ref     = self          -- for engine/ pseudo-path reads
    ctx._in_bfs        = self._in_bfs  -- propagate BFS-mode guard (prevents recursive BFS)
    ctx.scene_stack    = self._scene_stack  -- BFS builtins need the live scene stack
    ctx.narration_buf  = self._pending_narration  -- say output buffer (fn bodies)
    return ctx
  end

  -- ── Narration rendering ──────────────────────────────────────

  --- Render a narration text list to a plain string.
  ---@param text table   mixed string/inline_expr list
  ---@param ctx  table   eval context
  ---@return string
  function eng:render_text(text, ctx)
    return eval.render_text(text, ctx)
  end

  --- Recursively render a list of narration body items into the narration table.
  --- Handles narration_line, cond_narration, when_stmt, and if_expr.
  ---@param narration table  accumulator list
  ---@param items     table  list of AST nodes
  ---@param ctx       table  eval context
  function eng:_render_narration_items(narration, items, ctx)
    for _, sub in ipairs(items or {}) do
      if not sub then
      elseif sub.kind == "narration_line" then
        narration[#narration + 1] = { kind = "narration", text = self:render_text(sub.text, ctx) }
      elseif sub.kind == "cond_narration" then
        if eval.eval_expr(sub.condition, ctx) then
          narration[#narration + 1] = { kind = "narration", text = self:render_text(sub.text, ctx) }
        end
      elseif sub.kind == "when_stmt" then
        if eval.eval_expr(sub.condition, ctx) then
          self:_render_narration_items(narration, sub.body, ctx)
        end
      elseif sub.kind == "if_expr" then
        local body = eval.eval_expr(sub.condition, ctx) and sub.then_body or sub.else_body
        self:_render_narration_items(narration, body, ctx)
      elseif sub.kind == "say_stmt" then
        local old_buf = ctx.narration_buf
        ctx.narration_buf = narration  -- emit directly into narration
        eval.eval_stmt(sub, ctx)
        ctx.narration_buf = old_buf
      elseif sub.kind == "scene_goto" or sub.kind == "scene_enter" then
        eval.eval_stmt(sub, ctx)  -- sets ctx.signal
      elseif sub.kind == "for_stmt" then
        local list = eval.eval_for_iter(sub.iter, ctx)
        local iterated = false
        if type(list) == "table" then
          for _, val in ipairs(list) do
            iterated = true
            local sub_ctx = eval.child_ctx_vars(ctx, {[sub.var] = val})
            sub_ctx.narration_buf = narration
            self:_render_narration_items(narration, sub.body, sub_ctx)
            if sub_ctx.signal then ctx.signal = sub_ctx.signal; break end
          end
        end
        if not iterated and sub.else_body then
          self:_render_narration_items(narration, sub.else_body, ctx)
        end
      end
      if ctx.signal then return end  -- stop on navigation signal
    end
  end

  -- ── Scene choice traversal (J-I2) ────────────────────────────
  --
  -- Walk scene-body items left-to-right depth-first, calling `visit(choice, ctx)`
  -- for each `*` choice in source order. Descends into for_stmt / when_stmt /
  -- if_expr bodies so choices nested inside those blocks are visible. Both
  -- `render_scene` (to populate the visible choice list) and `do_choice` (to
  -- locate the player-selected choice) use this, guaranteeing the visible
  -- index → (choice node, iteration bindings) mapping is identical across
  -- render and execute.
  --
  -- Non-choice items (narration, say, goto) are ignored here; they are
  -- handled by `_render_narration_items`. If `visit` sets `ctx.signal` (e.g.
  -- by returning early through a navigation signal), the walk stops.
  ---@param items table   list of scene-body AST nodes
  ---@param ctx   table   eval context (carries any for-loop var bindings)
  ---@param visit function (choice_node, ctx) → optional truthy to stop walk
  ---@return boolean stopped — true if walk aborted early
  function eng:_walk_scene_choices(items, ctx, visit)
    if not items then return false end
    for _, item in ipairs(items) do
      if not item then  -- skip nil entries
      elseif item.kind == "choice" then
        if visit(item, ctx) then return true end

      elseif item.kind == "when_stmt" then
        if eval.eval_expr(item.condition, ctx) then
          if self:_walk_scene_choices(item.body, ctx, visit) then return true end
        end

      elseif item.kind == "if_expr" then
        local body = eval.eval_expr(item.condition, ctx) and item.then_body or item.else_body
        if body and self:_walk_scene_choices(body, ctx, visit) then return true end

      elseif item.kind == "for_stmt" then
        local list = eval.eval_for_iter(item.iter, ctx)
        local iterated = false
        if type(list) == "table" then
          for _, val in ipairs(list) do
            iterated = true
            local sub_ctx = eval.child_ctx_vars(ctx, {[item.var] = val})
            if self:_walk_scene_choices(item.body, sub_ctx, visit) then return true end
          end
        end
        if not iterated and item.else_body then
          if self:_walk_scene_choices(item.else_body, ctx, visit) then return true end
        end
      end
    end
    return false
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

    -- Prepend any dialogue objects accumulated during the previous fn-body execution
    local narration = {}
    for _, obj in ipairs(self._pending_narration) do
      narration[#narration + 1] = obj
    end
    self._pending_narration = {}

    local ctx       = self:make_ctx("scene:" .. scene_name)
    ctx.narration_buf = narration  -- say in scene body emits directly here
    local choices   = {}
    local choice_idx = 0
    local nav_signal = nil

    -- Pass 1: narration + navigation. Choice items are deferred to pass 2 so
    -- that nested choices inside for/when/if blocks (J-I2) participate in the
    -- visible-index ordering on equal footing with top-level choices.
    for _, item in ipairs(scene.body or {}) do
      if not item then
        -- skip nil items

      elseif item.kind == "narration_line" then
        narration[#narration + 1] = { kind = "narration", text = self:render_text(item.text, ctx) }

      elseif item.kind == "cond_narration" then
        local cond = eval.eval_expr(item.condition, ctx)
        if cond then
          narration[#narration + 1] = { kind = "narration", text = self:render_text(item.text, ctx) }
        end

      elseif item.kind == "say_stmt" then
        eval.eval_stmt(item, ctx)  -- emits into ctx.narration_buf = narration

      elseif item.kind == "choice" then
        -- Choices handled in pass 2 (below).

      elseif item.kind == "scene_goto" then
        -- Unconditional redirect in scene body — evaluate and record
        eval.eval_stmt(item, ctx)
        if ctx.signal then nav_signal = ctx.signal; break end

      elseif item.kind == "scene_enter" then
        eval.eval_stmt(item, ctx)
        if ctx.signal then nav_signal = ctx.signal; break end

      elseif item.kind == "when_stmt" then
        -- Conditional narration block: render body if condition is true.
        -- Choices inside this body are still emitted in pass 2.
        local cond = eval.eval_expr(item.condition, ctx)
        if cond then
          self:_render_narration_items(narration, item.body, ctx)
          if ctx.signal then nav_signal = ctx.signal; break end
        end

      elseif item.kind == "if_expr" then
        -- if/else block at scene level — narration handled here, choices in pass 2.
        local cond = eval.eval_expr(item.condition, ctx)
        local body = cond and item.then_body or item.else_body
        if body then
          self:_render_narration_items(narration, body, ctx)
        end

      elseif item.kind == "for_stmt" then
        -- for loop at scene level — iterate and render narration for each element.
        -- Choices inside the body are still emitted in pass 2.
        local list = eval.eval_for_iter(item.iter, ctx)
        local iterated = false
        if type(list) == "table" then
          for _, val in ipairs(list) do
            iterated = true
            local sub = eval.child_ctx_vars(ctx, {[item.var] = val})
            sub.narration_buf = narration
            self:_render_narration_items(narration, item.body, sub)
            if sub.signal then nav_signal = sub.signal; break end
          end
        end
        if not iterated and item.else_body then
          self:_render_narration_items(narration, item.else_body, ctx)
        end
        if nav_signal then break end
      end
    end

    -- Pass 2: enumerate visible choices in source order, descending into
    -- for/when/if blocks via the shared walker.
    if not nav_signal then
      self:_walk_scene_choices(scene.body or {}, ctx, function(choice, sub_ctx)
        local visible = true
        if choice.guard then
          visible = eval.eval_expr(choice.guard, sub_ctx)
        end
        if visible then
          choice_idx = choice_idx + 1
          local label_str = self:render_text(choice.label, sub_ctx)
          choices[#choices + 1] = { index = choice_idx, label = label_str }
        end
        return false  -- never abort during render
      end)
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

    -- Record a "choice" log entry so diff-replay (H2) can re-run the player's
    -- inputs against modified fn bodies. Skipped under BFS/verify because those
    -- engines exhaustively probe choices; their throwaway logs do not need
    -- player-input markers and the extra seqs would inflate replay cost.
    if not self._in_bfs and self._log then
      local tick = self._state and self._state._time and self._state._time.tick or 0
      local time_snap = nil
      if self._state and self._state._time then
        time_snap = {}
        for k, v in pairs(self._state._time) do time_snap[k] = v end
      end
      self._log:append({
        kind  = "choice",
        scene = scene_name,
        idx   = choice_idx,
        tick  = tick,
        time  = time_snap,
      })
    end

    local ctx     = self:make_ctx("scene:" .. scene_name)
    local visible = 0
    local result_signal = nil

    self:_walk_scene_choices(scene.body or {}, ctx, function(choice, sub_ctx)
      local show = true
      if choice.guard then
        show = eval.eval_expr(choice.guard, sub_ctx)
      end
      if not show then return false end
      visible = visible + 1
      if visible ~= choice_idx then return false end
      -- Found the player's selection.  Execute its body with a fresh ctx
      -- (so say! buffers into self._pending_narration for the next scene)
      -- but inherit any for-loop iteration variables from sub_ctx so
      -- interpolated paths inside the body resolve correctly.
      local exec = self:make_ctx("choice")
      if sub_ctx.vars then
        for k, v in pairs(sub_ctx.vars) do exec.vars[k] = v end
      end
      eval.eval_stmts(choice.body, exec)
      result_signal = exec.signal
      return true  -- abort walk
    end)

    return result_signal
  end

  -- ── State initialisation ─────────────────────────────────────

  --- Register actors and schedules without touching state (used by BFS).
  function eng:register_actors_schedules()
    for _, actor_def in pairs(self._game.actors or {}) do
      self._actors:register(actor_def)
    end
    for _, sched_def in pairs(self._game.schedules or {}) do
      self._scheduler:register(sched_def.name, sched_def.trigger, sched_def.body)
    end
  end

  --- Initialise the engine: load defaults, register actors/schedules, go to entry scene.
  function eng:init()
    self._state:init_defaults()
    self:register_actors_schedules()
    self:init_grids()
    -- Wire engine-level context into scheduler so schedule bodies can call
    -- cancel-schedule!, engine/emit, send!, random-int, etc.
    self._scheduler._game   = self._game
    self._scheduler._actors = self._actors
    self._scheduler._rng    = self._rng
    -- Build name-indexed type map for O(1) random-enum lookups
    local schema = self._game.schema
    if schema and schema.types and not schema._type_index then
      local idx = {}
      for _, t in ipairs(schema.types) do
        if t.name then idx[t.name] = t end
      end
      schema._type_index = idx
    end

    -- §F1: run generate blocks AFTER defaults+grids but BEFORE entry-scene
    -- assignment, so seed-state reads see initialised values and any
    -- spawn!/relate!/set! mutations land in the log for replay.
    self:run_generates()

    local entry = self._game.schema
      and self._game.schema.engine_config
      and self._game.schema.engine_config["entry-scene"]
    if entry then
      self._scene_stack = { entry }
    end
  end

  --- Run every declared generate block once (§F1).
  --- Each generate's seed_path (if present) is read and used to re-seed the RNG
  --- before the body executes. All state mutations pass through the transaction
  --- log so the produced world replays deterministically from a saved log
  --- without re-running the generate block.
  function eng:run_generates()
    local gens = self._game.generates or {}
    if #gens == 0 then return end
    for _, gen in ipairs(gens) do
      if gen.seed_path then
        local path_key = (function(node)
          if node.kind == "path_expr" then
            return table.concat(node.segments or {}, "/")
          end
          return nil
        end)(gen.seed_path)
        if path_key then
          local seed_val = self._state:get(path_key)
          if type(seed_val) == "number" then
            self._rng:seed(math.floor(seed_val))
          end
        end
      end
      local ctx = self:make_ctx("generate:" .. (gen.name or "?"))
      eval.eval_stmts(gen.body or {}, ctx)
    end
  end

  --- Evaluate every declared ending's when-condition against the current state
  --- (§F2). Returns the first ending whose condition is true (in declaration
  --- order), or nil. Used by the step loop to decide when to render the
  --- ending body and terminate.
  ---@return table?  the ending descriptor {name, when_expr, body, doc} or nil
  function eng:check_ending()
    local endings = self._game.endings or {}
    if #endings == 0 then return nil end
    local ctx = self:make_ctx("ending-check")
    for _, e in ipairs(endings) do
      if e.when_expr then
        local ok, v = pcall(eval.eval_expr, e.when_expr, ctx)
        if ok and v then return e end
      end
    end
    return nil
  end

  --- Render the body of a triggered ending into a narration list, returning the
  --- list. Reuses the same scene-mode narration machinery so narration_line,
  --- cond_narration, say_stmt, when_stmt, and if_expr all work as expected.
  function eng:_render_ending(ending)
    local ctx = self:make_ctx("ending:" .. (ending.name or "?"))
    local narration = {}
    ctx.narration_buf = narration
    self:_render_narration_items(narration, ending.body or {}, ctx)
    return narration
  end

  --- Initialise all declared tile grids with their default cell values.
  --- Called automatically by eng:init().
  function eng:init_grids()
    local gdefs = self._game.grids or {}
    for name, gdef in pairs(gdefs) do
      local w   = gdef.width  or 0
      local h   = gdef.height or 0
      local def = gdef.default_val
      if w > 0 and h > 0 then
        self._grids[name] = {
          cells       = tilegrid_mod.new(w, h, def),
          width       = w,
          height      = h,
          cell_type   = gdef.cell_type,
          default_val = def,
        }
      end
    end
  end

  --- Apply any grid cell overrides stored in the state cache (written by grid-set!)
  --- back into the cells arrays.  Call after loading/replaying saved state so that
  --- tilegrid algorithms (visible-from?, path-to) see the correct cell values.
  function eng:apply_grid_cache()
    for k, v in pairs(self._state._cache) do
      local name, sx, sy = k:match("^__grid/([^/]+)/(-?%d+),(-?%d+)$")
      if name and self._grids[name] then
        local g = self._grids[name]
        tilegrid_mod.set(g.cells, g.width, g.height, tonumber(sx), tonumber(sy), v)
      end
    end
  end

  --- Attach a debug server to the engine, wiring mutation and scene hooks.
  ---@param srv table  debug server instance (from runtime.debug)
  function eng:set_debug_server(srv)
    self._debug = srv
    -- Wire mutation events through state store
    self._state._mutation_hook = function(path, old, new_val, fn_name)
      local seq  = self._log:seq()
      local tick = self._state._time and self._state._time.tick or 0
      srv:emit("mutation", { path = path, old = old, new = new_val,
                              fn = fn_name, tick = tick, seq = seq })
    end
    -- Wire clamp events through state store
    self._state._clamp_hook = function(path, attempted, clamped, fn_name)
      local seq  = self._log:seq()
      local tick = self._state._time and self._state._time.tick or 0
      srv:emit("clamp-event", { path = path, attempted = attempted,
                                 clamped = clamped, fn = fn_name, tick = tick, seq = seq })
    end
    -- Wire spawn/despawn events through state store
    self._state._spawn_hook = function(family, key, init, fn_name)
      local seq  = self._log:seq()
      local tick = self._state._time and self._state._time.tick or 0
      srv:emit("spawn-event", { family = family, key = key, init = init,
                                 fn = fn_name, tick = tick, seq = seq })
    end
    self._state._despawn_hook = function(family, key, fn_name)
      local seq  = self._log:seq()
      local tick = self._state._time and self._state._time.tick or 0
      srv:emit("despawn-event", { family = family, key = key,
                                   fn = fn_name, tick = tick, seq = seq })
    end
    -- Wire schedule-fired events through the scheduler
    self._scheduler._debug_server = srv
    -- Register watch/watch-when declarations from the compiled game table
    for _, w in ipairs(self._game and self._game.watches or {}) do
      if w.kind == "watch" and w.path then
        local segs = w.path.segments or {}
        local path_str = table.concat(segs, "/")
        if path_str ~= "" then
          srv:register_watch(path_str, w.label)
        end
      elseif w.kind == "watch_when" and w.condition then
        srv:register_watch_when(w.condition, w.label)
      end
    end
  end

  --- Run post-action phases (steps 2–6 of the turn lifecycle).
  --- Called after every player action (including autonomous turns).
  ---   2. Deliver pending messages into actor inboxes
  ---   3. Run actor behavior functions (writes captured, not applied yet)
  ---   4. Apply deferred mutations in priority order
  ---   5. Tick the scheduler (fire due schedules)
  ---   6. Clear actor inboxes
  function eng:post_action()
    self._actors:deliver_messages()
    self._actors:run_behaviors(self._fns)
    self._actors:apply_deferred()
    self._scheduler:tick(self._fns)
    self._actors:clear_inboxes()
  end

  --- Run one autonomous turn (steps 2–6 only; no player input).
  --- Used for NPC-driven turns, schedule-only advances, etc.
  function eng:autonomous_turn()
    self:post_action()
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

  --- Render narration items to the built-in output stream (plain-text fallback).
  ---@param narration table  list of {kind,text,...} items
  function eng:_render_plain(narration)
    self:out("")
    for _, item in ipairs(narration) do
      if item.kind == "say" then
        local label = item.display or item.speaker or "?"
        self:out(label .. ": " .. tostring(item.text or ""))
      elseif item.text and item.text ~= "" then
        self:out(item.text)
      end
    end
    self:out("")
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

    if self._driver then
      self._driver:render({ narration = narration, choices = choices })
    else
      self:_render_plain(narration)
    end

    -- §F2: an ending whose condition is already true at the start of the turn
    -- terminates the game before prompting for a choice. Useful when init or a
    -- generate block lands the player straight into an end state.
    do
      local triggered = self:check_ending()
      if triggered then
        local enarr = self:_render_ending(triggered)
        if self._driver then
          self._driver:render({ narration = enarr, choices = {} })
        else
          self:_render_plain(enarr)
        end
        self._ended_at = triggered.name
        return false
      end
    end

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
      if not self._driver then
        self:out("[No choices available — exiting]")
      end
      return false
    end

    -- Get player choice via driver or built-in stdin prompt
    local idx
    if self._driver then
      idx = self._driver:prompt(choices)
      if not idx then return false end
    else
      for i, c in ipairs(choices) do
        self:out(i .. ". " .. c.label)
      end
      self:out("")
      self:out("Choice (1-" .. #choices .. ", q to quit): ")
      local line = self:inp()
      if not line then return false end
      line = line:match("^%s*(.-)%s*$")  -- trim
      if line == "q" or line == "quit" or line == "exit" then
        return false
      end
      idx = tonumber(line)
      if not idx or idx < 1 or idx > #choices then
        self:out("Invalid choice.")
        return true
      end
    end

    -- Execute choice
    local signal = self:do_choice(scene_name, idx)

    -- Post-action phases: message delivery, actor behaviors, scheduler
    self:post_action()
    -- Poll debug server for incoming commands (non-blocking)
    if self._debug and self._debug.poll then
      pcall(function() self._debug:poll() end)
    end

    -- NPC speed: run N extra autonomous turns per player action
    local cfg = self._game.schema and self._game.schema.engine_config
    local npc_speed = tonumber(cfg and cfg["npc-speed"]) or 0
    for _ = 1, npc_speed do
      self:post_action()
    end

    if signal then
      if signal.type == "goto" then
        self:goto_scene(signal.target)
      elseif signal.type == "enter" then
        self:enter_scene(signal.target)
      elseif signal.type == "exit" then
        self:exit_scene()
      end
    end

    -- §F2: post-action ending check. If a choice or autonomous turn moved
    -- state into an ending condition, render the ending body and exit the
    -- loop. Pre-prompt check above handles the init-time case.
    do
      local triggered = self:check_ending()
      if triggered then
        local enarr = self:_render_ending(triggered)
        if self._driver then
          self._driver:render({ narration = enarr, choices = {} })
        else
          self:_render_plain(enarr)
        end
        self._ended_at = triggered.name
        return false
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
---@param opts       table? Options: seed, max_stack, io_out, io_in, save_path, load_path
---@return integer          Exit code
function M.run(game_table, opts)
  opts = opts or {}
  local eng = M.new(game_table, opts)

  -- Start debug server when --debug or --serve flag was given (debug_port is set)
  if opts.debug_port then
    local ok_d, debug_mod = pcall(require, "runtime.debug")
    if ok_d then
      local bind_addr = opts.bind or "127.0.0.1"
      local srv = debug_mod.new(eng, { port = opts.debug_port, mode = "tcp", bind = bind_addr })
      eng:set_debug_server(srv)
      srv:start()
      io.stderr:write(string.format("[debug] listening on %s:%d\n", bind_addr, opts.debug_port))
      -- Start HTTP UI server when requested
      if opts.http_port then
        srv:start_http(opts.http_port)
        io.stderr:write(string.format("[debug ui] http://%s:%d\n", bind_addr, opts.http_port))
      end
      -- Mark serve mode so do-choice commands are accepted
      if opts.serve then
        srv._serve_mode = true
      end
    else
      io.stderr:write("warning: could not load debug module: "
                      .. tostring(debug_mod) .. "\n")
    end
  end

  if opts.load_path then
    -- Load mode: restore defaults then replay saved log
    local save_data = read_save(opts.load_path)
    if not save_data then return 1 end
    eng._state:init_defaults()
    -- Try snapshot-accelerated load first
    local snap_path = opts.load_path .. ".snap"
    local sf = io.open(snap_path, "r")
    if sf then
      local snap_src = sf:read("*a")
      sf:close()
      local ok, snap = pcall(log_mod.deserialise_snapshot, snap_src)
      if ok and snap then
        state_mod.replay_from_snapshot(eng._state, snap, save_data.entries or {})
      else
        state_mod.replay(eng._state, save_data.entries or {})
      end
    else
      state_mod.replay(eng._state, save_data.entries or {})
    end
    -- Register static schedules/actors before replaying log so thresholds can be updated
    eng:register_actors_schedules()
    -- Replay schedule events so dynamic schedules and threshold advances are restored
    eng._scheduler:replay_log(save_data.entries or {}, eng._game.fns)
    -- Initialise grids from defaults, then apply any saved grid-set! overrides.
    eng:init_grids()
    eng:apply_grid_cache()
    -- Restore scene stack
    if type(save_data.scene_stack) == "table" and #save_data.scene_stack > 0 then
      eng._scene_stack = save_data.scene_stack
    else
      eng:init()
    end
    io.stdout:write("[Loaded from " .. opts.load_path .. "]\n")
  else
    eng:init()
  end

  if opts.serve and eng._debug then
    -- Serve mode: game loop driven by HTTP do-choice commands (no stdin).
    -- poll_http() + poll() are called each iteration; socket.sleep avoids busy-wait.
    local ok_s, socket_mod = pcall(require, "socket")
    while true do
      pcall(function() eng._debug:poll_http() end)
      pcall(function() eng._debug:poll() end)
      if ok_s and socket_mod.sleep then socket_mod.sleep(0.01) end
    end
  else
    while eng:step() do
      -- standard stdin-driven game loop
    end
  end

  if opts.save_path then
    if write_save(opts.save_path, eng._scene_stack, eng._log, eng._state) then
      io.stdout:write("[Saved to " .. opts.save_path .. "]\n")
    end
  end

  -- Shut down debug server if one was started
  if eng._debug and eng._debug.stop then
    pcall(function() eng._debug:stop() end)
  end

  return 0
end

return M

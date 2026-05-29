-- ui/kernel.lua
--
-- Presentation kernel for StoryBase drivers. The kernel is the single
-- owner of the event-dispatch surface between the runtime and any UI
-- driver (plain, ansi, curses, browser-sse, library subscriber).
--
-- See `ui_idea.md` §3 (driver protocol) and §4 (presentation kernel)
-- for the design rationale. See `docs/explanation/ui_event_audit.md`
-- (§M0 deliverable) for the event surface inventory this module is
-- built against, the recommended ownership model, and the §4.1
-- migration sketch that drives the wiring choices here.
--
-- The kernel exposes three groups of methods:
--
--   ── Subscription (driver ← kernel) ──
--     k:on(event, fn)         -- subscribe; returns an unsubscribe handle
--     k:off(event, fn)        -- unsubscribe a specific handler
--     k:emit(event, payload)  -- fan out (used by runtime hook shims)
--
--   ── Queries (driver → kernel, read-only) ──
--     k:get_state(path)       -- last-seen value at a state path
--     k:get_state_all()       -- full path→value map for initial paint
--     k:get_scene()           -- {name, narration, choices, nav_signal}
--     k:get_schema()          -- compiled-game schema
--     k:get_tick()            -- {axis = value, ...}
--     k:get_bindings()        -- author-declared UI bindings (§5)
--
--   ── Commands (driver → kernel, may mutate) ──
--     k:do_choice(idx)        -- dispatch player choice; synthesises
--                                a `choice-made` event on success
--     k:autonomous_turn()     -- run actors + scheduler without input
--     k:call_fn(name, ...)    -- (deferred; needs ctx plumbing — see
--                                ui_idea.md §M7 for the input-widget
--                                use case that exercises this)
--
-- Wiring: a caller (typically `runtime/engine.lua:set_kernel`) installs
-- this kernel's `_install_hooks` shims into the state-store /
-- actor-registry / game-table hook slots. From that moment, every
-- mutation, clamp, spawn, despawn, custom emit, and actor-no-progress
-- signal flows through `k:emit` and reaches every subscriber.
--
-- Wildcard subscription: `k:on("*", fn)` receives every event as
-- `fn(event_name, payload)`. Useful for debug forwarders.
--
-- Error isolation: every listener is invoked under `pcall`. A faulty
-- subscriber cannot block other subscribers from seeing an event. The
-- error is logged to `io.stderr` and the dispatch loop continues.

local M = {}

--- Construct a new kernel.
---@param engine_obj table?  Optional engine; bind later via `k:attach(eng)`.
---@return table kernel
function M.new(engine_obj)
  local self = {
    _engine    = engine_obj,
    _listeners = {},       -- event_name → array of fns
    _cache     = {},       -- path → last-seen value (synced via mutation)
    _attached  = false,
  }

  -- ── Subscription registry ──────────────────────────────────

  --- Subscribe to a named event. Returns an unsubscribe function.
  --- Use the event name "*" to subscribe to every event; the handler
  --- is then invoked as `fn(event_name, payload)` instead of `fn(payload)`.
  ---@param event   string    event name, or "*" for wildcard
  ---@param fn      function  handler
  ---@return function unsubscribe  call to remove this subscription
  function self:on(event, fn)
    assert(type(event) == "string", "event name must be a string")
    assert(type(fn) == "function", "handler must be a function")
    local l = self._listeners[event]
    if not l then
      l = {}
      self._listeners[event] = l
    end
    l[#l + 1] = fn
    return function() self:off(event, fn) end
  end

  --- Unsubscribe a specific handler from an event. No-op if not subscribed.
  ---@param event string
  ---@param fn    function
  function self:off(event, fn)
    local l = self._listeners[event]
    if not l then return end
    for i = 1, #l do
      if l[i] == fn then
        table.remove(l, i)
        return
      end
    end
  end

  --- Fan-out: call every subscriber to `event` with `payload`. Wildcard
  --- subscribers (registered under "*") also fire, with the event name
  --- as the first argument. Each call is `pcall`-isolated so one bad
  --- listener cannot block others.
  ---@param event   string
  ---@param payload table?
  function self:emit(event, payload)
    -- State-cache invariant: mirror mutations into the cache before
    -- any listener observes the event. Drivers that read `get_state`
    -- inside a `mutation` handler see the new value.
    if event == "mutation" and type(payload) == "table" and payload.path ~= nil then
      self._cache[payload.path] = payload.new
    end

    local l = self._listeners[event]
    if l then
      -- Iterate over a snapshot in case a handler unsubscribes itself
      -- during dispatch (otherwise table.remove would shift indices).
      local snap = {}
      for i = 1, #l do snap[i] = l[i] end
      for i = 1, #snap do
        local ok, err = pcall(snap[i], payload)
        if not ok then
          io.stderr:write("[ui/kernel] listener for '" .. event ..
                          "' errored: " .. tostring(err) .. "\n")
        end
      end
    end

    local wl = self._listeners["*"]
    if wl then
      local snap = {}
      for i = 1, #wl do snap[i] = wl[i] end
      for i = 1, #snap do
        local ok, err = pcall(snap[i], event, payload)
        if not ok then
          io.stderr:write("[ui/kernel] wildcard listener errored on '"
                          .. event .. "': " .. tostring(err) .. "\n")
        end
      end
    end
  end

  -- ── Engine binding ─────────────────────────────────────────

  --- Bind this kernel to a runtime engine instance and install hook
  --- shims into every single-slot dispatch point (see audit §2.3).
  --- After this call, every state mutation / clamp / spawn / despawn /
  --- custom emit / actor-no-progress signal flows through the kernel.
  ---
  --- Idempotent: a second call is a no-op. Chains: if a slot already
  --- has a callback installed (e.g. by a prior `set_debug_server`),
  --- the prior callback is invoked from inside the kernel shim so
  --- legacy consumers keep receiving their events during transition.
  ---@param engine_obj table  engine instance (from `runtime/engine.lua`)
  function self:attach(engine_obj)
    if self._attached then return end
    self._engine = engine_obj or self._engine
    if not self._engine then return end
    self:_install_hooks()
    self:_seed_state_cache()
    self._attached = true
  end

  --- Install the kernel's fan-out shims into the engine's hook slots.
  --- Each shim chains to whatever callback was previously installed
  --- so legacy `set_debug_server` wiring continues to fire.
  function self:_install_hooks()
    local eng    = self._engine
    local kernel = self
    local state  = eng._state
    local game   = eng._game
    local log    = eng._log

    local function tick_now()
      if state and state._time and state._time.tick then
        return state._time.tick
      end
      return 0
    end
    local function seq_now() return log and log:seq() or 0 end

    -- state._mutation_hook
    do
      local prior = state._mutation_hook
      state._mutation_hook = function(path, old, new_val, fn_name)
        if prior then pcall(prior, path, old, new_val, fn_name) end
        kernel:emit("mutation", {
          path = path, old = old, new = new_val,
          fn = fn_name, tick = tick_now(), seq = seq_now(),
        })
      end
    end

    -- state._clamp_hook
    do
      local prior = state._clamp_hook
      state._clamp_hook = function(path, attempted, clamped, fn_name)
        if prior then pcall(prior, path, attempted, clamped, fn_name) end
        kernel:emit("clamp-event", {
          path = path, attempted = attempted, clamped = clamped,
          fn = fn_name, tick = tick_now(), seq = seq_now(),
        })
      end
    end

    -- state._spawn_hook
    do
      local prior = state._spawn_hook
      state._spawn_hook = function(family, key, init, fn_name)
        if prior then pcall(prior, family, key, init, fn_name) end
        kernel:emit("spawn-event", {
          family = family, key = key, init = init,
          fn = fn_name, tick = tick_now(), seq = seq_now(),
        })
      end
    end

    -- state._despawn_hook
    do
      local prior = state._despawn_hook
      state._despawn_hook = function(family, key, fn_name)
        if prior then pcall(prior, family, key, fn_name) end
        kernel:emit("despawn-event", {
          family = family, key = key,
          fn = fn_name, tick = tick_now(), seq = seq_now(),
        })
      end
    end

    -- game._emit_hook (engine/emit custom events)
    if game then
      local prior = game._emit_hook
      game._emit_hook = function(event_name, payload, t)
        if prior then pcall(prior, event_name, payload, t) end
        kernel:emit(event_name, {
          event = event_name, payload = payload, tick = t or tick_now(),
        })
      end
    end

    -- actors:on_no_progress (registry-level, multi-subscriber-safe)
    if eng._actors and eng._actors.on_no_progress then
      eng._actors:on_no_progress(function(actor)
        kernel:emit("actor-no-progress", { actor = actor, tick = tick_now() })
      end)
    end
  end

  --- Populate the state cache from the engine's current state, so
  --- queries answered before the first mutation still return correct
  --- values for the initial paint.
  function self:_seed_state_cache()
    local s = self._engine and self._engine._state
    if not s or not s._cache then return end
    for path, value in pairs(s._cache) do
      self._cache[path] = value
    end
  end

  -- ── Queries ────────────────────────────────────────────────

  --- Read the last-seen value at a state path. Reads the cache first;
  --- falls through to `state:get(path)` for paths the kernel has not
  --- yet observed (e.g. never mutated since attach).
  ---@param path string
  ---@return any
  function self:get_state(path)
    if self._cache[path] ~= nil then return self._cache[path] end
    local s = self._engine and self._engine._state
    if not s then return nil end
    -- Time axes are read-only pseudo-paths exposed by the engine.
    local axis = path:match("^time/(.+)$")
    if axis then
      local t = s:get_time()
      return t[axis]
    end
    return s:get(path)
  end

  --- Snapshot of every known state path → value. Used by drivers for
  --- the initial paint. Combines the engine's authoritative cache
  --- with any kernel-cached values (kernel cache wins on collision).
  ---@return table
  function self:get_state_all()
    local out = {}
    local s = self._engine and self._engine._state
    if s and s._cache then
      for path, value in pairs(s._cache) do out[path] = value end
    end
    for path, value in pairs(self._cache) do out[path] = value end
    return out
  end

  --- Render the current scene. Returns `nil` when the scene stack is
  --- empty (game has ended).
  ---@return table?  `{ name, narration, choices, nav_signal }`
  function self:get_scene()
    local eng = self._engine
    if not eng then return nil end
    local name = eng:current_scene()
    if not name then return nil end
    local narr, choices, nav = eng:render_scene(name)
    return {
      name       = name,
      narration  = narr,
      choices    = choices,
      nav_signal = nav,
    }
  end

  --- Return the compiled-game schema (types, states, scene list, etc.).
  ---@return table?
  function self:get_schema()
    local g = self._engine and self._engine._game
    return g and g.schema or nil
  end

  --- Return the current time-axis map (e.g. `{day=0, hour=0, tick=5}`).
  ---@return table
  function self:get_tick()
    local s = self._engine and self._engine._state
    if not s then return { tick = 0 } end
    return s:get_time()
  end

  --- Return author-declared UI bindings (`game_table.ui_panels`). Empty
  --- list until `ui_idea.md` §M4 ships the parser+codegen for panel
  --- declarations.
  ---@return table
  function self:get_bindings()
    local g = self._engine and self._engine._game
    return (g and g.ui_panels) or {}
  end

  -- ── Commands ───────────────────────────────────────────────

  --- Dispatch a player choice by 1-based visible index. On success,
  --- synthesises a `choice-made` event with `{scene, index, label}`.
  ---@param idx integer
  ---@return boolean ok
  function self:do_choice(idx)
    local eng = self._engine
    if not eng then return false end
    local scene_name = eng:current_scene()
    if not scene_name then return false end

    -- Validate index against the visible choice list and capture the
    -- chosen label *before* dispatching, since `do_choice` mutates the
    -- scene stack and the choice list may no longer be reachable.
    local _, choices = eng:render_scene(scene_name)
    if idx < 1 or idx > #choices then return false end
    local chosen_label = choices[idx] and choices[idx].label or nil

    local ok, sig = pcall(function() return eng:do_choice(scene_name, idx) end)
    if not ok then return false end

    -- Apply navigation signal returned by the choice body.
    if sig then
      if     sig.type == "goto"  and sig.target then eng:goto_scene(sig.target)
      elseif sig.type == "enter" and sig.target then eng:enter_scene(sig.target)
      elseif sig.type == "exit"                  then eng:exit_scene() end
    end

    -- Follow any unconditional scene-body navigation to a stable scene
    -- (mirrors lib/storybase.lua:choose so callers see the final scene).
    for _ = 1, 100 do
      local cur = eng:current_scene()
      if not cur then break end
      local _, _, nav = eng:render_scene(cur)
      if not nav then break end
      if     nav.type == "goto"  and nav.target then eng:goto_scene(nav.target)
      elseif nav.type == "enter" and nav.target then eng:enter_scene(nav.target)
      elseif nav.type == "exit"                 then eng:exit_scene()
      else break end
    end

    pcall(function() eng:post_action() end)

    self:emit("choice-made", {
      scene = scene_name, index = idx, label = chosen_label,
    })
    return true
  end

  --- Advance one autonomous turn (NPC/schedule steps; no player choice).
  function self:autonomous_turn()
    if self._engine then self._engine:autonomous_turn() end
  end

  --- Invoke a named game fn with raw Lua args. Defers to the embedding
  --- host (`lib/storybase.lua:call`) which knows how to convert raw
  --- values to AST literals and build a ctx. Returns nil if no engine
  --- is bound or if the engine exposes no `call_fn` helper.
  ---@param name string
  ---@return any
  function self:call_fn(name, ...)
    local eng = self._engine
    if not eng then return nil end
    -- The engine itself doesn't expose a raw-args fn caller; the lib
    -- wrapper does (lib/storybase.lua:call). For M1 we route through
    -- the host if it has registered one via k._call_fn (see §M7
    -- input-widget plan in ui_idea.md).
    if self._call_fn then return self._call_fn(name, ...) end
    return nil
  end

  --- Register a raw-args fn caller. The embedding host (typically the
  --- library or CLI) provides this so `k:call_fn` can route to the
  --- correct dispatch path without the kernel depending on `lib/`.
  ---@param fn function  `function(name, ...) -> any`
  function self:set_call_fn(fn) self._call_fn = fn end

  return self
end

return M

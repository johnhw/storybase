-- runtime/actors.lua
-- Actor registry: inbox management, behavior dispatch, deferred mutations.
--
-- Each actor's behavior function runs against a capture-proxy state store that
-- records all mutations instead of applying them immediately.  After all actors
-- have run, deferred mutations are applied to the real state in priority order:
--   set / clear  — highest-priority actor wins (first write per path)
--   inc / dec / collection ops — all actors' writes are applied

local M = {}

-- ============================================================
-- Perception helpers
-- ============================================================

--- Test whether a concrete path matches a perceives pattern.
--- Patterns may contain `*` as a wildcard segment.
---@param pattern string  e.g. "npcs/*/health" or "player/location"
---@param path    string  e.g. "npcs/guard/health"
---@return boolean
local function perceived(pattern, path)
  if pattern == "*" or pattern == path then return true end
  -- Escape Lua magic chars except *, then replace * with [^/]+
  local lp = pattern:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")
  lp = lp:gsub("%*", "[^/]+")
  return path:match("^" .. lp .. "$") ~= nil
end

--- Check if a path is visible to an actor given its perceives list.
--- Returns true if perceives is empty (unspecified = perceives all).
--- The actor's own state subtree (state_path/*) is always perceivable.
---@param perceives  table   list of pattern strings
---@param state_path string? actor's own state path prefix (e.g. "npcs/bot")
---@param path       string  concrete path
---@return boolean
local function path_perceived(perceives, state_path, path)
  if not perceives or #perceives == 0 then return true end
  -- Actor always perceives its own state subtree
  if state_path and (path == state_path
      or path:sub(1, #state_path + 1) == state_path .. "/") then
    return true
  end
  for _, pat in ipairs(perceives) do
    if perceived(pat, path) then return true end
  end
  return false
end

-- ============================================================
-- Capture proxy
-- ============================================================

--- Build a lightweight proxy around the real state store.
--- Read methods delegate to real_store only for perceived paths;
--- unperceived reads return nil (silent — compiler should have caught them).
--- Write methods append a capture record instead of mutating state.
---@param real_store  table   Runtime state store
---@param priority    number  Actor priority (higher = wins set conflicts)
---@param actor_name  string
---@param perceives   table?  list of path patterns (nil = perceive all)
---@param state_path  string? actor's own state path prefix (always perceived)
---@return table proxy, table captures
local function make_capture_proxy(real_store, priority, actor_name, perceives, state_path)
  local captures = {}

  -- Perception-filtered read proxy: fallback to real_store only for perceived paths.
  local read_store = setmetatable({}, {
    __index = function(_, k)
      local v = real_store[k]
      -- If 'k' looks like a method (function in the store), delegate directly
      if type(v) == "function" then return v end
      return v
    end
  })
  -- Override the `get` method to enforce perception
  read_store.get = function(_, path)
    if not path_perceived(perceives, state_path, path) then return nil end
    return real_store:get(path)
  end

  local proxy = setmetatable({}, { __index = read_store })

  proxy.set = function(_, path, val, _fn)
    captures[#captures+1] = { op="set",  path=path, value=val,
                               priority=priority, actor=actor_name }
  end
  proxy.inc = function(_, path, amount, _fn)
    captures[#captures+1] = { op="inc",  path=path, amount=amount,
                               priority=priority, actor=actor_name }
  end
  proxy.dec = function(_, path, amount, _fn)
    captures[#captures+1] = { op="dec",  path=path, amount=amount,
                               priority=priority, actor=actor_name }
  end
  proxy.add = function(_, path, val, _fn)
    captures[#captures+1] = { op="add",  path=path, value=val,
                               priority=priority, actor=actor_name }
  end
  proxy.remove = function(_, path, val, _fn)
    captures[#captures+1] = { op="remove", path=path, value=val,
                               priority=priority, actor=actor_name }
  end
  proxy.push = function(_, path, val, _fn)
    captures[#captures+1] = { op="push", path=path, value=val,
                               priority=priority, actor=actor_name }
  end
  proxy.pop = function(_, path, _fn)
    captures[#captures+1] = { op="pop",  path=path,
                               priority=priority, actor=actor_name }
  end
  proxy.clear = function(_, path, _fn)
    captures[#captures+1] = { op="clear", path=path,
                               priority=priority, actor=actor_name }
  end
  proxy.spawn = function(_, family, key, record, _fn)
    captures[#captures+1] = { op="spawn", family=family, key=key, record=record,
                               priority=priority, actor=actor_name }
  end
  proxy.despawn = function(_, family, key, _fn)
    captures[#captures+1] = { op="despawn", family=family, key=key,
                               priority=priority, actor=actor_name }
  end
  proxy.inc_time = function(_, axis, amount)
    captures[#captures+1] = { op="inc_time", axis=axis, amount=amount,
                               priority=priority, actor=actor_name }
  end
  proxy.set_time = function(_, axis, value)
    captures[#captures+1] = { op="set_time", axis=axis, value=value,
                               priority=priority, actor=actor_name }
  end

  return proxy, captures
end

-- ============================================================
-- Registry constructor
-- ============================================================

--- Create a new actor registry.
---@param state table  Runtime state store instance
---@param log   table  Transaction log instance
---@return table
function M.new(state, log)
  local registry = {
    _state        = state,
    _log          = log,
    _actors       = {},   -- list of actor defs, sorted by priority desc
    _pending_msgs = {},   -- { actor_name → {msg, ...} } queued by send!
    _deferred     = {},   -- accumulated capture records from last run_behaviors
  }

  -- ── Registration ──────────────────────────────────────────

  --- Register an actor from the compiled game table.
  ---@param actor_def table  {name, state_path, perceives, inbox_type, behavior, priority}
  function registry:register(actor_def)
    for _, a in ipairs(self._actors) do
      if a.name == actor_def.name then return end  -- deduplicate
    end
    self._actors[#self._actors + 1] = actor_def
    table.sort(self._actors, function(a, b) return a.priority > b.priority end)
    -- Mark inbox path as declared so SF-3 doesn't warn on engine-internal inbox writes.
    -- deliver_messages writes to inbox_path for any actor with pending messages.
    if self._state and self._state._type_index then
      local inbox_path = (actor_def.state_path or actor_def.name) .. "/inbox"
      self._state._type_index[inbox_path] = true
    end
  end

  -- ── Message sending ────────────────────────────────────────

  --- Enqueue a message for delivery into an actor's inbox.
  --- Called by the SEND_MUT evaluator during player-action or behavior phase.
  ---@param actor_name string
  ---@param msg        any   typed message value
  function registry:send(actor_name, msg)
    if not self._pending_msgs[actor_name] then
      self._pending_msgs[actor_name] = {}
    end
    local q = self._pending_msgs[actor_name]
    q[#q + 1] = msg
  end

  --- Push all pending messages into actor inbox state paths.
  --- Inbox path = "{state_path}/inbox"  (e.g. "npcs/blacksmith/inbox").
  function registry:deliver_messages()
    for _, actor in ipairs(self._actors) do
      local msgs = self._pending_msgs[actor.name]
      if msgs and #msgs > 0 then
        local inbox_path = (actor.state_path or actor.name) .. "/inbox"
        local current = self._state:get(inbox_path)
        if type(current) ~= "table" then current = {} end
        local max_inbox = actor.inbox_type and actor.inbox_type.max
        for _, msg in ipairs(msgs) do
          if max_inbox and #current >= max_inbox then
            -- Log overflow and skip remaining messages rather than aborting the turn
            if self._log then
              self._log:append({
                kind       = "inbox_overflow",
                fn         = "deliver",
                actor      = actor.name,
                inbox_path = inbox_path,
                max        = max_inbox,
              })
            end
            break
          end
          current[#current + 1] = msg
        end
        self._state:set(inbox_path, current, "deliver")
      end
    end
    self._pending_msgs = {}
  end

  -- ── Behavior dispatch ──────────────────────────────────────

  --- Run every registered actor's behavior function using a capture proxy.
  --- Actors are called in descending priority order.
  --- All mutations are deferred — call apply_deferred() afterwards.
  ---
  --- §H1: actors declared with `goal:` + `actions:` (no `behavior:`) get a
  --- BFS-driven plan from `runtime/actor_search.lua` and the first action of
  --- that plan is dispatched through the capture proxy in the same way a
  --- regular behavior fn would have been.  When no plan exists, the
  --- registry's `_no_progress_hook` (if set) fires with the actor name; the
  --- engine subscribes this to surface a "*{actor} hesitates*" line.
  ---@param fns table  game_table.fns
  function registry:run_behaviors(fns)
    local eval         = require("runtime.eval")
    local actor_search = require("runtime.actor_search")
    local all_captures = {}

    for _, actor in ipairs(self._actors) do
      -- §H1 branch: goal-directed actor — plan with BFS, then dispatch
      -- the chosen action through a capture proxy so it commits via the
      -- regular conflict-resolution path.
      if actor.goal and actor.actions and #actor.actions > 0 then
        local game = self._game  -- set by engine:register_actors_schedules
        local plan = actor_search.find_plan(self._state, game, actor)
        if not plan then
          if self._no_progress_hook then
            pcall(self._no_progress_hook, actor.name)
          end
          goto continue
        end

        -- Goal already met: silent no-op (don't dispatch, don't fire
        -- the no-progress hook — the actor is done, not blocked).
        if plan.satisfied then goto continue end

        local fn_def = fns and fns[plan.name]
        if not fn_def then goto continue end

        local proxy, captures = make_capture_proxy(
          self._state, actor.priority, actor.name, actor.perceives, actor.state_path)

        local ctx = eval.new_ctx(proxy, fns, plan.name, game)
        ctx.actors = self
        local ok, _err = pcall(eval.call_fn, plan.name, plan.arg_nodes, ctx)
        if not ok then captures = {} end

        for _, c in ipairs(captures) do
          all_captures[#all_captures + 1] = c
        end
        goto continue
      end

      do
        local behavior = actor.behavior
        local fn_def   = behavior and fns and fns[behavior]
        if not fn_def then goto continue end

        local proxy, captures = make_capture_proxy(
          self._state, actor.priority, actor.name, actor.perceives, actor.state_path)

        -- Check pre: conditions against real state (not the proxy)
        local pre_ctx = eval.new_ctx(self._state, fns, behavior)
        local pre_ok  = true
        for _, pre_expr in ipairs(fn_def.pre or {}) do
          if not eval.eval_expr(pre_expr, pre_ctx) then
            pre_ok = false; break
          end
        end

        if pre_ok then
          local ctx    = eval.new_ctx(proxy, fns, behavior)
          ctx.actors   = self   -- allow send! within behavior bodies
          local ok, _err = pcall(eval.eval_stmts, fn_def.body, ctx)
          if not ok then
            captures = {}   -- discard writes from a failed behavior
          end
        end

        for _, c in ipairs(captures) do
          all_captures[#all_captures + 1] = c
        end
      end

      ::continue::
    end

    -- Stable sort by priority descending so highest-priority set wins below
    table.sort(all_captures, function(a, b) return a.priority > b.priority end)
    self._deferred = all_captures
  end

  --- Subscribe to the "actor has no plan toward its goal" signal.
  --- The engine wires this to surface a one-line narration fallback.
  ---@param fn function(actor_name)
  function registry:on_no_progress(fn)
    self._no_progress_hook = fn
  end

  --- Inject the compiled game table so goal-directed actors can resolve fns
  --- and schema types during BFS planning.  Called by the engine during
  --- `register_actors_schedules`.
  function registry:set_game(game)
    self._game = game
  end

  -- ── Deferred mutation application ─────────────────────────

  --- Apply all deferred mutations to the real state.
  ---   set / clear  — first write per path wins (= highest priority actor)
  ---   inc / dec / collection / spawn / despawn / inc_time — all applied
  function registry:apply_deferred()
    local written = {}  -- paths already claimed by a higher-priority set/clear

    for _, c in ipairs(self._deferred) do
      local tag = "actor:" .. (c.actor or "?")

      if c.op == "set" then
        if not written[c.path] then
          written[c.path] = { actor = c.actor, priority = c.priority }
          self._state:set(c.path, c.value, tag)
        elseif self._log then
          -- Log the conflict: this actor's write was discarded
          local winner = written[c.path]
          self._log:append({
            kind          = "conflict",
            path          = c.path,
            fn            = tag,
            winner_actor  = winner.actor,
            loser_actor   = c.actor,
            loser_value   = c.value,
          })
        end

      elseif c.op == "clear" then
        if not written[c.path] then
          written[c.path] = { actor = c.actor, priority = c.priority }
          self._state:clear(c.path, tag)
        elseif self._log then
          local winner = written[c.path]
          self._log:append({
            kind          = "conflict",
            path          = c.path,
            fn            = tag,
            winner_actor  = winner.actor,
            loser_actor   = c.actor,
            loser_value   = nil,
          })
        end

      elseif c.op == "inc" then
        self._state:inc(c.path, c.amount, tag)

      elseif c.op == "dec" then
        self._state:dec(c.path, c.amount, tag)

      elseif c.op == "add" then
        self._state:add(c.path, c.value, tag)

      elseif c.op == "remove" then
        self._state:remove(c.path, c.value, tag)

      elseif c.op == "push" then
        self._state:push(c.path, c.value, tag)

      elseif c.op == "pop" then
        pcall(function() self._state:pop(c.path, tag) end)

      elseif c.op == "spawn" then
        -- Guard: skip if the key already exists in the family
        pcall(function()
          self._state:spawn(c.family, c.key, c.record, tag)
        end)

      elseif c.op == "despawn" then
        pcall(function()
          self._state:despawn(c.family, c.key, tag)
        end)

      elseif c.op == "inc_time" then
        self._state:inc_time(c.axis, c.amount)

      elseif c.op == "set_time" then
        self._state:set_time(c.axis, c.value)
      end
    end

    self._deferred = {}
  end

  -- ── Inbox clearing ─────────────────────────────────────────

  --- Clear every actor's inbox state path at end of turn.
  function registry:clear_inboxes()
    for _, actor in ipairs(self._actors) do
      local inbox_path = (actor.state_path or actor.name) .. "/inbox"
      local current = self._state:get(inbox_path)
      if type(current) == "table" and #current > 0 then
        self._state:set(inbox_path, {}, "clear_inboxes")
      end
    end
  end

  return registry
end

return M

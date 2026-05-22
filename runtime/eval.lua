-- runtime/eval.lua
-- Tree-walking evaluator for StoryBase expression and statement AST nodes.
--
-- Evaluates the AST nodes emitted by the compiler (fn bodies, scene conditions,
-- narration inline expressions) against a live state store.
--
-- Context table (ctx) fields:
--   ctx.state    — runtime.state instance
--   ctx.fns      — compiled fns table (game_table.fns)
--   ctx.vars     — local variable bindings {name → value} (let/for scopes)
--   ctx.fn_name  — string: current function name, used in log entries
--   ctx.signal   — set by scene-navigation stmts: {type="goto"|"enter"|"exit", target=name}
--   ctx.retval   — last expression value (for pure function return values)
--   ctx.call_pos — {file,line,col} of the most recent fn_call node; used by log builtin
--   ctx.game._print_sink — optional function(string) for redirecting print/log output
--   ctx.game.production  — when true, print/log are silently suppressed

local M = {}

-- ============================================================
-- Kind constants (mirrors ast.K, kept local to avoid import)
-- ============================================================

local K = {
  BOOL_LIT           = "bool_lit",
  INT_LIT            = "int_lit",
  FLOAT_LIT          = "float_lit",
  STRING_LIT         = "string_lit",
  MULTILINE_STRING   = "multiline_string",
  SYMBOL_LIT         = "symbol_lit",
  PATH_EXPR          = "path_expr",
  INTERP_PATH        = "interp_path",
  BINARY_OP          = "binary_op",
  UNARY_OP           = "unary_op",
  NIL_COALESCE       = "nil_coalesce",
  FN_CALL            = "fn_call",
  IF_EXPR            = "if_expr",
  WHEN_STMT          = "when_stmt",
  MATCH_EXPR         = "match_expr",
  COND_EXPR          = "cond_expr",
  FOR_STMT           = "for_stmt",
  WHILE_STMT         = "while_stmt",
  BREAK_STMT         = "break_stmt",
  CONTINUE_STMT      = "continue_stmt",
  RETURN_STMT        = "return_stmt",
  LET_STMT           = "let_stmt",
  LET_BINDING        = "let_binding",
  LAMBDA_EXPR        = "lambda_expr",
  PASS_STMT          = "pass_stmt",
  EXPR_STMT          = "expr_stmt",
  MATCH_ARM          = "match_arm",
  COND_ARM           = "cond_arm",
  NAMED_ARG          = "named_arg",
  RECORD_CONSTRUCTOR = "record_constructor",
  LIST_LIT           = "list_lit",
  SET_LIT            = "set_lit",
  MAP_LIT            = "map_lit",
  EMPTY_SET          = "empty_set",
  EMPTY_LIST         = "empty_list",
  EMPTY_MAP          = "empty_map",
  INLINE_EXPR        = "inline_expr",
  SET_MUT            = "set_mut",
  INC_MUT            = "inc_mut",
  DEC_MUT            = "dec_mut",
  ADD_MUT            = "add_mut",
  REMOVE_MUT         = "remove_mut",
  CLEAR_MUT          = "clear_mut",
  PUSH_MUT           = "push_mut",
  POP_MUT            = "pop_mut",
  MAP_SET_MUT        = "map_set_mut",
  MAP_DELETE_MUT     = "map_delete_mut",
  SPAWN_MUT          = "spawn_mut",
  DESPAWN_MUT        = "despawn_mut",
  RELATE_MUT         = "relate_mut",
  UNRELATE_MUT       = "unrelate_mut",
  RELATE_BOTH_MUT    = "relate_both_mut",
  UNRELATE_BOTH_MUT  = "unrelate_both_mut",
  SEND_MUT           = "send_mut",
  UNDO_MUT           = "undo_mut",
  TIME_INC_MUT       = "time_inc_mut",
  TIME_SET_MUT       = "time_set_mut",
  CANCEL_SCHEDULE_MUT = "cancel_schedule_mut",
  SCHEDULE_MUT        = "schedule_mut",
  CHECKPOINT_MUT      = "checkpoint_mut",
  EMIT_MUT            = "emit_mut",
  PATH_AT_BEFORE        = "path_at_before",
  COUNTERFACTUAL_EXPR   = "counterfactual_expr",
  IN_STATE_EXPR         = "in_state_expr",
  FIND_EXPR             = "find_expr",
  INDEX_EXPR            = "index_expr",
  SLICE_EXPR            = "slice_expr",
  SCENE_GOTO         = "scene_goto",
  SCENE_ENTER        = "scene_enter",
  SCENE_EXIT         = "scene_exit",
  GOTO_SCENE_MUT     = "goto_scene_mut",
  ENTER_SCENE_MUT    = "enter_scene_mut",
  EXIT_SCENE_MUT     = "exit_scene_mut",
  SAY_STMT           = "say_stmt",
}

-- ============================================================
-- Context helpers
-- ============================================================

-- Module-level lazy require for the PCG RNG. We can't require at top of file
-- because runtime.random doesn't yet exist when eval.lua is first parsed in
-- some bundling scenarios; lazy-load on first ctx creation.
local _random_mod

--- Create a new evaluation context.
--- Always allocates a fresh per-context PCG RNG so that calls to random-* never
--- touch Lua's global math.random state. Engine-driven eval contexts overwrite
--- this with the engine's logged RNG via engine:make_ctx.
---@param state   table   runtime.state instance
---@param fns     table   game_table.fns
---@param fn_name string  current function name (for log)
---@param game    table?  compiled game table (for can-reach? etc.)
---@return table
function M.new_ctx(state, fns, fn_name, game)
  _random_mod = _random_mod or require("runtime.random")
  return {
    state      = state,
    fns        = fns or {},
    vars       = {},
    nil_vars   = {},   -- tracks variable names explicitly bound to nil
    fn_name    = fn_name or "?",
    signal     = nil,
    retval     = nil,
    game       = game,
    engine_ref = nil,  -- set by engine:make_ctx; used for engine/ pseudo-paths
    rng        = _random_mod.new(),  -- replaced by engine's logged rng when present
  }
end

--- Create a child context that shares state/fns but has its own var scope.
---@param parent table  parent context
---@param fn_name string?  override fn_name (optional)
---@return table
local function child_ctx(parent, fn_name)
  local child = {
    state   = parent.state,
    fns     = parent.fns,
    vars    = {},
    fn_name = fn_name or parent.fn_name,
    signal  = nil,
    retval  = nil,
    actors    = parent.actors,     -- propagate actor registry for send!
    scheduler = parent.scheduler,  -- propagate scheduler for cancel-schedule!
    rng        = parent.rng,        -- propagate seeded RNG
    game       = parent.game,       -- propagate compiled game table
    debug      = parent.debug,      -- propagate debug server for event emission
    engine_ref = parent.engine_ref, -- propagate engine reference for engine/ paths
    grids      = parent.grids,      -- propagate tile grid data
    scene_stack = parent.scene_stack,
    counterfactual_depth = parent.counterfactual_depth,  -- propagate nesting depth
    _in_bfs  = parent._in_bfs,   -- propagate BFS-mode guard (prevents recursive BFS)
    narration_buf = parent.narration_buf,  -- propagate say output buffer
    nil_vars = {},   -- tracks variable names explicitly bound to nil
  }
  -- Copy parent vars and nil_vars into child (shadowing allowed)
  for k, v in pairs(parent.vars) do
    child.vars[k] = v
  end
  for k in pairs(parent.nil_vars or {}) do
    child.nil_vars[k] = true
  end
  return child
end

-- ============================================================
-- Path resolution
-- ============================================================

--- Evaluate a path node to a path string.
--- path_expr: segments joined with "/".
--- interp_path: {interp="varname"} segments substituted from ctx.vars.
---@param node table  path_expr or interp_path node
---@param ctx  table  evaluation context
---@return string
local function eval_path(node, ctx)
  if not node then return "?" end
  if node.kind == K.PATH_EXPR then
    return table.concat(node.segments or {}, "/")
  elseif node.kind == K.INTERP_PATH then
    local parts = {}
    for _, seg in ipairs(node.segments or {}) do
      if type(seg) == "table" and seg.interp then
        local val
        if seg.interp:find("/", 1, true) then
          -- path expression: look up value from state (e.g. {player/companion})
          val = ctx.state and ctx.state:get(seg.interp)
        else
          val = ctx.vars[seg.interp]
        end
        parts[#parts + 1] = tostring(val ~= nil and val or seg.interp)
      else
        parts[#parts + 1] = tostring(seg)
      end
    end
    return table.concat(parts, "/")
  end
  return tostring(node)
end

-- ============================================================
-- Forward declarations
-- ============================================================

local eval_expr, eval_stmt, eval_stmts, call_fn, eval_match, eval_cond

-- ============================================================
-- Dynamic relation helper
-- ============================================================

--- Return a relation view that merges the static compiled edges with any dynamic
--- edges stored in the state cache under "__rel/<name>/<src>" keys.
--- Cache entries are tables {target=true/false}: true=added, false=removed.
--- Returns the original relation unchanged when no dynamic overrides exist.
---@param rel      table?  game_table.relations[name]
---@param rel_name string  relation name
---@param cache    table?  state._cache
---@return table  merged relation object with .data
local function effective_rel(rel, rel_name, cache)
  if not cache or not rel_name then return rel end
  local prefix = "__rel/" .. rel_name .. "/"
  local plen   = #prefix
  local has_dyn = false
  for k in pairs(cache) do
    if k:sub(1, plen) == prefix then has_dyn = true; break end
  end
  if not has_dyn then return rel end
  -- Build merged data: start from static, apply dynamic overrides
  local static  = rel and rel.data or {}
  local merged  = {}
  for src, tgts in pairs(static) do
    local m = {}; for t in pairs(tgts) do m[t] = true end
    merged[src] = m
  end
  for k, dyn in pairs(cache) do
    if k:sub(1, plen) == prefix and type(dyn) == "table" then
      local src = k:sub(plen + 1)
      merged[src] = merged[src] or {}
      for t, v in pairs(dyn) do
        if v then merged[src][t] = true else merged[src][t] = nil end
      end
    end
  end
  return { data = merged }
end

--- Write one dynamic relation edge into the state cache.
--- value=true adds an edge, value=false removes it (overriding static edges).
--- Routes through state:set so the edit is logged, saved, undoable, BFS-visible.
local function write_rel_edge(ctx, rel_name, source, target, value)
  if not ctx.state or not rel_name then return end
  local cache_key = "__rel/" .. rel_name .. "/" .. source
  local old_dyn = ctx.state._cache[cache_key] or {}
  local new_dyn = {}
  for t, v in pairs(old_dyn) do new_dyn[t] = v end
  new_dyn[target] = value
  ctx.state:set(cache_key, new_dyn, ctx.fn_name)
end

-- ============================================================
-- Expression evaluator
-- ============================================================

--- Evaluate an expression node and return its Lua value.
---@param node table  AST expression node
---@param ctx  table  evaluation context
---@return any
eval_expr = function(node, ctx)
  if not node then return nil end
  local k = node.kind

  -- Literals
  if k == K.BOOL_LIT then return node.value
  elseif k == K.INT_LIT or k == K.FLOAT_LIT then return node.value
  elseif k == K.STRING_LIT or k == K.MULTILINE_STRING then return node.value
  elseif k == K.SYMBOL_LIT then return node.name  -- symbols are strings internally
  -- Named-arg node appearing as an expression (e.g. after macro param substitution)
  elseif k == K.NAMED_ARG then return eval_expr(node.value, ctx)

  -- Path read
  elseif k == K.PATH_EXPR then
    local path = eval_path(node, ctx)
    local segs = node.segments or {}
    -- Check local vars first (single-segment paths can be loop/let vars).
    -- Must check nil_vars before falling through: a var explicitly bound to nil
    -- is absent from ctx.vars but must not read from the state store.
    if #segs == 1 then
      local n = segs[1]
      if ctx.vars[n] ~= nil then return ctx.vars[n] end
      if ctx.nil_vars and ctx.nil_vars[n] then return nil end
    end
    -- Multi-segment path where first segment is a local table var (record field access)
    if #segs > 1 and ctx.vars[segs[1]] ~= nil then
      local base = ctx.vars[segs[1]]
      if type(base) == "table" then
        for i = 2, #segs do
          if type(base) ~= "table" then return nil end
          base = base[segs[i]]
        end
        return base
      end
    end
    -- Engine pseudo-paths: engine/current-scene, engine/tick, etc.
    if path == "engine/current-scene" then
      local eng = ctx.engine_ref
      return eng and eng:current_scene() or nil
    elseif path == "engine/scene-stack" then
      local eng = ctx.engine_ref
      if not eng then return {} end
      local s = {}
      for _, v in ipairs(eng._scene_stack or {}) do s[#s+1] = v end
      return s
    elseif path == "engine/tick" then
      if ctx.state and ctx.state._time then return ctx.state._time.tick or 0 end
      return 0
    elseif path == "engine/time" then
      if ctx.state and ctx.state._time then
        local t = {}
        for k, v in pairs(ctx.state._time) do t[k] = v end
        return t
      end
      return {}
    elseif path:sub(1, 5) == "time/" then
      -- time/<axis> — read-only pseudo-path for a declared time axis value
      local axis = path:sub(6)
      if ctx.state and ctx.state._time then
        return ctx.state._time[axis]
      end
      return nil
    end
    local val = ctx.state:get(path)
    -- Fn-call fallback for single-segment paths whose state value is nil
    -- but a fn of the same name exists. This restores symmetry between
    -- `cast-fireball-once?` (a plain IDENT, parsed as fn_call) and
    -- `cast-$name-once?` after substitution (a single-segment path_expr).
    -- A state path with a declared default returns its declared value here
    -- (e.g. `false`, `0`, `""`), so fns can never shadow a real state path.
    if val == nil and #segs == 1 and ctx.fns and ctx.fns[segs[1]] then
      return call_fn(segs[1], {}, ctx)
    end
    return val

  elseif k == K.INTERP_PATH then
    return ctx.state:get(eval_path(node, ctx))

  elseif k == K.INDEX_EXPR then
    -- path[n]: read element n (1-based) from a list/set at the given path
    local list = eval_expr(node.base, ctx)
    -- If base evaluated to a string, it may be a bare single-segment state path name.
    -- Try reading it from state so that `items[1]` works for top-level list state.
    if type(list) == "string" and ctx.state then
      list = ctx.state:get(list)
    end
    local idx  = eval_expr(node.index, ctx)
    if type(list) ~= "table" then return nil end
    if type(idx) == "string" then return list[idx] end  -- symbol/string key: map field access
    if type(idx) ~= "number" then return nil end
    -- Support negative indices: -1 = last, -2 = second-to-last, etc.
    if idx < 0 then idx = #list + idx + 1 end
    return list[idx]

  elseif k == K.SLICE_EXPR then
    -- path[a:b]: return a sub-list from index a to index b (inclusive, 1-based)
    local list = eval_expr(node.base, ctx)
    if type(list) == "string" and ctx.state then
      list = ctx.state:get(list)
    end
    if type(list) ~= "table" then return {} end
    local len  = #list
    local from = eval_expr(node.from, ctx) or 1
    local to   = eval_expr(node.to,   ctx) or len
    if from < 0 then from = len + from + 1 end
    if to   < 0 then to   = len + to   + 1 end
    from = math.max(1, from)
    to   = math.min(len, to)
    local result = {}
    for i = from, to do result[#result+1] = list[i] end
    return result

  elseif k == K.PATH_AT_BEFORE then
    -- path@before: read value from before-snapshot if available
    local path = eval_path(node.path, ctx)
    if ctx.before_snapshot then
      return ctx.before_snapshot[path]
    end
    -- Fallback to current state (for contexts without a snapshot)
    return ctx.state:get(path)

  elseif k == K.COUNTERFACTUAL_EXPR then
    -- Enforce max-counterfactual-depth nesting limit
    local cf_depth = (ctx.counterfactual_depth or 0) + 1
    local max_depth = ctx.game and ctx.game.schema
      and ctx.game.schema.engine_config
      and ctx.game.schema.engine_config["max-counterfactual-depth"]
      or 10
    if cf_depth > max_depth then
      error("max-counterfactual-depth exceeded: nesting depth " .. cf_depth
            .. " exceeds limit of " .. max_depth)
    end

    -- Create a branched GameState, starting from either the current state or
    -- a historical snapshot built by replaying the log up to from_tick.
    local log_mod   = require("runtime.log")
    local state_mod = require("runtime.state")
    local cf_log    = log_mod.new()
    local cf_state  = state_mod.new(ctx.state and ctx.state._schema or {}, cf_log)

    if node.from_tick then
      -- Evaluate the from_tick expression to a tick number
      local target_tick = eval_expr(node.from_tick, ctx)
      if type(target_tick) == "number" and ctx.state and ctx.state._log then
        -- Replay log mutations up to target_tick to reconstruct historical state
        cf_state:init_defaults()
        for _, e in ipairs(ctx.state._log._entries or {}) do
          if e.path ~= nil then
            local etime = type(e.time) == "table" and (e.time.tick or 0) or 0
            if etime <= target_tick then
              if type(e["new"]) == "table" then
                local c = {}
                for tk, tv in pairs(e["new"]) do c[tk] = tv end
                cf_state._cache[e.path] = c
              else
                cf_state._cache[e.path] = e["new"]
              end
              if type(e.time) == "table" then
                for k, v in pairs(e.time) do cf_state._time[k] = v end
              end
            end
          end
        end
      else
        -- from_tick evaluated to non-number or no log available: copy current state
        for path, val in pairs(ctx.state and ctx.state._cache or {}) do
          if type(val) == "table" then
            local c = {}; for tk, tv in pairs(val) do c[tk] = tv end
            cf_state._cache[path] = c
          else
            cf_state._cache[path] = val
          end
        end
        for axis, v in pairs(ctx.state and ctx.state._time or {}) do
          cf_state._time[axis] = v
        end
      end
    else
      -- No from_tick: deep-copy current cache
      for path, val in pairs(ctx.state and ctx.state._cache or {}) do
        if type(val) == "table" then
          local c = {}; for tk, tv in pairs(val) do c[tk] = tv end
          cf_state._cache[path] = c
        else
          cf_state._cache[path] = val
        end
      end
      -- Copy time
      for axis, v in pairs(ctx.state and ctx.state._time or {}) do
        cf_state._time[axis] = v
      end
    end
    -- Apply transition function calls to the copy
    local cf_ctx = M.new_ctx(cf_state, ctx.fns, "counterfactual", ctx.game)
    cf_ctx.actors              = ctx.actors
    cf_ctx.scheduler           = ctx.scheduler
    cf_ctx.counterfactual_depth = cf_depth  -- propagate nesting depth
    cf_ctx.rng                 = ctx.rng    -- share seeded RNG so draws are logged
    cf_ctx.grids               = ctx.grids  -- tile grid data
    cf_ctx.engine_ref          = ctx.engine_ref
    cf_ctx._in_bfs             = ctx._in_bfs
    pcall(eval_stmts, node.transitions or {}, cf_ctx)
    -- simulate: true — run one round of actor behaviors + scheduler on the copy
    if node.simulate and ctx.actors then
      local actors_mod = require("runtime.actors")
      local sched_mod  = require("runtime.scheduler")
      local log_mod2   = require("runtime.log")
      local sim_log    = log_mod2.new()
      local sim_actors = actors_mod.new(cf_state, sim_log)
      -- Register actors from game table if available
      if ctx.game then
        for _, a in pairs(ctx.game.actors or {}) do sim_actors:register(a) end
      end
      local sim_sched = sched_mod.new(cf_state, sim_log)
      if ctx.game then
        for _, s in pairs(ctx.game.schedules or {}) do
          sim_sched:register(s.name, s.trigger, s.body)
        end
      end
      sim_actors:deliver_messages()
      sim_actors:run_behaviors(ctx.fns)
      sim_actors:apply_deferred()
      sim_sched:tick(ctx.fns)
      sim_actors:clear_inboxes()
    end
    -- Append counterfactual trace entry to live log (debug/audit trail)
    if ctx.state and ctx.state._log then
      local trans_names = {}
      for _, t in ipairs(node.transitions or {}) do
        if t.kind == "fn_call" and t.name then
          trans_names[#trans_names+1] = t.name
        end
      end
      ctx.state._log:append({
        kind        = "counterfactual",
        transitions = trans_names,
        simulate    = node.simulate or false,
        fn          = ctx.fn_name or "?",
      })
    end
    -- Return an immutable GameState object (read-only wrapper)
    return {
      _cache = cf_state._cache,
      _time  = cf_state._time,
      get    = function(self, path) return self._cache[path] end,
      path_exists = function(self, path) return self._cache[path] ~= nil end,
    }

  elseif k == K.IN_STATE_EXPR then
    -- Read inner_expr using the GameState's cache instead of live state
    local gs = eval_expr(node.state_expr, ctx)
    if not gs or type(gs) ~= "table" or not gs._cache then
      error("in-state: expected a GameState value, got " .. type(gs))
    end
    local log_mod   = require("runtime.log")
    local state_mod = require("runtime.state")
    local fake_log   = log_mod.new()
    local fake_state = state_mod.new(ctx.state and ctx.state._schema or {}, fake_log)
    fake_state._cache = gs._cache
    fake_state._time  = gs._time or {}
    local gs_ctx = {
      state   = fake_state,
      fns     = ctx.fns,
      vars    = ctx.vars,
      fn_name = "in-state",
      signal  = nil,
      retval  = nil,
      actors    = ctx.actors,
      scheduler = ctx.scheduler,
    }
    return eval_expr(node.inner_expr, gs_ctx)

  -- Binary operators
  elseif k == K.BINARY_OP then
    local l = eval_expr(node.left, ctx)
    local r = eval_expr(node.right, ctx)
    local op = node.op
    if op == "="   then return l == r
    elseif op == "!=" then return l ~= r
    elseif op == "<"  then return l < r
    elseif op == ">"  then return l > r
    elseif op == "<=" then return l <= r
    elseif op == ">=" then return l >= r
    elseif op == "+"  then return (l or 0) + (r or 0)
    elseif op == "-"  then return (l or 0) - (r or 0)
    elseif op == "*"  then return (l or 0) * (r or 0)
    elseif op == "/"  then
      if r == 0 then return 0 end
      return l / r
    elseif op == "and" then return l and r
    elseif op == "or"  then return l or r
    elseif op == "in"  then
      -- Membership test: l in r (r is a list/set/adjacency table)
      if type(r) ~= "table" then return false end
      -- Array-style check (list/set literals)
      for _, v in ipairs(r) do
        if v == l then return true end
      end
      -- Map-style check (relation adjacency or UMap membership)
      if r[l] ~= nil then return true end
      return false
    end
    return nil

  -- Unary operators
  elseif k == K.UNARY_OP then
    local val = eval_expr(node.expr, ctx)
    if node.op == "not" then return not val end
    return nil

  -- Nil-coalescing
  elseif k == K.NIL_COALESCE then
    local l = eval_expr(node.left, ctx)
    if l ~= nil then return l end
    return eval_expr(node.right, ctx)

  -- Function call
  elseif k == K.FN_CALL then
    ctx.call_pos = node.pos   -- expose source location to builtins (print/log)
    return call_fn(node.name, node.args, ctx)

  -- If expression
  elseif k == K.IF_EXPR then
    local cond = eval_expr(node.condition, ctx)
    if cond then
      local sub = child_ctx(ctx)
      eval_stmts(node.then_body, sub)
      -- Don't propagate 'return': the value was captured as sub.retval by this expression.
      -- Navigation signals (goto/enter/exit/break/continue) still propagate.
      if sub.signal and sub.signal.type ~= "return" then ctx.signal = sub.signal end
      return sub.retval
    elseif node.else_body then
      local sub = child_ctx(ctx)
      eval_stmts(node.else_body, sub)
      if sub.signal and sub.signal.type ~= "return" then ctx.signal = sub.signal end
      return sub.retval
    end
    return nil

  -- Match expression
  elseif k == K.MATCH_EXPR then
    return eval_match(node, ctx)

  -- Cond expression
  elseif k == K.COND_EXPR then
    return eval_cond(node, ctx)

  -- Lambda expression — return as a callable table
  elseif k == K.LAMBDA_EXPR then
    return { _lambda = true, params = node.params, body = node.body, captured_ctx = ctx }

  -- Collection literals
  elseif k == K.EMPTY_LIST or k == K.EMPTY_SET or k == K.EMPTY_MAP then
    return {}
  elseif k == K.LIST_LIT or k == K.SET_LIT then
    local t = {}
    for _, elem in ipairs(node.elements or {}) do
      t[#t + 1] = eval_expr(elem, ctx)
    end
    return t
  elseif k == K.MAP_LIT then
    -- entries are named_arg nodes with .name (key string) and .value (expr)
    local t = {}
    for _, entry in ipairs(node.entries or {}) do
      local key = entry.name  -- string key from named_arg
      local val = eval_expr(entry.value, ctx)
      t[key] = val
    end
    return t

  -- find query expression
  elseif k == K.FIND_EXPR then
    local query_mod = require("runtime.query")
    -- Check for in-state: clause — redirect find to a GameState's cache
    local find_ctx = ctx
    for _, clause in ipairs(node.clauses or {}) do
      if clause.kind == "in_state" then
        local gs = eval_expr(clause.state_expr, ctx)
        if gs and type(gs) == "table" and gs._cache then
          local log_mod2   = require("runtime.log")
          local state_mod2 = require("runtime.state")
          local flog   = log_mod2.new()
          local fstate = state_mod2.new(ctx.state and ctx.state._schema or {}, flog)
          fstate._cache = gs._cache
          fstate._time  = gs._time or {}
          find_ctx = {
            state     = fstate,
            fns       = ctx.fns,
            vars      = ctx.vars or {},
            fn_name   = "find-in-state",
            signal    = nil,
            retval    = nil,
            game      = ctx.game,
            actors    = ctx.actors,
            scheduler = ctx.scheduler,
          }
        end
        break
      end
    end
    return query_mod.find(find_ctx, node.family, node.clauses)

  -- Record constructor: TypeName(field: val, ...)
  elseif k == K.RECORD_CONSTRUCTOR then
    -- Embed the variant name so match patterns can identify the branch.
    -- e.g. (ActorMsg/trade-offer item: x, price: y) → {__variant="ActorMsg/trade-offer", item=x, price=y}
    local record = { __variant = node.type_name }
    for _, f in ipairs(node.fields or {}) do
      if f.kind == K.NAMED_ARG then
        record[f.name] = eval_expr(f.value, ctx)
      end
    end
    return record
  end

  return nil
end

-- ============================================================
-- match / cond helpers
-- ============================================================

--- Evaluate a wildcard string or pattern check.

eval_match = function(node, ctx)
  local subject = eval_expr(node.expr, ctx)
  for _, arm in ipairs(node.arms or {}) do
    if arm.kind == K.MATCH_ARM then
      local matched  = false
      local bind_vars = {}  -- field bindings from variant destructuring
      local pat = arm.pattern

      if pat == "_" then
        matched = true

      elseif type(pat) == "table" and pat.kind == K.RECORD_CONSTRUCTOR then
        -- Variant destructuring: match when subject.__variant matches the pattern name.
        -- Pattern name may be the full "Type/branch" or just "branch" — compare both.
        if type(subject) == "table" then
          local variant_name = pat.type_name or ""
          local subj_tag     = subject.__variant
          local pat_simple   = variant_name:match("[^/]+$") or variant_name
          local subj_simple  = subj_tag and (subj_tag:match("[^/]+$") or subj_tag)

          if subj_tag == nil                 -- no tag → always match (plain table)
          or subj_tag    == variant_name     -- exact full match
          or subj_simple == pat_simple       -- short name match ("ping" == "ping")
          then
            matched = true
            -- Bind each named field from subject into bind_vars
            for _, f in ipairs(pat.fields or {}) do
              if f.kind == K.NAMED_ARG then
                bind_vars[f.name] = subject[f.name]
              end
            end
          end
        end

      else
        local pval = eval_expr(pat, ctx)
        matched = (pval == subject)
      end

      if matched then
        local sub = child_ctx(ctx)
        for bk, bv in pairs(bind_vars) do sub.vars[bk] = bv end
        if type(arm.body) == "table" and arm.body.kind then
          return eval_expr(arm.body, sub)
        else
          eval_stmts(arm.body, sub)
          if sub.signal then ctx.signal = sub.signal end
          return nil
        end
      end
    end
  end
  -- No arm matched and no wildcard — emit a dev-mode warning
  if not (ctx.game and ctx.game.production) then
    local subj_str = (type(subject) == "string") and ("'" .. subject) or tostring(subject)
    local msg = "[WARN] match: unhandled value " .. subj_str ..
                " — add arms for this value or a wildcard '_:' arm\n"
    local sink = ctx.game and ctx.game._print_sink
    if sink then sink(msg) else io.stderr:write(msg) end
  end
  return nil
end

eval_cond = function(node, ctx)
  for _, arm in ipairs(node.arms or {}) do
    if arm.kind == K.COND_ARM then
      local cond_ok
      if arm.condition == "_" then
        cond_ok = true
      else
        cond_ok = eval_expr(arm.condition, ctx)
      end
      if cond_ok then
        if type(arm.body) == "table" and arm.body.kind then
          return eval_expr(arm.body, ctx)
        else
          local sub = child_ctx(ctx)
          eval_stmts(arm.body, sub)
          if sub.signal then ctx.signal = sub.signal end
          return nil
        end
      end
    end
  end
  return nil
end

-- ============================================================
-- Function call dispatch
-- ============================================================

--- Call a lambda value with positional arguments.
---@param lam  table  lambda table from eval_expr
---@param args table  list of already-evaluated argument values
---@param ctx  table  caller context (for state access)
---@return any
local function call_lambda(lam, args, ctx)
  if type(lam) ~= "table" or not lam._lambda then return nil end
  local sub = child_ctx(lam.captured_ctx or ctx)
  for i, param in ipairs(lam.params or {}) do
    sub.vars[param] = args[i]
  end
  local result
  local body = lam.body
  if type(body) == "table" and body.kind then
    result = eval_expr(body, sub)
  else
    eval_stmts(body, sub)
    result = sub.retval  -- multi-line lambda: use retval from return stmt or last expr
  end
  return result
end

-- Path pattern matching (mirrors debug.lua path_matches; used by query-history/query-changes).
-- Supports: * (single segment), ** (any segments), (a|b) alternation, !seg negation.
local function _path_pattern_matches(pattern, path)
  if pattern == "*"  then return true end
  if pattern == path then return true end
  -- Expand (a|b|c) alternation groups recursively
  local alt_s, alt_e = pattern:find("%((.-)%)")
  if alt_s then
    local before    = pattern:sub(1, alt_s - 1)
    local alt_inner = pattern:sub(alt_s + 1, alt_e - 1)
    local after     = pattern:sub(alt_e + 1)
    for branch in alt_inner:gmatch("[^|]+") do
      if _path_pattern_matches(before .. branch .. after, path) then return true end
    end
    return false
  end
  -- Handle !segment negation
  if pattern:find("!") then
    local neg = {}
    local norm_segs = {}
    local idx = 0
    for seg in (pattern .. "/"):gmatch("([^/]*)/") do
      idx = idx + 1
      if seg:sub(1,1) == "!" then
        neg[idx] = seg:sub(2)
        norm_segs[#norm_segs + 1] = "*"
      else
        norm_segs[#norm_segs + 1] = seg
      end
    end
    if not _path_pattern_matches(table.concat(norm_segs, "/"), path) then return false end
    local path_segs = {}
    for seg in (path .. "/"):gmatch("([^/]*)/") do path_segs[#path_segs + 1] = seg end
    for i, neg_val in pairs(neg) do
      if path_segs[i] == neg_val then return false end
    end
    return true
  end
  local lp = pattern:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")
  lp = lp:gsub("%*%*", "\0")
  lp = lp:gsub("%*", "[^/]+")
  lp = lp:gsub("\0", ".*")
  return path:match("^" .. lp .. "$") ~= nil
end

-- Build a full BFS-ready cache snapshot from ctx: copies _state._cache,
-- time axes (__time/<axis>), and scheduler state (__sched/<name>/...).
-- Must match the encoding used by search.lua clone_cache.
local function make_search_cache(ctx)
  local search_mod = require("runtime.search")
  return search_mod.clone_cache(ctx.state, ctx.scheduler, ctx.game)
end

-- Polymorphic length: handles List/UList/Set sequences via #v, and
-- UMap/relation adjacency hash-style tables via a pairs() fallback.
-- Shared by `size` (canonical) and its aliases (`count`, `list-size`,
-- `ulist-size`, `map-size`) so the five names always agree.
local function size_impl(args, ctx)
  local v = eval_expr(args[1], ctx)
  if type(v) ~= "table" then return 0 end
  local n = #v
  if n > 0 then return n end
  local count = 0
  for _ in pairs(v) do count = count + 1 end
  return count
end

--- Built-in functions.
local BUILTINS = {
  ["path-list"] = function(args, ctx)
    local family = eval_expr(args[1], ctx)
    if type(family) == "string" then
      return ctx.state:path_list(family)
    end
    return {}
  end,
  -- range n            → [0, 1, ..., n-1]
  -- range lo hi        → [lo, lo+1, ..., hi-1]
  -- range lo hi step   → step ≠ 0; direction follows the sign of step
  -- Cap at 10000 elements to match the engine's while-loop safety limit.
  ["range"] = function(args, ctx)
    local n = #args
    if n < 1 or n > 3 then
      error("range: expected 1..3 arguments, got " .. n)
    end
    local lo, hi, step
    if n == 1 then
      lo, hi, step = 0, eval_expr(args[1], ctx), 1
    elseif n == 2 then
      lo, hi, step = eval_expr(args[1], ctx), eval_expr(args[2], ctx), 1
    else
      lo   = eval_expr(args[1], ctx)
      hi   = eval_expr(args[2], ctx)
      step = eval_expr(args[3], ctx)
    end
    if type(lo) ~= "number" or lo ~= math.floor(lo) then
      error("range: lo must be an integer, got " .. tostring(lo))
    end
    if type(hi) ~= "number" or hi ~= math.floor(hi) then
      error("range: hi must be an integer, got " .. tostring(hi))
    end
    if type(step) ~= "number" or step ~= math.floor(step) then
      error("range: step must be an integer, got " .. tostring(step))
    end
    if step == 0 then error("range: step must not be zero") end
    local out = {}
    local limit = 10000
    local i = lo
    if step > 0 then
      while i < hi do
        out[#out + 1] = i
        if #out > limit then
          error("range: result exceeds 10000-element safety limit")
        end
        i = i + step
      end
    else
      while i > hi do
        out[#out + 1] = i
        if #out > limit then
          error("range: result exceeds 10000-element safety limit")
        end
        i = i + step
      end
    end
    return out
  end,
  ["min"] = function(args, ctx)
    local a = eval_expr(args[1], ctx)
    local b = eval_expr(args[2], ctx)
    return math.min(a or 0, b or 0)
  end,
  ["max"] = function(args, ctx)
    local a = eval_expr(args[1], ctx)
    local b = eval_expr(args[2], ctx)
    return math.max(a or 0, b or 0)
  end,
  ["count-where"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local pred = eval_expr(args[2], ctx)
    if type(list) ~= "table" then return 0 end
    local count = 0
    for _, v in ipairs(list) do
      if call_lambda(pred, {v}, ctx) then count = count + 1 end
    end
    return count
  end,
  ["any?"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local pred = eval_expr(args[2], ctx)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do
      if call_lambda(pred, {v}, ctx) then return true end
    end
    return false
  end,
  ["all?"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local pred = eval_expr(args[2], ctx)
    if type(list) ~= "table" then return true end
    for _, v in ipairs(list) do
      if not call_lambda(pred, {v}, ctx) then return false end
    end
    return true
  end,
  ["random-int"] = function(args, ctx)
    local lo = eval_expr(args[1], ctx) or 0
    local hi = eval_expr(args[2], ctx) or 0
    -- Search engine injection takes priority (BFS branching)
    if ctx.game and ctx.game._random_inject then
      local v = ctx.game._random_inject(lo, hi)
      if v ~= nil then return v end
    end
    return ctx.rng:int(lo, hi)
  end,
  ["random-bool"] = function(args, ctx)
    local p = (args[1] and eval_expr(args[1], ctx)) or 0.5
    -- Search engine injection: treat as random-int 0 1 (0=false, 1=true)
    if ctx.game and ctx.game._random_inject then
      local v = ctx.game._random_inject(0, 1)
      if v ~= nil then return v == 1 end
    end
    return ctx.rng:bool(p)
  end,
  ["random-enum"] = function(args, ctx)
    -- arg[1] is the enum type name (bare ident evaluates to its string name)
    local type_name = eval_expr(args[1], ctx)
    -- Look up enum values from the compiled schema (use pre-built index when available)
    local values = nil
    local schema = ctx.game and ctx.game.schema
    if schema then
      local idx_map = schema._type_index
      if idx_map then
        local t = idx_map[type_name]
        if t then
          values = t.values or (t.type_desc and t.type_desc.values)
        end
      elseif schema.types then
        for _, t in ipairs(schema.types) do
          if t.name == type_name and (t.kind == "enum" or t.kind == "alias") then
            values = t.values or (t.type_desc and t.type_desc.values)
            break
          end
        end
      end
    end
    if not values or #values == 0 then return nil end
    -- Search engine injection: index 0..#values-1 maps to enum values
    if ctx.game and ctx.game._random_inject then
      local v = ctx.game._random_inject(0, #values - 1)
      if v ~= nil then return values[v + 1] end
    end
    return ctx.rng:enum(values)
  end,
  ["random-choice"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    if type(list) ~= "table" or #list == 0 then return nil end
    if ctx.game and ctx.game._random_inject then
      local v = ctx.game._random_inject(0, #list - 1)
      if v ~= nil then return list[v + 1] end
    end
    return ctx.rng:choice(list)
  end,
  ["random-weighted"] = function(args, ctx)
    local weights = eval_expr(args[1], ctx)
    local list    = eval_expr(args[2], ctx)
    if type(list) ~= "table" or #list == 0 then return nil end
    -- Search engine injection: treat as uniform random-choice (weights ignored in BFS)
    if ctx.game and ctx.game._random_inject then
      local v = ctx.game._random_inject(0, #list - 1)
      if v ~= nil then return list[v + 1] end
    end
    return ctx.rng:weighted(weights, list)
  end,
  ["tostring"] = function(args, ctx)
    return tostring(eval_expr(args[1], ctx))
  end,
  -- ── Debug output (dev-mode only; suppressed when ctx.game.production is true) ─
  ["print"] = function(args, ctx)
    if ctx.game and ctx.game.production then return nil end
    local parts = {}
    for _, arg in ipairs(args) do
      local v = eval_expr(arg, ctx)
      parts[#parts + 1] = (v == nil) and "nil" or tostring(v)
    end
    local msg = table.concat(parts, " ") .. "\n"
    local sink = ctx.game and ctx.game._print_sink
    if sink then sink(msg) else io.stderr:write(msg) end
    return nil
  end,
  ["log"] = function(args, ctx)
    if ctx.game and ctx.game.production then return nil end
    local level_val = eval_expr(args[1], ctx)
    local level = tostring(level_val or "debug"):upper()
    local parts = {}
    for i = 2, #args do
      local v = eval_expr(args[i], ctx)
      parts[#parts + 1] = (v == nil) and "nil" or tostring(v)
    end
    local msg_text = table.concat(parts, " ")
    local pos = ctx.call_pos
    local loc
    if pos and pos.file and pos.file ~= "?" then
      loc = pos.file .. ":" .. tostring(pos.line)
    else
      loc = "?"
    end
    local fn = ctx.fn_name or "?"
    local msg = "[" .. level .. "] " .. loc .. " (" .. fn .. "): " .. msg_text .. "\n"
    local sink = ctx.game and ctx.game._print_sink
    if sink then sink(msg) else io.stderr:write(msg) end
    return nil
  end,
  -- ── String / numeric stdlib ──────────────────────────────────────────────────
  ["str"] = function(args, ctx)
    -- Concatenate any number of arguments into a String (superficial).
    -- nil renders as "" (suppressed); false/true render as "false"/"true"
    -- so Bool state values survive into narration unchanged.
    local parts = {}
    for _, arg in ipairs(args) do
      local v = eval_expr(arg, ctx)
      parts[#parts + 1] = (v == nil) and "" or tostring(v)
    end
    return table.concat(parts)
  end,
  ["abs"] = function(args, ctx)
    local v = eval_expr(args[1], ctx) or 0
    return math.abs(v)
  end,
  ["clamp"] = function(args, ctx)
    local v  = eval_expr(args[1], ctx) or 0
    local lo = eval_expr(args[2], ctx) or 0
    local hi = eval_expr(args[3], ctx) or 0
    return math.max(lo, math.min(hi, v))
  end,
  ["int-to-str"] = function(args, ctx)
    local v = eval_expr(args[1], ctx)
    return tostring(v ~= nil and v or "")
  end,
  ["str-to-int"] = function(args, ctx)
    local s = eval_expr(args[1], ctx)
    local n = tonumber(s)
    if n then return math.floor(n) end
    return nil  -- Option(Int) — nil means "not a valid integer"
  end,
  -- int-div a b: floor division (integer quotient); floor/ceil: rounding builtins
  -- mod a b: floor-division remainder (Python sign convention: sign matches divisor)
  ["int-div"] = function(args, ctx)
    local a = eval_expr(args[1], ctx) or 0
    local b = eval_expr(args[2], ctx) or 1
    return math.floor(a / b)
  end,
  ["floor"] = function(args, ctx)
    local n = eval_expr(args[1], ctx) or 0
    return math.floor(n)
  end,
  ["ceil"] = function(args, ctx)
    local n = eval_expr(args[1], ctx) or 0
    return math.ceil(n)
  end,
  ["mod"] = function(args, ctx)
    local a = eval_expr(args[1], ctx) or 0
    local b = eval_expr(args[2], ctx) or 1
    return a % b  -- Lua % is floor-division remainder (same sign convention as Python)
  end,
  -- ── Collection stdlib ────────────────────────────────────────────────────────
  -- size is the canonical polymorphic length. count, list-size,
  -- ulist-size, and map-size are aliases (see size_impl above).
  ["size"]       = size_impl,
  ["count"]      = size_impl,
  ["empty?"] = function(args, ctx)
    local v = eval_expr(args[1], ctx)
    if type(v) ~= "table" then return true end
    if #v > 0 then return false end
    -- Also check map-style entries
    for _ in pairs(v) do return false end
    return true
  end,
  ["contains?"] = function(args, ctx)
    local collection = eval_expr(args[1], ctx)
    local item       = eval_expr(args[2], ctx)
    if type(collection) ~= "table" then return false end
    for _, v in ipairs(collection) do
      if v == item then return true end
    end
    if collection[item] then return true end
    return false
  end,
  ["not-in?"] = function(args, ctx)
    local item       = eval_expr(args[1], ctx)
    local collection = eval_expr(args[2], ctx)
    if type(collection) ~= "table" then return true end
    for _, v in ipairs(collection) do
      if v == item then return false end
    end
    if collection[item] then return false end
    return true
  end,
  ["union"] = function(args, ctx)
    local a = eval_expr(args[1], ctx)
    local b = eval_expr(args[2], ctx)
    if type(a) ~= "table" then a = {} end
    if type(b) ~= "table" then b = {} end
    -- Sets are lists; union = deduplicated merge
    local seen = {}
    local result = {}
    for _, v in ipairs(a) do
      if not seen[tostring(v)] then seen[tostring(v)] = true; result[#result+1] = v end
    end
    for _, v in ipairs(b) do
      if not seen[tostring(v)] then seen[tostring(v)] = true; result[#result+1] = v end
    end
    return result
  end,
  ["intersect"] = function(args, ctx)
    local a = eval_expr(args[1], ctx)
    local b = eval_expr(args[2], ctx)
    if type(a) ~= "table" then return {} end
    if type(b) ~= "table" then return {} end
    local b_set = {}
    for _, v in ipairs(b) do b_set[tostring(v)] = v end
    local result = {}
    for _, v in ipairs(a) do
      if b_set[tostring(v)] ~= nil then result[#result+1] = v end
    end
    return result
  end,
  ["difference"] = function(args, ctx)
    local a = eval_expr(args[1], ctx)
    local b = eval_expr(args[2], ctx)
    if type(a) ~= "table" then return {} end
    if type(b) ~= "table" then return a end
    local b_set = {}
    for _, v in ipairs(b) do b_set[tostring(v)] = true end
    local result = {}
    for _, v in ipairs(a) do
      if not b_set[tostring(v)] then result[#result+1] = v end
    end
    return result
  end,
  ["list-get"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local idx  = eval_expr(args[2], ctx) or 1
    if type(list) ~= "table" then return nil end
    if idx < 0 then idx = #list + idx + 1 end
    return list[idx]  -- nil if out of bounds → Option(T)
  end,
  ["list-size"]  = size_impl,  -- alias for size
  ["map-get"] = function(args, ctx)
    local map = eval_expr(args[1], ctx)
    local key = eval_expr(args[2], ctx)
    if type(map) ~= "table" then return nil end
    return map[key]
  end,
  ["map-size"]   = size_impl,  -- alias for size
  ["map-keys"] = function(args, ctx)
    local map = eval_expr(args[1], ctx)
    if type(map) ~= "table" then return {} end
    local keys = {}
    for k in pairs(map) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
  end,
  ["map-values"] = function(args, ctx)
    local map = eval_expr(args[1], ctx)
    if type(map) ~= "table" then return {} end
    -- Sort by key so values align with map-keys output index-for-index.
    local keys = {}
    for k in pairs(map) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local vals = {}
    for _, k in ipairs(keys) do vals[#vals + 1] = map[k] end
    return vals
  end,
  ["map-contains-key?"] = function(args, ctx)
    local map = eval_expr(args[1], ctx)
    local key = eval_expr(args[2], ctx)
    if type(map) ~= "table" then return false end
    return map[key] ~= nil
  end,
  ["map-merge"] = function(args, ctx)
    local a = eval_expr(args[1], ctx)
    local b = eval_expr(args[2], ctx)
    local result = {}
    if type(a) == "table" then for k, v in pairs(a) do result[k] = v end end
    if type(b) == "table" then for k, v in pairs(b) do result[k] = v end end
    return result
  end,
  -- map-set / map-delete: pure versions (return new map, do not mutate state)
  ["map-set"] = function(args, ctx)
    local map = eval_expr(args[1], ctx)
    local key = eval_expr(args[2], ctx)
    local val = eval_expr(args[3], ctx)
    local result = {}
    if type(map) == "table" then for k, v in pairs(map) do result[k] = v end end
    result[key] = val
    return result
  end,
  ["map-delete"] = function(args, ctx)
    local map = eval_expr(args[1], ctx)
    local key = eval_expr(args[2], ctx)
    if type(map) ~= "table" then return {} end
    local result = {}
    for k, v in pairs(map) do if k ~= key then result[k] = v end end
    return result
  end,
  -- ── UList pure builtins ─────────────────────────────────────────────────────
  -- UList(T) is an unbounded superficial list. Stored as a Lua sequence table.
  -- Mutations use push!/pop!/clear!/set![idx].  These builtins are pure
  -- (return new tables; do not touch the state store).
  ["ulist-size"] = size_impl,  -- alias for size
  ["ulist-get"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local idx  = eval_expr(args[2], ctx) or 1
    if type(list) ~= "table" then return nil end
    if idx < 0 then idx = #list + idx + 1 end
    return list[idx]
  end,
  ["ulist-first"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    if type(list) ~= "table" or #list == 0 then return nil end
    return list[1]
  end,
  ["ulist-last"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    if type(list) ~= "table" or #list == 0 then return nil end
    return list[#list]
  end,
  ["ulist-index-of"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local val  = eval_expr(args[2], ctx)
    if type(list) ~= "table" then return nil end
    for i, v in ipairs(list) do if v == val then return i end end
    return nil
  end,
  ["ulist-contains?"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local val  = eval_expr(args[2], ctx)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do if v == val then return true end end
    return false
  end,
  ["ulist-append"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local val  = eval_expr(args[2], ctx)
    local result = {}
    if type(list) == "table" then for _, v in ipairs(list) do result[#result+1] = v end end
    result[#result+1] = val
    return result
  end,
  ["ulist-prepend"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local val  = eval_expr(args[2], ctx)
    local result = { val }
    if type(list) == "table" then for _, v in ipairs(list) do result[#result+1] = v end end
    return result
  end,
  ["ulist-remove-at"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local idx  = eval_expr(args[2], ctx) or 1
    if type(list) ~= "table" then return {} end
    local n = #list
    if idx < 0 then idx = n + idx + 1 end
    local result = {}
    for i, v in ipairs(list) do if i ~= idx then result[#result+1] = v end end
    return result
  end,
  ["ulist-remove"] = function(args, ctx)
    local list  = eval_expr(args[1], ctx)
    local val   = eval_expr(args[2], ctx)
    if type(list) ~= "table" then return {} end
    local removed = false
    local result  = {}
    for _, v in ipairs(list) do
      if not removed and v == val then removed = true
      else result[#result+1] = v end
    end
    return result
  end,
  ["ulist-concat"] = function(args, ctx)
    local a = eval_expr(args[1], ctx)
    local b = eval_expr(args[2], ctx)
    local result = {}
    if type(a) == "table" then for _, v in ipairs(a) do result[#result+1] = v end end
    if type(b) == "table" then for _, v in ipairs(b) do result[#result+1] = v end end
    return result
  end,
  ["ulist-slice"] = function(args, ctx)
    local list  = eval_expr(args[1], ctx)
    local from  = eval_expr(args[2], ctx) or 1
    local to    = eval_expr(args[3], ctx)
    if type(list) ~= "table" then return {} end
    local n = #list
    if from < 0 then from = n + from + 1 end
    if not to then to = n elseif to < 0 then to = n + to + 1 end
    local result = {}
    for i = from, to do if list[i] ~= nil then result[#result+1] = list[i] end end
    return result
  end,
  ["ulist-reverse"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    if type(list) ~= "table" then return {} end
    local result = {}
    for i = #list, 1, -1 do result[#result+1] = list[i] end
    return result
  end,
  ["ulist-map"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local fn   = eval_expr(args[2], ctx)
    if type(list) ~= "table" then return {} end
    local result = {}
    for _, v in ipairs(list) do
      result[#result+1] = call_lambda(fn, {v}, ctx)
    end
    return result
  end,
  ["ulist-filter"] = function(args, ctx)
    local list = eval_expr(args[1], ctx)
    local fn   = eval_expr(args[2], ctx)
    if type(list) ~= "table" then return {} end
    local result = {}
    for _, v in ipairs(list) do
      if call_lambda(fn, {v}, ctx) then result[#result+1] = v end
    end
    return result
  end,
  -- ── Relation query builtins ──────────────────────────────────────────────────
  -- Relation name is the first arg, passed as a bare IDENT (0-arg fn_call returns its name).
  -- e.g. `adjacent? exits 'village` → rel_name="exits", source="village"

  ["adjacent?"] = function(args, ctx)
    local query_mod = require("runtime.query")
    local rel_name  = eval_expr(args[1], ctx)   -- bare ident → string
    local source    = eval_expr(args[2], ctx)
    if type(rel_name) ~= "string" or not ctx.game then return {} end
    local rel = ctx.game.relations and ctx.game.relations[rel_name]
    return query_mod.adjacent(effective_rel(rel, rel_name, ctx.state and ctx.state._cache), source)
  end,

  ["reachable?"] = function(args, ctx)
    local query_mod = require("runtime.query")
    local rel_name  = eval_expr(args[1], ctx)
    local source    = eval_expr(args[2], ctx)
    local target    = eval_expr(args[3], ctx)
    local max_hops  = nil
    for i = 4, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG and a.name == "max-hops" then
        local v = eval_expr(a.value, ctx); if type(v) == "number" then max_hops = v end
      end
    end
    if type(rel_name) ~= "string" or not ctx.game then return false end
    local rel = ctx.game.relations and ctx.game.relations[rel_name]
    return query_mod.reachable(effective_rel(rel, rel_name, ctx.state and ctx.state._cache), source, target, max_hops)
  end,

  ["shortest-path"] = function(args, ctx)
    local query_mod = require("runtime.query")
    local rel_name  = eval_expr(args[1], ctx)
    local source    = eval_expr(args[2], ctx)
    local target    = eval_expr(args[3], ctx)
    if type(rel_name) ~= "string" or not ctx.game then return nil end
    local rel = ctx.game.relations and ctx.game.relations[rel_name]
    return query_mod.shortest_path(effective_rel(rel, rel_name, ctx.state and ctx.state._cache), source, target)
  end,

  ["reachable-set"] = function(args, ctx)
    local query_mod = require("runtime.query")
    local rel_name  = eval_expr(args[1], ctx)
    local source    = eval_expr(args[2], ctx)
    local max_hops  = nil
    for i = 3, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG and a.name == "max-hops" then
        local v = eval_expr(a.value, ctx); if type(v) == "number" then max_hops = v end
      end
    end
    if type(rel_name) ~= "string" or not ctx.game then return {} end
    local rel = ctx.game.relations and ctx.game.relations[rel_name]
    return query_mod.reachable_set(effective_rel(rel, rel_name, ctx.state and ctx.state._cache), source, max_hops)
  end,

  ["inverse-adjacent?"] = function(args, ctx)
    local query_mod = require("runtime.query")
    local rel_name  = eval_expr(args[1], ctx)
    local source    = eval_expr(args[2], ctx)
    if type(rel_name) ~= "string" or not ctx.game then return {} end
    local rel = ctx.game.relations and ctx.game.relations[rel_name]
    return query_mod.inverse_adjacent(effective_rel(rel, rel_name, ctx.state and ctx.state._cache), source)
  end,

  ["path-exists?"] = function(args, ctx)
    local arg = args[1]
    local path
    if arg and (arg.kind == K.PATH_EXPR or arg.kind == K.INTERP_PATH) then
      path = eval_path(arg, ctx)
    else
      path = eval_expr(arg, ctx)
    end
    if type(path) ~= "string" then return false end
    return ctx.state:path_exists(path) == true
  end,
  -- ── Historical log queries ───────────────────────────────────────────────
  -- query-at path [time: value]  → value at given time bound (or current)
  ["query-at"] = function(args, ctx)
    if not ctx.state or not ctx.state._log then return nil end
    local arg = args[1]
    local path
    if arg and (arg.kind == K.PATH_EXPR or arg.kind == K.INTERP_PATH) then
      path = eval_path(arg, ctx)
    else
      path = eval_expr(arg, ctx)
    end
    if type(path) ~= "string" then return nil end
    local time_val = nil
    for i = 2, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG and a.name == "time" then
        time_val = eval_expr(a.value, ctx)
      end
    end
    return ctx.state._log:query_at(path, time_val)
  end,
  -- query-history path → [{time, old, new}, ...]  (all recorded changes)
  -- path may be a pattern (player/*, player/(health|mana), player/!inventory) — returns union.
  ["query-history"] = function(args, ctx)
    if not ctx.state or not ctx.state._log then return {} end
    local arg = args[1]
    local path
    if arg and (arg.kind == K.PATH_EXPR or arg.kind == K.INTERP_PATH) then
      path = eval_path(arg, ctx)
    else
      path = eval_expr(arg, ctx)
    end
    if type(path) ~= "string" then return {} end
    local log = ctx.state._log
    if path:find("%*") or path:find("%(") or path:find("!") then
      local result = {}
      for _, e in ipairs(log._entries or {}) do
        if e.path and _path_pattern_matches(path, e.path) then
          result[#result + 1] = { time = e.time, old = e.old, new = e.new, path = e.path }
        end
      end
      return result
    end
    return log:query_history(path, nil, nil)
  end,
  -- query-changes path [last-n: N] → [{time, old, new}, ...]  (most recent N)
  -- path may be a pattern — returns union of matches, most recent last_n total.
  ["query-changes"] = function(args, ctx)
    if not ctx.state or not ctx.state._log then return {} end
    local arg = args[1]
    local path
    if arg and (arg.kind == K.PATH_EXPR or arg.kind == K.INTERP_PATH) then
      path = eval_path(arg, ctx)
    else
      path = eval_expr(arg, ctx)
    end
    if type(path) ~= "string" then return {} end
    local last_n = nil
    for i = 2, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG and a.name == "last-n" then
        last_n = eval_expr(a.value, ctx)
      end
    end
    local log = ctx.state._log
    if path:find("%*") or path:find("%(") or path:find("!") then
      local all = {}
      for _, e in ipairs(log._entries or {}) do
        if e.path and _path_pattern_matches(path, e.path) then
          all[#all + 1] = { time = e.time, old = e.old, new = e.new, path = e.path }
        end
      end
      local start = math.max(1, #all - (last_n or #all) + 1)
      local result = {}
      for i = start, #all do result[#result + 1] = all[i] end
      return result
    end
    return log:query_changes(path, last_n)
  end,

  ["can-reach?"] = function(args, ctx)
    if not ctx.game then return false end
    if ctx._in_bfs then return true end   -- optimistic during outer BFS: allow exploration

    local search_mod = require("runtime.search")
    local log_mod    = require("runtime.log")
    local state_mod  = require("runtime.state")

    local cond_expr = args[1]
    local depth     = 20
    local budget    = nil
    local strategy  = "bfs"

    -- Check for depth:, budget:, strategy: named args
    for i = 2, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG then
        if a.name == "depth" then
          local d = eval_expr(a.value, ctx)
          if type(d) == "number" then depth = d end
        elseif a.name == "budget" then
          local b = eval_expr(a.value, ctx)
          if type(b) == "number" then budget = b end
        elseif a.name == "strategy" then
          local s = eval_expr(a.value, ctx)
          if type(s) == "string" then
            -- Normalise long-form aliases to internal identifiers
            if s == "breadth-first" then s = "bfs"
            elseif s == "depth-first" then s = "dfs" end
            strategy = s
          end
        end
      end
    end

    local cache = make_search_cache(ctx)

    -- Scene stack: from ctx if available, otherwise use entry scene
    local stack = ctx.scene_stack
    if not stack then
      local entry = ctx.game.schema
        and ctx.game.schema.engine_config
        and ctx.game.schema.engine_config["entry-scene"]
      stack = entry and { entry } or {}
    end

    -- Condition function: evaluate cond_expr in a snapshot state
    local function condition_fn(snap_cache)
      local l          = log_mod.new()
      local fake_state = state_mod.new(ctx.game.schema or {}, l)
      for k, v in pairs(snap_cache) do
        if not k:match("^__time/") then fake_state._cache[k] = v end
      end
      local fake_ctx = {
        state    = fake_state,
        fns      = ctx.fns,
        vars     = {},
        fn_name  = "can-reach?",
        signal   = nil,
        retval   = nil,
        game     = ctx.game,
      }
      local ok, result = pcall(eval_expr, cond_expr, fake_ctx)
      return ok and result
    end

    return search_mod.can_reach(ctx.game, cache, stack, condition_fn, depth, budget, strategy)
  end,

  ["find-path"] = function(args, ctx)
    if not ctx.game then return nil end
    if ctx._in_bfs then return nil end    -- guard: no nested BFS during outer BFS

    local search_mod = require("runtime.search")
    local log_mod    = require("runtime.log")
    local state_mod  = require("runtime.state")

    local cond_expr = args[1]
    local depth     = 20
    local budget    = nil
    local strategy  = "bfs"

    for i = 2, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG then
        if a.name == "depth" then
          local d = eval_expr(a.value, ctx)
          if type(d) == "number" then depth = d end
        elseif a.name == "budget" then
          local b = eval_expr(a.value, ctx)
          if type(b) == "number" then budget = b end
        elseif a.name == "strategy" then
          local s = eval_expr(a.value, ctx)
          if type(s) == "string" then
            -- Normalise long-form aliases to internal identifiers
            if s == "breadth-first" then s = "bfs"
            elseif s == "depth-first" then s = "dfs" end
            strategy = s
          end
        end
      end
    end

    local cache = make_search_cache(ctx)

    local stack = ctx.scene_stack
    if not stack then
      local entry = ctx.game.schema
        and ctx.game.schema.engine_config
        and ctx.game.schema.engine_config["entry-scene"]
      stack = entry and { entry } or {}
    end

    local function condition_fn(snap_cache)
      local l          = log_mod.new()
      local fake_state = state_mod.new(ctx.game.schema or {}, l)
      for k, v in pairs(snap_cache) do
        if not k:match("^__time/") then fake_state._cache[k] = v end
      end
      local fake_ctx = {
        state    = fake_state,
        fns      = ctx.fns,
        vars     = {},
        fn_name  = "find-path",
        signal   = nil,
        retval   = nil,
        game     = ctx.game,
      }
      local ok, result = pcall(eval_expr, cond_expr, fake_ctx)
      return ok and result
    end

    -- find_path returns a list of {scene, label, index} steps or nil
    local path = search_mod.find_path(ctx.game, cache, stack, condition_fn, depth, budget, strategy)
    if not path then return nil end
    -- Convert to a list of label strings for easy consumption
    local labels = {}
    for _, step in ipairs(path) do labels[#labels + 1] = step.label end
    return labels
  end,

  -- verify-always expr [depth: N] → Bool (true if expr holds in ALL reachable states)
  ["verify-always"] = function(args, ctx)
    if not ctx.game then return true end
    if ctx._in_bfs then return true end   -- guard: skip nested BFS during outer BFS
    local search_mod = require("runtime.search")
    local log_mod    = require("runtime.log")
    local state_mod  = require("runtime.state")
    local cond_expr  = args[1]
    local depth      = 20
    for i = 2, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG and a.name == "depth" then
        local d = eval_expr(a.value, ctx); if type(d) == "number" then depth = d end
      end
    end
    local cache = make_search_cache(ctx)
    local stack = ctx.scene_stack or (function()
      local e = ctx.game.schema and ctx.game.schema.engine_config and ctx.game.schema.engine_config["entry-scene"]
      return e and {e} or {}
    end)()
    -- "holds always" = NOT (can-reach? NOT cond)
    local function negated_fn(snap)
      local l = log_mod.new()
      local fs = state_mod.new(ctx.game.schema or {}, l)
      for k, v in pairs(snap) do if not k:match("^__time/") then fs._cache[k] = v end end
      local fc = { state=fs, fns=ctx.fns, vars={}, fn_name="verify-always", signal=nil, retval=nil, game=ctx.game }
      local ok, result = pcall(eval_expr, cond_expr, fc)
      return ok and not result  -- negated: looking for states where cond is FALSE
    end
    return not search_mod.can_reach(ctx.game, cache, stack, negated_fn, depth)
  end,

  -- probability expr [depth: N] → Float (probability that expr holds at depth N)
  ["probability"] = function(args, ctx)
    if not ctx.game then return 0.0 end
    if ctx._in_bfs then return 0.0 end    -- guard: no nested BFS during outer BFS
    local search_mod = require("runtime.search")
    local log_mod    = require("runtime.log")
    local state_mod  = require("runtime.state")
    local cond_expr  = args[1]
    local depth      = 10
    local threshold  = 0.001
    for i = 2, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG then
        local d = eval_expr(a.value, ctx)
        if a.name == "depth"     and type(d) == "number" then depth = d end
        if a.name == "threshold" and type(d) == "number" then threshold = d end
      end
    end
    local cache = make_search_cache(ctx)
    local stack = ctx.scene_stack or (function()
      local e = ctx.game.schema and ctx.game.schema.engine_config and ctx.game.schema.engine_config["entry-scene"]
      return e and {e} or {}
    end)()
    local function condition_fn(snap)
      local l = log_mod.new()
      local fs = state_mod.new(ctx.game.schema or {}, l)
      for k, v in pairs(snap) do if not k:match("^__time/") then fs._cache[k] = v end end
      local fc = { state=fs, fns=ctx.fns, vars={}, fn_name="probability", signal=nil, retval=nil, game=ctx.game }
      local ok, result = pcall(eval_expr, cond_expr, fc)
      return ok and result
    end
    return search_mod.probability(ctx.game, cache, stack, condition_fn, depth, threshold)
  end,

  -- optimal-path expr [by: cost-expr] [depth: N] → list of choice labels or nil
  ["optimal-path"] = function(args, ctx)
    if not ctx.game then return nil end
    if ctx._in_bfs then return nil end    -- guard: no nested BFS during outer BFS
    local search_mod = require("runtime.search")
    local log_mod    = require("runtime.log")
    local state_mod  = require("runtime.state")
    local cond_expr  = args[1]
    local depth      = 20
    local by_expr    = nil  -- optional cost expression
    for i = 2, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG then
        local val = eval_expr(a.value, ctx)
        if a.name == "depth" and type(val) == "number" then depth = val end
        if a.name == "by"    then by_expr = a.value end
      end
    end
    local cache = make_search_cache(ctx)
    local stack = ctx.scene_stack or (function()
      local e = ctx.game.schema and ctx.game.schema.engine_config and ctx.game.schema.engine_config["entry-scene"]
      return e and {e} or {}
    end)()
    local function condition_fn(snap)
      local l = log_mod.new()
      local fs = state_mod.new(ctx.game.schema or {}, l)
      for k, v in pairs(snap) do if not k:match("^__time/") then fs._cache[k] = v end end
      local fc = { state=fs, fns=ctx.fns, vars={}, fn_name="optimal-path", signal=nil, retval=nil, game=ctx.game }
      local ok, result = pcall(eval_expr, cond_expr, fc)
      return ok and result
    end
    local cost_fn = nil
    if by_expr then
      cost_fn = function(snap)
        local l = log_mod.new()
        local fs = state_mod.new(ctx.game.schema or {}, l)
        for k, v in pairs(snap) do if not k:match("^__time/") then fs._cache[k] = v end end
        local fc = {
          state=fs, fns=ctx.fns, vars={}, fn_name="optimal-path-cost",
          signal=nil, retval=nil, game=ctx.game,
        }
        local ok, result = pcall(eval_expr, by_expr, fc)
        return (ok and type(result) == "number") and result or 1
      end
    end
    local path = search_mod.optimal_path(ctx.game, cache, stack, condition_fn, depth, cost_fn)
    if not path then return nil end
    local labels = {}
    for _, step in ipairs(path) do labels[#labels+1] = step.label end
    return labels
  end,

  -- find-counterexample expr [depth: N] → frozen GameState or nil
  ["find-counterexample"] = function(args, ctx)
    if not ctx.game then return nil end
    if ctx._in_bfs then return nil end    -- guard: no nested BFS during outer BFS
    local search_mod = require("runtime.search")
    local log_mod    = require("runtime.log")
    local state_mod  = require("runtime.state")
    local cond_expr  = args[1]
    local depth      = 20
    for i = 2, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG and a.name == "depth" then
        local d = eval_expr(a.value, ctx); if type(d) == "number" then depth = d end
      end
    end
    local cache = make_search_cache(ctx)
    local stack = ctx.scene_stack or (function()
      local e = ctx.game.schema and ctx.game.schema.engine_config and ctx.game.schema.engine_config["entry-scene"]
      return e and {e} or {}
    end)()
    -- BFS: find first state where cond is false
    local found_snap = nil
    local function violation_fn(snap)
      local l = log_mod.new()
      local fs = state_mod.new(ctx.game.schema or {}, l)
      for k, v in pairs(snap) do if not k:match("^__time/") then fs._cache[k] = v end end
      local fc = {
        state=fs, fns=ctx.fns, vars={}, fn_name="find-counterexample",
        signal=nil, retval=nil, game=ctx.game,
      }
      local ok, result = pcall(eval_expr, cond_expr, fc)
      if ok and not result then
        found_snap = snap
        return true  -- signal found
      end
      return false
    end
    search_mod.can_reach(ctx.game, cache, stack, violation_fn, depth)
    if not found_snap then return nil end
    return {
      _cache = found_snap,
      _time  = {},
      get    = function(self, path) return self._cache[path] end,
      path_exists = function(self, path) return self._cache[path] ~= nil end,
    }
  end,

  -- ── Tile grid builtins ────────────────────────────────────────────────────
  -- Grid name is always the first argument, passed as a bare IDENT (0-arg call
  -- returns the name as a string — same pattern as relation query builtins).

  --- grid-get grid-name x y → cell value (or nil if OOB)
  --- Checks the state cache for grid overrides (written by grid-set!) first,
  --- so save/load and BFS correctly see mutated cell values.
  ["grid-get"] = function(args, ctx)
    local tg = require("runtime.tilegrid")
    local name = eval_expr(args[1], ctx)
    local x    = eval_expr(args[2], ctx)
    local y    = eval_expr(args[3], ctx)
    local g = ctx.grids and ctx.grids[name]
    if not g then return nil end
    -- Cache override takes precedence over the default cells array.
    if ctx.state then
      local cache_key = string.format("__grid/%s/%d,%d", tostring(name), x, y)
      local cv = ctx.state._cache[cache_key]
      if cv ~= nil then return cv end
    end
    return tg.get(g.cells, g.width, g.height, x, y)
  end,

  --- grid-set! grid-name x y value → nil
  --- Writes to both the cells array (for immediate in-session access by tilegrid
  --- algorithms) and to the state cache (for logging, save/load, and BFS).
  ["grid-set!"] = function(args, ctx)
    local tg = require("runtime.tilegrid")
    local name  = eval_expr(args[1], ctx)
    local x     = eval_expr(args[2], ctx)
    local y     = eval_expr(args[3], ctx)
    local value = eval_expr(args[4], ctx)
    local g = ctx.grids and ctx.grids[name]
    if not g then return nil end
    -- Update cells array immediately (used by visible-from?, path-to, etc.).
    tg.set(g.cells, g.width, g.height, x, y, value)
    -- Persist to state cache so the change is logged, saved, and BFS-visible.
    if ctx.state and tg.in_bounds(g.width, g.height, x, y) then
      local cache_key = string.format("__grid/%s/%d,%d", tostring(name), x, y)
      ctx.state:set(cache_key, value, ctx.fn_name)
    end
    return nil
  end,

  --- grid-width grid-name → integer width (or 0 if unknown)
  ["grid-width"] = function(args, ctx)
    local name = eval_expr(args[1], ctx)
    local g = ctx.grids and ctx.grids[name]
    return g and g.width or 0
  end,

  --- grid-height grid-name → integer height (or 0 if unknown)
  ["grid-height"] = function(args, ctx)
    local name = eval_expr(args[1], ctx)
    local g = ctx.grids and ctx.grids[name]
    return g and g.height or 0
  end,

  --- within-range? grid-name x1 y1 x2 y2 [range: N] [metric: "chebyshev"|"manhattan"|"euclidean"]
  --- → Bool
  ["within-range?"] = function(args, ctx)
    local tg    = require("runtime.tilegrid")
    local _name = eval_expr(args[1], ctx)  -- grid name unused for range check
    local x1    = eval_expr(args[2], ctx)
    local y1    = eval_expr(args[3], ctx)
    local x2    = eval_expr(args[4], ctx)
    local y2    = eval_expr(args[5], ctx)
    local range  = 1
    local metric = "chebyshev"
    for i = 6, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG then
        local v = eval_expr(a.value, ctx)
        if a.name == "range"  and type(v) == "number" then range  = v end
        if a.name == "metric" and type(v) == "string" then metric = v end
      end
    end
    return tg.within_range(x1, y1, x2, y2, range, metric)
  end,

  --- visible-from? grid-name x1 y1 x2 y2 [solid: {values}]
  --- → Bool (true = unobstructed line of sight)
  ["visible-from?"] = function(args, ctx)
    local tg   = require("runtime.tilegrid")
    local name = eval_expr(args[1], ctx)
    local x1   = eval_expr(args[2], ctx)
    local y1   = eval_expr(args[3], ctx)
    local x2   = eval_expr(args[4], ctx)
    local y2   = eval_expr(args[5], ctx)
    local g = ctx.grids and ctx.grids[name]
    if not g then return false end
    local opaque_set = nil
    for i = 6, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG and a.name == "solid" then
        local v = eval_expr(a.value, ctx)
        if type(v) == "table" then
          opaque_set = {}
          for _, cell_val in ipairs(v) do opaque_set[cell_val] = true end
        end
      end
    end
    return tg.visible_from(g.cells, g.width, g.height, x1, y1, x2, y2, opaque_set)
  end,

  --- path-to grid-name x1 y1 x2 y2 [blocked: {values}] [diag: true|false]
  --- → List of {x,y} steps (excluding start, including end), or nil if unreachable
  ["path-to"] = function(args, ctx)
    local tg   = require("runtime.tilegrid")
    local name = eval_expr(args[1], ctx)
    local x1   = eval_expr(args[2], ctx)
    local y1   = eval_expr(args[3], ctx)
    local x2   = eval_expr(args[4], ctx)
    local y2   = eval_expr(args[5], ctx)
    local g = ctx.grids and ctx.grids[name]
    if not g then return nil end
    local blocked_set = nil
    local allow_diag  = true
    for i = 6, #args do
      local a = args[i]
      if a and a.kind == K.NAMED_ARG then
        local v = eval_expr(a.value, ctx)
        if a.name == "blocked" and type(v) == "table" then
          blocked_set = {}
          for _, cell_val in ipairs(v) do blocked_set[cell_val] = true end
        elseif a.name == "diag" then
          allow_diag = v and true or false
        end
      end
    end
    return tg.find_path(g.cells, g.width, g.height, x1, y1, x2, y2, blocked_set, allow_diag)
  end,

  --- occupied-by grid-name family-name x y → entity key string or nil
  ["occupied-by"] = function(args, ctx)
    local tg     = require("runtime.tilegrid")
    local _name  = eval_expr(args[1], ctx)  -- grid name (for context, unused in query)
    local family = eval_expr(args[2], ctx)
    local x      = eval_expr(args[3], ctx)
    local y      = eval_expr(args[4], ctx)
    if not ctx.state then return nil end
    return tg.occupied_by(ctx.state._cache, family, x, y)
  end,
}

--- Dispatch a function call by name.
---@param name string      function name
---@param args table       unevaluated arg nodes
---@param ctx  table       evaluation context
---@return any
call_fn = function(name, args, ctx)
  -- 0-arg fn_call nodes may actually be variable references (params, let bindings, for vars)
  if #(args or {}) == 0 then
    if name == "nil"  then return nil end  -- nil is a language literal
    if name == "pure" then return name end -- pure is a purity annotation; no-op at runtime
    if ctx.vars[name] ~= nil then
      return ctx.vars[name]
    end
    if ctx.nil_vars and ctx.nil_vars[name] then
      return nil  -- variable explicitly bound to nil
    end
  end

  -- Built-ins
  local builtin = BUILTINS[name]
  if builtin then
    return builtin(args, ctx)
  end

  -- Bounded function call
  local bounded_def = ctx.game and ctx.game.bounded and ctx.game.bounded[name]
  if bounded_def then
    -- Handler may be registered under the SB function name or the lua: dotted name
    local handlers = ctx.game._bounded_handlers
    local handler  = handlers and (handlers[name] or handlers[bounded_def.lua])
    if handler then
      -- Evaluate first argument
      local first_arg = args and args[1] and eval_expr(args[1], ctx) or nil
      -- Snapshot the reads
      local snap = {}
      for _, path in ipairs(bounded_def.reads or {}) do
        snap[path] = ctx.state:get(path)
      end
      local result = handler(first_arg, snap)
      -- Log as a random-draw entry for audit/replay
      if ctx.state and ctx.state._log then
        ctx.state._log:append({
          kind   = "random_draw",
          source = name,
          result = result,
          reads  = snap,
          fn     = ctx.fn_name or "?",
        })
      end
      return result
    end
    -- Fallback: no handler registered, return nil
    return nil
  end

  -- User-defined function
  local fn = ctx.fns and ctx.fns[name]
  if not fn then
    -- 0-arg call to an unknown name: return the name as a string.
    -- Required for bare identifiers (relation-name, family-name, grid-name) passed
    -- as arguments to builtins.  Known limitation: a typo in a 0-arg user function
    -- call silently returns a string instead of erroring; this trade-off is accepted
    -- because there is no reliable way to distinguish the two cases at eval time.
    if #(args or {}) == 0 then
      -- SF-1: warn in dev mode when the bare name is not a known legitimate
      -- non-function use.  Vars + builtins + bounded already dispatched above.
      -- Suppress for relation names, family names, and grid names — these are
      -- routinely passed as bare identifiers to builtins like adjacent?,
      -- path-list, grid-get, etc.
      if not (ctx.game and ctx.game.production) then
        local game = ctx.game
        local suppress = false
        if game then
          if game.relations and game.relations[name] then suppress = true end
          if not suppress and game.grids and game.grids[name] then suppress = true end
          if not suppress and game.scenes and game.scenes[name] then suppress = true end
          if not suppress then
            -- Lazily build a lookup set for: type names, family names, and
            -- single-segment state path names (used as base in index_expr and
            -- similar contexts where the caller does its own state lookup).
            if not game._known_bare_names then
              local s = {}
              -- Type names (map or list format depending on caller)
              for k, v in pairs((game.schema and game.schema.types) or {}) do
                if type(k) == "string" then s[k] = true
                elseif type(v) == "table" and v.name then s[v.name] = true end
              end
              -- Family names and single-segment state scalar/record paths
              for _, st in ipairs((game.schema and game.schema.states) or {}) do
                if st.kind == "family" then
                  s[st.family] = true
                elseif st.path then
                  -- Only suppress for single-segment paths (no slash)
                  if type(st.path) == "string" and not st.path:find("/", 1, true) then
                    s[st.path] = true
                  end
                end
              end
              game._known_bare_names = s
            end
            if game._known_bare_names[name] then suppress = true end
          end
        end
        if not suppress then
          local msg = "[WARN] unknown call '" .. name ..
                      "' returned as string — possible typo in function name\n"
          local sink = game and game._print_sink
          if sink then sink(msg) else io.stderr:write(msg) end
        end
      end
      return name
    end
    error("Undefined function: " .. tostring(name), 2)
  end

  -- Evaluate positional args
  local arg_vals = {}
  for i, arg_node in ipairs(args or {}) do
    arg_vals[i] = eval_expr(arg_node, ctx)
  end

  -- Create child context, bind params
  local sub = child_ctx(ctx, name)
  for i, param in ipairs(fn.params or {}) do
    -- params may be plain strings (from parser) or {name=...} tables
    local pname = type(param) == "table" and param.name or tostring(param)
    if arg_vals[i] == nil then
      sub.nil_vars = sub.nil_vars or {}
      sub.nil_vars[pname] = true
    else
      sub.vars[pname] = arg_vals[i]
    end
  end
  -- Set up before_snapshot for path@before in post: conditions.
  -- If the caller already has one, propagate it (we're inside a verify/counterfactual).
  -- Otherwise, if this fn has post: conditions and we're in dev mode, snapshot now.
  if ctx.before_snapshot then
    sub.before_snapshot = ctx.before_snapshot
  elseif #(fn.post or {}) > 0 and ctx.state and ctx.state._cache
      and not (ctx.game and ctx.game.production) then
    local snap = {}
    for k, v in pairs(ctx.state._cache) do snap[k] = v end
    sub.before_snapshot = snap
  end

  -- Check pre: conditions
  -- Each item in fn.pre may be an expr_stmt (wrapper) or a raw expression.
  for _, pre_node in ipairs(fn.pre or {}) do
    local expr_to_eval = (pre_node.kind == K.EXPR_STMT) and pre_node.expr or pre_node
    local ok = eval_expr(expr_to_eval, sub)
    if not ok then
      error("Precondition failed in " .. name)
    end
  end

  -- Push checkpoint snapshot before executing body (if fn is tagged [checkpoint])
  local is_checkpoint = false
  for _, tag in ipairs(fn.tags or {}) do
    if tag == "checkpoint" then is_checkpoint = true; break end
  end
  if is_checkpoint and ctx.state and ctx.state.push_checkpoint then
    ctx.state:push_checkpoint(name)
  end

  -- Collect hooks that apply to this function call (by tag or by fn name)
  local hooks = ctx.game and ctx.game.hooks or {}
  local fn_tags_set = {}
  for _, tag in ipairs(fn.tags or {}) do fn_tags_set[tag] = true end

  local pre_hooks  = {}  -- bodies to run before the fn body
  local post_hooks = {}  -- bodies to run after the fn body
  for _, h in ipairs(hooks) do
    if h.hook_kind == "tag_pre" and fn_tags_set[h.target] then
      pre_hooks[#pre_hooks+1] = h.body
    elseif h.hook_kind == "tag_post" and fn_tags_set[h.target] then
      post_hooks[#post_hooks+1] = h.body
    elseif h.hook_kind == "fn_before" and h.target == name then
      pre_hooks[#pre_hooks+1] = h.body
    elseif h.hook_kind == "fn_after" and h.target == name then
      post_hooks[#post_hooks+1] = h.body
    end
  end

  -- Run pre-hooks (observe-only context; mutations not allowed but not enforced here)
  for _, hbody in ipairs(pre_hooks) do
    local hctx = child_ctx(sub, name .. ":pre-hook")
    eval_stmts(hbody, hctx)
  end

  -- Emit fn-call debug event (dev mode only)
  if ctx.debug and not (ctx.game and ctx.game.production) then
    local tick = ctx.state and ctx.state._time and ctx.state._time.tick or 0
    pcall(function()
      ctx.debug:emit("fn-call", { name = name, args = arg_vals, tick = tick })
    end)
  end

  -- Record log length before body execution (for `changes` in post-hooks)
  local log_seq_before = ctx.state and ctx.state._log and #(ctx.state._log._entries or {}) or 0

  -- Coverage hook: track user fn calls (set game_table._fn_call_hook to instrument)
  if ctx.game and ctx.game._fn_call_hook then
    ctx.game._fn_call_hook(name)
  end

  -- Execute body
  eval_stmts(fn.body, sub)

  -- Check post: conditions (only when a before_snapshot is provided)
  if sub.before_snapshot and #(fn.post or {}) > 0 then
    for _, post_node in ipairs(fn.post) do
      local expr_to_eval = (post_node.kind == K.EXPR_STMT) and post_node.expr or post_node
      local ok = eval_expr(expr_to_eval, sub)
      if not ok then
        error("Postcondition failed in " .. name)
      end
    end
  end

  -- Run post-hooks with `changes` variable set to mutations made during body
  if #post_hooks > 0 then
    local changes = {}
    if ctx.state and ctx.state._log then
      local entries = ctx.state._log._entries or {}
      for i = log_seq_before + 1, #entries do
        local e = entries[i]
        if e and e.path then
          changes[#changes+1] = { path = e.path, old = e.old, new = e.new }
        end
      end
    end
    for _, hbody in ipairs(post_hooks) do
      local hctx = child_ctx(sub, name .. ":post-hook")
      hctx.vars["changes"] = changes
      eval_stmts(hbody, hctx)
    end
  end

  -- Propagate scene-navigation signals but not function-internal ones
  if sub.signal and sub.signal.type ~= "return" then
    ctx.signal = sub.signal
  end

  -- Return value: set by expression-type statements, explicit return, or retval propagation
  return sub.retval
end

-- ============================================================
-- Statement evaluator
-- ============================================================

--- Execute a single statement node (side effects only).
---@param node table  statement AST node
---@param ctx  table  evaluation context
eval_stmt = function(node, ctx)
  if not node then return end
  local k = node.kind

  -- Mutation primitives
  if k == K.SET_MUT then
    if node.path and node.path.kind == K.INDEX_EXPR then
      -- Indexed list write: set! path[n] value
      local list_path = eval_path(node.path.base, ctx)
      local idx       = eval_expr(node.path.index, ctx)
      local val       = eval_expr(node.value, ctx)
      local list      = ctx.state:get(list_path) or {}
      local len       = #list
      if type(idx) == "number" then
        if idx < 0 then idx = len + idx + 1 end
        if idx >= 1 and idx <= len then
          local new_list = {table.unpack(list)}
          new_list[idx]  = val
          ctx.state:set(list_path, new_list, ctx.fn_name)
        end
      end
    else
      local path = eval_path(node.path, ctx)
      local val  = eval_expr(node.value, ctx)
      ctx.state:set(path, val, ctx.fn_name)
    end

  elseif k == K.INC_MUT then
    local path   = eval_path(node.path, ctx)
    local amount = eval_expr(node.amount, ctx)
    ctx.state:inc(path, amount, ctx.fn_name)

  elseif k == K.DEC_MUT then
    local path   = eval_path(node.path, ctx)
    local amount = eval_expr(node.amount, ctx)
    ctx.state:dec(path, amount, ctx.fn_name)

  elseif k == K.ADD_MUT then
    local path = eval_path(node.path, ctx)
    local val  = eval_expr(node.value, ctx)
    ctx.state:add(path, val, ctx.fn_name)

  elseif k == K.REMOVE_MUT then
    local path = eval_path(node.path, ctx)
    local val  = eval_expr(node.value, ctx)
    ctx.state:remove(path, val, ctx.fn_name)

  elseif k == K.CLEAR_MUT then
    local path = eval_path(node.path, ctx)
    ctx.state:clear(path, ctx.fn_name)

  elseif k == K.PUSH_MUT then
    local path = eval_path(node.path, ctx)
    local val  = eval_expr(node.value, ctx)
    ctx.state:push(path, val, ctx.fn_name)

  elseif k == K.POP_MUT then
    local path = eval_path(node.path, ctx)
    ctx.state:pop(path, ctx.fn_name)

  elseif k == K.MAP_SET_MUT then
    local path = eval_path(node.path, ctx)
    local key  = eval_expr(node.key, ctx)
    local val  = eval_expr(node.value, ctx)
    local map  = ctx.state:get(path) or {}
    local new_map = {}
    for k2, v in pairs(map) do new_map[k2] = v end
    new_map[key] = val
    ctx.state:set(path, new_map, ctx.fn_name)

  elseif k == K.MAP_DELETE_MUT then
    local path = eval_path(node.path, ctx)
    local key  = eval_expr(node.key, ctx)
    local map  = ctx.state:get(path) or {}
    local new_map = {}
    for k2, v in pairs(map) do if k2 ~= key then new_map[k2] = v end end
    ctx.state:set(path, new_map, ctx.fn_name)

  elseif k == K.SPAWN_MUT then
    -- family is a bare string (IDENT), key and record are exprs
    local family = node.family  -- string
    local key    = eval_expr(node.key, ctx)
    local record = eval_expr(node.record, ctx)
    ctx.state:spawn(family, key, record, ctx.fn_name)

  elseif k == K.DESPAWN_MUT then
    local family = node.family  -- string
    local key    = eval_expr(node.key, ctx)
    ctx.state:despawn(family, key, ctx.fn_name)

  elseif k == K.RELATE_MUT then
    local rel_name = node.rel  -- string
    local source   = tostring(eval_expr(node.a, ctx))
    local target   = tostring(eval_expr(node.b, ctx))
    write_rel_edge(ctx, rel_name, source, target, true)

  elseif k == K.UNRELATE_MUT then
    local rel_name = node.rel  -- string
    local source   = tostring(eval_expr(node.a, ctx))
    local target   = tostring(eval_expr(node.b, ctx))
    write_rel_edge(ctx, rel_name, source, target, false)

  elseif k == K.RELATE_BOTH_MUT then
    local rel_name = node.rel
    local a        = tostring(eval_expr(node.a, ctx))
    local b        = tostring(eval_expr(node.b, ctx))
    write_rel_edge(ctx, rel_name, a, b, true)
    write_rel_edge(ctx, rel_name, b, a, true)

  elseif k == K.UNRELATE_BOTH_MUT then
    local rel_name = node.rel
    local a        = tostring(eval_expr(node.a, ctx))
    local b        = tostring(eval_expr(node.b, ctx))
    write_rel_edge(ctx, rel_name, a, b, false)
    write_rel_edge(ctx, rel_name, b, a, false)

  -- Control flow
  elseif k == K.WHEN_STMT then
    local cond = eval_expr(node.condition, ctx)
    if cond then
      local sub = child_ctx(ctx)
      eval_stmts(node.body, sub)
      if sub.signal then ctx.signal = sub.signal end
      if sub.retval ~= nil then ctx.retval = sub.retval end
    end

  elseif k == K.IF_EXPR then
    -- if_expr used as a statement; propagate retval so if/else works in fn bodies
    local cond = eval_expr(node.condition, ctx)
    if cond then
      local sub = child_ctx(ctx)
      eval_stmts(node.then_body, sub)
      if sub.signal then ctx.signal = sub.signal end
      if sub.retval ~= nil then ctx.retval = sub.retval end
    elseif node.else_body then
      local sub = child_ctx(ctx)
      eval_stmts(node.else_body, sub)
      if sub.signal then ctx.signal = sub.signal end
      if sub.retval ~= nil then ctx.retval = sub.retval end
    end

  elseif k == K.MATCH_EXPR then
    ctx.retval = eval_match(node, ctx)

  elseif k == K.COND_EXPR then
    ctx.retval = eval_cond(node, ctx)

  elseif k == K.FOR_STMT then
    local list = M.eval_for_iter(node.iter, ctx)
    local iterated = false
    if type(list) == "table" then
      for _, val in ipairs(list) do
        iterated = true
        local sub = child_ctx(ctx)
        sub.vars[node.var] = val
        eval_stmts(node.body, sub)
        if sub.signal then
          local st = sub.signal.type
          if st == "break"    then return end
          if st == "continue" then -- continue to next iteration
          else ctx.signal = sub.signal; return end
        end
      end
    end
    if not iterated and node.else_body then
      eval_stmts(node.else_body, ctx)
    end

  elseif k == K.WHILE_STMT then
    local limit = 10000
    while eval_expr(node.condition, ctx) do
      if limit <= 0 then
        error("while loop exceeded 10000 iteration safety limit")
      end
      local sub = child_ctx(ctx)
      eval_stmts(node.body, sub)
      if sub.signal then
        local st = sub.signal.type
        if st == "break"    then return end
        if st == "continue" then -- continue to next iteration
        else ctx.signal = sub.signal; return end
      end
      limit = limit - 1
    end

  elseif k == K.LET_STMT then
    if #(node.body or {}) > 0 then
      -- Colon form: `let x = expr: body` — scoped sub-context
      local sub = child_ctx(ctx)
      for _, binding in ipairs(node.bindings or {}) do
        if binding.kind == K.LET_BINDING then
          sub.vars[binding.name] = eval_expr(binding.expr, sub)
        end
      end
      eval_stmts(node.body, sub)
      if sub.signal then ctx.signal = sub.signal end
      if sub.retval ~= nil then ctx.retval = sub.retval end
    else
      -- Plain form: `let x = expr` — bind into current context for rest of fn
      for _, binding in ipairs(node.bindings or {}) do
        if binding.kind == K.LET_BINDING then
          local val = eval_expr(binding.expr, ctx)
          if val == nil then
            ctx.nil_vars = ctx.nil_vars or {}
            ctx.nil_vars[binding.name] = true
          else
            ctx.vars[binding.name] = val
          end
        end
      end
    end

  elseif k == K.SEND_MUT then
    -- Resolve actor name from the actor node (always a 0-arg fn_call)
    local actor_name
    if node.actor and node.actor.kind == K.FN_CALL then
      actor_name = node.actor.name
    else
      actor_name = tostring(eval_expr(node.actor, ctx) or "?")
    end
    local msg = eval_expr(node.msg, ctx)
    if ctx.actors then
      ctx.actors:send(actor_name, msg)
    end
    if ctx.debug then
      local tick = ctx.state and ctx.state._time and ctx.state._time.tick or 0
      pcall(function()
        ctx.debug:emit("message-sent", { actor = actor_name, msg = msg, tick = tick })
      end)
    end

  elseif k == K.CANCEL_SCHEDULE_MUT then
    if ctx.scheduler then ctx.scheduler:cancel(node.name) end

  elseif k == K.SCHEDULE_MUT then
    -- Imperative schedule creation: schedule! 'name every: [...] fn: fn-name
    if ctx.scheduler then
      local name_val = eval_expr(node.name, ctx)
      if type(name_val) ~= "string" then name_val = tostring(name_val or "?") end
      local fn_name  = node.fn  -- string function name
      local trigger  = { every = {}, at = {}, offset = {} }
      -- Evaluate trigger entries
      for kind, entries in pairs(node.opts or {}) do
        if trigger[kind] then
          for _, entry in ipairs(entries or {}) do
            local val = eval_expr(entry.value, ctx)
            trigger[kind][#trigger[kind]+1] = { axis = entry.axis, value = val or 0 }
          end
        end
      end
      -- Retrieve fn body from fns table
      local fn = fn_name and ctx.fns and ctx.fns[fn_name]
      local body = fn and fn.body or {}
      ctx.scheduler:register(name_val, trigger, body, fn_name)
      -- Log schedule creation so save/load can replay it
      if ctx.state and ctx.state._log then
        local ss = ctx.scheduler._static[name_val]
        local nf, fa, fi = {}, {}, {}
        if ss then
          for a, v in pairs(ss.next_fire or {}) do nf[a] = v end
          for a, v in pairs(ss.fire_at   or {}) do fa[a] = v end
          for a, v in pairs(ss.fired     or {}) do fi[a] = v end
        end
        ctx.state._log:append({
          kind          = "schedule_created",
          fn            = ctx.fn_name or "?",
          path          = nil,
          old           = nil,
          new           = nil,
          schedule_name = name_val,
          trigger       = trigger,
          fn_body       = fn_name,
          next_fire     = nf,
          fire_at       = fa,
          fired         = fi,
        })
      end
    end

  elseif k == K.CHECKPOINT_MUT then
    -- engine/checkpoint! [fn-name] — push a checkpoint into the log
    if ctx.state and ctx.state.push_checkpoint then
      local label
      if node.fn_name then
        local v = eval_expr(node.fn_name, ctx)
        label = tostring(v or "manual")
      else
        label = ctx.fn_name or "manual"
      end
      ctx.state:push_checkpoint(label)
    end

  elseif k == K.EMIT_MUT then
    -- engine/emit event [args] — emit a named event to debug/presentation layer
    local event_name = eval_expr(node.event, ctx)
    local payload    = node.args and eval_expr(node.args, ctx) or {}
    if type(event_name) == "string" then
      local tick = ctx.state and ctx.state._time and ctx.state._time.tick or 0
      if ctx.debug then
        pcall(function() ctx.debug:emit(event_name, payload) end)
      end
      -- Also fire game-level listeners (ctx.game._emit_hook if set by lib/storybase)
      if ctx.game and type(ctx.game._emit_hook) == "function" then
        pcall(ctx.game._emit_hook, event_name, payload, tick)
      end
    end

  elseif k == K.UNDO_MUT then
    local steps = node.steps and eval_expr(node.steps, ctx) or 1
    if ctx.state and ctx.state.undo then
      local ok = ctx.state:undo(steps)
      if not ok then
        error("undo!: no checkpoint found in history")
      end
    end

  elseif k == K.TIME_INC_MUT then
    -- Advance engine time clock for each named axis
    for _, ax in ipairs(node.axes or {}) do
      local amount = eval_expr(ax.value, ctx)
      if type(amount) == "number" and type(ax.axis) == "string" then
        ctx.state:inc_time(ax.axis, amount)
      end
    end

  elseif k == K.TIME_SET_MUT then
    -- Set engine time clock to absolute values for each named axis
    for _, ax in ipairs(node.axes or {}) do
      local value = eval_expr(ax.value, ctx)
      if type(value) == "number" and type(ax.axis) == "string" then
        ctx.state:set_time(ax.axis, value)
      end
    end

  elseif k == K.BREAK_STMT then
    ctx.signal = { type = "break" }

  elseif k == K.CONTINUE_STMT then
    ctx.signal = { type = "continue" }

  elseif k == K.RETURN_STMT then
    if node.expr then ctx.retval = eval_expr(node.expr, ctx) end
    ctx.signal = { type = "return" }

  elseif k == K.PASS_STMT then
    -- no-op

  elseif k == K.EXPR_STMT then
    ctx.retval = eval_expr(node.expr, ctx)

  elseif k == K.FN_CALL then
    -- fn_call appearing directly as a statement (not wrapped in expr_stmt)
    ctx.call_pos = node.pos   -- expose source location to builtins (print/log)
    ctx.retval = call_fn(node.name, node.args, ctx)

  elseif k == K.SAY_STMT then
    -- Resolve speaker name to string
    local spk_name
    if node.speaker then
      local v = eval_expr(node.speaker, ctx)
      spk_name = v ~= nil and tostring(v) or nil
    end
    -- Look up speaker metadata from game schema
    local speakers = ctx.game and ctx.game.schema and ctx.game.schema.speakers or {}
    local meta     = spk_name and speakers[spk_name]
    local display  = meta and meta.display or spk_name
    local color    = meta and meta.color
    -- Render each line and emit a dialogue object into the narration buffer
    local buf = ctx.narration_buf
    for _, line in ipairs(node.lines or {}) do
      local text = M.render_text(line, ctx)
      if text ~= "" then
        local obj = { kind = "say", speaker = spk_name, display = display, color = color, text = text }
        if buf then
          buf[#buf + 1] = obj
        end
      end
    end

  -- Scene navigation
  elseif k == K.SCENE_GOTO then
    local target
    if type(node.target) == "string" then
      target = node.target
    else
      target = eval_expr(node.target, ctx)
    end
    ctx.signal = { type = "goto", target = tostring(target or "?") }

  elseif k == K.SCENE_ENTER then
    local target
    if type(node.target) == "string" then
      target = node.target
    else
      target = eval_expr(node.target, ctx)
    end
    ctx.signal = { type = "enter", target = tostring(target or "?") }

  elseif k == K.SCENE_EXIT then
    ctx.signal = { type = "exit" }

  -- Imperative scene navigation mutation primitives — semantically identical
  -- to scene_goto / scene_enter / scene_exit; the sigil and bang forms target
  -- the same engine signal machinery.
  elseif k == K.GOTO_SCENE_MUT then
    local target
    if type(node.target) == "string" then
      target = node.target
    else
      target = eval_expr(node.target, ctx)
    end
    ctx.signal = { type = "goto", target = tostring(target or "?") }

  elseif k == K.ENTER_SCENE_MUT then
    local target
    if type(node.target) == "string" then
      target = node.target
    else
      target = eval_expr(node.target, ctx)
    end
    ctx.signal = { type = "enter", target = tostring(target or "?") }

  elseif k == K.EXIT_SCENE_MUT then
    ctx.signal = { type = "exit" }
  end
end

--- Execute a list of statement nodes.
--- Stops early if ctx.signal is set (scene navigation).
---@param stmts table  list of statement nodes
---@param ctx   table  evaluation context
eval_stmts = function(stmts, ctx)
  for _, stmt in ipairs(stmts or {}) do
    eval_stmt(stmt, ctx)
    if ctx.signal then return end
  end
end

-- ============================================================
-- Narration rendering
-- ============================================================

--- Convert any value to a display string for narration/template interpolation.
--- Lists (sequential tables) are joined with ", ".
--- Numbers with no fractional part are rendered without ".0" (presentational only).
local function val_to_display(val)
  if val == nil then return "" end
  if type(val) == "number" and math.type(val) == "float" and val == math.floor(val) then
    return string.format("%d", val)
  end
  if type(val) == "table" then
    -- Sequential list: join with ", "
    if #val > 0 or next(val) == nil then
      local parts = {}
      for _, v in ipairs(val) do parts[#parts+1] = tostring(v) end
      return table.concat(parts, ", ")
    end
    return tostring(val)
  end
  return tostring(val)
end

--- Render a narration text list (mixed strings and inline_expr nodes) to a string.
---@param text table  list of strings and inline_expr nodes
---@param ctx  table  evaluation context
---@return string
function M.render_text(text, ctx)
  local parts = {}
  for _, item in ipairs(text or {}) do
    if type(item) == "string" then
      parts[#parts + 1] = item
    elseif type(item) == "table" and item.kind == K.INLINE_EXPR then
      local val = eval_expr(item.expr, ctx)
      parts[#parts + 1] = val_to_display(val)
    end
  end
  return table.concat(parts, "")
end

-- ============================================================
-- Public API
-- ============================================================

--- Evaluate an expression against a context.
---@param node table  expression AST node
---@param ctx  table  evaluation context
---@return any
function M.eval_expr(node, ctx)
  return eval_expr(node, ctx)
end

--- Execute a list of statements against a context.
---@param stmts table  list of statement AST nodes
---@param ctx   table  evaluation context
function M.eval_stmts(stmts, ctx)
  eval_stmts(stmts, ctx)
end

--- Execute a single statement.
---@param node table  statement AST node
---@param ctx  table  evaluation context
function M.eval_stmt(node, ctx)
  eval_stmt(node, ctx)
end

--- Create a child context with extra variable bindings.
---@param ctx  table  parent context
---@param vars table  variable bindings to add {name → value}
---@return table
function M.child_ctx_vars(ctx, vars)
  local c = child_ctx(ctx)
  for k, v in pairs(vars or {}) do c.vars[k] = v end
  return c
end

--- Resolve a `for-loop` iter expression to a Lua array.
--- Shape C (J-I2): if the iter is a bare identifier matching a declared
--- enum type, return that enum's variant symbols. The parser emits such
--- iters as either a single-segment `path_expr` or a zero-arg `fn_call`,
--- depending on token shape — match both. Otherwise delegate to
--- `eval_expr`. The schema's `_type_index` is built lazily on first call
--- (BFS callers don't always invoke `engine:init`).
function M.eval_for_iter(node, ctx)
  local name = nil
  if node and node.kind == K.PATH_EXPR
              and node.segments and #node.segments == 1 then
    name = node.segments[1]
  elseif node and node.kind == K.FN_CALL
              and (not node.args or #node.args == 0) then
    name = node.name
  end
  if name then
    local schema = ctx.game and ctx.game.schema
    if schema and schema.types then
      local idx = schema._type_index
      if not idx then
        idx = {}
        for _, t in ipairs(schema.types) do
          if t.name then idx[t.name] = t end
        end
        schema._type_index = idx
      end
      local t = idx[name]
      if t and t.kind == "enum" then
        return t.values
      end
    end
  end
  return eval_expr(node, ctx)
end

--- Evaluate a path node to a string.
---@param node table  path_expr or interp_path node
---@param ctx  table  evaluation context
---@return string
function M.eval_path(node, ctx)
  return eval_path(node, ctx)
end

--- Call a user-defined or built-in function by name.
---@param name string  function name
---@param args table   list of unevaluated argument nodes
---@param ctx  table   evaluation context
---@return any
function M.call_fn(name, args, ctx)
  return call_fn(name, args, ctx)
end

function M.call_lambda(lam, args, ctx)
  return call_lambda(lam, args, ctx)
end

return M

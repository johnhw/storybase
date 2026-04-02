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
  SPAWN_MUT          = "spawn_mut",
  DESPAWN_MUT        = "despawn_mut",
  RELATE_MUT         = "relate_mut",
  UNRELATE_MUT       = "unrelate_mut",
  SEND_MUT           = "send_mut",
  UNDO_MUT           = "undo_mut",
  TIME_INC_MUT       = "time_inc_mut",
  SCENE_GOTO         = "scene_goto",
  SCENE_ENTER        = "scene_enter",
  SCENE_EXIT         = "scene_exit",
}

-- ============================================================
-- Context helpers
-- ============================================================

--- Create a new evaluation context.
---@param state   table   runtime.state instance
---@param fns     table   game_table.fns
---@param fn_name string  current function name (for log)
---@return table
function M.new_ctx(state, fns, fn_name)
  return {
    state   = state,
    fns     = fns or {},
    vars    = {},
    fn_name = fn_name or "?",
    signal  = nil,
    retval  = nil,
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
  }
  -- Copy parent vars into child (shadowing allowed)
  for k, v in pairs(parent.vars) do
    child.vars[k] = v
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
        local val = ctx.vars[seg.interp]
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

  -- Path read
  elseif k == K.PATH_EXPR then
    local path = eval_path(node, ctx)
    -- Check local vars first (single-segment paths can be loop/let vars)
    if #(node.segments or {}) == 1 and ctx.vars[node.segments[1]] ~= nil then
      return ctx.vars[node.segments[1]]
    end
    return ctx.state:get(path)

  elseif k == K.INTERP_PATH then
    return ctx.state:get(eval_path(node, ctx))

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
    return call_fn(node.name, node.args, ctx)

  -- If expression
  elseif k == K.IF_EXPR then
    local cond = eval_expr(node.condition, ctx)
    if cond then
      -- Return the last expression value from then_body
      local result
      local sub = child_ctx(ctx)
      eval_stmts(node.then_body, sub)
      if sub.signal then ctx.signal = sub.signal end
      return result
    elseif node.else_body then
      local result
      local sub = child_ctx(ctx)
      eval_stmts(node.else_body, sub)
      if sub.signal then ctx.signal = sub.signal end
      return result
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
    local t = {}
    for _, entry in ipairs(node.entries or {}) do
      local key = eval_expr(entry.key, ctx)
      local val = eval_expr(entry.value, ctx)
      t[key] = val
    end
    return t

  -- Record constructor: TypeName(field: val, ...)
  elseif k == K.RECORD_CONSTRUCTOR then
    local record = {}
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
local function match_pattern(pattern, value)
  if pattern == "_" then return true end  -- wildcard
  local pval = eval_expr(pattern, { state = { get = function() return nil end }, vars = {}, fns = {} })
  return pval == value
end

eval_match = function(node, ctx)
  local subject = eval_expr(node.expr, ctx)
  for _, arm in ipairs(node.arms or {}) do
    if arm.kind == K.MATCH_ARM then
      local matched = false
      local pat = arm.pattern
      if pat == "_" then
        matched = true
      else
        local pval = eval_expr(pat, ctx)
        matched = (pval == subject)
      end
      if matched then
        if type(arm.body) == "table" and arm.body.kind then
          -- body is a single expression
          return eval_expr(arm.body, ctx)
        else
          -- body is a list of statements
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
  end
  return result
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
    return math.random(lo, hi)
  end,
  ["tostring"] = function(args, ctx)
    return tostring(eval_expr(args[1], ctx))
  end,
}

--- Dispatch a function call by name.
---@param name string      function name
---@param args table       unevaluated arg nodes
---@param ctx  table       evaluation context
---@return any
call_fn = function(name, args, ctx)
  -- 0-arg fn_call nodes may actually be variable references (params, let bindings, for vars)
  if #(args or {}) == 0 and ctx.vars[name] ~= nil then
    return ctx.vars[name]
  end

  -- Built-ins
  local builtin = BUILTINS[name]
  if builtin then
    return builtin(args, ctx)
  end

  -- User-defined function
  local fn = ctx.fns and ctx.fns[name]
  if not fn then
    -- If this is a 0-arg call and the name isn't any known entity, return the name
    -- as a string (used for bare family/path names passed to path-list, spawn!, etc.)
    if #(args or {}) == 0 then
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
    sub.vars[pname] = arg_vals[i]
  end

  -- Check pre: conditions
  for _, pre_expr in ipairs(fn.pre or {}) do
    local ok = eval_expr(pre_expr, sub)
    if not ok then
      error("Precondition failed in " .. name)
    end
  end

  -- Execute body
  eval_stmts(fn.body, sub)

  -- Propagate any scene-navigation signal
  if sub.signal then
    ctx.signal = sub.signal
  end

  -- Return value: set by expression-type statements (cond, match, fn_call, expr_stmt)
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
    local path = eval_path(node.path, ctx)
    local val  = eval_expr(node.value, ctx)
    ctx.state:set(path, val, ctx.fn_name)

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

  -- Control flow
  elseif k == K.WHEN_STMT then
    local cond = eval_expr(node.condition, ctx)
    if cond then
      local sub = child_ctx(ctx)
      eval_stmts(node.body, sub)
      if sub.signal then ctx.signal = sub.signal end
    end

  elseif k == K.IF_EXPR then
    -- if_expr used as a statement
    local cond = eval_expr(node.condition, ctx)
    if cond then
      local sub = child_ctx(ctx)
      eval_stmts(node.then_body, sub)
      if sub.signal then ctx.signal = sub.signal end
    elseif node.else_body then
      local sub = child_ctx(ctx)
      eval_stmts(node.else_body, sub)
      if sub.signal then ctx.signal = sub.signal end
    end

  elseif k == K.MATCH_EXPR then
    ctx.retval = eval_match(node, ctx)

  elseif k == K.COND_EXPR then
    ctx.retval = eval_cond(node, ctx)

  elseif k == K.FOR_STMT then
    local list = eval_expr(node.iter, ctx)
    if type(list) == "table" then
      for _, val in ipairs(list) do
        local sub = child_ctx(ctx)
        sub.vars[node.var] = val
        eval_stmts(node.body, sub)
        if sub.signal then ctx.signal = sub.signal; return end
      end
    end

  elseif k == K.WHILE_STMT then
    local limit = 10000  -- safety limit
    while eval_expr(node.condition, ctx) and limit > 0 do
      local sub = child_ctx(ctx)
      eval_stmts(node.body, sub)
      if sub.signal then ctx.signal = sub.signal; return end
      -- Merge any var changes back? No — stmts mutate state directly.
      limit = limit - 1
    end

  elseif k == K.LET_STMT then
    local sub = child_ctx(ctx)
    for _, binding in ipairs(node.bindings or {}) do
      -- binding is a let_binding node with .name and .expr
      if binding.kind == K.LET_BINDING then
        sub.vars[binding.name] = eval_expr(binding.expr, sub)
      end
    end
    eval_stmts(node.body, sub)
    if sub.signal then ctx.signal = sub.signal end

  elseif k == K.UNDO_MUT then
    -- undo! not yet implemented — no-op

  elseif k == K.TIME_INC_MUT then
    -- Advance engine time clock for each named axis
    for _, ax in ipairs(node.axes or {}) do
      local amount = eval_expr(ax.value, ctx)
      if type(amount) == "number" and type(ax.axis) == "string" then
        ctx.state:inc_time(ax.axis, amount)
      end
    end

  elseif k == K.PASS_STMT then
    -- no-op

  elseif k == K.EXPR_STMT then
    ctx.retval = eval_expr(node.expr, ctx)

  elseif k == K.FN_CALL then
    -- fn_call appearing directly as a statement (not wrapped in expr_stmt)
    ctx.retval = call_fn(node.name, node.args, ctx)

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
      parts[#parts + 1] = tostring(val ~= nil and val or "")
    end
  end
  return table.concat(parts, " ")
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

return M

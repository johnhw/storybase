-- cli/format_cmd.lua
-- storybase format [--check] [--write] <file>
--
-- Pretty-print a .sb file in canonical style (2-space indentation).
-- Without flags: write formatted source to stdout.
-- --check: exit 0 if file is already canonical, 1 if it differs.
-- --write: rewrite file in-place (creates .sb.bak backup).
--
-- The formatter walks the parsed AST and emits a normalised representation.
-- Comments and blank lines in the original source are not preserved.

local M = {}

local ast = require("compiler.ast")

-- ============================================================
-- Formatter state
-- ============================================================

local function new_buf()
  local parts  = {}
  local indent = 0

  local function emit(s)
    parts[#parts + 1] = s
  end

  local function nl()
    parts[#parts + 1] = "\n"
  end

  local function ind()
    parts[#parts + 1] = string.rep("  ", indent)
  end

  local function line(s)
    ind(); emit(s); nl()
  end

  local function blank()
    nl()
  end

  local function push()
    indent = indent + 1
  end

  local function pop()
    indent = indent - 1
  end

  local function result()
    return table.concat(parts)
  end

  return {
    emit   = emit,
    nl     = nl,
    ind    = ind,
    line   = line,
    blank  = blank,
    push   = push,
    pop    = pop,
    result = result,
  }
end

-- ============================================================
-- Helpers
-- ============================================================

--- Render a mixed text-segment list (narration or choice label) to a string.
--- Each item is either a plain string or an inline_expr node {kind="inline_expr", expr=...}.
---@param segments table  list of string | {kind, expr}
---@return string
local function render_text_segments(segments)
  if type(segments) == "string" then return segments end
  if type(segments) ~= "table" then return tostring(segments) end
  local parts = {}
  for _, seg in ipairs(segments) do
    if type(seg) == "string" then
      parts[#parts + 1] = seg
    elseif type(seg) == "table" and seg.kind == "inline_expr" then
      parts[#parts + 1] = "{" .. (fmt_expr and fmt_expr(seg.expr) or "?") .. "}"
    elseif type(seg) == "table" then
      -- Fallback for other segment types
      parts[#parts + 1] = tostring(seg.value or "?")
    end
  end
  return table.concat(parts)
end

-- ============================================================
-- Expression / type formatters (recursive)
-- ============================================================

local fmt_expr   -- forward declaration
local fmt_type   -- forward declaration
local fmt_stmts  -- forward declaration

--- Format a type expression to a compact string.
---@param node table  type-expr AST node
---@return string
fmt_type = function(node)
  if not node then return "?" end
  local K = ast.K
  local k = node.kind
  if k == K.TYPE_BOOL   then return "Bool" end
  if k == K.TYPE_INT    then
    if node.lo ~= nil or node.hi ~= nil then
      local lo = node.lo ~= nil and tostring(node.lo) or ""
      local hi = node.hi ~= nil and tostring(node.hi) or ""
      return string.format("Int(%s, %s)", lo, hi)
    end
    return "Int"
  end
  if k == K.TYPE_FLOAT  then return "Float" end
  if k == K.TYPE_STRING then return "String" end
  if k == K.TYPE_SYMBOL then return "Symbol" end
  if k == K.TYPE_SYMBOL_OF then
    return string.format("SymbolOf(%s)", node.family or "?")
  end
  if k == K.TYPE_NAMED  then return node.name or "?" end
  if k == K.TYPE_OPTION then return fmt_type(node.inner) .. "?" end
  if k == K.TYPE_SET    then return "Set " .. fmt_type(node.inner) end
  if k == K.TYPE_LIST   then return "List " .. fmt_type(node.inner) end
  if k == K.TYPE_ULIST  then return "UList " .. fmt_type(node.inner) end
  if k == K.TYPE_UMAP then
    return string.format("UMap %s %s",
      fmt_type(node.key_type), fmt_type(node.val_type))
  end
  if k == K.TYPE_ENUM_INLINE then
    local vals = {}
    for _, v in ipairs(node.values or {}) do vals[#vals + 1] = "'" .. v end
    return table.concat(vals, " | ")
  end
  if k == K.TYPE_FN then
    local params = {}
    for _, p in ipairs(node.params or {}) do params[#params + 1] = fmt_type(p) end
    return "fn(" .. table.concat(params, ", ") .. ") -> " .. fmt_type(node.ret)
  end
  return "?" -- unknown type node
end

--- Format a single expression node to a compact string.
---@param node table  expression AST node
---@return string
fmt_expr = function(node)
  if not node then return "?" end
  local K = ast.K
  local k = node.kind

  if k == K.INT_LIT    then return tostring(node.value) end
  if k == K.FLOAT_LIT  then
    local s = tostring(node.value)
    -- Ensure float has decimal point
    if not s:find("%.") and not s:find("e") then s = s .. ".0" end
    return s
  end
  if k == K.BOOL_LIT   then return node.value and "true" or "false" end
  if k == K.STRING_LIT then
    return string.format("%q", node.value):gsub("\\\n", "\\n")
  end
  if k == K.MULTILINE_STRING then
    return '"""' .. (node.value or "") .. '"""'
  end
  if k == K.SYMBOL_LIT then return "'" .. (node.value or "?") end

  if k == K.PATH_EXPR then
    local segs = {}
    for _, s in ipairs(node.segments or {}) do
      if type(s) == "string" then
        segs[#segs + 1] = s
      elseif type(s) == "table" then
        segs[#segs + 1] = "{" .. fmt_expr(s) .. "}"
      end
    end
    return table.concat(segs, "/")
  end

  if k == K.INTERP_PATH then
    local segs = {}
    for _, s in ipairs(node.segments or {}) do
      if type(s) == "string" then
        segs[#segs + 1] = s
      elseif type(s) == "table" then
        segs[#segs + 1] = "{" .. fmt_expr(s) .. "}"
      end
    end
    return table.concat(segs, "/")
  end

  if k == K.BINARY_OP then
    return string.format("(%s %s %s)",
      fmt_expr(node.left), node.op, fmt_expr(node.right))
  end

  if k == K.UNARY_OP then
    local operand = node.operand or node.expr
    return string.format("(%s %s)", node.op, fmt_expr(operand))
  end

  if k == K.NIL_COALESCE then
    return string.format("(%s ?? %s)", fmt_expr(node.left), fmt_expr(node.right))
  end

  if k == K.FN_CALL then
    if not node.args or #node.args == 0 then
      return node.name or "?"
    end
    local args = {}
    for _, a in ipairs(node.args) do args[#args + 1] = fmt_expr(a) end
    return (node.name or "?") .. " " .. table.concat(args, " ")
  end

  if k == K.NAMED_ARG then
    return (node.name or "?") .. ": " .. fmt_expr(node.value)
  end

  if k == K.IF_EXPR then
    local s = "if " .. fmt_expr(node.cond) .. ": " .. fmt_expr(node.then_expr)
    if node.else_expr then s = s .. " else: " .. fmt_expr(node.else_expr) end
    return s
  end

  if k == K.MATCH_EXPR then
    local arms = {}
    for _, arm in ipairs(node.arms or {}) do
      arms[#arms + 1] = fmt_expr(arm.pattern) .. " -> " .. fmt_expr(arm.body)
    end
    return "match " .. fmt_expr(node.subject) .. " { "
           .. table.concat(arms, " | ") .. " }"
  end

  if k == K.INDEX_EXPR then
    return fmt_expr(node.table_expr) .. "[" .. fmt_expr(node.index) .. "]"
  end

  if k == K.SET_LIT then
    local items = {}
    for _, v in ipairs(node.items or {}) do items[#items + 1] = fmt_expr(v) end
    return "{" .. table.concat(items, ", ") .. "}"
  end

  if k == K.LIST_LIT then
    local items = {}
    for _, v in ipairs(node.items or {}) do items[#items + 1] = fmt_expr(v) end
    return "[" .. table.concat(items, ", ") .. "]"
  end

  if k == K.MAP_LIT then
    local items = {}
    for _, p in ipairs(node.pairs or {}) do
      items[#items + 1] = fmt_expr(p.key) .. " => " .. fmt_expr(p.value)
    end
    return "{" .. table.concat(items, ", ") .. "}"
  end

  if k == K.EMPTY_SET  then return "{}" end
  if k == K.EMPTY_LIST then return "[]" end
  if k == K.EMPTY_MAP  then return "{=>}" end

  if k == K.LAMBDA_EXPR then
    local params = table.concat(node.params or {}, " ")
    return "fn " .. params .. ": " .. fmt_expr(node.body)
  end

  if k == K.RECORD_CONSTRUCTOR then
    local fields = {}
    for _, f in ipairs(node.fields or {}) do
      fields[#fields + 1] = f.name .. ": " .. fmt_expr(f.value)
    end
    return (node.type_name or "?") .. "(" .. table.concat(fields, ", ") .. ")"
  end

  if k == K.PATH_AT_BEFORE then
    return fmt_expr(node.path) .. "@@before"
  end

  return "?"
end

-- ============================================================
-- Statement / body formatters
-- ============================================================

local function fmt_stmt(buf, node)
  if not node then return end
  local K = ast.K
  local k = node.kind

  -- Path mutations (set!, inc!, dec!, add!, remove!, clear!, push!, pop!)
  if k == K.SET_MUT then
    buf.line("set! " .. fmt_expr(node.path) .. " " .. fmt_expr(node.value))
  elseif k == K.INC_MUT then
    buf.line("inc! " .. fmt_expr(node.path) .. " " .. fmt_expr(node.amount))
  elseif k == K.DEC_MUT then
    buf.line("dec! " .. fmt_expr(node.path) .. " " .. fmt_expr(node.amount))
  elseif k == K.ADD_MUT then
    buf.line("add! " .. fmt_expr(node.path) .. " " .. fmt_expr(node.value))
  elseif k == K.REMOVE_MUT then
    buf.line("remove! " .. fmt_expr(node.path) .. " " .. fmt_expr(node.value))
  elseif k == K.CLEAR_MUT then
    buf.line("clear! " .. fmt_expr(node.path))
  elseif k == K.PUSH_MUT then
    buf.line("push! " .. fmt_expr(node.path) .. " " .. fmt_expr(node.value))
  elseif k == K.POP_MUT then
    buf.line("pop! " .. fmt_expr(node.path))

  -- Entity mutations
  elseif k == K.SPAWN_MUT then
    local s = "spawn! " .. fmt_expr(node.family) .. " " .. fmt_expr(node.key)
    if node.record then s = s .. " " .. fmt_expr(node.record) end
    buf.line(s)
  elseif k == K.DESPAWN_MUT then
    buf.line("despawn! " .. fmt_expr(node.family) .. " " .. fmt_expr(node.key))

  -- Actor messaging
  elseif k == K.SEND_MUT then
    buf.line("send! " .. fmt_expr(node.actor) .. " " .. fmt_expr(node.msg))

  -- Relation mutations
  elseif k == K.RELATE_MUT then
    buf.line("relate! " .. tostring(node.rel or "?")
             .. " " .. fmt_expr(node.a) .. " " .. fmt_expr(node.b))
  elseif k == K.UNRELATE_MUT then
    buf.line("unrelate! " .. tostring(node.rel or "?")
             .. " " .. fmt_expr(node.a) .. " " .. fmt_expr(node.b))

  -- Time mutations
  elseif k == K.TIME_INC_MUT then
    local axes = {}
    for _, entry in ipairs(node.axes or {}) do
      axes[#axes + 1] = entry.axis .. ": " .. tostring(entry.value)
    end
    buf.line("time-inc! " .. table.concat(axes, " "))
  elseif k == K.TIME_SET_MUT then
    local axes = {}
    for _, entry in ipairs(node.axes or {}) do
      axes[#axes + 1] = entry.axis .. ": " .. tostring(entry.value)
    end
    buf.line("time-set! " .. table.concat(axes, " "))

  -- Undo
  elseif k == K.UNDO_MUT then
    if node.steps and node.steps ~= 1 then
      buf.line("undo! steps: " .. tostring(node.steps))
    else
      buf.line("undo!")
    end

  -- Scene navigation (sigil forms in choice/fn bodies)
  elseif k == K.SCENE_GOTO then
    -- target can be a string or an expr (computed goto)
    local tgt = type(node.target) == "string" and node.target or fmt_expr(node.target)
    buf.line("-> " .. tgt)
  elseif k == K.SCENE_ENTER then
    local tgt = type(node.target) == "string" and node.target or fmt_expr(node.target)
    buf.line("=> " .. tgt)
  elseif k == K.SCENE_EXIT then
    buf.line("<-")

  -- Imperative scene navigation (goto-scene!, enter-scene!, exit-scene!)
  elseif k == K.GOTO_SCENE_MUT then
    buf.line("goto-scene! " .. fmt_expr(node.target))
  elseif k == K.ENTER_SCENE_MUT then
    buf.line("enter-scene! " .. fmt_expr(node.target))
  elseif k == K.EXIT_SCENE_MUT then
    buf.line("exit-scene!")

  -- Schedule mutations
  elseif k == K.SCHEDULE_MUT then
    buf.line("schedule! " .. fmt_expr(node.name))
  elseif k == K.CANCEL_SCHEDULE_MUT then
    buf.line("cancel-schedule! " .. fmt_expr(node.name))

  -- Scene-context if_expr (condition/then_body/else_body with narration items)
  elseif k == K.IF_EXPR then
    local cond = node.condition or node.cond
    buf.ind(); buf.emit("if " .. fmt_expr(cond) .. ":"); buf.nl()
    buf.push()
    for _, t in ipairs(node.then_body or {}) do
      if type(t) == "table" and t.kind == "narration_line" then
        buf.line(render_text_segments(t.text or ""))
      elseif type(t) == "table" and t.kind == "cond_narration" then
        buf.ind()
        buf.emit("[" .. fmt_expr(t.condition or t.cond) .. "] ")
        buf.emit(render_text_segments(t.text or ""))
        buf.nl()
      elseif type(t) == "string" then
        buf.line(t)
      else
        fmt_stmt(buf, t)
      end
    end
    buf.pop()
    if node.else_body and #node.else_body > 0 then
      buf.line("else:")
      buf.push()
      for _, t in ipairs(node.else_body) do
        if type(t) == "table" and t.kind == "narration_line" then
          buf.line(render_text_segments(t.text or ""))
        elseif type(t) == "table" and t.kind == "cond_narration" then
          buf.ind()
          buf.emit("[" .. fmt_expr(t.condition or t.cond) .. "] ")
          buf.emit(render_text_segments(t.text or ""))
          buf.nl()
        elseif type(t) == "string" then
          buf.line(t)
        else
          fmt_stmt(buf, t)
        end
      end
      buf.pop()
    elseif node.else_expr then
      buf.line("else:")
      buf.push()
      buf.line(fmt_expr(node.else_expr))
      buf.pop()
    end

  -- Control flow statements
  elseif k == K.LET_STMT then
    for _, b in ipairs(node.bindings or {}) do
      if type(b) == "table" and b.name then
        buf.line("let " .. b.name .. " = " .. fmt_expr(b.expr))
      end
    end
    fmt_stmts(buf, node.body)
  elseif k == K.FOR_STMT then
    buf.ind()
    buf.emit("for " .. (node.var or "?") .. " in " .. fmt_expr(node.iter) .. ":")
    buf.nl()
    buf.push()
    fmt_stmts(buf, node.body)
    buf.pop()
  elseif k == K.WHILE_STMT then
    buf.ind(); buf.emit("while " .. fmt_expr(node.cond) .. ":"); buf.nl()
    buf.push()
    fmt_stmts(buf, node.body)
    buf.pop()
  elseif k == K.WHEN_STMT then
    local cond = node.condition or node.cond
    buf.ind(); buf.emit("when " .. fmt_expr(cond) .. ":"); buf.nl()
    buf.push()
    fmt_stmts(buf, node.body)
    buf.pop()
    if node.else_body and #node.else_body > 0 then
      buf.line("else:")
      buf.push()
      fmt_stmts(buf, node.else_body)
      buf.pop()
    end
  elseif k == K.IF_EXPR then
    -- if_expr used as a statement (single-branch if as narration control)
    buf.ind(); buf.emit("if " .. fmt_expr(node.cond) .. ":"); buf.nl()
    buf.push()
    if node.then_body then
      fmt_stmts(buf, node.then_body)
    elseif node.then_expr then
      buf.line(fmt_expr(node.then_expr))
    end
    buf.pop()
    if node.else_body and #node.else_body > 0 then
      buf.line("else:")
      buf.push()
      fmt_stmts(buf, node.else_body)
      buf.pop()
    elseif node.else_expr then
      buf.line("else:")
      buf.push()
      buf.line(fmt_expr(node.else_expr))
      buf.pop()
    end
  elseif k == K.MATCH_EXPR then
    -- match used as statement
    buf.ind(); buf.emit("match " .. fmt_expr(node.subject or node.expr) .. ":"); buf.nl()
    buf.push()
    for _, arm in ipairs(node.arms or {}) do
      fmt_stmt(buf, arm)
    end
    buf.pop()
  elseif k == K.COND_EXPR then
    -- cond used as statement
    buf.ind(); buf.emit("cond:"); buf.nl()
    buf.push()
    for _, arm in ipairs(node.arms or {}) do
      fmt_stmt(buf, arm)
    end
    buf.pop()
  elseif k == K.EXPR_STMT then
    buf.line(fmt_expr(node.expr))
  elseif k == K.PASS_STMT then
    buf.line("pass")
  elseif k == K.MATCH_ARM then
    buf.ind(); buf.emit(fmt_expr(node.pattern) .. ":"); buf.nl()
    buf.push()
    fmt_stmts(buf, node.body)
    buf.pop()
  elseif k == K.COND_ARM then
    local cond = node.condition or node.cond
    buf.ind(); buf.emit("[" .. fmt_expr(cond) .. "]:"); buf.nl()
    buf.push()
    fmt_stmts(buf, node.body)
    buf.pop()
  else
    -- Fallback: emit a comment placeholder
    buf.line("-- (stmt:" .. tostring(k) .. ")")
  end
end

fmt_stmts = function(buf, stmts)
  for _, s in ipairs(stmts or {}) do
    fmt_stmt(buf, s)
  end
end

-- ============================================================
-- Declaration formatters
-- ============================================================

local function fmt_decl(buf, decl)
  local K = ast.K
  local k = decl.kind

  if k == K.MODULE_DECL then
    buf.ind(); buf.emit("module " .. (decl.name or "?")); buf.nl()
    local has_body = decl.version or (decl.exports and #decl.exports > 0)
    if has_body then
      buf.push()
      if decl.version then
        buf.line("version: " .. tostring(decl.version))
      end
      if decl.exports and #decl.exports > 0 then
        buf.line("exports: [" .. table.concat(decl.exports, ", ") .. "]")
      end
      buf.pop()
    end

  elseif k == K.IMPORT_DECL then
    local s = 'import "' .. (decl.path or "") .. '"'
    if decl.alias then s = s .. " as " .. decl.alias end
    buf.line(s)

  elseif k == K.SCHEMA_VERSION then
    buf.line("schema-version: " .. tostring(decl.version or "?"))

  elseif k == K.ENGINE_CONFIG then
    buf.line("engine-config:")
    buf.push()
    for k_name, v in pairs(decl.entries or {}) do
      buf.line(k_name .. ": " .. tostring(v))
    end
    buf.pop()

  elseif k == K.TIME_MODEL then
    buf.line("time-model:")
    buf.push()
    for _, axis in ipairs(decl.axes or {}) do
      local s = "axis " .. (axis.name or "?")
      if axis.max ~= nil then s = s .. " max: " .. tostring(axis.max) end
      buf.line(s)
    end
    if decl.default_axis then
      buf.line("default: " .. decl.default_axis)
    end
    buf.pop()

  elseif k == K.TYPE_ENUM then
    local vals = {}
    for _, v in ipairs(decl.values or {}) do vals[#vals + 1] = "'" .. v end
    buf.line("type " .. (decl.name or "?") .. " = " .. table.concat(vals, " | "))

  elseif k == K.TYPE_ALIAS then
    buf.line("type " .. (decl.name or "?") .. " = " .. fmt_type(decl.type_expr))

  elseif k == K.TYPE_RECORD then
    buf.ind(); buf.emit("type " .. (decl.name or "?")); buf.nl()
    buf.push()
    -- with mixins
    for _, w in ipairs(decl.withs or {}) do
      buf.line("with " .. w)
    end
    for _, f in ipairs(decl.fields or {}) do
      local s = (f.name or "?") .. ": " .. fmt_type(f.type_expr)
      if f.default ~= nil then s = s .. " = " .. fmt_expr(f.default) end
      buf.line(s)
    end
    buf.pop()

  elseif k == K.TYPE_VARIANT then
    buf.ind(); buf.emit("type " .. (decl.name or "?")); buf.nl()
    buf.push()
    for _, branch in ipairs(decl.branches or {}) do
      buf.ind(); buf.emit("| " .. (branch.tag or "?") .. ":"); buf.nl()
      buf.push()
      for _, f in ipairs(branch.fields or {}) do
        local s = (f.name or "?") .. ": " .. fmt_type(f.type_expr)
        if f.default ~= nil then s = s .. " = " .. fmt_expr(f.default) end
        buf.line(s)
      end
      buf.pop()
    end
    buf.pop()

  elseif k == K.STATE_SCALAR then
    local s = "state " .. fmt_expr(decl.path) .. ": " .. fmt_type(decl.type_expr)
    if decl.default ~= nil then s = s .. " = " .. fmt_expr(decl.default) end
    if decl.max ~= nil     then s = s .. " max: " .. tostring(decl.max) end
    buf.line(s)

  elseif k == K.STATE_RECORD then
    buf.ind(); buf.emit("state " .. fmt_expr(decl.path) .. ":"); buf.nl()
    buf.push()
    for _, f in ipairs(decl.fields or {}) do
      local s = (f.name or "?") .. ": " .. fmt_type(f.type_expr)
      if f.default ~= nil then s = s .. " = " .. fmt_expr(f.default) end
      buf.line(s)
    end
    buf.pop()

  elseif k == K.STATE_FAMILY then
    local path_s = fmt_expr(decl.path)
    buf.ind()
    buf.emit("state " .. path_s .. ":")
    buf.nl()
    buf.push()
    buf.line("type: " .. fmt_type(decl.type_expr))
    if decl.max ~= nil then buf.line("max: " .. tostring(decl.max)) end
    buf.pop()

  elseif k == K.RELATION_DECL then
    local s = "relation " .. (decl.name or "?")
    if decl.data_type then s = s .. " data: " .. fmt_type(decl.data_type) end
    buf.line(s)

  elseif k == K.FN_DECL then
    buf.ind(); buf.emit("fn " .. (decl.name or "?") .. ":"); buf.nl()
    buf.push()
    if decl.pre and #decl.pre > 0 then
      for _, p in ipairs(decl.pre) do
        buf.line("pre: " .. fmt_expr(p))
      end
    end
    if decl.post and #decl.post > 0 then
      for _, p in ipairs(decl.post) do
        buf.line("post: " .. fmt_expr(p))
      end
    end
    if decl.tags and #decl.tags > 0 then
      buf.line("tags: [" .. table.concat(decl.tags, ", ") .. "]")
    end
    if decl.params and #decl.params > 0 then
      local params = {}
      for _, p in ipairs(decl.params) do
        params[#params + 1] = (p.name or "?") .. ": " .. fmt_type(p.type_expr)
      end
      buf.line("params: " .. table.concat(params, ", "))
    end
    fmt_stmts(buf, decl.body)
    buf.pop()

  elseif k == K.SCENE_DECL then
    buf.ind(); buf.emit("scene " .. (decl.name or "?") .. ":"); buf.nl()
    buf.push()
    -- Emit scene body items: narration text, conditions, choices
    for _, item in ipairs(decl.body or {}) do
      if type(item) == "string" then
        buf.line(item)
      elseif type(item) == "table" then
        local ik = item.kind
        if ik == "narration_line" then
          buf.line(render_text_segments(item.text or ""))
        elseif ik == "narration" or ik == "text" then
          buf.line(render_text_segments(item.text or ""))
        elseif ik == "cond_narration" then
          -- [condition] Narration text
          buf.ind()
          buf.emit("[" .. fmt_expr(item.condition) .. "] ")
          buf.emit(render_text_segments(item.text or ""))
          buf.nl()
        elseif ik == "if_narration" then
          buf.ind(); buf.emit("if " .. fmt_expr(item.cond) .. ":"); buf.nl()
          buf.push()
          if item.then_body then
            for _, t in ipairs(item.then_body) do
              if type(t) == "string" then
                buf.line(t)
              elseif type(t) == "table" and t.kind == "narration_line" then
                buf.line(render_text_segments(t.text or ""))
              else
                fmt_stmt(buf, t)
              end
            end
          end
          buf.pop()
          if item.else_body and #item.else_body > 0 then
            buf.line("else:")
            buf.push()
            for _, t in ipairs(item.else_body) do
              if type(t) == "string" then
                buf.line(t)
              elseif type(t) == "table" and t.kind == "narration_line" then
                buf.line(render_text_segments(t.text or ""))
              else
                fmt_stmt(buf, t)
              end
            end
            buf.pop()
          end
        elseif ik == "choice" then
          local guard_s = ""
          if item.guard then guard_s = "[" .. fmt_expr(item.guard) .. "] " end
          local label_s = render_text_segments(item.label or "")
          buf.ind(); buf.emit("* " .. guard_s .. label_s); buf.nl()
          buf.push()
          fmt_stmts(buf, item.body)
          buf.pop()
        elseif ik == K.WHEN_STMT then
          buf.ind(); buf.emit("when " .. fmt_expr(item.cond) .. ":"); buf.nl()
          buf.push()
          for _, t in ipairs(item.body or {}) do
            if type(t) == "table" and t.kind == "narration_line" then
              buf.line(render_text_segments(t.text or ""))
            else
              fmt_stmt(buf, t)
            end
          end
          buf.pop()
        else
          fmt_stmt(buf, item)
        end
      end
    end
    buf.pop()

  elseif k == K.ACTOR_DECL then
    buf.ind(); buf.emit("actor " .. (decl.name or "?") .. ":"); buf.nl()
    buf.push()
    if decl.state_path then buf.line("state: " .. fmt_expr(decl.state_path)) end
    if decl.perceives and #decl.perceives > 0 then
      local pp = {}
      for _, p in ipairs(decl.perceives) do pp[#pp + 1] = fmt_expr(p) end
      buf.line("perceives: [" .. table.concat(pp, ", ") .. "]")
    end
    if decl.inbox_type then buf.line("inbox: " .. fmt_type(decl.inbox_type)) end
    if decl.behavior   then buf.line("behavior: " .. decl.behavior) end
    if decl.priority   then buf.line("priority: " .. tostring(decl.priority)) end
    buf.pop()

  elseif k == K.SCHEDULE_DECL then
    buf.ind(); buf.emit("schedule " .. (decl.name or "?") .. ":"); buf.nl()
    buf.push()
    local trig = decl.trigger or {}
    if trig.every and #trig.every > 0 then
      local axes = {}
      for _, e in ipairs(trig.every) do
        axes[#axes + 1] = e.axis .. ": +" .. tostring(e.value)
      end
      buf.line("every: [" .. table.concat(axes, ", ") .. "]")
    end
    if trig.at and #trig.at > 0 then
      local axes = {}
      for _, e in ipairs(trig.at) do
        axes[#axes + 1] = e.axis .. ": +" .. tostring(e.value)
      end
      buf.line("at: [" .. table.concat(axes, ", ") .. "]")
    end
    if trig.offset and #trig.offset > 0 then
      local axes = {}
      for _, e in ipairs(trig.offset) do
        axes[#axes + 1] = e.axis .. ": " .. tostring(e.value)
      end
      buf.line("offset: [" .. table.concat(axes, ", ") .. "]")
    end
    if decl.body and #decl.body > 0 then
      buf.line("fn:")
      buf.push()
      fmt_stmts(buf, decl.body)
      buf.pop()
    end
    buf.pop()

  elseif k == K.VERIFY_DECL then
    buf.ind(); buf.emit("verify " .. (decl.name or "?") .. ":"); buf.nl()
    buf.push()
    for _, clause in ipairs(decl.clauses or {}) do
      local ck = clause.kind
      if ck == "always" then
        buf.line("always: " .. fmt_expr(clause.condition))
      elseif ck == "after" then
        buf.ind()
        buf.emit("after " .. (clause.fn or "?"))
        if clause.args and #clause.args > 0 then
          local aa = {}
          for _, a in ipairs(clause.args) do aa[#aa + 1] = fmt_expr(a) end
          buf.emit(" " .. table.concat(aa, " "))
        end
        buf.emit(":"); buf.nl()
        buf.push()
        fmt_stmts(buf, clause.body)
        buf.pop()
      elseif ck == "requires" then
        buf.line("requires: " .. fmt_expr(clause.condition))
      else
        buf.line("-- (clause:" .. tostring(ck) .. ")")
      end
    end
    buf.pop()

  elseif k == K.WATCH_DECL then
    buf.line("watch " .. fmt_expr(decl.path) .. " \"" .. (decl.label or "") .. "\"")

  elseif k == K.WATCH_WHEN_DECL then
    buf.line("watch-when " .. fmt_expr(decl.cond) .. " \"" .. (decl.label or "") .. "\"")

  elseif k == K.BOUNDED_DECL then
    buf.ind(); buf.emit("bounded " .. (decl.name or "?") .. ":"); buf.nl()
    buf.push()
    if decl.reads and #decl.reads > 0 then
      local rr = {}
      for _, r in ipairs(decl.reads) do rr[#rr + 1] = fmt_expr(r) end
      buf.line("reads: [" .. table.concat(rr, ", ") .. "]")
    end
    if decl.distribution then buf.line("distribution: " .. decl.distribution) end
    if decl.returns_type  then buf.line("returns: " .. fmt_type(decl.returns_type)) end
    buf.pop()

  elseif k == K.MIGRATION_DECL then
    buf.ind()
    buf.emit("migration " .. tostring(decl.from_version or "?")
             .. " -> " .. tostring(decl.to_version or "?") .. ":")
    buf.nl()
    buf.push()
    fmt_stmts(buf, decl.body)
    buf.pop()

  elseif k == K.DEFGRID_DECL then
    buf.ind()
    buf.emit("defgrid " .. (decl.name or "?"))
    if decl.width and decl.height then
      buf.emit(string.format(" %d %d", decl.width, decl.height))
    end
    buf.emit(":"); buf.nl()
    -- grid rows
    buf.push()
    for _, row in ipairs(decl.rows or {}) do
      buf.line(row)
    end
    buf.pop()

  elseif k == K.TAG_DECL then
    buf.line("tag " .. (decl.name or "?"))

  elseif k == K.HOOK_DECL then
    buf.ind()
    buf.emit("hook " .. (decl.tag or "?") .. ":")
    buf.nl()
    buf.push()
    if decl.when == "pre" then buf.line("pre:") end
    if decl.when == "post" then buf.line("post:") end
    buf.push()
    fmt_stmts(buf, decl.body)
    buf.pop(); buf.pop()

  else
    -- Unknown declaration kind: emit a comment so we don't silently lose it
    buf.line("-- (decl:" .. tostring(k) .. ")")
  end
end

-- ============================================================
-- Top-level formatter
-- ============================================================

--- Format a parsed AST into a canonical source string.
---@param ast_root table  PROGRAM node with .decls
---@return string
local function format_ast(ast_root)
  local buf = new_buf()
  local prev_kind = nil

  for _, decl in ipairs(ast_root.decls or {}) do
    -- Blank line between top-level declarations (except first)
    if prev_kind ~= nil then
      buf.blank()
    end
    fmt_decl(buf, decl)
    prev_kind = decl.kind
  end

  -- Ensure trailing newline
  local out = buf.result()
  if out ~= "" and out:sub(-1) ~= "\n" then
    out = out .. "\n"
  end
  return out
end

-- ============================================================
-- Argument parsing
-- ============================================================

local BOOL_FLAGS = { check = true, write = true }

local function parse_args(args)
  local flags, positional = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      local key = a:sub(3)
      if BOOL_FLAGS[key] then
        flags[key] = true; i = i + 1
      elseif args[i + 1] and args[i + 1]:sub(1, 2) ~= "--" then
        flags[key] = args[i + 1]; i = i + 2
      else
        flags[key] = true; i = i + 1
      end
    else
      positional[#positional + 1] = a; i = i + 1
    end
  end
  return flags, positional
end

-- ============================================================
-- Entry point
-- ============================================================

--- Run the format subcommand.
---@param args table  argument list (without the leading "format")
---@return integer    exit code
function M.run(args)
  local flags, pos_args = parse_args(args)
  local filepath = pos_args[1]
  if not filepath then
    io.stderr:write("error: storybase format: no input file\n")
    return 1
  end

  local ok_c, compiler = pcall(require, "compiler.compiler")
  if not ok_c then
    io.stderr:write("error: could not load compiler: " .. tostring(compiler) .. "\n")
    return 1
  end

  -- We only need the parsed AST (not full compilation)
  local f, ferr = io.open(filepath, "r")
  if not f then
    io.stderr:write("error: cannot open '" .. filepath .. "': " .. tostring(ferr) .. "\n")
    return 1
  end
  local source = f:read("*a"); f:close()

  local lexer  = require("compiler.lexer")
  local parser = require("compiler.parser")

  -- Helper: count errors in a plain diag array
  local function has_errors(diag_list)
    for _, d in ipairs(diag_list or {}) do
      if d.level == "error" then return true end
    end
    return false
  end

  local tokens, ld = lexer.tokenize(source, filepath)
  if not tokens or has_errors(ld) then
    io.stderr:write("error: cannot format '" .. filepath .. "': lex errors\n")
    return 1
  end

  local ast_root, pd = parser.parse(tokens, filepath)
  if not ast_root or has_errors(pd) then
    io.stderr:write("error: cannot format '" .. filepath .. "': parse errors\n")
    return 1
  end

  local formatted = format_ast(ast_root)

  if flags["check"] then
    -- Check mode: compare original with formatted
    if source == formatted then
      io.stdout:write("ok\n")
      return 0
    else
      io.stderr:write(filepath .. ": not in canonical format\n")
      return 1
    end
  elseif flags["write"] then
    -- Write mode: rewrite file in-place with backup
    local bak_path = filepath .. ".bak"
    local bf, berr = io.open(bak_path, "w")
    if not bf then
      io.stderr:write("error: cannot write backup '" .. bak_path
                      .. "': " .. tostring(berr) .. "\n")
      return 1
    end
    bf:write(source); bf:close()
    local wf, werr = io.open(filepath, "w")
    if not wf then
      io.stderr:write("error: cannot write '" .. filepath
                      .. "': " .. tostring(werr) .. "\n")
      return 1
    end
    wf:write(formatted); wf:close()
    io.stdout:write("formatted " .. filepath .. " (backup: " .. bak_path .. ")\n")
    return 0
  else
    -- Default: write to stdout
    io.stdout:write(formatted)
    return 0
  end
end

return M

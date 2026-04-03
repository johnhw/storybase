-- compiler/parser.lua
-- Parse a token stream into an untyped AST.
--
-- Phase 1: module, import, schema-version, engine-config, time-model,
--          type (enum/alias/record/variant), state (scalar/record/family),
--          relation declarations.
-- Phase 2 will extend this with expression and statement forms.

local M = {}

local ast = require("compiler.ast")

-- ============================================================
-- Parser state
-- ============================================================

local parser = {}
parser.__index = parser

local function new_parser(tokens, filename)
  return setmetatable({
    tokens   = tokens,
    pos      = 1,
    filename = filename,
    diags    = {},
  }, parser)
end

function parser:cur()
  local t = self.tokens[self.pos]
  if t then return t end
  local last = self.tokens[#self.tokens]
  local p = last and last.pos or ast.pos(self.filename, 1, 1)
  return { kind = "EOF", value = nil, pos = p }
end

function parser:peek(n)
  local t = self.tokens[self.pos + (n or 1)]
  if t then return t end
  local last = self.tokens[#self.tokens]
  local p = last and last.pos or ast.pos(self.filename, 1, 1)
  return { kind = "EOF", value = nil, pos = p }
end

function parser:adv()
  local t = self:cur()
  if self.pos <= #self.tokens then self.pos = self.pos + 1 end
  return t
end

function parser:skip_newlines()
  while self:cur().kind == "NEWLINE" do self:adv() end
end

function parser:at(kind, value)
  local t = self:cur()
  if t.kind ~= kind then return false end
  if value ~= nil and t.value ~= value then return false end
  return true
end

function parser:match(kind, value)
  if self:at(kind, value) then return self:adv() end
  return nil
end

function parser:expect(kind, value, msg)
  if self:at(kind, value) then return self:adv() end
  local t = self:cur()
  local desc = value ~= nil and (kind .. " '" .. tostring(value) .. "'") or kind
  self:emit_err(ast.E.EXPECTED_TOKEN, msg or ("expected " .. desc), t.pos)
  return nil
end

function parser:emit_err(code, msg, pos, note)
  table.insert(self.diags, ast.error(code, msg, pos or self:cur().pos, note))
end

--- Advance to end of current logical line (error recovery).
function parser:skip_to_eol()
  while not self:at("NEWLINE") and not self:at("DEDENT") and not self:at("EOF") do
    self:adv()
  end
  self:match("NEWLINE")
end

--- Skip an entire INDENT...DEDENT block (error recovery).
function parser:skip_block()
  if not self:at("INDENT") then return end
  self:adv()
  local depth = 1
  while depth > 0 and not self:at("EOF") do
    if self:at("INDENT") then depth = depth + 1
    elseif self:at("DEDENT") then depth = depth - 1
    end
    self:adv()
  end
end

--- Parse an indented block, calling parse_fn(self) for each item.
--- Returns a list of non-nil results. Consumes the final DEDENT.
function parser:parse_block(parse_fn)
  self:skip_newlines()
  if not self:at("INDENT") then
    self:emit_err(ast.E.EXPECTED_TOKEN, "expected indented block")
    return {}
  end
  self:adv()  -- consume INDENT
  local items = {}
  while not self:at("DEDENT") and not self:at("EOF") do
    self:skip_newlines()
    if self:at("DEDENT") or self:at("EOF") then break end
    local item = parse_fn(self)
    if item then table.insert(items, item) end
  end
  if self:at("DEDENT") then self:adv() end
  return items
end

-- ============================================================
-- Path helpers
-- ============================================================

local function split_path(val)
  local segs = {}
  for seg in val:gmatch("[^/]+") do
    table.insert(segs, seg)
  end
  return segs
end

local function split_interp_path(val)
  local segs = {}
  for seg in val:gmatch("[^/]+") do
    local var = seg:match("^{(.+)}$")
    table.insert(segs, var and { interp = var } or seg)
  end
  return segs
end

-- ============================================================
-- Type expression parser
-- ============================================================

local function parse_type_expr(p)
  local t = p:cur()
  local tpos = t.pos

  if t.kind == "IDENT" then
    local name = t.value
    p:adv()

    if name == "Bool" then
      return ast.type_bool(tpos)

    elseif name == "Int" then
      p:expect("OP", "(")
      local lo = p:expect("INTEGER", nil, "expected min bound")
      p:expect("OP", ",")
      local hi = p:expect("INTEGER", nil, "expected max bound")
      p:expect("OP", ")")
      return ast.type_int(lo and lo.value or 0, hi and hi.value or 0, tpos)

    elseif name == "Enum" then
      p:expect("OP", "(")
      local values = {}
      while not p:at("OP", ")") and not p:at("EOF")
            and not p:at("NEWLINE") and not p:at("DEDENT") do
        local v = p:match("IDENT")
        if v then table.insert(values, v.value) end
        p:match("OP", ",")
      end
      p:expect("OP", ")")
      return ast.type_enum_inline(values, tpos)

    elseif name == "Option" then
      p:expect("OP", "(")
      local inner = parse_type_expr(p)
      p:expect("OP", ")")
      return ast.type_option(inner, tpos)

    elseif name == "Set" then
      p:expect("OP", "(")
      local inner = parse_type_expr(p)
      p:expect("OP", ",")
      local mx = p:expect("INTEGER", nil, "expected max bound")
      p:expect("OP", ")")
      return ast.type_set(inner, mx and mx.value or 0, tpos)

    elseif name == "List" then
      p:expect("OP", "(")
      local inner = parse_type_expr(p)
      p:expect("OP", ",")
      local mx = p:expect("INTEGER", nil, "expected max bound")
      p:expect("OP", ")")
      return ast.type_list(inner, mx and mx.value or 0, tpos)

    elseif name == "Symbol" then
      return ast.type_symbol(tpos)

    elseif name == "SymbolOf" then
      p:expect("OP", "(")
      local fam = p:expect("IDENT", nil, "expected family name")
      p:expect("OP", ")")
      return ast.type_symbol_of(fam and fam.value or "?", tpos)

    elseif name == "String" then
      return ast.type_string(tpos)

    elseif name == "Float" then
      return ast.type_float(tpos)

    elseif name == "UList" then
      p:expect("OP", "(")
      local inner = parse_type_expr(p)
      p:expect("OP", ")")
      return ast.type_ulist(inner, tpos)

    elseif name == "UMap" then
      p:expect("OP", "(")
      local k = parse_type_expr(p)
      p:expect("OP", ",")
      local v = parse_type_expr(p)
      p:expect("OP", ")")
      return ast.type_umap(k, v, tpos)

    else
      return ast.type_named(name, tpos)
    end

  elseif t.kind == "OP" and t.value == "(" then
    -- Function type: (T U -> R)
    p:adv()
    local params = {}
    while not p:at("OP", "->") and not p:at("OP", ")")
          and not p:at("EOF") and not p:at("NEWLINE") do
      local pt = parse_type_expr(p)
      if pt then table.insert(params, pt) end
    end
    p:expect("OP", "->", "expected '->' in function type")
    local ret = parse_type_expr(p)
    p:expect("OP", ")")
    return ast.type_fn(params, ret, tpos)
  end

  p:emit_err(ast.E.BAD_TYPE_EXPR, "expected type expression", tpos)
  return nil
end

-- ============================================================
-- Default value parser
-- ============================================================

local parse_default_value  -- forward declaration

local function parse_record_constructor(p, type_name, tpos)
  p:adv()  -- consume "("
  local fields = {}
  -- Inside parens the lexer suppresses INDENT/DEDENT; skip newlines freely.
  p:skip_newlines()
  while not p:at("OP", ")") and not p:at("EOF") and not p:at("DEDENT") do
    if p:at("NAMED_ARG") then
      local fname = p:adv()
      local val = parse_default_value(p)
      table.insert(fields, ast.named_arg(fname.value, val, fname.pos))
    else
      p:adv()  -- skip unexpected token
    end
    p:match("OP", ",")
    p:skip_newlines()  -- allow newlines between fields
  end
  p:expect("OP", ")")
  return ast.node(ast.K.RECORD_CONSTRUCTOR, { type_name = type_name, fields = fields }, tpos)
end

parse_default_value = function(p)
  local t = p:cur()
  local tpos = t.pos

  if t.kind == "INTEGER"          then p:adv(); return ast.int_lit(t.value, tpos)
  elseif t.kind == "FLOAT"        then p:adv(); return ast.float_lit(t.value, tpos)
  elseif t.kind == "BOOL"         then p:adv(); return ast.bool_lit(t.value, tpos)
  elseif t.kind == "STRING"       then p:adv(); return ast.string_lit(t.value, tpos)
  elseif t.kind == "MULTILINE_STRING" then p:adv(); return ast.multiline_string(t.value, tpos)
  elseif t.kind == "SYMBOL"       then p:adv(); return ast.symbol_lit(t.value, tpos)
  elseif t.kind == "IDENT" then
    local name = t.value
    p:adv()
    if p:at("OP", "(") then
      return parse_record_constructor(p, name, tpos)
    end
    return ast.type_named(name, tpos)

  elseif t.kind == "OP" and t.value == "(" then
    p:adv()
    if p:at("IDENT", "set") then
      p:adv()
      p:expect("OP", ")")
      return ast.node(ast.K.EMPTY_SET, {}, tpos)
    end
    -- unknown paren expr — skip to matching ")"
    local depth = 1
    while depth > 0 and not p:at("EOF") do
      if p:at("OP", "(") then depth = depth + 1
      elseif p:at("OP", ")") then depth = depth - 1
      end
      if depth > 0 then p:adv() end
    end
    p:match("OP", ")")
    return nil

  elseif t.kind == "OP" and t.value == "[" then
    p:adv()
    if p:at("OP", "]") then
      p:adv()
      return ast.node(ast.K.EMPTY_LIST, {}, tpos)
    end
    -- skip non-empty list
    local depth = 1
    while depth > 0 and not p:at("EOF") do
      if p:at("OP", "[") then depth = depth + 1
      elseif p:at("OP", "]") then depth = depth - 1
      end
      if depth > 0 then p:adv() end
    end
    p:match("OP", "]")
    return nil
  end

  return nil
end

-- ============================================================
-- Declaration parsers
-- ============================================================

--- module name
---   version: N
local function parse_module_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume "module"
  local name_t = p:expect("IDENT", nil, "expected module name")
  local name = name_t and name_t.value or "?"
  local version = nil

  p:skip_newlines()
  if p:at("INDENT") then
    p:adv()
    while not p:at("DEDENT") and not p:at("EOF") do
      p:skip_newlines()
      if p:at("DEDENT") or p:at("EOF") then break end
      if p:at("NAMED_ARG", "version") then
        p:adv()
        local v = p:match("INTEGER") or p:match("FLOAT")
        if v then version = v.value end
        p:skip_to_eol()
      else
        p:skip_to_eol()
      end
    end
    if p:at("DEDENT") then p:adv() end
  end

  return ast.module_decl(name, version, tpos)
end

--- import "path"  /  import "path" as Alias
local function parse_import_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume "import"
  local path_t = p:expect("STRING", nil, "expected import path string")
  local path = path_t and path_t.value or ""
  local alias = nil

  if p:at("IDENT", "as") then
    p:adv()
    local alias_t = p:expect("IDENT", nil, "expected alias after 'as'")
    alias = alias_t and alias_t.value or nil
  end
  p:skip_to_eol()
  return ast.import_decl(path, alias, tpos)
end

--- schema-version: N
local function parse_schema_version(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume NAMED_ARG("schema-version")
  local v_t = p:expect("INTEGER", nil, "expected schema version number")
  p:skip_to_eol()
  return ast.schema_version(v_t and v_t.value or 0, tpos)
end

--- engine-config:\n  key: value ...
local function parse_engine_config(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume NAMED_ARG("engine-config")
  local keys = {}
  p:parse_block(function(self)
    if not self:at("NAMED_ARG") then self:skip_to_eol(); return nil end
    local k = self:adv()
    local v
    if     self:at("INTEGER") then v = self:adv().value
    elseif self:at("FLOAT")   then v = self:adv().value
    elseif self:at("BOOL")    then v = self:adv().value
    elseif self:at("IDENT")   then v = self:adv().value
    elseif self:at("STRING")  then v = self:adv().value
    end
    table.insert(keys, { key = k.value, value = v })
    self:skip_to_eol()
    return true  -- sentinel so parse_block knows the line was consumed
  end)
  return ast.engine_config(keys, tpos)
end

--- time-model:\n  axes: [name,...]\n  wrap: [none/N,...]
local function parse_time_model(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume NAMED_ARG("time-model")
  local axes, wrap = {}, {}
  p:parse_block(function(self)
    if self:at("NAMED_ARG", "axes") then
      self:adv()
      self:expect("OP", "[")
      while not self:at("OP", "]") and not self:at("EOF") and not self:at("NEWLINE") do
        local v = self:match("IDENT")
        if v then table.insert(axes, v.value) end
        self:match("OP", ",")
      end
      self:expect("OP", "]")
    elseif self:at("NAMED_ARG", "wrap") then
      self:adv()
      self:expect("OP", "[")
      while not self:at("OP", "]") and not self:at("EOF") and not self:at("NEWLINE") do
        if self:at("IDENT", "none") then
          self:adv(); table.insert(wrap, "none")
        elseif self:at("INTEGER") then
          table.insert(wrap, self:adv().value)
        else
          self:adv()
        end
        self:match("OP", ",")
      end
      self:expect("OP", "]")
    end
    self:skip_to_eol()
    return true
  end)
  return ast.time_model(axes, wrap, tpos)
end

--- Parse the body of a record or variant block (shared logic).
--- Returns a list of record_field / with_mixin / variant_branch nodes.
local function parse_type_body(p)
  return p:parse_block(function(self)
    self:skip_newlines()
    if self:at("DEDENT") or self:at("EOF") then return nil end

    if self:at("KEYWORD", "with") then
      local wpos = self:cur().pos
      self:adv()
      local tn = self:expect("IDENT", nil, "expected mixin type name")
      self:skip_to_eol()
      return ast.with_mixin(tn and tn.value or "?", wpos)

    elseif self:at("OP", "|") then
      local bpos = self:cur().pos
      self:adv()  -- consume "|"
      if not self:at("NAMED_ARG") then
        self:emit_err(ast.E.BAD_DECLARATION, "expected branch name after '|'")
        self:skip_to_eol()
        return nil
      end
      local bname = self:adv()
      local fields = {}
      while self:at("NAMED_ARG") do
        local fname = self:adv()
        local ftype = parse_type_expr(self)
        table.insert(fields, ast.record_field(fname.value, ftype, nil, nil, fname.pos))
        self:match("OP", ",")
      end
      self:skip_to_eol()
      return ast.variant_branch(bname.value, fields, bpos)

    elseif self:at("NAMED_ARG") then
      local fname = self:adv()
      local ftype = parse_type_expr(self)
      local fdefault = nil
      if self:at("OP", "=") then
        self:adv()
        fdefault = parse_default_value(self)
      end
      self:skip_to_eol()
      return ast.record_field(fname.value, ftype, fdefault, nil, fname.pos)

    else
      self:emit_err(ast.E.BAD_DECLARATION,
        "unexpected token in type body: " .. self:cur().kind)
      self:skip_to_eol()
      return nil
    end
  end)
end

--- type Name = val | val   (enum)
--- type Name = TypeExpr    (alias)
--- type Name:              (record or variant)
local function parse_type_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume "type"

  local name
  local block_style = false

  if p:at("NAMED_ARG") then
    -- type Name:  (no space before colon)
    name = p:adv().value
    block_style = true
  elseif p:at("IDENT") then
    name = p:adv().value
    if p:at("OP", ":") then
      p:adv()  -- consume ":"
      block_style = true
    elseif p:at("OP", "=") then
      p:adv()  -- consume "="
    else
      p:emit_err(ast.E.BAD_DECLARATION,
        "expected '=' or ':' after type name '" .. name .. "'")
      p:skip_to_eol()
      return nil
    end
  else
    p:emit_err(ast.E.BAD_DECLARATION, "expected type name after 'type'")
    p:skip_to_eol()
    return nil
  end

  if block_style then
    local items = parse_type_body(p)
    local has_variant = false
    for _, item in ipairs(items) do
      if item.kind == ast.K.VARIANT_BRANCH then has_variant = true; break end
    end
    if has_variant then
      return ast.type_variant(name, items, doc, tpos)
    else
      return ast.type_record(name, items, doc, tpos)
    end
  end

  -- "=" form: decide enum vs alias by scanning for "|" on this line
  local is_enum = false
  if p:at("IDENT") then
    local i = p.pos
    while true do
      local tok = p.tokens[i]
      if not tok then break end
      local k = tok.kind
      if k == "NEWLINE" or k == "DEDENT" or k == "EOF" then break end
      if k == "OP" and tok.value == "|" then is_enum = true; break end
      i = i + 1
    end
  end

  if is_enum then
    local values = {}
    local v = p:match("IDENT")
    if v then table.insert(values, v.value) end
    while p:at("OP", "|") do
      p:adv()
      local v2 = p:expect("IDENT", nil, "expected enum value after '|'")
      if v2 then table.insert(values, v2.value) end
    end
    p:skip_to_eol()
    return ast.type_enum(name, values, doc, tpos)
  else
    local texpr = parse_type_expr(p)
    p:skip_to_eol()
    return ast.type_alias(name, texpr, doc, tpos)
  end
end

--- state path: Type [= default]      (scalar)
--- state path:                       (inline record)
--- state family/{var}: Type max: N   (family)
local function parse_state_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume "state"

  local t = p:cur()
  local path_kind, path_val, path_pos

  if t.kind == "NAMED_ARG" then
    path_kind, path_val, path_pos = "simple", t.value, t.pos
    p:adv()
  elseif t.kind == "PATH" then
    path_kind, path_val, path_pos = "path", t.value, t.pos
    p:adv()
    p:expect("OP", ":", "expected ':' after path")
  elseif t.kind == "INTERP_PATH" then
    path_kind, path_val, path_pos = "interp", t.value, t.pos
    p:adv()
    p:expect("OP", ":", "expected ':' after path")
  elseif t.kind == "IDENT" then
    path_kind, path_val, path_pos = "simple", t.value, t.pos
    p:adv()
    p:expect("OP", ":", "expected ':' after state name")
  else
    p:emit_err(ast.E.BAD_DECLARATION, "expected state path")
    p:skip_to_eol()
    return nil
  end

  local path_node
  if path_kind == "simple" then
    path_node = ast.path_expr({ path_val }, path_pos)
  elseif path_kind == "path" then
    path_node = ast.path_expr(split_path(path_val), path_pos)
  else
    path_node = ast.interp_path(split_interp_path(path_val), path_pos)
  end

  -- Check for inline record block
  p:skip_newlines()
  if p:at("INDENT") then
    local fields = p:parse_block(function(self)
      self:skip_newlines()
      if self:at("DEDENT") or self:at("EOF") then return nil end
      if not self:at("NAMED_ARG") then
        self:skip_to_eol(); return nil
      end
      local fname = self:adv()
      local ftype = parse_type_expr(self)
      local fdefault = nil
      if self:at("OP", "=") then
        self:adv()
        fdefault = parse_default_value(self)
      end
      self:skip_to_eol()
      return ast.record_field(fname.value, ftype, fdefault, nil, fname.pos)
    end)
    return ast.state_record(path_node, fields, doc, tpos)
  end

  -- Scalar or family
  local texpr = parse_type_expr(p)
  local max_val = nil
  local default = nil

  if p:at("NAMED_ARG", "max") then
    p:adv()
    local mx = p:expect("INTEGER", nil, "expected max count")
    max_val = mx and mx.value or 0
  end

  if p:at("OP", "=") then
    p:adv()
    default = parse_default_value(p)
  end

  p:skip_to_eol()

  if path_kind == "interp" then
    local segs = split_interp_path(path_val)
    local family = type(segs[1]) == "string" and segs[1] or "?"
    local var = nil
    for _, seg in ipairs(segs) do
      if type(seg) == "table" and seg.interp then var = seg.interp; break end
    end
    return ast.state_family(family, var, texpr, max_val, doc, tpos)
  else
    return ast.state_scalar(path_node, texpr, default, doc, tpos)
  end
end

--- relation name: FromType -> ToTypeExpr [:  static data block ]
local function parse_relation_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume "relation"

  local name
  if p:at("NAMED_ARG") then
    name = p:adv().value
  elseif p:at("IDENT") then
    name = p:adv().value
    p:expect("OP", ":")
  else
    p:emit_err(ast.E.BAD_DECLARATION, "expected relation name")
    p:skip_to_eol()
    return nil
  end

  local from_t = p:expect("IDENT", nil, "expected from-type in relation")
  local from_type = from_t and from_t.value or "?"

  p:expect("OP", "->", "expected '->' in relation declaration")
  local to_type = parse_type_expr(p)

  local initial_data = {}
  if p:at("OP", ":") then
    p:adv()
    initial_data = p:parse_block(function(self)
      self:skip_newlines()
      if self:at("DEDENT") or self:at("EOF") then return nil end
      local kpos = self:cur().pos
      local key
      if self:at("SYMBOL") then
        key = ast.symbol_lit(self:adv().value, kpos)
      elseif self:at("IDENT") then
        key = ast.type_named(self:adv().value, kpos)
      else
        self:skip_to_eol(); return nil
      end
      self:expect("OP", ":", "expected ':' after relation key")
      self:skip_to_eol()
      return { key = key, values = {} }
    end)
  else
    p:skip_to_eol()
  end

  return ast.relation_decl(name, from_type, to_type, initial_data, doc, tpos)
end

-- ============================================================
-- Phase 2 — Expressions, statements, fn/scene declarations
-- ============================================================

-- Convert "player/health" PATH token string → path_expr node
local function make_path_expr(path_str, pos)
  local segs = {}
  for seg in path_str:gmatch("[^/]+") do table.insert(segs, seg) end
  return ast.path_expr(segs, pos)
end

-- Convert "npcs/{npc}/hp" INTERP_PATH token string → interp_path node
local function make_interp_path(path_str, pos)
  local segs = {}
  for seg in path_str:gmatch("[^/]+") do
    if seg:sub(1,1) == '{' then
      table.insert(segs, { interp = seg:sub(2, -2) })
    else
      table.insert(segs, seg)
    end
  end
  return ast.interp_path(segs, pos)
end

-- Can the next token begin an argument atom (for function application)?
local function can_start_arg(p)
  local t = p:cur()
  local k = t.kind
  return k == "INTEGER" or k == "FLOAT" or k == "BOOL"
      or k == "STRING"  or k == "MULTILINE_STRING"
      or k == "SYMBOL"  or k == "PATH" or k == "INTERP_PATH"
      or k == "IDENT"
      or (k == "OP" and (t.value == "(" or t.value == "["))
end

-- Forward declarations (mutual recursion)
local parse_expr, parse_stmt, parse_body_items

-- ── Atom (no application argument collection) ──────────────────────────────
-- Used for collecting function-call arguments so we don't recurse infinitely.
local function parse_atom(p)
  local t = p:cur()
  local tpos = t.pos

  if t.kind == "INTEGER" then
    p:adv(); return ast.int_lit(t.value, tpos)
  elseif t.kind == "FLOAT" then
    p:adv(); return ast.float_lit(t.value, tpos)
  elseif t.kind == "BOOL" then
    p:adv(); return ast.bool_lit(t.value, tpos)
  elseif t.kind == "STRING" then
    p:adv(); return ast.string_lit(t.value, tpos)
  elseif t.kind == "MULTILINE_STRING" then
    p:adv(); return ast.multiline_string(t.value, tpos)
  elseif t.kind == "SYMBOL" then
    p:adv(); return ast.symbol_lit(t.value, tpos)
  elseif t.kind == "PATH" then
    p:adv()
    local path_node = make_path_expr(t.value, tpos)
    -- Check for path@before suffix
    if p:at("OP", "@") then
      local nx = p:peek()
      if nx and nx.kind == "IDENT" and nx.value == "before" then
        p:adv()  -- consume "@"
        p:adv()  -- consume "before"
        return ast.path_at_before(path_node, tpos)
      end
    end
    return path_node
  elseif t.kind == "INTERP_PATH" then
    p:adv(); return make_interp_path(t.value, tpos)
  elseif t.kind == "IDENT" then
    -- 0-arg function call (no further argument collection in atom context)
    p:adv(); return ast.fn_call(t.value, {}, tpos)
  elseif t.kind == "OP" and t.value == "(" then
    p:adv()
    -- (set) → empty set literal
    if p:at("IDENT", "set") and p:peek().kind == "OP" and p:peek().value == ")" then
      p:adv(); p:adv()
      return ast.empty_set(tpos)
    end
    -- (TypeName/variant-name field: val, ...) → variant record constructor
    -- e.g. (ActorMsg/alert threat: 'wanderer, location: player/location)
    if p:at("PATH") then
      local path_tok = p:cur()
      local next2 = p:peek()
      if next2 and (next2.kind == "NAMED_ARG" or (next2.kind == "OP" and next2.value == ")")) then
        local ctor_name = path_tok.value
        p:adv()  -- consume PATH token
        local fields = {}
        while p:at("NAMED_ARG") do
          local nt = p:adv()
          local val = parse_expr(p)
          fields[#fields + 1] = ast.named_arg(nt.value, val, nt.pos)
          p:match("OP", ",")
          p:skip_newlines()
        end
        p:expect("OP", ")", "expected ')' to close record constructor")
        return ast.record_constructor(ctor_name, fields, tpos)
      end
    end
    local e = parse_expr(p)
    p:expect("OP", ")", "expected ')'")
    return e
  elseif t.kind == "OP" and t.value == "[" then
    p:adv()
    if p:at("OP", "]") then p:adv(); return ast.empty_list(tpos) end
    local elems = {}
    while not p:at("OP", "]") and not p:at("NEWLINE") and not p:at("EOF") do
      table.insert(elems, parse_expr(p))
      if not p:match("OP", ",") then break end
    end
    p:expect("OP", "]", "expected ']' to close list literal")
    return ast.list_lit(elems, tpos)
  end
  return nil
end

-- ── Match / cond / if expressions (forward-declared bodies) ────────────────

local function parse_match_expr(p)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "match"
  -- The lexer tokenises bare 'name:' as NAMED_ARG; handle that case so
  -- `match foo:` works even when `foo` is a simple identifier.
  local subject
  if p:at("NAMED_ARG") then
    local nt = p:adv()
    subject = ast.fn_call(nt.value, {}, nt.pos)
    -- colon was already consumed as part of the NAMED_ARG token
  else
    subject = parse_expr(p)
    p:expect("OP", ":", "expected ':' after match expression")
  end
  p:match("NEWLINE")
  local arms = {}
  p:skip_newlines()
  -- Parse arms: either inside an INDENT block, or inline (paren context, no INDENT/DEDENT)
  local in_indent = p:at("INDENT")
  if in_indent then p:adv() end
  while true do
    p:skip_newlines()
    -- Stop conditions
    if p:at("EOF") then break end
    if in_indent and p:at("DEDENT") then break end
    if p:at("OP", ")") then break end
    -- Try to parse an arm pattern
    local apos = p:cur().pos
    local pattern
    local colon_consumed = false
    if p:at("NAMED_ARG", "_") then
      p:adv(); pattern = "_"; colon_consumed = true
    elseif p:at("NAMED_ARG") then
      local nt = p:adv()
      pattern = ast.fn_call(nt.value, {}, nt.pos); colon_consumed = true
    elseif p:at("SYMBOL") then
      local s = p:adv(); pattern = ast.symbol_lit(s.value, s.pos)
    elseif p:at("IDENT", "_") then
      pattern = "_"; p:adv()
    elseif p:at("BOOL") then
      local b = p:adv(); pattern = ast.bool_lit(b.value, b.pos)
    elseif p:at("INTEGER") then
      local n = p:adv(); pattern = ast.int_lit(n.value, n.pos)
    elseif p:at("IDENT") then
      -- Variant destructuring pattern: variant-name {field1, field2}:
      -- e.g.  trade-offer {item, price}:
      local ident_tok = p:adv()
      local variant_name = ident_tok.value
      local bind_fields = {}
      if p:at("OP", "{") then
        p:adv()  -- consume "{"
        while not p:at("OP", "}") and not p:at("EOF") and not p:at("NEWLINE") do
          if p:at("IDENT") then
            bind_fields[#bind_fields + 1] = p:adv().value
          else
            p:adv()
          end
          p:match("OP", ",")
        end
        p:expect("OP", "}")
      end
      -- The variant pattern is represented as a record_constructor node
      -- with variant name and binding field names (no values yet — just names)
      local field_nodes = {}
      for _, fname in ipairs(bind_fields) do
        -- named_arg with nil value = binding variable
        field_nodes[#field_nodes + 1] = ast.named_arg(fname, ast.fn_call(fname, {}, apos), apos)
      end
      pattern = ast.record_constructor(variant_name, field_nodes, apos)
    else
      p:emit_err(ast.E.BAD_EXPRESSION, "expected match arm pattern", p:cur().pos)
      p:skip_to_eol(); break
    end
    if pattern ~= nil then
      if not colon_consumed then
        p:expect("OP", ":", "expected ':' after match arm pattern")
      end
      local body
      if p:at("NEWLINE") or p:at("DEDENT") or p:at("EOF") then
        p:match("NEWLINE")
        if p:at("INDENT") then body = parse_body_items(p, false) end
      else
        -- pass and mutation primitives are statements, not expressions
        if p:at("KEYWORD", "pass") then
          local spos = p:cur().pos; p:adv(); body = { ast.pass_stmt(spos) }
        elseif p:at("IDENT") and MUTATION_TABLE[p:cur().value] then
          body = { parse_stmt(p) }
        else
          body = parse_expr(p)
        end
        if not p:at("OP", ")") and not p:at("NEWLINE") then p:skip_to_eol() end
        p:match("NEWLINE")
      end
      table.insert(arms, ast.match_arm(pattern, nil, body, apos))
    end
  end
  if in_indent and p:at("DEDENT") then p:adv() end
  return ast.match_expr(subject, arms, tpos)
end

local function parse_if_expr(p, is_scene)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "if"
  local cond = parse_expr(p)
  p:expect("OP", ":", "expected ':' after if condition")
  p:match("NEWLINE")
  local then_body = parse_body_items(p, is_scene or false)
  local else_body = nil
  p:skip_newlines()
  if p:at("NAMED_ARG", "else") then
    p:adv()
    p:match("NEWLINE")
    else_body = parse_body_items(p, is_scene or false)
  end
  return ast.if_expr(cond, then_body, else_body, tpos)
end

local function parse_when_stmt(p, is_scene)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "when"
  local cond = parse_expr(p)
  p:expect("OP", ":", "expected ':' after when condition")
  p:match("NEWLINE")
  local body = parse_body_items(p, is_scene or false)
  return ast.when_stmt(cond, body, tpos)
end

-- ── cond / for / while / let / lambda parsers ────────────────────────────────

--- Parse a cond: expression.
--- cond:
---   condition1: result1
---   condition2: result2
---   _: default
--- Note: 'cond:' may be tokenized as NAMED_ARG "cond" (lexer eats the ':')
--- or as KEYWORD "cond" + OP ":".  Both forms are handled.
local function parse_cond_expr(p)
  local tpos = p:cur().pos
  if p:at("KEYWORD", "cond") then
    p:adv()  -- consume KEYWORD "cond"
    p:expect("OP", ":", "expected ':' after cond")
  else
    -- NAMED_ARG "cond" — lexer already consumed the ':'
    p:adv()
  end
  p:match("NEWLINE")
  local arms = {}
  p:skip_newlines()
  if p:at("INDENT") then
    p:adv()
    while not p:at("DEDENT") and not p:at("EOF") do
      p:skip_newlines()
      if p:at("DEDENT") or p:at("EOF") then break end
      local apos = p:cur().pos
      local condition
      if p:at("NAMED_ARG", "_") then
        p:adv(); condition = "_"
      elseif p:at("IDENT", "_") then
        p:adv()
        p:expect("OP", ":", "expected ':' after '_'")
        condition = "_"
      else
        condition = parse_expr(p)
        p:expect("OP", ":", "expected ':' after cond arm condition")
      end
      local body
      if p:at("NEWLINE") or p:at("DEDENT") or p:at("EOF") then
        p:match("NEWLINE")
        if p:at("INDENT") then body = parse_body_items(p, false) end
      else
        body = parse_expr(p)
        if not p:at("OP", ")") then p:skip_to_eol() end
      end
      arms[#arms + 1] = ast.cond_arm(condition, body, apos)
    end
    if p:at("DEDENT") then p:adv() end
  end
  return ast.cond_expr(arms, tpos)
end

--- Parse a for loop statement: for var in expr: body
local function parse_for_stmt(p)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "for"
  local var_name = p:at("IDENT") and p:adv().value or "?"
  if p:at("KEYWORD", "in") then
    p:adv()
  else
    p:emit_err(ast.E.EXPECTED_TOKEN, "expected 'in' after for variable", p:cur().pos)
  end
  local iter = parse_expr(p)
  p:expect("OP", ":", "expected ':' after for expression")
  p:skip_to_eol()
  local body = parse_body_items(p, false)
  return ast.for_stmt(var_name, iter, body, tpos)
end

--- Parse a while loop statement: while cond: body
local function parse_while_stmt(p)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "while"
  local cond = parse_expr(p)
  p:expect("OP", ":", "expected ':' after while condition")
  p:skip_to_eol()
  local body = parse_body_items(p, false)
  return ast.while_stmt(cond, body, tpos)
end

--- Parse a let statement: let name = expr: body  (single binding form)
--- Multi-binding form with continuation lines (name = expr on subsequent lines,
--- last one ending with :) is also supported.
--- Parse a let binding value.
--- Returns (expr, colon_consumed).
--- colon_consumed is true when the value was a NAMED_ARG (lexer ate the ':').
local function parse_let_value(p)
  if p:at("NAMED_ARG") then
    -- 'name:' tokenized as one unit — the ':' is already gone
    local nt = p:adv()
    return ast.fn_call(nt.value, {}, nt.pos), true
  end
  return parse_expr(p), false
end

local function parse_let_stmt(p)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "let"
  local bindings = {}
  -- Parse first binding on the same line
  local bpos = p:cur().pos
  local bname = p:at("IDENT") and p:adv().value or "?"
  p:expect("OP", "=", "expected '=' in let binding")
  local bexpr, colon_done = parse_let_value(p)
  bindings[#bindings + 1] = ast.let_binding(bname, bexpr, bpos)
  if colon_done or p:at("OP", ":") then
    if not colon_done then p:adv() end  -- consume ":" if not already done
    p:skip_to_eol()
    local body = parse_body_items(p, false)
    return ast.let_stmt(bindings, body, tpos)
  end
  -- Otherwise: newline then possible INDENT block with more bindings
  p:match("NEWLINE")
  if p:at("INDENT") then
    p:adv()  -- consume INDENT (bindings continuation block)
    while not p:at("DEDENT") and not p:at("EOF") do
      p:skip_newlines()
      if p:at("DEDENT") or p:at("EOF") then break end
      if not p:at("IDENT") then break end
      local bpos2 = p:cur().pos
      local bname2 = p:adv().value
      if not p:at("OP", "=") then
        p:emit_err(ast.E.EXPECTED_TOKEN, "expected '=' in let binding continuation", p:cur().pos)
        break
      end
      p:adv()  -- consume "="
      local bexpr2, colon_done2 = parse_let_value(p)
      bindings[#bindings + 1] = ast.let_binding(bname2, bexpr2, bpos2)
      if colon_done2 or p:at("OP", ":") then
        if not colon_done2 then p:adv() end
        p:skip_to_eol()
        local body = parse_body_items(p, false)
        if p:at("DEDENT") then p:adv() end
        return ast.let_stmt(bindings, body, tpos)
      end
      p:match("NEWLINE")
    end
    if p:at("DEDENT") then p:adv() end
  end
  return ast.let_stmt(bindings, {}, tpos)
end

--- Parse a lambda expression: fn(params): body_expr
local function parse_lambda(p)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "fn"
  local params = {}
  if p:at("OP", "(") then
    p:adv()
    while p:at("IDENT") do
      params[#params + 1] = p:adv().value
      if not p:match("OP", ",") then break end
    end
    p:expect("OP", ")", "expected ')' to close lambda params")
  end
  p:expect("OP", ":", "expected ':' after lambda params")
  local body = parse_expr(p)
  return ast.lambda_expr(params, body, tpos)
end

-- ── Primary expression (with function application argument collection) ──────

local function parse_primary(p)
  local t = p:cur()
  local tpos = t.pos

  -- NAMED_ARG in expression context: 'name:' — the lexer ate the ':'.
  -- 'cond:' → parse as cond expression.
  -- Any other NAMED_ARG → treat as 0-arg fn_call (name is the callee).
  if t.kind == "NAMED_ARG" then
    if t.value == "cond" then return parse_cond_expr(p) end
    p:adv()
    return ast.fn_call(t.value, {}, tpos)
  end

  if t.kind == "KEYWORD" then
    if t.value == "match"  then return parse_match_expr(p) end
    if t.value == "if"     then return parse_if_expr(p)    end
    if t.value == "when"   then return parse_when_stmt(p)  end
    if t.value == "cond"   then return parse_cond_expr(p)  end
    if t.value == "fn"     then return parse_lambda(p)     end
    -- for / while / let: not valid as inline expressions
    if t.value == "for" or t.value == "while" or t.value == "let" then
      p:emit_err(ast.E.BAD_EXPRESSION,
        "'" .. t.value .. "' not valid as inline expression", tpos)
      p:skip_to_eol()
      return ast.int_lit(0, tpos)
    end
    p:emit_err(ast.E.BAD_EXPRESSION,
      "unexpected keyword '" .. t.value .. "' in expression", tpos)
    p:adv(); return ast.int_lit(0, tpos)
  end

  -- For IDENT: function application with argument collection
  if t.kind == "IDENT" then
    local name = t.value
    p:adv()
    -- Check for variant constructor: TypeName/variant-name field: val, ...
    -- e.g. ActorMsg/trade-offer item: item, price: price
    if p:at("OP", "/") and p:peek() and p:peek().kind == "IDENT" then
      -- Only treat as variant constructor if not followed by a lone expression
      -- (i.e. if the token after 'variant-name' is a NAMED_ARG or ')' or end)
      local saved_pos = p._pos  -- save position for backtracking
      p:adv()  -- consume "/"
      local variant_name = p:adv().value  -- consume variant IDENT
      local compound = name .. "/" .. variant_name
      -- If followed by named args (without `(`), parse as variant record constructor
      if p:at("NAMED_ARG") or p:at("OP", ")") or p:at("NEWLINE") or p:at("EOF") then
        local fields = {}
        while p:at("NAMED_ARG") do
          local nt = p:adv()
          local val = parse_expr(p)
          fields[#fields + 1] = ast.named_arg(nt.value, val, nt.pos)
          p:match("OP", ",")
        end
        return ast.record_constructor(compound, fields, tpos)
      else
        -- Not a variant constructor; treat original IDENT as fn_call, restore
        -- and let parse_mul handle the "/" as division with variant name as RHS
        -- Actually: return fn_call for base name, and let caller handle "/"
        -- We can't easily backtrack, so just emit a 0-arg call for compound
        return ast.fn_call(compound, {}, tpos)
      end
    end
    -- Check for record constructor: Name(field: val, ...)
    if p:at("OP", "(") and p:peek() and p:peek().kind == "NAMED_ARG" then
      p:adv()  -- consume "("
      local fields = {}
      p:skip_newlines()  -- inside parens: newlines are continuations
      while not p:at("OP", ")") and not p:at("EOF") and not p:at("DEDENT") do
        if p:at("NAMED_ARG") then
          local nt = p:adv()
          local val = parse_expr(p)
          fields[#fields + 1] = ast.named_arg(nt.value, val, nt.pos)
          p:match("OP", ",")
          p:skip_newlines()
        else
          break
        end
      end
      p:expect("OP", ")", "expected ')' to close record constructor")
      return ast.record_constructor(name, fields, tpos)
    end
    local args = {}
    while can_start_arg(p) do
      local arg = parse_atom(p)
      if not arg then break end
      args[#args + 1] = arg
    end
    -- Check for trailing lambda argument: fn(params): expr
    if p:at("KEYWORD", "fn") then
      local lam = parse_lambda(p)
      if lam then args[#args + 1] = lam end
    end
    return ast.fn_call(name, args, tpos)
  end

  -- Non-IDENT atoms (no argument collection)
  local a = parse_atom(p)
  if a then return a end

  p:emit_err(ast.E.BAD_EXPRESSION,
    "unexpected token in expression: " .. t.kind, tpos)
  p:adv()
  return ast.int_lit(0, tpos)
end

-- ── Precedence-climbing expression parser ───────────────────────────────────

local function parse_mul(p)
  local left = parse_primary(p)
  while p:at("OP") and (p:cur().value == "*" or p:cur().value == "/") do
    local op_pos = p:cur().pos; local op = p:adv().value
    local right = parse_primary(p)
    left = ast.binary_op(op, left, right, op_pos)
  end
  return left
end

local function parse_add(p)
  local left = parse_mul(p)
  while p:at("OP") and (p:cur().value == "+" or p:cur().value == "-") do
    local op_pos = p:cur().pos; local op = p:adv().value
    local right = parse_mul(p)
    left = ast.binary_op(op, left, right, op_pos)
  end
  return left
end

local CMP_OPS = { ["="]  = true, ["!="] = true, ["<"] = true,
                  [">"]  = true, ["<="] = true, [">="] = true }

local function parse_cmp(p)
  local left = parse_add(p)
  if p:at("OP") and CMP_OPS[p:cur().value] then
    local op_pos = p:cur().pos; local op = p:adv().value
    local right = parse_add(p)
    left = ast.binary_op(op, left, right, op_pos)
  end
  return left
end

local function parse_coalesce(p)
  local left = parse_cmp(p)
  while p:at("OP", "??") do
    local op_pos = p:cur().pos; p:adv()
    local right = parse_cmp(p)
    left = ast.nil_coalesce(left, right, op_pos)
  end
  return left
end

local function parse_not(p)
  if p:at("KEYWORD", "not") then
    local op_pos = p:cur().pos; p:adv()
    return ast.unary_op("not", parse_not(p), op_pos)
  end
  return parse_coalesce(p)
end

local function parse_and_expr(p)
  local left = parse_not(p)
  while p:at("KEYWORD", "and") do
    local op_pos = p:cur().pos; p:adv()
    local right = parse_not(p)
    left = ast.binary_op("and", left, right, op_pos)
  end
  return left
end

local function parse_or_expr(p)
  local left = parse_and_expr(p)
  while p:at("KEYWORD", "or") do
    local op_pos = p:cur().pos; p:adv()
    local right = parse_and_expr(p)
    left = ast.binary_op("or", left, right, op_pos)
  end
  return left
end

parse_expr = function(p) return parse_or_expr(p) end

-- ── Mutation path ────────────────────────────────────────────────────────────

local function parse_mut_path(p)
  local t = p:cur()
  if t.kind == "PATH" then
    p:adv(); return make_path_expr(t.value, t.pos)
  elseif t.kind == "INTERP_PATH" then
    p:adv(); return make_interp_path(t.value, t.pos)
  elseif t.kind == "IDENT" then
    -- Single-segment path (no slash) used in mutation position
    local v = p:adv(); return ast.path_expr({v.value}, v.pos)
  end
  p:emit_err(ast.E.BAD_EXPRESSION, "expected state path", t.pos)
  return ast.path_expr({}, t.pos)
end

-- ── Mutation primitives ──────────────────────────────────────────────────────

local MUTATION_TABLE = {
  ["set!"]     = function(p, pos)
    local path = parse_mut_path(p); local val = parse_expr(p)
    p:skip_to_eol(); return ast.set_mut(path, val, pos)
  end,
  ["inc!"]     = function(p, pos)
    local path = parse_mut_path(p); local amt = parse_expr(p)
    p:skip_to_eol(); return ast.inc_mut(path, amt, pos)
  end,
  ["dec!"]     = function(p, pos)
    local path = parse_mut_path(p); local amt = parse_expr(p)
    p:skip_to_eol(); return ast.dec_mut(path, amt, pos)
  end,
  ["add!"]     = function(p, pos)
    local path = parse_mut_path(p); local val = parse_expr(p)
    p:skip_to_eol(); return ast.add_mut(path, val, pos)
  end,
  ["remove!"]  = function(p, pos)
    local path = parse_mut_path(p); local val = parse_expr(p)
    p:skip_to_eol(); return ast.remove_mut(path, val, pos)
  end,
  ["clear!"]   = function(p, pos)
    local path = parse_mut_path(p)
    p:skip_to_eol(); return ast.clear_mut(path, pos)
  end,
  ["push!"]    = function(p, pos)
    local path = parse_mut_path(p); local val = parse_expr(p)
    p:skip_to_eol(); return ast.push_mut(path, val, pos)
  end,
  ["pop!"]     = function(p, pos)
    local path = parse_mut_path(p)
    p:skip_to_eol(); return ast.pop_mut(path, pos)
  end,
  ["spawn!"]   = function(p, pos)
    local fam = p:at("IDENT") and p:adv().value or "?"
    local key = parse_expr(p); local rec = parse_expr(p)
    p:skip_to_eol(); return ast.spawn_mut(fam, key, rec, pos)
  end,
  ["despawn!"] = function(p, pos)
    local fam = p:at("IDENT") and p:adv().value or "?"
    local key = parse_expr(p)
    p:skip_to_eol(); return ast.despawn_mut(fam, key, pos)
  end,
  ["relate!"]  = function(p, pos)
    local rel = p:at("IDENT") and p:adv().value or "?"
    local a = parse_expr(p); local b = parse_expr(p)
    p:skip_to_eol(); return ast.relate_mut(rel, a, b, pos)
  end,
  ["unrelate!"] = function(p, pos)
    local rel = p:at("IDENT") and p:adv().value or "?"
    local a = parse_expr(p); local b = parse_expr(p)
    p:skip_to_eol(); return ast.unrelate_mut(rel, a, b, pos)
  end,
  ["send!"]    = function(p, pos)
    -- actor is always a bare name; use parse_atom so '(' is not collected as an arg
    local actor = parse_atom(p)
    local msg   = parse_expr(p)
    p:skip_to_eol(); return ast.send_mut(actor, msg, pos)
  end,
  ["undo!"]    = function(p, pos)
    local steps = nil
    if p:at("NAMED_ARG", "steps") then p:adv(); steps = parse_expr(p) end
    p:skip_to_eol(); return ast.undo_mut(steps, pos)
  end,
  ["time-inc!"] = function(p, pos)
    -- Parse optional axis: value pairs, e.g. time-inc! tick: 1  hour: 8
    local axes = {}
    while p:at("NAMED_ARG") do
      local nt = p:adv()
      local val = parse_expr(p)
      axes[#axes + 1] = { axis = nt.value, value = val }
    end
    p:skip_to_eol(); return ast.time_inc_mut(axes, pos)
  end,
  ["cancel-schedule!"] = function(p, pos)
    local name = p:at("IDENT") and p:adv().value
                 or (p:at("SYMBOL") and p:adv().value)
                 or "?"
    p:skip_to_eol(); return ast.cancel_schedule_mut(name, pos)
  end,
}

-- ── Scene navigation ─────────────────────────────────────────────────────────

local function parse_scene_goto(p)
  local tpos = p:cur().pos
  p:adv()  -- consume "->"
  local target
  if p:at("OP", "(") then
    p:adv(); target = parse_expr(p); p:expect("OP", ")")
  elseif p:at("IDENT") or p:at("PATH") then
    target = p:adv().value
  else
    p:emit_err(ast.E.BAD_EXPRESSION, "expected scene name after '->'", p:cur().pos)
    target = "?"
  end
  p:skip_to_eol()
  return ast.scene_goto(target, tpos)
end

local function parse_scene_enter(p)
  local tpos = p:cur().pos
  p:adv()  -- consume "=>"
  local target
  if p:at("IDENT") or p:at("PATH") then target = p:adv().value
  else p:emit_err(ast.E.BAD_EXPRESSION, "expected scene name after '=>'", p:cur().pos); target = "?"
  end
  p:skip_to_eol()
  return ast.scene_enter(target, tpos)
end

-- ── Statement parser (code context) ─────────────────────────────────────────

parse_stmt = function(p)
  local t  = p:cur()
  local tpos = t.pos

  -- Mutation primitives (IDENTs ending in '!')
  if t.kind == "IDENT" and MUTATION_TABLE[t.value] then
    p:adv()
    return MUTATION_TABLE[t.value](p, tpos)
  end

  -- Control flow
  if t.kind == "KEYWORD" then
    if t.value == "when"  then return parse_when_stmt(p, false) end
    if t.value == "if"    then return parse_if_expr(p, false)   end
    if t.value == "match" then
      local e = parse_match_expr(p); return ast.expr_stmt(e, tpos)
    end
    if t.value == "for"   then return parse_for_stmt(p)   end
    if t.value == "while" then return parse_while_stmt(p) end
    if t.value == "let"   then return parse_let_stmt(p)   end
    if t.value == "cond" then
      local e = parse_cond_expr(p); return ast.expr_stmt(e, tpos)
    end
  end
  -- NAMED_ARG "cond" — 'cond:' with colon eaten by lexer
  if t.kind == "NAMED_ARG" and t.value == "cond" then
    local e = parse_cond_expr(p); return ast.expr_stmt(e, tpos)
  end
  if t.kind == "KEYWORD" then
    if t.value == "pass" then p:adv(); p:skip_to_eol(); return ast.pass_stmt(tpos) end
  end

  -- Scene navigation in fn/choice bodies
  if t.kind == "OP" then
    if t.value == "->" then return parse_scene_goto(p)  end
    if t.value == "=>" then return parse_scene_enter(p) end
    if t.value == "<-" then
      p:adv(); p:skip_to_eol(); return ast.scene_exit(tpos)
    end
  end

  -- Expression as statement (function call, path reference, etc.)
  local e = parse_expr(p)
  p:skip_to_eol()
  return ast.expr_stmt(e, tpos)
end

-- ── Body items (INDENT block, scene or code mode) ────────────────────────────

-- Collect tokens as a narration text list (strings + inline_expr nodes).
-- Consumes up to and including the NEWLINE.
local function parse_narration_text(p)
  local text = {}
  local text_parts = {}
  while not p:at("NEWLINE") and not p:at("DEDENT") and not p:at("EOF") do
    if p:at("OP", "{") then
      if #text_parts > 0 then
        table.insert(text, table.concat(text_parts, " "))
        text_parts = {}
      end
      local epos = p:cur().pos
      p:adv()  -- consume "{"
      local e = parse_expr(p)
      p:expect("OP", "}", "expected '}' to close inline expression")
      table.insert(text, ast.inline_expr(e, epos))
    else
      local tok = p:adv()
      table.insert(text_parts, tostring(tok.value))
    end
  end
  if #text_parts > 0 then table.insert(text, table.concat(text_parts, " ")) end
  p:match("NEWLINE")
  return text
end

parse_body_items = function(p, is_scene)
  local items = {}
  p:skip_newlines()
  if not p:at("INDENT") then
    p:emit_err(ast.E.EXPECTED_TOKEN, "expected indented block")
    return items
  end
  p:adv()  -- consume INDENT
  while not p:at("DEDENT") and not p:at("EOF") do
    p:skip_newlines()
    if p:at("DEDENT") or p:at("EOF") then break end
    local t = p:cur()
    local tpos = t.pos
    local item

    if is_scene then
      -- Scene body: choices, conditional narration, navigation, control flow, narration
      if t.kind == "OP" and t.value == "*" then
        -- Choice
        p:adv()  -- consume "*"
        local guard = nil
        if p:at("OP", "[") then
          p:adv(); guard = parse_expr(p); p:expect("OP", "]")
        end
        local label = parse_narration_text(p)
        local body = {}
        if p:at("INDENT") then
          body = parse_body_items(p, false)  -- choice body = code mode
        end
        item = ast.choice(guard, label, body, tpos)

      elseif t.kind == "OP" and t.value == "[" then
        -- Conditional narration
        p:adv(); local cond = parse_expr(p); p:expect("OP", "]")
        local text = parse_narration_text(p)
        item = ast.cond_narration(cond, text, tpos)

      elseif t.kind == "OP" and t.value == "->" then
        item = parse_scene_goto(p)
      elseif t.kind == "OP" and t.value == "=>" then
        item = parse_scene_enter(p)
      elseif t.kind == "OP" and t.value == "<-" then
        p:adv(); p:skip_to_eol(); item = ast.scene_exit(tpos)

      elseif t.kind == "KEYWORD" and t.value == "if" then
        item = parse_if_expr(p, true)   -- scene mode
      elseif t.kind == "KEYWORD" and t.value == "when" then
        item = parse_when_stmt(p, true) -- scene mode
      elseif t.kind == "KEYWORD" and t.value == "match" then
        local e = parse_match_expr(p); item = ast.expr_stmt(e, tpos)

      else
        -- Narration line: collect remaining tokens as text
        local text = parse_narration_text(p)
        item = ast.narration_line(text, tpos)
      end

    else
      -- Code body: statements only
      item = parse_stmt(p)
    end

    if item then table.insert(items, item) end
  end
  if p:at("DEDENT") then p:adv() end
  return items
end

-- ── Function declaration ─────────────────────────────────────────────────────

local function parse_fn_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "fn"

  -- Parse function name (and parameters)
  local fn_name, params = nil, {}
  if p:at("NAMED_ARG") then
    -- fn name:  (no parameters)
    fn_name = p:adv().value
  elseif p:at("IDENT") then
    fn_name = p:adv().value
    -- Collect intermediate IDENT params, last one is NAMED_ARG
    while p:at("IDENT") do
      table.insert(params, p:adv().value)
    end
    if p:at("NAMED_ARG") then
      table.insert(params, p:adv().value)
    else
      p:emit_err(ast.E.EXPECTED_TOKEN, "expected ':' after function parameters", p:cur().pos)
    end
  else
    p:emit_err(ast.E.EXPECTED_TOKEN, "expected function name after 'fn'", p:cur().pos)
    p:skip_to_eol(); p:skip_block(); return nil
  end

  p:match("NEWLINE")

  -- Function body block
  local pre_exprs = {}
  local post_exprs = {}
  local tags = {}
  local body_stmts = {}

  if not p:at("INDENT") then
    -- Zero-line function body (unusual but possible with pass)
    return ast.fn_decl(fn_name, params, pre_exprs, post_exprs, tags, body_stmts, doc, tpos)
  end
  p:adv()  -- consume INDENT

  while not p:at("DEDENT") and not p:at("EOF") do
    p:skip_newlines()
    if p:at("DEDENT") or p:at("EOF") then break end

    local bt = p:cur()

    if bt.kind == "NAMED_ARG" and bt.value == "pre" then
      p:adv()
      if p:at("NEWLINE") or p:at("INDENT") then
        p:match("NEWLINE")
        if p:at("INDENT") then
          local es = parse_body_items(p, false)
          for _, e in ipairs(es) do table.insert(pre_exprs, e) end
        end
      else
        local e = parse_expr(p); p:skip_to_eol()
        table.insert(pre_exprs, e)
      end

    elseif bt.kind == "NAMED_ARG" and bt.value == "post" then
      p:adv()
      if p:at("NEWLINE") or p:at("INDENT") then
        p:match("NEWLINE")
        if p:at("INDENT") then
          local es = parse_body_items(p, false)
          for _, e in ipairs(es) do table.insert(post_exprs, e) end
        end
      else
        local e = parse_expr(p); p:skip_to_eol()
        table.insert(post_exprs, e)
      end

    elseif bt.kind == "NAMED_ARG" and bt.value == "tags" then
      -- tags: [name, ...]  — skip for now
      p:skip_to_eol()

    else
      local stmt = parse_stmt(p)
      if stmt then table.insert(body_stmts, stmt) end
    end
  end

  if p:at("DEDENT") then p:adv() end
  return ast.fn_decl(fn_name, params, pre_exprs, post_exprs, tags, body_stmts, doc, tpos)
end

-- ── Scene declaration ────────────────────────────────────────────────────────

local function parse_scene_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "scene"

  local scene_name
  if p:at("NAMED_ARG") then
    scene_name = p:adv().value
  elseif p:at("IDENT") then
    -- scene name without colon? Shouldn't happen but handle gracefully
    scene_name = p:adv().value
    p:match("OP", ":")
  else
    p:emit_err(ast.E.EXPECTED_TOKEN, "expected scene name after 'scene'", p:cur().pos)
    p:skip_to_eol(); p:skip_block(); return nil
  end

  p:match("NEWLINE")

  local body = {}
  if p:at("INDENT") then
    body = parse_body_items(p, true)  -- scene mode
  end

  return ast.scene_decl(scene_name, body, doc, tpos)
end

-- ── Time-trigger helper ──────────────────────────────────────────────────────

--- Parse a time-axis list: [axis: +N, axis: N, ...]
--- Returns a list of {axis=string, value=number} tables.
local function parse_time_trigger(p)
  local entries = {}
  if not p:at("OP", "[") then return entries end
  p:adv()  -- consume "["
  while not p:at("OP", "]") and not p:at("EOF") and not p:at("NEWLINE") do
    if p:at("NAMED_ARG") then
      local axis = p:adv().value
      local sign = 1
      if     p:at("OP", "+") then p:adv()
      elseif p:at("OP", "-") then p:adv(); sign = -1 end
      local n = 0
      if p:at("INTEGER") then n = p:adv().value end
      table.insert(entries, { axis = axis, value = sign * n })
    else
      p:adv()
    end
    p:match("OP", ",")
  end
  p:expect("OP", "]", "expected ']' to close time-trigger list")
  return entries
end

-- ── Actor declaration ────────────────────────────────────────────────────────

--- actor name:
---   state:     path
---   perceives: [path, ...]
---   inbox:     TypeExpr
---   behavior:  fn-name
---   priority:  N
local function parse_actor_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD("actor")

  local name
  if p:at("NAMED_ARG") then
    name = p:adv().value
  elseif p:at("IDENT") then
    name = p:adv().value
    p:expect("OP", ":", "expected ':' after actor name")
  else
    p:emit_err(ast.E.BAD_DECLARATION, "expected actor name after 'actor'", p:cur().pos)
    p:skip_to_eol(); p:skip_block(); return nil
  end

  p:match("NEWLINE")

  local state_path, perceives, inbox_type, behavior, priority = nil, {}, nil, nil, 0

  if not p:at("INDENT") then
    return ast.actor_decl(name, state_path, perceives, inbox_type, behavior, priority, doc, tpos)
  end
  p:adv()  -- consume INDENT

  while not p:at("DEDENT") and not p:at("EOF") do
    p:skip_newlines()
    if p:at("DEDENT") or p:at("EOF") then break end
    local bt = p:cur()
    if bt.kind == "NAMED_ARG" then
      if bt.value == "state" then
        p:adv()
        if p:at("PATH") then
          state_path = p:adv().value
        elseif p:at("IDENT") then
          state_path = p:adv().value
        end
      elseif bt.value == "perceives" then
        p:adv()
        if p:at("OP", "[") then
          p:adv()
          while not p:at("OP", "]") and not p:at("EOF") and not p:at("NEWLINE") do
            -- Collect tokens until ',' or ']' and reconstruct path string
            local parts = {}
            while not p:at("OP", ",") and not p:at("OP", "]")
                  and not p:at("EOF") and not p:at("NEWLINE") do
              table.insert(parts, tostring(p:adv().value or ""))
            end
            if #parts > 0 then
              table.insert(perceives, table.concat(parts))
            end
            p:match("OP", ",")
            p:skip_newlines()
          end
          p:expect("OP", "]", "expected ']' to close perceives list")
        end
      elseif bt.value == "inbox" then
        p:adv()
        inbox_type = parse_type_expr(p)
      elseif bt.value == "behavior" then
        p:adv()
        if p:at("IDENT") then
          behavior = p:adv().value
        end
      elseif bt.value == "priority" then
        p:adv()
        if p:at("INTEGER") then
          priority = p:adv().value
        end
      end
    end
    p:skip_to_eol()
  end

  if p:at("DEDENT") then p:adv() end
  return ast.actor_decl(name, state_path, perceives, inbox_type, behavior, priority, doc, tpos)
end

-- ── Schedule declaration ─────────────────────────────────────────────────────

--- schedule name:
---   every:  [axis: +N, ...]
---   at:     [axis: +N, ...]
---   offset: [axis: N, ...]
---   fn:
---     body...
local function parse_schedule_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD("schedule")

  local name
  if p:at("NAMED_ARG") then
    name = p:adv().value
  elseif p:at("IDENT") then
    name = p:adv().value
    p:expect("OP", ":", "expected ':' after schedule name")
  else
    p:emit_err(ast.E.BAD_DECLARATION, "expected schedule name after 'schedule'", p:cur().pos)
    p:skip_to_eol(); p:skip_block(); return nil
  end

  p:match("NEWLINE")

  local trigger = {}
  local body = {}

  if not p:at("INDENT") then
    return ast.schedule_decl(name, trigger, body, doc, tpos)
  end
  p:adv()  -- consume INDENT

  while not p:at("DEDENT") and not p:at("EOF") do
    p:skip_newlines()
    if p:at("DEDENT") or p:at("EOF") then break end
    local bt = p:cur()
    if bt.kind == "NAMED_ARG" then
      if bt.value == "every" then
        p:adv()
        trigger.every = parse_time_trigger(p)
        p:skip_to_eol()
      elseif bt.value == "at" then
        p:adv()
        trigger.at = parse_time_trigger(p)
        p:skip_to_eol()
      elseif bt.value == "offset" then
        p:adv()
        trigger.offset = parse_time_trigger(p)
        p:skip_to_eol()
      elseif bt.value == "fn" then
        p:adv()  -- consume "fn:" NAMED_ARG
        p:match("NEWLINE")
        if p:at("INDENT") then
          body = parse_body_items(p, false)
        else
          local stmt = parse_stmt(p)
          if stmt then body = { stmt } end
        end
      else
        p:skip_to_eol()
      end
    else
      p:skip_to_eol()
    end
  end

  if p:at("DEDENT") then p:adv() end
  return ast.schedule_decl(name, trigger, body, doc, tpos)
end

--- Parse a `verify "label": clauses` declaration.
local function parse_verify_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD("verify")

  local label = nil
  if p:at("STRING") then label = p:adv().value end
  p:expect("OP", ":", "expected ':' after verify label")
  p:match("NEWLINE")

  local clauses = {}

  if not p:at("INDENT") then
    return ast.verify_decl(label, clauses, tpos)
  end
  p:adv()  -- consume INDENT

  while not p:at("DEDENT") and not p:at("EOF") do
    p:skip_newlines()
    if p:at("DEDENT") or p:at("EOF") then break end
    local ct = p:cur()
    local cpos = ct.pos

    if ct.kind == "IDENT" and ct.value == "verify-always" then
      p:adv()
      local expr = parse_expr(p); p:skip_to_eol()
      clauses[#clauses+1] = ast.verify_clause("always", expr, {}, cpos)

    elseif ct.kind == "NAMED_ARG" and ct.value == "from-any-state" then
      p:adv(); p:skip_to_eol()
      -- Consume the nested body (sub-clauses like can-reach?) — stored but not yet evaluated
      if p:at("INDENT") then
        local sub_body = parse_body_items(p, false)
        clauses[#clauses+1] = ast.verify_clause("from_any_state", nil, sub_body, cpos)
      else
        clauses[#clauses+1] = ast.verify_clause("from_any_state", nil, {}, cpos)
      end

    elseif (ct.kind == "IDENT" or ct.kind == "NAMED_ARG") and ct.value == "requires" then
      p:adv()
      local expr = parse_expr(p); p:skip_to_eol()
      clauses[#clauses+1] = ast.verify_clause("requires", expr, {}, cpos)

    elseif (ct.kind == "NAMED_ARG" or ct.kind == "IDENT") and ct.value == "after" then
      p:adv()
      -- after (<fn-call>): body
      local call_expr = nil
      if p:at("OP", "(") then
        p:adv()
        call_expr = parse_expr(p)
        p:expect("OP", ")", "expected ')' after after-clause call")
      else
        call_expr = parse_expr(p)
      end
      p:expect("OP", ":", "expected ':' after after-clause call")
      p:match("NEWLINE")
      local assertions = {}
      if p:at("INDENT") then
        p:adv()
        while not p:at("DEDENT") and not p:at("EOF") do
          p:skip_newlines()
          if p:at("DEDENT") or p:at("EOF") then break end
          local ae = parse_expr(p); p:skip_to_eol()
          if ae then assertions[#assertions+1] = ae end
        end
        if p:at("DEDENT") then p:adv() end
      end
      clauses[#clauses+1] = ast.verify_clause("after", call_expr, assertions, cpos)

    elseif ct.kind == "KEYWORD" and ct.value == "when" then
      p:adv()
      local cond = parse_expr(p)
      p:expect("OP", ":", "expected ':' after when-condition")
      p:match("NEWLINE")
      -- when body is sub-clauses (for now, just skip)
      if p:at("INDENT") then p:adv(); while not p:at("DEDENT") and not p:at("EOF") do p:skip_to_eol() end; if p:at("DEDENT") then p:adv() end end
      clauses[#clauses+1] = ast.verify_clause("when", cond, {}, cpos)

    else
      p:skip_to_eol()
    end
  end

  if p:at("DEDENT") then p:adv() end
  return ast.verify_decl(label, clauses, doc, tpos)
end

--- Parse `watch path "label"` and `watch-when cond "label"` declarations.
local function parse_watch_decl(p, doc)
  local tpos = p:cur().pos
  local kw = p:adv().value  -- consume KEYWORD("watch" or "watch-when")

  -- Helper: grab optional label (STRING) on the same or next indented line
  local function consume_label()
    if p:at("STRING") then return p:adv().value end
    p:skip_to_eol()
    -- Check if label is on the next line as an indented string
    if p:at("INDENT") then
      p:adv()  -- consume INDENT
      p:skip_newlines()
      local lbl = nil
      if p:at("STRING") then lbl = p:adv().value end
      p:skip_to_eol()
      while not p:at("DEDENT") and not p:at("EOF") do p:skip_to_eol() end
      if p:at("DEDENT") then p:adv() end
      return lbl
    end
    return nil
  end

  if kw == "watch" then
    local path_node = nil
    if p:at("PATH") then
      local pt = p:adv(); path_node = make_path_expr(pt.value, pt.pos)
    elseif p:at("INTERP_PATH") then
      local pt = p:adv(); path_node = make_interp_path(pt.value, pt.pos)
    elseif p:at("IDENT") then
      local pt = p:adv(); path_node = ast.path_expr({pt.value}, pt.pos)
    else
      p:emit_err(ast.E.BAD_DECLARATION, "expected state path after 'watch'", p:cur().pos)
      p:skip_to_eol(); return nil
    end
    local label = consume_label()
    return ast.watch_decl(path_node, label, tpos)
  else  -- watch-when
    local cond = parse_expr(p)
    local label = consume_label()
    return ast.watch_when_decl(cond, label, tpos)
  end
end


-- ============================================================
-- Top-level dispatch
-- ============================================================

local function parse_decl(p, doc)
  local t = p:cur()

  if t.kind == "KEYWORD" then
    if     t.value == "module"   then return parse_module_decl(p, doc)
    elseif t.value == "import"   then return parse_import_decl(p, doc)
    elseif t.value == "type"     then return parse_type_decl(p, doc)
    elseif t.value == "state"    then return parse_state_decl(p, doc)
    elseif t.value == "relation" then return parse_relation_decl(p, doc)
    elseif t.value == "fn"       then return parse_fn_decl(p, doc)
    elseif t.value == "scene"    then return parse_scene_decl(p, doc)
    elseif t.value == "actor"      then return parse_actor_decl(p, doc)
    elseif t.value == "schedule"   then return parse_schedule_decl(p, doc)
    elseif t.value == "verify"     then return parse_verify_decl(p, doc)
    elseif t.value == "watch"
        or t.value == "watch-when" then return parse_watch_decl(p, doc)
    else
      -- bounded, macro, migration — later phases
      p:skip_to_eol()
      p:skip_block()
      return nil
    end

  elseif t.kind == "NAMED_ARG" then
    if     t.value == "schema-version" then return parse_schema_version(p, doc)
    elseif t.value == "engine-config"  then return parse_engine_config(p, doc)
    elseif t.value == "time-model"     then return parse_time_model(p, doc)
    else
      p:emit_err(ast.E.BAD_DECLARATION,
        "unexpected named argument '" .. t.value .. "' at top level", t.pos)
      p:skip_to_eol()
      return nil
    end

  else
    p:emit_err(ast.E.UNEXPECTED_TOKEN,
      "unexpected " .. t.kind .. " at top level", t.pos)
    p:skip_to_eol()
    return nil
  end
end

-- ============================================================
-- Public API
-- ============================================================

--- Parse a token stream produced by the lexer.
---
--- Returns (ast_root, diags):
---   ast_root — root ast.program node
---   diags    — list of diagnostic tables
---
---@param tokens   table   Token list from lexer.tokenize
---@param filename string  File name for diagnostics
---@return table, table
function M.parse(tokens, filename)
  local p = new_parser(tokens, filename)
  local decls = {}
  local doc = nil

  p:skip_newlines()

  while not p:at("EOF") do
    -- Collect optional leading doc string
    if p:at("STRING") or p:at("MULTILINE_STRING") then
      doc = p:adv().value
      p:skip_newlines()
    else
      doc = nil
    end

    if p:at("EOF") then break end

    local prev = p.pos
    local decl = parse_decl(p, doc)
    if decl then table.insert(decls, decl) end
    doc = nil

    p:skip_newlines()

    -- Safety guard: if nothing was consumed, force advance to prevent infinite loop
    if p.pos == prev then p:adv() end
  end

  local prog_pos = decls[1] and decls[1].pos or ast.pos(filename, 1, 1)
  return ast.program(decls, prog_pos), p.diags
end

return M

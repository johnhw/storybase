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
  while not p:at("OP", ")") and not p:at("EOF")
        and not p:at("NEWLINE") and not p:at("DEDENT") do
    if p:at("NAMED_ARG") then
      local fname = p:adv()
      local val = parse_default_value(p)
      table.insert(fields, ast.named_arg(fname.value, val, fname.pos))
    else
      p:adv()  -- skip unexpected token
    end
    p:match("OP", ",")
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
    else
      -- fn, scene, actor, etc. — Phase 2+ features; skip silently in Phase 1
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

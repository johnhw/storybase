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

    -- Namespace-qualified type: Alias.TypeName  (e.g. E.Npc)
    if p:at("OP", ".") then
      local nx = p:peek()
      if nx and nx.kind == "IDENT" then
        p:adv()  -- consume "."
        local member = p:adv().value  -- consume member name
        return ast.type_named(name .. "." .. member, tpos)
      end
    end

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
    -- Parse non-empty list literal [elem, ...]
    local elements = {}
    while not p:at("OP", "]") and not p:at("EOF") and not p:at("NEWLINE") do
      local elem = parse_default_value(p)
      if elem then elements[#elements+1] = elem end
      if p:at("OP", ",") then p:adv() end
    end
    p:match("OP", "]")
    return ast.list_lit(elements, tpos)

  elseif t.kind == "OP" and t.value == "{" then
    p:adv()
    if p:at("OP", "}") then
      p:adv()
      return ast.node(ast.K.EMPTY_MAP, {}, tpos)
    end
    -- Parse elements; if first is followed by ":" it's a map, else a set
    local first_elem = parse_default_value(p)
    if p:at("OP", ":") then
      -- Map literal: {key: val, ...}
      p:adv()  -- consume ":"
      local first_val = parse_default_value(p)
      local entries = {}
      if first_elem then
        local key = (first_elem.kind == ast.K.SYMBOL_LIT and first_elem.name)
                 or (first_elem.kind == ast.K.STRING_LIT and first_elem.value)
                 or tostring(first_elem)
        entries[#entries+1] = ast.named_arg(key, first_val, tpos)
      end
      if p:at("OP", ",") then p:adv() end
      while not p:at("OP", "}") and not p:at("EOF") and not p:at("NEWLINE") do
        local k_elem = parse_default_value(p)
        if p:at("OP", ":") then p:adv() end
        local v_elem = parse_default_value(p)
        if k_elem then
          local key = (k_elem.kind == ast.K.SYMBOL_LIT and k_elem.name)
                   or (k_elem.kind == ast.K.STRING_LIT and k_elem.value)
                   or tostring(k_elem)
          entries[#entries+1] = ast.named_arg(key, v_elem, tpos)
        end
        if p:at("OP", ",") then p:adv() end
      end
      p:match("OP", "}")
      return ast.map_lit(entries, tpos)
    else
      -- Set literal: {elem, elem, ...}
      local elements = {}
      if first_elem then elements[#elements+1] = first_elem end
      if p:at("OP", ",") then p:adv() end
      while not p:at("OP", "}") and not p:at("EOF") and not p:at("NEWLINE") do
        local elem = parse_default_value(p)
        if elem then elements[#elements+1] = elem end
        if p:at("OP", ",") then p:adv() end
      end
      p:match("OP", "}")
      return ast.set_lit(elements, tpos)
    end
  end

  return nil
end

-- ============================================================
-- Declaration parsers
-- ============================================================

--- module name
---   version: N
---   exports: [Name, ...]
local function parse_module_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume "module"
  local name_t = p:expect("IDENT", nil, "expected module name")
  local name = name_t and name_t.value or "?"
  local version = nil
  local exports = nil  -- list of exported names, or nil if not specified

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
      elseif p:at("NAMED_ARG", "exports") then
        -- exports: [Name, Name, ...]
        p:adv()
        exports = {}
        if p:at("OP", "[") then
          p:adv()
          while not p:at("OP", "]") and not p:at("EOF") and not p:at("NEWLINE") do
            if p:at("IDENT") then
              exports[#exports+1] = p:adv().value
            else
              p:adv()
            end
            p:match("OP", ",")
          end
          p:match("OP", "]")
        end
        p:skip_to_eol()
      else
        p:skip_to_eol()
      end
    end
    if p:at("DEDENT") then p:adv() end
  end

  return ast.module_decl(name, version, exports, tpos)
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
      -- Parse optional value list: ['a, 'b, ...] or {'a, 'b, ...} or bare symbols/idents
      local values = {}
      local close_bracket = nil
      if self:at("OP", "[") then
        self:adv(); close_bracket = "]"
      elseif self:at("OP", "{") then
        self:adv(); close_bracket = "}"
      end
      if close_bracket then
        while not self:at("OP", close_bracket) and not self:at("NEWLINE")
              and not self:at("EOF") do
          local vpos = self:cur().pos
          if self:at("SYMBOL") then
            values[#values+1] = ast.symbol_lit(self:adv().value, vpos)
          elseif self:at("IDENT") then
            values[#values+1] = ast.type_named(self:adv().value, vpos)
          else
            self:adv()  -- skip unexpected token
          end
          self:match("OP", ",")
        end
        self:expect("OP", close_bracket, "expected '"..close_bracket.."' to close relation value list")
      end
      self:skip_to_eol()
      return { key = key, values = values }
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
-- Handles path-expression interpolations like {player/companion} correctly.
local function make_interp_path(path_str, pos)
  local segs = {}
  local i = 1
  local n = #path_str
  while i <= n do
    local c = path_str:sub(i, i)
    if c == '/' then
      i = i + 1  -- skip path separator
    elseif c == '{' then
      local close = path_str:find("}", i + 1, true)
      if close then
        table.insert(segs, { interp = path_str:sub(i + 1, close - 1) })
        i = close + 1
      else
        table.insert(segs, path_str:sub(i))
        break
      end
    else
      local j = path_str:find("[/{]", i) or (n + 1)
      table.insert(segs, path_str:sub(i, j - 1))
      i = j
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
local parse_expr, parse_stmt, parse_body_items, parse_narration_text
-- Forward-declared so parse_match_expr (defined before the table) captures
-- the same upvalue slot that is filled at the MUTATION_TABLE = {...} assignment.
local MUTATION_TABLE

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
    -- Check for indexed access: path[n] or path[a:b]
    if p:at("OP", "[") then
      p:adv()  -- consume "["
      -- Special case: the lexer may have consumed "ident:" as a NAMED_ARG token
      -- (e.g. in path[start:end], "start:" is lexed as NAMED_ARG "start").
      -- Detect this and treat the identifier as the lower bound of a slice.
      local idx, slice_colon_consumed = nil, false
      if p:at("NAMED_ARG") then
        local na = p:cur()
        idx = ast.fn_call(na.value, {}, na.pos)
        p:adv()
        slice_colon_consumed = true
      else
        idx = parse_expr(p)
      end
      -- Optionally: path[a:b] slice — parse optional ':' and end
      local idx2 = nil
      if slice_colon_consumed or p:at("OP", ":") then
        if not slice_colon_consumed then p:adv() end  -- consume ':'
        if not p:at("OP", "]") then
          idx2 = parse_expr(p)
        end
      end
      p:expect("OP", "]", "expected ']' to close index")
      if idx2 then
        return ast.slice_expr(path_node, idx, idx2, tpos)
      end
      return ast.index_expr(path_node, idx, tpos)
    end
    return path_node
  elseif t.kind == "INTERP_PATH" then
    p:adv()
    local ipath_node = make_interp_path(t.value, tpos)
    -- Check for @before suffix on interpolated paths
    if p:at("OP", "@") then
      local nx = p:peek()
      if nx and nx.kind == "IDENT" and nx.value == "before" then
        p:adv()  -- consume "@"
        p:adv()  -- consume "before"
        return ast.path_at_before(ipath_node, tpos)
      end
    end
    return ipath_node
  elseif t.kind == "IDENT" and t.value == "counterfactual" then
    -- counterfactual [from: expr] [simulate: true] do: (indented block)
    p:adv()
    local from_tick = nil
    local simulate  = false
    -- Optional from: and simulate: clauses (both are NAMED_ARG tokens)
    while p:at("NAMED_ARG") and (p:cur().value == "from" or p:cur().value == "simulate") do
      local clause = p:cur().value; p:adv()
      if clause == "from" then
        from_tick = parse_expr(p)
      elseif clause == "simulate" then
        if p:at("BOOL") then simulate = p:cur().value; p:adv()
        else simulate = true end
      end
    end
    -- do: block
    local transitions = {}
    if p:at("NAMED_ARG") and p:cur().value == "do" then
      p:adv()  -- consume "do:"
      p:match("NEWLINE")
      if p:at("INDENT") then
        p:adv()
        while not p:at("DEDENT") and not p:at("EOF") do
          p:skip_newlines()
          if p:at("DEDENT") or p:at("EOF") then break end
          local call_expr = parse_stmt(p)
          if call_expr then transitions[#transitions+1] = call_expr end
        end
        if p:at("DEDENT") then p:adv() end
      end
    end
    return ast.counterfactual_expr(from_tick, transitions, simulate, tpos)

  elseif t.kind == "IDENT" and (t.value == "find" or t.value == "count") then
    -- find/count family [where: expr] [order-by: path asc|desc] [limit: N] [count]
    local is_count_form = (t.value == "count")
    p:adv()  -- consume "find" or "count"
    local family_name = ""
    if p:at("IDENT") or p:at("PATH") then
      family_name = p:adv().value
    end
    local clauses = {}
    if is_count_form then
      clauses[#clauses+1] = { kind = "count" }
    end
    -- Parse inline clauses (same line) or indented block.
    -- newline_skip: when true, skip newlines between clauses (paren continuation context).
    local function parse_find_clauses_inline(newline_skip)
      while p:at("NAMED_ARG") do
        local na = p:adv()
        if na.value == "where" then
          local cond = parse_expr(p)
          clauses[#clauses+1] = { kind = "where", condition = cond }
        elseif na.value == "or-where" then
          local cond = parse_expr(p)
          clauses[#clauses+1] = { kind = "or_where", condition = cond }
        elseif na.value == "order-by" then
          local path_node = parse_atom(p)
          local dir = "asc"
          if p:at("IDENT") and (p:cur().value == "asc" or p:cur().value == "desc") then
            dir = p:adv().value
          end
          clauses[#clauses+1] = { kind = "order_by", path = path_node, dir = dir }
        elseif na.value == "limit" then
          local lim_tok = parse_expr(p)
          local lim_val = (lim_tok and lim_tok.kind == "int_lit") and lim_tok.value or 10
          clauses[#clauses+1] = { kind = "limit", value = lim_val }
        elseif na.value == "in-state" then
          local state_expr = parse_expr(p)
          clauses[#clauses+1] = { kind = "in_state", state_expr = state_expr }
        end
        -- unknown NAMED_ARG: skip
        if newline_skip then p:skip_newlines() end
      end
      if newline_skip then p:skip_newlines() end
      -- bare "count" IDENT
      if p:at("IDENT", "count") then
        p:adv()
        clauses[#clauses+1] = { kind = "count" }
      end
    end

    -- Check for indented block or inline clauses
    if p:at("NEWLINE") then
      local saved_pos = p.pos
      p:adv()  -- consume NEWLINE
      if p:at("INDENT") then
        p:adv()  -- consume INDENT
        while not p:at("DEDENT") and not p:at("EOF") do
          p:skip_newlines()
          if p:at("DEDENT") or p:at("EOF") then break end
          if p:at("NAMED_ARG") then
            local na = p:adv()
            if na.value == "where" then
              local cond = parse_expr(p)
              clauses[#clauses+1] = { kind = "where", condition = cond }
            elseif na.value == "or-where" then
              local cond = parse_expr(p)
              clauses[#clauses+1] = { kind = "or_where", condition = cond }
            elseif na.value == "order-by" then
              local path_node = parse_atom(p)
              local dir = "asc"
              if p:at("IDENT") and (p:cur().value == "asc" or p:cur().value == "desc") then
                dir = p:adv().value
              end
              clauses[#clauses+1] = { kind = "order_by", path = path_node, dir = dir }
            elseif na.value == "limit" then
              local lim_tok = parse_expr(p)
              local lim_val = (lim_tok and lim_tok.kind == "int_lit") and lim_tok.value or 10
              clauses[#clauses+1] = { kind = "limit", value = lim_val }
            elseif na.value == "in-state" then
              local state_expr = parse_expr(p)
              clauses[#clauses+1] = { kind = "in_state", state_expr = state_expr }
            end
            p:skip_to_eol()
          elseif p:at("IDENT", "count") then
            p:adv()
            clauses[#clauses+1] = { kind = "count" }
            p:skip_to_eol()
          elseif p:at("IDENT", "within") then
            -- within N hops of <relation> from <src>
            p:adv()  -- consume "within"
            local hops_node = parse_expr(p)
            local hops = (hops_node and hops_node.kind == "int_lit") and hops_node.value or 1
            -- expect "hops" ident
            if p:at("IDENT", "hops") then p:adv() end
            -- expect "of" ident
            if p:at("IDENT", "of") then p:adv() end
            -- relation name (bare ident or symbol)
            local rel_name = nil
            if p:at("IDENT") then
              rel_name = p:adv().value
            elseif p:at("SYMBOL") then
              rel_name = p:adv().value
            end
            -- expect "from" ident
            if p:at("IDENT", "from") then p:adv() end
            local src_expr = parse_expr(p)
            clauses[#clauses+1] = { kind = "within", hops = hops,
                                    relation_name = rel_name, from = src_expr }
            p:skip_to_eol()
          elseif p:at("IDENT", "connected-to") then
            -- connected-to <path> via <relation>
            p:adv()  -- consume "connected-to"
            local path_node = parse_expr(p)
            -- expect "via" ident
            if p:at("IDENT", "via") then p:adv() end
            local rel_name = nil
            if p:at("IDENT") then
              rel_name = p:adv().value
            elseif p:at("SYMBOL") then
              rel_name = p:adv().value
            end
            clauses[#clauses+1] = { kind = "connected_to", path = path_node,
                                    relation_name = rel_name }
            p:skip_to_eol()
          else
            p:skip_to_eol()
          end
        end
        if p:at("DEDENT") then p:adv() end
      else
        -- No INDENT after NEWLINE: inside parens the lexer never emits INDENT/DEDENT.
        -- Check whether continuation lines hold find clauses; if so, parse them.
        p:skip_newlines()
        if p:at("NAMED_ARG") or p:at("IDENT", "count") then
          parse_find_clauses_inline(true)  -- true = skip newlines between clauses
        else
          p.pos = saved_pos  -- nothing found; restore NEWLINE for caller
        end
      end
    else
      parse_find_clauses_inline()
    end
    return ast.find_expr(family_name, clauses, tpos)

  elseif t.kind == "IDENT" then
    -- 0-arg function call (no further argument collection in atom context)
    local name = t.value
    p:adv()
    -- Namespace-qualified call: Alias.fn-name
    if p:at("OP", ".") then
      local nx = p:peek()
      if nx and nx.kind == "IDENT" then
        p:adv()  -- consume "."
        local member = p:adv().value  -- consume member name
        name = name .. "." .. member
      end
    end
    return ast.fn_call(name, {}, tpos)
  elseif t.kind == "OP" and t.value == "(" then
    -- Check for (in-state gs) prefix before regular expr
    local nx = p:peek()
    if nx and nx.kind == "IDENT" and nx.value == "in-state" then
      p:adv()  -- consume "("
      p:adv()  -- consume "in-state"
      local state_var = parse_expr(p)
      p:expect("OP", ")", "expected ')' after in-state expression")
      local inner = parse_atom(p)  -- path or simple expr to redirect
      return ast.in_state_expr(state_var, inner, tpos)
    end
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

  elseif t.kind == "OP" and t.value == "{" then
    -- Set literal: {'a, 'b, ...}    — elements are symbol literals
    -- Map literal: {key: val, ...}  — elements are NAMED_ARG pairs
    -- Empty map:   {}
    p:adv()  -- consume "{"
    if p:at("OP", "}") then
      -- Empty: treat as empty map literal
      p:adv()
      return ast.map_lit({}, tpos)
    end
    if p:at("SYMBOL") then
      -- Set literal
      local elems = {}
      while not p:at("OP", "}") and not p:at("NEWLINE") and not p:at("EOF") do
        table.insert(elems, parse_expr(p))
        if not p:match("OP", ",") then break end
      end
      p:expect("OP", "}", "expected '}' to close set literal")
      return ast.set_lit(elems, tpos)
    elseif p:at("NAMED_ARG") then
      -- Map literal: key: val, ...
      local entries = {}
      while p:at("NAMED_ARG") do
        local kt = p:adv()  -- consume "key:"
        local val = parse_expr(p)
        table.insert(entries, ast.named_arg(kt.value, val, kt.pos))
        p:match("OP", ",")
        p:skip_newlines()
      end
      p:expect("OP", "}", "expected '}' to close map literal")
      return ast.map_lit(entries, tpos)
    else
      -- Unrecognised; parse as empty map
      p:emit_err(ast.E.BAD_EXPRESSION,
        "expected symbol ('name) or 'key:' in set/map literal", p:cur().pos)
      while not p:at("OP", "}") and not p:at("NEWLINE") and not p:at("EOF") do p:adv() end
      p:match("OP", "}")
      return ast.map_lit({}, tpos)
    end
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
      -- bare "variant-name:" (no fields) — zero-field variant pattern
      local nt = p:adv()
      pattern = ast.record_constructor(nt.value, {}, nt.pos); colon_consumed = true
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
        local eol_consumed = false
        if p:at("KEYWORD", "pass") then
          local spos = p:cur().pos; p:adv(); body = { ast.pass_stmt(spos) }
        elseif p:at("IDENT") and MUTATION_TABLE[p:cur().value] then
          body = { parse_stmt(p) }
          -- Mutation handlers call skip_to_eol() internally, which consumes
          -- the NEWLINE.  Avoid consuming it again below.
          eol_consumed = true
        else
          body = parse_expr(p)
        end
        if not eol_consumed then
          if not p:at("OP", ")") and not p:at("NEWLINE") then p:skip_to_eol() end
          p:match("NEWLINE")
        end
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
  -- ':' may have been consumed by the lexer as part of a NAMED_ARG token
  -- (e.g. 'nil:' → NAMED_ARG "nil"). If so, the current token is NEWLINE/DEDENT.
  if p:at("OP", ":") then
    p:adv()
  elseif not (p:at("NEWLINE") or p:at("DEDENT") or p:at("EOF")) then
    p:expect("OP", ":", "expected ':' after if condition")
  end
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
  -- The ':' after the condition may already have been consumed by the lexer as
  -- part of a NAMED_ARG token (e.g. "room-clear?:" → NAMED_ARG "room-clear?").
  -- In that case the current token will be NEWLINE/DEDENT/EOF — just skip the
  -- explicit ':' check.  If ':' is still present, consume it normally.
  if p:at("OP", ":") then
    p:adv()
  elseif not (p:at("NEWLINE") or p:at("DEDENT") or p:at("EOF")) then
    p:expect("OP", ":", "expected ':' after when condition")
  end
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

--- Parse a for loop statement: for var in expr: body [else: else_body]
--- is_scene: if true the loop body is parsed in scene mode (narration lines allowed).
local function parse_for_stmt(p, is_scene)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "for"
  local var_name = p:at("IDENT") and p:adv().value or "?"
  if p:at("KEYWORD", "in") then
    p:adv()
  else
    p:emit_err(ast.E.EXPECTED_TOKEN, "expected 'in' after for variable", p:cur().pos)
  end
  -- Peek ahead: if the iterator expression is a bare NAMED_ARG (e.g. "changes:")
  -- the lexer already consumed the ':' as part of the token.
  local iter_tok_is_named_arg = p:at("NAMED_ARG")
  local iter = parse_expr(p)
  -- Only expect explicit ':' if the NAMED_ARG did NOT already consume it.
  if not iter_tok_is_named_arg then
    p:expect("OP", ":", "expected ':' after for expression")
  end
  p:skip_to_eol()
  local body = parse_body_items(p, is_scene or false)
  local else_body = nil
  p:skip_newlines()
  if p:at("NAMED_ARG", "else") then
    p:adv()  -- consume "else:" (NAMED_ARG already consumed the ':')
    p:match("NEWLINE")
    else_body = parse_body_items(p, is_scene or false)
  end
  return ast.for_stmt(var_name, iter, body, else_body, tpos)
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
  local expr = parse_expr(p)
  -- If parse_expr consumed a NAMED_ARG as its last token (e.g. `amount - defense:`),
  -- the lexer folded the colon into that token, so the let-body colon is already gone.
  local last = p.tokens[p.pos - 1]
  local colon_done = last ~= nil and last.kind == "NAMED_ARG"
  return expr, colon_done
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

--- Parse a lambda expression: fn(params): body_expr  OR  fn(params):\n  block
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
  -- Multi-line block body: fn(params):\n  stmts...
  local body
  if p:at("NEWLINE") or p:at("INDENT") then
    body = parse_body_items(p, false)
  else
    body = parse_expr(p)
  end
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

  -- Special IDENTs that are parsed as structured expressions (not fn calls)
  if t.kind == "IDENT" and t.value == "find" then
    return parse_atom(p)
  end

  -- "count family where: ..." → FIND_EXPR with count clause (not the builtin count)
  if t.kind == "IDENT" and t.value == "count" then
    local nx = p:peek()
    if nx and (nx.kind == "IDENT" or nx.kind == "PATH") then
      -- lookahead: if the token after the family name is a NAMED_ARG, it's a find-count
      local nx2 = p.tokens[p.pos + 2]  -- token 2 positions ahead
      if nx2 and nx2.kind == "NAMED_ARG" then
        return parse_atom(p)
      end
    end
  end

  if t.kind == "IDENT" and t.value == "counterfactual" then
    return parse_atom(p)
  end

  -- For IDENT: function application with argument collection
  if t.kind == "IDENT" then
    local name = t.value
    p:adv()
    -- Namespace-qualified call: Alias.fn-name (consume before variant/record checks)
    if p:at("OP", ".") then
      local nx = p:peek()
      if nx and nx.kind == "IDENT" then
        p:adv()  -- consume "."
        local member = p:adv().value  -- consume member name
        name = name .. "." .. member
      end
    end
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
    -- Check for index/slice access: name[expr] or name[a:b]
    -- Must come before arg collection so `items[1]` is not parsed as `items([1])`.
    if p:at("OP", "[") then
      p:adv()  -- consume "["
      -- NAMED_ARG fix: lexer produces "ident:" as single token, recover identifier
      local idx, slice_colon_consumed = nil, false
      if p:at("NAMED_ARG") then
        local na = p:cur()
        idx = ast.fn_call(na.value, {}, na.pos)
        p:adv()
        slice_colon_consumed = true
      else
        idx = parse_expr(p)
      end
      local idx2 = nil
      if slice_colon_consumed or p:at("OP", ":") then
        if not slice_colon_consumed then p:adv() end  -- consume ':'
        if not p:at("OP", "]") then
          idx2 = parse_expr(p)
        end
      end
      p:expect("OP", "]", "expected ']' to close index")
      local base = ast.fn_call(name, {}, tpos)
      if idx2 then
        return ast.slice_expr(base, idx, idx2, tpos)
      end
      return ast.index_expr(base, idx, tpos)
    end
    local args = {}
    while can_start_arg(p) do
      local arg = parse_atom(p)
      if not arg then break end
      args[#args + 1] = arg
    end
    -- Collect trailing named-arg tokens: e.g. `within-range? g x1 y1 x2 y2 range: 3`
    while p:at("NAMED_ARG") do
      local na = p:adv()
      local val = parse_atom(p)
      args[#args + 1] = ast.named_arg(na.value, val, na.pos)
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
  elseif p:at("KEYWORD", "in") then
    local op_pos = p:cur().pos; p:adv()
    local right = parse_add(p)
    left = ast.binary_op("in", left, right, op_pos)
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
  local base_node
  if t.kind == "PATH" then
    p:adv(); base_node = make_path_expr(t.value, t.pos)
  elseif t.kind == "INTERP_PATH" then
    p:adv(); base_node = make_interp_path(t.value, t.pos)
  elseif t.kind == "IDENT" then
    -- Single-segment path (no slash) used in mutation position
    local v = p:adv(); base_node = ast.path_expr({v.value}, v.pos)
  else
    p:emit_err(ast.E.BAD_EXPRESSION, "expected state path", t.pos)
    return ast.path_expr({}, t.pos)
  end
  -- Check for indexed write: path[n] in mutation position
  if p:at("OP", "[") then
    local tpos = base_node.pos
    p:adv()  -- consume "["
    local idx = parse_expr(p)
    p:expect("OP", "]", "expected ']' to close index")
    return ast.index_expr(base_node, idx, tpos)
  end
  return base_node
end

-- ── Mutation primitives ──────────────────────────────────────────────────────

MUTATION_TABLE = {
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
  ["map-set!"] = function(p, pos)
    local path = parse_mut_path(p); local key = parse_atom(p); local val = parse_expr(p)
    p:skip_to_eol(); return ast.map_set_mut(path, key, val, pos)
  end,
  ["map-delete!"] = function(p, pos)
    local path = parse_mut_path(p); local key = parse_atom(p)
    p:skip_to_eol(); return ast.map_delete_mut(path, key, pos)
  end,
  ["spawn!"]   = function(p, pos)
    local fam = p:at("IDENT") and p:adv().value or "?"
    local key = parse_expr(p)
    local rec = (not p:at("NEWLINE") and not p:at("EOF")) and parse_expr(p) or nil
    p:skip_to_eol(); return ast.spawn_mut(fam, key, rec, pos)
  end,
  ["despawn!"] = function(p, pos)
    local fam = p:at("IDENT") and p:adv().value or "?"
    local key = parse_expr(p)
    p:skip_to_eol(); return ast.despawn_mut(fam, key, pos)
  end,
  ["relate!"]  = function(p, pos)
    local rel = p:at("IDENT") and p:adv().value or "?"
    -- Use parse_atom (not parse_expr) for source and target to avoid greedy
    -- argument collection: `relate! rel ident1 ident2` must not parse ident2
    -- as an argument to ident1.
    local a = parse_atom(p); local b = parse_atom(p)
    p:skip_to_eol(); return ast.relate_mut(rel, a, b, pos)
  end,
  ["unrelate!"] = function(p, pos)
    local rel = p:at("IDENT") and p:adv().value or "?"
    local a = parse_atom(p); local b = parse_atom(p)
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
  ["time-set!"] = function(p, pos)
    -- Absolute time set: time-set! tick: N day: M
    local axes = {}
    while p:at("NAMED_ARG") do
      local nt = p:adv()
      local val = parse_expr(p)
      axes[#axes + 1] = { axis = nt.value, value = val }
    end
    p:skip_to_eol(); return ast.time_set_mut(axes, pos)
  end,
  ["cancel-schedule!"] = function(p, pos)
    local name = p:at("IDENT") and p:adv().value
                 or (p:at("SYMBOL") and p:adv().value)
                 or "?"
    p:skip_to_eol(); return ast.cancel_schedule_mut(name, pos)
  end,
  ["schedule!"] = function(p, pos)
    -- schedule! 'name every: [tick: +N] fn: fn-name
    -- or: schedule! name every: [tick: +N] fn: fn-name
    local name_expr = nil
    if p:at("SYMBOL") then
      name_expr = ast.symbol_lit(p:adv().value, p:cur().pos)
    elseif p:at("IDENT") then
      name_expr = ast.fn_call(p:cur().value, {}, p:cur().pos); p:adv()
    else
      name_expr = parse_expr(p)
    end
    local opts = {}
    local fn_name = nil
    while p:at("NAMED_ARG") do
      local na = p:adv()
      if na.value == "every" or na.value == "at" or na.value == "offset" then
        -- Parse a time list: [tick: +N, ...]
        local trigger_entries = {}
        if p:at("OP", "[") then
          p:adv()
          while not p:at("OP", "]") and not p:at("NEWLINE") and not p:at("EOF") do
            if p:at("NAMED_ARG") then
              local axis_tok = p:adv()
              local val_expr = parse_expr(p)
              trigger_entries[#trigger_entries+1] = { axis = axis_tok.value, value = val_expr }
            else
              break
            end
            p:match("OP", ",")
          end
          p:match("OP", "]")
        end
        opts[na.value] = trigger_entries
      elseif na.value == "fn" then
        if p:at("IDENT") or p:at("PATH") then
          fn_name = p:adv().value
        else
          fn_name = (parse_expr(p) or {}).name or "?"
        end
      end
    end
    p:skip_to_eol()
    return ast.schedule_mut(name_expr, opts, fn_name, pos)
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
    -- Support namespace-qualified scene: -> E.scene-name
    if p:at("OP", ".") then
      local nx = p:peek()
      if nx and nx.kind == "IDENT" then
        p:adv()  -- consume "."
        local member = p:adv().value
        target = target .. "." .. member
      end
    end
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
  if p:at("IDENT") or p:at("PATH") then
    target = p:adv().value
    -- Support namespace-qualified scene: => E.scene-name
    if p:at("OP", ".") then
      local nx = p:peek()
      if nx and nx.kind == "IDENT" then
        p:adv()  -- consume "."
        local member = p:adv().value
        target = target .. "." .. member
      end
    end
  else
    p:emit_err(ast.E.BAD_EXPRESSION, "expected scene name after '=>'", p:cur().pos)
    target = "?"
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

  -- Engine pseudo-mutation paths (PATH tokens)
  if t.kind == "PATH" and t.value == "engine/checkpoint!" then
    p:adv()
    local fn_name_expr = nil
    if not p:at("NEWLINE") and not p:at("EOF") and not p:at("DEDENT") then
      fn_name_expr = parse_atom(p)
    end
    p:skip_to_eol()
    return ast.checkpoint_mut(fn_name_expr, tpos)
  end
  if t.kind == "PATH" and t.value == "engine/emit" then
    p:adv()
    local event_expr = parse_atom(p)
    local args_expr = nil
    if not p:at("NEWLINE") and not p:at("EOF") and not p:at("DEDENT") then
      args_expr = parse_expr(p)
    end
    p:skip_to_eol()
    return ast.emit_mut(event_expr, args_expr, tpos)
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
    if t.value == "pass"     then p:adv(); p:skip_to_eol(); return ast.pass_stmt(tpos)     end
    if t.value == "break"    then p:adv(); p:skip_to_eol(); return ast.break_stmt(tpos)    end
    if t.value == "continue" then p:adv(); p:skip_to_eol(); return ast.continue_stmt(tpos) end
    if t.value == "return" then
      p:adv()  -- consume "return"
      local expr = nil
      if not p:at("NEWLINE") and not p:at("EOF") and not p:at("DEDENT") then
        expr = parse_expr(p)
      end
      p:skip_to_eol()
      return ast.return_stmt(expr, tpos)
    end
    if t.value == "say"  then
      -- Function/choice-body form: say <speaker> <text>
      -- speaker: NAMED_ARG | SYMBOL | IDENT | OP "(" expr OP ")"
      -- text:    narration text to end of line
      p:adv()  -- consume "say"
      local t2 = p:cur()
      local speaker
      if t2.kind == "NAMED_ARG" then
        speaker = ast.symbol_lit(t2.value, t2.pos); p:adv()
      elseif t2.kind == "SYMBOL" then
        speaker = ast.symbol_lit(t2.value, t2.pos); p:adv()
      elseif t2.kind == "IDENT" then
        speaker = ast.symbol_lit(t2.value, t2.pos); p:adv()
      elseif t2.kind == "OP" and t2.value == "(" then
        p:adv(); speaker = parse_expr(p); p:expect("OP", ")")
      else
        p:emit_err(ast.E.BAD_EXPRESSION, "expected speaker after 'say'", t2.pos)
        p:skip_to_eol(); return nil
      end
      local text = parse_narration_text(p)
      return ast.say_stmt(speaker, { text }, tpos)
    end
  end

  -- Scene navigation in fn/choice bodies
  if t.kind == "OP" then
    if t.value == "->" then return parse_scene_goto(p)  end
    if t.value == "=>" then return parse_scene_enter(p) end
    if t.value == "<-" then
      p:adv(); p:skip_to_eol(); return ast.scene_exit(tpos)
    end
  end

  -- Macro call with body block.  Two syntactic cases:
  --   Case A: "name:" NEWLINE INDENT body — NAMED_ARG("name") token, no expr args
  --   Case B: "name arg1 arg2:" NEWLINE INDENT body — FN_CALL then OP(":")
  -- We detect Case A early (before parse_expr), since the lexer ate the ":".
  if t.kind == "NAMED_ARG" then
    local nx = p:peek()
    -- If the next non-whitespace token is NEWLINE then INDENT, it's a body block.
    -- p:peek() skips the current token and returns the one after.
    if nx and (nx.kind == "NEWLINE" or nx.kind == "INDENT") then
      local name = t.value
      p:adv()  -- consume NAMED_ARG
      p:match("NEWLINE")
      if p:at("INDENT") then
        local mac_body = parse_body_items(p, false)
        return ast.macro_call_stmt(name, {}, mac_body, tpos)
      end
      -- Fallback: treat as regular 0-arg fn_call expression statement
      p:skip_to_eol()
      return ast.expr_stmt(ast.fn_call(name, {}, tpos), tpos)
    end
  end

  -- Expression as statement (function call, path reference, etc.)
  local e = parse_expr(p)
  -- Case B: FN_CALL expression immediately followed by OP(":") + body block
  if e and e.kind == ast.K.FN_CALL and p:at("OP", ":") then
    p:adv()  -- consume ":"
    p:match("NEWLINE")
    local mac_body = parse_body_items(p, false)
    return ast.macro_call_stmt(e.name, e.args, mac_body, tpos)
  end
  p:skip_to_eol()
  return ast.expr_stmt(e, tpos)
end

-- ── Body items (INDENT block, scene or code mode) ────────────────────────────

-- Return the display string and raw source byte-length for a token.
-- Used by parse_narration_text to reconstruct original spacing.
local function tok_display_and_len(tok)
  local k, v = tok.kind, tok.value
  if k == "SYMBOL" then
    local s = tostring(v)
    return "`" .. s, 1 + #s          -- ` prefix not in value
  elseif k == "NAMED_ARG" then
    local s = tostring(v)
    return s .. ":", #s + 1          -- : suffix not in value
  elseif k == "BOOL" then
    local s = v and "true" or "false"
    return s, #s
  elseif k == "INT" or k == "FLOAT" then
    local s = tostring(v)
    return s, #s
  elseif k == "RAW_TEXT" then
    local s = tostring(v)
    return s, #s
  else
    local s = tostring(v)
    return s, #s
  end
end

-- Collect tokens as a narration text list (strings + inline_expr nodes).
-- Spacing is reconstructed from token column positions so that punctuation
-- adjacent to words (commas, periods, apostrophes) is not padded with spaces.
-- Consumes up to and including the NEWLINE.
parse_narration_text = function(p)
  local text = {}
  local buf = {}
  local prev_end = nil  -- column just past the last character of the previous token

  local function flush()
    if #buf > 0 then
      table.insert(text, table.concat(buf))
      buf = {}
    end
  end

  while not p:at("NEWLINE") and not p:at("DEDENT") and not p:at("EOF") do
    if p:at("OP", "{") then
      -- Add trailing space to buf if there's a gap before {
      local brace_col = p:cur().pos.col
      if prev_end ~= nil and brace_col > prev_end then
        table.insert(buf, " ")
      end
      flush()
      local epos = p:cur().pos
      p:adv()  -- consume "{"
      local e = parse_expr(p)
      local rbrace = p:expect("OP", "}", "expected '}' to close inline expression")
      prev_end = rbrace and (rbrace.pos.col + 1) or nil
      table.insert(text, ast.inline_expr(e, epos))
    else
      local tok = p:adv()
      local display, raw_len = tok_display_and_len(tok)
      local col = tok.pos.col
      if prev_end ~= nil and col > prev_end then
        table.insert(buf, " ")
      end
      table.insert(buf, display)
      prev_end = col + raw_len
    end
  end
  flush()
  p:match("NEWLINE")
  return text
end

-- Parse an indented block of narration lines for a say statement.
-- Returns a list of text-item lists (one per line).
local function parse_say_block(p)
  local lines = {}
  p:skip_newlines()
  if not p:at("INDENT") then
    p:emit_err(ast.E.EXPECTED_TOKEN, "expected indented block after 'say ... :'")
    return lines
  end
  p:adv()  -- consume INDENT
  while not p:at("DEDENT") and not p:at("EOF") do
    p:skip_newlines()
    if p:at("DEDENT") or p:at("EOF") then break end
    local text = parse_narration_text(p)
    if text and #text > 0 then lines[#lines + 1] = text end
  end
  if p:at("DEDENT") then p:adv() end
  return lines
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
        local nd = #p.diags
        item = parse_if_expr(p, true)    -- scene mode
        if #p.diags > nd then
          local d = p.diags[#p.diags]
          if d then d.note = "if this line is narration beginning with 'if', start it with a different word" end
        end
      elseif t.kind == "KEYWORD" and t.value == "when" then
        local nd = #p.diags
        item = parse_when_stmt(p, true)  -- scene mode
        if #p.diags > nd then
          local d = p.diags[#p.diags]
          if d then d.note = "if this line is narration beginning with 'when', start it with a different word" end
        end
      elseif t.kind == "KEYWORD" and t.value == "for" then
        local nd = #p.diags
        item = parse_for_stmt(p, true)   -- scene mode: body parsed as narration
        if #p.diags > nd then
          local d = p.diags[#p.diags]
          if d then d.note = "if this line is narration beginning with 'for', start it with a different word" end
        end
      elseif t.kind == "KEYWORD" and t.value == "match" then
        local e = parse_match_expr(p); item = ast.expr_stmt(e, tpos)

      elseif t.kind == "KEYWORD" and t.value == "say" then
        -- Scene-body say: say <speaker>: block-or-inline
        -- speaker: NAMED_ARG | SYMBOL | IDENT | OP "(" expr OP ")" then OP ":"
        p:adv()  -- consume "say"
        local t2 = p:cur()
        local speaker, bad_speaker = nil, false
        if t2.kind == "NAMED_ARG" then
          -- say aldric: ...  (NAMED_ARG already has colon consumed by lexer)
          speaker = ast.symbol_lit(t2.value, t2.pos); p:adv()
        elseif t2.kind == "SYMBOL" then
          speaker = ast.symbol_lit(t2.value, t2.pos); p:adv()
          -- colon is optional when speaker is a symbol literal (fn-body style)
          if p:at("OP", ":") then p:adv() end
        elseif t2.kind == "IDENT" then
          speaker = ast.symbol_lit(t2.value, t2.pos); p:adv()
          p:expect("OP", ":", "expected ':' after speaker name")
        elseif t2.kind == "OP" and t2.value == "(" then
          p:adv(); speaker = parse_expr(p); p:expect("OP", ")")
          p:expect("OP", ":", "expected ':' after ')'")
        else
          p:emit_err(ast.E.BAD_EXPRESSION, "expected speaker after 'say'", t2.pos)
          p:skip_to_eol(); bad_speaker = true
        end
        if not bad_speaker then
          -- Block or inline form
          local lines
          if p:at("NEWLINE") or p:at("EOF") then
            p:match("NEWLINE")
            if p:at("INDENT") then
              lines = parse_say_block(p)
            else
              lines = {}
            end
          else
            -- Inline: rest of line is the single dialogue line
            local text = parse_narration_text(p)
            lines = (#text > 0) and { text } or {}
          end
          item = ast.say_stmt(speaker, lines, tpos)
        end

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
      p:adv()  -- consume "tags:"
      if p:at("OP", "[") then
        p:adv()  -- consume "["
        while not p:at("OP", "]") and not p:at("EOF") and not p:at("NEWLINE") do
          if p:at("IDENT") then
            tags[#tags + 1] = p:cur().value
            p:adv()
          end
          if p:at("OP", ",") then p:adv() end
        end
        if p:at("OP", "]") then p:adv() end
      end
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

  local state_path, perceives, inbox_type, behavior, priority = nil, nil, nil, nil, 0

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
        perceives = {}   -- declaration present; list may still be empty
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

--- Parse a `migration A -> B: ops` declaration.
--- Syntax:
---   migration 1 -> 2:
---     rename player/hp -> player/health
---     add    player/mana = 50
---     drop   player/notes
---     transform player/level:
---       fn old: old * 10
---     rename-enum player/class 'fighter -> 'warrior
local function parse_migration_decl(p, _doc)
  local tpos = p:cur().pos
  p:adv()  -- consume IDENT "migration"

  -- from_ver -> to_ver
  local from_ver = nil
  local to_ver   = nil
  if p:at("INTEGER") then
    from_ver = tonumber(p:cur().value); p:adv()
  end
  if p:at("OP", "->") then p:adv() end
  if p:at("INTEGER") then
    to_ver = tonumber(p:cur().value); p:adv()
  end
  p:expect("OP", ":", "expected ':' after migration version range")
  p:match("NEWLINE")

  local ops = {}
  if p:at("INDENT") then
    p:adv()
    while not p:at("DEDENT") and not p:at("EOF") do
      p:skip_newlines()
      if p:at("DEDENT") or p:at("EOF") then break end

      local ct = p:cur()
      if ct.kind == "IDENT" and ct.value == "rename" then
        p:adv()
        -- Check if this is rename-enum (next token could be "-enum" suffix)
        -- Actually "rename-enum" is tokenised as a single IDENT due to kebab-case
        -- We won't reach this branch for rename-enum (handled below)
        -- rename old-path -> new-path
        local old_path = nil
        if p:at("PATH") or p:at("IDENT") then
          old_path = p:cur().value; p:adv()
        end
        p:expect("OP", "->", "expected '->' in rename op")
        local new_path = nil
        if p:at("PATH") or p:at("IDENT") then
          new_path = p:cur().value; p:adv()
        end
        ops[#ops + 1] = { op = "rename", old_path = old_path, new_path = new_path }
        p:skip_to_eol()

      elseif ct.kind == "IDENT" and ct.value == "rename-enum" then
        p:adv()
        -- rename-enum path old-symbol -> new-symbol
        local path = nil
        if p:at("PATH") or p:at("IDENT") then
          path = p:cur().value; p:adv()
        end
        local old_sym = nil
        if p:at("SYMBOL") then
          old_sym = p:cur().value; p:adv()
        end
        p:expect("OP", "->", "expected '->' in rename-enum op")
        local new_sym = nil
        if p:at("SYMBOL") then
          new_sym = p:cur().value; p:adv()
        end
        ops[#ops + 1] = { op = "rename-enum", path = path, old_sym = old_sym, new_sym = new_sym }
        p:skip_to_eol()

      elseif ct.kind == "IDENT" and ct.value == "add" then
        p:adv()
        -- add path = value
        local path = nil
        if p:at("PATH") or p:at("IDENT") then
          path = p:cur().value; p:adv()
        end
        p:expect("OP", "=", "expected '=' in add op")
        local val_expr = parse_expr(p)
        ops[#ops + 1] = { op = "add", path = path, value = val_expr }
        p:skip_to_eol()

      elseif ct.kind == "IDENT" and ct.value == "drop" then
        p:adv()
        -- drop path
        local path = nil
        if p:at("PATH") or p:at("IDENT") then
          path = p:cur().value; p:adv()
        end
        ops[#ops + 1] = { op = "drop", path = path }
        p:skip_to_eol()

      elseif ct.kind == "IDENT" and ct.value == "transform" then
        p:adv()
        -- transform path: fn old: expr  (multi-line body — skip_to_eol handled inside)
        local path = nil
        if p:at("PATH") or p:at("IDENT") or p:at("NAMED_ARG") then
          -- Consume the path — it may end with ':' if NAMED_ARG
          if p:at("NAMED_ARG") then
            path = p:cur().value; p:adv()
          else
            path = p:cur().value; p:adv()
            if p:at("OP", ":") then p:adv() end
          end
        end
        p:match("NEWLINE")
        -- Expect indented body: fn old: expr
        local transform_expr = nil
        if p:at("INDENT") then
          p:adv()
          -- fn old: expr
          if p:at("KEYWORD") and p:cur().value == "fn" then
            p:adv()
            -- consume param name (e.g. "old" or "old:")
            -- The lexer may tokenise "old:" as NAMED_ARG(old), consuming the colon.
            local _param = nil
            if p:at("NAMED_ARG") then
              _param = p:cur().value; p:adv()  -- NAMED_ARG consumed the colon
            elseif p:at("IDENT") then
              _param = p:cur().value; p:adv()
              p:expect("OP", ":", "expected ':' after transform param")
            end
            transform_expr = parse_expr(p)
          end
          p:skip_to_eol()
          if p:at("DEDENT") then p:adv() end
        end
        ops[#ops + 1] = { op = "transform", path = path, expr = transform_expr }
        -- do NOT call skip_to_eol here: already advanced past the block

      else
        p:skip_to_eol()
      end
    end
    if p:at("DEDENT") then p:adv() end
  end

  return ast.migration_decl(from_ver, to_ver, ops, tpos)
end

--- Parse a `bounded name param: clauses` declaration.
--- Syntax:
---   bounded classify-intent text:
---     returns:      PlayerIntent
---     distribution: uniform
---     reads:        []
---     lua:          "game.nlp.classify_intent"
local function parse_bounded_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD("bounded") or IDENT("bounded")
  local params = {}
  -- The name may be a plain IDENT, a hyphenated NAMED_ARG (e.g. "roll-die:"),
  -- or an IDENT followed by optional params then ":".
  local name
  if p:at("NAMED_ARG") then
    -- "roll-die:" → NAMED_ARG token: the name is its value; the colon is already consumed
    name = p:adv().value
    p:match("NEWLINE")
    goto bounded_body
  else
    name = p:at("IDENT") and p:adv().value or "?"
  end
  -- Optional parameter name.
  -- The lexer may have eaten the ':' from "paramname:" producing NAMED_ARG.
  -- If next token is NAMED_ARG, the param name is its value and ':' is consumed.
  -- If next token is IDENT followed by ':', parse param as IDENT.
  if p:at("NAMED_ARG") then
    -- "paramname:" → the ':' is already consumed; this doubles as the colon we need
    params[#params+1] = p:adv().value
    -- No need to consume ':' separately
    p:match("NEWLINE")
    goto bounded_body
  end
  if p:at("IDENT") then
    params[#params+1] = p:adv().value
  end
  p:expect("OP", ":", "expected ':' after bounded declaration name")
  ::bounded_body::
  p:match("NEWLINE")

  local returns_type  = nil
  local distribution  = nil
  local reads         = {}
  local lua_name      = nil

  if p:at("INDENT") then
    p:adv()
    while not p:at("DEDENT") and not p:at("EOF") do
      p:skip_newlines()
      if p:at("DEDENT") or p:at("EOF") then break end
      local ct = p:cur()
      if ct.kind == "NAMED_ARG" then
        local na = p:adv()
        if na.value == "returns" then
          returns_type = parse_type_expr(p)
        elseif na.value == "distribution" then
          -- distribution: uniform  or  distribution: conditioned-on path
          if p:at("IDENT") then
            local d = p:adv().value
            if p:at("IDENT") then
              -- e.g. conditioned-on
              local part2 = p:adv().value
              if p:at("PATH") or p:at("IDENT") then
                local path_val = p:adv().value
                distribution = d .. "-" .. part2 .. " " .. path_val
              else
                distribution = d .. "-" .. part2
              end
            else
              distribution = d
            end
          end
        elseif na.value == "reads" then
          if p:at("OP", "[") then
            p:adv()
            while not p:at("OP", "]") and not p:at("NEWLINE") and not p:at("EOF") do
              if p:at("PATH") or p:at("IDENT") then
                reads[#reads+1] = p:adv().value
              else
                p:adv()
              end
              p:match("OP", ",")
            end
            p:match("OP", "]")
          end
        elseif na.value == "lua" then
          if p:at("STRING") then lua_name = p:adv().value end
        end
      end
      p:skip_to_eol()
    end
    if p:at("DEDENT") then p:adv() end
  end

  return ast.bounded_decl(name, params, returns_type, distribution, reads, lua_name, doc, tpos)
end

--- Parse a `defgrid name: body` declaration.
--- Syntax:
---   defgrid world-map:
---     dimensions: W x H
---     cell-type:  TypeName
---     default:    cell_value   (optional)
local function parse_defgrid_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume IDENT("defgrid")

  -- Grid name: may arrive as NAMED_ARG("name") (colon already consumed)
  -- or as IDENT("name") followed by OP(":").
  local name
  if p:at("NAMED_ARG") then
    name = p:adv().value
  elseif p:at("IDENT") then
    name = p:adv().value
    p:expect("OP", ":", "expected ':' after defgrid name")
  else
    p:emit_err(ast.E.UNEXPECTED_TOKEN, "expected grid name after 'defgrid'", p:cur().pos)
    name = "?"
  end
  p:match("NEWLINE")

  local width       = nil
  local height      = nil
  local cell_type   = nil
  local default_val = nil

  if p:at("INDENT") then
    p:adv()
    while not p:at("DEDENT") and not p:at("EOF") do
      p:skip_newlines()
      if p:at("DEDENT") or p:at("EOF") then break end
      local ct = p:cur()
      if ct.kind == "NAMED_ARG" then
        local na = p:adv()
        if na.value == "dimensions" then
          -- dimensions: W x H   (two INTEGER tokens separated by IDENT("x"))
          if p:at("INTEGER") then width  = p:adv().value end
          p:match("IDENT")   -- consume "x"
          if p:at("INTEGER") then height = p:adv().value end
        elseif na.value == "cell-type" then
          if p:at("IDENT") then cell_type = p:adv().value end
        elseif na.value == "default" then
          -- Accept a bare identifier or a symbol literal
          if p:at("SYMBOL") then
            default_val = p:adv().value
          elseif p:at("IDENT") then
            default_val = p:adv().value
          end
        end
      end
      p:skip_to_eol()
    end
    if p:at("DEDENT") then p:adv() end
  end

  return ast.defgrid_decl(name, width, height, cell_type, default_val, doc, tpos)
end

--- Parse a `macro name param1 param2...: body` declaration.
--- The colon that separates params from body is eaten by the lexer as a
--- NAMED_ARG token for the last identifier before it.  So both forms work:
---   macro foo x y:       → params ["x","y"],  "y:" is NAMED_ARG("y") NEWLINE
---   macro foo body:      → params ["body"],   "body:" is NAMED_ARG("body") NEWLINE
local function parse_macro_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "macro"
  local name = p:at("IDENT") and p:adv().value or "?"
  local params = {}
  -- Collect params: plain IDENT tokens, terminated by NAMED_ARG (which eats the `:`)
  while p:at("IDENT") or p:at("NAMED_ARG") do
    local t = p:adv()
    params[#params + 1] = t.value
    if t.kind == "NAMED_ARG" then break end  -- "name:" ate the ':'
  end
  -- If ended on a plain IDENT (no NAMED_ARG seen), there might still be a `:` or NAMED_ARG
  -- If the last consumed was IDENT and we still see OP(":"), consume it
  if #params > 0 then
    p:match("OP", ":")  -- optional fallback if somehow `:` was not in NAMED_ARG
  end
  p:match("NEWLINE")
  local body = parse_body_items(p, false)  -- code (not scene) mode
  return ast.macro_decl(name, params, body, doc, tpos)
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
      if p:at("INDENT") then
        p:adv()
        while not p:at("DEDENT") and not p:at("EOF") do p:skip_to_eol() end
        if p:at("DEDENT") then p:adv() end
      end
      clauses[#clauses+1] = ast.verify_clause("when", cond, {}, cpos)

    else
      p:skip_to_eol()
    end
  end

  if p:at("DEDENT") then p:adv() end
  return ast.verify_decl(label, clauses, doc, tpos)
end

--- Parse a `test "label": setup:/run:/expect:` declaration.
--- Handles both `test "label":` (IDENT form) and `test:` (NAMED_ARG form).
local function parse_test_decl(p, _doc)
  local tpos = p:cur().pos
  local is_named_arg = p:cur().kind == "NAMED_ARG"
  p:adv()  -- consume IDENT("test") or NAMED_ARG("test:")

  local label = nil
  if not is_named_arg then
    if p:at("STRING") then label = p:adv().value end
    p:expect("OP", ":", "expected ':' after test label")
  end
  p:match("NEWLINE")

  local setup  = {}
  local run    = {}
  local expect = {}

  if not p:at("INDENT") then
    return ast.test_decl(label, setup, run, expect, tpos)
  end
  p:adv()  -- consume INDENT

  while not p:at("DEDENT") and not p:at("EOF") do
    p:skip_newlines()
    if p:at("DEDENT") or p:at("EOF") then break end
    local ct = p:cur()
    local section = (ct.kind == "NAMED_ARG") and ct.value

    if section == "setup" then
      p:adv(); p:skip_to_eol()
      if p:at("INDENT") then
        setup = parse_body_items(p, false)
      end

    elseif section == "run" then
      p:adv(); p:skip_to_eol()
      if p:at("INDENT") then
        run = parse_body_items(p, false)
      end

    elseif section == "expect" then
      p:adv(); p:skip_to_eol()
      if p:at("INDENT") then
        p:adv()
        while not p:at("DEDENT") and not p:at("EOF") do
          p:skip_newlines()
          if p:at("DEDENT") or p:at("EOF") then break end
          local ae = parse_expr(p); p:skip_to_eol()
          if ae then expect[#expect+1] = ae end
        end
        if p:at("DEDENT") then p:adv() end
      end

    else
      p:skip_to_eol()
    end
  end

  if p:at("DEDENT") then p:adv() end
  return ast.test_decl(label, setup, run, expect, tpos)
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
    local label
    -- parse_expr may greedily absorb a trailing STRING label as the last
    -- function-call argument: `watch-when name "label"` becomes
    -- fn_call(name, [string_lit("label")]).  Detect and recover it.
    local K = ast.K
    if cond and cond.kind == K.FN_CALL then
      local args = cond.args or {}
      local last = args[#args]
      if last and last.kind == K.STRING_LIT then
        label = last.value
        args[#args] = nil
      end
    end
    if not label then label = consume_label() end
    return ast.watch_when_decl(cond, label, tpos)
  end
end


-- ── `tag name` declaration ───────────────────────────────────────────────────
local function parse_tag_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "tag"
  local name = p:at("IDENT") and p:adv().value or "?"
  p:skip_to_eol()
  return ast.tag_decl(name, tpos)
end

-- ── `hook` declaration ───────────────────────────────────────────────────────
-- Syntax variants:
--   hook tag-name:                         → hooks pre:/post: body for that tag
--     pre:  stmt...
--     post: stmt...
--   hook after: fn-name:                   → post-hook for a specific function
--     stmt...
--   hook before: fn-name:                  → pre-hook for a specific function
--     stmt...
local function parse_hook_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume KEYWORD "hook"

  -- Determine hook kind
  local hook_kind, target

  -- `after:` and `before:` are tokenized as NAMED_ARG by the lexer.
  if p:at("NAMED_ARG", "after") then
    p:adv()  -- consume NAMED_ARG("after") — colon already consumed
    -- fn-name follows as NAMED_ARG (e.g. `foo:`) or IDENT
    if p:at("NAMED_ARG") then
      target = p:adv().value
    elseif p:at("IDENT") then
      target = p:adv().value
      p:match("OP", ":")
    end
    hook_kind = "fn_after"
  elseif p:at("NAMED_ARG", "before") then
    p:adv()  -- consume NAMED_ARG("before")
    if p:at("NAMED_ARG") then
      target = p:adv().value
    elseif p:at("IDENT") then
      target = p:adv().value
      p:match("OP", ":")
    end
    hook_kind = "fn_before"
  elseif p:at("KEYWORD", "after") or p:at("IDENT", "after") then
    p:adv()  -- consume "after"
    p:match("OP", ":")
    if p:at("NAMED_ARG") then
      target = p:adv().value
    elseif p:at("IDENT") then
      target = p:adv().value
      p:match("OP", ":")
    end
    hook_kind = "fn_after"
  elseif p:at("KEYWORD", "before") or p:at("IDENT", "before") then
    p:adv()  -- consume "before"
    p:match("OP", ":")
    if p:at("NAMED_ARG") then
      target = p:adv().value
    elseif p:at("IDENT") then
      target = p:adv().value
      p:match("OP", ":")
    end
    hook_kind = "fn_before"
  elseif p:at("NAMED_ARG") then
    -- "tag-name:" — NAMED_ARG already consumed the colon
    target    = p:adv().value
    hook_kind = nil  -- determined below from pre:/post: sub-blocks
  elseif p:at("IDENT") then
    target    = p:adv().value
    p:match("OP", ":")
    hook_kind = nil  -- determined below from pre:/post: sub-blocks
  else
    p:emit_err(ast.E.BAD_DECLARATION, "expected hook target after 'hook'", tpos)
    p:skip_to_eol()
    return nil
  end

  p:match("NEWLINE")

  -- Parse body: either a raw body block (for fn_before/fn_after)
  -- or an inner block with pre:/post: sub-blocks (for tag hooks)
  local result = {}

  if hook_kind == "fn_before" or hook_kind == "fn_after" then
    -- Direct body
    local body = parse_body_items(p, false)
    result[#result+1] = ast.hook_decl(hook_kind, target, body, doc, tpos)
  else
    -- Tag hook: look for pre:/post: sub-blocks inside an INDENT block
    if p:at("INDENT") then
      p:adv()
      while not p:at("DEDENT") and not p:at("EOF") do
        p:skip_newlines()
        if p:at("DEDENT") or p:at("EOF") then break end
        local sub = p:cur()
        -- `pre:` and `post:` are NAMED_ARG tokens inside the indented block.
        local is_pre_post = (sub.kind == "KEYWORD" and (sub.value == "pre" or sub.value == "post"))
                         or (sub.kind == "NAMED_ARG" and (sub.value == "pre" or sub.value == "post"))
        if is_pre_post then
          local timing = sub.value
          p:adv()  -- consume KEYWORD/NAMED_ARG for "pre" or "post"
          -- KEYWORD "pre"/"post" still has a colon to consume; NAMED_ARG already ate it
          if sub.kind == "KEYWORD" then p:match("OP", ":") end
          local body
          if p:at("NEWLINE") then
            p:adv()
            body = parse_body_items(p, false)
          else
            local stmt = parse_stmt(p)
            body = stmt and {stmt} or {}
            p:skip_to_eol()
          end
          local hk = (timing == "pre") and "tag_pre" or "tag_post"
          result[#result+1] = ast.hook_decl(hk, target, body, doc, tpos)
        else
          p:skip_to_eol()
        end
      end
      if p:at("DEDENT") then p:adv() end
    else
      -- Single-line hook with no sub-block: treat as post
      local body = {}
      local stmt = parse_stmt(p)
      if stmt then body[1] = stmt end
      p:skip_to_eol()
      result[#result+1] = ast.hook_decl("tag_post", target, body, doc, tpos)
    end
  end

  -- Return multiple nodes if we parsed both pre and post blocks.
  -- The caller's parse_file_decls handles single nodes, so wrap in a
  -- sentinel that parse_file_decls will flatten.
  if #result == 1 then return result[1] end
  if #result == 0 then return nil end
  -- Return as a special multi-decl wrapper (parse_file_decls will handle it)
  return { _multi_decl = true, decls = result }
end

-- ── Speaker declaration ──────────────────────────────────────────────────────

local function parse_speaker_decl(p, doc)
  local tpos = p:cur().pos
  p:adv()  -- consume "speaker"
  local name
  if p:at("NAMED_ARG") then
    name = p:adv().value
  elseif p:at("IDENT") then
    name = p:adv().value
    p:expect("OP", ":", "expected ':' after speaker name")
  else
    p:emit_err(ast.E.BAD_DECLARATION, "expected speaker name after 'speaker'", p:cur().pos)
    p:skip_to_eol(); return nil
  end
  local display, color = nil, nil
  p:skip_newlines()
  if p:at("INDENT") then
    p:adv()  -- consume INDENT
    while not p:at("DEDENT") and not p:at("EOF") do
      p:skip_newlines()
      if p:at("DEDENT") or p:at("EOF") then break end
      local ft = p:cur()
      if ft.kind == "NAMED_ARG" then
        local fname = ft.value; p:adv()
        local sv = p:cur()
        if fname == "display" and sv.kind == "STRING" then
          display = sv.value; p:adv()
        elseif fname == "color" and sv.kind == "STRING" then
          color = sv.value; p:adv()
        end
      end
      p:skip_to_eol()
    end
    if p:at("DEDENT") then p:adv() end
  end
  return ast.speaker_decl(name, display, color, doc, tpos)
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
    elseif t.value == "tag"        then return parse_tag_decl(p, doc)
    elseif t.value == "hook"       then return parse_hook_decl(p, doc)
    elseif t.value == "watch"
        or t.value == "watch-when" then return parse_watch_decl(p, doc)
    elseif t.value == "bounded"    then return parse_bounded_decl(p, doc)
    elseif t.value == "macro"      then return parse_macro_decl(p, doc)
    elseif t.value == "speaker"    then return parse_speaker_decl(p, doc)
    else
      p:skip_to_eol()
      p:skip_block()
      return nil
    end

  elseif t.kind == "NAMED_ARG" then
    if     t.value == "schema-version" then return parse_schema_version(p, doc)
    elseif t.value == "engine-config"  then return parse_engine_config(p, doc)
    elseif t.value == "time-model"     then return parse_time_model(p, doc)
    elseif t.value == "test"           then return parse_test_decl(p, doc)
    else
      p:emit_err(ast.E.BAD_DECLARATION,
        "unexpected named argument '" .. t.value .. "' at top level", t.pos)
      p:skip_to_eol()
      return nil
    end

  elseif t.kind == "IDENT" then
    if     t.value == "migration" then return parse_migration_decl(p, doc)
    elseif t.value == "defgrid"   then return parse_defgrid_decl(p, doc)
    elseif t.value == "test"      then return parse_test_decl(p, doc)
    end
    -- unknown top-level identifier — skip
    p:emit_err(ast.E.UNEXPECTED_TOKEN,
      "unexpected IDENT '" .. t.value .. "' at top level", t.pos)
    p:skip_to_eol()
    p:skip_block()
    return nil

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
    if decl then
      -- parse_hook_decl may return a multi-decl wrapper when it produces
      -- both a pre: and a post: hook node from one hook block.
      if decl._multi_decl then
        for _, d in ipairs(decl.decls or {}) do
          table.insert(decls, d)
        end
      else
        table.insert(decls, decl)
      end
    end
    doc = nil

    p:skip_newlines()

    -- Safety guard: if nothing was consumed, force advance to prevent infinite loop
    if p.pos == prev then p:adv() end
  end

  local prog_pos = decls[1] and decls[1].pos or ast.pos(filename, 1, 1)
  return ast.program(decls, prog_pos), p.diags
end

return M

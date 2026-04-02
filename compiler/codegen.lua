-- compiler/codegen.lua
-- Emit a compiled game table from a typed AST.
--
-- Phase 1 deliverable: emit the schema section from a schema-only file.
--
-- The compiled game table structure:
--   schema   — types, state paths with defaults, relations, time model,
--               engine config, counts, and state-space size
--   fns      — compiled function bodies (empty in Phase 1)
--   verifies — compiled verify blocks (empty in Phase 1)
--   watches  — watch/watch-when declarations (empty in Phase 1)

local M = {}

local ast = require("compiler.ast")

-- ============================================================
-- State-space size computation
-- ============================================================

--- Compute the state-space size of a type expression node.
--- Returns a non-negative integer, or math.huge for unbounded types.
--- Returns 0 for types that cannot be resolved (undefined references).
local function state_space_size(texpr, symtab)
  if not texpr then return 0 end
  local k = ast.K

  if texpr.kind == k.TYPE_BOOL then
    return 2

  elseif texpr.kind == k.TYPE_INT then
    local lo = texpr.min or 0
    local hi = texpr.max or 0
    if hi < lo then return 0 end  -- malformed; checker already reported error
    return hi - lo + 1

  elseif texpr.kind == k.TYPE_ENUM_INLINE then
    return #(texpr.values or {})

  elseif texpr.kind == k.TYPE_SYMBOL then
    return math.huge   -- untyped symbol: unbounded

  elseif texpr.kind == k.TYPE_SYMBOL_OF then
    -- Size = number of declared family members; unknown at this phase → huge
    return math.huge

  elseif texpr.kind == k.TYPE_OPTION then
    local inner = state_space_size(texpr.inner, symtab)
    if inner == math.huge then return math.huge end
    return inner + 1

  elseif texpr.kind == k.TYPE_SET then
    -- |Set(T, max)| = Σ C(|T|, i) for i = 0..max
    local t = state_space_size(texpr.inner, symtab)
    local mx = texpr.max or 0
    if t == math.huge then return math.huge end
    local total = 0
    local c = 1
    for i = 0, math.min(mx, t) do
      total = total + c
      if i < mx then
        c = c * (t - i) // (i + 1)
      end
    end
    return total

  elseif texpr.kind == k.TYPE_LIST then
    -- |List(T, max)| = (|T| + 1)^max
    local t = state_space_size(texpr.inner, symtab)
    local mx = texpr.max or 0
    if t == math.huge then return math.huge end
    return (t + 1) ^ mx

  elseif texpr.kind == k.TYPE_STRING or texpr.kind == k.TYPE_FLOAT
      or texpr.kind == k.TYPE_ULIST or texpr.kind == k.TYPE_UMAP then
    return math.huge   -- superficial / unbounded

  elseif texpr.kind == k.TYPE_NAMED then
    -- Look up the declared type in the symbol table
    local decl = texpr.resolved
    if not decl then return 0 end  -- unresolved; checker already reported
    if decl.builtin then return math.huge end  -- shouldn't happen for named types
    return state_space_size_of_decl(decl, symtab)

  elseif texpr.kind == k.TYPE_FN then
    return math.huge  -- function types have unbounded state space

  end

  return 0
end

--- Compute the state-space size of a type declaration node.
--- Defined after state_space_size to allow mutual recursion guard.
state_space_size_of_decl = function(decl, symtab)
  if not decl then return 0 end
  local k = ast.K

  if decl.kind == k.TYPE_ENUM then
    return #(decl.values or {})

  elseif decl.kind == k.TYPE_ALIAS then
    return state_space_size(decl.type_expr, symtab)

  elseif decl.kind == k.TYPE_RECORD then
    -- Product of all field sizes
    local product = 1
    for _, field in ipairs(decl.fields or {}) do
      if field.kind == k.RECORD_FIELD then
        local fs = state_space_size(field.type_expr, symtab)
        if fs == math.huge then return math.huge end
        product = product * fs
      end
      -- WITH_MIXIN fields are already spliced in the checker; skip here
    end
    return product

  elseif decl.kind == k.TYPE_VARIANT then
    -- Sum of branch sizes
    local total = 0
    for _, branch in ipairs(decl.branches or {}) do
      if branch.kind == k.VARIANT_BRANCH then
        local bsize = 1
        for _, field in ipairs(branch.fields or {}) do
          if field.kind == k.RECORD_FIELD then
            local fs = state_space_size(field.type_expr, symtab)
            if fs == math.huge then return math.huge end
            bsize = bsize * fs
          end
        end
        total = total + bsize
      end
    end
    return total
  end

  return 0
end

-- ============================================================
-- Schema section emitters
-- ============================================================

--- Emit a compact serialisable descriptor for a type expression.
local function emit_type_desc(texpr)
  if not texpr then return { tag = "unknown" } end
  local k = ast.K

  if texpr.kind == k.TYPE_BOOL    then return { tag = "bool" }
  elseif texpr.kind == k.TYPE_INT then return { tag = "int", min = texpr.min, max = texpr.max }
  elseif texpr.kind == k.TYPE_ENUM_INLINE then
    return { tag = "enum", values = texpr.values }
  elseif texpr.kind == k.TYPE_OPTION then
    return { tag = "option", inner = emit_type_desc(texpr.inner) }
  elseif texpr.kind == k.TYPE_SET then
    return { tag = "set", inner = emit_type_desc(texpr.inner), max = texpr.max }
  elseif texpr.kind == k.TYPE_LIST then
    return { tag = "list", inner = emit_type_desc(texpr.inner), max = texpr.max }
  elseif texpr.kind == k.TYPE_SYMBOL    then return { tag = "symbol" }
  elseif texpr.kind == k.TYPE_SYMBOL_OF then return { tag = "symbol_of", family = texpr.family }
  elseif texpr.kind == k.TYPE_STRING    then return { tag = "string" }
  elseif texpr.kind == k.TYPE_FLOAT     then return { tag = "float" }
  elseif texpr.kind == k.TYPE_ULIST then
    return { tag = "ulist", inner = emit_type_desc(texpr.inner) }
  elseif texpr.kind == k.TYPE_UMAP then
    return { tag = "umap", key = emit_type_desc(texpr.key), val = emit_type_desc(texpr.val) }
  elseif texpr.kind == k.TYPE_NAMED then
    return { tag = "named", name = texpr.name }
  elseif texpr.kind == k.TYPE_FN then
    return { tag = "fn" }
  end
  return { tag = "unknown" }
end

--- Emit a compact descriptor for a literal default value.
local function emit_default(node)
  if not node then return nil end
  local k = ast.K

  if node.kind == k.INT_LIT     then return { tag = "int",    value = node.value }
  elseif node.kind == k.FLOAT_LIT   then return { tag = "float",  value = node.value }
  elseif node.kind == k.BOOL_LIT    then return { tag = "bool",   value = node.value }
  elseif node.kind == k.STRING_LIT  then return { tag = "string", value = node.value }
  elseif node.kind == k.MULTILINE_STRING then
    return { tag = "string", value = node.value }
  elseif node.kind == k.SYMBOL_LIT  then return { tag = "symbol", name = node.name }
  elseif node.kind == k.EMPTY_SET   then return { tag = "empty_set" }
  elseif node.kind == k.EMPTY_LIST  then return { tag = "empty_list" }
  elseif node.kind == k.EMPTY_MAP   then return { tag = "empty_map" }
  elseif node.kind == k.RECORD_CONSTRUCTOR then
    local fields = {}
    for _, f in ipairs(node.fields or {}) do
      if f.kind == k.NAMED_ARG then
        fields[f.name] = emit_default(f.value)
      end
    end
    return { tag = "record", type_name = node.type_name, fields = fields }
  end
  return nil
end

--- Emit schema.types list from all type declarations.
local function emit_types(decls)
  local types = {}
  local k = ast.K
  for _, node in ipairs(decls) do
    if node.kind == k.TYPE_ENUM then
      table.insert(types, {
        kind   = "enum",
        name   = node.name,
        values = node.values,
        doc    = node.doc,
      })

    elseif node.kind == k.TYPE_ALIAS then
      table.insert(types, {
        kind      = "alias",
        name      = node.name,
        type_desc = emit_type_desc(node.type_expr),
        doc       = node.doc,
      })

    elseif node.kind == k.TYPE_RECORD then
      local fields = {}
      for _, f in ipairs(node.fields or {}) do
        if f.kind == k.RECORD_FIELD then
          table.insert(fields, {
            name      = f.name,
            type_desc = emit_type_desc(f.type_expr),
            default   = emit_default(f.default),
            doc       = f.doc,
          })
        elseif f.kind == k.WITH_MIXIN then
          table.insert(fields, { mixin = f.type_name })
        end
      end
      table.insert(types, {
        kind   = "record",
        name   = node.name,
        fields = fields,
        doc    = node.doc,
      })

    elseif node.kind == k.TYPE_VARIANT then
      local branches = {}
      for _, b in ipairs(node.branches or {}) do
        if b.kind == k.VARIANT_BRANCH then
          local bfields = {}
          for _, f in ipairs(b.fields or {}) do
            if f.kind == k.RECORD_FIELD then
              table.insert(bfields, {
                name      = f.name,
                type_desc = emit_type_desc(f.type_expr),
              })
            end
          end
          table.insert(branches, { name = b.name, fields = bfields })
        end
      end
      table.insert(types, {
        kind     = "variant",
        name     = node.name,
        branches = branches,
        doc      = node.doc,
      })
    end
  end
  return types
end

--- Emit schema.states list from all state declarations.
local function emit_states(decls)
  local states = {}
  local k = ast.K
  for _, node in ipairs(decls) do
    if node.kind == k.STATE_SCALAR then
      local path_str
      if node.path and node.path.segments then
        path_str = table.concat(node.path.segments, "/")
      else
        path_str = "?"
      end
      table.insert(states, {
        kind      = "scalar",
        path      = path_str,
        type_desc = emit_type_desc(node.type_expr),
        default   = emit_default(node.default),
        doc       = node.doc,
      })

    elseif node.kind == k.STATE_RECORD then
      local path_str
      if node.path and node.path.segments then
        path_str = table.concat(node.path.segments, "/")
      else
        path_str = "?"
      end
      local fields = {}
      for _, f in ipairs(node.fields or {}) do
        if f.kind == k.RECORD_FIELD then
          table.insert(fields, {
            name      = f.name,
            type_desc = emit_type_desc(f.type_expr),
            default   = emit_default(f.default),
          })
        end
      end
      table.insert(states, {
        kind   = "record",
        path   = path_str,
        fields = fields,
        doc    = node.doc,
      })

    elseif node.kind == k.STATE_FAMILY then
      table.insert(states, {
        kind      = "family",
        family    = node.family,
        var       = node.var,
        type_desc = emit_type_desc(node.type_expr),
        max       = node.max,
        doc       = node.doc,
      })
    end
  end
  return states
end

--- Emit schema.relations list.
local function emit_relations(decls)
  local relations = {}
  local k = ast.K
  for _, node in ipairs(decls) do
    if node.kind == k.RELATION_DECL then
      table.insert(relations, {
        name          = node.name,
        from_type     = node.from_type,
        to_type_desc  = emit_type_desc(node.to_type_expr),
        initial_count = #(node.initial_data or {}),
        doc           = node.doc,
      })
    end
  end
  return relations
end

--- Collect engine-config keys into a flat table.
local function emit_engine_config(decls)
  local k = ast.K
  local cfg = {}
  for _, node in ipairs(decls) do
    if node.kind == k.ENGINE_CONFIG then
      for _, pair in ipairs(node.keys or {}) do
        cfg[pair.key] = pair.value
      end
    end
  end
  return cfg
end

--- Collect time-model axes and wrap into a descriptor.
local function emit_time_model(decls)
  local k = ast.K
  for _, node in ipairs(decls) do
    if node.kind == k.TIME_MODEL then
      return { axes = node.axes, wrap = node.wrap }
    end
  end
  return nil
end

--- Collect schema-version number.
local function emit_schema_version(decls)
  local k = ast.K
  for _, node in ipairs(decls) do
    if node.kind == k.SCHEMA_VERSION then
      return node.version
    end
  end
  return nil
end

--- Compute total state-space size across all state declarations.
local function compute_total_state_space(decls, symtab)
  local k = ast.K
  local total = 1
  for _, node in ipairs(decls) do
    local sz
    if node.kind == k.STATE_SCALAR then
      sz = state_space_size(node.type_expr, symtab)
    elseif node.kind == k.STATE_RECORD then
      sz = 1
      for _, f in ipairs(node.fields or {}) do
        if f.kind == k.RECORD_FIELD then
          local fs = state_space_size(f.type_expr, symtab)
          if fs == math.huge then sz = math.huge; break end
          sz = sz * fs
        end
      end
    elseif node.kind == k.STATE_FAMILY then
      local member_sz = state_space_size(node.type_expr, symtab)
      local mx = node.max or 0
      if member_sz == math.huge then
        sz = math.huge
      else
        -- Approximate: (member_sz + 1)^max  (each slot: value or absent)
        sz = (member_sz + 1) ^ mx
      end
    end
    if sz then
      if sz == math.huge then return math.huge end
      total = total * sz
    end
  end
  return total
end

-- ============================================================
-- Function and scene emission
-- ============================================================

--- Emit the fns table: name → fn descriptor with params, pre, post, body, is_transaction.
--- The body/pre/post fields are AST node trees that the runtime evaluator interprets.
local function emit_fns(decls)
  local fns = {}
  local k = ast.K
  for _, node in ipairs(decls) do
    if node.kind == k.FN_DECL then
      fns[node.name] = {
        name           = node.name,
        params         = node.params or {},
        pre            = node.pre or {},
        post           = node.post or {},
        body           = node.body or {},
        is_transaction = node.is_transaction or false,
        doc            = node.doc,
      }
    end
  end
  return fns
end

--- Emit the scenes table: name → scene descriptor with body.
--- The body is a list of scene element AST nodes (narration, choices, gotos).
local function emit_scenes(decls)
  local scenes = {}
  local k = ast.K
  for _, node in ipairs(decls) do
    if node.kind == k.SCENE_DECL then
      scenes[node.name] = {
        name = node.name,
        body = node.body or {},
        doc  = node.doc,
      }
    end
  end
  return scenes
end

-- ============================================================
-- Public API
-- ============================================================

--- Emit a compiled game table from a typed AST.
---
--- Returns (game_table, diags):
---   game_table — compiled Lua table, or nil on fatal error
---   diags      — list of diagnostic tables
---
---@param typed_ast table  Typed AST root (with .symtab attached by checker)
---@return table, table
function M.emit(typed_ast)
  local diags   = {}
  local decls   = typed_ast.decls or {}
  local symtab  = typed_ast.symtab or { types = {}, states = {}, relations = {} }

  local types     = emit_types(decls)
  local states    = emit_states(decls)
  local relations = emit_relations(decls)
  local eng_cfg   = emit_engine_config(decls)
  local time_mdl  = emit_time_model(decls)
  local schema_v  = emit_schema_version(decls)
  local ss_size   = compute_total_state_space(decls, symtab)

  -- Count unique type/state/relation entries
  local type_count     = 0
  for _ in pairs(symtab.types)     do type_count     = type_count     + 1 end
  local path_count     = 0
  for _ in pairs(symtab.states)    do path_count     = path_count     + 1 end
  local relation_count = 0
  for _ in pairs(symtab.relations) do relation_count = relation_count + 1 end
  local scene_count = 0
  for _, d in ipairs(decls) do
    if d.kind == ast.K.SCENE_DECL then scene_count = scene_count + 1 end
  end

  local game_table = {
    schema = {
      version          = schema_v,
      type_count       = type_count,
      path_count       = path_count,
      scene_count      = scene_count,
      relation_count   = relation_count,
      state_space_size = ss_size == math.huge and "unbounded" or ss_size,
      types            = types,
      states           = states,
      relations        = relations,
      engine_config    = eng_cfg,
      time_model       = time_mdl,
    },
    fns      = emit_fns(decls),
    scenes   = emit_scenes(decls),
    verifies = {},
    watches  = {},
  }

  return game_table, diags
end

return M

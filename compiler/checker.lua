-- compiler/checker.lua
-- Type checker and analyser.  Runs multiple sub-passes over the AST:
--
--   Pass 1 — Schema collection: gather all type/state/relation names,
--             resolve named type references, detect duplicates.
--   Pass 2 — Basic type-check: field types reference declared types,
--             record field defaults are kind-correct, Int bounds well-formed,
--             with-mixin splicing and conflict detection.
--
-- Passes 3-6 (pure/transaction inference, write-set analysis, state-space
-- computation, contract validation) are not yet implemented.
--
-- The checker annotates AST nodes in-place (adds a `resolved` field to
-- TYPE_NAMED nodes) and returns the same tree with diagnostics.

local M = {}

local ast = require("compiler.ast")

-- ============================================================
-- Symbol table
-- ============================================================

--- Build a fresh empty symbol table.
local function new_symtab()
  return {
    types     = {},  -- name → TYPE_ENUM / TYPE_ALIAS / TYPE_RECORD / TYPE_VARIANT node
    states    = {},  -- path-string → STATE_SCALAR / STATE_RECORD / STATE_FAMILY node
    relations = {},  -- name → RELATION_DECL node
  }
end

-- ============================================================
-- Diagnostic accumulator
-- ============================================================

local function new_accum(filename)
  return { filename = filename, diags = {} }
end

local function err(acc, code, msg, pos, note)
  table.insert(acc.diags, ast.error(code, msg, pos, note))
end

-- ============================================================
-- Built-in type names (always resolvable without a declaration)
-- ============================================================

local BUILTIN_TYPES = {
  Bool = true, Int = true, Enum = true, Option = true,
  Set  = true, List = true, Symbol = true, SymbolOf = true,
  String = true, Float = true, UList = true, UMap = true,
}

-- ============================================================
-- Pass 1 — Schema collection
-- ============================================================

--- Register a type declaration in the symbol table.
--- Emits DUPLICATE_NAME if the name is already registered.
local function register_type(acc, symtab, node)
  local name = node.name
  if BUILTIN_TYPES[name] then
    err(acc, ast.E.DUPLICATE_NAME,
      "'" .. name .. "' shadows a built-in type", node.pos)
    return
  end
  if symtab.types[name] then
    err(acc, ast.E.DUPLICATE_NAME,
      "type '" .. name .. "' already declared",
      node.pos,
      "previous declaration at line " .. symtab.types[name].pos.line)
    return
  end
  symtab.types[name] = node
end

--- Convert a path AST node to a canonical string key for the state table.
local function path_key(path_node)
  local k = ast.K
  if path_node.kind == k.PATH_EXPR then
    return table.concat(path_node.segments, "/")
  elseif path_node.kind == k.INTERP_PATH then
    local parts = {}
    for _, seg in ipairs(path_node.segments) do
      if type(seg) == "table" and seg.interp then
        table.insert(parts, "{" .. seg.interp .. "}")
      else
        table.insert(parts, seg)
      end
    end
    return table.concat(parts, "/")
  end
  return "?"
end

--- Collect all top-level names into symtab.
local function pass1_collect(acc, symtab, program)
  local k = ast.K
  for _, node in ipairs(program.decls) do
    local kind = node.kind

    if kind == k.TYPE_ENUM or kind == k.TYPE_ALIAS
    or kind == k.TYPE_RECORD or kind == k.TYPE_VARIANT then
      register_type(acc, symtab, node)

    elseif kind == k.STATE_SCALAR or kind == k.STATE_RECORD then
      local key = path_key(node.path)
      if symtab.states[key] then
        err(acc, ast.E.DUPLICATE_NAME,
          "state path '" .. key .. "' already declared",
          node.pos,
          "previous declaration at line " .. symtab.states[key].pos.line)
      else
        symtab.states[key] = node
      end

    elseif kind == k.STATE_FAMILY then
      local key = node.family .. "/{" .. (node.var or "?") .. "}"
      if symtab.states[key] then
        err(acc, ast.E.DUPLICATE_NAME,
          "state family '" .. key .. "' already declared", node.pos)
      else
        symtab.states[key] = node
      end

    elseif kind == k.RELATION_DECL then
      local name = node.name
      if symtab.relations[name] then
        err(acc, ast.E.DUPLICATE_NAME,
          "relation '" .. name .. "' already declared", node.pos)
      else
        symtab.relations[name] = node
      end
    end
    -- MODULE_DECL, IMPORT_DECL, SCHEMA_VERSION, ENGINE_CONFIG, TIME_MODEL
    -- are informational and need no symbol registration.
  end
end

-- ============================================================
-- Pass 2 — Basic type-check
-- ============================================================

--- Resolve a TYPE_NAMED reference against the symbol table.
--- Annotates the node with node.resolved = symtab.types[name] or a built-in marker.
--- Emits UNDEFINED_TYPE if not found.
local function resolve_type_named(acc, symtab, node)
  if node.kind ~= ast.K.TYPE_NAMED then return end
  local name = node.name
  if BUILTIN_TYPES[name] then
    node.resolved = { builtin = true, name = name }
    return
  end
  local decl = symtab.types[name]
  if decl then
    node.resolved = decl
  else
    err(acc, ast.E.UNDEFINED_TYPE,
      "undefined type '" .. name .. "'", node.pos)
    node.resolved = nil
  end
end

--- Recursively resolve all TYPE_NAMED nodes in a type expression tree.
local function resolve_type_expr(acc, symtab, texpr)
  if not texpr then return end
  local k = ast.K
  local kind = texpr.kind

  if kind == k.TYPE_NAMED then
    resolve_type_named(acc, symtab, texpr)
  elseif kind == k.TYPE_OPTION then
    resolve_type_expr(acc, symtab, texpr.inner)
  elseif kind == k.TYPE_SET then
    resolve_type_expr(acc, symtab, texpr.inner)
  elseif kind == k.TYPE_LIST then
    resolve_type_expr(acc, symtab, texpr.inner)
  elseif kind == k.TYPE_ULIST then
    resolve_type_expr(acc, symtab, texpr.inner)
  elseif kind == k.TYPE_UMAP then
    resolve_type_expr(acc, symtab, texpr.key)
    resolve_type_expr(acc, symtab, texpr.val)
  elseif kind == k.TYPE_FN then
    for _, pt in ipairs(texpr.param_types or {}) do
      resolve_type_expr(acc, symtab, pt)
    end
    resolve_type_expr(acc, symtab, texpr.return_type)
  elseif kind == k.TYPE_INT then
    -- Check bounds well-formedness
    if texpr.min ~= nil and texpr.max ~= nil and texpr.min > texpr.max then
      err(acc, ast.E.BAD_INT_BOUNDS,
        "Int bounds out of order: min=" .. texpr.min .. " > max=" .. texpr.max,
        texpr.pos)
    end
  end
  -- TYPE_BOOL, TYPE_ENUM_INLINE, TYPE_SYMBOL, TYPE_SYMBOL_OF,
  -- TYPE_STRING, TYPE_FLOAT: no sub-expressions to resolve
end

--- Check record fields: resolve types, check mixin references, detect conflicts.
--- Returns a flat field-name set (the "effective" fields after mixin expansion).
local function check_record_fields(acc, symtab, fields, record_name)
  local seen = {}       -- fieldname → source (record_name or mixin name)
  local mixin_sources = {} -- track which mixin contributes which fields

  for _, item in ipairs(fields) do
    local k = ast.K
    if item.kind == k.RECORD_FIELD then
      -- Resolve the field's type
      resolve_type_expr(acc, symtab, item.type_expr)
      local fname = item.name
      if seen[fname] then
        -- Override from within the same record body is allowed (e.g. after with)
        -- only if the previous contributor was a mixin (not the record itself).
        local prev_src = seen[fname]
        if prev_src == record_name then
          err(acc, ast.E.DUPLICATE_NAME,
            "field '" .. fname .. "' declared twice in '" .. record_name .. "'",
            item.pos)
        end
        -- Override after mixin: allowed (default override). No error.
      else
        seen[fname] = record_name
      end

    elseif item.kind == k.WITH_MIXIN then
      local mixin_name = item.type_name
      local mixin_decl = symtab.types[mixin_name]
      if not mixin_decl then
        err(acc, ast.E.UNDEFINED_TYPE,
          "mixin type '" .. mixin_name .. "' not declared", item.pos)
      elseif mixin_decl.kind ~= k.TYPE_RECORD then
        err(acc, ast.E.TYPE_MISMATCH,
          "'" .. mixin_name .. "' is not a record type and cannot be used as a mixin",
          item.pos)
      else
        -- Register mixin fields; detect conflicts between two different mixins
        for _, mf in ipairs(mixin_decl.fields or {}) do
          if mf.kind == k.RECORD_FIELD then
            local fname = mf.name
            if seen[fname] then
              local prev = seen[fname]
              if prev ~= record_name and prev ~= mixin_name then
                -- Two different mixins contribute the same field
                err(acc, ast.E.CONFLICTING_WITH,
                  "field '" .. fname .. "' appears in both '" ..
                  prev .. "' and '" .. mixin_name .. "'",
                  item.pos)
              end
            else
              seen[fname] = mixin_name
              mixin_sources[fname] = mixin_name
            end
          end
        end
      end
      item.resolved = mixin_decl
    end
  end

  return seen
end

--- Check a single top-level declaration.
local function check_decl(acc, symtab, node)
  local k = ast.K

  if node.kind == k.TYPE_ALIAS then
    resolve_type_expr(acc, symtab, node.type_expr)

  elseif node.kind == k.TYPE_ENUM then
    -- Validate that there are at least 2 values (a 1-value enum is technically
    -- legal but useless; we allow it with no warning for now)
    -- Nothing to resolve — enum values are self-defining symbols

  elseif node.kind == k.TYPE_RECORD then
    check_record_fields(acc, symtab, node.fields or {}, node.name)

  elseif node.kind == k.TYPE_VARIANT then
    for _, branch in ipairs(node.branches or {}) do
      if branch.kind == k.VARIANT_BRANCH then
        for _, field in ipairs(branch.fields or {}) do
          resolve_type_expr(acc, symtab, field.type_expr)
        end
      end
    end

  elseif node.kind == k.STATE_SCALAR then
    resolve_type_expr(acc, symtab, node.type_expr)

  elseif node.kind == k.STATE_RECORD then
    for _, field in ipairs(node.fields or {}) do
      if field.kind == k.RECORD_FIELD then
        resolve_type_expr(acc, symtab, field.type_expr)
      end
    end

  elseif node.kind == k.STATE_FAMILY then
    resolve_type_expr(acc, symtab, node.type_expr)

  elseif node.kind == k.RELATION_DECL then
    -- Resolve from_type name
    if node.from_type then
      local ft_node = { kind = k.TYPE_NAMED, name = node.from_type, pos = node.pos }
      resolve_type_named(acc, symtab, ft_node)
      node.from_type_resolved = ft_node.resolved
    end
    resolve_type_expr(acc, symtab, node.to_type_expr)
  end
  -- MODULE_DECL, IMPORT_DECL, SCHEMA_VERSION, ENGINE_CONFIG, TIME_MODEL:
  -- no type-check needed in Phase 1
end

--- Run pass 2 (type-check) over all declarations.
local function pass2_check(acc, symtab, program)
  for _, node in ipairs(program.decls) do
    check_decl(acc, symtab, node)
  end
end

-- ============================================================
-- Pass 3 — Pure / transaction inference
-- ============================================================
-- A function is a "transaction" if its body contains any mutation primitive
-- directly or if it calls a function that is a transaction.
-- Everything else is "pure".
--
-- This pass annotates every FN_DECL node with:
--   node.is_transaction = true | false
--
-- Errors emitted:
--   PURE_CALLS_MUT  — pre:/post: blocks contain a mutation primitive

-- Mutation primitive names (used when a mutation appears in expression position
-- and is parsed as a fn_call rather than a dedicated mutation node).
local MUTATION_NAMES = {
  ["set!"] = true, ["inc!"] = true, ["dec!"] = true, ["add!"] = true,
  ["remove!"] = true, ["clear!"] = true, ["push!"] = true, ["pop!"] = true,
  ["spawn!"] = true, ["despawn!"] = true, ["relate!"] = true,
  ["unrelate!"] = true, ["send!"] = true, ["undo!"] = true,
  ["time-inc!"] = true, ["goto-scene!"] = true,
  ["enter-scene!"] = true, ["exit-scene!"] = true,
}

--- Return true if a node subtree contains any mutation primitive.
local function has_mutation(node)
  if not node then return false end
  if ast.is_mut(node) then return true end
  -- A mutation primitive parsed in expression context becomes a fn_call node
  if node.kind == ast.K.FN_CALL and MUTATION_NAMES[node.name] then return true end
  -- Recurse into known child fields
  if node.body then
    for _, s in ipairs(node.body) do if has_mutation(s) then return true end end
  end
  if node.then_body then
    for _, s in ipairs(node.then_body) do if has_mutation(s) then return true end end
  end
  if node.else_body then
    for _, s in ipairs(node.else_body) do if has_mutation(s) then return true end end
  end
  if node.condition and has_mutation(node.condition) then return true end
  if node.expr     and has_mutation(node.expr)      then return true end
  if node.arms     then
    for _, a in ipairs(node.arms) do
      if type(a.body) == "table" then
        for _, s in ipairs(a.body) do if has_mutation(s) then return true end end
      elseif has_mutation(a.body) then return true end
    end
  end
  return false
end

--- Classify all fn_decl nodes as pure or transaction.
local function pass3_infer_purity(acc, program)
  local k = ast.K
  for _, node in ipairs(program.decls) do
    if node.kind == k.FN_DECL then
      -- Check body for mutations
      local body_has_mut = false
      for _, s in ipairs(node.body or {}) do
        if has_mutation(s) then body_has_mut = true; break end
      end
      node.is_transaction = body_has_mut

      -- pre: and post: blocks must be pure (no mutations allowed)
      for _, e in ipairs(node.pre or {}) do
        if has_mutation(e) then
          err(acc, ast.E.PURE_CALLS_MUT,
            "mutation primitive in pre: condition of '" .. (node.name or "?") .. "'",
            e.pos or node.pos)
        end
      end
      for _, e in ipairs(node.post or {}) do
        if has_mutation(e) then
          err(acc, ast.E.PURE_CALLS_MUT,
            "mutation primitive in post: condition of '" .. (node.name or "?") .. "'",
            e.pos or node.pos)
        end
      end
    end
  end
end

-- ============================================================
-- Public API
-- ============================================================

--- Check a parsed AST.
---
--- Returns (typed_ast, diags):
---   typed_ast — the AST annotated with resolved types (modified in-place)
---   diags     — list of diagnostic tables (errors and warnings)
---
---@param ast_root table   Root ast.program node from the parser
---@param filename string  File name for diagnostics
---@return table, table
function M.check(ast_root, filename)
  local acc    = new_accum(filename)
  local symtab = new_symtab()

  pass1_collect(acc, symtab, ast_root)
  pass2_check(acc, symtab, ast_root)
  pass3_infer_purity(acc, ast_root)

  -- Attach the symbol table to the AST root for use by codegen
  ast_root.symtab = symtab

  return ast_root, acc.diags
end

return M

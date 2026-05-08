-- compiler/checker.lua
-- Type checker and analyser.  Runs multiple sub-passes over the AST:
--
--   Pass 1 — Schema collection: gather all type/state/relation names,
--             resolve named type references, detect duplicates.
--   Pass 2 — Basic type-check: field types reference declared types,
--             record field defaults are kind-correct, Int bounds well-formed,
--             with-mixin splicing and conflict detection.
--
-- Pass 6 — Write-set analysis: compute the set of state paths each fn/scene
--           can write to; emit WRITE_UNTYPED_VAR / WRITE_DYNAMIC_PATH.
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
    scenes    = {},  -- name → SCENE_DECL node
    families  = {},  -- family_name → STATE_FAMILY node
    grids     = {},  -- name → DEFGRID_DECL node
    speakers  = {},  -- name → SPEAKER_DECL node
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
        symtab.families[node.family] = node
      end

    elseif kind == k.RELATION_DECL then
      local name = node.name
      if symtab.relations[name] then
        err(acc, ast.E.DUPLICATE_NAME,
          "relation '" .. name .. "' already declared", node.pos)
      else
        symtab.relations[name] = node
      end

    elseif kind == k.SCENE_DECL then
      local name = node.name
      if symtab.scenes[name] then
        err(acc, ast.E.DUPLICATE_NAME,
          "scene '" .. name .. "' already declared",
          node.pos,
          "previous declaration at line " .. symtab.scenes[name].pos.line)
      else
        symtab.scenes[name] = node
      end

    elseif kind == k.DEFGRID_DECL then
      local name = node.name
      if symtab.grids[name] then
        err(acc, ast.E.DUPLICATE_NAME,
          "defgrid '" .. name .. "' already declared",
          node.pos,
          "previous declaration at line " .. symtab.grids[name].pos.line)
      else
        symtab.grids[name] = node
      end

    elseif kind == k.SPEAKER_DECL then
      local name = node.name
      if symtab.speakers[name] then
        err(acc, ast.E.DUPLICATE_NAME,
          "speaker '" .. name .. "' already declared",
          node.pos,
          "previous declaration at line " .. symtab.speakers[name].pos.line)
      else
        symtab.speakers[name] = node
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
  elseif kind == k.TYPE_SYMBOL_OF then
    -- Validate that the argument refers to a declared entity family OR a named enum type
    local fname = texpr.family
    if fname then
      local is_family = symtab.families[fname] ~= nil
      local td = symtab.types[fname]
      local is_enum = td and (td.kind == k.TYPE_ENUM or
        (td.kind == k.TYPE_ALIAS and td.type_expr and td.type_expr.kind == k.TYPE_ENUM_INLINE))
      if not is_family and not is_enum then
        err(acc, ast.E.UNDEFINED_TYPE,
          "SymbolOf('" .. fname .. "') — '" .. fname ..
          "' is not a declared entity family or named enum type",
          texpr.pos)
      end
    end

  elseif kind == k.TYPE_SYMBOL then
    -- Warn: bare Symbol has no declared membership; prefer SymbolOf(Family) or a named enum.
    table.insert(acc.diags, ast.warning(
      ast.E.UNTYPED_SYMBOL,
      "bare Symbol type has no declared membership — prefer SymbolOf(Family) or a named enum type",
      texpr.pos))
  end
  -- TYPE_BOOL, TYPE_ENUM_INLINE, TYPE_STRING, TYPE_FLOAT: no sub-expressions to resolve
end

--- Check that a default value node is compatible with a type expression.
--- Emits BAD_DEFAULT if the default is incompatible.
--- `label` is a human-readable description for the error message.
local function check_default_value(acc, symtab, default_node, texpr, label)
  if not default_node or not texpr then return end
  local k = ast.K
  local tk = texpr.kind
  local dk = default_node.kind

  if tk == k.TYPE_BOOL then
    if dk ~= k.BOOL_LIT then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": expected Bool literal for Bool type", default_node.pos)
    end

  elseif tk == k.TYPE_INT then
    if dk ~= k.INT_LIT then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": expected integer literal for Int type", default_node.pos)
    else
      local v = default_node.value
      local lo = texpr.min
      local hi = texpr.max
      if lo ~= nil and v < lo then
        err(acc, ast.E.BAD_DEFAULT,
          label .. ": default " .. v .. " is below Int minimum " .. lo, default_node.pos)
      end
      if hi ~= nil and v > hi then
        err(acc, ast.E.BAD_DEFAULT,
          label .. ": default " .. v .. " is above Int maximum " .. hi, default_node.pos)
      end
    end

  elseif tk == k.TYPE_FLOAT then
    if dk ~= k.FLOAT_LIT and dk ~= k.INT_LIT then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": expected numeric literal for Float type", default_node.pos)
    end

  elseif tk == k.TYPE_STRING then
    if dk ~= k.STRING_LIT and dk ~= k.MULTILINE_STRING then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": expected string literal for String type", default_node.pos)
    end

  elseif tk == k.TYPE_SYMBOL then
    if dk ~= k.SYMBOL_LIT then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": expected symbol literal ('name) for Symbol type", default_node.pos)
    end

  elseif tk == k.TYPE_SYMBOL_OF then
    if dk ~= k.SYMBOL_LIT then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": expected symbol literal ('name) for SymbolOf type", default_node.pos)
    end

  elseif tk == k.TYPE_ENUM_INLINE then
    if dk ~= k.SYMBOL_LIT then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": expected symbol literal for Enum type", default_node.pos)
    else
      local valid = {}
      for _, v in ipairs(texpr.values or {}) do valid[v] = true end
      if not valid[default_node.name] then
        local vals = table.concat(texpr.values or {}, ", ")
        err(acc, ast.E.BAD_DEFAULT,
          label .. ": '" .. default_node.name .. "' is not a member of Enum(" .. vals .. ")",
          default_node.pos)
      end
    end

  elseif tk == k.TYPE_OPTION then
    -- nil default (no node) is valid; otherwise check inner type
    -- (EMPTY_SET/LIST also acceptable as "no value" for collections inside Option)

  elseif tk == k.TYPE_SET then
    if dk ~= k.EMPTY_SET and dk ~= k.SET_LIT then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": Set default must be (set) or a set literal {'val, ...}", default_node.pos)
    end

  elseif tk == k.TYPE_LIST then
    if dk ~= k.EMPTY_LIST and dk ~= k.LIST_LIT then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": List default must be [] or a list literal ['val, ...]", default_node.pos)
    end

  elseif tk == k.TYPE_ULIST then
    if dk ~= k.EMPTY_LIST and dk ~= k.LIST_LIT then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": UList default must be [] or a list literal ['val, ...]", default_node.pos)
    end

  elseif tk == k.TYPE_UMAP then
    if dk ~= k.EMPTY_MAP then
      err(acc, ast.E.BAD_DEFAULT,
        label .. ": UMap default must be {}", default_node.pos)
    end

  elseif tk == k.TYPE_NAMED then
    local decl = texpr.resolved
    if not decl then return end  -- undefined type already reported
    if decl.builtin then return end  -- built-in alias: skip (no user can shadow them)

    local decl_k = decl.kind
    if decl_k == k.TYPE_ENUM then
      if dk ~= k.SYMBOL_LIT then
        err(acc, ast.E.BAD_DEFAULT,
          label .. ": expected symbol literal for enum type '" .. decl.name .. "'",
          default_node.pos)
      else
        local valid = {}
        for _, v in ipairs(decl.values or {}) do valid[v] = true end
        if not valid[default_node.name] then
          err(acc, ast.E.BAD_DEFAULT,
            label .. ": '" .. default_node.name .. "' is not a member of " .. decl.name,
            default_node.pos)
        end
      end
    elseif decl_k == k.TYPE_ALIAS then
      check_default_value(acc, symtab, default_node, decl.type_expr, label)
    elseif decl_k == k.TYPE_RECORD then
      if dk ~= k.RECORD_CONSTRUCTOR then
        err(acc, ast.E.BAD_DEFAULT,
          label .. ": expected record constructor " .. decl.name .. "(...) for record type",
          default_node.pos)
      end
    end
    -- TYPE_VARIANT: any constructor accepted; full check would require matching branch name
  end
end

--- Compare two type expression nodes for structural equality.
--- Returns true iff they describe the same type.
local function types_equal(a, b)
  if not a or not b then return a == b end
  if a.kind ~= b.kind then return false end
  local k = ast.K
  if a.kind == k.TYPE_INT then
    return a.min == b.min and a.max == b.max
  elseif a.kind == k.TYPE_NAMED then
    return a.name == b.name
  elseif a.kind == k.TYPE_ENUM_INLINE then
    if #a.values ~= #b.values then return false end
    for i, v in ipairs(a.values) do
      if v ~= b.values[i] then return false end
    end
    return true
  elseif a.kind == k.TYPE_OPTION or a.kind == k.TYPE_SET or a.kind == k.TYPE_LIST
      or a.kind == k.TYPE_ULIST then
    if a.kind == k.TYPE_SET or a.kind == k.TYPE_LIST then
      if a.max ~= b.max then return false end
    end
    return types_equal(a.inner, b.inner)
  elseif a.kind == k.TYPE_UMAP then
    return types_equal(a.key, b.key) and types_equal(a.val, b.val)
  elseif a.kind == k.TYPE_SYMBOL_OF then
    return a.family == b.family
  else
    -- TYPE_BOOL, TYPE_STRING, TYPE_FLOAT, TYPE_SYMBOL: equal iff same kind (already checked)
    return true
  end
end

--- Check record fields: resolve types, check mixin references, detect conflicts.
--- Returns a flat field-name set (the "effective" fields after mixin expansion).
local function check_record_fields(acc, symtab, fields, record_name)
  local seen      = {}   -- fieldname → {src=name, texpr=type_expr_node}
  local mixin_sources = {} -- track which mixin contributes which fields

  for _, item in ipairs(fields) do
    local k = ast.K
    if item.kind == k.RECORD_FIELD then
      -- Resolve the field's type
      resolve_type_expr(acc, symtab, item.type_expr)
      local fname = item.name
      if seen[fname] then
        local prev = seen[fname]
        if prev.src == record_name then
          err(acc, ast.E.DUPLICATE_NAME,
            "field '" .. fname .. "' declared twice in '" .. record_name .. "'",
            item.pos)
        else
          -- Override of a mixin field: allowed only if the type is identical.
          if not types_equal(item.type_expr, prev.texpr) then
            err(acc, ast.E.TYPE_MISMATCH,
              "field '" .. fname .. "' in '" .. record_name ..
              "' overrides mixin field with a different type",
              item.pos)
          end
          -- Default override (same type): silently accepted.
        end
      else
        seen[fname] = { src = record_name, texpr = item.type_expr }
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
              if prev.src ~= record_name and prev.src ~= mixin_name then
                -- Two different mixins contribute the same field
                err(acc, ast.E.CONFLICTING_WITH,
                  "field '" .. fname .. "' appears in both '" ..
                  prev.src .. "' and '" .. mixin_name .. "'",
                  item.pos)
              end
            else
              seen[fname] = { src = mixin_name, texpr = mf.type_expr }
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
    -- Check field defaults
    for _, field in ipairs(node.fields or {}) do
      if field.kind == k.RECORD_FIELD and field.default then
        check_default_value(acc, symtab, field.default, field.type_expr,
          "field '" .. field.name .. "' in " .. node.name)
      end
    end

  elseif node.kind == k.TYPE_VARIANT then
    for _, branch in ipairs(node.branches or {}) do
      if branch.kind == k.VARIANT_BRANCH then
        for _, field in ipairs(branch.fields or {}) do
          resolve_type_expr(acc, symtab, field.type_expr)
          if field.kind == k.RECORD_FIELD and field.default then
            check_default_value(acc, symtab, field.default, field.type_expr,
              "field '" .. field.name .. "' in variant branch '" .. (branch.name or "?") .. "'")
          end
        end
      end
    end

  elseif node.kind == k.STATE_SCALAR then
    resolve_type_expr(acc, symtab, node.type_expr)
    if node.default then
      check_default_value(acc, symtab, node.default, node.type_expr,
        "state '" .. (node.path and node.path.segments and
                       table.concat(node.path.segments, "/") or "?") .. "'")
    end

  elseif node.kind == k.STATE_RECORD then
    for _, field in ipairs(node.fields or {}) do
      if field.kind == k.RECORD_FIELD then
        resolve_type_expr(acc, symtab, field.type_expr)
        if field.default then
          check_default_value(acc, symtab, field.default, field.type_expr,
            "inline-record field '" .. field.name .. "'")
        end
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

  elseif node.kind == k.DEFGRID_DECL then
    -- Validate dimensions
    if not node.width or node.width <= 0 then
      err(acc, ast.E.BAD_DECLARATION,
        "defgrid '" .. (node.name or "?") .. "': dimensions width must be a positive integer",
        node.pos)
    end
    if not node.height or node.height <= 0 then
      err(acc, ast.E.BAD_DECLARATION,
        "defgrid '" .. (node.name or "?") .. "': dimensions height must be a positive integer",
        node.pos)
    end
    -- Validate cell-type reference (must be a declared type or a built-in)
    if node.cell_type then
      if not BUILTIN_TYPES[node.cell_type] and not symtab.types[node.cell_type] then
        err(acc, ast.E.UNDEFINED_TYPE,
          "defgrid '" .. (node.name or "?") .. "': undefined cell-type '" .. node.cell_type .. "'",
          node.pos)
      end
    else
      err(acc, ast.E.BAD_DECLARATION,
        "defgrid '" .. (node.name or "?") .. "': missing cell-type declaration",
        node.pos)
    end
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
  -- say stmt is effectful (impure)
  if node.kind == ast.K.SAY_STMT then return true end
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
  -- First pass: classify by direct mutation primitives
  for _, node in ipairs(program.decls) do
    if node.kind == k.FN_DECL then
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

  -- Second pass: transitive promotion — a fn that calls a transaction fn is also a transaction.
  -- Repeat until no more promotions occur (handles arbitrarily deep call chains).
  local changed = true
  while changed do
    changed = false
    -- Build current transaction set
    local is_tx = {}
    for _, node in ipairs(program.decls) do
      if node.kind == k.FN_DECL and node.is_transaction then
        is_tx[node.name] = true
      end
    end
    for _, node in ipairs(program.decls) do
      if node.kind == k.FN_DECL and not node.is_transaction then
        -- Check if body calls any known transaction fn
        for _, s in ipairs(node.body or {}) do
          local calls = {}
          -- collect_fn_calls is defined later; use local inline search
          local function scan(n)
            if not n or type(n) ~= "table" then return end
            if n.kind == k.FN_CALL and n.name and is_tx[n.name] then
              node.is_transaction = true; changed = true
              return
            end
            for _, f in ipairs({ "body","then_body","else_body","condition","expr",
                                  "left","right","value","amount","inner_expr" }) do
              scan(n[f])
            end
            for _, list_f in ipairs({ "arms","choices","clauses" }) do
              if type(n[list_f]) == "table" then
                for _, child in ipairs(n[list_f]) do scan(child) end
              end
            end
            if type(n.args) == "table" then
              for _, a in ipairs(n.args) do scan(a) end
            end
          end
          scan(s)
          if node.is_transaction then break end
        end
      end
    end
  end
end

-- ============================================================
-- Pass 3c — reversible tag verification
-- ============================================================

-- Mutations that cannot be undone by replaying from a checkpoint.
local IRREVERSIBLE_MUT_KINDS = {
  [ast.K.CLEAR_MUT]           = "clear!",
  [ast.K.TIME_INC_MUT]        = "time-inc!",
  [ast.K.TIME_SET_MUT]        = "time-set!",
  [ast.K.SEND_MUT]            = "send!",
  [ast.K.CANCEL_SCHEDULE_MUT] = "cancel-schedule!",
  [ast.K.SCHEDULE_MUT]        = "schedule!",
}

--- Return the first irreversible mutation node found in a subtree, or nil.
local function find_irreversible(node)
  if not node or type(node) ~= "table" then return nil end
  if IRREVERSIBLE_MUT_KINDS[node.kind] then return node end
  for _, f in ipairs({ "body", "then_body", "else_body", "args",
                       "arms", "choices", "clauses", "bindings" }) do
    local v = node[f]
    if type(v) == "table" then
      for _, child in ipairs(v) do
        local found = find_irreversible(child)
        if found then return found end
        -- also recurse into arm bodies
        if type(child) == "table" and child.body then
          if type(child.body) == "table" and not child.body.kind then
            for _, s in ipairs(child.body) do
              local f2 = find_irreversible(s)
              if f2 then return f2 end
            end
          else
            local f2 = find_irreversible(child.body)
            if f2 then return f2 end
          end
        end
      end
    end
  end
  for _, f in ipairs({ "condition", "expr", "value", "amount",
                       "left", "right", "inner_expr" }) do
    local found = find_irreversible(node[f])
    if found then return found end
  end
  return nil
end

--- For each fn tagged [reversible], verify no irreversible mutation appears in its body.
local function pass3c_check_reversible(acc, program)
  local k = ast.K
  -- Build a map fn_name → fn_decl for call-site checks
  local fn_map = {}
  for _, node in ipairs(program.decls) do
    if node.kind == k.FN_DECL then fn_map[node.name] = node end
  end

  for _, node in ipairs(program.decls) do
    if node.kind ~= k.FN_DECL then goto continue end
    local is_reversible = false
    for _, tag in ipairs(node.tags or {}) do
      if tag == "reversible" then is_reversible = true; break end
    end
    if not is_reversible then goto continue end

    -- Check body directly
    for _, s in ipairs(node.body or {}) do
      local bad = find_irreversible(s)
      if bad then
        err(acc, ast.E.IRREVERSIBLE_IN_REVERSIBLE,
          "fn '" .. (node.name or "?") .. "' is tagged [reversible] but contains '" ..
          (IRREVERSIBLE_MUT_KINDS[bad.kind] or bad.kind) .. "', which cannot be undone",
          bad.pos or node.pos)
        break
      end
    end
    ::continue::
  end
end

-- ============================================================
-- Pass 3b — Transaction-in-pure-context checks + uses-bounded tag
-- ============================================================

--- Collect all FN_CALL names (with positions) in an AST subtree.
local function collect_fn_calls(node, result)
  if not node or type(node) ~= "table" then return end
  if node.kind == ast.K.FN_CALL and node.name then
    result[#result+1] = { name = node.name, pos = node.pos }
  end
  local LIST_FIELDS = { "body", "then_body", "else_body", "arms", "choices" }
  for _, field in ipairs(LIST_FIELDS) do
    local v = node[field]
    if type(v) == "table" then
      for _, child in ipairs(v) do
        collect_fn_calls(child, result)
        if type(child) == "table" then
          if child.guard then collect_fn_calls(child.guard, result) end
          if child.body then
            if type(child.body) == "table" and not child.body.kind then
              for _, s in ipairs(child.body) do collect_fn_calls(s, result) end
            else collect_fn_calls(child.body, result) end
          end
        end
      end
    end
  end
  local NODE_FIELDS = { "condition", "expr", "left", "right",
                        "base", "value", "amount", "inner_expr" }
  for _, field in ipairs(NODE_FIELDS) do
    collect_fn_calls(node[field], result)
  end
  if type(node.args) == "table" then
    for _, a in ipairs(node.args) do collect_fn_calls(a, result) end
  end
  if type(node.clauses) == "table" then
    for _, c in ipairs(node.clauses) do
      collect_fn_calls(c.condition, result)
      if type(c.body) == "table" then
        for _, s in ipairs(c.body) do collect_fn_calls(s, result) end
      end
    end
  end
end

--- Recursively visit all LAMBDA_EXPR nodes in a subtree, calling fn(lambda_node).
local function walk_lambdas(node, fn)
  if not node or type(node) ~= "table" then return end
  if node.kind == ast.K.LAMBDA_EXPR then fn(node) end
  local LIST_FIELDS = { "body", "then_body", "else_body", "arms", "choices",
                        "clauses", "bindings" }
  for _, field in ipairs(LIST_FIELDS) do
    local v = node[field]
    if type(v) == "table" then
      if v.kind then
        walk_lambdas(v, fn)  -- single node stored in a list field
      else
        for _, child in ipairs(v) do walk_lambdas(child, fn) end
      end
    end
  end
  for _, scalar in ipairs({ "condition", "expr", "left", "right", "value",
                             "amount", "inner_expr", "guard" }) do
    walk_lambdas(node[scalar], fn)
  end
  if type(node.args) == "table" then
    for _, a in ipairs(node.args) do walk_lambdas(a, fn) end
  end
end

--- Recursively visit all nodes, calling fn for FIND_EXPR and VERIFY_DECL.
local function walk_pure_contexts(node, fn)
  if not node or type(node) ~= "table" then return end
  if node.kind == ast.K.FIND_EXPR or node.kind == ast.K.VERIFY_DECL then
    fn(node)
  end
  local LIST_FIELDS = { "body", "then_body", "else_body", "arms", "choices" }
  for _, field in ipairs(LIST_FIELDS) do
    local v = node[field]
    if type(v) == "table" then
      for _, child in ipairs(v) do
        walk_pure_contexts(child, fn)
        if type(child) == "table" then
          if child.guard then walk_pure_contexts(child.guard, fn) end
          if child.body then
            if type(child.body) == "table" and not child.body.kind then
              for _, s in ipairs(child.body) do walk_pure_contexts(s, fn) end
            else walk_pure_contexts(child.body, fn) end
          end
        end
      end
    end
  end
  local NODE_FIELDS = { "condition", "expr", "left", "right",
                        "base", "value", "amount", "inner_expr" }
  for _, field in ipairs(NODE_FIELDS) do
    walk_pure_contexts(node[field], fn)
  end
  if type(node.args) == "table" then
    for _, a in ipairs(node.args) do walk_pure_contexts(a, fn) end
  end
end

--- Check transaction/pure-context constraints and annotate uses_bounded.
--- Runs after pass3_infer_purity so fn_decl.is_transaction is already set.
---
--- Errors emitted:
---   TRANSACTION_IN_PURE   — transaction fn called inside a pure fn body
---   TRANSACTION_IN_FIND   — transaction fn called inside a find where clause
---   TRANSACTION_IN_VERIFY — transaction fn called inside a verify condition
--- Annotations:
---   fn_decl.uses_bounded = true  — fn (directly) calls a bounded computation
local function pass3b_check_call_purity(acc, program)
  local k = ast.K

  -- Build fn classification and bounded-name sets from top-level decls
  local fn_is_transaction = {}   -- fn_name → bool
  local bounded_names     = {}   -- bounded_decl names → true
  for _, node in ipairs(program.decls) do
    if node.kind == k.FN_DECL then
      fn_is_transaction[node.name] = node.is_transaction or false
    elseif node.kind == k.BOUNDED_DECL then
      bounded_names[node.name] = true
    end
  end

  -- Check each fn_decl for TRANSACTION_IN_PURE (in pre:/post:) and uses_bounded
  for _, node in ipairs(program.decls) do
    if node.kind == k.FN_DECL then
      -- TRANSACTION_IN_PURE: pre:/post: block calls a transaction function.
      -- (Direct mutations in pre:/post: are already caught by PURE_CALLS_MUT in pass3.)
      for _, e in ipairs(node.pre or {}) do
        local calls = {}; collect_fn_calls(e, calls)
        for _, call in ipairs(calls) do
          if fn_is_transaction[call.name] == true then
            err(acc, ast.E.TRANSACTION_IN_PURE,
              "pre: condition of '" .. (node.name or "?") ..
              "' calls transaction function '" .. call.name .. "'",
              call.pos or node.pos)
            break
          end
        end
      end
      for _, e in ipairs(node.post or {}) do
        local calls = {}; collect_fn_calls(e, calls)
        for _, call in ipairs(calls) do
          if fn_is_transaction[call.name] == true then
            err(acc, ast.E.TRANSACTION_IN_PURE,
              "post: condition of '" .. (node.name or "?") ..
              "' calls transaction function '" .. call.name .. "'",
              call.pos or node.pos)
            break
          end
        end
      end

      -- uses_bounded tag: fn directly calls a bounded computation
      local all_calls = {}
      for _, stmt in ipairs(node.body or {}) do collect_fn_calls(stmt, all_calls) end
      for _, call in ipairs(all_calls) do
        if bounded_names[call.name] then
          node.uses_bounded = true
          break
        end
      end
    end
  end

  -- Walk all decls for FIND_EXPR and VERIFY_DECL nodes anywhere in the tree
  for _, decl in ipairs(program.decls) do
    walk_pure_contexts(decl, function(node)
      if node.kind == k.FIND_EXPR then
        -- TRANSACTION_IN_FIND: transaction fn in find where/or-where clause
        for _, clause in ipairs(node.clauses or {}) do
          if clause.kind == "where" or clause.kind == "or_where" then
            local calls = {}
            collect_fn_calls(clause.condition, calls)
            for _, call in ipairs(calls) do
              if fn_is_transaction[call.name] == true then
                err(acc, ast.E.TRANSACTION_IN_FIND,
                  "transaction function '" .. call.name .. "' called in find where clause",
                  call.pos or node.pos)
                break
              end
            end
          end
        end
      elseif node.kind == k.VERIFY_DECL then
        -- TRANSACTION_IN_VERIFY: transaction fn in pure-context verify clauses.
        -- "after" clauses have a call expression that IS a transaction (intentional),
        -- so we only check the assertion body of after:, not the call itself.
        -- For always/requires/from_any_state/when: check both condition and body.
        -- NOTE: AST verify_clause nodes use `clause_kind` (not `kind`) for type.
        for _, clause in ipairs(node.clauses or {}) do
          local exprs = {}
          if clause.clause_kind == "after" then
            -- Only check assertion body; clause.condition is the intentional transaction call
            if type(clause.body) == "table" then
              for _, e in ipairs(clause.body) do exprs[#exprs+1] = e end
            end
          else
            -- always/requires/from_any_state/when: fully pure context
            if clause.condition then exprs[#exprs+1] = clause.condition end
            if type(clause.body) == "table" then
              for _, e in ipairs(clause.body) do exprs[#exprs+1] = e end
            end
          end
          for _, expr in ipairs(exprs) do
            local calls = {}
            collect_fn_calls(expr, calls)
            for _, call in ipairs(calls) do
              if fn_is_transaction[call.name] == true then
                err(acc, ast.E.TRANSACTION_IN_VERIFY,
                  "transaction function '" .. call.name .. "' called in verify condition",
                  call.pos or node.pos)
                break
              end
            end
          end
        end
      end
    end)
  end

  -- Lambda purity: a lambda body may not contain mutation primitives.
  -- (LAMBDA_CALLS_MUT — lambdas are always pure per spec §2.3)
  for _, decl in ipairs(program.decls) do
    walk_lambdas(decl, function(lam)
      local body_has_mut = false
      if type(lam.body) == "table" then
        if lam.body.kind then
          -- Single expression body (e.g. fn(x): expr)
          body_has_mut = has_mutation(lam.body)
        else
          -- List of statements (multi-line lambda body)
          for _, s in ipairs(lam.body) do
            if has_mutation(s) then body_has_mut = true; break end
          end
        end
      end
      if body_has_mut then
        err(acc, ast.E.LAMBDA_CALLS_MUT,
          "lambda body contains a mutation primitive; lambdas must be pure",
          lam.pos)
      end
    end)
  end
end

-- ============================================================
-- Pass 4 — Perceives enforcement
-- ============================================================

--- Test whether a concrete path matches a perceives pattern (same logic as runtime).
local function pat_matches(pattern, path)
  if pattern == "*" or pattern == path then return true end
  local lp = pattern:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")
  lp = lp:gsub("%*", "[^/]+")
  return path:match("^" .. lp .. "$") ~= nil
end

local function path_in_perceives(perceives, state_path, path)
  -- Actor always perceives its own state subtree
  if state_path and (path == state_path
      or path:sub(1, #state_path + 1) == state_path .. "/") then
    return true
  end
  for _, pat in ipairs(perceives) do
    if pat_matches(pat, path) then return true end
  end
  return false
end

--- Collect all static PATH_EXPR reads from a node subtree (not writes).
--- Skips paths that are the target of mutation primitives.
local function collect_path_reads(node, into)
  if not node or type(node) ~= "table" then return end
  local k = ast.K
  -- Skip mutation nodes — their target paths are writes, not reads
  if ast.is_mut(node) then
    -- Still recurse into value expressions (RHS of set!, amount of inc!, etc.)
    if node.value then collect_path_reads(node.value, into) end
    if node.amount then collect_path_reads(node.amount, into) end
    if node.msg    then collect_path_reads(node.msg, into) end
    return
  end
  if node.kind == k.PATH_EXPR then
    -- Only collect concrete (non-interpolated) paths
    local segs = node.segments or {}
    local has_var = false
    for _, s in ipairs(segs) do
      if type(s) ~= "string" then has_var = true; break end
    end
    if not has_var then
      into[#into+1] = { path = table.concat(segs, "/"), pos = node.pos }
    end
    return
  end
  -- Recurse into child expression/statement fields
  for _, field in ipairs({ "body", "then_body", "else_body", "arms" }) do
    if type(node[field]) == "table" then
      for _, child in ipairs(node[field]) do
        if type(child) == "table" then
          if field == "arms" then
            collect_path_reads(child.body, into)
          else
            collect_path_reads(child, into)
          end
        end
      end
    end
  end
  for _, field in ipairs({ "condition", "expr", "left", "right",
                            "base", "index", "value", "msg" }) do
    collect_path_reads(node[field], into)
  end
  if type(node.args) == "table" then
    for _, a in ipairs(node.args) do collect_path_reads(a, into) end
  end
end

--- Warn when a behavior function reads a path not covered by the actor's perceives list.
local function pass4_check_perceives(acc, program)
  local k = ast.K
  -- Build fn_name → fn_decl map
  local fns = {}
  for _, node in ipairs(program.decls) do
    if node.kind == k.FN_DECL then fns[node.name] = node end
  end
  -- For each actor, check its behavior fn
  for _, node in ipairs(program.decls) do
    if node.kind == k.ACTOR_DECL then
      local perceives  = node.perceives   -- nil means not declared → skip check
      local state_path = node.state_path or ""
      local bname      = node.behavior
      if not bname or perceives == nil then goto next_actor end
      local fn = fns[bname]
      if not fn then goto next_actor end

      local reads = {}
      collect_path_reads(fn, reads)
      for _, r in ipairs(reads) do
        if not path_in_perceives(perceives, state_path, r.path) then
          -- Emit as a warning (not error) since some reads may be guarded
          table.insert(acc.diags, ast.warning(
            ast.E.PERCEIVES_VIOLATION,
            "behavior '" .. bname .. "' reads '" .. r.path
            .. "' which is not in actor '" .. node.name .. "' perceives list",
            r.pos))
        end
      end
      ::next_actor::
    end
  end
end

-- ============================================================
-- Pass 5 — Discrete/Superficial boundary enforcement
-- ============================================================
-- Emits warnings when:
--   SUPERFICIAL_IN_COND  — a String/Float/Symbol path appears in a comparison
--   RANDOM_SUPERFICIAL   — random-choice result assigned to a superficial field

--- Return true if the type expression node is superficial (String, Float, Symbol,
--- List, UList, or UMap).  Recurses through TYPE_ALIAS named types.
local function is_superficial_texpr(texpr, symtab)
  if not texpr then return false end
  local k = ast.K
  if texpr.kind == k.TYPE_STRING then return true end
  if texpr.kind == k.TYPE_FLOAT  then return true end
  if texpr.kind == k.TYPE_SYMBOL then return true end   -- untyped Symbol
  if texpr.kind == k.TYPE_LIST   then return true end
  if texpr.kind == k.TYPE_ULIST  then return true end
  if texpr.kind == k.TYPE_UMAP   then return true end
  if texpr.kind == k.TYPE_NAMED  then
    -- Follow one level of alias resolution
    if texpr.resolved and texpr.resolved.kind == k.TYPE_ALIAS then
      return is_superficial_texpr(texpr.resolved.type_expr, symtab)
    end
  end
  return false
end

--- Build a flat map  path-string → type_expr node  for all declared state fields.
--- Handles STATE_SCALAR, STATE_RECORD (inline), and STATE_FAMILY.
--- For STATE_SCALAR whose type resolves to a TYPE_RECORD, expands sub-fields.
local function build_path_type_map(program, symtab_data)
  local map = {}
  local k   = ast.K

  local function expand_record_fields(prefix, fields)
    for _, field in ipairs(fields or {}) do
      if field.kind == k.RECORD_FIELD then
        map[prefix .. "/" .. field.name] = field.type_expr
      end
    end
  end

  for _, node in ipairs(program.decls) do
    if node.kind == k.STATE_SCALAR then
      local p = path_key(node.path)
      map[p] = node.type_expr
      local texpr = node.type_expr
      if texpr and texpr.kind == k.TYPE_NAMED and texpr.resolved then
        local res = texpr.resolved
        if res.kind == k.TYPE_RECORD then
          expand_record_fields(p, res.fields)
        end
      end

    elseif node.kind == k.STATE_RECORD then
      local p = path_key(node.path)
      expand_record_fields(p, node.fields)

    elseif node.kind == k.STATE_FAMILY then
      local family = node.family
      local texpr  = node.type_expr
      if texpr then
        map[family] = texpr
        if texpr.kind == k.TYPE_NAMED and texpr.resolved then
          local res = texpr.resolved
          if res.kind == k.TYPE_RECORD then
            for _, field in ipairs(res.fields or {}) do
              if field.kind == k.RECORD_FIELD then
                -- Store under wildcard pattern "family/*/fieldname"
                map[family .. "/*/" .. field.name] = field.type_expr
              end
            end
          end
        end
      end
    end
  end

  return map
end

--- Look up the type_expr for a PATH_EXPR node in the map.
--- Returns nil for interpolated paths or unknown paths.
local function lookup_path_type(path_node, path_map)
  if not path_node then return nil end
  local k = ast.K
  if path_node.kind ~= k.PATH_EXPR then return nil end
  local segs = path_node.segments or {}
  for _, s in ipairs(segs) do
    if type(s) ~= "string" then return nil end   -- interpolated segment
  end
  local p = table.concat(segs, "/")
  if path_map[p] then return path_map[p] end
  -- Try family wildcard: "npcs/guard/hp" → "npcs/*/hp"
  if #segs >= 3 then
    local wcard = segs[1] .. "/*/" .. table.concat(segs, "/", 3, #segs)
    if path_map[wcard] then return path_map[wcard] end
  end
  return nil
end

local COMPARISON_OPS = {
  ["="] = true, ["!="] = true,
  ["<"] = true, [">"]  = true,
  ["<="] = true, [">="] = true,
}


--- Build a map fn_name → list of {name, type_expr} for all user fn declarations.
local function build_fn_param_map(program)
  local map = {}
  local k = ast.K
  for _, node in ipairs(program.decls) do
    if node.kind == k.FN_DECL and node.name then
      map[node.name] = node.params or {}
    end
  end
  return map
end

local function pass5_check_boundary(acc, symtab_data, program)
  local path_map    = build_path_type_map(program, symtab_data)
  local fn_param_map = build_fn_param_map(program)
  local k = ast.K

  -- Patch walk_boundary to receive fn_param_map via upvalue
  local _walk
  _walk = function(node)
    if not node or type(node) ~= "table" or not node.kind then return end

    if node.kind == k.BINARY_OP and COMPARISON_OPS[node.op] then
      for _, side in ipairs({ node.left, node.right }) do
        if side and side.kind == k.PATH_EXPR then
          local texpr = lookup_path_type(side, path_map)
          if texpr and is_superficial_texpr(texpr, symtab_data) then
            local pstr = table.concat(side.segments or {}, "/")
            table.insert(acc.diags, ast.warning(
              ast.E.SUPERFICIAL_IN_COND,
              "'" .. pstr .. "' has a superficial type in a comparison expression",
              side.pos,
              "String/Float/Symbol values cannot drive state-space search; use a discrete type"))
          end
        end
      end
    end

    if node.kind == k.SET_MUT then
      local val = node.value
      if val and val.kind == k.FN_CALL and
         (val.name == "random-choice" or val.name == "random-element") then
        local texpr = lookup_path_type(node.path, path_map)
        if texpr and is_superficial_texpr(texpr, symtab_data) then
          local pstr = node.path and path_key(node.path) or "?"
          table.insert(acc.diags, ast.warning(
            ast.E.RANDOM_SUPERFICIAL,
            "random output assigned to superficial path '" .. pstr .. "'",
            node.pos,
            "random values should only be assigned to discrete types (Int, Bool, Enum)"))
        end
      end
    end

    -- SUPERFICIAL_PARAM: superficial path arg passed to a user-defined fn.
    -- fn params have no declared types in the current parser, so we warn whenever
    -- a superficial PATH_EXPR is passed to any user-declared fn.
    if node.kind == k.FN_CALL and fn_param_map[node.name] then
      for _, arg in ipairs(node.args or {}) do
        if arg.kind == k.PATH_EXPR then
          local arg_texpr = lookup_path_type(arg, path_map)
          if arg_texpr and is_superficial_texpr(arg_texpr, symtab_data) then
            local pstr = table.concat(arg.segments or {}, "/")
            table.insert(acc.diags, ast.warning(
              ast.E.SUPERFICIAL_PARAM,
              "superficial path '" .. pstr .. "' passed as argument to fn '" .. node.name .. "'",
              arg.pos,
              "superficial types (String, Float, Symbol) cannot participate in state-space search"))
          end
        end
      end
    end

    -- Recurse into all child fields
    local LIST_FIELDS = { "body", "then_body", "else_body", "arms", "choices" }
    for _, field in ipairs(LIST_FIELDS) do
      local v = node[field]
      if type(v) == "table" then
        for _, child in ipairs(v) do
          _walk(child)
          if child and type(child) == "table" and child.guard then
            _walk(child.guard)
          end
          if child and type(child) == "table" and child.body then
            if type(child.body) == "table" and not child.body.kind then
              for _, s in ipairs(child.body) do _walk(s) end
            else
              _walk(child.body)
            end
          end
        end
      end
    end
    local NODE_FIELDS = { "condition", "expr", "left", "right",
                          "base", "value", "amount", "msg", "inner_expr" }
    for _, field in ipairs(NODE_FIELDS) do
      _walk(node[field])
    end
    if type(node.args) == "table" then
      for _, a in ipairs(node.args) do _walk(a) end
    end
  end

  for _, node in ipairs(program.decls) do
    if node.kind == k.FN_DECL then
      for _, stmt in ipairs(node.body or {}) do
        _walk(stmt)
      end
    elseif node.kind == k.SCENE_DECL then
      for _, stmt in ipairs(node.body or {}) do
        _walk(stmt)
      end
      for _, choice in ipairs(node.choices or {}) do
        if choice.guard then
          _walk(choice.guard)
        end
        for _, stmt in ipairs(choice.body or {}) do
          _walk(stmt)
        end
      end
    end
  end
end

-- ============================================================
-- Pass 6 — Write-set analysis
-- ============================================================

--- Mutation node kinds that carry a `path` field.
local WRITE_PATH_MUTS = {
  [ast.K.SET_MUT]    = true, [ast.K.INC_MUT]    = true,
  [ast.K.DEC_MUT]    = true, [ast.K.ADD_MUT]    = true,
  [ast.K.REMOVE_MUT] = true, [ast.K.CLEAR_MUT]  = true,
  [ast.K.PUSH_MUT]   = true, [ast.K.POP_MUT]    = true,
}

--- Resolve a path node into write-pattern strings, given the current variable env.
--- env: { var_name → "family:X" } for loop-bound SymbolOf vars.
--- Returns a table { pattern_string → true }.
--- Emits WRITE_UNTYPED_VAR warning for unresolved {var}, WRITE_DYNAMIC_PATH error
--- for non-path values in write position.
local function resolve_write_path(path_node, env, acc)
  if not path_node then return {} end
  local k = ast.K
  local result = {}

  if path_node.kind == k.PATH_EXPR then
    local segs = path_node.segments or {}
    local parts = {}
    for _, s in ipairs(segs) do
      if type(s) == "string" then
        parts[#parts+1] = s
      else
        -- Unexpected non-string segment in PATH_EXPR (shouldn't happen)
        parts[#parts+1] = "?"
      end
    end
    result[table.concat(parts, "/")] = true

  elseif path_node.kind == k.INTERP_PATH then
    local segs = path_node.segments or {}
    local parts = {}
    for _, s in ipairs(segs) do
      if type(s) == "string" then
        parts[#parts+1] = s
      elseif type(s) == "table" and s.interp then
        local var = s.interp
        local binding = env and env[var]
        if binding and binding:sub(1, 7) == "family:" then
          parts[#parts+1] = "*"
        else
          table.insert(acc.diags, ast.warning(
            ast.E.WRITE_UNTYPED_VAR,
            "interpolated variable '{" .. var .. "}' in write path has no declared entity-family type",
            path_node.pos,
            "annotate the variable's type as SymbolOf(family) to enable static write-set inference"))
          parts[#parts+1] = "*"
        end
      end
    end
    result[table.concat(parts, "/")] = true

  elseif path_node.kind == k.INDEX_EXPR then
    -- Indexed list write: set! path[n] val  (§4.4 — legal for List and UList)
    -- Resolve the base path; the static write-set is the base path itself.
    local base_writes = resolve_write_path(path_node.base, env, acc)
    for p in pairs(base_writes) do result[p] = true end

  else
    -- A computed or non-path node in write position
    table.insert(acc.diags, ast.error(
      ast.E.WRITE_DYNAMIC_PATH,
      "write position contains a dynamic or computed path expression",
      path_node.pos,
      "only static paths (player/health) and {var} interpolations are allowed in mutation targets"))
  end

  return result
end

--- Recursively collect write-path patterns from a statement/expression subtree.
--- Adds patterns to write_set (table { pattern → true }).
--- env: scoped loop-variable → family bindings.
local function collect_writes(node, write_set, env, acc)
  if not node or type(node) ~= "table" or not node.kind then return end
  local k = ast.K

  if WRITE_PATH_MUTS[node.kind] and node.path then
    for pat in pairs(resolve_write_path(node.path, env, acc)) do
      write_set[pat] = true
    end
    -- Recurse into value/amount in case they contain nested lambdas, etc.
    collect_writes(node.value,  write_set, env, acc)
    collect_writes(node.amount, write_set, env, acc)
    return

  elseif node.kind == k.SPAWN_MUT then
    if type(node.family) == "string" then
      write_set[node.family .. "/*"] = true
    end
    return

  elseif node.kind == k.DESPAWN_MUT then
    if type(node.family) == "string" then
      write_set[node.family .. "/*"] = true
    end
    return

  elseif node.kind == k.FOR_STMT then
    -- Extend env: detect `for var in (path-list family)`
    local new_env = {}
    for vk, vv in pairs(env) do new_env[vk] = vv end

    local iter = node.iter
    if iter and iter.kind == k.FN_CALL and iter.name == "path-list" then
      local args = iter.args or {}
      if #args == 1 and args[1] then
        local arg = args[1]
        -- Family name may arrive as PATH_EXPR(["npcs"]) or fn_call{name="npcs", args={}}
        local family_name
        if arg.kind == k.PATH_EXPR then
          local segs = arg.segments or {}
          if #segs == 1 and type(segs[1]) == "string" then
            family_name = segs[1]
          end
        elseif arg.kind == k.FN_CALL and #(arg.args or {}) == 0 then
          family_name = arg.name
        end
        if family_name then
          new_env[node.var] = "family:" .. family_name
        end
      end
    end

    for _, stmt in ipairs(node.body or {}) do
      collect_writes(stmt, write_set, new_env, acc)
    end
    return
  end

  -- Generic recursive descent
  local LIST_FIELDS = { "body", "then_body", "else_body", "arms", "choices" }
  for _, field in ipairs(LIST_FIELDS) do
    local v = node[field]
    if type(v) == "table" then
      for _, child in ipairs(v) do
        collect_writes(child, write_set, env, acc)
      end
    end
  end
  local NODE_FIELDS = { "condition", "expr", "value", "amount", "iter" }
  for _, field in ipairs(NODE_FIELDS) do
    collect_writes(node[field], write_set, env, acc)
  end
  if type(node.args) == "table" then
    for _, a in ipairs(node.args) do collect_writes(a, write_set, env, acc) end
  end
end

-- ============================================================
-- Pass: recursive scene detection
-- ============================================================

--- Walk a list of statements looking for scene_goto/scene_enter nodes whose
--- target is the string `scene_name`.  Descends into when_stmt, for_stmt,
--- while_stmt, choice bodies, and cond_expr branches.
local function stmts_contain_self_nav(stmts, scene_name)
  local k = ast.K
  local function walk_stmt(node)
    if not node then return false end
    local nk = node.kind
    if (nk == k.SCENE_GOTO or nk == k.SCENE_ENTER) then
      if type(node.target) == "string" and node.target == scene_name then
        return true
      end
    end
    -- Descend into compound statements
    if nk == k.WHEN_STMT then
      if stmts_contain_self_nav(node.body or {}, scene_name) then return true end
      if stmts_contain_self_nav(node.else_body or {}, scene_name) then return true end
    elseif nk == k.FOR_STMT then
      if stmts_contain_self_nav(node.body or {}, scene_name) then return true end
    elseif nk == k.WHILE_STMT then
      if stmts_contain_self_nav(node.body or {}, scene_name) then return true end
    end
    return false
  end

  for _, s in ipairs(stmts or {}) do
    if walk_stmt(s) then return true end
  end
  return false
end

--- Emit WARN_RECURSIVE_SCENE for any scene that directly navigates to itself
--- (via -> or =>) without an intervening player choice.
local function pass_recursive_scenes(acc, program)
  local k = ast.K
  for _, node in ipairs(program.decls) do
    if node.kind == k.SCENE_DECL then
      local name = node.name
      -- Check top-level body
      if stmts_contain_self_nav(node.body or {}, name) then
        table.insert(acc.diags, ast.warning(
          ast.E.RECURSIVE_SCENE,
          "scene '" .. name .. "' navigates directly to itself — this creates an infinite loop",
          node.pos))
      end
    end
  end
end

--- Pass 6: annotate every FN_DECL and SCENE_DECL with a `write_set` table.
--- Also emits WRITE_UNTYPED_VAR / WRITE_DYNAMIC_PATH diagnostics.
local function pass6_write_sets(acc, program)
  local k = ast.K

  for _, node in ipairs(program.decls) do
    if node.kind == k.FN_DECL then
      local ws = {}
      for _, stmt in ipairs(node.body or {}) do
        collect_writes(stmt, ws, {}, acc)
      end
      node.write_set = ws

    elseif node.kind == k.SCENE_DECL then
      local ws = {}
      for _, stmt in ipairs(node.body or {}) do
        collect_writes(stmt, ws, {}, acc)
      end
      for _, choice in ipairs(node.choices or {}) do
        if choice.guard then
          collect_writes(choice.guard, ws, {}, acc)
        end
        for _, stmt in ipairs(choice.body or {}) do
          collect_writes(stmt, ws, {}, acc)
        end
      end
      node.write_set = ws
    end
  end
end

-- ============================================================
-- Pass 7 — Contract Validation (pre:/post: type checking + path@before scope)
-- ============================================================

--- Return a human-readable reason string if node is obviously not a Bool expression.
--- Returns nil when the type cannot be determined (e.g. fn call, binary comparison).
local function non_bool_reason(node, path_map)
  if not node then return nil end
  local k = ast.K
  if node.kind == k.INT_LIT    then return "integer literal" end
  if node.kind == k.FLOAT_LIT  then return "float literal"   end
  if node.kind == k.STRING_LIT then return "string literal"  end
  if node.kind == k.SYMBOL_LIT then return "symbol literal"  end
  if node.kind == k.PATH_EXPR  then
    local texpr = lookup_path_type(node, path_map)
    if texpr then
      local kk = texpr.kind
      if kk == k.TYPE_INT        then return "Int path"    end
      if kk == k.TYPE_FLOAT      then return "Float path"  end
      if kk == k.TYPE_STRING     then return "String path" end
      if kk == k.TYPE_SYMBOL     then return "Symbol path" end
      if kk == k.TYPE_SYMBOL_OF  then return "SymbolOf path" end
      if kk == k.TYPE_ENUM       then return "Enum path"   end
      if kk == k.TYPE_ENUM_INLINE then return "Enum path"  end
      -- TYPE_BOOL → is a boolean, no issue
    end
  end
  if node.kind == k.BINARY_OP then
    local arith = {["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true}
    if arith[node.op] then return "arithmetic expression" end
  end
  return nil  -- unknown or definitely Bool
end

--- Return true if node subtree contains any PATH_AT_BEFORE node.
local function has_path_at_before(node)
  if not node or type(node) ~= "table" then return false end
  if node.kind == ast.K.PATH_AT_BEFORE then return true end
  local LIST_FIELDS = { "body", "then_body", "else_body", "arms", "choices" }
  for _, field in ipairs(LIST_FIELDS) do
    local v = node[field]
    if type(v) == "table" then
      for _, child in ipairs(v) do
        if has_path_at_before(child) then return true end
        if type(child) == "table" then
          if has_path_at_before(child.guard)     then return true end
          if has_path_at_before(child.condition) then return true end
          if child.body then
            if type(child.body) == "table" and not child.body.kind then
              for _, s in ipairs(child.body) do
                if has_path_at_before(s) then return true end
              end
            else if has_path_at_before(child.body) then return true end end
          end
        end
      end
    end
  end
  local NODE_FIELDS = { "condition", "expr", "left", "right",
                        "base", "value", "amount", "inner_expr", "path" }
  for _, field in ipairs(NODE_FIELDS) do
    if has_path_at_before(node[field]) then return true end
  end
  if type(node.args) == "table" then
    for _, a in ipairs(node.args) do
      if has_path_at_before(a) then return true end
    end
  end
  if type(node.clauses) == "table" then
    for _, c in ipairs(node.clauses) do
      if has_path_at_before(c.condition) then return true end
      if type(c.body) == "table" then
        for _, s in ipairs(c.body) do if has_path_at_before(s) then return true end end
      end
    end
  end
  return false
end

--- Pass 7: Contract Validation.
---
--- Checks:
---   PRE_NOT_BOOL  (warning) — pre: condition is obviously not Bool
---   POST_NOT_BOOL (warning) — post: condition is obviously not Bool
---   PATH_BEFORE_INVALID (error) — path@before outside post: / verify after: assertion
local function pass7_check_contracts(acc, symtab_data, program)
  local k = ast.K
  local path_map = build_path_type_map(program, symtab_data)

  for _, node in ipairs(program.decls) do
    if node.kind == k.FN_DECL then
      -- PRE_NOT_BOOL
      for _, e in ipairs(node.pre or {}) do
        local reason = non_bool_reason(e, path_map)
        if reason then
          table.insert(acc.diags, ast.warning(
            ast.E.PRE_NOT_BOOL,
            "pre: condition of '" .. (node.name or "?") ..
              "' is a " .. reason .. " (expected Bool expression)",
            e.pos or node.pos,
            "pre: conditions must evaluate to Bool"))
        end
      end
      -- POST_NOT_BOOL
      for _, e in ipairs(node.post or {}) do
        local reason = non_bool_reason(e, path_map)
        if reason then
          table.insert(acc.diags, ast.warning(
            ast.E.POST_NOT_BOOL,
            "post: condition of '" .. (node.name or "?") ..
              "' is a " .. reason .. " (expected Bool expression)",
            e.pos or node.pos,
            "post: conditions must evaluate to Bool"))
        end
      end
      -- PATH_BEFORE_INVALID in pre: block
      for _, e in ipairs(node.pre or {}) do
        if has_path_at_before(e) then
          table.insert(acc.diags, ast.error(
            ast.E.PATH_BEFORE_INVALID,
            "path@before in pre: block of '" .. (node.name or "?") ..
              "' — path@before is only valid in post: blocks or verify after: assertions",
            e.pos or node.pos))
        end
      end
      -- PATH_BEFORE_INVALID in fn body
      for _, s in ipairs(node.body or {}) do
        if has_path_at_before(s) then
          table.insert(acc.diags, ast.error(
            ast.E.PATH_BEFORE_INVALID,
            "path@before in body of '" .. (node.name or "?") ..
              "' — path@before is only valid in post: blocks or verify after: assertions",
            s.pos or node.pos))
        end
      end

    elseif node.kind == k.SCENE_DECL then
      -- PATH_BEFORE_INVALID anywhere in scene body/choices
      for _, s in ipairs(node.body or {}) do
        if has_path_at_before(s) then
          table.insert(acc.diags, ast.error(
            ast.E.PATH_BEFORE_INVALID,
            "path@before used in scene '" .. (node.name or "?") ..
              "' — only valid in fn post: blocks or verify after: assertions",
            s.pos or node.pos))
        end
      end
      for _, choice in ipairs(node.choices or {}) do
        for _, s in ipairs(choice.body or {}) do
          if has_path_at_before(s) then
            table.insert(acc.diags, ast.error(
              ast.E.PATH_BEFORE_INVALID,
              "path@before used in scene '" .. (node.name or "?") ..
                "' choice body — only valid in fn post: blocks or verify after: assertions",
              s.pos or node.pos))
          end
        end
      end

    elseif node.kind == k.VERIFY_DECL then
      -- PATH_BEFORE_INVALID: only valid in after: assertion bodies, not in the call
      -- expression and not in other clause kinds
      for _, clause in ipairs(node.clauses or {}) do
        if clause.clause_kind == "after" then
          -- The call expression (condition) must NOT contain path@before
          if clause.condition and has_path_at_before(clause.condition) then
            table.insert(acc.diags, ast.error(
              ast.E.PATH_BEFORE_INVALID,
              "path@before in after: call expression — only valid in the assertion body",
              clause.condition.pos or node.pos))
          end
          -- The assertion body (clause.body) is allowed
        else
          -- All other clause kinds: path@before is invalid
          if clause.condition and has_path_at_before(clause.condition) then
            table.insert(acc.diags, ast.error(
              ast.E.PATH_BEFORE_INVALID,
              "path@before in verify " .. (clause.clause_kind or "?") ..
                " clause — only valid in after: assertion bodies",
              clause.condition.pos or node.pos))
          end
          if type(clause.body) == "table" then
            for _, e in ipairs(clause.body) do
              if has_path_at_before(e) then
                table.insert(acc.diags, ast.error(
                  ast.E.PATH_BEFORE_INVALID,
                  "path@before in verify " .. (clause.clause_kind or "?") ..
                    " clause — only valid in after: assertion bodies",
                  e.pos or node.pos))
              end
            end
          end
        end
      end
    end
  end
end

-- ============================================================
-- Pass — Undeclared speaker hints
-- ============================================================

--- Walk a list of scene/fn body items and emit UNDECLARED_SPEAKER hints
--- for SAY_STMT nodes whose speaker is a static IDENT or SYMBOL not in symtab.speakers.
local function check_speakers_in_body(acc, symtab, body)
  local k = ast.K
  for _, node in ipairs(body or {}) do
    if not node or type(node) ~= "table" then
    elseif node.kind == k.SAY_STMT then
      local spk = node.speaker
      -- Only static symbols/idents are checked; dynamic exprs are skipped
      if spk and spk.kind == k.SYMBOL_LIT then
        local name = spk.name
        if type(name) == "string" and not symtab.speakers[name] then
          table.insert(acc.diags, ast.hint(
            ast.E.UNDECLARED_SPEAKER,
            "speaker '" .. name .. "' has no declaration",
            spk.pos,
            "add 'speaker " .. name .. ":' to provide display/color metadata"))
        end
      end
    elseif node.kind == k.WHEN_STMT then
      check_speakers_in_body(acc, symtab, node.body)
    elseif node.kind == k.IF_EXPR then
      check_speakers_in_body(acc, symtab, node.then_body)
      check_speakers_in_body(acc, symtab, node.else_body)
    end
  end
end

local function pass_check_speakers(acc, symtab, program)
  local k = ast.K
  for _, node in ipairs(program.decls) do
    if node.kind == k.SCENE_DECL then
      check_speakers_in_body(acc, symtab, node.body)
    elseif node.kind == k.FN_DECL then
      check_speakers_in_body(acc, symtab, node.body)
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

  -- Synthesise the auto-generated SceneId enum from all collected scene names.
  -- This must happen after pass1 so all scenes are known, but before pass2 so
  -- that TYPE_NAMED("SceneId") references can be resolved.
  if not symtab.types["SceneId"] then
    local scene_values = {}
    for name in pairs(symtab.scenes) do
      table.insert(scene_values, name)
    end
    table.sort(scene_values)
    local auto_pos = { file = "<auto>", line = 0, col = 0 }
    symtab.types["SceneId"] = ast.type_enum("SceneId", scene_values, nil, auto_pos)
  end

  pass2_check(acc, symtab, ast_root)
  pass3_infer_purity(acc, ast_root)
  pass3b_check_call_purity(acc, ast_root)
  pass3c_check_reversible(acc, ast_root)
  pass4_check_perceives(acc, ast_root)
  pass5_check_boundary(acc, symtab, ast_root)
  pass6_write_sets(acc, ast_root)
  pass7_check_contracts(acc, symtab, ast_root)
  pass_recursive_scenes(acc, ast_root)
  pass_check_speakers(acc, symtab, ast_root)

  -- Attach the symbol table to the AST root for use by codegen
  ast_root.symtab = symtab

  return ast_root, acc.diags
end

return M

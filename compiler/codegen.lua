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
local state_space_size_of_decl  -- forward declaration (mutual recursion)

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

--- Determine whether a type expression node represents a discrete type.
--- Discrete types have a finite, enumerable state-space (Bool, Int, Enum, Set, List, SymbolOf,
--- and their combinations). Superficial types (String, Float, UList, UMap, Symbol) are unbounded.
local is_discrete_texpr  -- forward declaration
local is_discrete_decl   -- forward declaration

is_discrete_decl = function(decl)
  if not decl then return true end
  local k = ast.K
  if decl.kind == k.TYPE_ENUM then
    return true  -- finite named values
  elseif decl.kind == k.TYPE_ALIAS then
    return is_discrete_texpr(decl.type_expr)
  elseif decl.kind == k.TYPE_RECORD then
    for _, f in ipairs(decl.fields or {}) do
      if f.kind == k.RECORD_FIELD and not is_discrete_texpr(f.type_expr) then
        return false
      end
    end
    return true
  elseif decl.kind == k.TYPE_VARIANT then
    for _, br in ipairs(decl.branches or {}) do
      for _, f in ipairs(br.fields or {}) do
        if f.kind == k.RECORD_FIELD and not is_discrete_texpr(f.type_expr) then
          return false
        end
      end
    end
    return true
  end
  return true  -- built-in marker or unknown → assume discrete
end

is_discrete_texpr = function(texpr)
  if not texpr then return false end
  local k = ast.K
  if texpr.kind == k.TYPE_BOOL          then return true
  elseif texpr.kind == k.TYPE_INT       then return true
  elseif texpr.kind == k.TYPE_ENUM_INLINE then return true
  elseif texpr.kind == k.TYPE_SYMBOL_OF then return true
  elseif texpr.kind == k.TYPE_OPTION    then return is_discrete_texpr(texpr.inner)
  elseif texpr.kind == k.TYPE_SET       then return is_discrete_texpr(texpr.inner)
  elseif texpr.kind == k.TYPE_LIST      then return is_discrete_texpr(texpr.inner)
  elseif texpr.kind == k.TYPE_NAMED     then return is_discrete_decl(texpr.resolved)
  elseif texpr.kind == k.TYPE_SYMBOL    then return false
  elseif texpr.kind == k.TYPE_STRING    then return false
  elseif texpr.kind == k.TYPE_FLOAT     then return false
  elseif texpr.kind == k.TYPE_ULIST     then return false
  elseif texpr.kind == k.TYPE_UMAP      then return false
  elseif texpr.kind == k.TYPE_FN        then return false
  end
  return false
end

--- Emit a compact serialisable descriptor for a type expression.
--- Each descriptor includes a `discrete` boolean: true iff the type has a
--- finite, enumerable state-space (suitable for search/verify).
local function emit_type_desc(texpr)
  if not texpr then return { tag = "unknown", discrete = false } end
  local k = ast.K
  local disc = is_discrete_texpr(texpr)

  if texpr.kind == k.TYPE_BOOL    then return { tag = "bool", discrete = true }
  elseif texpr.kind == k.TYPE_INT then
    return { tag = "int", min = texpr.min, max = texpr.max, discrete = true }
  elseif texpr.kind == k.TYPE_ENUM_INLINE then
    return { tag = "enum", values = texpr.values, discrete = true }
  elseif texpr.kind == k.TYPE_OPTION then
    return { tag = "option", inner = emit_type_desc(texpr.inner), discrete = disc }
  elseif texpr.kind == k.TYPE_SET then
    return { tag = "set", inner = emit_type_desc(texpr.inner), max = texpr.max, discrete = disc }
  elseif texpr.kind == k.TYPE_LIST then
    return { tag = "list", inner = emit_type_desc(texpr.inner), max = texpr.max, discrete = disc }
  elseif texpr.kind == k.TYPE_SYMBOL    then return { tag = "symbol",    discrete = false }
  elseif texpr.kind == k.TYPE_SYMBOL_OF then
    return { tag = "symbol_of", family = texpr.family, discrete = true }
  elseif texpr.kind == k.TYPE_STRING    then return { tag = "string",    discrete = false }
  elseif texpr.kind == k.TYPE_FLOAT     then return { tag = "float",     discrete = false }
  elseif texpr.kind == k.TYPE_ULIST then
    return { tag = "ulist", inner = emit_type_desc(texpr.inner), discrete = false }
  elseif texpr.kind == k.TYPE_UMAP then
    return { tag = "umap", key = emit_type_desc(texpr.key), val = emit_type_desc(texpr.val),
             discrete = false }
  elseif texpr.kind == k.TYPE_NAMED then
    return { tag = "named", name = texpr.name, discrete = disc }
  elseif texpr.kind == k.TYPE_FN then
    return { tag = "fn", discrete = false }
  end
  return { tag = "unknown", discrete = false }
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
  elseif node.kind == k.SET_LIT then
    local items = {}
    for _, item in ipairs(node.elements or {}) do
      items[#items+1] = emit_default(item)
    end
    return { tag = "set", items = items }
  elseif node.kind == k.LIST_LIT then
    local items = {}
    for _, item in ipairs(node.elements or {}) do
      items[#items+1] = emit_default(item)
    end
    return { tag = "list", items = items }
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

--- Collect all fields for a named record type, resolving `with` mixins.
--- decls_by_name: {name → decl_node}
--- Returns an ordered list of RECORD_FIELD-like tables with name, type_expr, default,
--- or nil if the type is not a record.
local function collect_type_record_fields(type_name, decls_by_name, visited)
  visited = visited or {}
  if visited[type_name] then return nil end   -- cycle guard
  visited[type_name] = true

  local decl = decls_by_name[type_name]
  if not decl or decl.kind ~= ast.K.TYPE_RECORD then return nil end

  local fields    = {}   -- ordered
  local seen      = {}   -- name → index for override

  for _, f in ipairs(decl.fields or {}) do
    if f.kind == ast.K.WITH_MIXIN then
      local mixin = collect_type_record_fields(f.type_name, decls_by_name, visited)
      if mixin then
        for _, mf in ipairs(mixin) do
          if not seen[mf.name] then
            seen[mf.name] = #fields + 1
            fields[#fields + 1] = mf
          end
          -- with-mixin fields that are already present are kept (subtype override comes later)
        end
      end
    elseif f.kind == ast.K.RECORD_FIELD and f.name then
      if seen[f.name] then
        fields[seen[f.name]] = f   -- override mixin default
      else
        seen[f.name] = #fields + 1
        fields[#fields + 1] = f
      end
    end
  end

  return fields
end

--- Emit schema.states list from all state declarations.
--- When a STATE_SCALAR references a named record type, expand it to kind="record"
--- so that init_defaults creates individual sub-paths (player/name, etc.).
local function emit_states(decls)
  -- Build a name → decl index for record-type lookup
  local decls_by_name = {}
  for _, d in ipairs(decls) do
    if d.name then decls_by_name[d.name] = d end
  end

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

      -- Check if the type is a named record: if so, expand to kind="record"
      local named_type = node.type_expr and node.type_expr.kind == k.TYPE_NAMED
                         and node.type_expr.name
      local type_fields = named_type and collect_type_record_fields(named_type, decls_by_name)

      if type_fields then
        -- Build constructor override map from the default expression
        local overrides = {}
        local ctor_node = node.default
        if ctor_node and ctor_node.kind == k.RECORD_CONSTRUCTOR then
          for _, f in ipairs(ctor_node.fields or {}) do
            if f.kind == k.NAMED_ARG and f.name then
              overrides[f.name] = f.value
            end
          end
        end

        -- Produce fields list: type defaults, overridden by constructor values
        local out_fields = {}
        for _, tf in ipairs(type_fields) do
          local default_node = overrides[tf.name] or tf.default
          table.insert(out_fields, {
            name      = tf.name,
            type_desc = emit_type_desc(tf.type_expr),
            default   = emit_default(default_node),
          })
        end

        table.insert(states, {
          kind   = "record",
          path   = path_str,
          fields = out_fields,
          doc    = node.doc,
        })
      else
        -- Scalar (non-record named type, or inline type)
        table.insert(states, {
          kind      = "scalar",
          path      = path_str,
          type_desc = emit_type_desc(node.type_expr),
          default   = emit_default(node.default),
          doc       = node.doc,
        })
      end

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

--- Emit schema.relations list and a by-name map with adjacency data.
--- Returns (relations_list, relations_by_name).
local function emit_relations(decls)
  local relations      = {}
  local relations_map  = {}  -- name → {name, data={src={dst=true,...}}}
  local k = ast.K
  for _, node in ipairs(decls) do
    if node.kind == k.RELATION_DECL then
      -- Build adjacency data from initial_data
      local data = {}
      for _, entry in ipairs(node.initial_data or {}) do
        local key_str = entry.key and (entry.key.value or entry.key.name) or "?"
        local adj = {}
        for _, v in ipairs(entry.values or {}) do
          local dst = v.value or v.name or tostring(v)
          adj[dst] = true
        end
        data[key_str] = adj
      end
      table.insert(relations, {
        name          = node.name,
        from_type     = node.from_type,
        to_type_desc  = emit_type_desc(node.to_type_expr),
        initial_count = #(node.initial_data or {}),
        doc           = node.doc,
      })
      relations_map[node.name] = { name = node.name, data = data }
    end
  end
  return relations, relations_map
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
--- When opts.production is true (and opts.strict_contracts is not), pre/post are stripped.
local function emit_fns(decls, opts)
  opts = opts or {}
  local strip_contracts = opts.production and not opts.strict_contracts
  local fns = {}
  local k = ast.K
  for _, node in ipairs(decls) do
    if node.kind == k.FN_DECL then
      fns[node.name] = {
        name           = node.name,
        params         = node.params or {},
        pre            = strip_contracts and {} or (node.pre or {}),
        post           = strip_contracts and {} or (node.post or {}),
        tags           = node.tags or {},
        body           = node.body or {},
        is_transaction = node.is_transaction or false,
        uses_bounded   = node.uses_bounded   or false,
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

--- Emit the actors table: name → actor descriptor.
local function emit_actors(decls)
  local actors = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.ACTOR_DECL then
      actors[node.name] = {
        name       = node.name,
        state_path = node.state_path,
        perceives  = node.perceives or {},
        inbox_type = node.inbox_type,
        behavior   = node.behavior,
        priority   = node.priority or 0,
        doc        = node.doc,
      }
    end
  end
  return actors
end

--- Emit the schedules table: name → schedule descriptor.
local function emit_schedules(decls)
  local schedules = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.SCHEDULE_DECL then
      schedules[node.name] = {
        name    = node.name,
        trigger = node.trigger or {},
        body    = node.body or {},
        doc     = node.doc,
      }
    end
  end
  return schedules
end

--- Emit the verifies list: [{label, clauses}]
--- Clauses contain raw AST nodes evaluated by the verify runtime.
local function emit_verifies(decls)
  local verifies = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.VERIFY_DECL then
      local clauses = {}
      for _, c in ipairs(node.clauses or {}) do
        clauses[#clauses+1] = {
          kind      = c.clause_kind,
          condition = c.condition,  -- AST expr node (may be nil)
          body      = c.body or {}, -- list of AST assertion nodes
        }
      end
      verifies[#verifies+1] = {
        label   = node.label,
        clauses = clauses,
      }
    end
  end
  return verifies
end

--- Emit the tests list: [{label, setup, run, expect}]
--- Raw AST nodes are preserved for evaluation by runtime/tests.lua.
local function emit_tests(decls)
  local tests = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.TEST_DECL then
      tests[#tests+1] = {
        label  = node.label,
        setup  = node.setup  or {},
        run    = node.run    or {},
        expect = node.expect or {},
      }
    end
  end
  return tests
end

--- Emit the watches list: [{kind, path/condition, label}]
local function emit_watches(decls)
  local watches = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.WATCH_DECL then
      watches[#watches+1] = {
        kind  = "watch",
        path  = node.path,
        label = node.label,
      }
    elseif node.kind == ast.K.WATCH_WHEN_DECL then
      watches[#watches+1] = {
        kind      = "watch_when",
        condition = node.condition,
        label     = node.label,
      }
    end
  end
  return watches
end

--- Emit bounded declarations into game_table.bounded
local function emit_bounded(decls)
  local bounded = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.BOUNDED_DECL then
      bounded[node.name] = {
        name         = node.name,
        returns      = emit_type_desc(node.returns_type),
        distribution = node.distribution,
        reads        = node.reads or {},
        lua          = node.lua_name,
        doc          = node.doc,
      }
    end
  end
  return bounded
end

--- Emit defgrid declarations into game_table.grids.
--- Returns a name-keyed table of grid descriptors.
local function emit_grids(decls)
  local grids = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.DEFGRID_DECL then
      grids[node.name] = {
        name        = node.name,
        width       = node.width  or 0,
        height      = node.height or 0,
        cell_type   = node.cell_type,
        default_val = node.default_val,
      }
    end
  end
  return grids
end

--- Emit tag declarations into game_table.tags (name-keyed set).
local function emit_tags(decls)
  local tags = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.TAG_DECL then
      tags[node.name] = true
    end
  end
  return tags
end

--- Emit hook declarations into game_table.hooks list.
--- Each entry: { hook_kind, target, body }
local function emit_hooks(decls)
  local hooks = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.HOOK_DECL then
      hooks[#hooks+1] = {
        hook_kind = node.hook_kind,
        target    = node.target,
        body      = node.body,
      }
    end
  end
  return hooks
end

--- Emit speaker declarations into a name-keyed map for the schema.
local function emit_speakers(decls)
  local speakers = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.SPEAKER_DECL then
      speakers[node.name] = {
        display = node.display or node.name,
        color   = node.color,
        doc     = node.doc,
      }
    end
  end
  return speakers
end

--- Emit generate declarations into game_table.generates (§F1).
--- Result is an ordered list so the engine runs them in source order.
--- Each entry preserves the raw AST body for runtime evaluation by eval.lua.
local function emit_generates(decls)
  local generates = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.GENERATE_DECL then
      generates[#generates+1] = {
        name      = node.name,
        seed_path = node.seed_path,  -- nil or PATH_EXPR/INTERP_PATH AST node
        body      = node.body or {},
        doc       = node.doc,
      }
    end
  end
  return generates
end

--- Emit ending declarations into game_table.endings (§F2).
--- Each entry preserves the when expression (AST) and the narration body
--- (scene-mode AST) for the engine to evaluate on every step.
local function emit_endings(decls)
  local endings = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.ENDING_DECL then
      endings[#endings+1] = {
        name      = node.name,
        when_expr = node.when_expr,
        body      = node.body or {},
        doc       = node.doc,
      }
    end
  end
  return endings
end

--- Emit quest declarations into game_table.quests (§E1).
--- Mostly informational — the runtime behaviour is carried entirely by the
--- desugared state + fn declarations spliced in by `compiler.expand_quests`.
--- Codegen keeps an entry per quest so tooling (docs, LSP) can list them.
---
--- Each entry exposes:
---   - name         string         the quest's identifier
---   - description  string?        author-supplied description (if any)
---   - doc          string?        author doc-string (if any)
---   - steps        table[]        per-step summaries (each: {name, requires})
---   - prereq       table?         AST node for the `prereq:` expression
---   - reward       table[]?       AST node list for the `reward:` body
---
--- §E4-gap-2: `prereq` and `reward` (and `steps[].requires`) are raw AST
--- nodes — sufficient for tooling that walks the AST shape directly. They
--- are documented as AST-shaped values; downstream tools should treat
--- them as opaque or use ast.K constants to dispatch on them. If a more
--- stable summary becomes necessary, build it from these AST nodes
--- without changing the field names.
local function emit_quests(decls)
  local quests = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.QUEST_DECL then
      local steps = {}
      for _, st in ipairs(node.steps or {}) do
        steps[#steps+1] = {
          name     = st.name,
          requires = st.requires,
        }
      end
      quests[#quests+1] = {
        name        = node.name,
        description = node.description,
        steps       = steps,
        doc         = node.doc,
        prereq      = node.prereq,
        reward      = node.reward,
      }
    end
  end
  return quests
end

--- Synthesise an auto-verify entry per quest declaration (§E1):
---   "quest '<name>' is reachable to completion" →
---     verify-eventually (quest-<name>-complete?)
---
--- This is the "emergent power" of §E1 — every declared quest gets a
--- reachability check for free, exposing wiring bugs (a quest is declared
--- but the player can't actually advance through its steps) at compile
--- time rather than at playtest time.
local function emit_quest_verifies(decls)
  local k = ast.K
  local out = {}

  local function make_clause(kind, expr)
    return { kind = kind, condition = expr, body = {} }
  end

  for _, node in ipairs(decls) do
    if node.kind == k.QUEST_DECL and node.name then
      local pos = node.pos
      -- condition: quest-<name>-complete?
      local cond = ast.fn_call("quest-" .. node.name .. "-complete?", {}, pos)
      out[#out+1] = {
        label   = "quest '" .. node.name .. "' is reachable to completion",
        clauses = { make_clause("eventually", cond) },
        _auto   = true,
      }
    end
  end

  return out
end

--- Synthesise auto-verify entries for every ending declaration (§F2):
---  - "ending '<name>' is reachable"          → verify-eventually <when_expr>
---  - "endings '<a>' and '<b>' are exclusive" → verify-always not (a and b)
--- The synthesised AST nodes mirror what the parser would produce for a
--- hand-written verify block, so verify.lua can consume them unchanged.
local function emit_ending_verifies(endings_list)
  local k = ast.K
  local out = {}
  if #endings_list == 0 then return out end

  local function make_clause(kind, expr)
    return { kind = kind, condition = expr, body = {} }
  end

  -- Reachability verify for each ending
  for _, e in ipairs(endings_list) do
    out[#out+1] = {
      label    = "ending '" .. (e.name or "?") .. "' is reachable",
      clauses  = { make_clause("eventually", e.when_expr) },
      _auto    = true,
    }
  end

  -- Pairwise mutual-exclusivity: verify-always not (a.when and b.when)
  for i = 1, #endings_list do
    for j = i + 1, #endings_list do
      local a, b = endings_list[i], endings_list[j]
      if a.when_expr and b.when_expr then
        local pos = a.when_expr.pos
        local conj = ast.binary_op("and", a.when_expr, b.when_expr, pos)
        local neg  = ast.unary_op("not", conj, pos)
        out[#out+1] = {
          label   = "endings '" .. a.name .. "' and '" .. b.name ..
                    "' are mutually exclusive",
          clauses = { make_clause("always", neg) },
          _auto   = true,
        }
      end
    end
  end

  return out
end

local function emit_migrations(decls)
  local migrations = {}
  for _, node in ipairs(decls) do
    if node.kind == ast.K.MIGRATION_DECL then
      migrations[#migrations+1] = {
        from_ver = node.from_ver,
        to_ver   = node.to_ver,
        ops      = node.ops or {},
      }
    end
  end
  -- Sort ascending by from_ver
  table.sort(migrations, function(a, b) return (a.from_ver or 0) < (b.from_ver or 0) end)
  return migrations
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
--- Emit a compiled game table from a typed AST.
---@param typed_ast table  The type-checked AST (output of checker)
---@param opts      table? Optional: {production=true} strips debug-only content
---@return table, table    game_table, diags
function M.emit(typed_ast, opts)
  opts = opts or {}
  local diags   = {}
  local decls   = typed_ast.decls or {}
  local symtab  = typed_ast.symtab or { types = {}, states = {}, relations = {}, scenes = {} }

  local types     = emit_types(decls)
  -- Append the auto-generated SceneId enum at the end of the types list
  local scene_id_decl = symtab.types and symtab.types["SceneId"]
  if scene_id_decl and scene_id_decl.kind == ast.K.TYPE_ENUM then
    table.insert(types, {
      kind      = "enum",
      name      = "SceneId",
      values    = scene_id_decl.values,
      auto      = true,   -- flag: generated, not user-declared
    })
  end
  local states    = emit_states(decls)
  local relations, relations_map = emit_relations(decls)
  local eng_cfg   = emit_engine_config(decls)
  local time_mdl  = emit_time_model(decls)
  local schema_v  = emit_schema_version(decls)
  local ss_size   = compute_total_state_space(decls, symtab)

  -- Count unique type/state/relation entries (user-declared only; SceneId is auto-generated)
  local k = ast.K
  local type_count = 0
  for _, d in ipairs(decls) do
    if d.kind == k.TYPE_ENUM or d.kind == k.TYPE_ALIAS
    or d.kind == k.TYPE_RECORD or d.kind == k.TYPE_VARIANT then
      type_count = type_count + 1
    end
  end
  local path_count     = 0
  for _ in pairs(symtab.states)    do path_count     = path_count     + 1 end
  local relation_count = 0
  for _ in pairs(symtab.relations) do relation_count = relation_count + 1 end
  local scene_count = 0
  local scene_names = {}
  for _, d in ipairs(decls) do
    if d.kind == ast.K.SCENE_DECL then
      scene_count = scene_count + 1
      table.insert(scene_names, d.name)
    end
  end
  table.sort(scene_names)

  local game_table = {
    schema = {
      version          = schema_v,
      type_count       = type_count,
      path_count       = path_count,
      scene_count      = scene_count,
      scene_names      = scene_names,
      relation_count   = relation_count,
      state_space_size = ss_size == math.huge and "unbounded" or ss_size,
      types            = types,
      states           = states,
      relations        = relations,
      engine_config    = eng_cfg,
      time_model       = time_mdl,
      speakers         = emit_speakers(decls),
    },
    fns        = emit_fns(decls, opts),
    scenes     = emit_scenes(decls),
    actors     = emit_actors(decls),
    schedules  = emit_schedules(decls),
    relations  = relations_map,  -- name → {name, data={src={dst=true,...}}} for runtime queries
    -- In production builds, strip debug-only content
    verifies   = opts.production and {} or emit_verifies(decls),
    watches    = opts.production and {} or emit_watches(decls),
    tests      = opts.production and {} or emit_tests(decls),
    migrations = emit_migrations(decls),
    bounded    = emit_bounded(decls),
    grids      = emit_grids(decls),
    tags       = emit_tags(decls),
    hooks      = emit_hooks(decls),
    generates  = emit_generates(decls),
    endings    = emit_endings(decls),
    quests     = emit_quests(decls),
    production = opts.production or false,
  }

  -- §F2: auto-emit reachability + mutual-exclusivity verify blocks for endings.
  -- Skipped in production (since verifies are stripped anyway).
  if not opts.production and #game_table.endings > 0 then
    local auto_v = emit_ending_verifies(game_table.endings)
    for _, v in ipairs(auto_v) do
      game_table.verifies[#game_table.verifies+1] = v
    end
  end

  -- §E1: auto-emit "quest is reachable to completion" verify blocks.
  -- Skipped in production (since verifies are stripped anyway).
  if not opts.production and #game_table.quests > 0 then
    local auto_v = emit_quest_verifies(decls)
    for _, v in ipairs(auto_v) do
      game_table.verifies[#game_table.verifies+1] = v
    end
  end

  return game_table, diags
end

return M

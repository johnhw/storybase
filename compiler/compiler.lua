-- compiler/compiler.lua
-- Pipeline orchestrator: source text → compiled game table.
--
-- Pipeline:  source text
--              → lexer.tokenize   → token stream
--              → parser.parse     → AST
--              → checker.check    → typed AST + symbol table
--              → codegen.emit     → compiled game table
--
-- All diagnostics are accumulated across every pass before returning.
-- The caller receives the compiled table (or nil on error) and the
-- full diagnostic accumulator.

local M = {}

local ast     = require("compiler.ast")
local lexer   = require("compiler.lexer")
local parser  = require("compiler.parser")
local checker = require("compiler.checker")
local codegen = require("compiler.codegen")

-- ============================================================
-- Import resolver
-- ============================================================

--- Resolve the absolute path of an imported file.
--- Imported paths are relative to the importing file's directory.
--- e.g. importing "lib/npc.sb" from "/games/main.sb" → "/games/lib/npc.sb"
---@param import_path string  Path from import declaration
---@param source_file string  Path of the file containing the import
---@return string  resolved absolute path
local function resolve_import_path(import_path, source_file)
  -- Extract directory of the source file
  local dir = source_file:match("^(.*[/\\])") or "./"
  -- If import_path is already absolute, return it unchanged
  if import_path:sub(1,1) == "/" then return import_path end
  return dir .. import_path
end

--- "Top-level" declaration kinds that should NOT be spliced from imported files.
--- (module metadata and import declarations are not re-exported)
local SKIP_ON_IMPORT = {
  [ast.K.MODULE_DECL]    = true,
  [ast.K.IMPORT_DECL]    = true,
  [ast.K.SCHEMA_VERSION] = true,
  [ast.K.ENGINE_CONFIG]  = true,
}

--- Declaration kinds that are subject to exports: filtering.
--- State/relation/grid/speaker/verify/hook declarations are always exported.
local EXPORTS_FILTERABLE = {
  [ast.K.FN_DECL]       = true,
  [ast.K.SCENE_DECL]    = true,
  [ast.K.ACTOR_DECL]    = true,
  [ast.K.SCHEDULE_DECL] = true,
  [ast.K.BOUNDED_DECL]  = true,
  [ast.K.MACRO_DECL]    = true,
  [ast.K.TYPE_ENUM]     = true,
  [ast.K.TYPE_ALIAS]    = true,
  [ast.K.TYPE_RECORD]   = true,
  [ast.K.TYPE_VARIANT]  = true,
}

--- Apply namespace prefix to all non-state declarations from a namespaced import.
--- Renames type/fn/scene/actor/schedule/bounded/macro declarations to "Alias.Name",
--- and rewrites all internal cross-references accordingly.
--- State and relation declarations remain global (unchanged paths).
---@param imp_ast table  Parsed+resolved AST of the imported module (modified in-place)
---@param alias   string  The namespace alias (e.g. "E" for `import "x" as E`)
local function apply_import_namespace(imp_ast, alias)
  local k = ast.K

  -- Collect names to prefix (type/fn/scene/actor/schedule/bounded/macro)
  local rename = {}
  for _, decl in ipairs(imp_ast.decls or {}) do
    local dk = decl.kind
    if (dk == k.TYPE_ENUM or dk == k.TYPE_ALIAS or
        dk == k.TYPE_RECORD or dk == k.TYPE_VARIANT or
        dk == k.FN_DECL or dk == k.SCENE_DECL or
        dk == k.ACTOR_DECL or dk == k.SCHEDULE_DECL or
        dk == k.BOUNDED_DECL or dk == k.MACRO_DECL)
       and decl.name then
      rename[decl.name] = alias .. "." .. decl.name
    end
  end
  if not next(rename) then return end

  -- Recursive rename walker.
  -- Handles AST nodes (kind present) and plain tables (pos, trigger, lists, etc.)
  local function rn(node)
    if type(node) ~= "table" then return node end

    -- Plain table (no kind): walk all key-value pairs
    if not node.kind then
      local copy = {}
      local changed = false
      for f, v in pairs(node) do
        local nv = rn(v)
        copy[f] = nv
        if nv ~= v then changed = true end
      end
      return changed and copy or node
    end

    -- AST node: shallow-copy, apply targeted renames, then walk all child tables
    local copy = {}
    for f, v in pairs(node) do copy[f] = v end
    local nk = node.kind

    -- Rename declaration names
    if copy.name and rename[copy.name] and
       (nk == k.TYPE_ENUM or nk == k.TYPE_ALIAS or
        nk == k.TYPE_RECORD or nk == k.TYPE_VARIANT or
        nk == k.FN_DECL or nk == k.SCENE_DECL or
        nk == k.ACTOR_DECL or nk == k.SCHEDULE_DECL or
        nk == k.BOUNDED_DECL or nk == k.MACRO_DECL) then
      copy.name = rename[copy.name]
    end

    -- Rename TYPE_NAMED references
    if nk == k.TYPE_NAMED and copy.name and rename[copy.name] then
      copy.name = rename[copy.name]
    end

    -- Rename FN_CALL and MACRO_CALL_STMT names
    if (nk == k.FN_CALL or nk == k.MACRO_CALL_STMT)
       and copy.name and rename[copy.name] then
      copy.name = rename[copy.name]
    end

    -- Rename scene navigation targets (string targets only; expr targets are walked below)
    if (nk == k.GOTO_SCENE_MUT or nk == k.ENTER_SCENE_MUT or
        nk == k.SCENE_GOTO or nk == k.SCENE_ENTER)
       and type(copy.target) == "string" and rename[copy.target] then
      copy.target = rename[copy.target]
    end

    -- Rename schedule mutation names
    if (nk == k.SCHEDULE_MUT or nk == k.CANCEL_SCHEDULE_MUT)
       and copy.name and rename[copy.name] then
      copy.name = rename[copy.name]
    end

    -- Rename record constructor type names ("TypeName" or "TypeName/variant")
    if nk == k.RECORD_CONSTRUCTOR and copy.type_name then
      local slash = (copy.type_name):find("/")
      if slash then
        local tname = (copy.type_name):sub(1, slash - 1)
        local rest  = (copy.type_name):sub(slash)
        if rename[tname] then copy.type_name = rename[tname] .. rest end
      elseif rename[copy.type_name] then
        copy.type_name = rename[copy.type_name]
      end
    end

    -- Recursively walk all table-valued child fields
    for f, v in pairs(copy) do
      if f ~= "pos" and type(v) == "table" then
        copy[f] = rn(v)
      end
    end

    return copy
  end

  -- Apply rename walk to all declarations
  local new_decls = {}
  for _, decl in ipairs(imp_ast.decls or {}) do
    new_decls[#new_decls + 1] = rn(decl)
  end
  imp_ast.decls = new_decls
end

--- Recursively resolve all import declarations in an AST node, splicing
--- imported declarations in-place before the first non-import declaration.
---
---@param ast_root    table   Parsed AST (PROGRAM node with .decls)
---@param source_file string  Absolute or relative path of the source file
---@param diags       table   Diagnostic accumulator
---@param in_progress table   Set of files currently being resolved (cycle detection)
local function resolve_imports(ast_root, source_file, diags, in_progress)
  in_progress = in_progress or {}
  local canonical = source_file  -- used as the cycle-detection key

  local new_decls = {}
  for _, decl in ipairs(ast_root.decls or {}) do
    if decl.kind ~= ast.K.IMPORT_DECL then
      new_decls[#new_decls+1] = decl
    else
      -- Resolve the import path
      local imp_path = resolve_import_path(decl.path, source_file)

      -- Cycle detection
      if in_progress[imp_path] then
        diags:push_error(ast.E.IMPORT_CYCLE,
          string.format("import cycle detected: '%s' is already being compiled", imp_path),
          decl.pos or ast.pos(source_file, 0, 0))
        -- Do not splice; continue
      else
        -- Read and parse the imported file
        local f, ferr = io.open(imp_path, "r")
        if not f then
          diags:push_error(ast.E.FILE_NOT_FOUND,
            string.format("cannot open imported file '%s': %s", imp_path, tostring(ferr)),
            decl.pos or ast.pos(source_file, 0, 0))
        else
          local imp_src = f:read("*a"); f:close()
          local imp_tokens, ld = lexer.tokenize(imp_src, imp_path)
          diags:push_all(ld)
          if imp_tokens then
            local imp_ast, pd = parser.parse(imp_tokens, imp_path)
            diags:push_all(pd)
            if imp_ast then
              -- Recurse into imported file's imports
              in_progress[imp_path] = true
              resolve_imports(imp_ast, imp_path, diags, in_progress)
              in_progress[imp_path] = nil
              -- Apply exports: filtering before namespace renaming (names are originals here)
              local exports_set = nil
              for _, d in ipairs(imp_ast.decls or {}) do
                if d.kind == ast.K.MODULE_DECL and d.exports and #d.exports > 0 then
                  exports_set = {}
                  for _, n in ipairs(d.exports) do exports_set[n] = true end
                  break
                end
              end
              if exports_set then
                local filtered = {}
                for _, d in ipairs(imp_ast.decls or {}) do
                  if EXPORTS_FILTERABLE[d.kind] then
                    if d.name and exports_set[d.name] then
                      filtered[#filtered + 1] = d
                    end
                  else
                    filtered[#filtered + 1] = d
                  end
                end
                imp_ast.decls = filtered
              end
              -- Apply namespace prefix if this is an aliased import
              if decl.alias then
                apply_import_namespace(imp_ast, decl.alias)
              end
              -- Splice non-metadata declarations
              for _, d in ipairs(imp_ast.decls or {}) do
                if not SKIP_ON_IMPORT[d.kind] then
                  new_decls[#new_decls+1] = d
                end
              end
            end
          end
        end
      end
    end
  end
  ast_root.decls = new_decls
  local _ = canonical  -- suppress unused warning
end

-- ============================================================
-- Macro expansion pass
-- ============================================================

--- Deep-copy an AST node, substituting param_map values for bare fn_calls
--- and body_param's statement list for MACRO_CALL_STMT body placeholders.
--- hyg_prefix is a string prepended to let-binding names for hygiene.
--- renames maps original let-bound names → hygienic names in the current scope.
local function expand_macro_body(stmts, param_map, body_param, body_stmts, hyg_prefix)
  local K = ast.K

  -- Returns true if stmt is a body_param placeholder call.
  local function is_body_ref(stmt)
    if not body_param then return false end
    if stmt.kind == K.FN_CALL and stmt.name == body_param
       and #(stmt.args or {}) == 0 then return true end
    if stmt.kind == K.EXPR_STMT and stmt.expr
       and stmt.expr.kind == K.FN_CALL
       and stmt.expr.name == body_param
       and #(stmt.expr.args or {}) == 0 then return true end
    return false
  end

  -- Declare both as upvalue variables so they can call each other.
  local subst, subst_list

  -- Expand a statement list: splice body_stmts at body_param refs, recurse into each node.
  subst_list = function(list, renames)
    local out = {}
    for _, item in ipairs(list or {}) do
      if type(item) == "table" and item.kind and is_body_ref(item) then
        for _, bs in ipairs(body_stmts or {}) do
          out[#out+1] = bs
        end
      elseif type(item) == "table" and item.kind then
        out[#out+1] = subst(item, renames)
      else
        out[#out+1] = item
      end
    end
    return out
  end

  subst = function(node, renames)
    if not node or type(node) ~= "table" then return node end
    local k = node.kind
    -- Bare fn_call with no args: check param substitution then local renames
    if k == K.FN_CALL and #(node.args or {}) == 0 then
      local pval = param_map[node.name]
      if pval ~= nil then return pval end
      local rn = renames and renames[node.name]
      if rn then return { kind=K.FN_CALL, name=rn, args={}, pos=node.pos } end
    end
    -- NAMED_ARG: if name matches a macro param, substitute the whole node with
    -- the param value.  This handles 'param:' at the end of a condition line
    -- where the lexer fuses identifier+colon into one NAMED_ARG token.
    if k == K.NAMED_ARG then
      local pval = param_map[node.name]
      if pval ~= nil then return pval end
      local rn = renames and renames[node.name]
      if rn then
        return { kind=K.NAMED_ARG, name=rn, value=subst(node.value, renames), pos=node.pos }
      end
    end
    -- Single-segment path_expr: rename if local var (used as mutation target, e.g. set! i)
    if k == K.PATH_EXPR then
      local segs = node.segments
      if segs and #segs == 1 and type(segs[1]) == "string" then
        local rn = renames and renames[segs[1]]
        if rn then return { kind=K.PATH_EXPR, segments={rn}, pos=node.pos } end
      end
    end
    -- LET_STMT: build extended rename scope before recursing into body
    if k == K.LET_STMT and hyg_prefix then
      -- Binding exprs evaluated in the outer scope
      local ext = {}
      for kk, vv in pairs(renames or {}) do ext[kk] = vv end
      local new_bindings = {}
      for _, b in ipairs(node.bindings or {}) do
        if b.kind == K.LET_BINDING and b.name then
          local new_name = hyg_prefix .. b.name
          ext[b.name] = new_name
          new_bindings[#new_bindings+1] = {
            kind = b.kind,
            name = new_name,
            expr = subst(b.expr, renames),  -- init expr in outer scope
            pos  = b.pos,
          }
        else
          new_bindings[#new_bindings+1] = subst(b, renames)
        end
      end
      return { kind=k, bindings=new_bindings,
               body=subst_list(node.body, ext), pos=node.pos }
    end
    -- Generic recursive deep-copy with renames propagated
    local copy = {}
    for field, val in pairs(node) do
      if type(val) == "table" and val.kind then
        copy[field] = subst(val, renames)
      elseif type(val) == "table" then
        -- Use subst_list for arrays of AST nodes (handles body_param splicing)
        local is_node_list = false
        for _, item in ipairs(val) do
          if type(item) == "table" and item.kind then is_node_list = true end
          break
        end
        if is_node_list then
          copy[field] = subst_list(val, renames)
        else
          local new_list = {}
          for i, item in ipairs(val) do
            new_list[i] = item
          end
          copy[field] = new_list
        end
      else
        copy[field] = val
      end
    end
    return copy
  end

  return subst_list(stmts, {})
end

--- Walk all statement lists in an AST, expanding macro calls.
--- macros: {name → macro_decl}
--- diags: accumulator
--- expanding: set of macro names currently being expanded (cycle detection)
local function walk_and_expand(stmts, macros, diags, expanding, filename)
  if not stmts then return stmts end
  local K = ast.K
  local result = {}
  local expansion_count = 0
  for _, stmt in ipairs(stmts) do
    if stmt.kind == K.MACRO_CALL_STMT then
      local macro = macros[stmt.name]
      if not macro then
        diags:push_error(ast.E.UNDEFINED_NAME,
          "macro '" .. stmt.name .. "' is not defined",
          ast.pos(filename, stmt.pos and stmt.pos.line or 0, stmt.pos and stmt.pos.col or 0))
        -- keep as-is so remaining stmts are still processed
        result[#result+1] = stmt
      elseif expanding[stmt.name] then
        diags:push_error(ast.E.MACRO_RECURSIVE,
          "recursive macro invocation: '" .. stmt.name .. "'",
          ast.pos(filename, stmt.pos and stmt.pos.line or 0, stmt.pos and stmt.pos.col or 0))
        -- skip this stmt to break the cycle
      else
        -- Find the body parameter name (last param if macro has params)
        local params = macro.params or {}
        local body_param = nil
        local expr_params = {}
        -- Recursively search stmt lists for a bare call to pname.
        local function finds_bare_call(stmts, pname)
          for _, ms in ipairs(stmts or {}) do
            if (ms.kind == K.FN_CALL and ms.name == pname and #(ms.args or {}) == 0)
            or (ms.kind == K.EXPR_STMT and ms.expr and ms.expr.kind == K.FN_CALL
                and ms.expr.name == pname and #(ms.expr.args or {}) == 0) then
              return true
            end
            -- Recurse into nested statement lists
            for _, field in ipairs({"body","then_body","else_body","arms","clauses"}) do
              if type(ms[field]) == "table" and finds_bare_call(ms[field], pname) then
                return true
              end
            end
          end
          return false
        end
        -- Last param is body if it is referenced as a bare call anywhere in the macro body
        for i, pname in ipairs(params) do
          if i == #params then
            if finds_bare_call(macro.body, pname) then
              body_param = pname
            else
              expr_params[#expr_params+1] = pname
            end
          else
            expr_params[#expr_params+1] = pname
          end
        end

        -- Build param substitution map.
        -- Named-arg call syntax produces NAMED_ARG nodes in stmt.args; unwrap
        -- them to get the actual expression value so the substituted AST is clean.
        local param_map = {}
        for i, pname in ipairs(expr_params) do
          local arg = stmt.args[i]
          if arg and arg.kind == ast.K.NAMED_ARG then
            param_map[pname] = arg.value
          else
            param_map[pname] = arg
          end
        end

        -- Hygiene prefix: _m<N>_ where N is an expansion counter
        expansion_count = expansion_count + 1
        local hyg_prefix = "_m" .. expansion_count .. "_"

        -- Mark as expanding (for recursion detection)
        expanding[stmt.name] = true

        -- Expand macro body
        local expanded = expand_macro_body(
          macro.body, param_map, body_param, stmt.body, hyg_prefix)

        -- Recursively process the expanded stmts (they may contain nested macro calls)
        expanded = walk_and_expand(expanded, macros, diags, expanding, filename)

        expanding[stmt.name] = nil

        -- Append expanded stmts
        for _, es in ipairs(expanded) do result[#result+1] = es end
      end
    else
      -- Recursively walk sub-bodies of this stmt
      local copy = {}
      for k, v in pairs(stmt) do copy[k] = v end
      for _, field in ipairs({"body","then_body","else_body","arms","clauses","choices"}) do
        if type(copy[field]) == "table" then
          copy[field] = walk_and_expand(copy[field], macros, diags, expanding, filename)
        end
      end
      result[#result+1] = copy
    end
  end
  return result
end

-- ============================================================
-- §E0 Stage 3 — decl-level macro expansion
-- ============================================================
--
-- A `decl-macro NAME params...:` declaration defines a *template* for a
-- list of declarations (state, fn, verify, ...) parameterised by `$ident`
-- substitution slots.  At every `MACRO_CALL_DECL` site found in the
-- top-level decl list, we look up the matching `decl-macro`, build a
-- param map from the call's positional args, deep-copy the template body
-- with substitutions applied, and splice the resulting decls into the
-- program.  Both `DECL_MACRO_DECL` and `MACRO_CALL_DECL` nodes are
-- stripped from the AST before the checker sees it.
--
-- Substitution sites:
--   * `PATH_EXPR.segments` may contain `{kind="macro_param", name=X}` or
--     `{kind="composite", parts={...}}` entries; both are replaced by
--     concrete string segments.
--   * Top-level `name_parts` on a node (e.g. FN_DECL) — same shape; the
--     resolved string overwrites `.name` and `name_parts` is removed.

-- Forward-declared so substitute_decl_node can reference it before its
-- definition (it lives below for proximity to its sole caller).
local compose_name_placeholder_for_err

--- Stringify a `path_expr`-shaped param argument into a string. Used when
--- a param value needs to land inside a composite identifier (e.g. fn
--- name `$path-inc`). Returns (string, err_message_or_nil) — err is set
--- when the value cannot be stringified to a *single* identifier
--- segment (e.g. multi-segment path).
local function _stringify_param_for_segment(val)
  if val == nil then
    return nil, "param value is missing"
  end
  if type(val) == "string" then
    if val:find("/", 1, true) then
      return nil, "param value '" .. val .. "' contains '/'"
    end
    return val
  end
  if type(val) ~= "table" or not val.kind then
    return nil, "param value is not a path-shaped expression"
  end
  if val.kind == ast.K.PATH_EXPR then
    local segs = val.segments or {}
    if #segs == 0 then
      return nil, "param value has no segments"
    end
    if #segs > 1 then
      return nil, "param value spans " .. #segs ..
        " path segments; expected a single identifier"
    end
    local s = segs[1]
    if type(s) ~= "string" then
      return nil, "param value's segment is not yet substituted"
    end
    return s
  end
  if val.kind == ast.K.FN_CALL and (#(val.args or {}) == 0) then
    return val.name  -- bare ident-as-fn-call
  end
  if val.kind == ast.K.SYMBOL_LIT then
    return val.name
  end
  if val.kind == ast.K.STRING_LIT then
    return val.value
  end
  return nil, "param value of kind '" .. tostring(val.kind) ..
    "' cannot stringify to an identifier"
end

--- Resolve a composite name_parts list (mixed strings and macro_param
--- placeholder tables) against `param_map`, returning the concatenated
--- string or (nil, err) on failure.
local function _resolve_name_parts(parts, param_map)
  local out = {}
  for _, p in ipairs(parts) do
    if type(p) == "string" then
      out[#out + 1] = p
    elseif type(p) == "table" and p.kind == "macro_param" then
      local val = param_map[p.name]
      if val == nil then
        return nil, "no value bound for $" .. p.name
      end
      local s, err = _stringify_param_for_segment(val)
      if not s then return nil, err end
      out[#out + 1] = s
    else
      return nil, "unexpected name-part entry"
    end
  end
  return table.concat(out)
end

--- Given a path-expr param value, return its segments as a list of
--- strings (so they can be spliced into the surrounding segments list).
local function _path_segments_of(val)
  if val == nil then return nil, "param value is missing" end
  if type(val) == "string" then return { val } end
  if type(val) ~= "table" or not val.kind then
    return nil, "param value is not a path-shaped expression"
  end
  if val.kind == ast.K.PATH_EXPR then
    local segs = {}
    for _, s in ipairs(val.segments or {}) do
      if type(s) ~= "string" then
        return nil, "param value contains an un-substituted segment"
      end
      segs[#segs + 1] = s
    end
    return segs
  end
  if val.kind == ast.K.FN_CALL and (#(val.args or {}) == 0) then
    return { val.name }
  end
  if val.kind == ast.K.SYMBOL_LIT then return { val.name } end
  if val.kind == ast.K.STRING_LIT then return { val.value } end
  return nil,
    "param value of kind '" .. tostring(val.kind) ..
    "' cannot supply path segments"
end

--- Deep-copy `node`, substituting macro params throughout. Recurses into
--- all table-valued fields. Reports errors into `diags` with the
--- `call_pos` source position. Returns the substituted copy.
---
--- `expansion_info` (§E0 Stage 4) — table `{ macro_name, macro_pos }`
--- attached to every emitted node's `pos`, so downstream diagnostics
--- pick up an "expanded from macro 'NAME' at FILE:LINE" note for free
--- via `ast.format_expanded_from` inside the diagnostic constructor.
local function substitute_decl_node(node, param_map, diags, call_pos, filename, expansion_info)
  -- Forward declaration so the closures below can reference it.
  local subst

  -- Resolve a PATH_EXPR.segments-style list: replace macro_param and
  -- composite placeholder entries with concrete strings; flatten
  -- macro_param values that are themselves multi-segment paths.
  local function subst_path_segments(segs)
    local out = {}
    for _, s in ipairs(segs) do
      if type(s) == "string" then
        out[#out + 1] = s
      elseif type(s) == "table" and s.kind == "macro_param" then
        local val = param_map[s.name]
        if val == nil then
          diags:push_error(ast.E.MACRO_DECL_EMIT,
            "decl-macro: no value bound for $" .. s.name,
            ast.pos(filename, call_pos.line or 0, call_pos.col or 0))
        else
          local segs2, err = _path_segments_of(val)
          if not segs2 then
            diags:push_error(ast.E.MACRO_DECL_EMIT,
              "decl-macro: cannot substitute $" .. s.name .. ": " .. err,
              ast.pos(filename, call_pos.line or 0, call_pos.col or 0))
          else
            for _, seg in ipairs(segs2) do out[#out + 1] = seg end
          end
        end
      elseif type(s) == "table" and s.kind == "composite" then
        local resolved, err = _resolve_name_parts(s.parts or {}, param_map)
        if not resolved then
          diags:push_error(ast.E.MACRO_DECL_EMIT,
            "decl-macro: cannot resolve composite identifier: " .. err,
            ast.pos(filename, call_pos.line or 0, call_pos.col or 0))
        else
          out[#out + 1] = resolved
        end
      else
        out[#out + 1] = s  -- {interp=...} or other shape; leave intact
      end
    end
    return out
  end

  subst = function(n)
    if type(n) ~= "table" then return n end

    -- Plain (kindless) table: walk all keys
    if not n.kind then
      local copy = {}
      for k, v in pairs(n) do copy[k] = subst(v) end
      return copy
    end

    -- AST node: shallow-copy
    local copy = {}
    for k, v in pairs(n) do copy[k] = v end

    -- PATH_EXPR with macro_param / composite segments → substitute
    if n.kind == ast.K.PATH_EXPR and type(n.segments) == "table" then
      copy.segments = subst_path_segments(n.segments)
    end

    -- Resolve `name_parts` field on decl-name-bearing nodes
    if type(copy.name_parts) == "table" then
      local resolved, err = _resolve_name_parts(copy.name_parts, param_map)
      if not resolved then
        diags:push_error(ast.E.MACRO_DECL_EMIT,
          "decl-macro: cannot resolve identifier '" ..
          compose_name_placeholder_for_err(copy.name_parts) .. "': " .. err,
          ast.pos(filename, call_pos.line or 0, call_pos.col or 0))
      else
        copy.name = resolved
      end
      copy.name_parts = nil
    end

    -- Stamp call-site position on every emitted node so checker errors
    -- point at the call site, not the macro body line. Preserve a link
    -- back to the macro body for tooling on the node itself, and attach
    -- `expanded_from` to the pos table so any diagnostic carrying that
    -- pos is auto-decorated with an "expanded from macro 'X' at F:L" note
    -- (see ast.format_expanded_from / ast._diag).
    local orig_pos = copy.pos
    local new_pos = ast.pos(
      filename,
      call_pos.line or 0,
      call_pos.col or 0)
    if expansion_info then
      new_pos.expanded_from = expansion_info
    end
    copy.pos = new_pos
    copy.expanded_from = orig_pos

    -- Recurse into all child table-valued fields (after the shallow-copy
    -- of scalar fields).
    for k, v in pairs(copy) do
      if k ~= "pos" and k ~= "expanded_from"
         and k ~= "name_parts" -- already handled
         and type(v) == "table" then
        copy[k] = subst(v)
      end
    end

    return copy
  end

  return subst(node)
end

-- Helper to format a parts list for diagnostic messages without leaking
-- the internal table shape. (Mirrors parser's compose_name_placeholder
-- but lives here to avoid a circular require.)
compose_name_placeholder_for_err = function(parts)
  local out = {}
  for _, p in ipairs(parts or {}) do
    if type(p) == "string" then
      out[#out + 1] = p
    elseif type(p) == "table" and p.kind == "macro_param" then
      out[#out + 1] = "$" .. p.name
    else
      out[#out + 1] = "?"
    end
  end
  return table.concat(out)
end

--- Expand all top-level `MACRO_CALL_DECL` invocations into their spliced
--- decl lists. Reports `UNDEFINED_NAME` for unknown macros and
--- `MACRO_DECL_EMIT` for malformed substitutions.
---
---@param ast_root table   PROGRAM node
---@param diags    table   Diagnostic accumulator
---@param filename string
local function expand_decl_macros(ast_root, diags, filename)
  -- 1. Collect every DECL_MACRO_DECL by name.
  local decl_macros = {}
  for _, decl in ipairs(ast_root.decls or {}) do
    if decl and decl.kind == ast.K.DECL_MACRO_DECL then
      if decl_macros[decl.name] then
        diags:push_error(ast.E.DUPLICATE_NAME,
          "duplicate decl-macro '" .. decl.name .. "'",
          ast.pos(filename, decl.pos and decl.pos.line or 0,
                            decl.pos and decl.pos.col or 0))
      else
        decl_macros[decl.name] = decl
      end
    end
  end

  -- 2. Walk decl list, splicing expansions at each MACRO_CALL_DECL.
  local new_decls = {}
  for _, decl in ipairs(ast_root.decls or {}) do
    if decl and decl.kind == ast.K.MACRO_CALL_DECL then
      local m = decl_macros[decl.name]
      if not m then
        -- Not a known decl-macro: leave the node in place; the existing
        -- stmt-level macro expander or later passes will diagnose. We
        -- emit a targeted error here too so the message is actionable.
        diags:push_error(ast.E.UNDEFINED_NAME,
          "no decl-macro named '" .. decl.name .. "' is in scope",
          ast.pos(filename, decl.pos and decl.pos.line or 0,
                            decl.pos and decl.pos.col or 0))
      else
        local params = m.params or {}
        local args   = decl.args or {}
        if #args ~= #params then
          diags:push_error(ast.E.MACRO_DECL_EMIT,
            string.format(
              "decl-macro '%s' expects %d argument(s), got %d",
              decl.name, #params, #args),
            ast.pos(filename, decl.pos and decl.pos.line or 0,
                              decl.pos and decl.pos.col or 0))
        else
          local param_map = {}
          for i, pname in ipairs(params) do
            local arg = args[i]
            if arg and arg.kind == ast.K.NAMED_ARG then
              param_map[pname] = arg.value
            else
              param_map[pname] = arg
            end
          end
          local call_pos = decl.pos or ast.pos(filename, 0, 0)
          local expansion_info = {
            macro_name = m.name,
            macro_pos  = m.pos or ast.pos(filename, 0, 0),
          }
          for _, body_decl in ipairs(m.body or {}) do
            local expanded = substitute_decl_node(
              body_decl, param_map, diags, call_pos, filename,
              expansion_info)
            new_decls[#new_decls + 1] = expanded
          end
        end
      end
    elseif decl and decl.kind == ast.K.DECL_MACRO_DECL then
      -- Strip: templates are not part of the final program.
    else
      new_decls[#new_decls + 1] = decl
    end
  end
  ast_root.decls = new_decls
end

--- Expand all macro calls in the parsed AST, in-place.
---@param ast_root table  PROGRAM node with .decls
---@param diags    table  Diagnostic accumulator
---@param filename string
local function expand_macros(ast_root, diags, filename)
  -- ── §E0 Stage 3: decl-level expansion runs first so the spliced decls
  -- ── can themselves contain stmt-level macro calls that get expanded
  -- ── in the second pass below.
  expand_decl_macros(ast_root, diags, filename)
  if diags:has_errors() then return end

  -- Collect macro declarations
  local macros = {}
  for _, decl in ipairs(ast_root.decls or {}) do
    if decl and decl.kind == ast.K.MACRO_DECL then
      -- Check for macro bodies that call other macros in the same unit (MACRO_CROSS_UNIT)
      macros[decl.name] = decl
    end
  end
  -- Check for cross-unit macro use in macro bodies
  for mname, mdecl in pairs(macros) do
    for _, stmt in ipairs(mdecl.body or {}) do
      if stmt.kind == ast.K.MACRO_CALL_STMT and macros[stmt.name] and stmt.name ~= mname then
        diags:push_error(ast.E.MACRO_CROSS_UNIT,
          "macro '" .. mname .. "' expands macro '" .. stmt.name
          .. "' from the same compilation unit",
          ast.pos(filename, stmt.pos and stmt.pos.line or 0, stmt.pos and stmt.pos.col or 0))
      end
    end
  end

  -- Expand macros in all declaration bodies.
  local new_decls = {}
  for _, decl in ipairs(ast_root.decls or {}) do
    if decl and decl.kind ~= ast.K.MACRO_DECL then
      local copy = {}
      for k, v in pairs(decl) do copy[k] = v end
      -- Expand in fn/scene/actor bodies
      for _, field in ipairs({"body","choices","arms"}) do
        if type(copy[field]) == "table" then
          copy[field] = walk_and_expand(copy[field], macros, diags, {}, filename)
        end
      end
      new_decls[#new_decls+1] = copy
    end
    -- Macro decls themselves are dropped from the output (they've been expanded)
  end
  ast_root.decls = new_decls
end

--- Compile StoryBase source text.
---
--- Returns (game_table, diags):
---   game_table  — compiled Lua table ready for the runtime, or nil on error
---   diags       — ast.new_accum() with .errors, .warnings, .all lists
---
---@param source   string  Source text of the .sb file
---@param filename string  File name used in diagnostic messages
---@return table?, table
function M.compile(source, filename, opts)
  opts = opts or {}
  local diags = ast.new_accum()

  -- ── Pass 1: Lex ──────────────────────────────────────────────
  local tokens, lex_diags = lexer.tokenize(source, filename)
  diags:push_all(lex_diags)
  -- Continue parsing even with lex errors when possible; stop only if
  -- the token stream is completely unusable (i.e. nil).
  if tokens == nil then
    return nil, diags
  end

  -- ── Pass 2: Parse ────────────────────────────────────────────
  local ast_root, parse_diags = parser.parse(tokens, filename)
  diags:push_all(parse_diags)
  -- A nil AST means the parser could not produce any tree; stop.
  if ast_root == nil then
    return nil, diags
  end

  -- ── Pass 2.5: Resolve imports ────────────────────────────────
  resolve_imports(ast_root, filename, diags, {})
  if diags:has_errors() then return nil, diags end

  -- ── Pass 2.6: Macro expansion ────────────────────────────────
  expand_macros(ast_root, diags, filename)
  if diags:has_errors() then return nil, diags end

  -- ── Pass 3: Check (multiple sub-passes inside checker) ───────
  local typed_ast, check_diags = checker.check(ast_root, filename)
  diags:push_all(check_diags)
  if diags:has_errors() then
    return nil, diags
  end

  -- ── Pass 4: Codegen ──────────────────────────────────────────
  local game_table, gen_diags = codegen.emit(typed_ast, opts)
  diags:push_all(gen_diags)
  if diags:has_errors() then
    return nil, diags
  end

  return game_table, diags
end

--- Parse and type-check source text, returning the typed AST (stops before codegen).
--- Useful for tools that need to walk the AST (e.g. extract-symbols).
---
---@param source   string
---@param filename string
---@return table?, table   typed_ast (with .decls), diags
function M.parse_and_check(source, filename)
  local diags = ast.new_accum()

  local tokens, lex_diags = lexer.tokenize(source, filename)
  diags:push_all(lex_diags)
  if tokens == nil then return nil, diags end

  local ast_root, parse_diags = parser.parse(tokens, filename)
  diags:push_all(parse_diags)
  if ast_root == nil then return nil, diags end

  resolve_imports(ast_root, filename, diags, {})
  if diags:has_errors() then return nil, diags end

  expand_macros(ast_root, diags, filename)
  if diags:has_errors() then return nil, diags end

  local typed_ast, check_diags = checker.check(ast_root, filename)
  diags:push_all(check_diags)
  if diags:has_errors() then return nil, diags end

  return typed_ast, diags
end

--- Parse and type-check a .sb file (stops before codegen).
---
---@param filepath string
---@return table?, table   typed_ast (with .decls), diags
function M.parse_and_check_file(filepath)
  local diags = ast.new_accum()

  local f, err = io.open(filepath, "r")
  if not f then
    diags:push_error(ast.E.FILE_NOT_FOUND,
      "Cannot open file: " .. tostring(err), ast.pos(filepath, 0, 0))
    return nil, diags
  end
  local source = f:read("*a"); f:close()
  if source == nil then
    diags:push_error(ast.E.FILE_READ_ERROR,
      "Failed to read file contents", ast.pos(filepath, 0, 0))
    return nil, diags
  end
  return M.parse_and_check(source, filepath)
end

--- Compile a .sb file specified by path.
---
---@param filepath string  Absolute or relative path to the .sb file
---@return table?, table
function M.compile_file(filepath, opts)
  local diags = ast.new_accum()

  local f, err = io.open(filepath, "r")
  if not f then
    diags:push_error(
      ast.E.FILE_NOT_FOUND,
      "Cannot open file: " .. tostring(err),
      ast.pos(filepath, 0, 0))
    return nil, diags
  end

  local source = f:read("*a")
  f:close()

  if source == nil then
    diags:push_error(
      ast.E.FILE_READ_ERROR,
      "Failed to read file contents",
      ast.pos(filepath, 0, 0))
    return nil, diags
  end

  return M.compile(source, filepath, opts)
end

return M

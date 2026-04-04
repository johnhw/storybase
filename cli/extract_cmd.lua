-- cli/extract_cmd.lua
-- storybase extract-symbols <file>: scan symbol literals and suggest type declarations.
--
-- Walks the compiled AST looking for 'symbol (SYMBOL_LIT) nodes, groups them
-- by the state path they appear to belong to, and emits candidate type declarations.
--
-- Usage: storybase extract-symbols <file.sb>

local M = {}

local ast      = require("compiler.ast")
local compiler = require("compiler.compiler")

-- ============================================================
-- Symbol collector
-- ============================================================

--- Recursively walk an AST node collecting SYMBOL_LIT values.
--- Groups by context when possible (path of the assignment target).
--- symbols_by_path: { path_str → { symbol_name → true } }
--- all_symbols: { symbol_name → true }
local function collect_symbols(node, symbols_by_path, all_symbols, context_path)
  if not node or type(node) ~= "table" or not node.kind then return end
  local k = ast.K

  if node.kind == k.SYMBOL_LIT then
    all_symbols[node.name] = true
    if context_path then
      if not symbols_by_path[context_path] then
        symbols_by_path[context_path] = {}
      end
      symbols_by_path[context_path][node.name] = true
    end
    return
  end

  -- Track context for mutation targets (set! path 'symbol)
  if node.kind == k.SET_MUT and node.path and node.value then
    local path_str
    if node.path.kind == k.PATH_EXPR then
      path_str = table.concat(node.path.segments or {}, "/")
    elseif node.path.kind == k.INTERP_PATH then
      local segs = {}
      for _, s in ipairs(node.path.segments or {}) do
        segs[#segs+1] = type(s) == "string" and s or "*"
      end
      path_str = table.concat(segs, "/")
    end
    -- Recursively collect from value, passing path as context
    collect_symbols(node.value, symbols_by_path, all_symbols, path_str)
    return
  end

  -- Generic recursion
  local LIST_FIELDS = { "body", "then_body", "else_body", "arms", "choices",
                        "decls", "params" }
  for _, field in ipairs(LIST_FIELDS) do
    local v = node[field]
    if type(v) == "table" then
      for _, child in ipairs(v) do
        collect_symbols(child, symbols_by_path, all_symbols, context_path)
      end
    end
  end
  local NODE_FIELDS = { "condition", "expr", "left", "right",
                        "value", "amount", "iter", "base", "guard" }
  for _, field in ipairs(NODE_FIELDS) do
    collect_symbols(node[field], symbols_by_path, all_symbols, context_path)
  end
  if type(node.args) == "table" then
    for _, a in ipairs(node.args) do
      collect_symbols(a, symbols_by_path, all_symbols, context_path)
    end
  end
end

--- Collect symbols from initial defaults in state declarations.
local function collect_from_defaults(decls, symbols_by_path, all_symbols)
  local k = ast.K
  for _, node in ipairs(decls or {}) do
    if node.kind == k.STATE_SCALAR and node.default then
      local path_str
      if node.path and node.path.kind == k.PATH_EXPR then
        path_str = table.concat(node.path.segments or {}, "/")
      end
      collect_symbols(node.default, symbols_by_path, all_symbols, path_str)
    elseif node.kind == k.STATE_RECORD or node.kind == k.STATE_FAMILY then
      for _, field in ipairs(node.fields or {}) do
        if field.kind == k.RECORD_FIELD and field.default then
          -- context path would be parent/field_name — best effort with field.name
          local ctx = field.name and ("*/" .. field.name)
          collect_symbols(field.default, symbols_by_path, all_symbols, ctx)
        end
      end
    end
  end
end

-- ============================================================
-- Output formatting
-- ============================================================

--- Format a set of symbol names as a sorted pipe-separated list.
local function format_enum_values(sym_set)
  local names = {}
  for name in pairs(sym_set) do names[#names+1] = name end
  table.sort(names)
  return table.concat(names, " | ")
end

--- Convert a path string to a candidate type name (PascalCase).
--- "player/location" → "Location"
--- "guard/disposition" → "Disposition"
--- "*/status" → "Status"
local function path_to_type_name(path_str)
  local last = path_str:match("[^/]+$") or path_str
  -- Title-case: "disposition" → "Disposition"
  return last:sub(1, 1):upper() .. last:sub(2)
end

-- ============================================================
-- Public CLI entry point
-- ============================================================

function M.run(args)
  local filepath = args and args[1]
  if not filepath then
    io.stderr:write("usage: storybase extract-symbols <file.sb>\n")
    return 1
  end

  local typed_ast, diags = compiler.parse_and_check_file(filepath)
  if not typed_ast then
    io.stderr:write("error: could not compile '" .. filepath .. "'\n")
    if diags then
      for _, d in ipairs(diags.errors or {}) do
        io.stderr:write(string.format("  %s:%d [%s] %s\n",
          d.file or filepath, d.line or 0, d.code, d.message))
      end
    end
    return 1
  end

  -- Collect symbols
  local symbols_by_path = {}
  local all_symbols     = {}

  -- Walk all top-level declarations
  collect_from_defaults(typed_ast.decls, symbols_by_path, all_symbols)
  for _, node in ipairs(typed_ast.decls or {}) do
    local k = ast.K
    if node.kind == k.FN_DECL or node.kind == k.SCENE_DECL then
      for _, stmt in ipairs(node.body or {}) do
        collect_symbols(stmt, symbols_by_path, all_symbols, nil)
      end
      for _, choice in ipairs(node.choices or {}) do
        if choice.guard then
          collect_symbols(choice.guard, symbols_by_path, all_symbols, nil)
        end
        for _, stmt in ipairs(choice.body or {}) do
          collect_symbols(stmt, symbols_by_path, all_symbols, nil)
        end
      end
    elseif node.kind == k.ACTOR_DECL then
      -- Walk actor behavior body (stored as fn name; skip for now)
    end
  end

  -- Print header
  io.write("# Symbol literal analysis for: " .. filepath .. "\n")
  io.write("# Generated by: storybase extract-symbols\n\n")

  -- Print per-path grouped symbols (only paths with ≥2 symbols, to avoid noise)
  local typed_paths = {}
  for path_str, sym_set in pairs(symbols_by_path) do
    local count = 0
    for _ in pairs(sym_set) do count = count + 1 end
    if count >= 2 then
      typed_paths[#typed_paths+1] = path_str
    end
  end
  table.sort(typed_paths)

  if #typed_paths > 0 then
    io.write("# Suggested enum types (paths with 2+ distinct symbols):\n\n")
    local emitted_types = {}
    for _, path_str in ipairs(typed_paths) do
      local type_name  = path_to_type_name(path_str)
      local sym_values = format_enum_values(symbols_by_path[path_str])

      -- Avoid duplicate type names
      local name = type_name
      local n = 2
      while emitted_types[name] do
        name = type_name .. tostring(n); n = n + 1
      end
      emitted_types[name] = true

      io.write(string.format("# path: %s\ntype %s = %s\n\n", path_str, name, sym_values))
    end
  else
    io.write("# No paths with 2+ distinct symbol values found.\n\n")
  end

  -- Print all symbols seen (for reference)
  local all_list = {}
  for name in pairs(all_symbols) do all_list[#all_list+1] = name end
  table.sort(all_list)

  if #all_list > 0 then
    io.write("# All symbol literals found (" .. #all_list .. " unique):\n")
    io.write("# type AllSymbols = " .. table.concat(all_list, " | ") .. "\n")
  else
    io.write("# No symbol literals found in " .. filepath .. "\n")
  end

  return 0
end

return M

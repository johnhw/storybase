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
              -- Splice non-metadata declarations before current position
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

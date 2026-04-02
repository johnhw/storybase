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

--- Compile StoryBase source text.
---
--- Returns (game_table, diags):
---   game_table  — compiled Lua table ready for the runtime, or nil on error
---   diags       — ast.new_accum() with .errors, .warnings, .all lists
---
---@param source   string  Source text of the .sb file
---@param filename string  File name used in diagnostic messages
---@return table?, table
function M.compile(source, filename)
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

  -- ── Pass 3: Check (multiple sub-passes inside checker) ───────
  local typed_ast, check_diags = checker.check(ast_root, filename)
  diags:push_all(check_diags)
  if diags:has_errors() then
    return nil, diags
  end

  -- ── Pass 4: Codegen ──────────────────────────────────────────
  local game_table, gen_diags = codegen.emit(typed_ast)
  diags:push_all(gen_diags)
  if diags:has_errors() then
    return nil, diags
  end

  return game_table, diags
end

--- Compile a .sb file specified by path.
---
---@param filepath string  Absolute or relative path to the .sb file
---@return table?, table
function M.compile_file(filepath)
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

  return M.compile(source, filepath)
end

return M

-- compiler/parser.lua
-- Parse a token stream into an untyped AST.
--
-- Phase 1 deliverable (declaration forms only).
-- Phase 2 extends this with expression and statement forms.
--
-- Not yet implemented.

local M = {}

local ast = require("compiler.ast")

--- Parse a token stream produced by the lexer.
---
--- Returns (ast_root, diags):
---   ast_root — root ast.program node, or nil if completely unparseable
---   diags    — list of diagnostic tables
---
---@param tokens   table   Token list from lexer.tokenize
---@param filename string  File name for diagnostics
---@return table?, table
function M.parse(tokens, filename)
  local _ = tokens
  local _ = filename
  -- Return an empty program node; no errors.
  return ast.program({}, ast.pos(filename, 1, 1)), {}
end

return M

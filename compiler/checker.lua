-- compiler/checker.lua
-- Type checker and analyser.  Runs multiple sub-passes over the AST:
--
--   Pass 1 — Schema collection:  gather all type/state/relation/scene names
--   Pass 2 — Basic type-check:   field types, defaults, Int bounds, with-mixin rules
--   Pass 3 — Pure/transaction inference
--   Pass 4 — Write-set analysis
--   Pass 5 — State-space computation
--   Pass 6 — Contract validation (pre:/post: well-formedness)
--
-- Not yet implemented.

local M = {}

--- Check a parsed AST and return a typed AST plus diagnostics.
---
--- Returns (typed_ast, diags):
---   typed_ast — the AST annotated with resolved types (may equal ast_root),
---               or nil if errors prevent further processing
---   diags     — list of diagnostic tables
---
---@param ast_root table   Root ast.program node from the parser
---@param filename string  File name for diagnostics
---@return table?, table
function M.check(ast_root, filename)
  local _ = filename
  -- Not yet implemented: pass the AST through unchanged.
  return ast_root, {}
end

return M

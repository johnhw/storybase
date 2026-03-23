-- compiler/codegen.lua
-- Emit a compiled game table from a typed AST.
--
-- The compiled game table is a serialisable Lua value consumed by the runtime.
-- It contains:
--   schema   — types, state paths with defaults, relations, scenes, actors, schedules
--   fns      — compiled function bodies (as Lua closures or bytecode descriptors)
--   verifies — compiled verify blocks
--   watches  — watch/watch-when declarations (dev mode only)
--
-- Not yet implemented.

local M = {}

--- Emit a compiled game table from a typed AST.
---
--- Returns (game_table, diags):
---   game_table — compiled Lua table, or nil on error
---   diags      — list of diagnostic tables
---
---@param typed_ast table  Typed AST root from the checker
---@return table?, table
function M.emit(typed_ast)
  local _ = typed_ast
  -- Not yet implemented: return a minimal placeholder game table.
  local game_table = {
    schema = {
      type_count       = 0,
      path_count       = 0,
      scene_count      = 0,
      state_space_size = 0,
    },
    fns      = {},
    verifies = {},
    watches  = {},
  }
  return game_table, {}
end

return M

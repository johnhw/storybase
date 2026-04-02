-- runtime/migrate.lua
-- Schema migration chain: apply outstanding migrations to a save log.
--
-- Migrations run in ascending version order on load when the save file's
-- schema version is less than the current schema version.
--
-- Supported migration operations:
--   rename old-path -> new-path
--   add path = value
--   drop path
--   transform path: fn old: expr
--   rename-enum path old -> new
--
-- Phase 6 deliverable. Not yet implemented.

local M = {}

local ast = require("compiler.ast")

--- Apply all outstanding migrations to a log, updating cache entries.
---
---@param log          table    Transaction log instance
---@param state        table    State store instance (cache to update)
---@param migrations   table    List of migration_decl nodes in version order
---@param save_version integer  Schema version of the save file
---@param game_version integer  Current schema version
---@return table                Diagnostic accumulator
function M.migrate(log, state, migrations, save_version, game_version)
  local diags = ast.new_accum()

  if save_version == game_version then
    return diags  -- nothing to do
  end

  if save_version > game_version then
    diags:push_error(
      ast.E.SCHEMA_VERSION_AHEAD,
      string.format(
        "Save file schema version %d is ahead of game version %d",
        save_version, game_version),
      ast.pos("save", 0, 0))
    return diags
  end

  -- Apply migrations in order
  for v = save_version, game_version - 1 do
    local found = false
    for _, m in ipairs(migrations or {}) do
      if m.from_ver == v and m.to_ver == v + 1 then
        found = true
        -- Not yet implemented: apply m.ops to state and log
        local _ = m; local _ = state; local _ = log
      end
    end
    if not found then
      diags:push_error(
        ast.E.MIGRATION_MISSING,
        string.format("No migration block found for version %d -> %d", v, v + 1),
        ast.pos("schema", 0, 0))
      return diags
    end
  end

  return diags
end

return M

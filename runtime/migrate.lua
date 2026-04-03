-- runtime/migrate.lua
-- Schema migration chain: apply outstanding migrations to a save log.
--
-- Migrations run in ascending version order on load when the save file's
-- schema version is less than the current schema version.
--
-- Supported migration operations:
--   rename old-path -> new-path
--   add path = value         (value is a compiled AST expression)
--   drop path
--   transform path: fn old: expr   (expr uses implicit "old" variable)
--   rename-enum path old-sym -> new-sym
--
-- Migration is applied to the in-memory state cache (not the log entries
-- themselves, which are preserved for audit). After migration the cache
-- reflects the new schema.

local M   = {}
local ast = require("compiler.ast")
local eval_mod -- lazy require to avoid circular dependency

-- ============================================================
-- Wildcard path expansion
-- ============================================================

--- Expand a path pattern with a `*` wildcard against the current cache.
--- e.g. "npcs/*/health" → {"npcs/blacksmith/health", "npcs/guard/health"}
---@param pattern string  path with optional `*`
---@param cache   table   current state cache
---@return table  list of concrete paths matching pattern
local function expand_wildcard(pattern, cache)
  local star = pattern:find("%*")
  if not star then
    return { pattern }  -- no wildcard: return as-is
  end
  local prefix = pattern:sub(1, star - 1)  -- e.g. "npcs/"
  local suffix = pattern:sub(star + 1)      -- e.g. "/health"

  -- Find all keys in the family (one level after prefix)
  local seen = {}
  local result = {}
  for path in pairs(cache) do
    if path:sub(1, #prefix) == prefix then
      local rest = path:sub(#prefix + 1)  -- e.g. "blacksmith/health"
      local slash = rest:find("/")
      local key = slash and rest:sub(1, slash - 1) or rest
      if not seen[key] then
        seen[key] = true
        local concrete = prefix .. key .. suffix
        -- Only include if the concrete path actually exists in cache
        if cache[concrete] ~= nil then
          result[#result + 1] = concrete
        end
      end
    end
  end
  return result
end

-- ============================================================
-- Apply one migration operation to the cache
-- ============================================================

local function apply_op(op, cache, game_table)
  if op.op == "rename" then
    -- rename old-path -> new-path
    local old = op.old_path
    local new = op.new_path
    if old and new and cache[old] ~= nil then
      cache[new] = cache[old]
      cache[old] = nil
    end

  elseif op.op == "add" then
    -- add path = value (value is AST expr evaluated with empty ctx)
    if op.path and cache[op.path] == nil and op.value then
      if not eval_mod then eval_mod = require("runtime.eval") end
      local state_mod = require("runtime.state")
      local log_mod   = require("runtime.log")
      local tmp_log   = log_mod.new()
      local tmp_state = state_mod.new(game_table and game_table.schema, tmp_log)
      -- Temporarily set cache to current state for expression evaluation
      for k, v in pairs(cache) do tmp_state._cache[k] = v end
      local ctx = eval_mod.new_ctx(tmp_state, (game_table and game_table.fns) or {}, "migrate")
      local ok, val = pcall(eval_mod.eval_expr, op.value, ctx)
      cache[op.path] = ok and val or nil
    end

  elseif op.op == "drop" then
    -- drop path (also handles wildcards)
    local paths = expand_wildcard(op.path or "", cache)
    for _, p in ipairs(paths) do
      cache[p] = nil
    end

  elseif op.op == "transform" then
    -- transform path: fn old: expr
    -- op.path may contain wildcard; op.expr is the transform expression with "old" bound
    if op.path and op.expr then
      if not eval_mod then eval_mod = require("runtime.eval") end
      local state_mod = require("runtime.state")
      local log_mod   = require("runtime.log")
      local paths = expand_wildcard(op.path, cache)
      for _, p in ipairs(paths) do
        local old_val = cache[p]
        if old_val ~= nil then
          local tmp_log   = log_mod.new()
          local tmp_state = state_mod.new(game_table and game_table.schema, tmp_log)
          for k, v in pairs(cache) do tmp_state._cache[k] = v end
          local ctx = eval_mod.new_ctx(tmp_state, (game_table and game_table.fns) or {}, "migrate")
          ctx.vars["old"] = old_val
          local ok, new_val = pcall(eval_mod.eval_expr, op.expr, ctx)
          if ok then cache[p] = new_val end
        end
      end
    end

  elseif op.op == "rename-enum" then
    -- rename-enum path old-sym -> new-sym
    local paths = expand_wildcard(op.path or "", cache)
    for _, p in ipairs(paths) do
      if cache[p] == op.old_sym then
        cache[p] = op.new_sym
      end
    end
  end
end

-- ============================================================
-- Public API
-- ============================================================

--- Apply all outstanding migrations to the state cache.
---
---@param cache        table    Live state cache (mutated in place)
---@param migrations   table    game_table.migrations (sorted by from_ver)
---@param save_version integer  Schema version of the save file
---@param game_version integer  Current schema version
---@param game_table   table?   Full game_table (for eval context)
---@return table  Diagnostic accumulator
function M.migrate(cache, migrations, save_version, game_version, game_table)
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

  -- Apply migrations in ascending version order
  for v = save_version, game_version - 1 do
    local found = false
    for _, m in ipairs(migrations or {}) do
      if m.from_ver == v and m.to_ver == v + 1 then
        found = true
        for _, op in ipairs(m.ops or {}) do
          apply_op(op, cache, game_table)
        end
        break
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

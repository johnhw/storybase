-- cli/migrate_cmd.lua
-- storybase migrate <game.sb> <save.log> [--out <output.log>]
-- Apply outstanding schema migrations to a save log and write an upgraded copy.

local M = {}

function M.run(args)
  -- Parse args: game file, save file, optional --out
  local game_file = args and args[1]
  local save_file = args and args[2]
  local out_file  = nil
  local i = 3
  while args and args[i] do
    if args[i] == "--out" and args[i+1] then
      out_file = args[i+1]; i = i + 2
    else
      i = i + 1
    end
  end

  if not game_file then
    io.stderr:write("usage: storybase migrate <game.sb> <save.log> [--out <output.log>]\n")
    return 1
  end
  if not save_file then
    io.stderr:write("error: storybase migrate: no save log specified\n")
    return 1
  end
  out_file = out_file or (save_file:gsub("%.log$", ".migrated.log"):gsub("%.save$", ".migrated.save"))

  -- 1. Compile game file
  local compiler = require("compiler.compiler")
  local gt, diags = compiler.compile_file(game_file)
  for _, d in ipairs(diags and diags.errors or {}) do
    io.stderr:write(string.format("%s:%d:%d: error: %s\n",
      d.file or "?", d.line or 0, d.col or 0, d.message))
  end
  if diags:has_errors() or not gt then
    io.stderr:write("Compilation failed.\n")
    return 1
  end

  local game_version = gt.schema and gt.schema.version or 1
  local migrations   = gt.migrations or {}

  if #migrations == 0 then
    io.stdout:write("No migration blocks found in " .. game_file .. ". Nothing to do.\n")
    return 0
  end

  -- 2. Load save file
  local f, ferr = io.open(save_file, "r")
  if not f then
    io.stderr:write("error: cannot open save file " .. save_file .. ": " .. tostring(ferr) .. "\n")
    return 1
  end
  local src = f:read("*a"); f:close()
  local fn, perr = load(src)
  if not fn then
    io.stderr:write("error: save file parse error: " .. tostring(perr) .. "\n")
    return 1
  end
  local ok, save_data = pcall(fn)
  if not ok or type(save_data) ~= "table" then
    io.stderr:write("error: save file exec error: " .. tostring(save_data) .. "\n")
    return 1
  end

  local save_version = save_data.schema_version or 1
  local entries      = save_data.entries or {}

  if save_version == game_version then
    io.stdout:write(string.format(
      "Save is already at version %d. No migration needed.\n", save_version))
    return 0
  end

  -- 3. Replay log to build current cache
  local state_mod = require("runtime.state")
  local log_mod   = require("runtime.log")
  local tmp_log   = log_mod.new()
  local store     = state_mod.new(gt.schema, tmp_log)
  store:init_defaults()
  state_mod.replay(store, entries)

  -- 4. Apply migrations to the cache
  local migrate_mod = require("runtime.migrate")
  local mdiags = migrate_mod.migrate(
    store._cache, migrations, save_version, game_version, gt)
  for _, d in ipairs(mdiags.errors or {}) do
    io.stderr:write(string.format("migration error: %s\n", d.message))
    has_errors = true
  end
  if has_errors then
    io.stderr:write("Migration failed.\n")
    return 1
  end

  -- 5. Write new save file: serialize migrated cache as a fresh log
  --    Produce a compact save with one entry per live path
  local new_entries = {}
  local seq = 0
  for path, val in pairs(store._cache) do
    seq = seq + 1
    new_entries[#new_entries + 1] = {
      seq      = seq,
      fn       = "migrate",
      path     = path,
      old      = nil,
      ["new"]  = val,
    }
  end

  local outf, oerr = io.open(out_file, "w")
  if not outf then
    io.stderr:write("error: cannot write output file " .. out_file .. ": " .. tostring(oerr) .. "\n")
    return 1
  end
  outf:write("-- StoryBase save file (migrated from v" .. save_version .. " to v" .. game_version .. ")\n")
  outf:write("local save = {}\n")
  outf:write("save.version = 1\n")
  outf:write("save.schema_version = " .. tostring(game_version) .. "\n")
  outf:write("save.scene_stack = {")
  local stack_parts = {}
  for _, s in ipairs(save_data.scene_stack or {}) do
    stack_parts[#stack_parts + 1] = string.format("%q", s)
  end
  outf:write(table.concat(stack_parts, ", ") .. "}\n")
  outf:write("save.entries =\n")
  outf:write(log_mod.serialise_entries(new_entries))
  outf:write("\n")
  outf:write("return save\n")
  outf:close()

  io.stdout:write(string.format(
    "Migrated %s (v%d → v%d) → %s\n",
    save_file, save_version, game_version, out_file))
  return 0
end

return M

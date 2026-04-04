-- cli/compact_cmd.lua
-- storybase compact <game.sb> <save.log> [--out <compacted.log>]
--
-- Reads a save log, replays it to obtain the current state snapshot,
-- and writes a new compact save log.  The compact log contains a single
-- synthetic SET entry per path (the final value) so subsequent loads
-- replay in O(paths) instead of O(log-entries).
--
-- Usage:
--   storybase compact game.sb save.log
--   storybase compact game.sb save.log --out save.compact.log

local M = {}

local compiler = require("compiler.compiler")
local log_mod  = require("runtime.log")
local state_mod = require("runtime.state")

-- ============================================================
-- Helpers
-- ============================================================

local function read_save(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local src = f:read("*a"); f:close()
  local fn, perr = load(src)
  if not fn then return nil, "parse error: " .. tostring(perr) end
  local data = fn()
  if not data then return nil, "save file returned nil" end
  return data
end

local function write_compact(path, entries, scene_stack)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write("-- StoryBase compact save file (v1)\n")
  f:write("local save = {}\n")
  f:write("save.version = 1\n")
  f:write("save.compact = true\n")
  -- Scene stack
  f:write("save.scene_stack = {")
  local parts = {}
  for _, s in ipairs(scene_stack or {}) do
    parts[#parts+1] = string.format("%q", s)
  end
  f:write(table.concat(parts, ", ") .. "}\n")
  -- Entries (one per path)
  f:write("save.entries =\n")
  f:write(log_mod.serialise_entries(entries))
  f:write("\n")
  f:write("return save\n")
  f:close()
  return true
end

-- ============================================================
-- Public CLI entry point
-- ============================================================

function M.run(args)
  -- Parse args: accept positional + --out flag
  local flags      = {}
  local positional = {}
  local i = 1
  while i <= #(args or {}) do
    local a = args[i]
    if a:sub(1,2) == "--" then
      local key = a:sub(3)
      if args[i+1] and args[i+1]:sub(1,2) ~= "--" then
        flags[key] = args[i+1]; i = i + 2
      else
        flags[key] = true; i = i + 1
      end
    else
      positional[#positional+1] = a; i = i + 1
    end
  end

  local sb_path   = positional[1]
  local save_path = positional[2]

  if not sb_path or not save_path then
    io.stderr:write("usage: storybase compact <game.sb> <save.log> [--out <out.log>]\n")
    return 1
  end

  local out_path = flags["out"] or (save_path:gsub("%.log$", "") .. ".compact.log")

  -- Compile game to get schema
  local game_table, diags = compiler.compile_file(sb_path)
  if not game_table or diags:has_errors() then
    io.stderr:write("error: could not compile '" .. sb_path .. "'\n")
    for _, d in ipairs(diags and diags.errors or {}) do
      io.stderr:write(string.format("  %s:%d [%s] %s\n",
        d.file or sb_path, d.line or 0, d.code, d.message))
    end
    return 1
  end

  -- Read save log
  local save_data, serr = read_save(save_path)
  if not save_data then
    io.stderr:write("error: could not read save log '" .. save_path .. "': " .. tostring(serr) .. "\n")
    return 1
  end

  -- Replay into fresh state to get final cache
  local lg    = log_mod.new()
  local state = state_mod.new(game_table.schema or {}, lg)
  state:init_defaults()
  state_mod.replay(state, save_data.entries or {})

  -- Build compact entries: one synthetic SET entry per path in the cache
  local compact_entries = {}
  local seq = 1
  for path, value in pairs(state._cache) do
    compact_entries[#compact_entries+1] = {
      seq   = seq,
      op    = "set",
      fn    = "compact",
      path  = path,
      old   = nil,
      new   = value,
    }
    seq = seq + 1
  end
  -- Sort for determinism
  table.sort(compact_entries, function(a, b) return a.path < b.path end)
  for idx, e in ipairs(compact_entries) do e.seq = idx end

  -- Write compact save
  local ok, werr = write_compact(out_path, compact_entries, save_data.scene_stack)
  if not ok then
    io.stderr:write("error: could not write output '" .. out_path .. "': " .. tostring(werr) .. "\n")
    return 1
  end

  io.write(string.format(
    "Compacted %d log entries → %d snapshot entries\nOutput: %s\n",
    #(save_data.entries or {}), #compact_entries, out_path))

  return 0
end

return M

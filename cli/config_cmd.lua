-- cli/config_cmd.lua
-- Implements `storybase config <subcommand>`:
--   dump            list every declared key with its resolved value + winning layer
--   get  <key>      print just the resolved value for one key (machine-friendly)
--   doc  <key>      print the human-readable spec for one key
--
-- All three commands assume the env/file layers have already been populated
-- by `cli/main.lua` via `config.load_startup()`.  CLI overrides supplied as
-- `--config key=value` on the same invocation are also honoured because they
-- get applied to the cli layer before the dispatch table calls this handler.
--
-- An optional positional `<file.sb>` argument compiles the file and calls
-- `config.bind_game`, so `storybase config dump game.sb` shows the values
-- you would get when running that game.

local M = {}

local config = require("runtime.config")

local function emit_err(msg) io.stderr:write("storybase config: " .. msg .. "\n") end

local function parse_args(args)
  local positional = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      -- Skip flags here — main.lua's pre-dispatch loop already handled them.
      -- We still tolerate them silently so users can mix flag order.
      if a == "--config" and args[i + 1] then
        i = i + 2
      else
        i = i + 1
      end
    else
      positional[#positional + 1] = a
      i = i + 1
    end
  end
  return positional
end

--- Compile the file (if given) and bind the game layer so the output reflects
--- the actual layered resolution for that .sb file. Errors are surfaced as a
--- non-zero exit but with the env/file layers still in effect.
local function maybe_bind_game(filepath)
  if not filepath then return true end
  local ok_c, compiler = pcall(require, "compiler.compiler")
  if not ok_c then
    emit_err("could not load compiler: " .. tostring(compiler))
    return false
  end
  local game_table, diags = compiler.compile_file(filepath, { production = false })
  if diags and diags:has_errors() then
    emit_err("could not compile " .. filepath .. " for game layer")
    return false
  end
  config.bind_game(game_table)
  return true
end

local function cmd_dump(filepath)
  if not maybe_bind_game(filepath) then return 1 end
  local rows = config.dump()
  local keys = config.keys()
  -- column widths
  local kw = 4   -- "key"
  local lw = 5   -- "layer"
  for _, k in ipairs(keys) do
    if #k > kw then kw = #k end
    local layer = rows[k].layer
    if #layer > lw then lw = #layer end
  end
  io.stdout:write(string.format("%-" .. kw .. "s  %-" .. lw .. "s  %s\n",
    "key", "layer", "value"))
  io.stdout:write(string.format("%s  %s  %s\n",
    string.rep("-", kw), string.rep("-", lw), string.rep("-", 5)))
  for _, k in ipairs(keys) do
    local row = rows[k]
    local v
    if row.value == nil then v = "<unset>"
    else v = tostring(row.value) end
    io.stdout:write(string.format("%-" .. kw .. "s  %-" .. lw .. "s  %s\n",
      k, row.layer, v))
  end
  return 0
end

local function cmd_get(key, filepath)
  if not key or key == "" then
    emit_err("config get: missing <key>")
    return 1
  end
  if not config.spec(key) then
    emit_err("config get: unknown key '" .. key .. "'")
    return 1
  end
  if not maybe_bind_game(filepath) then return 1 end
  local v = config.get(key)
  if v == nil then
    io.stdout:write("\n")
  else
    io.stdout:write(tostring(v) .. "\n")
  end
  return 0
end

local function cmd_doc(key)
  if not key or key == "" then
    emit_err("config doc: missing <key>")
    return 1
  end
  local spec = config.spec(key)
  if not spec then
    emit_err("config doc: unknown key '" .. key .. "'")
    return 1
  end
  io.stdout:write(key .. "\n")
  io.stdout:write("  type:     " .. tostring(spec.type) .. "\n")
  if spec.default ~= nil then
    io.stdout:write("  default:  " .. tostring(spec.default) .. "\n")
  end
  if spec.enum then
    io.stdout:write("  enum:     " .. table.concat(spec.enum, ", ") .. "\n")
  end
  if spec.env then
    io.stdout:write("  env:      " .. spec.env .. "\n")
  else
    local auto = "STORYBASE_" .. key:upper():gsub("[%.%-]", "_")
    io.stdout:write("  env:      " .. auto .. " (auto)\n")
  end
  if spec.cli then
    io.stdout:write("  cli:      " .. spec.cli .. "\n")
  end
  if spec.doc and spec.doc ~= "" then
    io.stdout:write("  doc:      " .. spec.doc .. "\n")
  end
  local v, layer = config.get(key)
  io.stdout:write("  current:  " .. tostring(v) .. " (from " .. layer .. ")\n")
  return 0
end

function M.run(args)
  local pos = parse_args(args or {})
  local sub = pos[1]
  if not sub or sub == "help" or sub == "--help" then
    io.stdout:write([[
Usage:
  storybase config dump [file.sb]      Show every key with its resolved value
  storybase config get <key> [file.sb] Print just the value for one key
  storybase config doc <key>           Show the spec/help for one key

`--config key=value` flags supplied alongside any of these subcommands are
also applied (highest precedence other than --runtime overrides).
]])
    return 0
  end
  if sub == "dump" then
    return cmd_dump(pos[2])
  end
  if sub == "get" then
    return cmd_get(pos[2], pos[3])
  end
  if sub == "doc" then
    return cmd_doc(pos[2])
  end
  emit_err("unknown subcommand: " .. sub)
  return 1
end

return M

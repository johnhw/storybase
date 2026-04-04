-- cli/main.lua
-- Entry point for the storybase CLI tool.
--
-- Usage:
--   lua cli/main.lua <command> [options] [file]
--
-- Commands:
--   compile <file>             Compile a .sb file; report errors and warnings
--   run     <file>             Compile and run a game interactively
--   verify  <file>             Run all verify blocks in a .sb file
--   migrate <save.log>         Apply outstanding schema migrations to a save log
--   extract-symbols <file>     Scan symbol literals; suggest type declarations
--   compact <save.log>         Emit snapshot + delta log for faster replay
--   help                       Show this help text

local M = {}

-- ── Package path setup ────────────────────────────────────────
-- Allow running as:  lua cli/main.lua  from the project root.
-- The script's directory is determined by arg[0] when available.
local function setup_path()
  local script = (arg and arg[0]) or ""
  -- Resolve to the project root (one level above cli/)
  local root = script:match("^(.*[/\\])cli[/\\]main%.lua$")
  if root and root ~= "" then
    -- Normalise separators and strip trailing slash
    root = root:gsub("\\", "/"):gsub("/$", "")
    package.path = root .. "/?.lua;" .. package.path
  end
end

setup_path()

-- ── Helpers ───────────────────────────────────────────────────

local function print_usage()
  io.stderr:write([[
Usage: storybase <command> [options] <file>

Commands:
  compile <file>              Compile a .sb file; report errors and warnings
  run     <file>              Compile and run a game interactively
  verify  <file>              Run all verify blocks in a .sb file
  migrate <save.log>          Apply outstanding schema migrations to a save log
  extract-symbols <file>      Scan symbol literals; suggest type declarations
  compact <save.log>          Emit snapshot + delta log for faster replay
  help                        Show this help text

Options (compile / run):
  --production                Emit a production build (strips debug-only content)
  --seed N                    Fix random seed for reproducible runs

Options (run):
  --save <path>               Save game log to <path> on exit
  --load <path>               Load game log from <path> before starting

]])
end

--- Format and print all diagnostics in a list to stderr.
local function print_diags(diags)
  for _, d in ipairs(diags.all or {}) do
    local loc = string.format("%s:%d:%d", d.file or "?", d.line or 0, d.col or 0)
    local label = (d.level == "error") and "error" or "warning"
    io.stderr:write(string.format("%s: %s [%s]: %s\n", loc, label, d.code, d.message))
    if d.note and d.note ~= "" then
      io.stderr:write(string.format("  note: %s\n", d.note))
    end
  end
end

--- Return a human-readable summary string for a diagnostic accumulator.
local function diag_summary(diags)
  local ne = #(diags.errors or {})
  local nw = #(diags.warnings or {})
  local parts = {}
  if ne > 0 then parts[#parts + 1] = ne .. " error" .. (ne > 1 and "s" or "") end
  if nw > 0 then parts[#parts + 1] = nw .. " warning" .. (nw > 1 and "s" or "") end
  return table.concat(parts, ", ")
end

--- Parse a flat argument list into {flags, positional}.
--- Flags are --name or --name value pairs; positional are the rest.
local function parse_args(args)
  local flags = {}
  local positional = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      local key = a:sub(3)
      -- Peek at next arg: if it doesn't start with "--", treat as value
      if args[i + 1] and args[i + 1]:sub(1, 2) ~= "--" then
        flags[key] = args[i + 1]
        i = i + 2
      else
        flags[key] = true
        i = i + 1
      end
    else
      positional[#positional + 1] = a
      i = i + 1
    end
  end
  return flags, positional
end

-- ── Command: compile ──────────────────────────────────────────

local function cmd_compile(args)
  local flags, pos_args = parse_args(args)
  local filepath = pos_args[1]
  if not filepath then
    io.stderr:write("error: storybase compile: no input file\n")
    return 1
  end

  local ok, compiler = pcall(require, "compiler.compiler")
  if not ok then
    io.stderr:write("error: could not load compiler: " .. tostring(compiler) .. "\n")
    return 1
  end

  local game_table, diags = compiler.compile_file(filepath)
  print_diags(diags)

  if diags:has_errors() then
    local s = diag_summary(diags)
    io.stderr:write(string.format("Compilation failed: %s\n", s))
    return 1
  end

  local s = diag_summary(diags)
  local msg = "Compilation succeeded"
  if s ~= "" then msg = msg .. " (" .. s .. ")" end
  io.stdout:write(msg .. "\n")

  -- Print basic schema stats when available
  if game_table and game_table.schema then
    local sc = game_table.schema
    io.stdout:write(string.format(
      "  Types: %d  State paths: %d  Scenes: %d\n",
      sc.type_count or 0, sc.path_count or 0, sc.scene_count or 0))
    if sc.state_space_size then
      io.stdout:write(string.format("  State-space size: %s\n",
        tostring(sc.state_space_size)))
    end
  end

  return 0
end

-- ── Command: run ─────────────────────────────────────────────

local function cmd_run(args)
  local flags, pos_args = parse_args(args)
  local filepath = pos_args[1]
  if not filepath then
    io.stderr:write("error: storybase run: no input file\n")
    return 1
  end

  local ok_c, compiler = pcall(require, "compiler.compiler")
  if not ok_c then
    io.stderr:write("error: could not load compiler: " .. tostring(compiler) .. "\n")
    return 1
  end

  local game_table, diags = compiler.compile_file(filepath)
  print_diags(diags)
  if diags:has_errors() then
    io.stderr:write("Compilation failed; cannot run.\n")
    return 1
  end

  local ok_e, engine = pcall(require, "runtime.engine")
  if not ok_e then
    io.stderr:write("error: could not load runtime engine: " .. tostring(engine) .. "\n")
    return 1
  end

  local opts = {
    seed       = flags["seed"] and tonumber(flags["seed"]),
    production = flags["production"] == true,
    save_path  = flags["save"],
    load_path  = flags["load"],
  }

  return engine.run(game_table, opts) or 0
end

-- ── Command: verify ───────────────────────────────────────────

local function cmd_verify(args)
  local ok, verify_cmd = pcall(require, "cli.verify_cmd")
  if not ok then
    io.stderr:write("error: could not load verify command: " .. tostring(verify_cmd) .. "\n")
    return 1
  end
  return verify_cmd.run(args) or 0
end

-- ── Command: migrate ──────────────────────────────────────────

local function cmd_migrate(args)
  local ok, migrate_cmd = pcall(require, "cli.migrate_cmd")
  if not ok then
    io.stderr:write("error: could not load migrate command: " .. tostring(migrate_cmd) .. "\n")
    return 1
  end
  return migrate_cmd.run(args) or 0
end

-- ── Command: extract-symbols ──────────────────────────────────

local function cmd_extract_symbols(args)
  local ok, extract_cmd = pcall(require, "cli.extract_cmd")
  if not ok then
    io.stderr:write(
      "error: could not load extract-symbols command: " .. tostring(extract_cmd) .. "\n")
    return 1
  end
  return extract_cmd.run(args) or 0
end

-- ── Command: compact ──────────────────────────────────────────

local function cmd_compact(args)
  local ok, compact_cmd = pcall(require, "cli.compact_cmd")
  if not ok then
    io.stderr:write("error: could not load compact command: " .. tostring(compact_cmd) .. "\n")
    return 1
  end
  return compact_cmd.run(args) or 0
end

-- ── Dispatch table ────────────────────────────────────────────

local COMMANDS = {
  ["compile"]         = cmd_compile,
  ["run"]             = cmd_run,
  ["verify"]          = cmd_verify,
  ["migrate"]         = cmd_migrate,
  ["extract-symbols"] = cmd_extract_symbols,
  ["compact"]         = cmd_compact,
  ["help"]            = function(_) print_usage(); return 0 end,
}

-- ── Main entry point ──────────────────────────────────────────

--- Run the CLI with the given argument vector.
---@param argv table  Argument list (e.g. the global `arg` table)
---@return integer    Exit code (0 = success)
function M.main(argv)
  if not argv or #argv == 0 then
    print_usage()
    return 1
  end

  local cmd     = argv[1]
  local handler = COMMANDS[cmd]

  if not handler then
    io.stderr:write(string.format("storybase: unknown command '%s'\n", cmd))
    print_usage()
    return 1
  end

  -- Shift args (remove command name, pass the rest)
  local sub_args = {}
  for i = 2, #argv do sub_args[i - 1] = argv[i] end

  local ok, result = pcall(handler, sub_args)
  if not ok then
    io.stderr:write(string.format("storybase: internal error in '%s': %s\n", cmd, tostring(result)))
    return 1
  end

  return result or 0
end

-- Run when invoked directly as:  lua cli/main.lua <args>
if arg then
  os.exit(M.main(arg))
end

return M

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
--   test    <file>             Run all test blocks in a .sb file
--   coverage <file>            BFS coverage report: scenes and fns reached
--   fuzz    <file>             Random-walk the choice tree; check verify-always invariants
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
  check    <file>             Check a .sb file (lexer+parser+checker; no codegen)
  compile  <file>             Compile a .sb file; report errors and warnings
  run      <file>             Compile and run a game interactively
  format   <file>             Pretty-print a .sb file in canonical style
  repl     <file>             Load and explore a .sb file interactively
  verify   <file>             Run all verify blocks in a .sb file
  test     <file>             Run all test blocks in a .sb file
  coverage <file>             BFS coverage report: scenes and fns reached
  fuzz     <file>             Random-walk choice tree; check verify-always invariants
  migrate  <save.log>         Apply outstanding schema migrations to a save log
  extract-symbols <file>      Scan symbol literals; suggest type declarations
  compact  <game.sb> <save.log> Emit snapshot + delta log for faster replay
  bundle   <file>             Bundle a game into a single self-contained .lua file
  docs     <file>             Generate static HTML/Markdown reference for a game
  serve-api <file>            Stateless HTTP API (client-held save log)
  lsp                         Start the LSP server (stdio JSON-RPC)
  help                        Show this help text

Options (compile / run):
  --production                Emit a production build (strips debug-only content)
  --seed N                    Fix random seed for reproducible runs

Options (run):
  --save <path>               Save game log to <path> on exit
  --load <path>               Load game log from <path> before starting
  --quiet                     Suppress compiler warnings (errors still shown)
  --debug                     Start TCP debug server + browser UI (ports 7373/7374)
  --serve                     Like --debug, but browser drives the game (no stdin)
  --http-port N               Override the HTTP UI port (default: debug-port + 1)
  --bind <addr>               Bind debug/serve sockets to <addr> (default: 127.0.0.1)
  --ui <name>                 UI driver: plain (default) or ansi (ANSI colour)
  --cli <save.sbd>            Single-step scripting mode: read one choice from stdin,
                              output JSON to stdout, save full state, then exit
  --reset                     (--cli only) Wipe save file and start fresh

]])
end

--- Split source text into a 1-based array of line strings.
---@param source string
---@return string[]
local function split_lines(source)
  local lines = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

--- Format and print all diagnostics in a list to stderr.
--- Optional source_map: {[filepath] = source_string} — used to print the
--- offending source line with a caret (^) pointer beneath it.
---@param diags      table   diagnostic accumulator
---@param source_map table?  {[file] = source_string}
local function print_diags(diags, source_map)
  -- Pre-split source lines on demand (lazy cache)
  local line_cache = {}  -- {[file] = string[]}
  local function get_lines(file)
    if not source_map or not file then return nil end
    if not line_cache[file] then
      local src = source_map[file]
      if src then line_cache[file] = split_lines(src) end
    end
    return line_cache[file]
  end

  for _, d in ipairs(diags.all or {}) do
    local loc   = string.format("%s:%d:%d", d.file or "?", d.line or 0, d.col or 0)
    local label = (d.level == "error") and "error"
                  or (d.level == "hint") and "hint"
                  or "warning"
    io.stderr:write(string.format("%s: %s [%s]: %s\n", loc, label, d.code, d.message))

    -- Print source context if we have the source and a valid line number
    if d.line and d.line > 0 then
      local lines = get_lines(d.file)
      if lines then
        local srcline = lines[d.line]
        if srcline then
          io.stderr:write(string.format("  %s\n", srcline))
          local col = math.max(1, d.col or 1)
          io.stderr:write(string.format("  %s^\n", string.rep(" ", col - 1)))
        end
      end
    end

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

-- Flags that are boolean (do not consume the next token as a value).
local BOOL_FLAGS = { production = true, auto = true, debug = true, serve = true, reset = true, quiet = true }

--- Parse a flat argument list into {flags, positional}.
--- Flags are --name or --name value pairs; positional are the rest.
--- Known boolean flags (e.g. --production) never consume the following token.
local function parse_args(args)
  local flags = {}
  local positional = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      local key = a:sub(3)
      if BOOL_FLAGS[key] then
        -- Boolean flag: no value token
        flags[key] = true
        i = i + 1
      elseif args[i + 1] and args[i + 1]:sub(1, 2) ~= "--" then
        -- Value flag: next token is the value
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

  -- Read source for context lines in error messages
  local source_map = {}
  local sf = io.open(filepath, "r")
  if sf then source_map[filepath] = sf:read("*a"); sf:close() end

  local compile_opts = { production = (flags["production"] == true) }
  local game_table, diags = compiler.compile_file(filepath, compile_opts)
  print_diags(diags, source_map)

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

  -- Read source for context lines in error messages
  local run_source_map = {}
  local rsf = io.open(filepath, "r")
  if rsf then run_source_map[filepath] = rsf:read("*a"); rsf:close() end

  local compile_opts = { production = (flags["production"] == true) }
  local game_table, diags = compiler.compile_file(filepath, compile_opts)
  if flags["quiet"] then
    -- Suppress warnings; errors still printed unconditionally
    local errors_only = { all = diags.errors or {}, errors = diags.errors or {}, warnings = {} }
    print_diags(errors_only, run_source_map)
  else
    print_diags(diags, run_source_map)
  end
  if diags:has_errors() then
    io.stderr:write("Compilation failed; cannot run.\n")
    return 1
  end

  local ok_e, engine = pcall(require, "runtime.engine")
  if not ok_e then
    io.stderr:write("error: could not load runtime engine: " .. tostring(engine) .. "\n")
    return 1
  end

  -- --auto [--steps N]: play automatically (always pick choice 1).
  -- --steps N: limit auto play to N turns (implies --auto).
  local auto_steps = flags["steps"] and tonumber(flags["steps"])
  local is_auto = flags["auto"] == true or auto_steps ~= nil

  local io_in = io.stdin
  if is_auto then
    local remaining = auto_steps  -- nil means unlimited
    io_in = {
      read = function(_, _fmt)
        if remaining ~= nil then
          if remaining <= 0 then return nil end
          remaining = remaining - 1
        end
        return "1"
      end,
    }
  end

  -- --debug / --serve: start debug TCP server
  -- --serve also starts HTTP UI and switches to browser-driven game loop
  local is_serve = flags["serve"] == true
  local debug_port = nil
  if flags["debug"] or is_serve then
    -- Prefer port from engine-config, fall back to default 7373
    local ec = game_table and game_table.schema and game_table.schema.engine_config
    debug_port = (ec and tonumber(ec["debug-port"])) or 7373
  end

  -- HTTP UI port (debug_port + 1 by default, or explicit --http-port N)
  local http_port = nil
  if flags["debug"] or is_serve then
    http_port = tonumber(flags["http-port"]) or (debug_port + 1)
  end

  -- --cli <path>: single-step scripting mode (read one choice, write JSON, exit)
  local cli_path = flags["cli"]
  if cli_path then
    local ok_cli, cli_cmd = pcall(require, "cli.cli_cmd")
    if not ok_cli then
      io.stderr:write("error: could not load cli command: " .. tostring(cli_cmd) .. "\n")
      return 1
    end
    local cli_opts = {
      seed  = flags["seed"] and tonumber(flags["seed"]),
      reset = flags["reset"] == true,
    }
    return cli_cmd.run(game_table, cli_path, cli_opts) or 0
  end

  -- --ui <name>: select UI driver (default: plain)
  -- Whitelist driver names to prevent arbitrary module loading via package.path
  -- traversal (e.g. `--ui ../../foo`). Extend this set as new drivers land.
  local ALLOWED_UI_DRIVERS = { plain = true, ansi = true }
  local ui_name = flags["ui"] or "plain"
  if not ALLOWED_UI_DRIVERS[ui_name] then
    io.stderr:write("error: unknown UI driver '" .. tostring(ui_name)
                    .. "' (available: plain, ansi)\n")
    return 1
  end
  local ok_drv, drv_mod = pcall(require, "cli.drivers." .. ui_name)
  if not ok_drv then
    io.stderr:write("error: failed to load UI driver '" .. ui_name
                    .. "': " .. tostring(drv_mod) .. "\n")
    return 1
  end
  local driver = drv_mod.new({ io_out = io.stdout, io_in = io_in })

  local opts = {
    seed        = flags["seed"] and tonumber(flags["seed"]),
    production  = flags["production"] == true,
    save_path   = flags["save"],
    load_path   = flags["load"],
    io_in       = io_in,
    debug_port  = debug_port,
    http_port   = http_port,
    serve       = is_serve,
    bind        = flags["bind"],
    driver      = driver,
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

-- ── Command: test ─────────────────────────────────────────────

local function cmd_test(args)
  local ok, test_cmd = pcall(require, "cli.test_cmd")
  if not ok then
    io.stderr:write("error: could not load test command: " .. tostring(test_cmd) .. "\n")
    return 1
  end
  return test_cmd.run(args) or 0
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

-- ── Command: check ───────────────────────────────────────────

local function cmd_check(args)
  local ok, check_cmd = pcall(require, "cli.check_cmd")
  if not ok then
    io.stderr:write("error: could not load check command: " .. tostring(check_cmd) .. "\n")
    return 1
  end
  return check_cmd.run(args) or 0
end

-- ── Command: format ───────────────────────────────────────────

local function cmd_format(args)
  local ok, format_cmd = pcall(require, "cli.format_cmd")
  if not ok then
    io.stderr:write("error: could not load format command: " .. tostring(format_cmd) .. "\n")
    return 1
  end
  return format_cmd.run(args) or 0
end

-- ── Command: repl ─────────────────────────────────────────────

local function cmd_repl(args)
  local ok, repl_cmd = pcall(require, "cli.repl_cmd")
  if not ok then
    io.stderr:write("error: could not load repl command: " .. tostring(repl_cmd) .. "\n")
    return 1
  end
  return repl_cmd.run(args) or 0
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

-- ── Command: bundle ──────────────────────────────────────────

local function cmd_bundle(args)
  local ok, bundle_cmd = pcall(require, "cli.bundle_cmd")
  if not ok then
    io.stderr:write("error: could not load bundle command: " .. tostring(bundle_cmd) .. "\n")
    return 1
  end
  return bundle_cmd.run(args) or 0
end

-- ── Command: fuzz ─────────────────────────────────────────────

local function cmd_fuzz(args)
  local ok, fuzz_cmd = pcall(require, "cli.fuzz_cmd")
  if not ok then
    io.stderr:write("error: could not load fuzz command: " .. tostring(fuzz_cmd) .. "\n")
    return 1
  end
  return fuzz_cmd.run(args) or 0
end

-- ── Command: coverage ─────────────────────────────────────────

local function cmd_coverage(args)
  local ok, coverage_cmd = pcall(require, "cli.coverage_cmd")
  if not ok then
    io.stderr:write("error: could not load coverage command: " .. tostring(coverage_cmd) .. "\n")
    return 1
  end
  return coverage_cmd.run(args) or 0
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

-- ── Command: docs ────────────────────────────────────────────

local function cmd_docs(args)
  local ok, docs_cmd = pcall(require, "cli.docs_cmd")
  if not ok then
    io.stderr:write("error: could not load docs command: " .. tostring(docs_cmd) .. "\n")
    return 1
  end
  return docs_cmd.run(args) or 0
end

-- ── Command: serve-api ───────────────────────────────────────

local function cmd_serve_api(args)
  local ok, serve_api_cmd = pcall(require, "cli.serve_api_cmd")
  if not ok then
    io.stderr:write("error: could not load serve-api command: " .. tostring(serve_api_cmd) .. "\n")
    return 1
  end
  return serve_api_cmd.run(args) or 0
end

-- ── Command: lsp ─────────────────────────────────────────────

local function cmd_lsp(_args)
  local ok, lsp = pcall(require, "cli.lsp")
  if not ok then
    io.stderr:write("error: could not load lsp: " .. tostring(lsp) .. "\n")
    return 1
  end
  lsp.run()
  return 0
end

-- ── Dispatch table ────────────────────────────────────────────

local COMMAND_HELP = {
  ["compile"] = [[
storybase compile [--production] <file>

  Compile a .sb file and report any errors or warnings.
  Exits 0 on success, 1 if compilation fails.

  Options:
    --production   Strip debug-only content (watches, verify blocks)
                   from the compiled game table.
]],
  ["run"] = [[
storybase run [options] <file>

  Compile and run a game interactively in the terminal.

  Options:
    --production   Strip debug-only content before running
    --seed N       Fix the random seed for reproducible runs
    --save <path>  Save the game log to <path> on exit
    --load <path>  Load a saved game log from <path> before starting
    --quiet        Suppress compiler warnings (errors still shown)
    --auto         Auto-play: always select choice 1 until game ends
    --steps N      Auto-play for at most N turns (implies --auto)
    --ui <name>    UI driver: plain (default) or ansi (ANSI colour)
]],
  ["verify"] = [[
storybase verify <file> [--no-cache] [--clear-cache] [--cache-dir DIR]

  Run all verify blocks defined in a .sb file.
  Each block performs a BFS over reachable states and checks invariants.
  Exits 0 if all checks pass, 1 if any fail.

  Supported clause kinds:
    verify-always              expr  — invariant at every reachable state
    verify-eventually          expr  — expr reachable on some path (EF)
    verify-always-eventually   expr  — expr eventually holds on every path (AF)
    verify-until      p until  q     — every path: p holds until q (AU)
    after (fn args): assertions      — post-condition with path@before
    requires expr                    — pre-condition guard for `after`
    from-any-state:                  — reachability sub-clauses

  Results are cached in .storybase-cache/verify.json keyed by an AST-level
  hash of each block plus the fns it transitively reaches. Re-running with
  unchanged inputs reuses cached verdicts (marked [cached]). Flags:
    --no-cache       skip cache lookup; always re-run every block
    --clear-cache    delete the cache file before running
    --cache-dir DIR  use DIR instead of .storybase-cache
]],
  ["migrate"] = [[
storybase migrate <save.log>

  Apply outstanding schema migrations to a save log.
  Reads the save log, applies any migration functions defined in the
  compiled game, and writes the updated log back to the same path.
]],
  ["extract-symbols"] = [[
storybase extract-symbols <file>

  Scan a .sb file for bare symbol literals and group them by the state
  paths they are written to.  Suggests `type` enum declarations for
  paths that have consistent sets of symbol values.
]],
  ["check"] = [[
storybase check <file>

  Run lexer → parser → checker on a .sb file and report errors/warnings.
  Stops before code generation; faster feedback than `compile`.
  Exits 0 if no errors (warnings are allowed), 1 if any error is found.
]],
  ["format"] = [[
storybase format [--check] <file>

  Pretty-print a .sb file in canonical style (2-space indentation).
  Without --check, writes the formatted source to stdout.
  With --check, exits 0 if the file is already canonical, 1 if not.

  Options:
    --check    Verify the file matches canonical format without printing
    --write    Rewrite the file in-place (creates a .sb.bak backup)
]],
  ["repl"] = [[
storybase repl <file>

  Load a .sb file and start an interactive expression REPL.

  At the prompt, you can:
    <expression>       Evaluate a pure expression and print the result
    <fn-name> [args]   Call a transaction function
    :state <path>      Inspect a state path value
    :scene             Show current scene name
    :choices           List available choices
    :choose <N>        Execute choice N
    :tick              Run one autonomous turn
    :load <path>       Load a save file
    :save <path>       Save the current state
    :help              Show this command list
    :quit / :q         Exit the REPL
]],
  ["compact"] = [[
storybase compact <game.sb> <save.log> [--out <output.log>]

  Collapse a full save log into a snapshot for faster replay.
  Reads the save log, replays it to get the final state, and emits a
  new compact log with one synthetic SET entry per state path.

  Options:
    --out <path>   Write compacted log to <path>
                   (default: <save.log base>.compact.log)
]],
  ["bundle"] = [[
storybase bundle [--production] [--output <path>] <file>

  Bundle a .sb game into a single self-contained Lua file.  The output file
  embeds all runtime modules and the compiled game table; it runs with a
  stock lua5.4 binary and requires no StoryBase installation.

  Options:
    --production     Strip verify/watch blocks from the compiled game
    --output <path>  Write the bundle to <path>  (default: <file>.lua)

  The bundled game accepts the following flags at runtime:
    --seed N         Set random seed for reproducible runs
    --save <path>    Save game log to <path> on exit
    --load <path>    Load game log from <path> before starting
]],
  ["fuzz"] = [[
storybase fuzz [--runs N] [--steps N] [--seed N] [--failures-dir D]
              [--max-failures N] [--format json] <file>

  Random-walk the choice tree of a .sb game and check every verify-always
  invariant after each step.  On violation, the engine log is saved so the
  path can be replayed with:
    storybase run <file> --load <failure.sbd>

  Options:
    --runs N             Number of random-walk runs (default: 1000)
    --steps N            Max steps per run (default: 50)
    --seed N             Base random seed; run i uses seed+i (default: os.time())
    --failures-dir D     Directory for saved failure logs (default: failures)
    --max-failures N     Stop saving after N failures (default: 10)
    --format json        Emit a JSON summary instead of human-readable text

  Exit codes: 0 if no invariants violated, 1 if any violation found or error.
]],
  ["coverage"] = [[
storybase coverage [--depth N] [--budget N] [--format json] <file>

  Walk the BFS frontier of a .sb game and report which scenes and
  functions are reachable within the given search depth.

  Options:
    --depth  N       BFS depth limit (default: 8)
    --budget N       Time budget in seconds (default: 30)
    --format json    Emit a JSON object instead of human-readable text

  Exit codes: 0 on success (even if coverage is incomplete), 1 on error.
]],
  ["docs"] = [[
storybase docs <file> [-o <output>] [--format html|md]

  Walk the typed AST of a .sb file and emit a static reference site:
  one page per declaration kind (types, state, fns, scenes, actors,
  schedules, bounded, macros, speakers, grids, hooks, verify) plus an
  overview home page.  Reuses the doc strings (§18.4) attached to
  declarations in the source.

  Options:
    -o, --output <path>   Output directory (HTML) or file (md).
                          Defaults to ./docs_out/ for HTML, ./docs.md for md.
    --format html|md      Output format (default: html)
]],
  ["serve-api"] = [[
storybase serve-api [--port N] [--bind addr] [--seed N] [--production] <file>

  Start a stateless HTTP API server that hosts the compiled game.  Unlike
  --serve (which keeps one session in memory and is browser-driven), every
  request to serve-api is independent: clients carry the full save log
  between calls.  Multiple chat-bot, web, or Discord frontends can share a
  single server process without locking.

  Endpoints:
    GET  /         Plain-text usage page
    GET  /schema   JSON summary of the compiled schema (states, scenes)
    POST /step     {save_log?, choice_index?, seed?, reset?}
                   → {scene, narration, choices, state, save_log, done, ended}
    POST /reset    Alias for /step with reset:true

  Options:
    --port N         Listen port (default: 8080)
    --bind addr      Bind address (default: 127.0.0.1)
    --seed N         Default seed for fresh-start games when the client
                     omits its own seed
    --production     Compile with verify/watch stripped before serving
]],
  ["lsp"] = [[
storybase lsp

  Start the StoryBase Language Server Protocol (LSP) server.
  Communicates over stdin/stdout using the JSON-RPC 2.0 protocol.

  Configure your editor to launch this command as an LSP server for
  files with the .sb extension.  The server provides:
    - Diagnostics (errors and warnings) on open/change
    - Hover documentation (doc strings, kind, parameters)
    - Go-to-definition (jump to declaration)
    - Completion (names, state paths, types, scenes, functions)
]],
  ["help"] = [[
storybase help [<command>]

  Show overall usage or detailed help for a specific command.

  Examples:
    storybase help
    storybase help run
    storybase help verify
]],
}

local function cmd_help(args)
  local _, pos_args = parse_args(args)
  local subcmd = pos_args[1]
  if subcmd and COMMAND_HELP[subcmd] then
    io.stdout:write(COMMAND_HELP[subcmd])
  else
    print_usage()
  end
  return 0
end

local COMMANDS = {
  ["check"]           = cmd_check,
  ["compile"]         = cmd_compile,
  ["run"]             = cmd_run,
  ["format"]          = cmd_format,
  ["repl"]            = cmd_repl,
  ["verify"]          = cmd_verify,
  ["test"]            = cmd_test,
  ["fuzz"]            = cmd_fuzz,
  ["coverage"]        = cmd_coverage,
  ["migrate"]         = cmd_migrate,
  ["extract-symbols"] = cmd_extract_symbols,
  ["compact"]         = cmd_compact,
  ["bundle"]          = cmd_bundle,
  ["docs"]            = cmd_docs,
  ["serve-api"]       = cmd_serve_api,
  ["lsp"]             = cmd_lsp,
  ["help"]            = cmd_help,
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
-- Guard: do NOT auto-run when require()'d by the test suite or another module.
-- When required, package.loaded["cli.main"] is being set, so we detect that.
if arg and arg[0] and arg[0]:find("[/\\]?main%.lua$") then
  os.exit(M.main(arg))
end

return M

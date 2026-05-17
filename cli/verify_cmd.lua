-- cli/verify_cmd.lua
-- storybase verify <file>: compile and run all verify blocks in a .sb file.
--
-- Flags:
--   --no-cache       Force re-running every verify block (skip cache lookups).
--   --clear-cache    Remove the on-disk cache before running.
--   --cache-dir DIR  Cache directory (default: ".storybase-cache").

local M = {}

local function parse_args(args)
  local opts = { no_cache = false, clear_cache = false, cache_dir = nil }
  local positional = {}
  local i = 1
  while i <= #(args or {}) do
    local a = args[i]
    if a == "--no-cache" then
      opts.no_cache = true
    elseif a == "--clear-cache" then
      opts.clear_cache = true
    elseif a == "--cache-dir" then
      i = i + 1
      opts.cache_dir = args[i]
    else
      positional[#positional+1] = a
    end
    i = i + 1
  end
  opts.file = positional[1]
  return opts
end

local function print_result(out, r, cached)
  local cached_tag = cached and " [cached]" or ""
  if r.skipped then
    out:write(string.format("  SKIP  %s%s\n", r.label or "(unnamed)", cached_tag))
    if r.reason then
      out:write(string.format("        (%s)\n", r.reason))
    end
  elseif r.pass then
    out:write(string.format("  PASS  %s%s\n", r.label or "(unnamed)", cached_tag))
    if r.states_checked then
      out:write(string.format("        (%d BFS states checked)\n",
        r.states_checked))
    end
  else
    out:write(string.format("  FAIL  %s%s\n", r.label or "(unnamed)", cached_tag))
    if r.fail_msg then
      out:write(string.format("        %s\n", r.fail_msg))
    end
    if r.counterexample_path and #r.counterexample_path > 0 then
      local hdr = "Counterexample path"
      if r.counterexample_path_original_len then
        hdr = string.format(
          "Counterexample path (minimised from %d to %d steps)",
          r.counterexample_path_original_len, #r.counterexample_path)
      end
      if r.counterexample_shrink_budget_exceeded then
        hdr = hdr .. " [budget exceeded — may not be minimal]"
      end
      out:write("        " .. hdr .. ":\n")
      for step_i, step in ipairs(r.counterexample_path) do
        out:write(string.format("          %d. [%s] %s\n",
          step_i, step.scene or "?", step.label or "?"))
      end
    end
  end
end

function M.run(args)
  local opts = parse_args(args)
  local filepath = opts.file
  if not filepath then
    io.stderr:write("error: storybase verify: no input file\n")
    return 1
  end

  -- 1. Read source file
  local f, ferr = io.open(filepath, "r")
  if not f then
    io.stderr:write("error: cannot open " .. filepath .. ": " .. tostring(ferr) .. "\n")
    return 1
  end
  local src = f:read("*a"); f:close()

  -- 2. Compile
  local compiler = require("compiler.compiler")
  local game_table, diags = compiler.compile(src, filepath)

  for _, d in ipairs(diags and diags.all or {}) do
    local loc = string.format("%s:%d:%d", d.file or "?", d.line or 0, d.col or 0)
    io.stderr:write(string.format("%s: %s: %s\n", loc, d.level, d.message))
  end
  if diags:has_errors() then
    io.stderr:write("Compilation failed; cannot verify.\n")
    return 1
  end

  -- 3. Run verify blocks
  local verifies = game_table.verifies or {}
  if #verifies == 0 then
    io.stdout:write("No verify blocks found in " .. filepath .. "\n")
    return 0
  end

  io.stdout:write(string.format("Verifying %s (%d block(s))...\n",
    filepath, #verifies))

  -- 4. Set up cache
  local cache_mod = require("cli.verify_cache")
  if opts.clear_cache then
    local path = cache_mod.cache_path(opts.cache_dir)
    os.remove(path)
  end
  local cache = cache_mod.load(opts.cache_dir)

  local verify_mod = require("runtime.verify")

  local passed, failed, skipped, cached_count = 0, 0, 0, 0
  local cache_dirty = false

  for _, ventry in ipairs(verifies) do
    local hash = cache_mod.compute_hash(ventry, game_table)
    local cached_result = (not opts.no_cache) and cache_mod.get(cache, hash) or nil
    local result, from_cache

    if cached_result then
      result = cached_result
      result.label = ventry.label  -- label may have changed via rename without affecting deps
      from_cache = true
      cached_count = cached_count + 1
    else
      local rs = verify_mod.run_all({
        -- Build a 1-block sub-game-table so run_all only runs THIS verify.
        schema     = game_table.schema,
        fns        = game_table.fns,
        scenes     = game_table.scenes,
        actors     = game_table.actors,
        schedules  = game_table.schedules,
        verifies   = { ventry },
        bounded    = game_table.bounded,
        tests      = {},
        migrations = game_table.migrations,
      })
      result = rs[1] or { label = ventry.label, pass = true }
      cache_mod.put(cache, hash, result)
      cache_dirty = true
    end

    if result.skipped       then skipped = skipped + 1
    elseif result.pass      then passed  = passed + 1
    else                         failed  = failed + 1
    end
    print_result(io.stdout, result, from_cache)
  end

  if cache_dirty then
    local ok, save_err = cache_mod.save(cache, opts.cache_dir)
    if not ok then
      io.stderr:write("warning: failed to save verify cache: "
                      .. tostring(save_err) .. "\n")
    end
  end

  io.stdout:write(string.format("\n%d passed, %d failed, %d skipped",
    passed, failed, skipped))
  if cached_count > 0 then
    io.stdout:write(string.format(" (%d cached)", cached_count))
  end
  io.stdout:write("\n")

  return (failed > 0) and 1 or 0
end

return M

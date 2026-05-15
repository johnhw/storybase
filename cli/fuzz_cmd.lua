-- cli/fuzz_cmd.lua
-- storybase fuzz [--runs N] [--steps N] [--seed N] [--failures-dir D]
--               [--max-failures N] [--format json] <file>
--
-- Random-walk the choice tree, checking every verify-always invariant after
-- each step.  On violation, saves the engine log to --failures-dir so the
-- path can be replayed with: storybase run <file> --load <failure.sbd>
--
-- Exit 0 when no invariants are violated; exit 1 on violation or error.

local M = {}

local function parse_args(args)
  local flags      = {}
  local positional = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      local key = a:sub(3)
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

-- Park-Miller LCG seeded per run — separate from the game's own RNG.
local function make_rng(seed)
  local s = (math.floor(math.abs(seed or 1)) % 2147483646) + 1
  return function(n)
    s = (s * 16807) % 2147483647
    return (s % n) + 1
  end
end

-- Write a save file in the engine.lua format so it can be --load-ed.
local function write_save(path, scene_stack, log_obj)
  local log_mod = require("runtime.log")
  local f, err = io.open(path, "w")
  if not f then return false, tostring(err) end
  f:write("-- StoryBase save file (v1)\n")
  f:write("local save = {}\n")
  f:write("save.version = 1\n")
  f:write("save.scene_stack = {")
  local parts = {}
  for _, s in ipairs(scene_stack) do
    parts[#parts + 1] = string.format("%q", s)
  end
  f:write(table.concat(parts, ", ") .. "}\n")
  f:write("save.entries =\n")
  f:write(log_mod.serialise_entries(log_obj:entries()))
  f:write("\n")
  f:write("return save\n")
  f:close()
  return true
end

function M.run(args)
  local flags, pos_args = parse_args(args or {})
  local filepath = pos_args[1]
  if not filepath then
    io.stderr:write("error: storybase fuzz: no input file\n")
    return 1
  end

  -- 1. Read and compile
  local f, ferr = io.open(filepath, "r")
  if not f then
    io.stderr:write("error: cannot open " .. filepath .. ": " .. tostring(ferr) .. "\n")
    return 1
  end
  local src = f:read("*a"); f:close()

  local compiler = require("compiler.compiler")
  local game_table, diags = compiler.compile(src, filepath)
  for _, d in ipairs(diags and diags.all or {}) do
    local loc = string.format("%s:%d:%d", d.file or "?", d.line or 0, d.col or 0)
    io.stderr:write(string.format("%s: %s: %s\n", loc, d.level, d.message))
  end
  if diags:has_errors() then
    io.stderr:write("Compilation failed; cannot fuzz.\n")
    return 1
  end

  -- 2. Collect verify-always clauses from all verify blocks
  local always_checks = {}
  for _, verify_entry in ipairs(game_table.verifies or {}) do
    for _, clause in ipairs(verify_entry.clauses or {}) do
      if clause.kind == "always" then
        always_checks[#always_checks + 1] = {
          label     = verify_entry.label,
          condition = clause.condition,
        }
      end
    end
  end

  -- 3. Parse options
  local runs         = tonumber(flags.runs)           or 1000
  local max_steps    = tonumber(flags.steps)          or 50
  local base_seed    = tonumber(flags.seed)           or os.time()
  local fail_dir     = flags["failures-dir"]          or "failures"
  local max_failures = tonumber(flags["max-failures"]) or 10
  local fmt          = flags.format

  -- 4. Run fuzz iterations
  local engine_mod = require("runtime.engine")
  local eval_mod   = require("runtime.eval")
  local io_sink    = { write = function() end }

  local total_runs     = 0
  local total_failures = 0
  local saved_failures = {}
  local fail_dir_ready = false

  local function ensure_fail_dir()
    if not fail_dir_ready then
      os.execute(string.format('mkdir -p "%s" 2>/dev/null', fail_dir))
      fail_dir_ready = true
    end
  end

  for run_i = 1, runs do
    total_runs = total_runs + 1
    local run_seed = base_seed + run_i

    local eng = engine_mod.new(game_table, { seed = run_seed, io_out = io_sink })
    eng:init()

    local pick = make_rng(run_seed)
    eng._driver = {
      render = function(_self, _frame) end,
      prompt = function(_self, choices_list)
        return pick(#choices_list)
      end,
    }

    local run_failed = false
    for step_i = 1, max_steps do
      local ok, cont = pcall(function() return eng:step() end)
      if not ok or not cont then break end

      -- Check all verify-always predicates after this step
      for _, check in ipairs(always_checks) do
        local ctx         = eng:make_ctx("fuzz-verify")
        local ok_e, result = pcall(eval_mod.eval_expr, check.condition, ctx)
        if not ok_e or not result then
          total_failures = total_failures + 1
          run_failed = true

          if #saved_failures < max_failures then
            ensure_fail_dir()
            local fname = string.format("%s/run%d_seed%d.sbd",
              fail_dir, run_i, run_seed)
            write_save(fname, eng._scene_stack, eng._log)
            saved_failures[#saved_failures + 1] = {
              run   = run_i,
              seed  = run_seed,
              step  = step_i,
              label = check.label or "(unnamed)",
              file  = fname,
            }
            if fmt ~= "json" then
              io.stdout:write(string.format(
                "  FAIL  run %d  step %d  seed %d  [%s]\n",
                run_i, step_i, run_seed, check.label or "(unnamed)"))
              io.stdout:write(string.format(
                "        saved: %s\n", fname))
            end
          end
          break  -- one failure per run is enough
        end
      end

      if run_failed then break end
    end
  end

  -- 5. Emit report
  local pass_count = total_runs - total_failures
  local pass_pct   = total_runs > 0
    and math.floor(pass_count / total_runs * 100 + 0.5) or 100

  if fmt == "json" then
    local debug_mod = require("runtime.debug")
    local payload = {
      file          = filepath,
      runs          = total_runs,
      steps_per_run = max_steps,
      base_seed     = base_seed,
      failures      = total_failures,
      pass_rate     = pass_pct,
      failure_list  = saved_failures,
    }
    io.stdout:write(debug_mod.encode_json(payload) .. "\n")
  else
    io.stdout:write(string.format("Fuzz: %s\n", filepath))
    io.stdout:write(string.format(
      "  %d runs  %d steps/run  seed %d  dir %s\n\n",
      total_runs, max_steps, base_seed, fail_dir))
    if #always_checks == 0 then
      io.stdout:write(
        "  (no verify-always blocks — running for crash detection only)\n\n")
    end
    io.stdout:write(string.format(
      "%d / %d runs passed  (%d%%)\n",
      pass_count, total_runs, pass_pct))
    if total_failures > 0 then
      io.stdout:write(string.format(
        "%d failure(s); %d saved to %s/\n",
        total_failures, #saved_failures, fail_dir))
      if #saved_failures > 0 then
        io.stdout:write(
          "Replay with: storybase run <file> --load <failure.sbd>\n")
      end
    end
  end

  return total_failures > 0 and 1 or 0
end

return M

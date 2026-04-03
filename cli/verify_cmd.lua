-- cli/verify_cmd.lua
-- storybase verify <file>: compile and run all verify blocks in a .sb file.

local M = {}

function M.run(args)
  local filepath = args and args[1]
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

  local has_errors = false
  for _, d in ipairs(diags or {}) do
    local loc = string.format("%s:%d:%d", d.file or "?", d.line or 0, d.col or 0)
    io.stderr:write(string.format("%s: %s: %s\n", loc, d.level, d.message))
    if d.level == "error" then has_errors = true end
  end
  if has_errors then
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

  local verify_mod = require("runtime.verify")
  local results    = verify_mod.run_all(game_table)

  local passed, failed, skipped = 0, 0, 0
  for _, r in ipairs(results) do
    if r.skipped then
      skipped = skipped + 1
      io.stdout:write(string.format("  SKIP  %s\n", r.label or "(unnamed)"))
      if r.reason then
        io.stdout:write(string.format("        (%s)\n", r.reason))
      end
    elseif r.pass then
      passed = passed + 1
      io.stdout:write(string.format("  PASS  %s\n", r.label or "(unnamed)"))
      if r.states_checked then
        io.stdout:write(string.format("        (%d BFS states checked)\n",
          r.states_checked))
      end
    else
      failed = failed + 1
      io.stdout:write(string.format("  FAIL  %s\n", r.label or "(unnamed)"))
      if r.fail_msg then
        io.stdout:write(string.format("        %s\n", r.fail_msg))
      end
    end
  end

  io.stdout:write(string.format("\n%d passed, %d failed, %d skipped\n",
    passed, failed, skipped))

  return (failed > 0) and 1 or 0
end

return M

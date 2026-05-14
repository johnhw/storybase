-- cli/test_cmd.lua
-- storybase test <file>: compile and run all test blocks in a .sb file.

local M = {}

function M.run(args)
  local filepath = args and args[1]
  if not filepath then
    io.stderr:write("error: storybase test: no input file\n")
    return 1
  end

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
    io.stderr:write("Compilation failed; cannot run tests.\n")
    return 1
  end

  local tests = game_table.tests or {}
  if #tests == 0 then
    io.stdout:write("No test blocks found in " .. filepath .. "\n")
    return 0
  end

  io.stdout:write(string.format("Testing %s (%d block(s))...\n", filepath, #tests))

  local tests_mod = require("runtime.tests")
  local results   = tests_mod.run_all(game_table)

  local passed, failed = 0, 0
  for _, r in ipairs(results) do
    if r.pass then
      passed = passed + 1
      io.stdout:write(string.format("  PASS  %s\n", r.label or "(unnamed)"))
    else
      failed = failed + 1
      io.stdout:write(string.format("  FAIL  %s\n", r.label or "(unnamed)"))
      if r.fail_msg then
        io.stdout:write(string.format("        %s\n", r.fail_msg))
      end
    end
  end

  io.stdout:write(string.format("\n%d passed, %d failed\n", passed, failed))

  return (failed > 0) and 1 or 0
end

return M

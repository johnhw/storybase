-- cli/verify_cmd.lua
-- storybase verify <file>: run all verify blocks in a .sb file.
-- Phase 5 deliverable. Not yet implemented.

local M = {}

function M.run(args)
  local filepath = args and args[1]
  if not filepath then
    io.stderr:write("error: storybase verify: no input file\n")
    return 1
  end
  io.stderr:write("storybase verify: not yet implemented\n")
  return 1
end

return M

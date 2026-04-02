-- cli/extract_cmd.lua
-- storybase extract-symbols <file>: scan symbol literals and suggest type declarations.
-- Phase 8 deliverable. Not yet implemented.

local M = {}

function M.run(args)
  local filepath = args and args[1]
  if not filepath then
    io.stderr:write("error: storybase extract-symbols: no input file\n")
    return 1
  end
  io.stderr:write("storybase extract-symbols: not yet implemented\n")
  return 1
end

return M

-- cli/migrate_cmd.lua
-- storybase migrate <save.log>: apply outstanding schema migrations.
-- Phase 6 deliverable. Not yet implemented.

local M = {}

function M.run(args)
  local filepath = args and args[1]
  if not filepath then
    io.stderr:write("error: storybase migrate: no save log specified\n")
    return 1
  end
  io.stderr:write("storybase migrate: not yet implemented\n")
  return 1
end

return M

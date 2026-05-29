-- cli/drivers/plain/init.lua
-- Plain-text UI driver for storybase.
--
-- Implements the driver protocol declared in `cli/drivers/driver.lua`.
-- Operates in pull-mode (render+prompt). Lifecycle methods
-- (attach/tick/detach) are no-op stubs reserved for the future
-- kernel-driven dispatch path (ui_idea.md §M1).

local M = {}

--- Create a new plain driver.
---@param opts table? { io_out, io_in }
---@return table  driver object
function M.new(opts)
  opts = opts or {}
  local out = opts.io_out or io.stdout
  local inp = opts.io_in  or io.stdin

  local driver = {}

  function driver:render(scene_output)
    out:write("\n")
    for _, item in ipairs(scene_output.narration or {}) do
      if item.kind == "say" then
        local label = item.display or item.speaker or "?"
        out:write(label .. ": " .. tostring(item.text or "") .. "\n")
      elseif item.text and item.text ~= "" then
        out:write(item.text .. "\n")
      end
    end
    out:write("\n")
  end

  function driver:prompt(choices)
    for i, c in ipairs(choices) do
      out:write(i .. ". " .. c.label .. "\n")
    end
    out:write("\n")
    out:write("Choice (1-" .. #choices .. ", q to quit): ")
    if out.flush then out:flush() end

    local line = inp:read("*l")
    if not line then return nil end
    line = line:match("^%s*(.-)%s*$")
    if line == "q" or line == "quit" or line == "exit" then return nil end
    local idx = tonumber(line)
    if not idx or idx < 1 or idx > #choices then
      out:write("Invalid choice.\n")
      return self:prompt(choices)
    end
    return idx
  end

  function driver:notify(_event, _data)
  end

  -- Lifecycle stubs (see cli/drivers/driver.lua and ui_idea.md §3.4).
  -- Plain driver is synchronous-pull; no kernel subscription, no
  -- animation frames, no surface to release.
  function driver:attach(_kernel) end
  function driver:tick(_dt) end
  function driver:detach() end

  return driver
end

return M

-- cli/drivers/ansi/init.lua
-- ANSI-color UI driver for storybase.
--
-- Implements the driver protocol declared in `cli/drivers/driver.lua`.
-- Uses ANSI true-color (24-bit) escape codes for speaker labels when a
-- `color:` is declared on the speaker.  Falls back to bold for undeclared
-- speakers.  Choice indices are printed in bold; narration is plain.
-- Operates in pull-mode like `plain`; lifecycle methods are no-op stubs.
--
-- Activate with:  storybase run game.sb --ui ansi

local M = {}

local RESET = "\27[0m"
local BOLD  = "\27[1m"
local DIM   = "\27[2m"

--- Convert a "#rrggbb" hex string to an ANSI true-color foreground escape.
---@param hex string  e.g. "#c8a96e"
---@return string     ANSI escape sequence, or BOLD if hex is nil/invalid
local function fg(hex)
  if not hex then return BOLD end
  local h = hex:match("^#?(%x%x%x%x%x%x)$")
  if not h then return BOLD end
  local r = tonumber(h:sub(1, 2), 16)
  local g = tonumber(h:sub(3, 4), 16)
  local b = tonumber(h:sub(5, 6), 16)
  return string.format("\27[38;2;%d;%d;%dm", r, g, b)
end

--- Create a new ANSI driver.
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
        local color = fg(item.color)
        out:write(color .. label .. RESET .. ": " .. tostring(item.text or "") .. "\n")
      elseif item.text and item.text ~= "" then
        out:write(item.text .. "\n")
      end
    end
    out:write("\n")
  end

  function driver:prompt(choices)
    for i, c in ipairs(choices) do
      out:write(BOLD .. tostring(i) .. RESET .. ". " .. c.label .. "\n")
    end
    out:write("\n")
    out:write(DIM .. "Choice (1-" .. #choices .. ", q to quit): " .. RESET)
    if out.flush then out:flush() end

    local line = inp:read("*l")
    if not line then return nil end
    line = line:match("^%s*(.-)%s*$")
    if line == "q" or line == "quit" or line == "exit" then return nil end
    local idx = tonumber(line)
    if not idx or idx < 1 or idx > #choices then
      out:write(DIM .. "Invalid choice." .. RESET .. "\n")
      return self:prompt(choices)
    end
    return idx
  end

  function driver:notify(_event, _data)
  end

  -- Lifecycle stubs (see cli/drivers/driver.lua and ui_idea.md §3.4).
  -- ANSI driver is synchronous-pull; no kernel subscription, no
  -- animation frames, no surface to release.
  function driver:attach(_kernel) end
  function driver:tick(_dt) end
  function driver:detach() end

  return driver
end

return M

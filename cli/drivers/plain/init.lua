-- cli/drivers/plain/init.lua
-- Plain-text UI driver for storybase.
--
-- Implements the driver protocol declared in `cli/drivers/driver.lua`.
-- Operates in pull-mode (render+prompt).
--
-- §M5 fallback: when a kernel is attached, every `render` prefixes a
-- one-line text rendering for each author-declared stat-bar binding
-- ("Health: 7/10"). The plain driver doesn't subscribe to mutations —
-- it re-emits the snapshot each turn, which is the natural cadence for
-- a synchronous-pull text driver. Drivers with no widgets/no kernel
-- print no header line.

local format = require("ui.format")

local M = {}

--- Walk schema + ui_panels and return a list of `{path, label,
--- type_desc}` records the plain driver should print as text lines.
--- Mirrors the discovery logic in `cli/drivers/curses/init.lua`
--- (collect_widgets) but ignores non-statbar widget kinds.
---@param schema table?
---@param panels table?
---@return table[]
local function collect_statbars(schema, panels)
  local out = {}
  local seen = {}
  local by_path = {}
  for _, s in ipairs((schema and schema.states) or {}) do
    if s.kind == "scalar" and s.path then by_path[s.path] = s end
  end
  local function add(path, ui)
    if seen[path] then return end
    seen[path] = true
    local s = by_path[path]
    if not s then return end
    out[#out + 1] = {
      path      = path,
      label     = (ui and ui.label) or path:match("([^/]+)$") or path,
      type_desc = s.type_desc,
    }
  end
  for _, s in ipairs((schema and schema.states) or {}) do
    if s.kind == "scalar" and s.ui and s.ui.kind == "stat-bar" then
      add(s.path, s.ui)
    end
  end
  for _, p in ipairs(panels or {}) do
    for _, child in ipairs(p.children or {}) do
      if child.kind == "stat-bar" and child.arg then
        local s = by_path[child.arg]
        add(child.arg, s and s.ui)
      end
    end
  end
  return out
end

--- Create a new plain driver.
---@param opts table? { io_out, io_in }
---@return table  driver object
function M.new(opts)
  opts = opts or {}
  local out = opts.io_out or io.stdout
  local inp = opts.io_in  or io.stdin

  local driver = {
    _kernel   = nil,
    _statbars = {},
  }

  --- Emit a one-line "Label: cur/max" header for every author-declared
  --- stat-bar binding. Silently skipped when no kernel is attached or
  --- when there are no bindings — preserves the historic plain-driver
  --- output for games that don't use UI bindings.
  local function write_stat_header(self)
    if not self._kernel or #self._statbars == 0 then return end
    for _, sb in ipairs(self._statbars) do
      local value = self._kernel:get_state(sb.path)
      local text
      if value == nil then
        text = sb.label .. ": -"
      else
        text = sb.label .. ": " .. format.int(value, sb.type_desc)
      end
      out:write(text .. "\n")
    end
    out:write("\n")
  end

  function driver:render(scene_output)
    out:write("\n")
    write_stat_header(self)
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

  -- §M5: pick up author-declared stat-bar bindings from the kernel.
  -- The plain driver does *not* subscribe to mutation events — every
  -- render() re-reads the kernel's state cache, which matches its
  -- synchronous-pull cadence.
  function driver:attach(kernel)
    self._kernel = kernel
    self._statbars = {}
    if kernel and kernel.get_schema then
      self._statbars = collect_statbars(
        kernel:get_schema(),
        kernel.get_bindings and kernel:get_bindings() or {})
    end
  end

  function driver:tick(_dt) end

  function driver:detach()
    self._kernel   = nil
    self._statbars = {}
  end

  return driver
end

return M

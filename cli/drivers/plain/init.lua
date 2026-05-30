-- cli/drivers/plain/init.lua
-- Plain-text UI driver for storybase.
--
-- Implements the driver protocol declared in `cli/drivers/driver.lua`.
-- Operates in pull-mode (render+prompt).
--
-- §M5 / §M8 fallback: when a kernel is attached, every `render` prefixes
-- a one-line text rendering for each author-declared widget binding the
-- driver knows how to flatten — today that includes `stat-bar`, `stat`,
-- `toggle`, `text`, and `inventory` (rendered as `"Label: a, b, c"`).
-- The plain driver doesn't subscribe to mutations — it re-emits the
-- snapshot each turn, which is the natural cadence for a synchronous-pull
-- text driver. Drivers with no widgets / no kernel print no header.

local format = require("ui.format")

local M = {}

--- Substitute `{path}` placeholders in `template` against `kernel`.
--- Mirrors the logic in widgets/text.lua so plain + curses agree on
--- the displayed value; kept here as a small local so the plain driver
--- does not need to instantiate widget objects.
---@param template string
---@param kernel   table
---@param schema   table?
---@return string
local function interp(template, kernel, schema)
  return (template:gsub("(%b{})", function(m)
    if m == "{{" or m == "}}" then return m end
    local path = m:sub(2, -2)
    local td
    if schema and schema.states then
      for _, s in ipairs(schema.states) do
        if s.kind == "scalar" and s.path == path then td = s.type_desc; break end
      end
    end
    return format.value(kernel:get_state(path), td, schema)
  end))
end

--- Walk schema + ui_panels and return a list of widget binding records
--- the plain driver should print as text lines. Each record:
---   { kind="stat-bar" | "stat" | "toggle" | "text" | "inventory",
---     path=...?, label=..., type_desc=..., template=...? (text only) }
---
--- Mirrors the discovery logic in `cli/drivers/curses/init.lua`
--- (collect_widgets) for the subset of widget kinds the plain driver
--- knows how to flatten to a single line. Unknown kinds are skipped.
---@param schema table?
---@param panels table?
---@return table[]
local function collect_widgets(schema, panels)
  local out = {}
  local seen = {}
  local by_path = {}
  for _, s in ipairs((schema and schema.states) or {}) do
    if s.kind == "scalar" and s.path then by_path[s.path] = s end
  end

  local function label_for(path, ui)
    return (ui and ui.label) or (path and path:match("([^/]+)$")) or path
  end

  local function add_path_widget(kind, path, ui)
    if seen[path] then return end
    local s = by_path[path]
    if not s then return end
    seen[path] = true
    out[#out + 1] = {
      kind      = kind,
      path      = path,
      label     = label_for(path, ui),
      type_desc = s.type_desc,
    }
  end

  local function add_text(template)
    if type(template) ~= "string" or template == "" then return end
    out[#out + 1] = { kind = "text", template = template }
  end

  -- Pass 1: state-decl ui blocks.
  for _, s in ipairs((schema and schema.states) or {}) do
    local ui = s.ui
    if s.kind == "scalar" and ui and ui.kind then
      local k = ui.kind
      if k == "stat-bar" or k == "stat" or k == "toggle" or k == "inventory" then
        add_path_widget(k, s.path, ui)
      elseif k == "text" then
        add_text(ui.template or ("{" .. s.path .. "}"))
      end
    end
  end

  -- Pass 2: ui-panel children.
  for _, p in ipairs(panels or {}) do
    for _, child in ipairs(p.children or {}) do
      local ck = child.kind
      if ck == "text" then
        add_text(child.arg or "")
      elseif ck == "stat-bar" or ck == "stat" or ck == "toggle"
             or ck == "inventory" then
        local s = by_path[child.arg]
        add_path_widget(ck, child.arg, s and s.ui)
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
    _kernel  = nil,
    _widgets = {},
    _schema  = nil,
  }

  --- Render a single-binding widget to a one-line string. Stat-bar and
  --- stat both flatten to `"Label: value"`; toggle to `"Label: yes|no"`;
  --- inventory to `"Label: a, b, c"` (or `"Label: (empty)"`).
  local function render_widget(self, w)
    local k = self._kernel
    if w.kind == "text" then
      return interp(w.template, k, self._schema)
    end
    local value = k:get_state(w.path)
    if w.kind == "stat-bar" or w.kind == "stat" then
      if value == nil then return w.label .. ": -" end
      return w.label .. ": " .. format.value(value, w.type_desc, self._schema)
    elseif w.kind == "toggle" then
      if value == nil then return w.label .. ": -" end
      return w.label .. ": " .. format.bool(value and true or false)
    elseif w.kind == "inventory" then
      if type(value) ~= "table" or #value == 0 then
        return w.label .. ": (empty)"
      end
      local parts = {}
      for i = 1, #value do
        parts[i] = format.value(value[i], nil, self._schema)
      end
      return w.label .. ": " .. table.concat(parts, ", ")
    end
    return tostring(w.label or "")
  end

  --- Emit one line per author-declared widget binding. Silently skipped
  --- when no kernel is attached or when there are no bindings — preserves
  --- the historic plain-driver output for games that don't use UI bindings.
  local function write_widget_header(self)
    if not self._kernel or #self._widgets == 0 then return end
    for _, w in ipairs(self._widgets) do
      out:write(render_widget(self, w) .. "\n")
    end
    out:write("\n")
  end

  function driver:render(scene_output)
    out:write("\n")
    write_widget_header(self)
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

  -- §M5 / §M8: pick up author-declared widget bindings from the kernel.
  -- The plain driver does *not* subscribe to mutation events — every
  -- render() re-reads the kernel's state cache, which matches its
  -- synchronous-pull cadence.
  function driver:attach(kernel)
    self._kernel  = kernel
    self._widgets = {}
    self._schema  = nil
    if kernel and kernel.get_schema then
      self._schema  = kernel:get_schema()
      self._widgets = collect_widgets(
        self._schema,
        kernel.get_bindings and kernel:get_bindings() or {})
    end
  end

  function driver:tick(_dt) end

  function driver:detach()
    self._kernel  = nil
    self._widgets = {}
    self._schema  = nil
  end

  return driver
end

return M

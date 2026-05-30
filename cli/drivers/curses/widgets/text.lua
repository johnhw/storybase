-- cli/drivers/curses/widgets/text.lua
--
-- Curses interpolated-text widget (ui_idea.md §5.3 + §M8). Renders a
-- template string with `{path/segment}` placeholders substituted by
-- live values from `kernel:get_state(path)`. Each `{...}` is replaced
-- by `ui/format.value(value, type_desc, schema)` so bounded ints show
-- as "cur/max", bools as "yes/no", etc.
--
-- The widget is *reactive*: the driver discovers every placeholder via
-- `M:paths()` and subscribes mutations on each of them. A single static
-- string with no placeholders is also valid — it never re-renders.
--
-- Wiring:
--   * `M.new{ template, schema? }` returns a widget.
--   * `widget:paths()` enumerates the placeholder paths so the driver
--     can subscribe each one to mutation events.
--   * `widget:paint(screen, win, kernel)` writes the substituted line(s)
--     into a driver-allocated window.
--
-- Template syntax:
--   "Gold: {player/gold}"          - one path
--   "{player/name} at {location}"  - multiple paths
--   "{{literal braces}}"           - "{literal braces}" (no substitution)
--
-- The widget renders top-aligned, one logical line per physical row, and
-- truncates each row on the right edge of the window. Newline characters
-- in the template are honoured.

local format = require("ui.format")

local M = {}

-- ── parsing ────────────────────────────────────────────────────────────

--- Parse the template into a sequence of segments. Each segment is one of:
---   { kind = "lit",  text  = "..." }   -- literal text
---   { kind = "path", path  = "..." }   -- {path} substitution
--- `{{` and `}}` collapse to literal braces (mirrors Lua's string.format
--- "%%"). An unterminated `{` raises an error so authors learn early.
---@param template string
---@return table[] segments
local function parse(template)
  local out = {}
  local buf = {}
  local i, n = 1, #template

  local function flush_lit()
    if #buf > 0 then
      out[#out + 1] = { kind = "lit", text = table.concat(buf) }
      buf = {}
    end
  end

  while i <= n do
    local ch = template:sub(i, i)
    if ch == "{" then
      if template:sub(i + 1, i + 1) == "{" then
        buf[#buf + 1] = "{"
        i = i + 2
      else
        local close = template:find("}", i + 1, true)
        assert(close, "text widget: unterminated '{' in template: "
                      .. template)
        local path = template:sub(i + 1, close - 1)
        assert(#path > 0,
               "text widget: empty placeholder in template: " .. template)
        flush_lit()
        out[#out + 1] = { kind = "path", path = path }
        i = close + 1
      end
    elseif ch == "}" and template:sub(i + 1, i + 1) == "}" then
      buf[#buf + 1] = "}"
      i = i + 2
    else
      buf[#buf + 1] = ch
      i = i + 1
    end
  end
  flush_lit()
  return out
end

-- ── public API ─────────────────────────────────────────────────────────

--- Construct a text widget.
---@param opts table  {
---   template : interpolated string template (required)
---   schema   : compiled schema; used to look up type descriptors so
---              substituted values format correctly (optional)
--- }
---@return table widget
function M.new(opts)
  opts = opts or {}
  assert(type(opts.template) == "string", "text: template is required")

  local self = {
    kind     = "text",
    template = opts.template,
    schema   = opts.schema,
    _segs    = parse(opts.template),
  }

  -- Build a stable list of unique placeholder paths in encounter order
  -- so the driver can subscribe each one exactly once.
  local seen = {}
  local paths = {}
  for _, seg in ipairs(self._segs) do
    if seg.kind == "path" and not seen[seg.path] then
      seen[seg.path] = true
      paths[#paths + 1] = seg.path
    end
  end
  self._paths = paths

  --- Return the list of placeholder paths in encounter order. Driver
  --- callers iterate this to subscribe mutation events.
  ---@return string[]
  function self:paths() return self._paths end

  --- Look up a path's scalar type descriptor in the schema, returning
  --- nil when no descriptor is available. Falls back to nil rather than
  --- erroring so a typo in a template degrades gracefully (the value
  --- renders via the heuristic fallback in ui/format.value).
  ---@param path string
  ---@return table?
  local function td_for(path)
    if not self.schema or not self.schema.states then return nil end
    for _, s in ipairs(self.schema.states) do
      if s.kind == "scalar" and s.path == path then return s.type_desc end
    end
    return nil
  end

  --- Substitute all placeholders against the kernel's current state and
  --- return the resulting string. Multi-line templates are honoured —
  --- callers split the result on "\n" themselves.
  ---@param kernel table
  ---@return string
  function self:render(kernel)
    local parts = {}
    for i, seg in ipairs(self._segs) do
      if seg.kind == "lit" then
        parts[i] = seg.text
      else
        local v  = kernel and kernel:get_state(seg.path)
        local td = td_for(seg.path)
        parts[i] = format.value(v, td, self.schema)
      end
    end
    return table.concat(parts)
  end

  --- Paint into a driver-allocated window. Top-aligned, one line per
  --- row, clipped on the right.
  ---@param screen table
  ---@param win    table
  ---@param kernel table
  function self:paint(screen, win, kernel)
    if not win or win.h < 1 or win.w < 1 then return end
    screen:fill(win, 0, 0, win.w, win.h, " ")
    local text = self:render(kernel)
    local y = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      if y >= win.h then break end
      if #line > win.w then line = line:sub(1, win.w) end
      screen:write(win, y, 0, line)
      y = y + 1
    end
  end

  return self
end

return M

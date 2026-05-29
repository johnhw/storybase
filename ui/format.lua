-- ui/format.lua
--
-- Display formatter for StoryBase values, parameterised by the
-- compiled-game schema type descriptor for the path being formatted.
-- See `ui_idea.md` §4 (presentation kernel — "Display formatter") for
-- the design intent. The formatter is intentionally driver-agnostic:
-- it produces strings only. Drivers add color, layout, and animation
-- on top of these strings.
--
-- Type descriptors are the runtime shape produced by
-- `compiler/codegen.lua` and consumed by `runtime/state.lua` (see
-- `runtime/state.lua:resolve_default` and `lookup_type` for the
-- complete set of recognised `tag` values).
--
-- Recognised type descriptor tags:
--
--   int     {tag="int", min?, max?}           Bounded → "cur/max",
--                                             unbounded → "cur".
--   float   {tag="float"}                     `%g`.
--   bool    {tag="bool"}                      "yes" / "no" by default;
--                                             callers may override via
--                                             `opts.bool_labels`.
--   string  {tag="string"}                    value verbatim.
--   symbol  {tag="symbol"}                    bare name (no leading `'`).
--   enum    {tag="enum", values=[...]}        the symbol name.
--   named   {tag="named", name=...}           resolved against schema;
--                                             alias chains followed.
--   set / list                                "(a, b, c)" / "[a, b, c]"
--                                             with N=0 special-cased to
--                                             "(empty)".
--   record  (no runtime tag for `record`)     "{k=v, ...}" with stable
--                                             alphabetical key order.
--
-- Callable as:
--   format.value(value, type_desc, schema?, opts?) -> string
--   format.bool(b, opts?) / format.int(n, td) / format.list(t, ", ")
--
-- `opts` is reserved for forward-compatible knobs (e.g. precision,
-- locale). Today only `opts.bool_labels = {yes="Y", no="N"}` is read.

local M = {}

--- Format a boolean as a localisable string.
---@param b    boolean
---@param opts table?  `{bool_labels = {yes="...", no="..."}}`
---@return string
function M.bool(b, opts)
  local labels = (opts and opts.bool_labels) or {}
  if b then return labels.yes or "yes" end
  return labels.no or "no"
end

--- Format an int with optional bounds. Bounded → "cur/max"; unbounded
--- → bare integer.
---@param n  integer
---@param td table?  type descriptor with optional `min` / `max`
---@return string
function M.int(n, td)
  if type(n) ~= "number" then return tostring(n) end
  local s = tostring(math.tointeger(n) or n)
  if td and td.max then
    return s .. "/" .. tostring(td.max)
  end
  return s
end

--- Format a float with `%g` (concise, no trailing zeros).
---@param x number
---@return string
function M.float(x)
  if type(x) ~= "number" then return tostring(x) end
  return string.format("%g", x)
end

--- Format a list-like value with the given separator. Uses parens for
--- sets ("(a, b)"), brackets for lists ("[a, b]"). Empty → "(empty)".
local function format_seq(t, open, close, schema)
  if type(t) ~= "table" then return tostring(t) end
  local n = #t
  if n == 0 then return "(empty)" end
  local parts = {}
  for i = 1, n do
    parts[i] = M.value(t[i], nil, schema)
  end
  return open .. table.concat(parts, ", ") .. close
end

--- Format a record as "{k=v, ...}" with stable alphabetical key order.
local function format_record(t, schema)
  if type(t) ~= "table" then return tostring(t) end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for i, k in ipairs(keys) do
    parts[i] = tostring(k) .. "=" .. M.value(t[k], nil, schema)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

--- Resolve a `{tag="named", name=...}` descriptor against the schema's
--- `types` list, following any `kind="alias"` chains. Returns the
--- final non-alias descriptor (e.g. the underlying enum or int), or
--- the original `named` if resolution fails.
local function resolve_named(td, schema)
  if not (td and schema and schema.types and td.tag == "named") then return td end
  local seen = {}
  local cur  = td
  while cur and cur.tag == "named" and not seen[cur.name] do
    seen[cur.name] = true
    local found
    for _, t in ipairs(schema.types or {}) do
      if t.name == cur.name then found = t; break end
    end
    if not found then return td end
    if found.kind == "alias" then
      cur = found.type_desc
    elseif found.kind == "enum" then
      return { tag = "enum", values = found.values }
    else
      -- e.g. record — return a synthetic descriptor so callers see the kind
      return { tag = found.kind, fields = found.fields }
    end
  end
  return cur or td
end

--- Format a value for display, dispatching on the schema type descriptor.
--- When `td` is nil, falls back to type-of-value heuristics.
---@param value any
---@param td    table?  schema type descriptor (e.g. `{tag="int", min=0, max=10}`)
---@param schema table?  compiled schema, used to resolve `named` references
---@param opts   table?  forward-compat knobs (see module header)
---@return string
function M.value(value, td, schema, opts)
  if value == nil then return "-" end

  -- Resolve named/alias chains so we operate on a concrete tag below.
  td = resolve_named(td, schema)

  if td then
    local tag = td.tag
    if     tag == "int"    then return M.int(value, td)
    elseif tag == "float"  then return M.float(value)
    elseif tag == "bool"   then return M.bool(value and true or false, opts)
    elseif tag == "string" then return tostring(value)
    elseif tag == "symbol" then return tostring(value)
    elseif tag == "enum"   then return tostring(value)
    elseif tag == "set"    then return format_seq(value, "(", ")", schema)
    elseif tag == "list"   then return format_seq(value, "[", "]", schema)
    elseif tag == "record" then return format_record(value, schema)
    end
  end

  -- Heuristic fallback when no descriptor is available.
  local lty = type(value)
  if     lty == "boolean" then return M.bool(value, opts)
  elseif lty == "number"  then
    if math.type(value) == "float" then return M.float(value) end
    return tostring(value)
  elseif lty == "string"  then return value
  elseif lty == "table"   then
    if #value > 0 then return format_seq(value, "[", "]", schema) end
    return format_record(value, schema)
  end
  return tostring(value)
end

--- Convenience: format a state path by looking up its descriptor in
--- the schema. Returns the same string `M.value(value, td)` would.
--- Useful for drivers that already hold the schema.
---@param schema table   compiled schema
---@param path   string  e.g. "player/hp"
---@param value  any
---@param opts   table?
---@return string
function M.path(schema, path, value, opts)
  local td = nil
  if schema and schema.states then
    for _, s in ipairs(schema.states) do
      if s.path == path and s.kind == "scalar" then td = s.type_desc; break end
    end
  end
  return M.value(value, td, schema, opts)
end

return M

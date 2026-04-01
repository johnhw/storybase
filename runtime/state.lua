-- runtime/state.lua
-- Path store: O(1) read cache backed by the transaction log.
--
-- The state store maintains two representations simultaneously:
--   cache — flat Lua table keyed by path string (e.g. "player/health")
--   log   — see runtime/log.lua (the ground truth)
--
-- Every mutation updates the cache and appends a log entry atomically.
-- Reads always go through the cache and are O(1).

local M = {}

-- ============================================================
-- Schema type-index builder
-- ============================================================

--- Build a path → type_desc lookup table from the compiled schema.
--- Handles scalars, inline records, and entity families.
---@param schema table  game_table.schema
---@return table  { ["player/health"] = {tag="int",min=0,max=100}, ... }
local function build_type_index(schema)
  local idx = {}
  if not schema then return idx end

  -- Build name → type_def lookup for named types
  local type_defs = {}
  for _, t in ipairs(schema.types or {}) do
    if t.name then type_defs[t.name] = t end
  end

  -- Expand a record's fields under a given path prefix
  local function expand_record(prefix, fields)
    for _, f in ipairs(fields or {}) do
      if f.name then
        idx[prefix .. "/" .. f.name] = f.type_desc
      end
    end
  end

  -- Look up the fields of a (possibly named) type descriptor
  local function get_fields(type_desc)
    if not type_desc then return {} end
    if type_desc.tag == "named" then
      local t = type_defs[type_desc.name]
      if t and t.kind == "record" then
        return t.fields or {}
      end
    end
    return {}
  end

  for _, s in ipairs(schema.states or {}) do
    if s.kind == "scalar" then
      idx[s.path] = s.type_desc

    elseif s.kind == "record" then
      -- Expand each field under the record path
      expand_record(s.path, s.fields)

    elseif s.kind == "family" then
      -- Store per-family metadata under a sentinel key
      idx["__family__" .. s.family] = {
        type_desc = s.type_desc,
        max       = s.max,
        fields    = get_fields(s.type_desc),
      }
    end
  end

  return idx
end

--- Look up the type descriptor for a path, handling family member paths.
---@param idx  table   type index from build_type_index
---@param path string  e.g. "party/fighter/health"
---@return table?  type_desc, or nil if not found
local function lookup_type(idx, path)
  if idx[path] then return idx[path] end

  -- Try family path: "family/key" or "family/key/field"
  local parts = {}
  for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end

  if #parts >= 2 then
    local fam_info = idx["__family__" .. parts[1]]
    if fam_info then
      if #parts == 2 then
        return fam_info.type_desc
      else
        -- "family/key/field..."
        local field_name = parts[3]
        for _, f in ipairs(fam_info.fields or {}) do
          if f.name == field_name then return f.type_desc end
        end
      end
    end
  end

  return nil
end

-- ============================================================
-- Default value resolver (module-level; used by init_defaults and spawn)
-- ============================================================

--- Resolve a default descriptor to a Lua runtime value.
---@param d table?  default descriptor {tag, value/name/fields}
---@return any
local function resolve_default(d)
  if not d then return nil end
  if d.tag == "int" or d.tag == "float" or d.tag == "bool" or d.tag == "string" then
    return d.value
  elseif d.tag == "symbol" then
    return d.name
  elseif d.tag == "empty_set" or d.tag == "empty_list" or d.tag == "empty_map" then
    return {}
  elseif d.tag == "record" then
    local r = {}
    if type(d.fields) == "table" then
      for k, v in pairs(d.fields) do r[k] = resolve_default(v) end
    end
    return r
  end
  return nil
end

-- ============================================================
-- Store constructor
-- ============================================================

--- Create a new, empty state store.
---@param schema table  Compiled schema (game_table.schema)
---@param log    table  Transaction log instance (from log.lua)
---@return table
function M.new(schema, log)
  local type_index = build_type_index(schema)

  local store = {
    _cache      = {},
    _schema     = schema or {},
    _type_index = type_index,
    _log        = log,
  }

  -- ── Read ───────────────────────────────────────────────────

  --- Read a path value from the cache.
  ---@param path string
  ---@return any  value or nil if uninstantiated
  function store:get(path)
    return self._cache[path]
  end

  --- Return true if a path is instantiated (not nil).
  ---@param path string
  ---@return boolean
  function store:path_exists(path)
    return self._cache[path] ~= nil
  end

  --- Return a list of all instantiated keys in a family.
  --- e.g. path_list("npcs") → {"blacksmith", "guard"}
  ---@param family string  e.g. "npcs"
  ---@return table
  function store:path_list(family)
    local prefix = family .. "/"
    local seen = {}
    local keys = {}
    for p in pairs(self._cache) do
      if p:sub(1, #prefix) == prefix then
        local rest = p:sub(#prefix + 1)
        local key  = rest:match("^([^/]+)")
        if key and not seen[key] then
          seen[key] = true
          keys[#keys + 1] = key
        end
      end
    end
    return keys
  end

  -- ── Internal log helper ────────────────────────────────────

  local function _log_entry(self, path, old, new_val, fn_name)
    if self._log then
      self._log:append({
        path = path,
        old  = old,
        new  = new_val,
        fn   = fn_name or "?",
      })
    end
  end

  -- ── Scalar mutations ───────────────────────────────────────

  --- Write a value to the cache and append a log entry.
  ---@param path  string
  ---@param value any
  ---@param fn    string?  calling function name
  function store:set(path, value, fn)
    local old = self._cache[path]
    self._cache[path] = value
    _log_entry(self, path, old, value, fn)
  end

  --- Increment a numeric path by amount, clamping to declared Int(min, max).
  ---@param path   string
  ---@param amount number
  ---@param fn     string?
  function store:inc(path, amount, fn)
    local old     = self._cache[path] or 0
    local new_val = old + (amount or 0)
    local td      = lookup_type(self._type_index, path)
    if td and td.tag == "int" then
      if td.min and new_val < td.min then new_val = td.min end
      if td.max and new_val > td.max then new_val = td.max end
    end
    self._cache[path] = new_val
    _log_entry(self, path, old, new_val, fn)
  end

  --- Decrement a numeric path by amount, clamping to declared Int(min, max).
  ---@param path   string
  ---@param amount number
  ---@param fn     string?
  function store:dec(path, amount, fn)
    local old     = self._cache[path] or 0
    local new_val = old - (amount or 0)
    local td      = lookup_type(self._type_index, path)
    if td and td.tag == "int" then
      if td.min and new_val < td.min then new_val = td.min end
      if td.max and new_val > td.max then new_val = td.max end
    end
    self._cache[path] = new_val
    _log_entry(self, path, old, new_val, fn)
  end

  -- ── Collection mutations ───────────────────────────────────

  --- Add a value to a Set at path.  Errors if the set is at max capacity.
  ---@param path  string
  ---@param value any
  ---@param fn    string?
  function store:add(path, value, fn)
    local set = self._cache[path]
    if type(set) ~= "table" then set = {} end
    -- Check for duplicate
    for _, v in ipairs(set) do
      if v == value then return end  -- already present; no-op
    end
    local td = lookup_type(self._type_index, path)
    local max_cap = td and td.max
    if max_cap and #set >= max_cap then
      error("SET_OVERFLOW: Set at " .. path .. " is at capacity (" .. max_cap .. ")")
    end
    local new_set = {}
    for _, v in ipairs(set) do new_set[#new_set + 1] = v end
    new_set[#new_set + 1] = value
    self._cache[path] = new_set
    _log_entry(self, path, set, new_set, fn)
  end

  --- Remove a value from a Set at path.  No-op if absent.
  ---@param path  string
  ---@param value any
  ---@param fn    string?
  function store:remove(path, value, fn)
    local set = self._cache[path]
    if type(set) ~= "table" then return end
    local new_set = {}
    for _, v in ipairs(set) do
      if v ~= value then new_set[#new_set + 1] = v end
    end
    if #new_set == #set then return end  -- not found; no-op
    self._cache[path] = new_set
    _log_entry(self, path, set, new_set, fn)
  end

  --- Empty a Set or List at path.
  ---@param path string
  ---@param fn   string?
  function store:clear(path, fn)
    local old = self._cache[path]
    self._cache[path] = {}
    _log_entry(self, path, old, {}, fn)
  end

  --- Append a value to a List at path.  Errors if the list is at max capacity.
  ---@param path  string
  ---@param value any
  ---@param fn    string?
  function store:push(path, value, fn)
    local list = self._cache[path]
    if type(list) ~= "table" then list = {} end
    local td = lookup_type(self._type_index, path)
    local max_cap = td and td.max
    if max_cap and #list >= max_cap then
      error("LIST_OVERFLOW: List at " .. path .. " is at capacity (" .. max_cap .. ")")
    end
    local new_list = {}
    for _, v in ipairs(list) do new_list[#new_list + 1] = v end
    new_list[#new_list + 1] = value
    self._cache[path] = new_list
    _log_entry(self, path, list, new_list, fn)
  end

  --- Remove and return the last element of a List at path.  Errors if empty.
  ---@param path string
  ---@param fn   string?
  ---@return any  the removed element
  function store:pop(path, fn)
    local list = self._cache[path]
    if type(list) ~= "table" or #list == 0 then
      error("LIST_EMPTY: List at " .. path .. " is empty")
    end
    local new_list = {}
    for i = 1, #list - 1 do new_list[i] = list[i] end
    local popped = list[#list]
    self._cache[path] = new_list
    _log_entry(self, path, list, new_list, fn)
    return popped
  end

  -- ── Entity family mutations ────────────────────────────────

  --- Instantiate a family member with the given key and initial record values.
  --- Errors if the key already exists.
  ---@param family string  e.g. "npcs"
  ---@param key    any     member key (e.g. "blacksmith" or symbol)
  ---@param record table?  initial field values {field=value, ...}
  ---@param fn     string?
  function store:spawn(family, key, record, fn)
    local key_str = tostring(key)
    -- Check uniqueness: look for any path with this family/key prefix
    local prefix = family .. "/" .. key_str
    for p in pairs(self._cache) do
      if p == prefix or p:sub(1, #prefix + 1) == prefix .. "/" then
        error("SPAWN_EXISTS: Family member " .. prefix .. " already exists")
      end
    end
    -- Write each field from the record (or just mark the key as existing)
    local rec = type(record) == "table" and record or {}
    if type(record) == "table" then
      for field, val in pairs(record) do
        if type(field) == "string" then
          local path = family .. "/" .. key_str .. "/" .. field
          self._cache[path] = val
          _log_entry(self, path, nil, val, fn)
        end
      end
    end
    -- Apply type defaults for any fields not explicitly set in the record
    local fam_info = self._type_index["__family__" .. family]
    for _, f in ipairs(fam_info and fam_info.fields or {}) do
      if f.name and rec[f.name] == nil and f.default ~= nil then
        local path = family .. "/" .. key_str .. "/" .. f.name
        local val  = resolve_default(f.default)
        if val ~= nil then
          self._cache[path] = val
          _log_entry(self, path, nil, val, fn)
        end
      end
    end
    -- Write a sentinel to mark the member as instantiated
    local sentinel = family .. "/" .. key_str
    if not self._cache[sentinel] then
      self._cache[sentinel] = true
      _log_entry(self, sentinel, nil, true, fn)
    end
  end

  --- Remove a family member and all its paths.
  ---@param family string
  ---@param key    any
  ---@param fn     string?
  function store:despawn(family, key, fn)
    local key_str = tostring(key)
    local prefix = family .. "/" .. key_str
    -- Collect paths to remove
    local to_remove = {}
    for p in pairs(self._cache) do
      if p == prefix or p:sub(1, #prefix + 1) == prefix .. "/" then
        to_remove[#to_remove + 1] = p
      end
    end
    for _, p in ipairs(to_remove) do
      local old = self._cache[p]
      self._cache[p] = nil
      _log_entry(self, p, old, nil, fn)
    end
  end

  -- ── State initialisation ───────────────────────────────────

  --- Initialise all state paths from their declared defaults in the schema.
  --- Call this once before starting a new game.
  function store:init_defaults()
    for _, s in ipairs(self._schema.states or {}) do
      if s.kind == "scalar" then
        if s.default ~= nil then
          self._cache[s.path] = resolve_default(s.default)
        end

      elseif s.kind == "record" then
        for _, f in ipairs(s.fields or {}) do
          if f.name and f.default ~= nil then
            local path = s.path .. "/" .. f.name
            self._cache[path] = resolve_default(f.default)
          end
        end

      -- Families start empty; members are created via spawn!
      end
    end
  end

  return store
end

return M

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
-- SF-3: Undeclared path write detection (dev mode only)
-- ============================================================

local function warn_undeclared(store, path, op)
  if store._production then return end
  if not store._schema_has_states then return end  -- empty schema: no declarations to check
  if path:sub(1, 2) == "__" then return end  -- engine-internal prefix (e.g. __rel/*)
  if lookup_type(store._type_index, path) == nil then
    local msg = "[WARN] " .. op .. " to undeclared path '" .. path ..
                "' — not found in state schema\n"
    local sink = store._print_sink
    if sink then sink(msg) else io.stderr:write(msg) end
  end
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
  elseif d.tag == "set" or d.tag == "list" then
    local result = {}
    for _, item in ipairs(d.items or {}) do
      result[#result+1] = resolve_default(item)
    end
    return result
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

  -- Build time-axis index from time_model (axis → wrap_at or nil)
  local time_wrap = {}  -- e.g. {hour = 24}
  local tm = schema and schema.time_model
  if tm and tm.axes then
    for i, axis in ipairs(tm.axes) do
      local w = tm.wrap and tm.wrap[i]
      if type(w) == "number" then
        time_wrap[axis] = w
      end
    end
  end

  -- Initialise the engine time clock to zero for all declared axes
  local init_time = {}
  if tm and tm.axes then
    for _, axis in ipairs(tm.axes) do
      init_time[axis] = 0
    end
  end

  local store = {
    _cache              = {},
    _schema             = schema or {},
    _type_index         = type_index,
    _schema_has_states  = next(type_index) ~= nil,  -- cached before actor inbox additions
    _log                = log,
    _time               = init_time,   -- current engine time (e.g. {day=0, hour=0, tick=0})
    _time_wrap          = time_wrap,   -- axis → wrap_at (nil = no wrap)
    _checkpoints        = {},          -- stack of {seq, cache, time} snapshots for undo!
    _production         = false,       -- set by engine to suppress SF-3 dev warnings
    _print_sink         = nil,         -- set by engine to redirect warnings
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

  -- ── Checkpoint stack (for undo!) ───────────────────────────

  --- Deep-copy the cache (table values get a shallow copy via pairs, preserving hash-keyed UMap values).
  local function deep_copy_cache(src)
    local dst = {}
    for k, v in pairs(src) do
      if type(v) == "table" then
        local c = {}; for tk, tv in pairs(v) do c[tk] = tv end
        dst[k] = c
      else
        dst[k] = v
      end
    end
    return dst
  end

  --- Push a checkpoint snapshot (call before executing a checkpoint function body).
  ---@param fn_name string
  function store:push_checkpoint(fn_name)
    local snap_time = {}
    for k, v in pairs(self._time) do snap_time[k] = v end
    self._checkpoints[#self._checkpoints + 1] = {
      fn    = fn_name,
      seq   = self._log and self._log:seq() or 0,
      cache = deep_copy_cache(self._cache),
      time  = snap_time,
    }
    -- Also mark checkpoint boundary in the log
    if self._log then self._log:checkpoint(fn_name) end
  end

  --- Revert state to N checkpoints back; returns true on success, false if none exist.
  ---@param steps integer  default 1
  ---@return boolean
  function store:undo(steps)
    steps = steps or 1
    local n = #self._checkpoints
    if n == 0 then return false end
    local idx = n - steps + 1
    if idx < 1 then idx = 1 end
    local snap = self._checkpoints[idx]
    -- Restore cache (use pairs so hash-keyed UMap values are preserved)
    for k in pairs(self._cache) do self._cache[k] = nil end
    for k, v in pairs(snap.cache) do
      if type(v) == "table" then
        local c = {}; for tk, tv in pairs(v) do c[tk] = tv end
        self._cache[k] = c
      else
        self._cache[k] = v
      end
    end
    -- Restore time
    for k in pairs(self._time) do self._time[k] = 0 end
    for k, v in pairs(snap.time) do self._time[k] = v end
    -- Drop checkpoints at or after this one
    for i = n, idx, -1 do self._checkpoints[i] = nil end
    -- Append undo audit entry
    if self._log then
      self._log:append({
        kind     = "undo",
        fn       = "undo!",
        path     = nil,
        old      = nil,
        ["new"]  = nil,
      })
    end
    return true
  end

  --- Return a sorted list of all instantiated keys in a family.
  --- e.g. path_list("npcs") → {"blacksmith", "guard"}
  --- Sorted lexicographically so iteration order is deterministic.
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
    table.sort(keys)
    return keys
  end

  -- ── Internal log helper ────────────────────────────────────

  local function _log_entry(self, path, old, new_val, fn_name)
    if self._log then
      -- Snapshot current time for the log entry
      local time_snap = nil
      if next(self._time) ~= nil then
        time_snap = {}
        for k, v in pairs(self._time) do time_snap[k] = v end
      end
      self._log:append({
        path = path,
        old  = old,
        new  = new_val,
        fn   = fn_name or "?",
        time = time_snap,
      })
    end
    -- Optional debug mutation hook (set by engine when debug server is active)
    if self._mutation_hook then
      pcall(self._mutation_hook, path, old, new_val, fn_name)
    end
  end

  -- ── Time model ─────────────────────────────────────────────

  --- Return a copy of the current engine time.
  ---@return table  e.g. {day=0, hour=0, tick=5}
  function store:get_time()
    local t = {}
    for k, v in pairs(self._time) do t[k] = v end
    return t
  end

  --- Set the named time axis to an absolute value.
  --- Only updates declared axes; silently ignores undeclared axes to avoid
  --- corrupting the scheduler's comparisons with phantom keys.
  ---@param axis  string  e.g. "tick"
  ---@param value number
  function store:set_time(axis, value)
    if self._time[axis] ~= nil then
      self._time[axis] = value
    end
    -- else: axis not declared in time-model → silently ignore
  end

  --- Advance the named time axis by amount, applying wrap if configured.
  ---@param axis   string  e.g. "tick"
  ---@param amount number
  function store:inc_time(axis, amount)
    local cur = self._time[axis] or 0
    local new_val = cur + amount
    local wrap_at = self._time_wrap[axis]
    if wrap_at then
      new_val = new_val % wrap_at
    end
    self._time[axis] = new_val
  end

  -- ── Scalar mutations ───────────────────────────────────────

  --- Write a value to the cache and append a log entry.
  ---@param path  string
  ---@param value any
  ---@param fn    string?  calling function name
  function store:set(path, value, fn)
    warn_undeclared(self, path, "set!")
    local old = self._cache[path]
    self._cache[path] = value
    _log_entry(self, path, old, value, fn)
  end

  --- Increment a numeric path by amount, clamping to declared Int(min, max).
  ---@param path   string
  ---@param amount number
  ---@param fn     string?
  function store:inc(path, amount, fn)
    warn_undeclared(self, path, "inc!")
    local old     = self._cache[path] or 0
    local attempted = old + (amount or 0)
    local new_val   = attempted
    local td      = lookup_type(self._type_index, path)
    if td and td.tag == "int" then
      if td.min and new_val < td.min then new_val = td.min end
      if td.max and new_val > td.max then new_val = td.max end
    end
    if new_val ~= attempted and self._clamp_hook then
      pcall(self._clamp_hook, path, attempted, new_val, fn)
    end
    self._cache[path] = new_val
    _log_entry(self, path, old, new_val, fn)
  end

  --- Decrement a numeric path by amount, clamping to declared Int(min, max).
  ---@param path   string
  ---@param amount number
  ---@param fn     string?
  function store:dec(path, amount, fn)
    warn_undeclared(self, path, "dec!")
    local old     = self._cache[path] or 0
    local attempted = old - (amount or 0)
    local new_val   = attempted
    local td      = lookup_type(self._type_index, path)
    if td and td.tag == "int" then
      if td.min and new_val < td.min then new_val = td.min end
      if td.max and new_val > td.max then new_val = td.max end
    end
    if new_val ~= attempted and self._clamp_hook then
      pcall(self._clamp_hook, path, attempted, new_val, fn)
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
    warn_undeclared(self, path, "add!")
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
    warn_undeclared(self, path, "remove!")
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
    warn_undeclared(self, path, "clear!")
    local old = self._cache[path]
    self._cache[path] = {}
    _log_entry(self, path, old, {}, fn)
  end

  --- Append a value to a List at path.  Errors if the list is at max capacity.
  ---@param path  string
  ---@param value any
  ---@param fn    string?
  function store:push(path, value, fn)
    warn_undeclared(self, path, "push!")
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
    warn_undeclared(self, path, "pop!")
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
    -- O(1) uniqueness check: a sentinel is always written at family/key on first spawn.
    local prefix = family .. "/" .. key_str
    if self._cache[prefix] ~= nil then
      error("SPAWN_EXISTS: Family member " .. prefix .. " already exists")
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
    -- Optional debug spawn hook
    if self._spawn_hook then
      local init_rec = {}
      for field, val in pairs(rec) do init_rec[field] = val end
      pcall(self._spawn_hook, family, key_str, init_rec, fn)
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
    -- Optional debug despawn hook
    if self._despawn_hook then
      pcall(self._despawn_hook, family, key_str, fn)
    end
  end

  -- ── State initialisation ───────────────────────────────────

  --- Initialise all state paths from their declared defaults in the schema.
  --- Emits log entries for each default so query-at can find initial values.
  --- Call this once before starting a new game.
  function store:init_defaults()
    for _, s in ipairs(self._schema.states or {}) do
      if s.kind == "scalar" then
        if s.default ~= nil then
          local val = resolve_default(s.default)
          self._cache[s.path] = val
          _log_entry(self, s.path, nil, val, "init-defaults")
        end

      elseif s.kind == "record" then
        for _, f in ipairs(s.fields or {}) do
          if f.name and f.default ~= nil then
            local path = s.path .. "/" .. f.name
            local val  = resolve_default(f.default)
            self._cache[path] = val
            _log_entry(self, path, nil, val, "init-defaults")
          end
        end

      -- Families start empty; members are created via spawn!
      end
    end
  end

  return store
end

-- ============================================================
-- Log replay: reconstruct cache from a serialised log
-- ============================================================

--- Replay a deserialized log to reconstruct state on top of defaults.
--- Call `store:init_defaults()` BEFORE replay to establish baseline.
--- Also restores the engine time clock from the last entry that has a time field.
---@param store table  state store (already init_defaults'd)
---@param entries table  list of log entry tables (from log:entries())
-- Entry kinds that are informational only and should not affect state during replay.
local SKIP_ON_REPLAY = {
  checkpoint       = true,
  conflict         = true,
  schedule_fired   = true,
  cancel_schedule  = true,
  schedule_created = true,
}

--- Restore state directly from a snapshot then replay only entries after snapshot.seq.
--- This is faster than full replay for long logs.
---@param store    table  state store (already init_defaults'd)
---@param snapshot table  {seq=N, time={...}, cache={...}} from log.deserialise_snapshot
---@param entries  table  full list of log entries (will skip seq <= snapshot.seq)
function M.replay_from_snapshot(store, snapshot, entries)
  -- Load snapshot cache directly (overwrite defaults)
  for k in pairs(store._cache) do store._cache[k] = nil end
  for k, v in pairs(snapshot.cache) do store._cache[k] = v end
  -- Restore time
  for k in pairs(store._time) do store._time[k] = 0 end
  for k, v in pairs(snapshot.time) do store._time[k] = v end
  -- Replay only delta entries after snapshot.seq
  local delta = {}
  for _, e in ipairs(entries) do
    if e.seq > snapshot.seq then delta[#delta + 1] = e end
  end
  M.replay(store, delta)
end

function M.replay(store, entries)
  for _, e in ipairs(entries) do
    -- Skip metadata-only entries that carry no state mutation.
    if not SKIP_ON_REPLAY[e.kind] and e.path ~= nil then
      -- Apply the mutation: set path to the recorded new value.
      -- e["new"] == nil correctly removes paths (e.g. after despawn).
      store._cache[e.path] = e["new"]
    end
    -- Restore time clock from the most recent entry that has a time field
    if type(e.time) == "table" then
      for k, v in pairs(e.time) do
        store._time[k] = v
      end
    end
  end
end

return M

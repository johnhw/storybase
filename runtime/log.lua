-- runtime/log.lua
-- Transaction log: append-only sequence of mutation records.
--
-- Every mutation — set!, inc!, dec!, collection ops, relate!/unrelate!,
-- send!, spawn!, despawn!, undo!, scene transitions, random draws, bounded
-- computations, and scheduled events — produces a log entry:
--
--   { seq=N, time={day=N,...}, fn="name", path="player/health", old=V, new=V }
--
-- The log is the single source of truth.  Current state is always a
-- projection of all log entries in order.
--
-- Phase 3 deliverable. Not yet implemented.

local M = {}

--- Create a new, empty transaction log.
---@return table
function M.new()
  local log = {
    _entries = {},
    _seq     = 0,
  }

  --- Append a log entry.  Assigns a sequential number automatically.
  ---@param entry table  Must have at least: path, old, new, fn
  function log:append(entry)
    self._seq = self._seq + 1
    entry.seq = self._seq
    self._entries[#self._entries + 1] = entry
  end

  --- Return the current sequence number.
  function log:seq()
    return self._seq
  end

  --- Return all entries as a list (do not modify the returned table).
  function log:entries()
    return self._entries
  end

  --- query-at: return the value of `path` at the given time bound.
  ---
  --- `time` can be:
  ---   number  — treated as a seq bound: return value at the last entry whose seq <= time
  ---   table   — axis table (e.g. {day=3}): return value at the last entry whose recorded
  ---             time satisfies ALL provided axes (entry.time.axis <= time.axis for each axis).
  ---   nil     — return the current value (same as query_history result)
  ---
  ---@param path string
  ---@param time number|table|nil
  ---@return any
  function log:query_at(path, time)
    local result = nil

    if time == nil then
      -- Return latest value
      for _, e in ipairs(self._entries) do
        if e.path == path then result = e.new end
      end
      return result
    end

    if type(time) == "number" then
      -- Seq-based bound
      local bound = math.floor(time)
      for _, e in ipairs(self._entries) do
        if e.seq > bound then break end
        if e.path == path then result = e.new end
      end
      return result
    end

    if type(time) == "table" then
      -- Axis-based bound: include entry if all provided axes satisfy entry.time.axis <= time.axis
      for _, e in ipairs(self._entries) do
        if e.path == path then
          local ok = true
          for axis, bound_val in pairs(time) do
            local entry_val = e.time and e.time[axis]
            if entry_val == nil or entry_val > bound_val then
              ok = false; break
            end
          end
          if ok then result = e.new end
        end
      end
      return result
    end

    return result
  end

  --- query-history: return ordered list of {time, old, new} for path.
  function log:query_history(path, _from, _to)
    local result = {}
    for _, e in ipairs(self._entries) do
      if e.path == path then
        result[#result + 1] = { time = e.time, old = e.old, new = e.new }
      end
    end
    return result
  end

  --- query-changes: return the most recent N changes for path.
  function log:query_changes(path, last_n)
    local all = self:query_history(path, nil, nil)
    local start = math.max(1, #all - (last_n or #all) + 1)
    local result = {}
    for i = start, #all do result[#result + 1] = all[i] end
    return result
  end

  --- Append a checkpoint marker (no path/old/new — just a boundary marker).
  ---@param fn_name string  name of the function being checkpointed
  function log:checkpoint(fn_name)
    self._seq = self._seq + 1
    self._entries[#self._entries + 1] = {
      seq      = self._seq,
      kind     = "checkpoint",
      fn       = fn_name,
      path     = nil,
      old      = nil,
      ["new"]  = nil,
    }
  end

  --- Return the seq number of the most recent checkpoint entry, or nil if none.
  ---@param steps integer  how many checkpoints back (default 1)
  ---@return integer? seq of the target checkpoint entry, or nil
  function log:last_checkpoint_seq(steps)
    steps = steps or 1
    local count = 0
    for i = #self._entries, 1, -1 do
      local e = self._entries[i]
      if e.kind == "checkpoint" then
        count = count + 1
        if count >= steps then return e.seq end
      end
    end
    return nil
  end

  --- Return all mutation entries (kind ~= "checkpoint") strictly after seq_from.
  ---@param seq_from integer  first seq to exclude (inclusive lower bound excluded)
  ---@return table  list of mutation entries
  function log:entries_after(seq_from)
    local result = {}
    for _, e in ipairs(self._entries) do
      if e.seq > seq_from and e.kind ~= "checkpoint" and e.kind ~= "undo" then
        result[#result + 1] = e
      end
    end
    return result
  end

  --- Return all mutation entries at or before `seq_to`.
  ---@param seq_to integer
  ---@return table
  function log:entries_up_to(seq_to)
    local result = {}
    for _, e in ipairs(self._entries) do
      if e.seq <= seq_to and e.kind ~= "checkpoint" and e.kind ~= "undo" then
        result[#result + 1] = e
      end
    end
    return result
  end

  --- Serialise the log to a self-contained Lua chunk (with `return`).
  --- Execute with load() to recover the entries list.
  function log:serialise()
    return "return " .. M.serialise_entries(self._entries)
  end

  return log
end

-- ============================================================
-- Module-level serialise / deserialise helpers
-- ============================================================

--- Render a Lua runtime value as a Lua literal string.
--- Handles: nil, boolean, number, string, array-table, hash-table.
---@param v any
---@return string
local function ser_val(v)
  if v == nil then
    return "nil"
  elseif type(v) == "boolean" then
    return tostring(v)
  elseif type(v) == "number" then
    -- Use %.14g to preserve precision; avoids scientific notation for integers
    return string.format("%.14g", v)
  elseif type(v) == "string" then
    -- Escape backslash, double-quote, and control characters
    local escaped = v
      :gsub("\\", "\\\\")
      :gsub('"',  '\\"')
      :gsub("\n", "\\n")
      :gsub("\r", "\\r")
      :gsub("\0", "\\0")
    return '"' .. escaped .. '"'
  elseif type(v) == "table" then
    local parts = {}
    -- Detect array-like tables (integer keys 1..n, no holes)
    local n = #v
    local is_array = n > 0
    if is_array then
      for i = 1, n do
        parts[#parts + 1] = ser_val(v[i])
      end
    else
      for k, val in pairs(v) do
        if type(k) == "string" then
          parts[#parts + 1] = k .. "=" .. ser_val(val)
        elseif type(k) == "number" then
          parts[#parts + 1] = "[" .. k .. "]=" .. ser_val(val)
        end
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  else
    return "nil"
  end
end

--- Serialise a list of log entries to a Lua table literal string (no `return`).
--- The result is a `{...}` expression suitable for embedding as a value.
--- To get a self-contained chunk, prefix with "return ".
---@param entries table  list of log entry tables
---@return string
function M.serialise_entries(entries)
  local lines = { "{" }
  for _, e in ipairs(entries) do
    local parts = {
      "seq="  .. tostring(e.seq),
      "fn="   .. ser_val(e.fn),
    }
    if e.kind then
      parts[#parts + 1] = "kind=" .. ser_val(e.kind)
    end
    parts[#parts + 1] = "path=" .. ser_val(e.path)
    parts[#parts + 1] = "old="  .. ser_val(e.old)
    parts[#parts + 1] = '["new"]=' .. ser_val(e.new)  -- 'new' is a keyword in older Lua
    if e.time ~= nil then
      parts[#parts + 1] = "time=" .. ser_val(e.time)
    end
    if e.schedule_name ~= nil then
      parts[#parts + 1] = "schedule_name=" .. ser_val(e.schedule_name)
    end
    if e.next_fire ~= nil then
      local nf_parts = {}
      for axis, val in pairs(e.next_fire) do
        nf_parts[#nf_parts + 1] = axis .. "=" .. tostring(val)
      end
      parts[#parts + 1] = "next_fire={" .. table.concat(nf_parts, ",") .. "}"
    end
    if e.fired_axes and #e.fired_axes > 0 then
      local fa_parts = {}
      for i, axis in ipairs(e.fired_axes) do fa_parts[i] = string.format("%q", axis) end
      parts[#parts + 1] = "fired_axes={" .. table.concat(fa_parts, ",") .. "}"
    end
    lines[#lines + 1] = "  {" .. table.concat(parts, ", ") .. "},"
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

-- ============================================================
-- Snapshot: full cache state at a given sequence number
-- ============================================================

--- Serialise a cache snapshot to a Lua chunk string.
--- The snapshot records the full cache, current time, and the seq number
--- at the moment of capture.  On load, only log entries with seq > snapshot.seq
--- need to be replayed.
---@param seq   integer  current log sequence number
---@param cache table    flat path→value cache
---@param time  table    current engine time (e.g. {day=0, tick=5})
---@return string  Lua chunk starting with "return"
function M.serialise_snapshot(seq, cache, time)
  local parts = { "return {\n" }
  parts[#parts + 1] = "  seq=" .. tostring(seq) .. ",\n"
  -- time
  parts[#parts + 1] = "  time={"
  local tparts = {}
  for k, v in pairs(time or {}) do
    tparts[#tparts + 1] = k .. "=" .. tostring(v)
  end
  parts[#parts + 1] = table.concat(tparts, ", ") .. "},\n"
  -- cache
  parts[#parts + 1] = "  cache={\n"
  local paths = {}
  for p in pairs(cache or {}) do paths[#paths + 1] = p end
  table.sort(paths)
  for _, p in ipairs(paths) do
    local v = cache[p]
    -- Use the same ser_val logic via the module-level serialise_entries helper
    -- but we need it inline here.  Use a small local serialiser.
    parts[#parts + 1] = "    [" .. string.format("%q", p) .. "]="
    if type(v) == "nil" then
      parts[#parts + 1] = "nil"
    elseif type(v) == "boolean" then
      parts[#parts + 1] = tostring(v)
    elseif type(v) == "number" then
      parts[#parts + 1] = string.format("%.14g", v)
    elseif type(v) == "string" then
      parts[#parts + 1] = string.format("%q", v)
    elseif type(v) == "table" then
      -- Shallow serialise (arrays only — cache values are sets/lists)
      local ap = {}
      for i, x in ipairs(v) do
        if type(x) == "string" then ap[i] = string.format("%q", x)
        elseif type(x) == "number" then ap[i] = string.format("%.14g", x)
        elseif type(x) == "boolean" then ap[i] = tostring(x)
        else ap[i] = "nil" end
      end
      parts[#parts + 1] = "{" .. table.concat(ap, ",") .. "}"
    else
      parts[#parts + 1] = "nil"
    end
    parts[#parts + 1] = ",\n"
  end
  parts[#parts + 1] = "  },\n"
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

--- Deserialise a snapshot string produced by M.serialise_snapshot().
---@param str string
---@return table  {seq=N, time={...}, cache={...}}
function M.deserialise_snapshot(str)
  local fn, err = load(str)
  if not fn then
    error("log.deserialise_snapshot: parse error: " .. tostring(err))
  end
  local snap = fn()
  if type(snap) ~= "table" then
    error("log.deserialise_snapshot: expected table")
  end
  snap.seq   = snap.seq   or 0
  snap.time  = snap.time  or {}
  snap.cache = snap.cache or {}
  return snap
end

--- Deserialise a log string produced by log:serialise() and return a log instance.
--- str must be a complete Lua chunk (starts with "return").
---@param str string  produced by log:serialise()
---@return table  log instance
function M.deserialise(str)
  local fn, err = load(str)  -- str must be "return {...}"
  if not fn then
    error("log.deserialise: parse error: " .. tostring(err))
  end
  local entries = fn()
  if type(entries) ~= "table" then
    error("log.deserialise: expected table, got " .. type(entries))
  end
  local log = M.new()
  for _, e in ipairs(entries) do
    -- Normalise: "new" may have been stored under the key ["new"]
    if e["new"] == nil and rawget(e, "new") ~= nil then
      e["new"] = rawget(e, "new")
    end
    log._entries[#log._entries + 1] = e
    if type(e.seq) == "number" and e.seq > log._seq then
      log._seq = e.seq
    end
  end
  return log
end

return M

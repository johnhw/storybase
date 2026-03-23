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

  --- query-at: return the value of `path` at the given time.
  ---@param path string
  ---@param time table  Time tuple (e.g. {day=1, tick=5})
  ---@return any
  function log:query_at(path, time)
    local _ = time  -- not yet implemented
    local result = nil
    for _, e in ipairs(self._entries) do
      if e.path == path then
        result = e.new
      end
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

  --- Serialise the log to a string (simple Lua table format).
  function log:serialise()
    -- Not yet implemented
    return ""
  end

  return log
end

return M

-- runtime/state.lua
-- Path store: O(1) read cache backed by the transaction log.
--
-- The state store maintains two representations simultaneously:
--   cache — flat Lua table keyed by path string (e.g. "player/health")
--   log   — see runtime/log.lua (the ground truth)
--
-- Every mutation updates the cache and appends a log entry atomically.
-- Reads always go through the cache and are O(1).
--
-- Phase 3 deliverable. Not yet implemented.

local M = {}

--- Create a new, empty state store.
---@param schema table  Compiled schema (types, defaults, family declarations)
---@param log    table  Transaction log instance (from log.lua)
---@return table
function M.new(schema, log)
  local store = {
    _cache  = {},
    _schema = schema or {},
    _log    = log,
  }

  --- Read a path value from the cache.
  ---@param path string
  ---@return any  value or nil if uninstantiated
  function store:get(path)
    return self._cache[path]
  end

  --- Write a value to the cache and append a log entry.
  ---@param path  string
  ---@param value any
  ---@param fn    string  Name of the calling function (for the log entry)
  function store:set(path, value, fn)
    local old = self._cache[path]
    self._cache[path] = value
    if self._log then
      self._log:append({ path = path, old = old, new = value, fn = fn or "?" })
    end
  end

  --- Return true if a path is instantiated (not nil).
  function store:path_exists(path)
    return self._cache[path] ~= nil
  end

  --- Return a list of all instantiated keys in a family.
  ---@param family string  e.g. "npcs"
  ---@return table
  function store:path_list(family)
    local prefix = family .. "/"
    local seen = {}
    local keys = {}
    for p, _ in pairs(self._cache) do
      if p:sub(1, #prefix) == prefix then
        local rest = p:sub(#prefix + 1)
        local key = rest:match("^([^/]+)")
        if key and not seen[key] then
          seen[key] = true
          keys[#keys + 1] = key
        end
      end
    end
    return keys
  end

  return store
end

return M

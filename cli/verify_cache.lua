-- cli/verify_cache.lua
-- Persistent cache for verify-block results (§C4).
--
-- For each verify block, we compute a hash from:
--   * the verify block's own AST
--   * the schema (types, states, relations) section of the typed game_table
--   * the AST of each fn transitively reachable from the verify
--   * (for BFS-style verifies) the AST of every scene, actor behavior,
--     schedule body, and bounded declaration
--
-- If the hash matches a stored entry, we skip running the verify and reuse
-- the cached verdict. The cache lives at <cache_dir>/verify.json (default:
-- ".storybase-cache/verify.json" relative to cwd).
--
-- Source-line positions are stripped from AST serialisation so reformatting
-- the source does not invalidate the cache.

local M = {}

M.DEFAULT_CACHE_DIR  = ".storybase-cache"
M.CACHE_FILE         = "verify.json"
M.CACHE_VERSION      = 1

-- ─────────────────────────────────────────────────────────────────────────────
-- FNV-1a 64-bit hash (deterministic, no external deps)
-- ─────────────────────────────────────────────────────────────────────────────

local FNV_OFFSET = 0xcbf29ce484222325
local FNV_PRIME  = 0x100000001b3
local U64_MASK   = 0xffffffffffffffff

local function fnv1a_64(s)
  local h = FNV_OFFSET
  for i = 1, #s do
    h = (h ~ s:byte(i)) & U64_MASK
    h = (h * FNV_PRIME) & U64_MASK
  end
  return string.format("%016x", h)
end

M._fnv1a_64 = fnv1a_64

-- ─────────────────────────────────────────────────────────────────────────────
-- Deterministic AST serialisation (skips pos/file fields)
-- ─────────────────────────────────────────────────────────────────────────────

local SKIP_FIELDS = { pos = true, file = true, line = true, col = true }

local function serialize_node(node, sb, depth)
  depth = depth or 0
  if depth > 200 then sb[#sb+1] = "<deep>"; return end
  local t = type(node)
  if node == nil then sb[#sb+1] = "nil"; return end
  if t == "boolean" then sb[#sb+1] = node and "T" or "F"; return end
  if t == "number"  then sb[#sb+1] = tostring(node); return end
  if t == "string"  then
    sb[#sb+1] = "S"
    sb[#sb+1] = tostring(#node)
    sb[#sb+1] = ":"
    sb[#sb+1] = node
    return
  end
  if t ~= "table" then sb[#sb+1] = tostring(node); return end

  -- Collect keys, sort them (string keys then integer keys), skip pos/file/line/col.
  local skeys, ikeys = {}, {}
  for k in pairs(node) do
    if not SKIP_FIELDS[k] then
      if type(k) == "string" then skeys[#skeys+1] = k
      elseif type(k) == "number" then ikeys[#ikeys+1] = k
      end
    end
  end
  table.sort(skeys)
  table.sort(ikeys)

  sb[#sb+1] = "{"
  for _, k in ipairs(skeys) do
    sb[#sb+1] = k
    sb[#sb+1] = "="
    serialize_node(node[k], sb, depth + 1)
    sb[#sb+1] = ";"
  end
  for _, k in ipairs(ikeys) do
    sb[#sb+1] = "["
    sb[#sb+1] = tostring(k)
    sb[#sb+1] = "]="
    serialize_node(node[k], sb, depth + 1)
    sb[#sb+1] = ";"
  end
  sb[#sb+1] = "}"
end

M._serialize_node = serialize_node

-- ─────────────────────────────────────────────────────────────────────────────
-- Dependency analysis: collect all fn names called transitively
-- ─────────────────────────────────────────────────────────────────────────────

local function collect_fn_names(node, into, seen)
  if type(node) ~= "table" then return end
  if seen[node] then return end
  seen[node] = true
  if node.kind == "fn_call" and type(node.name) == "string" then
    into[node.name] = true
  end
  for k, v in pairs(node) do
    if not SKIP_FIELDS[k] and type(v) == "table" then
      collect_fn_names(v, into, seen)
    end
  end
end

--- Compute the transitive closure of fn calls starting from a list of
--- AST nodes (or AST node tables).
local function transitive_fns(start_nodes, all_fns)
  local deps = {}
  local worklist = {}
  for _, n in ipairs(start_nodes) do
    local direct = {}
    collect_fn_names(n, direct, {})
    for name in pairs(direct) do
      if all_fns[name] and not deps[name] then
        deps[name] = true
        worklist[#worklist+1] = name
      end
    end
  end
  while #worklist > 0 do
    local name = table.remove(worklist)
    local fn = all_fns[name]
    if fn then
      local direct = {}
      collect_fn_names(fn, direct, {})
      for callee in pairs(direct) do
        if all_fns[callee] and not deps[callee] then
          deps[callee] = true
          worklist[#worklist+1] = callee
        end
      end
    end
  end
  return deps
end

M._transitive_fns = transitive_fns

--- Decide if a verify block uses BFS exploration.
local function uses_bfs(verify_entry)
  for _, c in ipairs(verify_entry.clauses or {}) do
    if c.kind == "always" or c.kind == "from_any_state"
       or c.kind == "eventually" or c.kind == "always_eventually"
       or c.kind == "until" or c.kind == "requires" then
      return true
    end
  end
  return false
end

M._uses_bfs = uses_bfs

-- ─────────────────────────────────────────────────────────────────────────────
-- Hash computation for a verify block
-- ─────────────────────────────────────────────────────────────────────────────

--- Compute a stable hash for a single verify block.
--- The hash includes everything that could legitimately affect the verify's
--- outcome; editing anything outside that set produces an identical hash so
--- the cached verdict can be reused.
---
---@param verify_entry table  one element of game_table.verifies
---@param game_table   table  full compiled game table
---@return string  hex string (FNV-1a 64-bit)
function M.compute_hash(verify_entry, game_table)
  local sb = {}

  -- 1. Cache schema version (bump to invalidate all caches when format changes).
  sb[#sb+1] = "V" .. tostring(M.CACHE_VERSION) .. ";"

  -- 2. Schema-version of the source.
  if game_table.schema and game_table.schema.version then
    sb[#sb+1] = "SV=" .. tostring(game_table.schema.version) .. ";"
  end

  -- 3. The verify block itself (label + clauses).
  serialize_node({ label = verify_entry.label, clauses = verify_entry.clauses }, sb, 0)

  -- 4. Schema (types, states, relations, engine_config, time_model).
  if game_table.schema then
    serialize_node({
      types         = game_table.schema.types,
      states        = game_table.schema.states,
      relations     = game_table.schema.relations,
      engine_config = game_table.schema.engine_config,
      time_model    = game_table.schema.time_model,
    }, sb, 0)
  end

  -- 5. Transitively-reached fns.
  local start_nodes = {}
  for _, c in ipairs(verify_entry.clauses or {}) do
    start_nodes[#start_nodes+1] = { condition = c.condition, body = c.body }
  end

  local all_fns = game_table.fns or {}
  local needs_bfs = uses_bfs(verify_entry)

  if needs_bfs then
    -- For BFS verifies, the BFS walks every scene's choice bodies, every
    -- actor's behavior, and every schedule body. So those AST chunks (and
    -- their transitive fns) all participate.
    for _, sc in pairs(game_table.scenes or {}) do start_nodes[#start_nodes+1] = sc end
    for _, ac in pairs(game_table.actors or {}) do start_nodes[#start_nodes+1] = ac end
    for _, sh in pairs(game_table.schedules or {}) do start_nodes[#start_nodes+1] = sh end
  end

  local deps = transitive_fns(start_nodes, all_fns)

  -- 6. Add the actual fn bodies (sorted by name for determinism).
  local fn_names = {}
  for n in pairs(deps) do fn_names[#fn_names+1] = n end
  table.sort(fn_names)
  sb[#sb+1] = "fns["
  for _, name in ipairs(fn_names) do
    sb[#sb+1] = name .. "="
    serialize_node(all_fns[name], sb, 0)
    sb[#sb+1] = ";"
  end
  sb[#sb+1] = "]"

  -- 7. For BFS verifies, also include scenes, actors, schedules, bounded.
  if needs_bfs then
    local function dump_sorted(label, tbl)
      sb[#sb+1] = label .. "["
      local names = {}
      for n in pairs(tbl or {}) do names[#names+1] = n end
      table.sort(names)
      for _, n in ipairs(names) do
        sb[#sb+1] = n .. "="
        serialize_node(tbl[n], sb, 0)
        sb[#sb+1] = ";"
      end
      sb[#sb+1] = "]"
    end
    dump_sorted("scenes",    game_table.scenes)
    dump_sorted("actors",    game_table.actors)
    dump_sorted("schedules", game_table.schedules)
    dump_sorted("bounded",   game_table.bounded)
  end

  return fnv1a_64(table.concat(sb))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cache file I/O (JSON via runtime.debug)
-- ─────────────────────────────────────────────────────────────────────────────

local function ensure_dir(path)
  -- mkdir -p semantics; ignore "exists" errors. Compatible with WSL/Linux.
  os.execute("mkdir -p " .. string.format("%q", path) .. " 2>/dev/null")
end

local function cache_path(cache_dir)
  return (cache_dir or M.DEFAULT_CACHE_DIR) .. "/" .. M.CACHE_FILE
end

M.cache_path = cache_path

--- Load the cache from disk. Returns a table { entries = {hash → result}, ... }.
--- Returns an empty cache on first run or if the file is malformed.
function M.load(cache_dir)
  local path = cache_path(cache_dir)
  local f = io.open(path, "r")
  if not f then return { version = M.CACHE_VERSION, entries = {} } end
  local s = f:read("*a"); f:close()
  if not s or #s == 0 then return { version = M.CACHE_VERSION, entries = {} } end

  local debug_mod = require("runtime.debug")
  local ok, data = pcall(debug_mod.decode_json, s)
  if not ok or type(data) ~= "table" then
    return { version = M.CACHE_VERSION, entries = {} }
  end
  if data.version ~= M.CACHE_VERSION then
    return { version = M.CACHE_VERSION, entries = {} }
  end
  if type(data.entries) ~= "table" then data.entries = {} end
  return data
end

--- Save the cache to disk.
function M.save(cache, cache_dir)
  cache_dir = cache_dir or M.DEFAULT_CACHE_DIR
  ensure_dir(cache_dir)
  local path = cache_path(cache_dir)
  local debug_mod = require("runtime.debug")
  local json = debug_mod.encode_json(cache)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(json); f:close()
  return true
end

--- Look up a cached result. Returns the result table or nil.
function M.get(cache, hash)
  if not cache or not cache.entries then return nil end
  return cache.entries[hash]
end

--- Store a result under the given hash.
function M.put(cache, hash, result)
  if not cache.entries then cache.entries = {} end
  -- Strip non-serialisable fields (AST snapshots) before saving.
  cache.entries[hash] = {
    label                            = result.label,
    pass                             = result.pass and true or false,
    fail_msg                         = result.fail_msg,
    states_checked                   = result.states_checked,
    skipped                          = result.skipped and true or nil,
    reason                           = result.reason,
    counterexample_path              = result.counterexample_path,
    counterexample_path_original_len = result.counterexample_path_original_len,
    truncated                        = result.truncated and true or nil,
  }
end

return M

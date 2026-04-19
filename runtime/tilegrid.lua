-- runtime/tilegrid.lua
-- Tile grid algorithms for the optional defgrid extension.
--
-- A grid is a flat Lua array (1-indexed) of cell values where cell (x, y)
-- is stored at index  y * width + x + 1  (x and y are 0-based).
--
-- Public API:
--   M.new(width, height, default)           → cells[]
--   M.idx(width, height, x, y)              → integer or nil (OOB)
--   M.in_bounds(width, height, x, y)        → bool
--   M.get(cells, width, height, x, y)       → value or nil
--   M.set(cells, width, height, x, y, val)  → bool (false = OOB)
--   M.within_range(x1,y1, x2,y2, range, metric?) → bool
--   M.visible_from(cells,w,h, x1,y1, x2,y2, opaque_set?) → bool
--   M.find_path(cells,w,h, x1,y1, x2,y2, blocked_set?, allow_diag?) → list|nil
--   M.occupied_by(state_cache, family, x, y) → key or nil

local M = {}

-- ── Storage helpers ──────────────────────────────────────────────────────────

--- Create a new flat grid array, all cells initialised to default_value.
---@param width        integer  Number of columns (x-extent, must be > 0)
---@param height       integer  Number of rows    (y-extent, must be > 0)
---@param default_value any     Initial cell value
---@return table  Flat 1-indexed array of width*height cells
function M.new(width, height, default_value)
  assert(type(width)  == "number" and width  > 0 and math.floor(width)  == width,
         "tilegrid.new: width must be a positive integer")
  assert(type(height) == "number" and height > 0 and math.floor(height) == height,
         "tilegrid.new: height must be a positive integer")
  local cells = {}
  local n = width * height
  for i = 1, n do cells[i] = default_value end
  return cells
end

--- Compute the 1-based flat index for cell (x, y).
--- Returns nil if (x, y) is outside [0, width-1] × [0, height-1].
---@param width  integer
---@param height integer
---@param x      integer  0-based column
---@param y      integer  0-based row
---@return integer?
function M.idx(width, height, x, y)
  if x < 0 or y < 0 or x >= width or y >= height then return nil end
  return y * width + x + 1
end

--- Return true iff (x, y) lies within the grid.
---@param width  integer
---@param height integer
---@param x      integer  0-based column
---@param y      integer  0-based row
---@return boolean
function M.in_bounds(width, height, x, y)
  return x >= 0 and y >= 0 and x < width and y < height
end

--- Read the cell value at (x, y). Returns nil if out of bounds.
---@param cells  table    Flat cell array
---@param width  integer
---@param height integer
---@param x      integer  0-based column
---@param y      integer  0-based row
---@return any
function M.get(cells, width, height, x, y)
  local i = M.idx(width, height, x, y)
  if not i then return nil end
  return cells[i]
end

--- Write value to cell (x, y). Returns true on success, false if out of bounds.
---@param cells  table    Flat cell array (mutated in-place)
---@param width  integer
---@param height integer
---@param x      integer  0-based column
---@param y      integer  0-based row
---@param value  any
---@return boolean
function M.set(cells, width, height, x, y, value)
  local i = M.idx(width, height, x, y)
  if not i then return false end
  cells[i] = value
  return true
end

-- ── Range check ──────────────────────────────────────────────────────────────

--- Return true if (x2, y2) is within `range` steps of (x1, y1).
---
--- Supported distance metrics:
---   "chebyshev"  (default) — max(|dx|, |dy|) — treats diagonals as 1 step
---   "manhattan"            — |dx| + |dy|
---   "euclidean"            — sqrt(dx²+dy²) ≤ range  (compared squared)
---
---@param x1     integer
---@param y1     integer
---@param x2     integer
---@param y2     integer
---@param range  number   Maximum distance (inclusive)
---@param metric string?  "chebyshev" | "manhattan" | "euclidean"
---@return boolean
function M.within_range(x1, y1, x2, y2, range, metric)
  local dx = math.abs(x2 - x1)
  local dy = math.abs(y2 - y1)
  metric = metric or "chebyshev"
  if metric == "manhattan" then
    return (dx + dy) <= range
  elseif metric == "euclidean" then
    return (dx * dx + dy * dy) <= (range * range)
  else  -- chebyshev
    return math.max(dx, dy) <= range
  end
end

-- ── Line-of-sight (raycasting) ───────────────────────────────────────────────

--- Return true if there is an unobstructed line of sight from (x1,y1) to (x2,y2).
---
--- Uses a float-step ray from the centre of the source cell to the centre of
--- the target cell.  Only intermediate cells are tested for opacity; the
--- source and destination cells are never blocked (a unit can always "see"
--- the tile it is standing on, and can see an opaque destination).
---
--- opaque_set: a table used as a set, e.g. { ["wall"] = true }.
---   If nil (or empty), all cells are transparent and every in-bounds pair
---   is considered visible.
---
---@param cells      table    Flat cell array
---@param width      integer
---@param height     integer
---@param x1         integer  0-based source column
---@param y1         integer  0-based source row
---@param x2         integer  0-based target column
---@param y2         integer  0-based target row
---@param opaque_set table?   {cell_value = true, ...} — values that block LOS
---@return boolean
function M.visible_from(cells, width, height, x1, y1, x2, y2, opaque_set)
  if not M.in_bounds(width, height, x1, y1) then return false end
  if not M.in_bounds(width, height, x2, y2) then return false end
  if x1 == x2 and y1 == y2 then return true end
  if not opaque_set then return true end

  -- Ray from centre of (x1,y1) to centre of (x2,y2).
  -- steps = max(|dx|, |dy|) guarantees we sample at least one point per cell.
  local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1))
  local fx0 = x1 + 0.5
  local fy0 = y1 + 0.5
  local dx  = (x2 - x1) / steps
  local dy  = (y2 - y1) / steps

  for i = 1, steps - 1 do
    local ix = math.floor(fx0 + i * dx)
    local iy = math.floor(fy0 + i * dy)
    local cell = M.get(cells, width, height, ix, iy)
    if cell ~= nil and opaque_set[cell] then return false end
  end
  return true
end

-- ── A* pathfinding ────────────────────────────────────────────────────────────

-- Neighbour direction tables (4- and 8-directional).
local DIRS4 = { {1,0},{-1,0},{0,1},{0,-1} }
local DIRS8 = { {1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1} }

-- Chebyshev heuristic (admissible for 8-directional movement).
local function heuristic(x1, y1, x2, y2)
  return math.max(math.abs(x2 - x1), math.abs(y2 - y1))
end

-- Minimal binary min-heap used as the A* open set.
local function heap_new()  return {} end

local function heap_push(h, node, priority)
  local n = #h + 1
  h[n] = { node = node, p = priority }
  -- Bubble up
  local i = n
  while i > 1 do
    local parent = math.floor(i / 2)
    if h[parent].p > h[i].p then
      h[parent], h[i] = h[i], h[parent]
      i = parent
    else
      break
    end
  end
end

local function heap_pop(h)
  if #h == 0 then return nil end
  local top = h[1].node
  local n = #h
  h[1] = h[n]
  h[n] = nil
  -- Sift down
  local i = 1
  while true do
    local l, r = 2 * i, 2 * i + 1
    local s = i
    if l <= #h and h[l].p < h[s].p then s = l end
    if r <= #h and h[r].p < h[s].p then s = r end
    if s == i then break end
    h[i], h[s] = h[s], h[i]
    i = s
  end
  return top
end

--- Find the shortest path from (x1,y1) to (x2,y2) using A*.
---
--- blocked_set: {cell_value = true, ...} — values that cannot be traversed.
---   If nil, no cells are blocked (only grid bounds restrict movement).
---
--- allow_diag: bool (default true) — whether diagonal moves are permitted.
---   When true, diagonal step cost is 1.414; cardinal step cost is 1.
---   When false, only 4-directional (cardinal) movement is used.
---
--- Returns:
---   A list of {x, y} waypoints from the first step after the start to the
---   destination (inclusive), e.g. {{x=3,y=2},{x=4,y=2}} for a 2-step path.
---   Returns {} (empty list) if start == end.
---   Returns nil if no path exists (destination unreachable).
---
---@param cells       table    Flat cell array
---@param width       integer
---@param height      integer
---@param x1          integer  0-based source column
---@param y1          integer  0-based source row
---@param x2          integer  0-based target column
---@param y2          integer  0-based target row
---@param blocked_set table?   {cell_value = true, ...}
---@param allow_diag  boolean? Default true
---@return table?  List of {x,y} steps, or nil if unreachable
function M.find_path(cells, width, height, x1, y1, x2, y2, blocked_set, allow_diag)
  if not M.in_bounds(width, height, x1, y1) then return nil end
  if not M.in_bounds(width, height, x2, y2) then return nil end
  if x1 == x2 and y1 == y2 then return {} end

  if allow_diag == nil then allow_diag = true end
  local dirs = allow_diag and DIRS8 or DIRS4

  -- Encode a grid position as a unique integer key.
  local function pos_key(x, y) return y * width + x end

  -- Check whether a cell can be traversed.
  local function walkable(x, y)
    if not M.in_bounds(width, height, x, y) then return false end
    if blocked_set then
      local cell = M.get(cells, width, height, x, y)
      if cell ~= nil and blocked_set[cell] then return false end
    end
    return true
  end

  local open     = heap_new()
  local closed   = {}
  local g_score  = {}
  local came_from = {}  -- pos_key → {from_key, x, y}

  local start_key = pos_key(x1, y1)
  local end_key   = pos_key(x2, y2)

  g_score[start_key] = 0
  heap_push(open, { x = x1, y = y1, key = start_key },
            heuristic(x1, y1, x2, y2))

  while true do
    local cur = heap_pop(open)
    if not cur then return nil end  -- open set exhausted — no path

    if cur.key == end_key then
      -- Reconstruct path: follow came_from chain back to start, then reverse.
      local path = {}
      local k = end_key
      while came_from[k] do
        local entry = came_from[k]
        path[#path + 1] = { x = entry.x, y = entry.y }
        k = entry.from_key
      end
      -- Reverse in-place (came_from gives end→start order)
      local lo, hi = 1, #path
      while lo < hi do
        path[lo], path[hi] = path[hi], path[lo]
        lo = lo + 1; hi = hi - 1
      end
      return path
    end

    if not closed[cur.key] then
      closed[cur.key] = true

      for _, d in ipairs(dirs) do
        local nx, ny = cur.x + d[1], cur.y + d[2]
        if walkable(nx, ny) then
          -- Prevent corner-cutting: a diagonal move is blocked when both cardinal
          -- neighbours that form the corner are blocked (e.g. moving NW through
          -- the gap between a wall to the north and a wall to the west).
          if d[1] ~= 0 and d[2] ~= 0 then
            if not walkable(cur.x + d[1], cur.y) and not walkable(cur.x, cur.y + d[2]) then
              goto continue_dirs
            end
          end
          local nk = pos_key(nx, ny)
          if not closed[nk] then
            -- Diagonal cost ≈ √2; cardinal cost = 1
            local step_cost = (d[1] ~= 0 and d[2] ~= 0) and 1.414 or 1.0
            local new_g = g_score[cur.key] + step_cost
            if not g_score[nk] or new_g < g_score[nk] then
              g_score[nk]   = new_g
              came_from[nk] = { from_key = cur.key, x = nx, y = ny }
              heap_push(open, { x = nx, y = ny, key = nk },
                        new_g + heuristic(nx, ny, x2, y2))
            end
          end
        end
        ::continue_dirs::
      end
    end
  end
end

-- ── Occupancy query ──────────────────────────────────────────────────────────

--- Find which entity from `family` occupies position (x, y).
---
--- Searches the flat state cache for members of `family` whose "x" and "y"
--- sub-fields match the query position.  Assumes entity positions are stored
--- under the paths  "family/KEY/x"  and  "family/KEY/y".
---
--- Returns the first matching key string, or nil if the tile is empty.
---
---@param state_cache table   Flat {[path]=value} cache (e.g. store._cache)
---@param family      string  Entity family name (e.g. "npcs")
---@param x           integer 0-based column to query
---@param y           integer 0-based row    to query
---@return string?  Entity key, or nil
function M.occupied_by(state_cache, family, x, y)
  local prefix = family .. "/"
  local plen   = #prefix
  local seen   = {}

  for path in pairs(state_cache) do
    if path:sub(1, plen) == prefix then
      local rest = path:sub(plen + 1)
      -- Extract KEY from "KEY/field" or "KEY" patterns
      local key = rest:match("^([^/]+)/")
      if key and not seen[key] then
        seen[key] = true
        local ex = state_cache[family .. "/" .. key .. "/x"]
        local ey = state_cache[family .. "/" .. key .. "/y"]
        if ex == x and ey == y then
          return key
        end
      end
    end
  end
  return nil
end

return M

-- compiler/types.lua
-- Type representation and state-space size computation.
--
-- Each resolved type is a plain Lua table with a "tag" field indicating
-- whether it is discrete or superficial, plus type-specific fields.
--
-- Phase 1 deliverable (basic type tags and state-space arithmetic).
-- Not yet implemented.

local M = {}

-- Discrete / superficial classification tags
M.DISCRETE    = "discrete"
M.SUPERFICIAL = "superficial"

--- Return true if a resolved type is discrete.
function M.is_discrete(ty)
  return ty and ty.tag == M.DISCRETE
end

--- Return true if a resolved type is superficial.
function M.is_superficial(ty)
  return ty and ty.tag == M.SUPERFICIAL
end

--- Compute the state-space size of a resolved discrete type.
--- Returns a Lua number (may be math.huge for Symbol / unbounded).
---@param ty table  Resolved type table
---@return number
function M.state_space_size(ty)
  if not ty then return 0 end
  local k = ty.kind
  if k == "bool"      then return 2 end
  if k == "int"       then return math.max(0, ty.max - ty.min + 1) end
  if k == "enum"      then return #(ty.values or {}) end
  if k == "symbol"    then return math.huge end  -- untyped Symbol
  if k == "symbol_of" then return ty.family_size or math.huge end
  if k == "option"    then return (ty.inner_size or 1) + 1 end
  if k == "set" then
    -- Σ C(|T|, i) for i = 0..max
    local n = ty.elem_size or 0
    local mx = ty.max or 0
    local total = 0
    local c = 1  -- C(n, 0) = 1
    for i = 0, math.min(mx, n) do
      total = total + c
      if i < n then c = c * (n - i) // (i + 1) end
    end
    return total
  end
  if k == "list" then
    -- (|T| + 1)^max  (each slot can be absent or one of |T| values)
    return ((ty.elem_size or 0) + 1) ^ (ty.max or 0)
  end
  if k == "record"  then return ty.product_size or 1 end
  if k == "variant" then return ty.sum_size or 1 end
  return 0
end

-- ============================================================
-- log2-of-state-space (the "inexact" enumerator)
-- ============================================================
-- For state spaces larger than 2^53, M.state_space_size loses precision
-- (and Lua 5.4 integer multiplication wraps silently). M.state_space_log2
-- works entirely in log space — multiplications become additions, powers
-- become scalar multiplications — so it stays accurate for arbitrarily
-- large finite state spaces (up to log2 ≈ 1e308).
--
-- Conventions:
--   log2(0) = -math.huge   (empty type)
--   log2(1) =  0           (singleton)
--   log2(unbounded) = math.huge

local function safe_log2(x)
  if x == 0 then return -math.huge end
  if x == math.huge then return math.huge end
  return math.log(x, 2)
end

--- log2(2^a + 2^b) — log-sum-exp in base 2.
local function log2_add(a, b)
  if a == -math.huge then return b end
  if b == -math.huge then return a end
  if a == math.huge or b == math.huge then return math.huge end
  if a < b then a, b = b, a end
  local diff = b - a   -- ≤ 0
  if diff < -53 then return a end   -- 2^diff below float precision
  return a + math.log(1 + 2^diff, 2)
end

M._log2 = safe_log2       -- re-exported for codegen
M._log2_add = log2_add

--- Compute log2 of the state-space size of a resolved discrete type.
--- Composite types (option/set/list) read `inner_size` / `elem_size` directly;
--- record/variant read `product_l2` / `sum_l2` (or fall back to log2 of
--- `product_size` / `sum_size`).
---@param ty table  Resolved type table
---@return number   log2(|ty|) as a float
function M.state_space_log2(ty)
  if not ty then return -math.huge end
  local k = ty.kind
  if k == "bool"      then return 1 end
  if k == "int"       then return safe_log2(math.max(0, ty.max - ty.min + 1)) end
  if k == "enum"      then return safe_log2(#(ty.values or {})) end
  if k == "symbol"    then return math.huge end
  if k == "symbol_of" then return ty.family_size and safe_log2(ty.family_size) or math.huge end
  if k == "option" then
    -- inner_size + 1
    local inner_l2 = ty.inner_l2 or safe_log2(ty.inner_size or 1)
    return log2_add(inner_l2, 0)
  end
  if k == "set" then
    local n = ty.elem_size or 0
    local mx = ty.max or 0
    if n == math.huge then return math.huge end
    local upper = math.min(mx, n)
    local log_c = 0                       -- log2(C(n,0)) = 0
    local total_l2 = 0                    -- running log2 of the partial sum
    for i = 1, upper do
      -- log2(C(n,i)) = log2(C(n,i-1)) + log2(n-i+1) - log2(i)
      log_c = log_c + safe_log2(n - i + 1) - safe_log2(i)
      total_l2 = log2_add(total_l2, log_c)
    end
    return total_l2
  end
  if k == "list" then
    local n = ty.elem_size or 0
    local mx = ty.max or 0
    if n == math.huge then return math.huge end
    if mx == 0 then return 0 end
    return mx * safe_log2(n + 1)
  end
  if k == "record" then
    return ty.product_l2 or safe_log2(ty.product_size or 1)
  end
  if k == "variant" then
    return ty.sum_l2 or safe_log2(ty.sum_size or 1)
  end
  return -math.huge
end

return M

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
    return (ty.elem_size or 0 + 1) ^ (ty.max or 0)
  end
  if k == "record"  then return ty.product_size or 1 end
  if k == "variant" then return ty.sum_size or 1 end
  return 0
end

return M

-- runtime/query.lua
-- Find form and relation queries.
--
-- Implements:
--   find family where ... order-by ... limit ... count
--   adjacent?, reachable?, shortest-path, reachable-set, inverse-adjacent?
--
-- Phase 5 deliverable. Not yet implemented.

local M = {}

--- Execute a find query over an entity family.
---
---@param state   table  State store instance
---@param family  string Family name (e.g. "npcs")
---@param clauses table  List of clause tables from the AST
---@return table         List of matching family key strings (or integer for count)
function M.find(state, family, clauses)
  local _ = clauses
  -- Return all instantiated keys as a stub
  return state:path_list(family)
end

--- adjacent?(relation, source) → Set of nodes 1 hop from source.
---@param relation table  Relation data table
---@param source   any    Source node value
---@return table          Set of adjacent nodes
function M.adjacent(relation, source)
  local data = relation and relation.data or {}
  return data[source] or {}
end

--- reachable?(relation, source, target, max_hops?) → Bool.
function M.reachable(relation, source, target, max_hops)
  local _ = relation; local _ = source; local _ = target; local _ = max_hops
  return false  -- not yet implemented
end

--- shortest-path(relation, source, target) → List of nodes.
function M.shortest_path(relation, source, target)
  local _ = relation; local _ = source; local _ = target
  return nil  -- not yet implemented
end

--- reachable-set(relation, source, max_hops?) → Set of reachable nodes.
function M.reachable_set(relation, source, max_hops)
  local _ = relation; local _ = source; local _ = max_hops
  return {}  -- not yet implemented
end

--- inverse-adjacent?(relation, target) → Set of nodes that lead into target.
function M.inverse_adjacent(relation, target)
  local _ = relation; local _ = target
  return {}  -- not yet implemented
end

return M

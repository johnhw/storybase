-- runtime/random.lua
-- Reproducible random sources.
--
-- All random sources produce discrete values, are logged, and are replayable.
-- In exhaustive search mode each random call branches over all possible outcomes
-- weighted by their probabilities.
--
-- Phase 3 deliverable (basic); Phase 5 extends with search branching.

local M = {}

--- Create a new random source with an optional seed.
---@param seed   integer?  RNG seed (nil = use system time)
---@param log    table?    Transaction log instance (nil = no logging)
---@return table
function M.new(seed, log)
  local rng = {
    _seed = seed,
    _log  = log,
  }

  -- Initialise Lua's built-in RNG
  math.randomseed(seed or os.time())

  --- random-bool p: true with probability p (Float, 0–1).
  function rng:bool(p)
    local result = math.random() < p
    if self._log then
      self._log:append({ kind = "random", source = "random-bool", result = result })
    end
    return result
  end

  --- random-int min max: uniform integer in [min, max].
  function rng:int(min, max)
    local result = math.random(min, max)
    if self._log then
      self._log:append({ kind = "random", source = "random-int", result = result })
    end
    return result
  end

  --- random-enum EnumType: uniform draw from enum values list.
  ---@param values table  List of enum value strings
  function rng:enum(values)
    local idx = math.random(1, #values)
    local result = values[idx]
    if self._log then
      self._log:append({ kind = "random", source = "random-enum", result = result })
    end
    return result
  end

  --- random-choice list: uniform draw from a List value.
  ---@param list table  Lua list
  function rng:choice(list)
    local idx = math.random(1, #list)
    local result = list[idx]
    if self._log then
      self._log:append({ kind = "random", source = "random-choice", result = result })
    end
    return result
  end

  --- random-weighted weights list: weighted draw.
  ---@param weights table  List of Floats
  ---@param list    table  Parallel list of values
  function rng:weighted(weights, list)
    local total = 0
    for _, w in ipairs(weights) do total = total + w end
    local r = math.random() * total
    local acc = 0
    for i, w in ipairs(weights) do
      acc = acc + w
      if r <= acc then
        local result = list[i]
        if self._log then
          self._log:append({ kind = "random", source = "random-weighted", result = result })
        end
        return result
      end
    end
    return list[#list]
  end

  return rng
end

return M

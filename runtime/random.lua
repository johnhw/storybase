-- runtime/random.lua
-- Per-instance PCG32 random source.
--
-- All random sources produce discrete values, are logged, and are replayable.
-- In exhaustive search mode each random call branches over all possible outcomes
-- weighted by their probabilities.
--
-- Implementation note (2026-05-14): previously this module called math.randomseed
-- and math.random, mutating Lua's global RNG state. Multiple coexisting engines in
-- one Lua process clobbered each other's seed. This module now uses a PCG32
-- generator (M. O'Neill) with per-instance state, so two engines in the same
-- process are fully independent.
--
-- The implementation uses Lua 5.4 64-bit integer arithmetic. Multiplications wrap
-- modulo 2^64; bit shifts on values ≥ 64 produce 0 (per Lua 5.4 manual). The
-- generator is the standard XSH-RR variant.
--
-- For testing or injection, set `rng:set_provider(fn)` where fn(kind, ...) returns
-- the desired value. kind is one of "uniform", "int", "bool", "enum", "choice",
-- "weighted". A provider that returns nil delegates to the default PCG path.

local M = {}

-- PCG32 constants (O'Neill 2014, pcg-random.org).
local MULT          = 6364136223846793005   -- 0x5851F42D4C957F2D
local DEFAULT_STREAM = 1442695040888963407  -- 0x14057B7EF767814F
local TWO_TO_32     = 4294967296.0          -- 2^32, denominator for uniform float

--- Default seed when the user passes nil. Mixes os.time and os.clock to provide
--- some sub-second entropy. Callers should always pass an explicit seed when
--- replay determinism matters.
local function default_seed()
  local t = os.time()
  local c = os.clock() or 0
  return t * 1000003 + math.floor((c * 1000000) % 1000003)
end

--- Advance the PCG state and return the 32-bit XSH-RR output of the *previous*
--- state. The previous-state convention is critical for the standard PCG output
--- function — do not reorder.
local function pcg_next(rng)
  local old = rng._state
  rng._state = old * MULT + rng._inc                 -- wraps to 64-bit signed
  -- XSH RR output: xorshift then rotate right by top 5 bits of old state.
  local xorshifted = (((old >> 18) ~ old) >> 27) & 0xFFFFFFFF
  local rot        = (old >> 59) & 31
  -- 32-bit rotate-right: ((x >> rot) | (x << ((-rot) & 31))) & 0xFFFFFFFF
  local right = xorshifted >> rot
  local left  = (xorshifted << ((-rot) & 31)) & 0xFFFFFFFF
  return (right | left) & 0xFFFFFFFF
end

--- Initialise PCG state from a seed integer following the reference algorithm.
local function init_state(rng, seed, stream)
  stream      = stream or DEFAULT_STREAM
  rng._state  = 0
  rng._inc    = ((stream << 1) | 1) & 0xFFFFFFFFFFFFFFFF
  pcg_next(rng)
  rng._state  = (rng._state + seed) & 0xFFFFFFFFFFFFFFFF
  pcg_next(rng)
end

--- Create a new random source with an optional seed.
---@param seed   integer?  PCG seed (nil = derived from os.time + os.clock)
---@param log    table?    Transaction log instance (nil = no logging)
---@param stream integer?  PCG stream selector; default DEFAULT_STREAM
---@return table
function M.new(seed, log, stream)
  local rng = {
    _seed     = seed,
    _stream   = stream or DEFAULT_STREAM,
    _state    = 0,
    _inc      = 0,
    _log      = log,
    _provider = nil,  -- optional fn(kind, ...) → value for test injection
  }
  init_state(rng, seed or default_seed(), rng._stream)

  --- Re-seed the generator. Used by save/load to restore RNG state across runs.
  ---@param s integer
  function rng:seed(s)
    self._seed = s
    init_state(self, s, self._stream)
  end

  --- Capture full generator state for save/restore.
  ---@return table  {state=int, inc=int}
  function rng:save_state()
    return { state = self._state, inc = self._inc }
  end

  --- Restore generator state captured by save_state.
  ---@param s table
  function rng:load_state(s)
    self._state = s.state
    self._inc   = s.inc
  end

  --- Install a test/debug provider that intercepts all draws.
  --- The provider is called as fn(kind, ...) where kind ∈
  --- {"uniform", "int", "bool", "enum", "choice", "weighted"}. Returning nil
  --- delegates to the default PCG path for that single call.
  ---@param fn function?  Provider function, or nil to clear
  function rng:set_provider(fn)
    self._provider = fn
  end

  --- Uniform float in [0, 1). Underlies bool and weighted draws.
  ---@return number
  function rng:uniform()
    if self._provider then
      local v = self._provider("uniform")
      if v ~= nil then return v end
    end
    return pcg_next(self) / TWO_TO_32
  end

  --- random-bool p: true with probability p (Float, 0–1).
  function rng:bool(p)
    local result
    if self._provider then
      local v = self._provider("bool", p)
      if v ~= nil then result = v end
    end
    if result == nil then
      result = (pcg_next(self) / TWO_TO_32) < p
    end
    if self._log then
      self._log:append({ kind = "random", source = "random-bool", result = result })
    end
    return result
  end

  --- random-int min max: uniform integer in [min, max].
  function rng:int(min, max)
    local result
    if self._provider then
      local v = self._provider("int", min, max)
      if v ~= nil then result = v end
    end
    if result == nil then
      if max < min then min, max = max, min end
      local range = max - min + 1
      result = min + (pcg_next(self) % range)
    end
    if self._log then
      self._log:append({ kind = "random", source = "random-int", result = result })
    end
    return result
  end

  --- random-enum EnumType: uniform draw from enum values list.
  ---@param values table  List of enum value strings
  function rng:enum(values)
    local result
    if self._provider then
      local v = self._provider("enum", values)
      if v ~= nil then result = v end
    end
    if result == nil then
      local idx = 1 + (pcg_next(self) % #values)
      result = values[idx]
    end
    if self._log then
      self._log:append({ kind = "random", source = "random-enum", result = result })
    end
    return result
  end

  --- random-choice list: uniform draw from a List value.
  ---@param list table  Lua list
  function rng:choice(list)
    local result
    if self._provider then
      local v = self._provider("choice", list)
      if v ~= nil then result = v end
    end
    if result == nil then
      local idx = 1 + (pcg_next(self) % #list)
      result = list[idx]
    end
    if self._log then
      self._log:append({ kind = "random", source = "random-choice", result = result })
    end
    return result
  end

  --- random-weighted weights list: weighted draw.
  ---@param weights table  List of Floats
  ---@param list    table  Parallel list of values
  function rng:weighted(weights, list)
    local result
    if self._provider then
      local v = self._provider("weighted", weights, list)
      if v ~= nil then result = v end
    end
    if result == nil then
      local total = 0
      for _, w in ipairs(weights) do total = total + w end
      local r   = (pcg_next(self) / TWO_TO_32) * total
      local acc = 0
      for i, w in ipairs(weights) do
        acc = acc + w
        if r < acc then result = list[i]; break end
      end
      if result == nil then result = list[#list] end
    end
    if self._log then
      self._log:append({ kind = "random", source = "random-weighted", result = result })
    end
    return result
  end

  return rng
end

return M

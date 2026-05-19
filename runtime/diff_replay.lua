-- runtime/diff_replay.lua
-- H2: Diff-mode hot reload.
--
-- Given a running engine and a freshly compiled game table, re-execute the
-- recorded player choices against the new fn bodies in a throwaway engine and
-- report how the resulting state diverges from the original playthrough.
--
-- Inputs come from the engine's transaction log:
--   * `kind == "choice"` entries (added by engine:do_choice) name the scene
--     and visible-list index of every player action.
--   * `kind == "random"` entries record the value of every recorded random
--     draw, in order. A provider feeds these back into the new engine's RNG
--     so deterministic sources stay aligned across the two runs.
--
-- The original playthrough's per-tick "old" state is reconstructed by walking
-- the log forward and stopping at the seq boundary that ends each tick (the
-- entry just before the next choice marker, or the last entry).
--
-- Output: a list of `{tick, step, path, old_value, new_value}` entries, one
-- per (tick, path) at which the new playthrough first diverges or whose
-- divergent value changes. Paths that re-converge are dropped from the
-- running diff state, so a subsequent re-divergence is reported again.
--
-- Limitations:
--   * Old saves recorded before choice-logging landed have no "choice"
--     entries; the diff for those is empty with `aborted = "no choices"`.
--   * If the new fn body consumes a different number of random draws than
--     the original, the recorded sequence desyncs from that point on. The
--     diff still reports faithfully — it just may grow noisier.
--   * Schema changes are out of scope; use `reload` first.

local M = {}

local function clone_cache(cache)
  local out = {}
  for k, v in pairs(cache) do
    if type(v) == "table" then
      local sub = {}
      for kk, vv in pairs(v) do sub[kk] = vv end
      out[k] = sub
    else
      out[k] = v
    end
  end
  return out
end

local function values_equal(a, b)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return false end
  -- Shallow compare: state cache values are flat sets/lists/maps of scalars.
  for k, v in pairs(a) do
    if b[k] ~= v then return false end
  end
  for k, v in pairs(b) do
    if a[k] ~= v then return false end
  end
  return true
end

--- Walk `entries` and return a fresh cache snapshot reflecting all state
--- mutations up to (and including) seq_inclusive. Built on top of state.replay
--- so the projection rules stay consistent with normal load.
local function project_old_cache(schema, entries, seq_inclusive)
  local state_mod = require("runtime.state")
  local snap_store = state_mod.new(schema)
  snap_store:init_defaults()
  local subset = {}
  for _, e in ipairs(entries) do
    if e.seq <= seq_inclusive then subset[#subset + 1] = e end
  end
  state_mod.replay(snap_store, subset)
  return snap_store._cache, snap_store._time
end

--- Run diff-mode replay.
---@param eng    table   the live engine (its log + state are the "old" playthrough)
---@param new_gt table   freshly compiled game table to test against
---@param opts   table?  optional {max_entries = N, suppress_io = true}
---@return table         { ok = bool, diffs = list, choices_replayed = int,
---                        aborted = string?, final_diff = list }
function M.replay(eng, new_gt, opts)
  opts = opts or {}
  if not eng or not eng._log then
    return { ok = false, error = "no engine or log" }
  end
  if not new_gt then
    return { ok = false, error = "no new game table" }
  end

  local engine_mod = require("runtime.engine")
  local orig_entries = eng._log:entries()

  -- Collect choices and random draws in order.
  local choices = {}
  local randoms = {}
  for _, e in ipairs(orig_entries) do
    if e.kind == "choice" then choices[#choices + 1] = e
    elseif e.kind == "random" then randoms[#randoms + 1] = e end
  end

  -- Build a fresh engine from the new game table. Suppress stdout/stderr so
  -- the replay does not bleed into the host process. Preserve seed so PCG
  -- fall-through (when the random provider runs out) stays aligned with the
  -- original engine's draws.
  local new_opts = {
    seed      = eng._opts and eng._opts.seed,
    max_stack = eng._opts and eng._opts.max_stack,
    io_out    = { write = function() end },
    io_in     = nil,
  }
  local ok_new, new_eng = pcall(engine_mod.new, new_gt, new_opts)
  if not ok_new then
    return { ok = false, error = "engine construction failed: " .. tostring(new_eng) }
  end

  -- Install a random provider that feeds recorded values in order. Calls past
  -- the end of the recorded sequence return nil → fall through to PCG.
  local r_idx = 0
  new_eng._rng:set_provider(function(_kind, ...)
    r_idx = r_idx + 1
    local rec = randoms[r_idx]
    if rec then return rec.result end
    return nil
  end)

  -- Initialise the new engine (defaults, generates, entry-scene). Generates
  -- may consume random draws; the provider is already wired.
  local ok_init, init_err = pcall(function() new_eng:init() end)
  if not ok_init then
    new_eng._rng:set_provider(nil)
    return { ok = false, error = "init failed: " .. tostring(init_err) }
  end

  -- Per-tick boundary helper: tick i covers entries
  --   [choices[i].seq, choices[i+1].seq - 1]   for i < N
  --   [choices[N].seq, max_seq]                for i == N
  local max_seq = eng._log:seq()
  local function seq_end_of_tick(i)
    if i < #choices then return choices[i + 1].seq - 1
    else return max_seq end
  end

  local diffs = {}
  local prev_diff = {}    -- path → {old, new} last reported divergence for this path
  local aborted = nil

  if #choices == 0 then
    -- No recorded inputs; fall back to a final-state diff of init only.
    aborted = "no choices recorded in log"
  end

  for i, c in ipairs(choices) do
    local cur_scene = new_eng:current_scene()
    if cur_scene ~= c.scene then
      aborted = string.format(
        "scene divergence at step %d: expected '%s', got '%s'",
        i, tostring(c.scene), tostring(cur_scene))
      break
    end

    local ok_dc, signal = pcall(function() return new_eng:do_choice(c.scene, c.idx) end)
    if not ok_dc then
      aborted = string.format("choice %d failed: %s", i, tostring(signal))
      break
    end
    pcall(function() new_eng:post_action() end)

    if signal then
      if signal.type == "goto" then pcall(function() new_eng:goto_scene(signal.target) end)
      elseif signal.type == "enter" then pcall(function() new_eng:enter_scene(signal.target) end)
      elseif signal.type == "exit" then pcall(function() new_eng:exit_scene() end) end
    end

    -- Compare new state vs old state at the end of this tick.
    local end_seq = seq_end_of_tick(i)
    local old_cache = project_old_cache(new_gt.schema, orig_entries, end_seq)
    local new_cache = new_eng._state._cache
    local new_tick_num = (new_eng._state._time and new_eng._state._time.tick) or i

    local seen = {}
    for p in pairs(old_cache) do seen[p] = true end
    for p in pairs(new_cache) do seen[p] = true end

    for p in pairs(seen) do
      local o = old_cache[p]
      local n = new_cache[p]
      if not values_equal(o, n) then
        local prev = prev_diff[p]
        if not prev or not values_equal(prev.old, o) or not values_equal(prev.new, n) then
          diffs[#diffs + 1] = {
            step      = i,
            tick      = new_tick_num,
            path      = p,
            old_value = o,
            new_value = n,
          }
          prev_diff[p] = { old = o, new = n }
        end
      else
        prev_diff[p] = nil
      end
    end
  end

  -- Final-state diff: old's final cache (full log) vs new's current cache.
  -- Useful even when partway aborts happened, since it shows the cumulative
  -- divergence as far as the new engine got.
  local final_diff = {}
  local old_final = project_old_cache(new_gt.schema, orig_entries, max_seq)
  local new_final = new_eng._state._cache
  local fseen = {}
  for p in pairs(old_final) do fseen[p] = true end
  for p in pairs(new_final) do fseen[p] = true end
  for p in pairs(fseen) do
    local o = old_final[p]
    local n = new_final[p]
    if not values_equal(o, n) then
      final_diff[#final_diff + 1] = { path = p, old_value = o, new_value = n }
    end
  end

  new_eng._rng:set_provider(nil)

  return {
    ok               = true,
    diffs            = diffs,
    final_diff       = final_diff,
    choices_replayed = #choices - (aborted and 1 or 0),
    aborted          = aborted,
    new_cache        = clone_cache(new_eng._state._cache),
    new_scene_stack  = (function()
      local s = {}
      for _, v in ipairs(new_eng._scene_stack or {}) do s[#s + 1] = v end
      return s
    end)(),
  }
end

return M

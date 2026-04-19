-- cli/cli_cmd.lua
-- Single-step CLI mode for storybase run --cli <save.sbd>
--
-- Usage:
--   lua5.4 cli/main.lua run game.sb --cli save.sbd   (fresh or resume)
--   lua5.4 cli/main.lua run game.sb --cli save.sbd --reset
--
-- Protocol:
--   stdin:  one line per invocation
--     ""        → render current state, no choice (useful for initial probe)
--     "N"       → execute choice N then render next state
--     "q"/"quit"→ clean exit (save preserved)
--     "reset"   → wipe save, reinitialize, render first state
--   stdout: one JSON object
--     {type:"state",  scene, narration, choices, state, done, saved}
--     {type:"done",   scene, narration, state, saved}
--     {type:"error",  message}
--     {type:"quit",   saved}
--
-- Save file format (.sbd):
--   Lua chunk returning {version, scene_stack, entries, checkpoints}
--   Snapshot (.sbd.snap) alongside for fast reload.

local M = {}

local CLI_SAVE_VERSION = 1

-- ── Helpers ────────────────────────────────────────────────────

-- json_out is set per-call to support test capture; see M.run opts.output
local _json_out_dest = nil

local function json_out(tbl)
  local ok, dbg = pcall(require, "runtime.debug")
  if not ok then
    local dest = _json_out_dest or io.stdout
    dest:write('{"type":"error","message":"json encoder unavailable"}\n')
    return
  end
  local dest = _json_out_dest or io.stdout
  dest:write(dbg.encode_json(tbl) .. "\n")
  if dest.flush then dest:flush() end
end

-- Serialise a single cache table (path→value) to Lua source.
local function ser_cache(cache)
  local parts = { "{" }
  local paths = {}
  for p in pairs(cache or {}) do paths[#paths + 1] = p end
  table.sort(paths)
  for _, p in ipairs(paths) do
    local v = cache[p]
    local sv
    local t = type(v)
    if t == "nil" then
      sv = "nil"
    elseif t == "boolean" then
      sv = tostring(v)
    elseif t == "number" then
      sv = string.format("%.14g", v)
    elseif t == "string" then
      sv = string.format("%q", v)
    elseif t == "table" then
      local ap = {}
      for i, x in ipairs(v) do
        local xt = type(x)
        if xt == "string" then ap[i] = string.format("%q", x)
        elseif xt == "number" then ap[i] = string.format("%.14g", x)
        elseif xt == "boolean" then ap[i] = tostring(x)
        else ap[i] = "nil" end
      end
      sv = "{" .. table.concat(ap, ",") .. "}"
    else
      sv = "nil"
    end
    parts[#parts + 1] = "    [" .. string.format("%q", p) .. "]=" .. sv .. ","
  end
  parts[#parts + 1] = "  }"
  return table.concat(parts, "\n")
end

-- Serialise scheduler next_fire state so CLI steps can restore it without
-- needing a cumulative log (each step only saves its own log entries).
local function ser_schedule_state(scheduler)
  local lines = { "{" }
  local names = {}
  for name in pairs(scheduler._static or {}) do names[#names+1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local ss = scheduler._static[name]
    lines[#lines+1] = "  [" .. string.format("%q", name) .. "] = {"
    local nf_parts = {}
    for axis, val in pairs(ss.next_fire or {}) do
      nf_parts[#nf_parts+1] = axis .. "=" .. tostring(val)
    end
    lines[#lines+1] = "    next_fire={" .. table.concat(nf_parts, ",") .. "},"
    local fired_parts = {}
    for axis, v in pairs(ss.fired or {}) do
      if v then fired_parts[#fired_parts+1] = axis .. "=true" end
    end
    lines[#lines+1] = "    fired={" .. table.concat(fired_parts, ",") .. "},"
    lines[#lines+1] = "  },"
  end
  lines[#lines+1] = "}"
  return table.concat(lines, "\n")
end

-- Serialise grid cells to Lua source.
local function ser_grids(grids)
  local lines = { "{" }
  local names = {}
  for name in pairs(grids or {}) do names[#names+1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local g = grids[name]
    local cell_parts = {}
    for i, v in ipairs(g.cells or {}) do
      local t = type(v)
      if t == "string" then cell_parts[i] = string.format("%q", v)
      elseif t == "number" then cell_parts[i] = string.format("%.14g", v)
      elseif t == "boolean" then cell_parts[i] = tostring(v)
      else cell_parts[i] = "nil" end
    end
    lines[#lines+1] = "  [" .. string.format("%q", name) .. "]={" .. table.concat(cell_parts, ",") .. "},"
  end
  lines[#lines+1] = "}"
  return table.concat(lines, "\n")
end

-- Serialise the checkpoint stack to Lua source.
local function ser_checkpoints(checkpoints)
  local lines = { "{" }
  for _, cp in ipairs(checkpoints or {}) do
    local tparts = {}
    for k, v in pairs(cp.time or {}) do
      tparts[#tparts + 1] = k .. "=" .. tostring(v)
    end
    lines[#lines + 1] = "  {"
    lines[#lines + 1] = "    fn=" .. string.format("%q", cp.fn or "") .. ","
    lines[#lines + 1] = "    seq=" .. tostring(cp.seq or 0) .. ","
    lines[#lines + 1] = "    time={" .. table.concat(tparts, ",") .. "},"
    lines[#lines + 1] = "    cache=" .. ser_cache(cp.cache) .. ","
    lines[#lines + 1] = "  },"
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

-- Write full CLI save file (.sbd + .sbd.snap).
local function write_cli_save(path, eng)
  local log_mod = require("runtime.log")

  -- Main save file
  local f, err = io.open(path, "w")
  if not f then
    return false, "cannot write save file: " .. tostring(err)
  end
  f:write("-- StoryBase CLI save (v" .. CLI_SAVE_VERSION .. ")\n")
  f:write("local save = {}\n")
  f:write("save.version = " .. CLI_SAVE_VERSION .. "\n")

  -- Scene stack
  local ss_parts = {}
  for _, s in ipairs(eng._scene_stack) do
    ss_parts[#ss_parts + 1] = string.format("%q", s)
  end
  f:write("save.scene_stack = {" .. table.concat(ss_parts, ", ") .. "}\n")

  -- Log entries
  f:write("save.entries =\n")
  f:write(log_mod.serialise_entries(eng._log:entries()))
  f:write("\n")

  -- Checkpoint stack
  f:write("save.checkpoints =\n")
  f:write(ser_checkpoints(eng._state._checkpoints))
  f:write("\n")

  -- Grid cell state (tile grids mutated by grid-set!)
  f:write("save.grids =\n")
  f:write(ser_grids(eng._grids))
  f:write("\n")

  -- Scheduler state (next_fire per schedule, so thresholds survive across steps)
  f:write("save.schedule_state =\n")
  f:write(ser_schedule_state(eng._scheduler))
  f:write("\n")

  f:write("return save\n")
  f:close()

  -- Snapshot for fast reload
  local snap_path = path .. ".snap"
  local sf, serr = io.open(snap_path, "w")
  if sf then
    sf:write("-- StoryBase CLI snapshot (v" .. CLI_SAVE_VERSION .. ")\n")
    sf:write(log_mod.serialise_snapshot(
      eng._log:seq(), eng._state._cache, eng._state._time))
    sf:close()
  else
    -- Non-fatal: slow reload will still work
    io.stderr:write("storybase: cannot write snapshot: " .. tostring(serr) .. "\n")
  end

  return true
end

-- Read and parse a CLI save file.
local function read_cli_save(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local src = f:read("*a")
  f:close()
  local fn, perr = load(src)
  if not fn then return nil, "parse error: " .. tostring(perr) end
  local ok, data = pcall(fn)
  if not ok then return nil, "exec error: " .. tostring(data) end
  return data
end

-- Restore an engine from a CLI save (entries + snapshot + checkpoints).
local function restore_engine(eng, save_data)
  local log_mod   = require("runtime.log")
  local state_mod = require("runtime.state")

  eng._state:init_defaults()
  eng:init_grids()  -- initialise grids to defaults before replaying mutations

  -- Try snapshot-accelerated restore
  local snap_path = (save_data._path or "") .. ".snap"
  local sf = io.open(snap_path, "r")
  if sf then
    local snap_src = sf:read("*a")
    sf:close()
    local ok, snap = pcall(log_mod.deserialise_snapshot, snap_src)
    if ok and snap then
      state_mod.replay_from_snapshot(eng._state, snap, save_data.entries or {})
    else
      state_mod.replay(eng._state, save_data.entries or {})
    end
  else
    state_mod.replay(eng._state, save_data.entries or {})
  end

  -- Replay schedule state
  eng._scheduler:replay_log(save_data.entries or {}, eng._game.fns)

  -- Restore explicit scheduler next_fire state (overrides replay_log; handles the case
  -- where the schedule fired in a previous CLI step and the current step has no
  -- schedule_fired entry to replay from)
  if save_data.schedule_state then
    for name, ss_data in pairs(save_data.schedule_state) do
      local ss = eng._scheduler._static[name]
      if ss then
        if ss_data.next_fire then
          ss.next_fire = {}
          for axis, val in pairs(ss_data.next_fire) do ss.next_fire[axis] = val end
        end
        if ss_data.fired then
          ss.fired = {}
          for axis, v in pairs(ss_data.fired) do ss.fired[axis] = v end
        end
      end
    end
  end

  -- Restore grid cell state (overrides defaults set by init_grids above)
  if save_data.grids then
    for name, cells in pairs(save_data.grids) do
      local g = eng._grids[name]
      if g then
        for i, v in ipairs(cells) do g.cells[i] = v end
      end
    end
  end

  -- Restore scene stack
  if type(save_data.scene_stack) == "table" and #save_data.scene_stack > 0 then
    eng._scene_stack = {}
    for _, s in ipairs(save_data.scene_stack) do
      eng._scene_stack[#eng._scene_stack + 1] = s
    end
  else
    eng:init()
  end

  -- Restore checkpoint stack
  eng._state._checkpoints = {}
  for _, cp in ipairs(save_data.checkpoints or {}) do
    if type(cp) == "table" then
      -- Deep-copy cache to match push_checkpoint semantics
      local cache_copy = {}
      for k, v in pairs(cp.cache or {}) do
        if type(v) == "table" then
          local c = {}; for i, x in ipairs(v) do c[i] = x end
          cache_copy[k] = c
        else
          cache_copy[k] = v
        end
      end
      local time_copy = {}
      for k, v in pairs(cp.time or {}) do time_copy[k] = v end
      eng._state._checkpoints[#eng._state._checkpoints + 1] = {
        fn    = cp.fn or "",
        seq   = cp.seq or 0,
        cache = cache_copy,
        time  = time_copy,
      }
    end
  end
end

-- Collect all current state values into a flat table for JSON output.
local function collect_state(eng)
  local result = {}
  for k, v in pairs(eng._state._cache) do
    if not k:match("^__") then  -- skip internal keys
      result[k] = v
    end
  end
  return result
end

-- ── Main entry point ───────────────────────────────────────────

--- Run a single CLI step.
---@param game_table table  Compiled game table
---@param save_path  string Path to the .sbd save file
---@param opts       table  {reset, seed, input, output, auto}
---@return integer  exit code (0 = ok, 1 = error)
function M.run(game_table, save_path, opts)
  opts = opts or {}

  local engine_mod = require("runtime.engine")

  -- Wire output destination (default io.stdout; can be overridden for testing)
  _json_out_dest = opts.output or io.stdout

  -- Null I/O for engine (we handle output ourselves via JSON)
  local io_sink = { write = function() end }

  -- ── Reset: delete save file and start fresh ─────────────────
  if opts.reset then
    os.remove(save_path)
    os.remove(save_path .. ".snap")
  end

  -- ── Build engine ─────────────────────────────────────────────
  if opts.seed then math.randomseed(opts.seed) end
  local eng = engine_mod.new(game_table, { io_out = io_sink })
  eng:register_actors_schedules()

  local is_fresh = true
  local save_data, load_err = read_cli_save(save_path)
  if save_data then
    save_data._path = save_path
    restore_engine(eng, save_data)
    is_fresh = false
  elseif not opts.reset then
    -- File not found is expected on first run; other errors are warnings
    local f = io.open(save_path, "r")
    if f then
      f:close()
      io.stderr:write("storybase: warning: could not load save: " .. tostring(load_err) .. "\n")
    end
    eng:init()
  else
    eng:init()
  end

  -- ── Read input ────────────────────────────────────────────────
  local input_src = opts.input  -- string override for testing
  local raw_line
  if input_src ~= nil then
    raw_line = input_src
  else
    raw_line = io.stdin:read("*l") or ""
  end
  raw_line = raw_line:match("^%s*(.-)%s*$")  -- trim

  -- Handle special commands
  if raw_line == "q" or raw_line == "quit" or raw_line == "exit" then
    write_cli_save(save_path, eng)
    json_out({ type = "quit", saved = save_path })
    return 0
  end

  if raw_line == "reset" then
    os.remove(save_path)
    os.remove(save_path .. ".snap")
    eng = engine_mod.new(game_table, { io_out = io_sink })
    eng:register_actors_schedules()
    eng:init()
    raw_line = ""  -- fall through to render
    is_fresh = true
  end

  -- ── Determine current scene ───────────────────────────────────
  local scene_name = eng:current_scene()
  if not scene_name then
    json_out({ type = "error", message = "no current scene" })
    return 1
  end

  -- ── Render scene ──────────────────────────────────────────────
  local narration, choices, nav_signal = eng:render_scene(scene_name)

  -- Follow unconditional navigation (computed -> in scene body)
  while nav_signal do
    if nav_signal.type == "goto" then
      eng:goto_scene(nav_signal.target)
    elseif nav_signal.type == "enter" then
      eng:enter_scene(nav_signal.target)
    elseif nav_signal.type == "exit" then
      eng:exit_scene()
    end
    scene_name = eng:current_scene()
    if not scene_name then break end
    narration, choices, nav_signal = eng:render_scene(scene_name)
  end

  -- Filter empty narration lines (keep non-empty for JSON)
  local narr_lines = {}
  for _, line in ipairs(narration or {}) do
    if line ~= "" then narr_lines[#narr_lines + 1] = line end
  end

  -- ── Execute choice (if input provided) ───────────────────────
  if raw_line ~= "" and not is_fresh then
    local idx = tonumber(raw_line)
    if not idx then
      json_out({ type = "error", message = "invalid input: " .. raw_line })
      return 1
    end
    if not choices or #choices == 0 then
      json_out({ type = "error", message = "no choices available" })
      return 1
    end
    if idx < 1 or idx > #choices then
      json_out({ type = "error",
                 message = string.format("choice %d out of range (1-%d)", idx, #choices) })
      return 1
    end

    -- Execute the chosen action
    local signal = eng:do_choice(scene_name, idx)
    eng:post_action()

    -- NPC speed
    local cfg = game_table.schema and game_table.schema.engine_config
    local npc_speed = tonumber(cfg and cfg["npc-speed"]) or 0
    for _ = 1, npc_speed do eng:post_action() end

    -- Follow scene navigation from the choice
    if signal then
      if signal.type == "goto" then
        eng:goto_scene(signal.target)
      elseif signal.type == "enter" then
        eng:enter_scene(signal.target)
      elseif signal.type == "exit" then
        eng:exit_scene()
      end
    end

    -- Render the resulting scene
    scene_name = eng:current_scene()
    if scene_name then
      narration, choices, nav_signal = eng:render_scene(scene_name)
      while nav_signal do
        if nav_signal.type == "goto" then eng:goto_scene(nav_signal.target)
        elseif nav_signal.type == "enter" then eng:enter_scene(nav_signal.target)
        elseif nav_signal.type == "exit" then eng:exit_scene()
        end
        scene_name = eng:current_scene()
        if not scene_name then break end
        narration, choices, nav_signal = eng:render_scene(scene_name)
      end
      narr_lines = {}
      for _, line in ipairs(narration or {}) do
        if line ~= "" then narr_lines[#narr_lines + 1] = line end
      end
    else
      narr_lines = {}
      choices = {}
    end
  elseif raw_line ~= "" and is_fresh then
    -- Fresh start: if the user provided a number, treat it as the first choice
    local idx = tonumber(raw_line)
    if idx then
      if not choices or #choices == 0 then
        json_out({ type = "error", message = "no choices available on fresh start" })
        return 1
      end
      if idx < 1 or idx > #choices then
        json_out({ type = "error",
                   message = string.format("choice %d out of range (1-%d)", idx, #choices) })
        return 1
      end
      local signal = eng:do_choice(scene_name, idx)
      eng:post_action()
      if signal then
        if signal.type == "goto" then eng:goto_scene(signal.target)
        elseif signal.type == "enter" then eng:enter_scene(signal.target)
        elseif signal.type == "exit" then eng:exit_scene()
        end
      end
      scene_name = eng:current_scene()
      if scene_name then
        narration, choices, nav_signal = eng:render_scene(scene_name)
        while nav_signal do
          if nav_signal.type == "goto" then eng:goto_scene(nav_signal.target)
          elseif nav_signal.type == "enter" then eng:enter_scene(nav_signal.target)
          elseif nav_signal.type == "exit" then eng:exit_scene()
          end
          scene_name = eng:current_scene()
          if not scene_name then break end
          narration, choices, nav_signal = eng:render_scene(scene_name)
        end
        narr_lines = {}
        for _, line in ipairs(narration or {}) do
          if line ~= "" then narr_lines[#narr_lines + 1] = line end
        end
      else
        narr_lines = {}
        choices = {}
      end
    end
  end

  -- ── Save state ────────────────────────────────────────────────
  local ok_save, save_err = write_cli_save(save_path, eng)
  if not ok_save then
    io.stderr:write("storybase: " .. tostring(save_err) .. "\n")
  end

  -- ── Build choice list ─────────────────────────────────────────
  local choice_list = {}
  for i, c in ipairs(choices or {}) do
    choice_list[i] = { index = i, label = c.label }
  end

  -- ── Emit JSON ─────────────────────────────────────────────────
  local done = not scene_name or #choice_list == 0
  local resp = {
    type     = done and "done" or "state",
    scene    = scene_name or "",
    narration = narr_lines,
    choices  = choice_list,
    state    = collect_state(eng),
    done     = done,
    saved    = ok_save and save_path or nil,
  }
  json_out(resp)

  return 0
end

return M

-- cli/serve_api_cmd.lua
-- Stateless HTTP API mode for storybase. (§G2)
--
-- Distinct from the existing --serve / --debug HTTP server (runtime/debug.lua),
-- which keeps a single in-memory engine and supports a browser UI. The serve-api
-- server holds no per-session state: each POST /step request carries the full
-- save log; the server reconstructs the engine, applies the choice, and returns
-- the new save log alongside the rendered scene. Multiple clients can share one
-- server process without interfering.
--
-- Usage:
--   storybase serve-api game.sb [--port N] [--bind addr] [--seed N] [--production]
--
-- Endpoints:
--   GET  /            → plain-text usage page
--   GET  /schema      → JSON: schema/scenes/state-paths summary
--   POST /step        → JSON-in, JSON-out (see below)
--   POST /reset       → alias for /step with {"reset": true}
--   OPTIONS *         → CORS preflight (Access-Control-Allow-*)
--
-- POST /step request:
--   { "save_log":     <opaque from previous response> | null,
--     "choice_index": N | null,        -- 1-based; omit/null = render only
--     "seed":         N | null,        -- only honoured on fresh start (no save_log)
--     "reset":        bool             -- if true, ignore save_log and start fresh
--   }
--
-- POST /step response:
--   { "scene":     "scene-name",
--     "narration": [ {kind, text, speaker?, color?}, ... ],
--     "choices":   [ {index, label}, ... ],
--     "state":     { path: value, ... },
--     "save_log":  <opaque>,
--     "done":      bool,
--     "ended":     "ending-name" | null   -- §F2 ending name when game finished
--   }
--   or on error: { "error": "message" }
--
-- The "save_log" object is opaque to clients: they receive it from one response
-- and send it back unchanged with the next request. Compaction is not exposed
-- by this server; if logs grow large, clients can replay the save through
-- `storybase compact` offline.

local M = {}

-- ── Helpers ───────────────────────────────────────────────────

local function eprintf(fmt, ...)
  io.stderr:write(string.format(fmt, ...))
end

-- Parse argv into {flags, positional}. Mirrors the parser in cli/main.lua but
-- local here so this command can run without re-entering that module.
local BOOL_FLAGS = { production = true }
local function parse_args(args)
  local flags, positional = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      local key = a:sub(3)
      if BOOL_FLAGS[key] then
        flags[key] = true
        i = i + 1
      elseif args[i + 1] and args[i + 1]:sub(1, 2) ~= "--" then
        flags[key] = args[i + 1]
        i = i + 2
      else
        flags[key] = true
        i = i + 1
      end
    else
      positional[#positional + 1] = a
      i = i + 1
    end
  end
  return flags, positional
end

-- ── Engine save/restore over plain Lua tables ─────────────────
--
-- Unlike cli/cli_cmd.lua which writes a Lua chunk to disk, we keep everything
-- as ordinary Lua tables so the JSON encoder can ship them to the client and
-- the JSON decoder can round-trip them. Tables only contain string keys, number
-- values, strings, booleans, and nested tables — all natively JSON-safe.

--- Capture an engine's state into a JSON-ready Lua table.
---@param eng table  engine instance
---@return table     save data
local function save_to_table(eng)
  -- Scene stack: shallow copy
  local scene_stack = {}
  for i, s in ipairs(eng._scene_stack or {}) do scene_stack[i] = s end

  -- Log entries: copy entries; each entry already has only plain values
  local entries = {}
  for i, e in ipairs(eng._log:entries()) do
    -- Shallow-copy each entry so we don't share table identity with the engine
    local copy = {}
    for k, v in pairs(e) do copy[k] = v end
    entries[i] = copy
  end

  -- Checkpoints: cache + time + fn + seq
  local checkpoints = {}
  for i, cp in ipairs(eng._state._checkpoints or {}) do
    local cache_copy = {}
    for k, v in pairs(cp.cache or {}) do
      if type(v) == "table" then
        local c = {}
        for kk, vv in pairs(v) do c[kk] = vv end
        cache_copy[k] = c
      else
        cache_copy[k] = v
      end
    end
    local time_copy = {}
    for k, v in pairs(cp.time or {}) do time_copy[k] = v end
    checkpoints[i] = {
      fn    = cp.fn or "",
      seq   = cp.seq or 0,
      cache = cache_copy,
      time  = time_copy,
    }
  end

  -- Scheduler state (next_fire per static schedule, fired axes set)
  local schedule_state = {}
  for name, ss in pairs(eng._scheduler._static or {}) do
    local nf = {}
    for axis, val in pairs(ss.next_fire or {}) do nf[axis] = val end
    local fired = {}
    for axis, v in pairs(ss.fired or {}) do
      if v then fired[axis] = true end
    end
    schedule_state[name] = { next_fire = nf, fired = fired }
  end

  return {
    version        = 1,
    scene_stack    = scene_stack,
    entries        = entries,
    checkpoints    = checkpoints,
    schedule_state = schedule_state,
  }
end

--- Restore engine state from a save table produced by save_to_table.
---@param eng       table
---@param save_data table
local function restore_from_table(eng, save_data)
  local state_mod = require("runtime.state")

  eng._state:init_defaults()
  eng:init_grids()
  eng:register_actors_schedules()

  -- Replay log entries to rebuild the state cache
  state_mod.replay(eng._state, save_data.entries or {})

  -- Restore log entries so query-history / query-at / query-changes work
  eng._log._entries = {}
  local max_seq = 0
  for _, e in ipairs(save_data.entries or {}) do
    eng._log._entries[#eng._log._entries + 1] = e
    if (e.seq or 0) > max_seq then max_seq = e.seq end
  end
  eng._log._seq = max_seq

  -- Restore scheduler state from the log (handles threshold advances)
  eng._scheduler:replay_log(save_data.entries or {}, eng._game.fns)

  -- Override schedule next_fire from explicit save_data (covers cases where the
  -- schedule fired in a previous step but no schedule_fired entry was recorded
  -- since — same logic as cli_cmd.lua's restore_engine).
  if type(save_data.schedule_state) == "table" then
    for name, ss_data in pairs(save_data.schedule_state) do
      local ss = eng._scheduler._static[name]
      if ss then
        if type(ss_data.next_fire) == "table" then
          ss.next_fire = {}
          for axis, val in pairs(ss_data.next_fire) do
            ss.next_fire[axis] = val
          end
        end
        if type(ss_data.fired) == "table" then
          ss.fired = {}
          for axis, v in pairs(ss_data.fired) do
            if v then ss.fired[axis] = true end
          end
        end
      end
    end
  end

  -- Apply any grid-set! cache entries back into the cells arrays
  eng:apply_grid_cache()

  -- Scene stack
  if type(save_data.scene_stack) == "table" and #save_data.scene_stack > 0 then
    eng._scene_stack = {}
    for _, s in ipairs(save_data.scene_stack) do
      eng._scene_stack[#eng._scene_stack + 1] = s
    end
  else
    -- Fall back to entry scene
    eng:init()
  end

  -- Checkpoint stack
  eng._state._checkpoints = {}
  for _, cp in ipairs(save_data.checkpoints or {}) do
    if type(cp) == "table" then
      local cache_copy = {}
      for k, v in pairs(cp.cache or {}) do
        if type(v) == "table" then
          local c = {}
          for kk, vv in pairs(v) do c[kk] = vv end
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

-- Collect non-internal state paths into a flat table for JSON output.
local function collect_state(eng)
  local out = {}
  for k, v in pairs(eng._state._cache) do
    if not k:match("^__") then out[k] = v end
  end
  return out
end

-- Drop empty narration items (kind="narration" or "say" with empty text).
local function strip_empty_narration(narration)
  local out = {}
  for _, item in ipairs(narration or {}) do
    if item and item.text and item.text ~= "" then
      out[#out + 1] = item
    end
  end
  return out
end

-- Follow chained scene_goto/scene_enter/scene_exit signals returned by
-- render_scene, then re-render. Returns the final narration and choices.
local function chase_nav(eng, narration, choices, nav_signal)
  while nav_signal do
    if     nav_signal.type == "goto"  then eng:goto_scene(nav_signal.target)
    elseif nav_signal.type == "enter" then eng:enter_scene(nav_signal.target)
    elseif nav_signal.type == "exit"  then eng:exit_scene()
    end
    local scene = eng:current_scene()
    if not scene then return narration, choices, nil end
    narration, choices, nav_signal = eng:render_scene(scene)
  end
  return narration, choices, nil
end

-- ── Step kernel ───────────────────────────────────────────────

--- Reconstruct an engine, optionally apply a choice, and serialise the result.
--- Pure with respect to the input `req` and the compiled `game_table`.
---@param game_table table   compiled game
---@param req        table   decoded JSON request body
---@param opts       table?  { default_seed? }
---@return table             response body (JSON-safe)
local function handle_step(game_table, req, opts)
  opts = opts or {}
  local engine_mod = require("runtime.engine")

  local reset_requested = (req.reset == true) or (req.save_log == nil) or (req.save_log == false)

  -- Build engine. Seed only matters on fresh start; replays consume the log.
  local seed
  if reset_requested then
    seed = tonumber(req.seed) or opts.default_seed
  end
  local io_sink = { write = function() end }
  local eng = engine_mod.new(game_table, { io_out = io_sink, seed = seed })

  if reset_requested then
    eng:init()
  else
    if type(req.save_log) ~= "table" then
      return { error = "save_log must be an object or null" }
    end
    local ok, restore_err = pcall(restore_from_table, eng, req.save_log)
    if not ok then
      return { error = "failed to restore save_log: " .. tostring(restore_err) }
    end
  end

  local scene_name = eng:current_scene()
  if not scene_name then
    return { error = "no current scene after restore" }
  end

  -- Render current scene
  local narration, choices, nav_signal = eng:render_scene(scene_name)
  narration, choices = chase_nav(eng, narration, choices, nav_signal)
  scene_name = eng:current_scene() or scene_name

  -- §F2: check for an ending before any choice — covers init-time endings.
  local ended = eng:check_ending()
  if ended then
    narration = eng:_render_ending(ended)
    choices = {}
  end

  -- Apply choice if provided
  local choice_idx = tonumber(req.choice_index)
  if choice_idx and not ended then
    if not choices or #choices == 0 then
      return { error = "no choices available" }
    end
    if choice_idx < 1 or choice_idx > #choices then
      return {
        error = string.format("choice_index %d out of range (1-%d)",
                              choice_idx, #choices)
      }
    end

    local ok_dc, signal_or_err = pcall(eng.do_choice, eng, scene_name, choice_idx)
    if not ok_dc then
      return { error = "do_choice failed: " .. tostring(signal_or_err) }
    end
    local signal = signal_or_err
    eng:post_action()

    -- NPC speed: run N extra autonomous turns per player action
    local cfg = game_table.schema and game_table.schema.engine_config
    local npc_speed = tonumber(cfg and cfg["npc-speed"]) or 0
    for _ = 1, npc_speed do eng:post_action() end

    if signal then
      if     signal.type == "goto"  then eng:goto_scene(signal.target)
      elseif signal.type == "enter" then eng:enter_scene(signal.target)
      elseif signal.type == "exit"  then eng:exit_scene()
      end
    end

    -- Re-render after the choice
    scene_name = eng:current_scene()
    if scene_name then
      narration, choices, nav_signal = eng:render_scene(scene_name)
      narration, choices = chase_nav(eng, narration, choices, nav_signal)
      scene_name = eng:current_scene() or scene_name
    else
      narration, choices = {}, {}
    end

    -- Post-action ending check
    ended = eng:check_ending()
    if ended then
      narration = eng:_render_ending(ended)
      choices = {}
    end
  end

  -- Build choice list with 1-based index
  local choice_list = {}
  for i, c in ipairs(choices or {}) do
    choice_list[i] = { index = i, label = c.label }
  end

  local narr_clean = strip_empty_narration(narration)
  local save_log   = save_to_table(eng)
  local done       = ended ~= nil or scene_name == nil or #choice_list == 0

  return {
    scene     = scene_name or "",
    narration = narr_clean,
    choices   = choice_list,
    state     = collect_state(eng),
    save_log  = save_log,
    done      = done,
    ended     = ended and (ended.name or "") or nil,
  }
end

-- ── HTTP server (self-contained, blocking accept loop) ───────

-- Format the human-readable usage page returned for GET /.
local function usage_page(game_path, port)
  return table.concat({
    "StoryBase HTTP API",
    "==================",
    "",
    "Game:   " .. tostring(game_path),
    "Listen: 127.0.0.1:" .. tostring(port),
    "",
    "Endpoints:",
    "  GET  /         -- this page",
    "  GET  /schema   -- compiled schema summary",
    "  POST /step     -- {save_log?, choice_index?, seed?, reset?}",
    "  POST /reset    -- alias for /step with reset:true",
    "",
    "Send Content-Type: application/json. CORS open to all origins.",
    "",
  }, "\n")
end

local function schema_summary(game_table)
  local sc = game_table.schema or {}
  local states = {}
  for path in pairs(sc.states or {}) do states[#states + 1] = path end
  table.sort(states)
  local scenes = {}
  for name in pairs(game_table.scenes or {}) do scenes[#scenes + 1] = name end
  table.sort(scenes)
  return {
    version          = sc.version,
    type_count       = sc.type_count,
    path_count       = sc.path_count,
    scene_count      = sc.scene_count,
    state_space_size = sc.state_space_size,
    state_space_log2 = sc.state_space_log2,
    entry_scene      = (sc.engine_config or {})["entry-scene"],
    states           = states,
    scenes           = scenes,
  }
end

-- Read up to `length` bytes from a blocking socket. Returns "" on disconnect.
local function recv_exact(sock, length)
  local buf, remaining = {}, length
  while remaining > 0 do
    local data, err, partial = sock:receive(remaining)
    if data then
      buf[#buf + 1] = data
      remaining = 0
    elseif partial and #partial > 0 then
      buf[#buf + 1] = partial
      remaining = remaining - #partial
    else
      return table.concat(buf), err
    end
  end
  return table.concat(buf)
end

-- Read the request headers from a socket (blocking, one line at a time).
local function read_headers(sock)
  local first = sock:receive("*l")
  if not first then return nil, "no request line" end
  first = first:gsub("\r$", "")
  local method, path = first:match("^(%u+)%s+([^%s]+)")
  if not method then return nil, "malformed request line: " .. first end
  path = path:match("^([^?#]+)") or "/"

  local headers = {}
  while true do
    local line = sock:receive("*l")
    if not line then return nil, "headers ended mid-stream" end
    line = line:gsub("\r$", "")
    if line == "" then break end
    local k, v = line:match("^([^:]+):%s*(.+)$")
    if k then headers[k:lower():gsub("%s", "")] = v end
  end
  return { method = method, path = path, headers = headers }
end

local function send_response(sock, status, ctype, body, extra_hdrs)
  local parts = {
    "HTTP/1.1 " .. status,
    "Content-Type: "   .. ctype,
    "Content-Length: " .. #body,
    "Access-Control-Allow-Origin: *",
    "Cache-Control: no-cache",
    "Connection: close",
  }
  if extra_hdrs then
    for _, h in ipairs(extra_hdrs) do parts[#parts + 1] = h end
  end
  local response = table.concat(parts, "\r\n") .. "\r\n\r\n" .. body
  pcall(function() sock:settimeout(5) end)
  pcall(function() sock:send(response) end)
  pcall(function() sock:close() end)
end

-- Handle one connection. Returns nothing (the socket is closed by send_response).
local function handle_connection(sock, ctx)
  local dbg = ctx.dbg
  local req, herr = read_headers(sock)
  if not req then
    send_response(sock, "400 Bad Request", "text/plain", tostring(herr or "bad request"))
    return
  end

  local method = req.method
  local path   = req.path

  if method == "OPTIONS" then
    send_response(sock, "200 OK", "text/plain", "", {
      "Access-Control-Allow-Methods: GET, POST, OPTIONS",
      "Access-Control-Allow-Headers: Content-Type",
    })
    return
  end

  if method == "GET" and path == "/" then
    send_response(sock, "200 OK", "text/plain; charset=utf-8",
                  usage_page(ctx.game_path, ctx.port))
    return
  end

  if method == "GET" and path == "/schema" then
    local body = dbg.encode_json(schema_summary(ctx.game_table))
    send_response(sock, "200 OK", "application/json", body)
    return
  end

  if method == "POST" and (path == "/step" or path == "/reset") then
    local cl = tonumber(req.headers["content-length"]) or 0
    local body = ""
    if cl > 0 then
      body = recv_exact(sock, cl) or ""
    end

    local payload, decode_err
    if body == "" then
      payload = {}
    else
      local ok, val = pcall(dbg.decode_json, body)
      if not ok then
        decode_err = val
      else
        payload = val
      end
    end
    if decode_err then
      send_response(sock, "400 Bad Request", "application/json",
                    dbg.encode_json({ error = "invalid JSON: " .. tostring(decode_err) }))
      return
    end
    if type(payload) ~= "table" or #payload > 0 then
      -- Reject non-tables and JSON arrays. The endpoint expects an object.
      send_response(sock, "400 Bad Request", "application/json",
                    dbg.encode_json({ error = "request body must be a JSON object" }))
      return
    end

    -- /reset is identical to /step with reset:true
    if path == "/reset" then payload.reset = true end

    local ok_step, resp = pcall(handle_step, ctx.game_table, payload,
                                { default_seed = ctx.default_seed })
    if not ok_step then
      send_response(sock, "500 Internal Server Error", "application/json",
                    dbg.encode_json({ error = "step failed: " .. tostring(resp) }))
      return
    end
    local status = resp.error and "400 Bad Request" or "200 OK"
    send_response(sock, status, "application/json", dbg.encode_json(resp))
    return
  end

  send_response(sock, "404 Not Found", "text/plain", "Not Found\n")
end

-- ── Server lifecycle ──────────────────────────────────────────

--- Bind a listening socket and prepare the per-server context. The returned
--- server can be driven either by the blocking `M.serve` loop or, in tests,
--- by repeatedly calling `M.poll`.
---@param game_table table
---@param opts       table  { port, bind, game_path, default_seed, quiet }
---@return table|nil server  server context; nil on failure
---@return string?  err
function M.start(game_table, opts)
  opts = opts or {}
  local port = tonumber(opts.port) or 8080
  local bind = opts.bind or "127.0.0.1"

  local ok_sock, socket = pcall(require, "socket")
  if not ok_sock or not socket then
    return nil, "serve-api requires LuaSocket"
  end
  local ok_dbg, dbg = pcall(require, "runtime.debug")
  if not ok_dbg then
    return nil, "could not load runtime.debug for JSON codec: " .. tostring(dbg)
  end

  local listener, err = socket.tcp()
  if not listener then return nil, "cannot create socket: " .. tostring(err) end
  listener:setoption("reuseaddr", true)
  pcall(function() listener:setoption("reuseport", true) end)

  local bound, berr = listener:bind(bind, port)
  if not bound then
    listener:close()
    return nil, string.format("cannot bind %s:%d: %s", bind, port, tostring(berr))
  end
  local listened, lerr = listener:listen(32)
  if not listened then
    listener:close()
    return nil, string.format("cannot listen on %s:%d: %s",
                              bind, port, tostring(lerr))
  end
  listener:settimeout(0)  -- non-blocking accept

  if not opts.quiet then
    io.stderr:write(string.format("[serve-api] listening on http://%s:%d\n",
                                  bind, port))
    io.stderr:write(string.format("[serve-api] game: %s\n",
                                  tostring(opts.game_path)))
  end

  return {
    listener = listener,
    socket   = socket,
    ctx      = {
      dbg          = dbg,
      game_table   = game_table,
      game_path    = opts.game_path,
      port         = port,
      default_seed = opts.default_seed,
    },
  }
end

--- Accept and handle any pending connections without blocking. Returns the
--- number of connections handled this call.
---@param server table  result of M.start
---@return integer
function M.poll(server)
  local handled = 0
  while true do
    local client = server.listener:accept()
    if not client then break end
    client:settimeout(10)
    local ok, perr = pcall(handle_connection, client, server.ctx)
    if not ok then
      pcall(function() client:close() end)
      eprintf("[serve-api] handler error: %s\n", tostring(perr))
    end
    handled = handled + 1
  end
  return handled
end

--- Close the listening socket. Outstanding connections are already self-closed
--- by handle_connection / send_response.
function M.stop(server)
  if server and server.listener then
    pcall(function() server.listener:close() end)
    server.listener = nil
  end
end

--- Start the serve-api HTTP server. Blocks until the process is killed.
---@param game_table table
---@param opts       table   { port, bind, game_path, default_seed }
---@return integer           exit code (0 on success; 1 if socket setup fails)
function M.serve(game_table, opts)
  local server, err = M.start(game_table, opts)
  if not server then
    eprintf("error: %s\n", tostring(err))
    return 1
  end
  while true do
    M.poll(server)
    if server.socket.sleep then server.socket.sleep(0.01) end
  end
end

--- CLI entry point.  Invoked from cli/main.lua via the dispatcher.
---@param args table  argv slice (everything after the command name)
---@return integer    exit code
function M.run(args)
  local flags, pos_args = parse_args(args)
  local filepath = pos_args[1]
  if not filepath then
    eprintf("error: storybase serve-api: no input file\n")
    return 1
  end

  local ok_c, compiler = pcall(require, "compiler.compiler")
  if not ok_c then
    eprintf("error: could not load compiler: %s\n", tostring(compiler))
    return 1
  end

  local compile_opts = { production = (flags["production"] == true) }
  local game_table, diags = compiler.compile_file(filepath, compile_opts)
  if diags and diags.has_errors and diags:has_errors() then
    for _, d in ipairs(diags.all or {}) do
      if d.level == "error" then
        eprintf("%s:%d:%d: error [%s]: %s\n",
                d.file or "?", d.line or 0, d.col or 0, d.code, d.message)
      end
    end
    eprintf("error: compilation failed; cannot serve\n")
    return 1
  end

  return M.serve(game_table, {
    port         = flags["port"] and tonumber(flags["port"]),
    bind         = flags["bind"],
    game_path    = filepath,
    default_seed = flags["seed"] and tonumber(flags["seed"]),
  })
end

-- Exported for tests
M._save_to_table     = save_to_table
M._restore_from_table = restore_from_table
M._handle_step       = handle_step
M._schema_summary    = schema_summary

return M

-- runtime/debug.lua
-- Debug server: event hooks, watches, command handlers, and optional TCP transport.
--
-- The server can run in two modes:
--   1. Hook-only mode (default): emits events to registered Lua callbacks.
--   2. TCP mode (requires LuaSocket): additionally streams events over a socket.
--
-- Event hooks are used by the engine and state store to emit events. The server
-- evaluates watch/watch-when declarations after each mutation and fires watch
-- events when triggered.
--
-- Accepted commands (all available in hook-only mode):
--   get-state  {pattern}  → {path: value, ...}
--   eval       {expr}     → value (pure expressions only)
--   get-log    {from, to} → log entries
--   time-travel {tick}    → frozen GameState (live state unaffected)
--   set-breakpoint {condition} → id
--   clear-breakpoint {id}
--   reload     {src}      → outcome
--
-- Emitted events (delivered to registered handlers):
--   mutation    {path, old, new, fn, tick}
--   scene-change {from, to, stack, tick}
--   message-sent {actor, msg, tick}
--   schedule-fired {name, tick}
--   fn-call      {name, args, tick}
--   spawn-event  {family, key, init, tick}
--   despawn-event {family, key, tick}
--   clamp-event  {path, attempted, clamped, tick}
--   watch-fired  {label, kind, path?, value, tick}

local M = {}

local DEFAULT_PORT = 7373

-- ============================================================
-- Helpers
-- ============================================================

--- Pattern match: does `path` match `pattern` where `*` is a wildcard segment?
---@param pattern string  e.g. "player/*" or "npcs/*/health" or exact path
---@param path    string
---@return boolean
local function path_matches(pattern, path)
  if pattern == "*" then return true end
  if pattern == path then return true end
  -- Convert pattern to a Lua pattern (escape magic chars, replace * with [^/]+)
  local lp = pattern:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")
  lp = lp:gsub("%*", "[^/]+")
  lp = "^" .. lp .. "$"
  return path:match(lp) ~= nil
end

-- ============================================================
-- Debug server constructor
-- ============================================================

--- Create a new debug server instance.
---@param engine  table    Engine instance
---@param opts    table?   {port, mode} — mode: "hook" | "tcp" (default "hook")
---@return table
function M.new(engine, opts)
  opts = opts or {}

  local srv = {
    _engine      = engine,
    _port        = opts.port or DEFAULT_PORT,
    _mode        = opts.mode or "hook",
    _running     = false,
    _clients     = {},          -- TCP clients (when in tcp mode)
    _breakpoints = {},          -- {id → condition_fn}
    _bp_counter  = 0,
    _watches     = {},          -- {kind, path?, condition?, label}
    _handlers    = {},          -- {event_name → [fn, ...]}
    _tcp_socket  = nil,
  }

  -- ── Event delivery ────────────────────────────────────────

  --- Register a Lua callback to receive a given event type.
  ---@param event_name string
  ---@param fn         function  fn(payload)
  function srv:on(event_name, fn)
    if not self._handlers[event_name] then
      self._handlers[event_name] = {}
    end
    table.insert(self._handlers[event_name], fn)
  end

  --- Emit an event to all registered handlers and connected TCP clients.
  ---@param event_name string
  ---@param payload    table
  function srv:emit(event_name, payload)
    if not self._running then return end
    local hs = self._handlers[event_name] or {}
    for _, fn in ipairs(hs) do
      pcall(fn, payload)
    end
    -- TCP broadcast (if in tcp mode and clients connected)
    if self._mode == "tcp" and #self._clients > 0 then
      local json = M.encode_json({ event = event_name, data = payload })
      self:_broadcast(json .. "\n")
    end
  end

  -- ── Watch evaluation ───────────────────────────────────────

  --- Register a watch-path declaration.
  ---@param path  string
  ---@param label string
  function srv:register_watch(path, label)
    self._watches[#self._watches + 1] = {
      kind  = "path",
      path  = path,
      label = label,
    }
  end

  --- Register a watch-when declaration (condition as compiled AST expr).
  ---@param cond_expr  table   Compiled AST expression
  ---@param label      string
  function srv:register_watch_when(cond_expr, label)
    self._watches[#self._watches + 1] = {
      kind      = "cond",
      cond_expr = cond_expr,
      label     = label,
      _last     = nil,   -- last evaluated result (for edge detection)
    }
  end

  --- Evaluate all watches against the current engine state.
  --- Fires `watch-fired` events for triggered watches.
  function srv:check_watches()
    if not self._running then return end
    local eng = self._engine
    if not eng then return end

    local eval_mod = require("runtime.eval")
    local tick_val = eng._state and eng._state:get("world/tick") or 0

    for _, w in ipairs(self._watches) do
      if w.kind == "path" then
        local val = eng._state and eng._state:get(w.path)
        if val ~= nil then
          self:emit("watch-fired", {
            label = w.label, kind = "path", path = w.path, value = val, tick = tick_val
          })
        end

      elseif w.kind == "cond" then
        local ctx = eval_mod.new_ctx(eng._state, eng._fns, "watch-when")
        local ok, result = pcall(eval_mod.eval_expr, w.cond_expr, ctx)
        local cur = ok and result or false
        -- Fire on positive edge (false→true)
        if cur and not w._last then
          self:emit("watch-fired", {
            label = w.label, kind = "cond", value = true, tick = tick_val
          })
        end
        w._last = cur
      end
    end
  end

  -- ── Command handlers ───────────────────────────────────────

  --- Handle an incoming command.
  ---@param cmd     string  Command name
  ---@param payload table   Command payload
  ---@return table          Response payload
  function srv:handle_command(cmd, payload)
    payload = payload or {}
    local eng = self._engine

    if cmd == "get-state" then
      local pattern = payload.pattern or "*"
      local result  = {}
      if eng and eng._state then
        for path, val in pairs(eng._state._cache) do
          if path_matches(pattern, path) then
            result[path] = val
          end
        end
      end
      return { state = result }

    elseif cmd == "eval" then
      local expr_src = payload.expr
      if not expr_src then return { error = "missing 'expr'" } end
      if not eng then return { error = "no engine" } end

      -- Compile the expression
      local compiler_mod = require("compiler.compiler")
      local ok, gt = pcall(compiler_mod.compile,
        "module _eval version: 1.0 engine-config: entry-scene: _s\n"
        .. "scene _s:\n  * Go\n    -> _s\n"
        .. "fn _expr:\n  " .. expr_src)
      if not ok or not gt then
        return { error = "compile error: " .. tostring(gt) }
      end
      local fn_def = gt.fns and gt.fns["_expr"]
      if not fn_def then return { error = "expression failed to compile" } end

      local eval_mod = require("runtime.eval")
      local ctx = eval_mod.new_ctx(eng._state, eng._fns, "eval")
      local ok2, val = pcall(eval_mod.eval_stmts, fn_def.body, ctx)
      if not ok2 then return { error = tostring(val) } end
      return { value = ctx.retval }

    elseif cmd == "get-log" then
      if not eng then return { entries = {} } end
      local from = payload.from or 1
      local to   = payload.to
      local all  = eng._log:entries()
      local slice = {}
      for i = from, (to or #all) do
        if all[i] then slice[#slice + 1] = all[i] end
      end
      return { entries = slice }

    elseif cmd == "time-travel" then
      local tick = payload.tick
      if not eng or not tick then return { error = "missing 'tick'" } end

      -- Build a replay of the log up to the requested tick
      local state_mod = require("runtime.state")
      local log_mod   = require("runtime.log")
      local snap_log  = log_mod.new()
      local snap_state = state_mod.new(
        eng._game and eng._game.schema or {}, snap_log)
      snap_state:init_defaults()

      -- Replay all entries with time ≤ tick
      for _, e in ipairs(eng._log:entries()) do
        local etime = type(e.time) == "table" and e.time.tick or 0
        if etime <= tick then
          snap_state._cache[e.path] = e["new"]
        else
          break
        end
      end

      -- Return a frozen snapshot (table of path→value)
      local frozen = {}
      for k, v in pairs(snap_state._cache) do frozen[k] = v end
      return { snapshot = frozen, tick = tick }

    elseif cmd == "set-breakpoint" then
      local cond = payload.condition
      if not cond then return { error = "missing 'condition'" } end
      self._bp_counter = self._bp_counter + 1
      local id = self._bp_counter
      self._breakpoints[id] = cond
      return { id = id }

    elseif cmd == "clear-breakpoint" then
      local id = payload.id
      self._breakpoints[id] = nil
      return { ok = true }

    elseif cmd == "reload" then
      local src = payload.src
      if not src then return { error = "missing 'src'" } end
      if not eng then return { error = "no engine" } end

      local compiler_mod = require("compiler.compiler")
      local ok, new_gt = pcall(compiler_mod.compile, src)
      if not ok or not new_gt then
        return { ok = false, error = tostring(new_gt) }
      end

      -- Hot-reload: update fns and scenes in place, preserve state
      eng._fns   = new_gt.fns   or {}
      eng._scenes = new_gt.scenes or {}
      eng._game  = new_gt
      return { ok = true }

    else
      return { error = "unknown command: " .. tostring(cmd) }
    end
  end

  -- ── Server lifecycle ───────────────────────────────────────

  --- Start the debug server.
  function srv:start()
    self._running = true
    if self._mode == "tcp" then
      local ok, socket = pcall(require, "socket")
      if ok and socket then
        local s, err = socket.tcp()
        if not s then
          io.stderr:write("storybase debug: cannot create socket: "
                          .. tostring(err) .. "\n")
          self._mode = "hook"; return
        end
        s:setoption("reuseaddr", true)
        local bound, berr = s:bind("*", self._port)
        if not bound then
          io.stderr:write("storybase debug: cannot bind port "
                          .. self._port .. ": " .. tostring(berr) .. "\n")
          s:close(); self._mode = "hook"; return
        end
        s:listen(8)
        s:settimeout(0)
        self._tcp_socket = s
        io.stderr:write("storybase debug: listening on port "
                        .. self._port .. "\n")
      else
        io.stderr:write("storybase debug: LuaSocket not available; TCP disabled\n")
        self._mode = "hook"
      end
    end
  end

  --- Stop the debug server.
  function srv:stop()
    self._running = false
    for _, c in ipairs(self._clients) do
      pcall(function() c:close() end)
    end
    self._clients = {}
    if self._tcp_socket then
      pcall(function() self._tcp_socket:close() end)
      self._tcp_socket = nil
    end
  end

  --- Broadcast a message to all connected TCP clients.
  ---@param msg string
  function srv:_broadcast(msg)
    local live = {}
    for _, c in ipairs(self._clients) do
      local ok = pcall(function() c:send(msg) end)
      if ok then live[#live + 1] = c end
    end
    self._clients = live
  end

  --- Accept one pending TCP connection (non-blocking poll).
  --- Reads pending lines from all clients and dispatches commands.
  function srv:poll()
    if not self._running or not self._tcp_socket then return end
    -- Accept new clients (non-blocking)
    local client = self._tcp_socket:accept()
    while client do
      client:settimeout(0)
      self._clients[#self._clients + 1] = client
      client = self._tcp_socket:accept()
    end
    -- Read lines from existing clients
    local live = {}
    for _, c in ipairs(self._clients) do
      local line, err = c:receive("*l")
      if line then
        local ok_dec, payload = pcall(M.decode_json, line)
        if ok_dec and type(payload) == "table" then
          local cmd = payload.cmd
          payload.cmd = nil  -- remove cmd from payload before passing
          local resp = self:handle_command(tostring(cmd), payload)
          pcall(function() c:send(M.encode_json(resp) .. "\n") end)
        end
        live[#live + 1] = c
      elseif err == "timeout" then
        live[#live + 1] = c  -- still alive, just no data
      end
      -- err == "closed" or other → drop client
    end
    self._clients = live
  end

  return srv
end

-- ============================================================
-- Minimal JSON encoder (no external dependency)
-- ============================================================

--- Encode a Lua value as a JSON string.
--- Handles nil, boolean, number, string, array table, object table.
---@param v any
---@return string
function M.encode_json(v)
  local t = type(v)
  if v == nil then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    if v ~= v then return "null" end  -- NaN
    return tostring(v)
  elseif t == "string" then
    -- Escape special characters
    local s = v:gsub('\\', '\\\\')
               :gsub('"',  '\\"')
               :gsub('\n', '\\n')
               :gsub('\r', '\\r')
               :gsub('\t', '\\t')
    return '"' .. s .. '"'
  elseif t == "table" then
    -- Detect array vs object: array if all keys are consecutive integers from 1
    local is_array = true
    local n = 0
    for k in pairs(v) do
      n = n + 1
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
        is_array = false; break
      end
    end
    if is_array and n == #v then
      local parts = {}
      for _, item in ipairs(v) do
        parts[#parts + 1] = M.encode_json(item)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        parts[#parts + 1] = M.encode_json(tostring(k)) .. ":" .. M.encode_json(val)
      end
      table.sort(parts)  -- stable output
      return "{" .. table.concat(parts, ",") .. "}"
    end
  else
    return '"' .. tostring(v) .. '"'
  end
end

-- ============================================================
-- Minimal JSON decoder
-- ============================================================

--- Decode a JSON string into a Lua value.
--- Handles null, boolean, number, string, array, and object.
--- Raises an error on invalid JSON.
---@param s string
---@return any
function M.decode_json(s)
  local pos = 1

  local function skip_ws()
    pos = s:match("^%s*()", pos)
  end

  local decode_val  -- forward
  local function decode_string()
    assert(s:sub(pos, pos) == '"', "expected '\"'")
    pos = pos + 1
    local buf = {}
    while pos <= #s do
      local c = s:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(buf)
      elseif c == '\\' then
        pos = pos + 1
        local esc = s:sub(pos, pos)
        pos = pos + 1
        if     esc == '"'  then buf[#buf+1] = '"'
        elseif esc == '\\' then buf[#buf+1] = '\\'
        elseif esc == '/'  then buf[#buf+1] = '/'
        elseif esc == 'n'  then buf[#buf+1] = '\n'
        elseif esc == 'r'  then buf[#buf+1] = '\r'
        elseif esc == 't'  then buf[#buf+1] = '\t'
        elseif esc == 'b'  then buf[#buf+1] = '\b'
        elseif esc == 'f'  then buf[#buf+1] = '\f'
        elseif esc == 'u'  then
          -- \uXXXX → skip (convert to ?)
          buf[#buf+1] = '?'; pos = pos + 4
        else
          buf[#buf+1] = esc
        end
      else
        -- collect a run of plain chars
        local run_end = s:find('[\\"]', pos) or (#s + 1)
        buf[#buf+1] = s:sub(pos, run_end - 1)
        pos = run_end
      end
    end
    error("unterminated string")
  end

  local function decode_array()
    assert(s:sub(pos, pos) == '[', "expected '['")
    pos = pos + 1
    local arr = {}
    skip_ws()
    if s:sub(pos, pos) == ']' then pos = pos + 1; return arr end
    while true do
      skip_ws()
      arr[#arr+1] = decode_val()
      skip_ws()
      local c = s:sub(pos, pos)
      if c == ']' then pos = pos + 1; return arr end
      assert(c == ',', "expected ',' in array")
      pos = pos + 1
    end
  end

  local function decode_object()
    assert(s:sub(pos, pos) == '{', "expected '{'")
    pos = pos + 1
    local obj = {}
    skip_ws()
    if s:sub(pos, pos) == '}' then pos = pos + 1; return obj end
    while true do
      skip_ws()
      local key = decode_string()
      skip_ws()
      assert(s:sub(pos, pos) == ':', "expected ':' after key")
      pos = pos + 1
      skip_ws()
      obj[key] = decode_val()
      skip_ws()
      local c = s:sub(pos, pos)
      if c == '}' then pos = pos + 1; return obj end
      assert(c == ',', "expected ',' in object")
      pos = pos + 1
    end
  end

  decode_val = function()
    skip_ws()
    local c = s:sub(pos, pos)
    if c == '"' then
      return decode_string()
    elseif c == '[' then
      return decode_array()
    elseif c == '{' then
      return decode_object()
    elseif s:sub(pos, pos+3) == "true" then
      pos = pos + 4; return true
    elseif s:sub(pos, pos+4) == "false" then
      pos = pos + 5; return false
    elseif s:sub(pos, pos+3) == "null" then
      pos = pos + 4; return nil
    else
      -- number
      local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      assert(num_str, "unexpected token at pos " .. pos .. ": " .. s:sub(pos, pos+10))
      pos = pos + #num_str
      return tonumber(num_str)
    end
  end

  local val = decode_val()
  return val
end

return M

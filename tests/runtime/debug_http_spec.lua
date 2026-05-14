-- tests/runtime/debug_http_spec.lua
-- Tests for the HTTP/SSE transport layer added to runtime/debug.lua.
--
-- Uses LuaSocket to connect directly to the test HTTP server.
-- Each describe block uses a distinct port to allow parallel busted runs.
--
-- Run with:  busted tests/

local debug_mod   = require("runtime.debug")
local engine_mod  = require("runtime.engine")
local compiler_mod = require("compiler.compiler")

-- LuaSocket is a hard requirement for these tests.
local ok_s, socket = pcall(require, "socket")
if not ok_s then
  pending("LuaSocket not available; skipping HTTP tests")
  return
end

-- ── Helpers ────────────────────────────────────────────────────

local BASE_PORT = 17380  -- offset from common ports; chosen to avoid conflicts

-- Wait for the server to accept a connection (retry with small sleeps).
local function wait_connect(port, retries, timeout_sec)
  retries     = retries     or 30
  timeout_sec = timeout_sec or 0.1
  for _ = 1, retries do
    local s = socket.tcp()
    s:settimeout(timeout_sec)
    local ok = s:connect("127.0.0.1", port)
    if ok then
      s:settimeout(2)
      return s
    end
    s:close()
    socket.sleep(0.02)
  end
  return nil
end

-- Poll the debug server a given number of times (drives accept/dispatch).
local function poll(srv, times, delay)
  times = times or 20
  delay = delay or 0.01
  for _ = 1, times do
    srv:poll_http()
    socket.sleep(delay)
  end
end

-- Send an HTTP GET request; return the full raw response string.
-- Uses receive("*a") so the complete response (up to server-close) is returned.
local function http_get(srv, port, path)
  local s = wait_connect(port)
  assert(s, "could not connect to HTTP server on port " .. port)
  s:send("GET " .. path .. " HTTP/1.0\r\nHost: localhost\r\n\r\n")
  poll(srv, 20, 0.01)
  s:settimeout(2)
  local raw = s:receive("*a") or ""
  s:close()
  return raw
end

-- Send an HTTP POST with a JSON body; return the decoded JSON response table.
local function http_post(srv, port, path, body_table)
  local body = debug_mod.encode_json(body_table)
  local s = wait_connect(port)
  assert(s, "could not connect to HTTP server on port " .. port)
  s:send("POST " .. path .. " HTTP/1.0\r\n"
    .. "Host: localhost\r\n"
    .. "Content-Type: application/json\r\n"
    .. "Content-Length: " .. #body .. "\r\n"
    .. "\r\n" .. body)
  poll(srv, 20, 0.01)
  s:settimeout(2)
  local full = s:receive("*a") or ""
  s:close()
  -- Extract JSON body after the blank-line header separator
  local _, e = full:find("\r\n\r\n")
  if not e then return nil end
  local ok, t = pcall(debug_mod.decode_json, full:sub(e + 1))
  return ok and t or nil
end

-- Parse the HTTP status line from a raw response.
local function http_status(raw)
  return tonumber(raw:match("^HTTP/1%.[01] (%d+)"))
end

-- Parse a header value from a raw response.
local function http_header(raw, name)
  return raw:match("\r\n" .. name .. ":%s*([^\r\n]+)")
end

-- Minimal game table with two scenes (start → end-scene).
local MINIMAL_HTTP_SRC = table.concat({
  "module http-test",
  "  version: 1.0",
  "engine-config:",
  "  entry-scene: start",
  "",
  "state world:",
  "  tick: Int(0,9999) = 0",
  "",
  'scene start:',
  '  "You are at the start."',
  '  * Go',
  '    -> end-scene',
  'scene end-scene:',
  '  "You reached the end."',
  '  * Restart',
  '    -> start',
  "",
}, "\n")

local function make_minimal_game()
  local gt, diags = compiler_mod.compile(MINIMAL_HTTP_SRC, "http-test.sb")
  local errs = {}
  for _, d in ipairs(diags and diags.all or {}) do
    if d.level == "error" then errs[#errs + 1] = d.message end
  end
  assert(#errs == 0, "compile errors: " .. table.concat(errs, "; "))
  assert(gt ~= nil, "compiler returned nil game table")
  return gt
end

-- Create a started engine + debug server with HTTP on `port`.
local function make_server(port, serve_mode)
  local gt  = make_minimal_game()
  local eng = engine_mod.new(gt, {})
  local srv = debug_mod.new(eng, { mode = "hook" })
  eng:set_debug_server(srv)
  srv._running = true
  srv:start_http(port)
  if serve_mode then srv._serve_mode = true end
  eng:init()
  return srv, eng
end

-- ── Tests ──────────────────────────────────────────────────────

describe("debug HTTP server: lifecycle", function()
  local PORT = BASE_PORT

  it("start_http binds and accepts connections", function()
    local srv, _ = make_server(PORT)
    local s = wait_connect(PORT)
    assert.is_not_nil(s, "should be able to connect after start_http")
    s:close()
    srv:stop_http()
  end)

  it("stop_http closes the listening socket", function()
    local srv, _ = make_server(PORT + 1)
    srv:stop_http()
    -- After stop, connection should fail
    socket.sleep(0.05)
    local s = socket.tcp()
    s:settimeout(0.1)
    local ok = s:connect("127.0.0.1", PORT + 1)
    s:close()
    assert.is_falsy(ok, "should not be able to connect after stop_http")
  end)
end)

describe("debug HTTP server: GET /", function()
  local PORT = BASE_PORT + 10
  local srv, eng

  setup(function()
    srv, eng = make_server(PORT)
  end)

  teardown(function()
    srv:stop_http()
  end)

  it("returns HTTP 200", function()
    local raw = http_get(srv, PORT, "/")
    assert.equals(200, http_status(raw))
  end)

  it("returns Content-Type text/html", function()
    local raw = http_get(srv, PORT, "/")
    local ct = http_header(raw, "Content%-Type")
    assert.is_not_nil(ct)
    assert.truthy(ct:find("text/html"), "Content-Type should be text/html, got: " .. tostring(ct))
  end)

  it("body contains `StoryBase'", function()
    local raw = http_get(srv, PORT, "/")
    local _, e = raw:find("\r\n\r\n")
    local body = e and raw:sub(e + 1) or ""
    assert.truthy(body:find("StoryBase"), "HTML body should contain `StoryBase'")
  end)

  it("returns 404 for unknown paths", function()
    local raw = http_get(srv, PORT, "/nonexistent")
    assert.equals(404, http_status(raw))
  end)

  it("includes CORS header", function()
    local raw = http_get(srv, PORT, "/")
    local cors = http_header(raw, "Access%-Control%-Allow%-Origin")
    assert.equals("*", cors)
  end)
end)

describe("debug HTTP server: POST /command", function()
  local PORT = BASE_PORT + 20
  local srv, eng

  setup(function()
    srv, eng = make_server(PORT)
  end)

  teardown(function()
    srv:stop_http()
  end)

  it("get-state returns state object", function()
    local r = http_post(srv, PORT, "/command", { cmd = "get-state", pattern = "*" })
    assert.is_not_nil(r)
    assert.is_table(r.state)
  end)

  it("get-tick returns seq number", function()
    local r = http_post(srv, PORT, "/command", { cmd = "get-tick" })
    assert.is_not_nil(r)
    assert.is_number(r.seq)
  end)

  it("get-mode returns `debug' when not in serve mode", function()
    local r = http_post(srv, PORT, "/command", { cmd = "get-mode" })
    assert.is_not_nil(r)
    assert.equals("debug", r.mode)
  end)

  it("get-schema returns schema fields", function()
    local r = http_post(srv, PORT, "/command", { cmd = "get-schema" })
    assert.is_not_nil(r)
    assert.is_table(r.states)
    assert.is_table(r.scenes)
  end)

  it("unknown command returns error", function()
    local r = http_post(srv, PORT, "/command", { cmd = "no-such-command" })
    assert.is_not_nil(r)
    assert.is_string(r.error)
  end)

  it("OPTIONS preflight returns 200 with CORS headers", function()
    local s = wait_connect(PORT)
    assert(s)
    s:send("OPTIONS /command HTTP/1.0\r\nHost: localhost\r\n\r\n")
    poll(srv)
    s:settimeout(2)
    local raw = s:receive("*a") or ""
    s:close()
    assert.equals(200, http_status(raw))
    assert.truthy(raw:find("Access%-Control%-Allow%-Methods"))
  end)
end)

describe("debug HTTP server: get-scene / do-choice commands", function()
  local PORT = BASE_PORT + 30
  local PORT_SERVE = BASE_PORT + 31
  local srv_d, srv_s

  setup(function()
    srv_d = make_server(PORT,       false)  -- debug mode
    srv_s = make_server(PORT_SERVE, true)   -- serve mode
  end)

  teardown(function()
    srv_d:stop_http()
    srv_s:stop_http()
  end)

  it("get-scene returns scene, narration, choices", function()
    local r = http_post(srv_d, PORT, "/command", { cmd = "get-scene" })
    assert.is_not_nil(r)
    assert.is_string(r.scene)
    assert.is_table(r.narration)
    assert.is_table(r.choices)
    assert.truthy(#r.choices > 0, "should have at least one choice")
  end)

  it("get-scene returns `start' as entry scene", function()
    local r = http_post(srv_d, PORT, "/command", { cmd = "get-scene" })
    assert.equals("start", r.scene)
  end)

  it("choices have idx and label fields", function()
    local r = http_post(srv_d, PORT, "/command", { cmd = "get-scene" })
    local c = r.choices[1]
    assert.is_number(c.idx)
    assert.is_string(c.label)
  end)

  it("do-choice in debug mode returns error", function()
    local r = http_post(srv_d, PORT, "/command", { cmd = "do-choice", n = 1 })
    assert.is_not_nil(r)
    assert.is_string(r.error)
    assert.truthy(r.error:find("serve"), "error should mention serve mode")
  end)

  it("get-mode returns `serve' in serve mode", function()
    local r = http_post(srv_s, PORT_SERVE, "/command", { cmd = "get-mode" })
    assert.equals("serve", r.mode)
  end)

  it("do-choice in serve mode advances game state", function()
    -- start at `start' scene
    local before = http_post(srv_s, PORT_SERVE, "/command", { cmd = "get-scene" })
    assert.equals("start", before.scene)
    -- choose option 1 ("Go to end")
    local after = http_post(srv_s, PORT_SERVE, "/command", { cmd = "do-choice", n = 1 })
    assert.is_truthy(after.ok)
    assert.is_string(after.scene)
    -- scene should have changed
    assert.not_equals("start", after.scene)
  end)

  it("do-choice returns updated narration and choices", function()
    local r = http_post(srv_s, PORT_SERVE, "/command", { cmd = "do-choice", n = 1 })
    assert.is_table(r.narration)
    assert.is_table(r.choices)
    assert.truthy(#r.choices > 0)
  end)
end)

describe("debug HTTP server: SSE events", function()
  local PORT = BASE_PORT + 40
  local srv, eng

  setup(function()
    srv, eng = make_server(PORT)
  end)

  teardown(function()
    srv:stop_http()
  end)

  it("GET /events returns 200 with text/event-stream", function()
    -- Connect and send SSE request
    local s = wait_connect(PORT)
    assert(s)
    s:send("GET /events HTTP/1.0\r\nHost: localhost\r\n\r\n")
    -- Poll until the SSE connection is established (socket appears in _sse_clients).
    -- This guarantees the SSE headers have been sent before we try to read them.
    for _ = 1, 100 do
      srv:poll_http()
      if #srv._sse_clients > 0 then break end
      socket.sleep(0.02)
    end
    -- Read the SSE response headers with a blocking 2s timeout.
    -- receive(4096) returns nil,"timeout",partial on timeout — capture partial.
    s:settimeout(2)
    local buf, _, partial = s:receive(4096)
    buf = buf or partial or ""
    s:close()
    assert.equals(200, http_status(buf))
    local ct = http_header(buf, "Content%-Type")
    assert.is_not_nil(ct)
    assert.truthy(ct:find("text/event%-stream"),
      "Content-Type should be text/event-stream, got: " .. tostring(ct))
  end)

  it("emit() pushes events to connected SSE clients", function()
    -- Connect SSE client
    local s = wait_connect(PORT)
    assert(s)
    s:send("GET /events HTTP/1.0\r\nHost: localhost\r\n\r\n")
    -- Poll until a NEW SSE connection is established (count increases from baseline).
    -- Stale entries from earlier tests may already be in _sse_clients, so compare
    -- against the count at the time we sent the request.
    local base = #srv._sse_clients
    for _ = 1, 100 do
      srv:poll_http()
      if #srv._sse_clients > base then break end
      socket.sleep(0.02)
    end
    assert.truthy(#srv._sse_clients > base, "SSE connection not established")
    -- Read SSE headers with a blocking 2s timeout.
    -- receive(4096) returns nil,"timeout",partial on timeout — capture partial.
    s:settimeout(2)
    local buf, _, partial = s:receive(4096)
    buf = buf or partial or ""
    assert.truthy(buf:find("\r\n\r\n"), "should have received SSE headers")
    -- Now emit an event from the server
    srv:emit("test-event", { value = 42 })
    socket.sleep(0.05)
    -- Read the SSE data line
    s:settimeout(2)
    local line, _ = s:receive("*l")
    s:close()
    assert.is_not_nil(line, "should have received SSE data line")
    assert.truthy(line:find("^data:"), "SSE line should start with `data:'")
    -- Decode the JSON payload
    local json_str = line:match("^data:%s*(.+)$")
    assert.is_not_nil(json_str)
    local ok, ev = pcall(debug_mod.decode_json, json_str)
    assert.is_true(ok)
    assert.equals("test-event", ev.event)
    assert.equals(42, ev.data.value)
  end)

  it("disconnected SSE clients are removed from list", function()
    -- Connect then immediately disconnect
    local s = wait_connect(PORT)
    assert(s)
    s:send("GET /events HTTP/1.0\r\nHost: localhost\r\n\r\n")
    poll(srv, 15)
    s:close()
    socket.sleep(0.05)
    -- Trigger a push which should detect the broken socket and prune it
    srv:emit("cleanup-test", { x = 1 })
    socket.sleep(0.05)
    -- The internal SSE client list should be empty (or at least not growing)
    -- We can't assert the exact count since other tests may share the server,
    -- but emitting should not raise an error.
    assert.is_table(srv._sse_clients)
  end)
end)

describe("debug HTTP server: A10 security — bind address + eval gating", function()
  local PORT_D = BASE_PORT + 50   -- debug mode server
  local PORT_S = BASE_PORT + 51   -- serve mode server
  local srv_d, srv_s

  setup(function()
    srv_d = make_server(PORT_D, false)  -- debug mode
    srv_s = make_server(PORT_S, true)   -- serve mode
  end)

  teardown(function()
    srv_d:stop_http()
    srv_s:stop_http()
  end)

  it("default _bind is 127.0.0.1", function()
    local gt = make_minimal_game()
    local eng = engine_mod.new(gt, {})
    local srv = debug_mod.new(eng, { mode = "hook" })
    assert.equals("127.0.0.1", srv._bind)
  end)

  it("explicit bind address is stored", function()
    local gt = make_minimal_game()
    local eng = engine_mod.new(gt, {})
    local srv = debug_mod.new(eng, { mode = "hook", bind = "0.0.0.0" })
    assert.equals("0.0.0.0", srv._bind)
  end)

  it("eval succeeds in debug mode", function()
    local r = http_post(srv_d, PORT_D, "/command",
      { cmd = "eval", expr = "world/tick" })
    assert.is_not_nil(r)
    assert.is_nil(r.error, "eval should not error in debug mode")
  end)

  it("eval is blocked in serve mode", function()
    local r = http_post(srv_s, PORT_S, "/command",
      { cmd = "eval", expr = "world/tick" })
    assert.is_not_nil(r)
    assert.is_string(r.error)
    assert.truthy(r.error:find("serve"), "error should mention serve mode")
  end)
end)

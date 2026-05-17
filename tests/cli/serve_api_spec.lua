-- tests/cli/serve_api_spec.lua
-- Tests for the §G2 stateless HTTP API command.
--
-- Split into:
--   1. handle_step kernel tests (in-process, no socket)
--   2. End-to-end HTTP tests using a real LuaSocket client driving the
--      non-blocking server via M.poll(). Each describe block picks a unique
--      port so tests can run in parallel.

local compiler   = require("compiler.compiler")
local serve_api  = require("cli.serve_api_cmd")
local debug_mod  = require("runtime.debug")

local ok_sock, socket = pcall(require, "socket")
if not ok_sock then
  pending("LuaSocket not available; skipping serve-api tests")
  return
end

-- ── Common helpers ─────────────────────────────────────────────

local function compile(path)
  local gt, diags = compiler.compile_file(path)
  assert(not (diags and diags:has_errors()),
         "compile errors in " .. path)
  return gt
end

local DEMO01 = compile("demos/demo01_wanderer.sb")

-- ── handle_step kernel tests ───────────────────────────────────

describe("serve-api: handle_step kernel", function()
  it("fresh start returns entry scene with choices", function()
    local r = serve_api._handle_step(DEMO01, { reset = true })
    assert.is_nil(r.error)
    assert.equals("village", r.scene)
    assert.is_table(r.choices)
    assert.is_truthy(#r.choices > 0)
    assert.is_table(r.narration)
    assert.is_table(r.save_log)
    assert.is_false(r.done)
  end)

  it("null save_log is treated as a fresh start", function()
    local r = serve_api._handle_step(DEMO01, { save_log = nil })
    assert.is_nil(r.error)
    assert.equals("village", r.scene)
  end)

  it("choice advances scene", function()
    local r1 = serve_api._handle_step(DEMO01, { reset = true })
    local r2 = serve_api._handle_step(DEMO01,
                 { save_log = r1.save_log, choice_index = 1 })
    assert.is_nil(r2.error)
    assert.not_equals(r1.scene, r2.scene)
  end)

  it("survives JSON round-trip of save_log", function()
    local r1 = serve_api._handle_step(DEMO01, { reset = true })
    local r2 = serve_api._handle_step(DEMO01,
                 { save_log = r1.save_log, choice_index = 1 })
    local json = debug_mod.encode_json(r2.save_log)
    local decoded = debug_mod.decode_json(json)
    local r3 = serve_api._handle_step(DEMO01,
                 { save_log = decoded, choice_index = 1 })
    assert.is_nil(r3.error)
    assert.not_equals(r2.scene, r3.scene)
  end)

  it("save_log replay is deterministic", function()
    -- Two requests with the same save_log + choice should produce the same scene.
    local r1 = serve_api._handle_step(DEMO01, { reset = true })
    local sl = debug_mod.decode_json(debug_mod.encode_json(r1.save_log))
    local a = serve_api._handle_step(DEMO01, { save_log = sl, choice_index = 1 })
    local sl2 = debug_mod.decode_json(debug_mod.encode_json(r1.save_log))
    local b = serve_api._handle_step(DEMO01, { save_log = sl2, choice_index = 1 })
    assert.equals(a.scene, b.scene)
  end)

  it("choice_index out of range returns an error", function()
    local r1 = serve_api._handle_step(DEMO01, { reset = true })
    local r2 = serve_api._handle_step(DEMO01,
                 { save_log = r1.save_log, choice_index = 99 })
    assert.is_string(r2.error)
    assert.truthy(r2.error:find("out of range"))
  end)

  it("invalid save_log type returns an error", function()
    local r = serve_api._handle_step(DEMO01,
                { save_log = "not a table", choice_index = 1 })
    assert.is_string(r.error)
  end)

  it("reset:true ignores save_log and starts fresh", function()
    local r1 = serve_api._handle_step(DEMO01, { reset = true })
    local r2 = serve_api._handle_step(DEMO01,
                 { save_log = r1.save_log, choice_index = 1 })
    local r3 = serve_api._handle_step(DEMO01,
                 { save_log = r2.save_log, reset = true })
    -- After reset, we should be back at the entry scene
    assert.equals("village", r3.scene)
  end)

  it("save_log contains scene_stack and entries", function()
    local r = serve_api._handle_step(DEMO01, { reset = true })
    assert.is_table(r.save_log.scene_stack)
    assert.is_table(r.save_log.entries)
    assert.is_table(r.save_log.checkpoints)
    assert.is_table(r.save_log.schedule_state)
    assert.equals(1, r.save_log.version)
  end)

  it("schema_summary lists states and scenes", function()
    local s = serve_api._schema_summary(DEMO01)
    assert.is_table(s.states)
    assert.is_table(s.scenes)
    assert.is_truthy(#s.scenes > 0)
    assert.equals("village", s.entry_scene)
  end)
end)

-- ── HTTP end-to-end tests ──────────────────────────────────────

-- Unique base port that shifts each run, so back-to-back invocations do not
-- collide with sockets left in TIME_WAIT by the previous busted run.
-- LuaSocket has no PID accessor, so derive a port slice from os.time() % 100.
local BASE_PORT = 18800 + (os.time() % 100) * 10

-- Drive the server's non-blocking accept loop for a short window.
local function pump(server, ms)
  ms = ms or 200
  local end_t = socket.gettime() + ms / 1000
  while socket.gettime() < end_t do
    serve_api.poll(server)
    socket.sleep(0.005)
  end
end

-- Connect with a retry loop (the listener is set up synchronously, but be
-- tolerant of cross-platform scheduling delays).
local function connect(port)
  for _ = 1, 30 do
    local s = socket.tcp()
    s:settimeout(0.1)
    if s:connect("127.0.0.1", port) then
      s:settimeout(2)
      return s
    end
    s:close()
    socket.sleep(0.02)
  end
  return nil
end

local function http_request(server, port, method, path, body)
  local s = assert(connect(port), "could not connect to port " .. port)
  local req = method .. " " .. path .. " HTTP/1.0\r\n"
              .. "Host: localhost\r\n"
  if body then
    req = req .. "Content-Type: application/json\r\n"
              .. "Content-Length: " .. #body .. "\r\n"
  end
  req = req .. "\r\n"
  if body then req = req .. body end
  s:send(req)

  pump(server, 300)

  s:settimeout(2)
  local raw = s:receive("*a") or ""
  s:close()
  return raw
end

local function parse_response(raw)
  local status = tonumber(raw:match("^HTTP/1%.[01] (%d+)"))
  local hdr_end = raw:find("\r\n\r\n", 1, true)
  local body = hdr_end and raw:sub(hdr_end + 4) or ""
  return status, body, raw
end

local function http_get(server, port, path)
  local raw = http_request(server, port, "GET", path, nil)
  return parse_response(raw)
end

local function http_post_json(server, port, path, payload)
  local body = debug_mod.encode_json(payload or {})
  local raw = http_request(server, port, "POST", path, body)
  local status, body_str, full = parse_response(raw)
  local ok, decoded = pcall(debug_mod.decode_json, body_str)
  return status, (ok and decoded or nil), full
end

describe("serve-api: HTTP lifecycle", function()
  it("start binds, poll accepts, stop closes", function()
    local server, err = serve_api.start(DEMO01,
                          { port = BASE_PORT, quiet = true, game_path = "demos/demo01_wanderer.sb" })
    assert.is_nil(err)
    assert.is_not_nil(server)
    local s = connect(BASE_PORT)
    assert.is_not_nil(s)
    s:close()
    serve_api.stop(server)
    socket.sleep(0.05)
    -- After stop, connect should fail
    local s2 = socket.tcp()
    s2:settimeout(0.1)
    local ok = s2:connect("127.0.0.1", BASE_PORT)
    s2:close()
    assert.is_falsy(ok)
  end)
end)

describe("serve-api: GET endpoints", function()
  local PORT = BASE_PORT + 1
  local server

  setup(function()
    server = assert(serve_api.start(DEMO01,
              { port = PORT, quiet = true, game_path = "demos/demo01_wanderer.sb" }))
  end)
  teardown(function() serve_api.stop(server) end)

  it("GET / returns 200 and a usage page", function()
    local status, body = http_get(server, PORT, "/")
    assert.equals(200, status)
    assert.truthy(body:find("StoryBase HTTP API"))
    assert.truthy(body:find("/step"))
  end)

  it("GET /schema returns the schema summary as JSON", function()
    local status, body = http_get(server, PORT, "/schema")
    assert.equals(200, status)
    local decoded = debug_mod.decode_json(body)
    assert.is_table(decoded)
    assert.is_table(decoded.scenes)
    assert.equals("village", decoded.entry_scene)
  end)

  it("GET / includes CORS header", function()
    local _, _, raw = http_get(server, PORT, "/")
    assert.truthy(raw:find("Access%-Control%-Allow%-Origin: %*"))
  end)

  it("unknown route returns 404", function()
    local status = http_get(server, PORT, "/nonsense")
    assert.equals(404, status)
  end)
end)

describe("serve-api: OPTIONS preflight", function()
  local PORT = BASE_PORT + 2
  local server

  setup(function()
    server = assert(serve_api.start(DEMO01,
              { port = PORT, quiet = true, game_path = "demos/demo01_wanderer.sb" }))
  end)
  teardown(function() serve_api.stop(server) end)

  it("returns 200 with allow-methods header", function()
    local s = assert(connect(PORT))
    s:send("OPTIONS /step HTTP/1.0\r\nHost: localhost\r\n\r\n")
    pump(server, 200)
    local raw = s:receive("*a") or ""
    s:close()
    local status = tonumber(raw:match("^HTTP/1%.[01] (%d+)"))
    assert.equals(200, status)
    assert.truthy(raw:find("Access%-Control%-Allow%-Methods"))
  end)
end)

describe("serve-api: POST /step", function()
  local PORT = BASE_PORT + 3
  local server

  setup(function()
    server = assert(serve_api.start(DEMO01,
              { port = PORT, quiet = true, game_path = "demos/demo01_wanderer.sb" }))
  end)
  teardown(function() serve_api.stop(server) end)

  it("fresh request returns entry scene", function()
    local status, body = http_post_json(server, PORT, "/step", { reset = true })
    assert.equals(200, status)
    assert.is_table(body)
    assert.equals("village", body.scene)
    assert.is_table(body.save_log)
    assert.is_truthy(#body.choices > 0)
  end)

  it("client can drive a multi-step play-through", function()
    local _, r1 = http_post_json(server, PORT, "/step", { reset = true })
    assert.is_not_nil(r1.save_log)
    local _, r2 = http_post_json(server, PORT, "/step",
                    { save_log = r1.save_log, choice_index = 1 })
    assert.is_table(r2)
    assert.not_equals(r1.scene, r2.scene)
    local _, r3 = http_post_json(server, PORT, "/step",
                    { save_log = r2.save_log, choice_index = 1 })
    assert.is_table(r3)
    -- The wanderer demo has a chain of single-choice scenes; r3 should differ
    -- from both r1 and r2 in scene name (or be done).
    assert.is_true(r3.done or r3.scene ~= r2.scene)
  end)

  it("invalid choice_index returns 400 with an error", function()
    local _, r1 = http_post_json(server, PORT, "/step", { reset = true })
    local status, r2 = http_post_json(server, PORT, "/step",
                         { save_log = r1.save_log, choice_index = 999 })
    assert.equals(400, status)
    assert.is_string(r2.error)
  end)

  it("malformed JSON body returns 400", function()
    -- Send bogus body bytes; bypass http_post_json which encodes valid JSON.
    local body = "{ this is not valid json"
    local raw = http_request(server, PORT, "POST", "/step", body)
    local status, resp_body = parse_response(raw)
    assert.equals(400, status)
    assert.truthy(resp_body:find("invalid JSON") or resp_body:find("error"))
  end)

  it("non-object JSON body returns 400", function()
    local raw = http_request(server, PORT, "POST", "/step", "[1,2,3]")
    local status = parse_response(raw)
    assert.equals(400, status)
  end)
end)

describe("serve-api: POST /reset", function()
  local PORT = BASE_PORT + 4
  local server

  setup(function()
    server = assert(serve_api.start(DEMO01,
              { port = PORT, quiet = true, game_path = "demos/demo01_wanderer.sb" }))
  end)
  teardown(function() serve_api.stop(server) end)

  it("returns fresh entry-scene state", function()
    -- First advance a step
    local _, r1 = http_post_json(server, PORT, "/step", { reset = true })
    local _, r2 = http_post_json(server, PORT, "/step",
                    { save_log = r1.save_log, choice_index = 1 })
    -- Then reset
    local status, r3 = http_post_json(server, PORT, "/reset", { save_log = r2.save_log })
    assert.equals(200, status)
    assert.equals("village", r3.scene)
  end)
end)

-- tests/cli/drivers_spec.lua
-- Unit tests for cli/drivers/{plain,ansi,curses,driver}.

local plain_mod  = require("cli.drivers.plain")
local ansi_mod   = require("cli.drivers.ansi")
local curses_mod = require("cli.drivers.curses")
local driver_mod = require("cli.drivers.driver")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_io(input_lines)
  local out_parts = {}
  local line_idx  = 0
  local out = {
    write = function(_, s) out_parts[#out_parts + 1] = s end,
    flush = function() end,
  }
  local inp = {
    read = function(_, _fmt)
      line_idx = line_idx + 1
      return input_lines[line_idx]
    end,
  }
  local function captured() return table.concat(out_parts) end
  return out, inp, captured
end

local narr_items = {
  { kind = "narration", text = "The cave is dark." },
  { kind = "say",       speaker = "ghost", display = "Ghost", color = "#aabbcc", text = "Boo!" },
  { kind = "narration", text = "" },  -- empty line should be skipped
}

local choices = {
  { index = 1, label = "Run away" },
  { index = 2, label = "Stay put" },
}

-- ── plain driver ──────────────────────────────────────────────────────────────

describe("plain driver: render", function()
  it("prints narration text", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    local text = captured()
    assert.is_truthy(text:find("The cave is dark%."), text)
  end)

  it("formats say items as `Speaker: text'", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    local text = captured()
    assert.is_truthy(text:find("Ghost: Boo!"), text)
  end)

  it("skips empty narration text", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    -- rendered output should not have a bare blank line from the empty item
    -- (blank lines from the wrapping \n\n are fine; just no double-blank mid-list)
    local text = captured()
    assert.is_falsy(text:find("\n\n\n"), text)
  end)
end)

describe("plain driver: prompt", function()
  it("prints numbered choices", function()
    local out, inp, captured = make_io({ "1" })
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:prompt(choices)
    local text = captured()
    assert.is_truthy(text:find("1%. Run away"), text)
    assert.is_truthy(text:find("2%. Stay put"), text)
  end)

  it("returns the chosen index", function()
    local out, inp, _ = make_io({ "2" })
    local d = plain_mod.new({ io_out = out, io_in = inp })
    local idx = d:prompt(choices)
    assert.equal(2, idx)
  end)

  it("returns nil on `q'", function()
    local out, inp, _ = make_io({ "q" })
    local d = plain_mod.new({ io_out = out, io_in = inp })
    local idx = d:prompt(choices)
    assert.is_nil(idx)
  end)

  it("returns nil on EOF", function()
    local out, inp, _ = make_io({})  -- no lines → nil on read
    local d = plain_mod.new({ io_out = out, io_in = inp })
    local idx = d:prompt(choices)
    assert.is_nil(idx)
  end)

  it("retries on invalid input then accepts valid", function()
    local out, inp, captured = make_io({ "99", "1" })
    local d = plain_mod.new({ io_out = out, io_in = inp })
    local idx = d:prompt(choices)
    assert.equal(1, idx)
    assert.is_truthy(captured():find("Invalid"), captured())
  end)
end)

describe("plain driver: notify", function()
  it("is a no-op (does not error)", function()
    local out, inp, _ = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    assert.has_no_error(function() d:notify("mutation", { path = "x", value = 1 }) end)
  end)
end)

-- ── plain driver: §M5 stat-bar fallback ──────────────────────────────────────
--
-- The plain driver does not subscribe to mutations; it re-emits the
-- stat-bar header on every render. This matches its synchronous-pull
-- cadence and keeps a no-color text driver useful for `--ui plain`
-- runs of games that declare `ui:` bindings.

describe("plain driver: stat-bar fallback (M5)", function()
  --- Tiny kernel stub: enough surface for the plain driver's attach
  --- and render to discover bindings and read state.
  local function stub_kernel(schema, panels, state)
    return {
      _s = state or {},
      get_schema   = function() return schema end,
      get_bindings = function() return panels or {} end,
      get_state    = function(self, p) return self._s[p] end,
    }
  end

  local schema = {
    states = {
      { kind = "scalar", path = "player/hp",
        type_desc = { tag = "int", min = 0, max = 10 },
        ui = { kind = "stat-bar", label = "Health" } },
      { kind = "scalar", path = "player/mana",
        type_desc = { tag = "int", min = 0, max = 20 } },
    },
  }
  local panels = {
    { name = "status", children = {
        { kind = "stat-bar", arg = "player/mana" },
      } },
  }

  it("prints 'Health: 7/10' once per render when attached", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:attach(stub_kernel(schema, nil, { ["player/hp"] = 7 }))
    d:render({ narration = {}, choices = {} })
    assert.is_truthy(captured():find("Health: 7/10"), captured())
  end)

  it("includes panel-child stat-bars too", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:attach(stub_kernel(schema, panels, {
      ["player/hp"]   = 5,
      ["player/mana"] = 18,
    }))
    d:render({ narration = {}, choices = {} })
    local text = captured()
    assert.is_truthy(text:find("Health: 5/10"))
    assert.is_truthy(text:find("mana: 18/20"))
  end)

  it("re-reads the kernel state on every render", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    local k = stub_kernel(schema, nil, { ["player/hp"] = 10 })
    d:attach(k)
    d:render({ narration = {}, choices = {} })
    k._s["player/hp"] = 3
    d:render({ narration = {}, choices = {} })
    local text = captured()
    assert.is_truthy(text:find("Health: 10/10"))
    assert.is_truthy(text:find("Health: 3/10"))
  end)

  it("prints nothing extra when no kernel is attached", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = { { kind = "narration", text = "X." } }, choices = {} })
    local text = captured()
    assert.is_nil(text:find("Health"))
  end)

  it("prints nothing extra when the schema has no bindings", function()
    local bare = { states = {
      { kind = "scalar", path = "player/hp",
        type_desc = { tag = "int", min = 0, max = 10 } },  -- no ui:
    } }
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:attach(stub_kernel(bare, nil, { ["player/hp"] = 7 }))
    d:render({ narration = {}, choices = {} })
    assert.is_nil(captured():find("Health"))
    assert.is_nil(captured():find("hp:"))
  end)

  it("renders '-' for an unobserved path", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:attach(stub_kernel(schema, nil, {}))  -- no value yet
    d:render({ narration = {}, choices = {} })
    assert.is_truthy(captured():find("Health: %-"), captured())
  end)

  it("detach drops the kernel and the bindings", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:attach(stub_kernel(schema, nil, { ["player/hp"] = 7 }))
    d:detach()
    d:render({ narration = {}, choices = {} })
    assert.is_nil(captured():find("Health"))
  end)
end)

-- ── ansi driver ───────────────────────────────────────────────────────────────

describe("ansi driver: render", function()
  it("includes the speaker text", function()
    local out, inp, captured = make_io({})
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    assert.is_truthy(captured():find("Boo!"), captured())
  end)

  it("emits ANSI color escape for speaker with color field", function()
    local out, inp, captured = make_io({})
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    -- "#aabbcc" → \27[38;2;170;187;204m
    assert.is_truthy(captured():find("\27%[38;2;170;187;204m"), captured())
  end)

  it("emits ANSI reset after speaker label", function()
    local out, inp, captured = make_io({})
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    assert.is_truthy(captured():find("\27%[0m"), captured())
  end)

  it("prints plain narration without escape codes", function()
    local out, inp, captured = make_io({})
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = { { kind = "narration", text = "Plain text." } }, choices = {} })
    -- The output for narration should be just the text with no color escape before it
    local text = captured()
    assert.is_truthy(text:find("Plain text%."), text)
    -- No color escape immediately before "Plain text."
    assert.is_falsy(text:find("\27%[38;2;.-mPlain text"), text)
  end)
end)

describe("ansi driver: prompt", function()
  it("returns the chosen index", function()
    local out, inp, _ = make_io({ "1" })
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    local idx = d:prompt(choices)
    assert.equal(1, idx)
  end)

  it("emits bold escape around choice index", function()
    local out, inp, captured = make_io({ "1" })
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    d:prompt(choices)
    assert.is_truthy(captured():find("\27%[1m1\27%[0m"), captured())
  end)

  it("returns nil on quit", function()
    local out, inp, _ = make_io({ "quit" })
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    assert.is_nil(d:prompt(choices))
  end)
end)

-- ── --ui flag integration ─────────────────────────────────────────────────────

describe("--ui flag: driver loading via cli/main", function()
  local compiler = require("compiler.compiler")
  local engine   = require("runtime.engine")

  local src = [[
module ui-test
  version: 1.0
engine-config:
  entry-scene: start
speaker aldric:
  display: "Aldric"
  color:   "#ff0000"
scene start:
  say aldric: Hello.
  Welcome to the test.
  * Done -> start
]]

  local game_table
  before_each(function()
    local gt, diags = compiler.compile(src, "ui_test.sb")
    local errs = {}
    for _, d in ipairs(diags or {}) do
      if d.level == "error" then errs[#errs + 1] = d end
    end
    assert.equal(0, #errs, "compile errors")
    game_table = gt
  end)

  it("plain driver receives structured narration via step()", function()
    local rendered = {}
    local fake_driver = {
      render = function(_, scene_output)
        rendered[#rendered + 1] = scene_output
      end,
      prompt = function(_, _) return nil end,  -- quit immediately
      notify = function() end,
    }
    local io_null = { write = function() end }
    local eng = engine.new(game_table, { io_out = io_null, driver = fake_driver })
    eng:init()
    eng:step()
    assert.is_true(#rendered >= 1, "driver:render should have been called")
    local narr = rendered[1].narration
    local has_say = false
    local has_narration = false
    for _, item in ipairs(narr) do
      if item.kind == "say"       then has_say       = true end
      if item.kind == "narration" then has_narration = true end
    end
    assert.is_true(has_say,       "expected a say item")
    assert.is_true(has_narration, "expected a narration item")
  end)

  it("all narration items have a kind field", function()
    local rendered = {}
    local fake_driver = {
      render = function(_, scene_output) rendered[#rendered + 1] = scene_output end,
      prompt = function(_, _) return nil end,
      notify = function() end,
    }
    local io_null = { write = function() end }
    local eng = engine.new(game_table, { io_out = io_null, driver = fake_driver })
    eng:init()
    eng:step()
    for _, item in ipairs(rendered[1] and rendered[1].narration or {}) do
      assert.is_string(item.kind, "every narration item must have a kind field")
    end
  end)
end)

-- ── --ui flag: driver-name whitelist (A11) ────────────────────────────────────

describe("--ui flag: whitelist", function()
  local cli = require("cli.main")

  -- Minimal game source for cli.main to load.
  local src = [[
module ui-whitelist-test
  version: 1.0
engine-config:
  entry-scene: start
scene start:
  Hi.
  * Done -> start
]]

  local game_path
  before_each(function()
    game_path = os.tmpname() .. ".sb"
    local f = assert(io.open(game_path, "w"))
    f:write(src)
    f:close()
  end)
  after_each(function()
    if game_path then os.remove(game_path) end
  end)

  -- Run cli.main with captured stderr; returns exit_code, err_str.
  local function run_with(argv)
    local err_parts = {}
    local old_err = io.stderr
    io.stderr = setmetatable({}, {
      __index = {
        write = function(_, ...)
          for _, s in ipairs({...}) do err_parts[#err_parts + 1] = tostring(s) end
        end,
        flush = function() end,
      }
    })
    local ok, rc = pcall(cli.main, argv)
    io.stderr = old_err
    if not ok then error(rc, 2) end
    return rc or 0, table.concat(err_parts)
  end

  it("rejects path-traversal driver name", function()
    local rc, err = run_with({"run", game_path, "--ui", "../../foo", "--auto", "--steps", "0"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("unknown UI driver"), err)
    assert.is_truthy(err:find("%.%./%.%./foo"), err)
  end)

  it("rejects arbitrary module names not in the whitelist", function()
    local rc, err = run_with({"run", game_path, "--ui", "os", "--auto", "--steps", "0"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("unknown UI driver"), err)
  end)

  it("rejects dotted module paths", function()
    local rc, err = run_with({"run", game_path, "--ui", "foo.bar", "--auto", "--steps", "0"})
    assert.equal(1, rc)
    assert.is_truthy(err:find("unknown UI driver"), err)
  end)

  it("accepts whitelisted `plain' driver", function()
    -- 0 auto steps exits cleanly without consuming choices.
    local rc, err = run_with({"run", game_path, "--ui", "plain", "--auto", "--steps", "0"})
    assert.equal(0, rc, "stderr: " .. err)
  end)

  it("accepts whitelisted `ansi' driver", function()
    local rc, err = run_with({"run", game_path, "--ui", "ansi", "--auto", "--steps", "0"})
    assert.equal(0, rc, "stderr: " .. err)
  end)

  -- curses is in the enum as of §M2. The registry-level check (does
  -- `--ui curses` survive whitelist validation?) is the part exercised
  -- here. The full paint+input path is covered headlessly by
  -- tests/ui/curses_driver_spec.lua via a stub curses module; running
  -- the real ncurses init from inside busted would require a TTY.
  it("accepts `curses' in the cli.ui whitelist", function()
    local config = require("runtime.config")
    local spec = config.spec("cli.ui")
    local allowed = {}
    for _, v in ipairs(spec.enum) do allowed[v] = true end
    assert.is_true(allowed["curses"], "curses should be in the cli.ui enum")
  end)
end)

-- ── --ui curses + --ui-backend buffer: end-to-end CLI plumbing ───────────────
--
-- These exercise the CLI entry point with the headless buffer backend so
-- a regression in cli/main.lua's --ui-* plumbing fails fast. The full
-- paint behaviour is still covered in tests/ui/curses_driver_spec.lua.

describe("--ui curses + --ui-backend buffer", function()
  local cli = require("cli.main")

  -- Two-scene game so a scripted "1" key actually advances state.
  local src = [[
module ui-curses-buffer-test
  version: 1.0
engine-config:
  entry-scene: start
scene start:
  Welcome here.
  * Onwards
    -> later
scene later:
  You are at the end.
  * Stay
    -> later
]]

  local game_path, snap_path
  before_each(function()
    game_path = os.tmpname() .. ".sb"
    snap_path = os.tmpname() .. ".snap.txt"
    local f = assert(io.open(game_path, "w")); f:write(src); f:close()
  end)
  after_each(function()
    if game_path then os.remove(game_path) end
    if snap_path then os.remove(snap_path) end
  end)

  -- Run cli.main with captured stderr; returns exit_code, err_str.
  local function run_with(argv)
    local err_parts = {}
    local old_err = io.stderr
    io.stderr = setmetatable({}, {
      __index = {
        write = function(_, ...)
          for _, s in ipairs({...}) do err_parts[#err_parts + 1] = tostring(s) end
        end,
        flush = function() end,
      }
    })
    local ok, rc = pcall(cli.main, argv)
    io.stderr = old_err
    if not ok then error(rc, 2) end
    return rc or 0, table.concat(err_parts)
  end

  local function read_file(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a"); f:close()
    return s
  end

  it("plays through with scripted keys and writes a final snapshot", function()
    -- "1" → advance to `next` scene; "q" → quit. Snapshot the final frame.
    local rc, err = run_with({
      "run", game_path,
      "--ui", "curses", "--ui-backend", "buffer",
      "--ui-rows", "10", "--ui-cols", "40",
      "--ui-keys", "1q",
      "--ui-snapshot", snap_path,
    })
    assert.equal(0, rc, "stderr: " .. err)
    local snap = read_file(snap_path)
    assert.is_truthy(snap:find("You are at the end"),
      "final scene narration should appear in snapshot:\n" .. snap)
    assert.is_truthy(snap:find("Choice %(1%-1, q to quit%):"),
      "prompt should appear in snapshot:\n" .. snap)
  end)

  it("quits cleanly when --ui-keys exhausts before the game ends", function()
    -- No keys at all: first read_key returns nil, driver returns nil from
    -- prompt, engine treats that as a quit. Exit 0.
    local rc, err = run_with({
      "run", game_path,
      "--ui", "curses", "--ui-backend", "buffer",
      "--ui-snapshot", snap_path,
    })
    assert.equal(0, rc, "stderr: " .. err)
    local snap = read_file(snap_path)
    assert.is_truthy(snap:find("Welcome here"), snap)
  end)

  it("plain driver ignores --ui-backend/--ui-keys without error", function()
    local rc, err = run_with({
      "run", game_path,
      "--ui", "plain", "--auto", "--steps", "0",
      "--ui-backend", "buffer", "--ui-keys", "1",
    })
    assert.equal(0, rc, "stderr: " .. err)
  end)

  it("--ui-snapshot is a silent no-op on plain (no buffer handle)", function()
    -- The driver has no _backend_handle, so no file is created. The
    -- run still succeeds.
    local rc, err = run_with({
      "run", game_path,
      "--ui", "plain", "--auto", "--steps", "0",
      "--ui-snapshot", snap_path,
    })
    assert.equal(0, rc, "stderr: " .. err)
    local f = io.open(snap_path, "r")
    assert.is_nil(f, "snapshot path should not exist when driver has no buffer handle")
  end)
end)

-- ── §M5 end-to-end: --ui plain + ui: bindings ────────────────────────────────

describe("--ui plain + ui: bindings (M5 end-to-end)", function()
  local cli = require("cli.main")

  -- One-state game with a stat-bar binding and a single self-looping
  -- choice. The stat-bar header should appear in the captured stdout
  -- before the narration on every step.
  local src = [[
module ui-statbar-plain-e2e
  version: 1.0
engine-config:
  entry-scene: start
state player/hp: Int(0, 10) = 7
  ui:
    kind: stat-bar
    label: "Health"
scene start:
  You feel okay.
  * Continue
    -> start
]]

  local function tmpfile(contents)
    local path = os.tmpname() .. ".sb"
    local f = assert(io.open(path, "w")); f:write(contents); f:close()
    return path
  end

  -- cli.main writes to io.stdout; capture it for the assertion.
  local function run_capture(argv)
    local out_parts = {}
    local old_out = io.stdout
    io.stdout = setmetatable({}, { __index = {
      write = function(_, ...)
        for _, s in ipairs({...}) do out_parts[#out_parts + 1] = tostring(s) end
      end,
      flush = function() end,
    }})
    local ok, rc = pcall(cli.main, argv)
    io.stdout = old_out
    if not ok then error(rc, 2) end
    return rc or 0, table.concat(out_parts)
  end

  it("emits 'Health: 7/10' from the plain-driver fallback on render",
  function()
    local path = tmpfile(src)
    local rc, out = run_capture({
      "run", path, "--ui", "plain", "--auto", "--steps", "1",
    })
    os.remove(path)
    assert.equal(0, rc)
    assert.is_truthy(out:find("Health: 7/10"),
      "expected stat-bar header in plain output:\n" .. out)
  end)
end)

-- ── §M5 end-to-end: --ui curses + ui: bindings ───────────────────────────────

describe("--ui curses + ui: bindings (M5 end-to-end)", function()
  local cli = require("cli.main")

  local src = [[
module ui-statbar-curses-e2e
  version: 1.0
engine-config:
  entry-scene: start
state player/hp: Int(0, 10) = 7
  ui:
    kind: stat-bar
    label: "Health"
scene start:
  You feel okay.
  * Continue
    -> start
]]

  local function tmpfile(contents)
    local path = os.tmpname() .. ".sb"
    local f = assert(io.open(path, "w")); f:write(contents); f:close()
    return path
  end

  local function read_file(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a"); f:close()
    return s
  end

  local function run_with(argv)
    local err_parts = {}
    local old_err = io.stderr
    io.stderr = setmetatable({}, { __index = {
      write = function(_, ...)
        for _, s in ipairs({...}) do err_parts[#err_parts + 1] = tostring(s) end
      end,
      flush = function() end,
    }})
    local ok, rc = pcall(cli.main, argv)
    io.stderr = old_err
    if not ok then error(rc, 2) end
    return rc or 0, table.concat(err_parts)
  end

  it("paints the stat-bar above narration in the buffer snapshot", function()
    local path = tmpfile(src)
    local snap_path = os.tmpname() .. ".snap.txt"
    local rc, err = run_with({
      "run", path,
      "--ui", "curses", "--ui-backend", "buffer",
      "--ui-rows", "12", "--ui-cols", "60",
      "--ui-keys", "q",
      "--ui-snapshot", snap_path,
    })
    os.remove(path)
    assert.equal(0, rc, "stderr: " .. err)
    local snap = read_file(snap_path)
    os.remove(snap_path)
    -- Row 0 should be the stat-bar; narration follows below.
    local rows = {}
    for line in (snap .. "\n"):gmatch("([^\n]*)\n") do
      rows[#rows + 1] = line
    end
    assert.is_truthy(rows[1] and rows[1]:find("Health: 7/10"),
      "first row should be the stat-bar:\n" .. snap)
    assert.is_truthy(snap:find("You feel okay"),
      "narration should appear somewhere below the stat-bar:\n" .. snap)
  end)
end)

-- ── driver protocol contract ──────────────────────────────────────────────────

describe("driver.is_driver", function()
  it("rejects non-tables", function()
    local ok, why = driver_mod.is_driver(nil); assert.is_false(ok); assert.is_string(why)
    ok, why = driver_mod.is_driver("plain");   assert.is_false(ok); assert.is_string(why)
  end)

  it("reports the first missing method by name", function()
    local incomplete = { render = function() end, prompt = function() end }
    local ok, missing = driver_mod.is_driver(incomplete)
    assert.is_false(ok)
    assert.equal("notify", missing)
  end)

  it("accepts plain driver instances", function()
    local d = plain_mod.new()
    assert.is_true(driver_mod.is_driver(d))
  end)

  it("accepts ansi driver instances", function()
    local d = ansi_mod.new()
    assert.is_true(driver_mod.is_driver(d))
  end)

  it("accepts the curses scaffold (structural conformance)", function()
    local d = curses_mod.new()
    assert.is_true(driver_mod.is_driver(d))
  end)
end)

describe("plain/ansi lifecycle stubs", function()
  it("plain driver attach/tick/detach are callable no-ops", function()
    local d = plain_mod.new()
    assert.has_no_errors(function() d:attach({}) end)
    assert.has_no_errors(function() d:tick(0.016) end)
    assert.has_no_errors(function() d:detach() end)
  end)

  it("ansi driver attach/tick/detach are callable no-ops", function()
    local d = ansi_mod.new()
    assert.has_no_errors(function() d:attach({}) end)
    assert.has_no_errors(function() d:tick(0.016) end)
    assert.has_no_errors(function() d:detach() end)
  end)
end)

-- ── curses driver shape ───────────────────────────────────────────────────────
--
-- The full curses-rendering behaviour is covered in
-- tests/ui/curses_driver_spec.lua, which injects a stub curses module
-- to exercise paint + read_choice headlessly. These cases only assert
-- the structural contract: M.new() succeeds without touching curses,
-- the result satisfies the driver interface, and lifecycle stubs are
-- safe to call.

describe("curses driver shape", function()
  it("M.new returns a contract-conformant driver without touching curses", function()
    -- Inject a sentinel curses table so we can confirm M.new() does
    -- NOT call any of its functions (lazy init is honoured).
    local touched = false
    local sentinel = setmetatable({}, { __index = function() touched = true end })
    local d = curses_mod.new({ curses = sentinel })
    assert.is_table(d)
    assert.is_true(driver_mod.is_driver(d))
    assert.is_false(touched, "M.new must not call into curses")
  end)

  it("attach stores the kernel; detach clears it", function()
    local d = curses_mod.new({ curses = {} })
    local fake_kernel = { _name = "k" }
    d:attach(fake_kernel)
    assert.equal(fake_kernel, d._kernel)
    d:detach()
    assert.is_nil(d._kernel)
  end)

  it("notify and tick are no-op safe", function()
    local d = curses_mod.new({ curses = {} })
    assert.has_no_errors(function() d:notify("scene-change", {}) end)
    assert.has_no_errors(function() d:tick(0.016) end)
  end)

  it("exposes is_available() that probes lcurses without errors", function()
    -- In this dev env lcurses IS installed (CLAUDE.md), so this should
    -- be true. The interesting assertion is that calling it cannot
    -- throw, regardless of host packaging.
    assert.has_no_errors(function() curses_mod.is_available() end)
  end)
end)


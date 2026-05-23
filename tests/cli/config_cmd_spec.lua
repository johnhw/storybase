-- tests/cli/config_cmd_spec.lua
-- Tests for `storybase config <subcommand>` and the global `--config key=value`
-- flag.  The subcommand handlers are exercised in-process; the global flag is
-- driven through `cli.main` so we cover the `extract_cli_overrides` plumbing.

local config_cmd = require("cli.config_cmd")
local config     = require("runtime.config")
local cli        = require("cli.main")

-- Force the engine module to declare its keys before any spec runs.
require("runtime.engine")

-- ── Capture helpers ──────────────────────────────────────────────────────

local function capture_io(fn)
  local out_parts, err_parts = {}, {}
  local old_out, old_err = io.stdout, io.stderr
  local old_io_write = io.write
  local function proxy(parts)
    return setmetatable({}, { __index = {
      write = function(_, ...)
        for _, s in ipairs({...}) do parts[#parts + 1] = tostring(s) end
      end,
      flush = function() end,
    }})
  end
  io.stdout = proxy(out_parts)
  io.stderr = proxy(err_parts)
  io.write = function(...)
    for _, s in ipairs({...}) do out_parts[#out_parts + 1] = tostring(s) end
  end
  local ok, result = pcall(fn)
  io.stdout, io.stderr, io.write = old_out, old_err, old_io_write
  if not ok then error(result, 2) end
  return table.concat(out_parts), table.concat(err_parts), result
end

local function run_cmd(args)
  local out, err, rc = capture_io(function() return config_cmd.run(args) end)
  return rc or 0, out, err
end

local function run_main(argv)
  local out, err, rc = capture_io(function() return cli.main(argv) end)
  return rc or 0, out, err
end

-- Wipe the layers tests are allowed to write to: runtime + cli + game.
-- (env/file get repopulated by `load_startup` whenever `cli.main` is called,
-- so cross-test isolation against the host environment is at most best-effort
-- — the assertions below avoid depending on specific env/file content.)
local function clear_overrides()
  for _, k in ipairs(config.keys()) do
    pcall(config.set, k, nil)
  end
  config.bind_cli(nil)
  config.bind_game(nil)
end

-- ── config_cmd.run subcommands ───────────────────────────────────────────

describe("storybase config dump", function()
  before_each(clear_overrides)
  after_each(clear_overrides)

  it("prints a header row and every declared key", function()
    local rc, out = run_cmd({"dump"})
    assert.equals(0, rc)
    assert.is_truthy(out:find("key", 1, true))
    assert.is_truthy(out:find("layer", 1, true))
    assert.is_truthy(out:find("value", 1, true))
    assert.is_truthy(out:find("engine.scene-stack-max", 1, true))
    assert.is_truthy(out:find("engine.npc-speed", 1, true))
    assert.is_truthy(out:find("engine.entry-scene", 1, true))
  end)

  it("shows runtime layer wins over default", function()
    config.set("engine.npc-speed", 7)
    local rc, out = run_cmd({"dump"})
    assert.equals(0, rc)
    -- The line for engine.npc-speed should show layer=runtime, value=7
    assert.is_truthy(out:find("engine%.npc%-speed%s+runtime%s+7"))
  end)

  it("binds the game layer from a .sb file when given a path", function()
    local path = os.tmpname() .. ".sb"
    local f = assert(io.open(path, "w"))
    f:write([[
engine-config:
  entry-scene: main
  npc-speed:   2

scene main:
  * Stay -> main
]])
    f:close()
    local rc, out = run_cmd({"dump", path})
    os.remove(path)
    assert.equals(0, rc)
    assert.is_truthy(out:find("engine%.npc%-speed%s+game%s+2"))
    assert.is_truthy(out:find("engine%.entry%-scene%s+game%s+main"))
  end)
end)

describe("storybase config get", function()
  before_each(clear_overrides)
  after_each(clear_overrides)

  it("prints just the value for a known key", function()
    local rc, out, err = run_cmd({"get", "engine.scene-stack-max"})
    assert.equals(0, rc)
    assert.equals("16\n", out)
    assert.equals("", err)
  end)

  it("reflects runtime overrides", function()
    config.set("engine.npc-speed", 3)
    local rc, out = run_cmd({"get", "engine.npc-speed"})
    assert.equals(0, rc)
    assert.equals("3\n", out)
  end)

  it("prints a blank line for unset keys without a default", function()
    local rc, out = run_cmd({"get", "engine.entry-scene"})
    assert.equals(0, rc)
    assert.equals("\n", out)
  end)

  it("errors on unknown key", function()
    local rc, _, err = run_cmd({"get", "no.such.key"})
    assert.equals(1, rc)
    assert.is_truthy(err:find("unknown key"))
  end)

  it("errors on missing argument", function()
    local rc, _, err = run_cmd({"get"})
    assert.equals(1, rc)
    assert.is_truthy(err:find("missing <key>"))
  end)
end)

describe("storybase config doc", function()
  before_each(clear_overrides)
  after_each(clear_overrides)

  it("renders the spec for a known key", function()
    local rc, out, err = run_cmd({"doc", "engine.npc-speed"})
    assert.equals(0, rc)
    assert.equals("", err)
    assert.is_truthy(out:find("engine.npc-speed", 1, true))
    assert.is_truthy(out:find("type:%s+int"))
    assert.is_truthy(out:find("default:%s+0"))
    assert.is_truthy(out:find("STORYBASE_ENGINE_NPC_SPEED", 1, true))
    assert.is_truthy(out:find("current:%s+0%s+%(from default%)"))
  end)

  it("errors on unknown key", function()
    local rc, _, err = run_cmd({"doc", "no.such.key"})
    assert.equals(1, rc)
    assert.is_truthy(err:find("unknown key"))
  end)
end)

describe("storybase config (no subcommand)", function()
  it("prints usage and exits 0", function()
    local rc, out = run_cmd({})
    assert.equals(0, rc)
    assert.is_truthy(out:find("config dump"))
    assert.is_truthy(out:find("config get"))
    assert.is_truthy(out:find("config doc"))
  end)

  it("rejects an unknown subcommand", function()
    local rc, _, err = run_cmd({"frobnicate"})
    assert.equals(1, rc)
    assert.is_truthy(err:find("unknown subcommand"))
  end)
end)

-- ── Global --config key=value flag through cli.main ─────────────────────

describe("global --config flag", function()
  before_each(clear_overrides)
  after_each(clear_overrides)

  it("populates the cli layer and surfaces via config get", function()
    local rc, out, err = run_main({"--config", "engine.npc-speed=4",
                                    "config", "get", "engine.npc-speed"})
    assert.equals(0, rc)
    assert.equals("4\n", out)
    -- HOME-rc parse errors may surface here; we only assert the value
    -- printed to stdout, not that stderr is fully empty.
    assert.is_string(err)
  end)

  it("supports --config=key=value single-token form", function()
    local rc, out = run_main({"--config=engine.scene-stack-max=99",
                               "config", "get", "engine.scene-stack-max"})
    assert.equals(0, rc)
    assert.equals("99\n", out)
  end)

  it("reports unknown keys but still runs the command", function()
    local rc, out, err = run_main({"--config", "bogus.key=1",
                                    "config", "get", "engine.npc-speed"})
    assert.equals(0, rc)
    assert.equals("0\n", out)
    assert.is_truthy(err:find("unknown key 'bogus.key'"))
  end)

  it("reports coercion failures but still runs the command", function()
    local rc, out, err = run_main({"--config", "engine.npc-speed=notanumber",
                                    "config", "get", "engine.npc-speed"})
    assert.equals(0, rc)
    assert.equals("0\n", out)
    assert.is_truthy(err:find("invalid integer"))
  end)

  it("reports malformed --config values without aborting", function()
    local rc, _, err = run_main({"--config", "no_equals_here",
                                  "config", "get", "engine.npc-speed"})
    assert.equals(0, rc)
    assert.is_truthy(err:find("malformed %-%-config"))
  end)

  it("rejects --config at end of args (no value token)", function()
    -- Trailing --config has no following token — extract reports the
    -- "needs an argument" warning, strips the flag, and the remaining
    -- argv ("config get engine.npc-speed") dispatches normally.
    local rc, out, err = run_main({"config", "get", "engine.npc-speed", "--config"})
    assert.equals(0, rc)
    assert.is_truthy(err:find("--config", 1, true))
    assert.is_truthy(out:find("\n", 1, true))
  end)
end)

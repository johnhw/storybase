-- tests/runtime/config_spec.lua
-- Unit tests for runtime/config.lua.
--
-- Run with:  busted tests/runtime/config_spec.lua

local config = require("runtime.config")

-- Helper: build a getenv stub from a table.
local function stub_env(t)
  return function(name) return t[name] end
end

-- Helper: write a temp file with given contents and return its path.
local function write_tmp(contents)
  local path = os.tmpname()
  local f = assert(io.open(path, "w"))
  f:write(contents)
  f:close()
  return path
end

describe("runtime.config", function()

  before_each(function() config._reset() end)

  -- ── declare / get / set basics ─────────────────────────────────

  describe("declare/get", function()

    it("registers a key and returns its default", function()
      config.declare("a.b", { type = "int", default = 7, doc = "x" })
      local v, layer = config.get("a.b")
      assert.are.equal(7, v)
      assert.are.equal("default", layer)
    end)

    it("returns nil/unset when default is nil and no layer set", function()
      config.declare("a.b", { type = "string" })
      local v, layer = config.get("a.b")
      assert.is_nil(v)
      assert.are.equal("unset", layer)
    end)

    it("errors on duplicate declare", function()
      config.declare("a.b", { type = "int", default = 1 })
      assert.has_error(function()
        config.declare("a.b", { type = "int", default = 2 })
      end)
    end)

    it("errors on get of undeclared key", function()
      assert.has_error(function() config.get("nope") end)
    end)

    it("errors on set of undeclared key", function()
      assert.has_error(function() config.set("nope", 1) end)
    end)

  end)

  -- ── set / runtime layer ────────────────────────────────────────

  describe("set", function()

    it("places value in runtime layer", function()
      config.declare("a.b", { type = "int", default = 1 })
      config.set("a.b", 42)
      local v, layer = config.get("a.b")
      assert.are.equal(42, v)
      assert.are.equal("runtime", layer)
    end)

    it("clears runtime override when set to nil", function()
      config.declare("a.b", { type = "int", default = 1 })
      config.set("a.b", 42)
      config.set("a.b", nil)
      local v, layer = config.get("a.b")
      assert.are.equal(1, v)
      assert.are.equal("default", layer)
    end)

    it("coerces values to the declared type", function()
      config.declare("a.b", { type = "int", default = 1 })
      config.set("a.b", "42")
      assert.are.equal(42, config.get("a.b"))
    end)

  end)

  -- ── set_cli (additive cli-layer write) ────────────────────────

  describe("set_cli", function()

    it("places a single key in the cli layer without clearing siblings", function()
      config.declare("a.first",  { type = "int", default = 0 })
      config.declare("a.second", { type = "int", default = 0 })
      config.bind_cli({ ["a.first"] = 1 })
      config.set_cli("a.second", 2)
      assert.are.equal(1, config.get("a.first"))
      assert.are.equal(2, config.get("a.second"))
      local _, layer = config.get("a.first")
      assert.are.equal("cli", layer)
    end)

    it("clears just the one key when value is nil", function()
      config.declare("a.k", { type = "int", default = 9 })
      config.set_cli("a.k", 7)
      assert.are.equal(7, config.get("a.k"))
      config.set_cli("a.k", nil)
      assert.are.equal(9, config.get("a.k"))
    end)

    it("coerces values like set/bind_cli", function()
      config.declare("a.k", { type = "int", default = 0 })
      config.set_cli("a.k", "11")
      assert.are.equal(11, config.get("a.k"))
    end)

    it("errors on unknown key", function()
      assert.has_error(function() config.set_cli("no.such.key", 1) end)
    end)

  end)

  -- ── Precedence ─────────────────────────────────────────────────

  describe("precedence", function()

    local function setup_all_layers()
      config.declare("p", { type = "int", default = 0, env = "P_ENV" })
      LAYERS_DEFAULT = 0
      config.bind_game({ schema = { engine_config = { p = 1 } } })
      -- Manually populate via api seams
      local path = write_tmp("p = 3\n")
      config.load_file(path)
      os.remove(path)
      config.load_env(stub_env({ P_ENV = "4" }))
      config.bind_cli({ p = 5 })
      config.set("p", 6)
    end

    it("runtime beats everything", function()
      config.declare("p", { type = "int", default = 0, env = "P_ENV" })
      -- engine.p would conflict, so use a different key for game layer:
      -- precedence test uses a plain key. game layer is namespace-checked
      -- only via bind_game's "engine." prefix, so for this test we use a
      -- value directly placed via the public API surface.
      local tmp = write_tmp("p = 3\n")
      config.load_file(tmp)
      os.remove(tmp)
      config.load_env(stub_env({ P_ENV = "4" }))
      config.bind_cli({ p = 5 })
      config.set("p", 6)
      local v, layer = config.get("p")
      assert.are.equal(6, v)
      assert.are.equal("runtime", layer)
    end)

    it("cli beats env, file, default", function()
      config.declare("p", { type = "int", default = 0, env = "P_ENV" })
      local tmp = write_tmp("p = 3\n")
      config.load_file(tmp); os.remove(tmp)
      config.load_env(stub_env({ P_ENV = "4" }))
      config.bind_cli({ p = 5 })
      local v, layer = config.get("p")
      assert.are.equal(5, v)
      assert.are.equal("cli", layer)
    end)

    it("env beats file and default", function()
      config.declare("p", { type = "int", default = 0, env = "P_ENV" })
      local tmp = write_tmp("p = 3\n")
      config.load_file(tmp); os.remove(tmp)
      config.load_env(stub_env({ P_ENV = "4" }))
      local v, layer = config.get("p")
      assert.are.equal(4, v)
      assert.are.equal("env", layer)
    end)

    it("file beats game and default", function()
      config.declare("engine.q", { type = "int", default = 0 })
      config.bind_game({ schema = { engine_config = { ["q"] = 1 } } })
      local tmp = write_tmp("engine.q = 3\n")
      config.load_file(tmp); os.remove(tmp)
      local v, layer = config.get("engine.q")
      assert.are.equal(3, v)
      assert.are.equal("file", layer)
    end)

    it("game beats default", function()
      config.declare("engine.q", { type = "int", default = 0 })
      config.bind_game({ schema = { engine_config = { ["q"] = 1 } } })
      local v, layer = config.get("engine.q")
      assert.are.equal(1, v)
      assert.are.equal("game", layer)
    end)

  end)

  -- ── Type coercion ──────────────────────────────────────────────

  describe("type coercion", function()

    it("coerces strings to ints", function()
      config.declare("k", { type = "int", default = 0 })
      config.set("k", "123")
      assert.are.equal(123, config.get("k"))
    end)

    it("rejects fractional strings for int type", function()
      config.declare("k", { type = "int", default = 0 })
      assert.has_error(function() config.set("k", "1.5") end)
    end)

    it("rejects non-numeric strings for int type", function()
      config.declare("k", { type = "int", default = 0 })
      assert.has_error(function() config.set("k", "abc") end)
    end)

    it("coerces strings to floats", function()
      config.declare("k", { type = "float", default = 0.0 })
      config.set("k", "1.5")
      assert.are.equal(1.5, config.get("k"))
    end)

    it("coerces bool from common string forms", function()
      config.declare("k", { type = "bool", default = false })
      for _, s in ipairs({ "true", "yes", "on", "1", "True", "YES" }) do
        config.set("k", s); assert.is_true(config.get("k"))
      end
      for _, s in ipairs({ "false", "no", "off", "0", "False" }) do
        config.set("k", s); assert.is_false(config.get("k"))
      end
    end)

    it("rejects invalid bool strings", function()
      config.declare("k", { type = "bool", default = false })
      assert.has_error(function() config.set("k", "maybe") end)
    end)

    it("validates enum values", function()
      config.declare("k", { type = "enum", default = "a", enum = { "a", "b", "c" } })
      config.set("k", "b")
      assert.are.equal("b", config.get("k"))
      assert.has_error(function() config.set("k", "z") end)
    end)

    it("uses custom coerce function when provided", function()
      config.declare("k", {
        type = "int", default = 0,
        coerce = function(v) return (tonumber(v) or 0) * 10 end,
      })
      config.set("k", "3")
      assert.are.equal(30, config.get("k"))
    end)

  end)

  -- ── Env var loading ────────────────────────────────────────────

  describe("load_env", function()

    it("auto-derives env var name from key", function()
      config.declare("engine.scene-stack-max", { type = "int", default = 64 })
      config.load_env(stub_env({ STORYBASE_ENGINE_SCENE_STACK_MAX = "128" }))
      local v, layer = config.get("engine.scene-stack-max")
      assert.are.equal(128, v)
      assert.are.equal("env", layer)
    end)

    it("honors explicit env name in spec", function()
      config.declare("debug.port", { type = "int", default = 7373, env = "SB_DBG" })
      config.load_env(stub_env({ SB_DBG = "9000" }))
      assert.are.equal(9000, config.get("debug.port"))
    end)

    it("ignores empty env values", function()
      config.declare("k", { type = "string", default = "x" })
      config.load_env(stub_env({ STORYBASE_K = "" }))
      assert.are.equal("x", config.get("k"))
    end)

    it("ignores env vars not matching any declared key", function()
      config.declare("k", { type = "int", default = 1 })
      config.load_env(stub_env({ STORYBASE_OTHER = "999" }))
      assert.are.equal(1, config.get("k"))
    end)

  end)

  -- ── File loading ───────────────────────────────────────────────

  describe("load_file", function()

    it("parses simple key=value lines", function()
      config.declare("engine.scene-stack-max", { type = "int", default = 64 })
      config.declare("debug.bind", { type = "string", default = "127.0.0.1" })
      local path = write_tmp([[
engine.scene-stack-max = 128
debug.bind = 0.0.0.0
]])
      local ok, errs = config.load_file(path)
      os.remove(path)
      assert.is_true(ok)
      assert.are.equal(0, #errs)
      assert.are.equal(128, config.get("engine.scene-stack-max"))
      assert.are.equal("0.0.0.0", config.get("debug.bind"))
    end)

    it("ignores blank lines and # comments", function()
      config.declare("k", { type = "int", default = 0 })
      local path = write_tmp([[
# leading comment
   # indented comment

k = 5

]])
      local ok, errs = config.load_file(path)
      os.remove(path)
      assert.is_true(ok)
      assert.are.equal(5, config.get("k"))
    end)

    it("strips surrounding double and single quotes", function()
      config.declare("k", { type = "string", default = "" })
      local path = write_tmp([[k = "hello world"]] .. "\n")
      config.load_file(path); os.remove(path)
      assert.are.equal("hello world", config.get("k"))

      local path2 = write_tmp([[k = 'hello world']] .. "\n")
      config.load_file(path2); os.remove(path2)
      assert.are.equal("hello world", config.get("k"))
    end)

    it("returns errors for unknown keys but still applies valid lines", function()
      config.declare("good", { type = "int", default = 0 })
      local path = write_tmp([[
good = 7
unknown.key = 9
]])
      local ok, errs = config.load_file(path)
      os.remove(path)
      assert.is_false(ok)
      assert.are.equal(1, #errs)
      assert.is_truthy(errs[1]:match("unknown config key"))
      assert.are.equal(7, config.get("good"))
    end)

    it("returns errors for malformed lines", function()
      config.declare("k", { type = "int", default = 0 })
      local path = write_tmp([[
k = 1
this line has no equals
]])
      local ok, errs = config.load_file(path)
      os.remove(path)
      assert.is_false(ok)
      assert.are.equal(1, #errs)
      assert.is_truthy(errs[1]:match("malformed line"))
    end)

    it("returns error when file does not exist", function()
      local ok, errs = config.load_file("/no/such/path/x.conf")
      assert.is_false(ok)
      assert.is_table(errs)
      assert.is_truthy(#errs >= 1)
    end)

    it("collects coercion errors and continues", function()
      config.declare("n", { type = "int", default = 0 })
      config.declare("s", { type = "string", default = "" })
      local path = write_tmp([[
n = not-a-number
s = ok
]])
      local ok, errs = config.load_file(path)
      os.remove(path)
      assert.is_false(ok)
      assert.are.equal(1, #errs)
      assert.are.equal("ok", config.get("s"))
    end)

  end)

  -- ── bind_game ──────────────────────────────────────────────────

  describe("bind_game", function()

    it("loads engine_config block into game layer with engine.* prefix", function()
      config.declare("engine.scene-stack-max", { type = "int", default = 64 })
      config.bind_game({
        schema = { engine_config = { ["scene-stack-max"] = 128 } },
      })
      local v, layer = config.get("engine.scene-stack-max")
      assert.are.equal(128, v)
      assert.are.equal("game", layer)
    end)

    it("silently ignores undeclared engine_config keys", function()
      config.declare("engine.scene-stack-max", { type = "int", default = 64 })
      config.bind_game({
        schema = { engine_config = {
          ["scene-stack-max"] = 128,
          ["unknown-knob"] = "whatever",
        } },
      })
      assert.are.equal(128, config.get("engine.scene-stack-max"))
    end)

    it("is a no-op when game_table has no engine_config", function()
      config.declare("engine.scene-stack-max", { type = "int", default = 64 })
      config.bind_game({ schema = {} })
      assert.are.equal(64, config.get("engine.scene-stack-max"))
      assert.are.equal("default", select(2, config.get("engine.scene-stack-max")))
    end)

    it("clears prior game-layer values when called again", function()
      config.declare("engine.scene-stack-max", { type = "int", default = 64 })
      config.bind_game({ schema = { engine_config = { ["scene-stack-max"] = 128 } } })
      config.bind_game({ schema = { engine_config = {} } })
      local v, layer = config.get("engine.scene-stack-max")
      assert.are.equal(64, v)
      assert.are.equal("default", layer)
    end)

  end)

  -- ── bind_cli ───────────────────────────────────────────────────

  describe("bind_cli", function()

    it("populates the cli layer", function()
      config.declare("debug.port", { type = "int", default = 7373 })
      config.bind_cli({ ["debug.port"] = 9000 })
      local v, layer = config.get("debug.port")
      assert.are.equal(9000, v)
      assert.are.equal("cli", layer)
    end)

    it("errors on unknown keys", function()
      assert.has_error(function() config.bind_cli({ ["nope"] = 1 }) end)
    end)

    it("clears prior cli values when called again", function()
      config.declare("debug.port", { type = "int", default = 7373 })
      config.bind_cli({ ["debug.port"] = 9000 })
      config.bind_cli({})
      assert.are.equal(7373, config.get("debug.port"))
    end)

  end)

  -- ── dump / keys / spec ────────────────────────────────────────

  describe("dump", function()

    it("returns all keys with resolved value and winning layer", function()
      config.declare("a", { type = "int", default = 1, doc = "alpha" })
      config.declare("b", { type = "string", default = "x", doc = "beta" })
      config.set("a", 99)
      local d = config.dump()
      assert.are.equal(99, d.a.value)
      assert.are.equal("runtime", d.a.layer)
      assert.are.equal("alpha", d.a.doc)
      assert.are.equal("x", d.b.value)
      assert.are.equal("default", d.b.layer)
    end)

  end)

  describe("keys / spec", function()

    it("keys() returns a sorted list", function()
      config.declare("b", { type = "int", default = 0 })
      config.declare("a", { type = "int", default = 0 })
      config.declare("c", { type = "int", default = 0 })
      local ks = config.keys()
      assert.are.same({ "a", "b", "c" }, ks)
    end)

    it("spec() returns the registered spec table", function()
      config.declare("k", { type = "int", default = 0, doc = "hi" })
      local s = config.spec("k")
      assert.are.equal("int", s.type)
      assert.are.equal("hi", s.doc)
    end)

    it("spec() returns nil for undeclared keys", function()
      assert.is_nil(config.spec("nope"))
    end)

  end)

  -- ── load_startup orchestration ────────────────────────────────

  describe("load_startup", function()

    -- Build an isolated home + cwd pair under os.tmpname()'s directory.
    local function mk_home_cwd()
      local base = os.tmpname()
      os.remove(base)
      local home = base .. "_home"
      local cwd  = base .. "_cwd"
      assert(os.execute("mkdir -p " .. home))
      assert(os.execute("mkdir -p " .. cwd))
      return home, cwd
    end

    local function write(path, contents)
      local f = assert(io.open(path, "w"))
      f:write(contents)
      f:close()
    end

    local function rmrf(path)
      os.execute("rm -rf " .. path)
    end

    it("loads only home file when cwd file is absent", function()
      config.declare("a", { type = "int" })
      local home, cwd = mk_home_cwd()
      write(home .. "/.storybaserc", "a = 11\n")
      local errs, sources = config.load_startup({
        home = home, cwd = cwd, getenv = function() end,
      })
      assert.are.same({}, errs)
      assert.are.same({ home .. "/.storybaserc" }, sources)
      local v, layer = config.get("a")
      assert.equal(11, v)
      assert.equal("file", layer)
      rmrf(home); rmrf(cwd)
    end)

    it("cwd file overrides home file for the same key (later wins)", function()
      config.declare("a", { type = "int" })
      local home, cwd = mk_home_cwd()
      write(home .. "/.storybaserc", "a = 11\n")
      write(cwd  .. "/.storybaserc", "a = 22\n")
      local errs, sources = config.load_startup({
        home = home, cwd = cwd, getenv = function() end,
      })
      assert.are.same({}, errs)
      assert.equal(2, #sources)
      assert.equal(22, (config.get("a")))
      rmrf(home); rmrf(cwd)
    end)

    it("env var beats both files", function()
      config.declare("a", { type = "int" })
      local home, cwd = mk_home_cwd()
      write(home .. "/.storybaserc", "a = 11\n")
      write(cwd  .. "/.storybaserc", "a = 22\n")
      local errs = config.load_startup({
        home = home, cwd = cwd,
        getenv = stub_env({ STORYBASE_A = "99" }),
      })
      assert.are.same({}, errs)
      local v, layer = config.get("a")
      assert.equal(99, v)
      assert.equal("env", layer)
      rmrf(home); rmrf(cwd)
    end)

    it("missing files are silently skipped", function()
      config.declare("a", { type = "int", default = 5 })
      local home, cwd = mk_home_cwd()
      -- neither directory has a .storybaserc
      local errs, sources = config.load_startup({
        home = home, cwd = cwd, getenv = function() end,
      })
      assert.are.same({}, errs)
      assert.are.same({}, sources)
      assert.equal(5, (config.get("a")))
      rmrf(home); rmrf(cwd)
    end)

    it("collects parse errors but keeps loading valid keys", function()
      config.declare("a", { type = "int" })
      local home, cwd = mk_home_cwd()
      write(cwd .. "/.storybaserc", "a = 7\nb = nope\n")
      local errs = config.load_startup({
        home = home, cwd = cwd, getenv = function() end,
      })
      assert.equal(1, #errs)
      assert.matches("unknown config key: b", errs[1])
      assert.equal(7, (config.get("a")))
      rmrf(home); rmrf(cwd)
    end)

    it("accepts nil home directory (cwd-only)", function()
      config.declare("a", { type = "int" })
      local _, cwd = mk_home_cwd()
      write(cwd .. "/.storybaserc", "a = 4\n")
      local errs = config.load_startup({
        home = nil, cwd = cwd, getenv = function() end,
      })
      assert.are.same({}, errs)
      assert.equal(4, (config.get("a")))
      rmrf(cwd)
    end)

  end)

end)

-- tests/cli/migrate_cmd_spec.lua
-- Unit tests for cli/migrate_cmd.lua.
--
-- Drives migrate_cmd.M.run with captured stdout/stderr, building tiny
-- .sb game files and matching save logs on the fly so each test covers
-- one path in isolation.

local migrate_cmd = require("cli.migrate_cmd")

local function capture_run(args)
  local out_path = os.tmpname()
  local err_path = os.tmpname()
  local saved_out, saved_err = io.stdout, io.stderr
  io.stdout = assert(io.open(out_path, "w"))
  io.stderr = assert(io.open(err_path, "w"))
  local ok, code = pcall(migrate_cmd.run, args)
  io.stdout:close(); io.stderr:close()
  io.stdout, io.stderr = saved_out, saved_err
  local of = io.open(out_path, "r"); local out = of:read("*a"); of:close()
  local ef = io.open(err_path, "r"); local err = ef:read("*a"); ef:close()
  os.remove(out_path); os.remove(err_path)
  if not ok then error(code) end
  return code, out, err
end

local function tmpfile(src, ext)
  local p = os.tmpname() .. (ext or ".sb")
  local f = io.open(p, "w"); f:write(src); f:close()
  return p
end

--- Build a save file at the given path with the given cache entries.
--- schema_version is the version field; entries is a list of log entries.
local function write_save(path, schema_version, cache_entries)
  local f = io.open(path, "w")
  f:write("local save = {}\n")
  f:write("save.version = 1\n")
  f:write("save.schema_version = ", tostring(schema_version), "\n")
  f:write("save.scene_stack = {}\n")
  f:write("save.entries = {\n")
  local seq = 0
  for path_key, val in pairs(cache_entries or {}) do
    seq = seq + 1
    local vrepr
    if type(val) == "string" then
      vrepr = string.format("%q", val)
    elseif type(val) == "number" or type(val) == "boolean" then
      vrepr = tostring(val)
    else
      error("unsupported save value type: " .. type(val))
    end
    f:write(string.format("  {seq=%d, fn=%q, path=%q, old=nil, [\"new\"]=%s},\n",
      seq, "init", path_key, vrepr))
  end
  f:write("}\n")
  f:write("return save\n")
  f:close()
end

-- ── tests ──────────────────────────────────────────────────────

describe("migrate_cmd — usage errors", function()
  it("exits 1 with usage message when called with no args", function()
    local code, _, err = capture_run({})
    assert.equals(1, code)
    assert.is_truthy(err:find("usage") or err:find("no input"),
      "expected usage hint; got: " .. err)
  end)

  it("exits 1 when save file is missing from args", function()
    local code, _, err = capture_run({"some-game.sb"})
    assert.equals(1, code)
    assert.is_truthy(err:find("no save log"))
  end)
end)

describe("migrate_cmd — compilation failure", function()
  it("exits 1 when the game file does not compile", function()
    local bad = tmpfile([[
this is not a valid storybase file
]])
    local save = tmpfile("local save = {}\nsave.schema_version = 1\nsave.entries = {}\nreturn save\n", ".log")
    local code, _, err = capture_run({bad, save})
    os.remove(bad); os.remove(save)
    assert.equals(1, code)
    assert.is_truthy(err:find("Compilation failed") or err:find("error"))
  end)

  it("exits 1 on missing game file", function()
    local missing = "/tmp/no-such-game-" .. os.time() .. ".sb"
    local save = tmpfile("local save = {}\nsave.schema_version = 1\nsave.entries = {}\nreturn save\n", ".log")
    local code, _, err = capture_run({missing, save})
    os.remove(save)
    assert.equals(1, code)
    assert.is_truthy(err:find("Compilation failed") or err:find("FILE_NOT_FOUND")
                     or err:find("Cannot open"))
  end)
end)

describe("migrate_cmd — no migrations", function()
  it("exits 0 with 'nothing to do' when game has no migration blocks", function()
    local game = tmpfile([[
schema-version: 1

engine-config:
  entry-scene: main

state world/x: Int(0,9) = 0

scene main:
  * Go -> main
]])
    local save = tmpfile([[
local save = {}
save.schema_version = 1
save.entries = {}
return save
]], ".log")
    local code, out, _ = capture_run({game, save})
    os.remove(game); os.remove(save)
    assert.equals(0, code)
    assert.is_truthy(out:find("Nothing to do"))
  end)
end)

describe("migrate_cmd — save already at game version", function()
  it("exits 0 with 'already at version' when versions match", function()
    local game = tmpfile([[
schema-version: 2

engine-config:
  entry-scene: main

state world/x: Int(0,99) = 0

migration 1 -> 2:
  add world/x = 0

scene main:
  * Go -> main
]])
    -- Save version is already 2 (game version)
    local save_path = os.tmpname() .. ".log"
    write_save(save_path, 2, {["world/x"] = 5})
    local code, out, _ = capture_run({game, save_path})
    os.remove(game); os.remove(save_path)
    assert.equals(0, code)
    assert.is_truthy(out:find("already at version") or out:find("No migration needed"))
  end)
end)

describe("migrate_cmd — successful migration", function()
  it("migrates a v1 save to v2 schema and reports success", function()
    local game = tmpfile([[
schema-version: 2

engine-config:
  entry-scene: main

state world/score:  Int(0,9999) = 0
state world/bonus:  Int(0,9999) = 0

migration 1 -> 2:
  add world/bonus = 0

scene main:
  * Go -> main
]])
    local save_path = os.tmpname() .. ".log"
    write_save(save_path, 1, {["world/score"] = 42})
    local out_path = save_path:gsub("%.log$", ".migrated.log")
    local code, out, _ = capture_run({game, save_path})
    assert.equals(0, code, "expected success exit")
    assert.is_truthy(out:find("Migrated"))
    assert.is_truthy(out:find("v1 → v2"))

    -- The migrated save file should exist and contain the new schema_version
    local f = io.open(out_path, "r")
    assert.is_not_nil(f, "migrated save file should exist at " .. out_path)
    local content = f:read("*a"); f:close()
    assert.is_truthy(content:find("schema_version = 2"))

    os.remove(game); os.remove(save_path); os.remove(out_path)
  end)

  it("--out flag writes to a custom destination", function()
    local game = tmpfile([[
schema-version: 2

engine-config:
  entry-scene: main

state world/score: Int(0,9999) = 0
state world/bonus: Int(0,9999) = 0

migration 1 -> 2:
  add world/bonus = 0

scene main:
  * Go -> main
]])
    local save_path = os.tmpname() .. ".log"
    write_save(save_path, 1, {["world/score"] = 7})
    local out_path = os.tmpname() .. "_custom_dest.log"
    local code, out, _ = capture_run({game, save_path, "--out", out_path})
    assert.equals(0, code)
    assert.is_truthy(out:find(out_path, 1, true))
    local f = io.open(out_path, "r")
    assert.is_not_nil(f)
    f:close()
    os.remove(game); os.remove(save_path); os.remove(out_path)
  end)
end)

describe("migrate_cmd — corrupt save file", function()
  it("exits 1 when save file fails to parse", function()
    local game = tmpfile([[
schema-version: 2

engine-config:
  entry-scene: main

state world/x: Int(0,9) = 0

migration 1 -> 2:
  add world/x = 0

scene main:
  * Go -> main
]])
    local bad_save = tmpfile("this is not valid lua $$$$", ".log")
    local code, _, err = capture_run({game, bad_save})
    os.remove(game); os.remove(bad_save)
    assert.equals(1, code)
    assert.is_truthy(err:find("parse error") or err:find("exec error"))
  end)

  it("exits 1 when save file does not exist", function()
    local game = tmpfile([[
schema-version: 2

engine-config:
  entry-scene: main

state world/x: Int(0,9) = 0

migration 1 -> 2:
  add world/x = 0

scene main:
  * Go -> main
]])
    local missing = "/tmp/no-save-" .. os.time() .. ".log"
    local code, _, err = capture_run({game, missing})
    os.remove(game)
    assert.equals(1, code)
    assert.is_truthy(err:find("cannot open save"))
  end)
end)

describe("migrate_cmd — sad path does not leak via globals", function()
  -- This is a regression test for the previous `has_errors` bug, where the
  -- variable was implicit-global and a failed-migration run could leave it
  -- set to `true` for subsequent runs.
  it("a successful run after a failed run still reports success", function()
    -- The failure case: incomplete migration chain (game expects v3, save v1, only 1->2 block)
    local fail_game = tmpfile([[
schema-version: 3

engine-config:
  entry-scene: main

state world/x: Int(0,9999) = 0

migration 1 -> 2:
  add world/x = 0

scene main:
  * Go -> main
]])
    local save_path = os.tmpname() .. ".log"
    write_save(save_path, 1, {})
    local code_fail, _, _ = capture_run({fail_game, save_path})
    -- This may succeed or fail depending on migration completeness; we
    -- mainly want to ensure the success case below is not contaminated.

    -- Clear any stale output file
    local fail_out = save_path:gsub("%.log$", ".migrated.log")
    os.remove(fail_out)

    -- Now a clean run
    local ok_game = tmpfile([[
schema-version: 2

engine-config:
  entry-scene: main

state world/x: Int(0,9999) = 0
state world/y: Int(0,9999) = 0

migration 1 -> 2:
  add world/y = 0

scene main:
  * Go -> main
]])
    local save_path2 = os.tmpname() .. ".log"
    write_save(save_path2, 1, {["world/x"] = 1})
    local code_ok, out, _ = capture_run({ok_game, save_path2})

    os.remove(fail_game); os.remove(save_path); os.remove(fail_out)
    os.remove(ok_game); os.remove(save_path2)
    os.remove(save_path2:gsub("%.log$", ".migrated.log"))

    assert.equals(0, code_ok, "second (clean) run should succeed")
    assert.is_truthy(out:find("Migrated"))
    -- code_fail is informational; we don't assert its specific value
    local _ = code_fail
  end)
end)

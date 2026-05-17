-- tests/cli/verify_cache_spec.lua
-- Unit + integration tests for cli/verify_cache.lua and the --no-cache /
-- --clear-cache flags in cli/verify_cmd.lua.

local cache_mod  = require("cli.verify_cache")
local verify_cmd = require("cli.verify_cmd")
local compiler   = require("compiler.compiler")

local function compile(src)
  local gt, diags = compiler.compile(src, "test.sb")
  local errs = {}
  for _, d in ipairs(diags and diags.all or {}) do
    if d.level == "error" then errs[#errs+1] = d end
  end
  return gt, errs
end

local function tmpfile(src, suffix)
  local p = os.tmpname() .. (suffix or ".sb")
  local f = io.open(p, "w"); f:write(src); f:close()
  return p
end

local function tmpdir()
  local d = os.tmpname()
  os.remove(d)
  os.execute("mkdir -p " .. string.format("%q", d))
  return d
end

local function rmrf(path)
  os.execute("rm -rf " .. string.format("%q", path) .. " 2>/dev/null")
end

local function capture_run(args)
  local out_path = os.tmpname()
  local err_path = os.tmpname()
  local saved_out, saved_err = io.stdout, io.stderr
  io.stdout = assert(io.open(out_path, "w"))
  io.stderr = assert(io.open(err_path, "w"))
  local ok, code = pcall(verify_cmd.run, args)
  io.stdout:close(); io.stderr:close()
  io.stdout, io.stderr = saved_out, saved_err
  local of = io.open(out_path, "r"); local out = of:read("*a"); of:close()
  local ef = io.open(err_path, "r"); local err = ef:read("*a"); ef:close()
  os.remove(out_path); os.remove(err_path)
  if not ok then error(code) end
  return code, out, err
end

-- ============================================================
-- Hash determinism + insensitivity
-- ============================================================

describe("verify_cache.compute_hash", function()

  it("yields the same hash across compiles of identical source", function()
    local src = [[
engine-config:
  entry-scene: main
state world/x: Int(0, 9) = 0
verify "x ok":
  verify-always world/x >= 0
scene main:
  * Go -> main
]]
    local gt1 = assert(compile(src))
    local gt2 = assert(compile(src))
    local h1 = cache_mod.compute_hash(gt1.verifies[1], gt1)
    local h2 = cache_mod.compute_hash(gt2.verifies[1], gt2)
    assert.equals(h1, h2)
  end)

  it("ignores cosmetic changes (extra blank lines)", function()
    local a = [[
engine-config:
  entry-scene: main
state world/x: Int(0, 9) = 0
verify "x ok":
  verify-always world/x >= 0
scene main:
  * Go -> main
]]
    local b = [[


engine-config:
  entry-scene: main

state world/x: Int(0, 9) = 0


verify "x ok":
  verify-always world/x >= 0


scene main:
  * Go -> main
]]
    local gt1 = assert(compile(a))
    local gt2 = assert(compile(b))
    local h1 = cache_mod.compute_hash(gt1.verifies[1], gt1)
    local h2 = cache_mod.compute_hash(gt2.verifies[1], gt2)
    assert.equals(h1, h2)
  end)

  it("changes when the verify-block AST changes", function()
    local a = [[
engine-config:
  entry-scene: main
state world/x: Int(0, 9) = 0
verify "x ok":
  verify-always world/x >= 0
scene main:
  * Go -> main
]]
    local b = [[
engine-config:
  entry-scene: main
state world/x: Int(0, 9) = 0
verify "x ok":
  verify-always world/x >= 1
scene main:
  * Go -> main
]]
    local gt1 = assert(compile(a))
    local gt2 = assert(compile(b))
    local h1 = cache_mod.compute_hash(gt1.verifies[1], gt1)
    local h2 = cache_mod.compute_hash(gt2.verifies[1], gt2)
    assert.are_not.equals(h1, h2)
  end)

  it("changes when a transitively-reached fn changes", function()
    -- after-style verify: depends on the AST of the directly-called fn.
    local a = [[
engine-config:
  entry-scene: main
state world/x: Int(0, 99) = 50
fn add5:
  inc! world/x 5
verify "add5 increases":
  after (add5):
    world/x > world/x@before
scene main:
  * Go -> main
]]
    local b = a:gsub("inc! world/x 5", "inc! world/x 6")
    local gt1 = assert(compile(a))
    local gt2 = assert(compile(b))
    local h1 = cache_mod.compute_hash(gt1.verifies[1], gt1)
    local h2 = cache_mod.compute_hash(gt2.verifies[1], gt2)
    assert.are_not.equals(h1, h2)
  end)

  it("ignores changes to a fn outside the dependency closure (after-style)", function()
    -- Two fns: only `add5` is in the verify's closure. Edits to `unrelated`
    -- must not invalidate the cached hash for the verify.
    local a = [[
engine-config:
  entry-scene: main
state world:
  x: Int(0, 99) = 50
  y: Int(0, 99) = 50
fn add5:
  inc! world/x 5
fn unrelated:
  inc! world/y 1
verify "add5 increases":
  after (add5):
    world/x > world/x@before
scene main:
  * Go -> main
]]
    -- Edit ONLY `unrelated`. The verify's after-closure {add5} is unchanged.
    local b = a:gsub("inc! world/y 1", "inc! world/y 7")
    local gt1 = assert(compile(a))
    local gt2 = assert(compile(b))
    local h1 = cache_mod.compute_hash(gt1.verifies[1], gt1)
    local h2 = cache_mod.compute_hash(gt2.verifies[1], gt2)
    assert.equals(h1, h2,
      "after-style verify should not depend on fns outside its call closure")
  end)

  it("changes when the schema changes", function()
    local a = [[
engine-config:
  entry-scene: main
state world/x: Int(0, 9) = 0
verify "x ok":
  verify-always world/x >= 0
scene main:
  * Go -> main
]]
    local b = a:gsub("Int%(0, 9%)", "Int(0, 99)")
    local gt1 = assert(compile(a))
    local gt2 = assert(compile(b))
    local h1 = cache_mod.compute_hash(gt1.verifies[1], gt1)
    local h2 = cache_mod.compute_hash(gt2.verifies[1], gt2)
    assert.are_not.equals(h1, h2)
  end)

end)

-- ============================================================
-- Cache file I/O
-- ============================================================

describe("verify_cache load/save", function()

  it("load returns an empty cache when no file exists", function()
    local dir = tmpdir()
    rmrf(dir)  -- ensure clean
    local c = cache_mod.load(dir)
    assert.equals(cache_mod.CACHE_VERSION, c.version)
    assert.same({}, c.entries)
    rmrf(dir)
  end)

  it("save then load round-trips entries", function()
    local dir = tmpdir()
    local c = cache_mod.load(dir)
    cache_mod.put(c, "abc123", { label = "foo", pass = true, states_checked = 7 })
    local ok = cache_mod.save(c, dir)
    assert.is_true(ok)
    local c2 = cache_mod.load(dir)
    local e = cache_mod.get(c2, "abc123")
    assert.is_not_nil(e)
    assert.equals("foo", e.label)
    assert.is_true(e.pass)
    assert.equals(7, e.states_checked)
    rmrf(dir)
  end)

  it("load ignores a cache file with a bumped version", function()
    local dir = tmpdir()
    os.execute("mkdir -p " .. string.format("%q", dir))
    local path = cache_mod.cache_path(dir)
    local f = io.open(path, "w")
    f:write('{"version":999,"entries":{"x":{"label":"y","pass":true}}}'); f:close()
    local c = cache_mod.load(dir)
    assert.same({}, c.entries)
    rmrf(dir)
  end)

  it("load tolerates a malformed cache file", function()
    local dir = tmpdir()
    os.execute("mkdir -p " .. string.format("%q", dir))
    local path = cache_mod.cache_path(dir)
    local f = io.open(path, "w"); f:write("this is not json"); f:close()
    local c = cache_mod.load(dir)
    assert.same({}, c.entries)
    rmrf(dir)
  end)

end)

-- ============================================================
-- End-to-end via verify_cmd
-- ============================================================

describe("verify_cmd cache integration", function()

  local src_two_blocks = [[
engine-config:
  entry-scene: main
state world:
  x: Int(0, 99) = 50
  y: Int(0, 99) = 50
fn add5:
  inc! world/x 5
fn add3:
  inc! world/y 3
verify "add5 ok":
  after (add5):
    world/x > world/x@before
verify "add3 ok":
  after (add3):
    world/y > world/y@before
scene main:
  * Go -> main
]]

  it("re-running marks blocks as [cached]", function()
    local path = tmpfile(src_two_blocks)
    local dir  = tmpdir()
    capture_run({ path, "--cache-dir", dir })
    local _, out2 = capture_run({ path, "--cache-dir", dir })
    assert.is_truthy(out2:find("%[cached%]"), "expected [cached] marker on rerun")
    assert.is_truthy(out2:find("2 cached"))
    os.remove(path); rmrf(dir)
  end)

  it("--no-cache forces all blocks to re-run", function()
    local path = tmpfile(src_two_blocks)
    local dir  = tmpdir()
    capture_run({ path, "--cache-dir", dir })
    local _, out2 = capture_run({ path, "--cache-dir", dir, "--no-cache" })
    assert.is_nil(out2:find("%[cached%]"))
    os.remove(path); rmrf(dir)
  end)

  it("editing one fn re-runs only the affected block", function()
    local path = tmpfile(src_two_blocks)
    local dir  = tmpdir()
    capture_run({ path, "--cache-dir", dir })

    -- Edit only `add5` (and the verify "add5 ok" depends on `add5` only).
    local f = io.open(path, "r"); local s = f:read("*a"); f:close()
    s = s:gsub("inc! world/x 5", "inc! world/x 6")
    f = io.open(path, "w"); f:write(s); f:close()

    local _, out2 = capture_run({ path, "--cache-dir", dir })
    -- "add3 ok" stays cached, "add5 ok" reruns.
    assert.is_truthy(out2:find("add3 ok %[cached%]"))
    assert.is_nil(out2:find("add5 ok %[cached%]"))
    os.remove(path); rmrf(dir)
  end)

  it("--clear-cache removes prior entries", function()
    local path = tmpfile(src_two_blocks)
    local dir  = tmpdir()
    capture_run({ path, "--cache-dir", dir })  -- populate
    local _, out2 = capture_run({ path, "--cache-dir", dir, "--clear-cache" })
    assert.is_nil(out2:find("%[cached%]"),
      "after --clear-cache, no entry should be reported as cached")
    os.remove(path); rmrf(dir)
  end)

  it("failing verifies are also cached", function()
    local fail_src = [[
engine-config:
  entry-scene: main
state world/x: Int(0, 99) = 5
fn bust:
  dec! world/x 10
verify "x stays high":
  verify-always world/x > 0
scene main:
  * Bust
    bust
    -> main
]]
    local path = tmpfile(fail_src)
    local dir  = tmpdir()
    local code1, _, _ = capture_run({ path, "--cache-dir", dir })
    assert.equals(1, code1)
    local code2, out2, _ = capture_run({ path, "--cache-dir", dir })
    assert.equals(1, code2)
    assert.is_truthy(out2:find("FAIL"))
    assert.is_truthy(out2:find("%[cached%]"))
    os.remove(path); rmrf(dir)
  end)

end)

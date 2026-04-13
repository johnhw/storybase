-- tests/fuzz/parser_fuzz_spec.lua
-- Property test: random token sequences never crash the parser.
--
-- Invariant: compiler.compile(random_source) never raises an uncaught error;
-- it always returns either a game_table or nil with diagnostics.

local compiler_mod = require("compiler.compiler")

-- ── Helpers ──────────────────────────────────────────────────────────────────

math.randomseed(42)

--- Generate a random string of length n from chars.
local function rand_str(n, chars)
  chars = chars or "abcdefghijklmnopqrstuvwxyz-_/ "
  local parts = {}
  for _ = 1, n do
    local i = math.random(1, #chars)
    parts[#parts+1] = chars:sub(i, i)
  end
  return table.concat(parts)
end

--- Generate random source that is structurally plausible but syntactically noisy.
--- May or may not compile successfully.
local function random_source(seed)
  math.randomseed(seed)
  local lines = {}
  -- Always add a module header so at least the first pass works
  lines[#lines+1] = "module fuzz-" .. seed
  lines[#lines+1] = "  version: 1.0"
  lines[#lines+1] = "engine-config:"
  lines[#lines+1] = "  entry-scene: main"
  lines[#lines+1] = "schema-version: 1"

  -- Randomly add state, fn, scene declarations with noisy content
  local templates = {
    function() return "state " .. rand_str(math.random(2,8), "abcdefghijklmnopqrstuvwxyz-") .. ":\n  x: Int(0, 10) = 0" end,
    function() return "fn " .. rand_str(math.random(2,8), "abcdefghijklmnopqrstuvwxyz-") .. ":\n  pass" end,
    function() return "scene " .. rand_str(math.random(2,8), "abcdefghijklmnopqrstuvwxyz-") .. ":\n  * Go\n    -> main" end,
    function() return rand_str(math.random(5, 40)) end,
    function() return "!@#$%^&*()" end,
    function() return "fn bad body:\n  " .. rand_str(math.random(5, 30)) end,
  }

  for _ = 1, math.random(1, 6) do
    local t = templates[math.random(1, #templates)]
    lines[#lines+1] = t()
  end

  -- Always end with a valid scene so the compiler has something to work with
  lines[#lines+1] = "scene main:\n  * End\n    -> main"

  return table.concat(lines, "\n")
end

--- Try compiling a source; return true if it didn't crash, false otherwise.
local function safe_compile(src)
  local ok, result = pcall(compiler_mod.compile, src, "fuzz.sb")
  -- ok=true means no uncaught error (result may be nil on compile failure — that's fine)
  return ok, result
end

-- ── Tests ────────────────────────────────────────────────────────────────────

describe("parser fuzz — no crash on random input", function()

  it("empty string does not crash", function()
    local ok = safe_compile("")
    assert.is_true(ok)
  end)

  it("whitespace-only input does not crash", function()
    local ok = safe_compile("   \n\t\n  ")
    assert.is_true(ok)
  end)

  it("binary garbage does not crash", function()
    local garbage = ""
    for i = 1, 200 do garbage = garbage .. string.char(math.random(0, 127)) end
    local ok = safe_compile(garbage)
    assert.is_true(ok)
  end)

  it("50 random seeds all return without crashing", function()
    for seed = 1, 50 do
      local src = random_source(seed)
      local ok, _ = safe_compile(src)
      assert.is_true(ok,
        "compiler crashed on seed " .. seed .. "\nsource:\n" .. src:sub(1, 200))
    end
  end)

  it("deeply nested if/when does not crash", function()
    local parts = { "module deep version: 1.0 engine-config: entry-scene: s schema-version: 1" }
    parts[#parts+1] = "state w: x: Bool = false"
    parts[#parts+1] = "fn deep:"
    local indent = "  "
    for i = 1, 20 do
      parts[#parts+1] = indent .. "if w/x"
      indent = indent .. "  "
    end
    parts[#parts+1] = indent .. "pass"
    parts[#parts+1] = "scene s: * Go -> s"
    local ok = safe_compile(table.concat(parts, "\n"))
    assert.is_true(ok)
  end)

  it("very long identifier does not crash", function()
    local long_name = string.rep("a", 500)
    local src = "module m version: 1.0 engine-config: entry-scene: s schema-version: 1\nfn " .. long_name .. ":\n  pass\nscene s: * Go -> s"
    local ok = safe_compile(src)
    assert.is_true(ok)
  end)

  it("extremely long source line does not crash", function()
    local long_line = string.rep("x", 10000)
    local ok = safe_compile(long_line)
    assert.is_true(ok)
  end)

  it("only keywords and operators does not crash", function()
    local src = "fn if when match for while let set! inc! dec! spawn! despawn! -> scene"
    local ok = safe_compile(src)
    assert.is_true(ok)
  end)

  it("missing colon after module does not crash", function()
    local ok = safe_compile("module no-version engine-config entry-scene main scene s * Go -> s")
    assert.is_true(ok)
  end)

  it("repeated parse of same source is deterministic", function()
    local src = random_source(999)
    local ok1, r1 = safe_compile(src)
    local ok2, r2 = safe_compile(src)
    assert.equal(ok1, ok2)
    -- Both should succeed or both fail — result type should match
    assert.equal(type(r1), type(r2))
  end)

end)

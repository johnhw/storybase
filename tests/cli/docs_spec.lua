-- tests/cli/docs_spec.lua
-- Tests for cli/docs_cmd.lua (auto-docs site generator — §B5).

local compiler = require("compiler.compiler")
local docs_cmd = require("cli.docs_cmd")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function with_tmpfile(src, fn)
  local path = os.tmpname() .. ".sb"
  local f = io.open(path, "w"); f:write(src); f:close()
  local ok, err = pcall(fn, path)
  os.remove(path)
  if not ok then error(err, 2) end
end

local function tmp_dir()
  local path = os.tmpname()
  os.remove(path)  -- delete the placeholder file
  return path
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

local function rmrf(path)
  os.execute("rm -rf " .. string.format("%q", path) .. " >/dev/null 2>&1")
end

-- A small but reasonably comprehensive source covering each declaration kind.
local SAMPLE_SRC = [[
module sample
  version: 1.0

engine-config:
  entry-scene: start

"Three moods for the test type."
type Mood = happy | sad | thoughtful

"A small record."
type Reading:
  value: Int(0, 100) = 0
  noted: Bool        = false

"The player's running score."
state world:
  score: Int(0, 99) = 0

"Per-entity readings."
state readings/{r}: Reading max: 4

"Test relation between moods."
relation mood-edges: Mood -> Set(Mood, 3):
  `happy: {sad, thoughtful}

"Adds one to the score, capped at 99."
fn bump-score:
  pre:  world/score < 99
  post: world/score = (world/score@before + 1)
  inc! world/score 1

"The opening scene."
scene start:
  Welcome.
  * Press on
    bump-score
    -> next-room

scene next-room:
  Now you are here.
  * Loop
    -> start

verify "score is bounded":
  verify-always world/score <= 99
]]

-- ── build_pages: HTML mode ────────────────────────────────────────────────────

describe("docs_cmd.build_pages (html)", function()
  local typed, diags, result

  setup(function()
    typed, diags = compiler.parse_and_check(SAMPLE_SRC, "sample.sb")
    assert.is_not_nil(typed)
    assert.is_false(diags:has_errors())
    result = docs_cmd.build_pages(typed, "sample.sb", "html")
  end)

  it("emits an index page plus one page per kind plus style.css", function()
    assert.is_table(result.pages)
    local expected = {
      "index.html", "types.html", "state.html", "relations.html",
      "fns.html", "scenes.html", "actors.html", "schedules.html",
      "bounded.html", "macros.html", "speakers.html", "grids.html",
      "hooks.html", "verifies.html", "style.css",
    }
    for _, name in ipairs(expected) do
      assert.is_string(result.pages[name],
        "expected page '" .. name .. "' to be emitted")
    end
  end)

  it("index page names the module and shows summary counts", function()
    local idx = result.pages["index.html"]
    assert.matches("sample", idx)              -- module name
    assert.matches("v1.0", idx)                -- module version
    assert.matches("entry%-scene", idx)        -- engine config
    -- Summary card values: 1 enum + 1 record = 2 types; 2 states; etc.
    assert.matches('<div class="value">2</div>', idx)  -- types count
  end)

  it("types page includes enum values and record fields with doc string", function()
    local p = result.pages["types.html"]
    assert.matches("Mood", p)
    assert.matches("happy", p)
    assert.matches("sad", p)
    assert.matches("Reading", p)
    assert.matches("Three moods for the test type.", p)
    -- Record field surfaces type expression
    assert.matches("Int%(0, 100%)", p)
  end)

  it("state page lists scalar and family declarations", function()
    local p = result.pages["state.html"]
    assert.matches("world", p)
    assert.matches("readings/{r}", p)
    assert.matches("Reading", p)        -- family element type
    assert.matches("max: 4", p)
  end)

  it("relations page shows source and target types", function()
    local p = result.pages["relations.html"]
    assert.matches("mood%-edges", p)
    assert.matches("Mood %-&gt; Set%(Mood, 3%)", p)
  end)

  it("functions page lists fn with pre/post conditions and doc", function()
    local p = result.pages["fns.html"]
    assert.matches("bump%-score", p)
    assert.matches("Pre:",  p)
    assert.matches("Post:", p)
    assert.matches("Adds one to the score", p)
  end)

  it("scenes page renders a scene graph with goto targets", function()
    local p = result.pages["scenes.html"]
    assert.matches("Scene graph", p)
    assert.matches("start", p)
    assert.matches("next%-room", p)
    -- start -> next-room goes through the scene graph list
    assert.matches('href="#next%-room"', p)
  end)

  it("verifies page lists clauses", function()
    local p = result.pages["verifies.html"]
    assert.matches("score is bounded", p)
    assert.matches("always", p)
  end)

  it("sidebar marks the current page", function()
    local idx = result.pages["index.html"]
    assert.matches('href="index%.html" class="current"', idx)
    local types_p = result.pages["types.html"]
    assert.matches('href="types%.html" class="current"', types_p)
  end)

  it("escapes HTML special characters in user-supplied strings", function()
    local src = SAMPLE_SRC .. '\n\n"Brackets <like> &this&"\ntype Note = a | b\n'
    local t2, d2 = compiler.parse_and_check(src, "esc.sb")
    assert.is_false(d2:has_errors())
    local r2 = docs_cmd.build_pages(t2, "esc.sb", "html")
    local tp = r2.pages["types.html"]
    assert.matches("&lt;like&gt;", tp)
    assert.matches("&amp;this&amp;", tp)
  end)
end)

-- ── build_pages: Markdown mode ────────────────────────────────────────────────

describe("docs_cmd.build_pages (md)", function()
  local typed, diags, result

  setup(function()
    typed, diags = compiler.parse_and_check(SAMPLE_SRC, "sample.sb")
    assert.is_not_nil(typed)
    assert.is_false(diags:has_errors())
    result = docs_cmd.build_pages(typed, "sample.sb", "md")
  end)

  it("produces a single docs.md file", function()
    assert.is_table(result.pages)
    assert.is_string(result.pages["docs.md"])
    -- No HTML siblings
    assert.is_nil(result.pages["index.html"])
  end)

  it("includes summary, types, state, functions, and scenes sections", function()
    local md = result.pages["docs.md"]
    assert.matches("# sample", md)
    assert.matches("## Summary",   md)
    assert.matches("## Types",     md)
    assert.matches("## State",     md)
    assert.matches("## Functions", md)
    assert.matches("## Scenes",    md)
    assert.matches("`bump%-score`", md)
    assert.matches("`Mood`", md)
  end)
end)

-- ── CLI runner: writes files to disk ─────────────────────────────────────────

describe("docs_cmd.run (CLI)", function()
  -- Silence stderr/stdout for negative-case tests.
  local function with_silent_io(fn)
    local orig_err, orig_out = io.stderr, io.stdout
    local sink = { write = function() end, flush = function() end }
    io.stderr, io.stdout = sink, sink
    local ok, err = pcall(fn)
    io.stderr, io.stdout = orig_err, orig_out
    if not ok then error(err, 2) end
  end

  it("rejects missing file argument", function()
    local rc
    with_silent_io(function() rc = docs_cmd.run({}) end)
    assert.equals(1, rc)
  end)

  it("rejects unknown --format value", function()
    with_tmpfile(SAMPLE_SRC, function(src_path)
      local rc
      with_silent_io(function()
        rc = docs_cmd.run({ src_path, "--format", "pdf" })
      end)
      assert.equals(1, rc)
    end)
  end)

  it("writes a full HTML site to the output directory", function()
    with_tmpfile(SAMPLE_SRC, function(src_path)
      local out = tmp_dir()
      local rc = docs_cmd.run({ src_path, "-o", out })
      assert.equals(0, rc)
      assert.is_string(read_file(out .. "/index.html"))
      assert.is_string(read_file(out .. "/types.html"))
      assert.is_string(read_file(out .. "/style.css"))
      local idx = read_file(out .. "/index.html")
      assert.matches("sample", idx)
      rmrf(out)
    end)
  end)

  it("writes Markdown to the specified file", function()
    with_tmpfile(SAMPLE_SRC, function(src_path)
      local out_md = tmp_dir() .. ".md"
      local rc = docs_cmd.run({ src_path, "--format", "md", "-o", out_md })
      assert.equals(0, rc)
      local md = read_file(out_md)
      assert.is_string(md)
      assert.matches("# sample", md)
      os.remove(out_md)
    end)
  end)
end)

-- ── Demo round-trips: emit docs for several real demos ───────────────────────

describe("docs_cmd: demo round-trips", function()
  local DEMOS = {
    "demos/demo01_wanderer.sb",
    "demos/demo15_spellwright.sb",   -- macros
    "demos/demo20_harrow_house.sb",  -- big game with everything
    "demos/demo22_quest_temporal.sb",
  }
  for _, demo in ipairs(DEMOS) do
    it("emits HTML for " .. demo, function()
      local typed, diags = compiler.parse_and_check_file(demo)
      assert.is_not_nil(typed, "compile failed for " .. demo)
      assert.is_false(diags:has_errors())
      local r = docs_cmd.build_pages(typed, demo, "html")
      assert.is_string(r.pages["index.html"])
      assert.is_string(r.pages["scenes.html"])
      assert.is_string(r.pages["style.css"])
    end)
  end
end)

-- ── Specific feature: macros recovered from raw source ───────────────────────

describe("docs_cmd.run: macro recovery", function()
  it("includes MACRO_DECL nodes (which are stripped by macro expansion)", function()
    local src = [[
module mac
  version: 1.0
engine-config:
  entry-scene: s

"Wrap a body with a marker."
macro with-marker body:
  body

state world:
  flag: Bool = false

scene s:
  * Run
    with-marker:
      set! world/flag true
    -> s
]]
    with_tmpfile(src, function(src_path)
      local out = tmp_dir()
      local rc = docs_cmd.run({ src_path, "-o", out })
      assert.equals(0, rc)
      local mp = read_file(out .. "/macros.html")
      assert.is_string(mp)
      assert.matches("with%-marker", mp)
      rmrf(out)
    end)
  end)
end)

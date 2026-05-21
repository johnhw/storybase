-- tests/runtime/j_bugs_spec.lua
-- End-to-end regression tests for bugs identified in Language Review Pass 3:
--   J-B1: family `max:` capacity not enforced at spawn!
--   J-B2: `find ... limit:` silently falls back to 10 for non-literal exprs
--
-- Run with: busted tests/

local sb = require("lib.storybase")

-- ============================================================
-- J-B1: family `max:` is enforced at spawn!
-- ============================================================

describe("J-B1: family max: enforcement (e2e)", function()
  local SRC = [[
module jb1-test
  version: 1.0
engine-config:
  entry-scene: start

type Item:
  name: Symbol = `nameless

state things/{t}: Item  max: 2

fn add-two:
  spawn! things `a Item(name: `alpha)
  spawn! things `b Item(name: `beta)

fn add-three:
  spawn! things `a Item(name: `alpha)
  spawn! things `b Item(name: `beta)
  spawn! things `c Item(name: `gamma)

fn add-one-c:
  spawn! things `c Item(name: `gamma)

fn drop-a:
  despawn! things `a

scene start:
  Things in the bag.
]]

  it("spawn! errors with FAMILY_FULL when family is at capacity", function()
    local g = sb.from_source(SRC, "jb1"); g:init()
    local ok, err = pcall(function() g:call("add-three") end)
    assert.is_false(ok)
    assert.is_true(tostring(err):find("FAMILY_FULL", 1, true) ~= nil,
      "expected FAMILY_FULL error, got: " .. tostring(err))
  end)

  it("spawning up to max succeeds", function()
    local g = sb.from_source(SRC, "jb1"); g:init()
    g:call("add-two")
    assert.equal(2, #g:find("things"))
  end)

  it("despawn frees a slot at capacity", function()
    local g = sb.from_source(SRC, "jb1"); g:init()
    g:call("add-two")
    g:call("drop-a")
    -- Now there is space for one more
    assert.has_no.errors(function() g:call("add-one-c") end)
    assert.equal(2, #g:find("things"))
  end)
end)

-- ============================================================
-- J-B2: find ... limit: evaluates expressions at runtime
-- ============================================================

describe("J-B2: find limit: dynamic evaluation (e2e)", function()
  local SRC = [[
module jb2-test
  version: 1.0
engine-config:
  entry-scene: start

type Thing:
  rank: Int(0, 100) = 0

state world:
  cap: Int(0, 100) = 0

state things/{t}: Thing

fn populate:
  spawn! things `a Thing(rank: 1)
  spawn! things `b Thing(rank: 2)
  spawn! things `c Thing(rank: 3)
  spawn! things `d Thing(rank: 4)
  spawn! things `e Thing(rank: 5)

fn limited:
  find things order-by: things/{things}/rank asc limit: world/cap

fn limited-arith:
  find things order-by: things/{things}/rank asc limit: (world/cap + 2)

fn limited-literal:
  find things order-by: things/{things}/rank asc limit: 3

scene start:
  Five things ranked.
]]

  it("limit: from a state path returns that many results", function()
    local g = sb.from_source(SRC, "jb2"); g:init()
    g:call("populate")
    g:set("world/cap", 2)
    local result = g:call("limited")
    assert.equal(2, #result)
  end)

  it("limit: 0 returns empty result", function()
    local g = sb.from_source(SRC, "jb2"); g:init()
    g:call("populate")
    g:set("world/cap", 0)
    local result = g:call("limited")
    assert.equal(0, #result)
  end)

  it("limit: literal still works (backward compat)", function()
    local g = sb.from_source(SRC, "jb2"); g:init()
    g:call("populate")
    local result = g:call("limited-literal")
    assert.equal(3, #result)
  end)

  it("limit: from arithmetic expression evaluates", function()
    local g = sb.from_source(SRC, "jb2"); g:init()
    g:call("populate")
    g:set("world/cap", 1)
    -- world/cap + 2 → 3
    local result = g:call("limited-arith")
    assert.equal(3, #result)
  end)
end)

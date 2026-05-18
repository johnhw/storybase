-- tests/stdlib/inventory_spec.lua
-- §E3 stdlib/inventory.sb — `inventory $name $T $max` decl-macro.

local compiler = require("compiler.compiler")
local engine   = require("runtime.engine")
local eval     = require("runtime.eval")
local ast      = require("compiler.ast")

local function compile(src)
  local gt, diags = compiler.compile(src, "test.sb")
  return gt, (diags and diags.errors) or {}
end

local function find_state(gt, path)
  for _, st in ipairs(gt.schema.states or {}) do
    if st.path == path then return st end
  end
  return nil
end

--- Make a runtime context attached to a fresh engine + initial state.
local function fresh(src)
  local gt, errs = compile(src)
  assert(#errs == 0, "compile errors: " .. tostring(errs[1] and errs[1].message))
  local g = engine.new(gt)
  g:init()
  return gt, g
end

local function call_fn(gt, g, name, args)
  local ctx = eval.new_ctx(g._state, gt.fns, "test", gt)
  local arg_nodes = {}
  for _, a in ipairs(args or {}) do
    arg_nodes[#arg_nodes+1] = ast.symbol_lit(a)
  end
  return eval.call_fn(name, arg_nodes, ctx)
end

local SRC = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
type ItemKind = Enum(sword, shield, potion)
import "@stdlib/inventory"
inventory player-bag ItemKind 4
scene main:
  the end
]]

describe("stdlib/inventory — compile", function()
  it("emits a Set state at the supplied $name with the given $T and $max", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    local st = find_state(gt, "player-bag")
    assert.is_not_nil(st)
    assert.equal("set", st.type_desc.tag)
    assert.equal("ItemKind", st.type_desc.inner.name)
    assert.equal(4, st.type_desc.max)
  end)

  it("emits all 7 helper fns with the $name prefix", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    for _, fn in ipairs({
      "player-bag-give", "player-bag-take", "player-bag-has?",
      "player-bag-count", "player-bag-empty?", "player-bag-full?",
      "player-bag-clear!",
    }) do
      assert.is_not_nil(gt.fns[fn], "missing emitted fn: " .. fn)
    end
  end)

  it("two inventories side by side don't collide", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
type ItemKind = Enum(sword, shield)
type SpellKind = Enum(fire, ice)
import "@stdlib/inventory"
inventory player-bag    ItemKind  4
inventory player-spells SpellKind 8
scene main:
  done
]]
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    assert.is_not_nil(find_state(gt, "player-bag"))
    assert.is_not_nil(find_state(gt, "player-spells"))
    assert.equal(4, find_state(gt, "player-bag").type_desc.max)
    assert.equal(8, find_state(gt, "player-spells").type_desc.max)
    assert.is_not_nil(gt.fns["player-bag-give"])
    assert.is_not_nil(gt.fns["player-spells-give"])
  end)
end)

describe("stdlib/inventory — runtime", function()
  it("starts empty", function()
    local gt, g = fresh(SRC)
    assert.equal(0,    call_fn(gt, g, "player-bag-count"))
    assert.equal(true, call_fn(gt, g, "player-bag-empty?"))
    assert.equal(false, call_fn(gt, g, "player-bag-full?"))
  end)

  it("give/take/has? round-trip", function()
    local gt, g = fresh(SRC)
    call_fn(gt, g, "player-bag-give", {"sword"})
    call_fn(gt, g, "player-bag-give", {"shield"})
    assert.equal(2,    call_fn(gt, g, "player-bag-count"))
    assert.equal(true, call_fn(gt, g, "player-bag-has?", {"sword"}))
    assert.equal(true, call_fn(gt, g, "player-bag-has?", {"shield"}))
    assert.equal(false, call_fn(gt, g, "player-bag-has?", {"potion"}))

    call_fn(gt, g, "player-bag-take", {"sword"})
    assert.equal(1,     call_fn(gt, g, "player-bag-count"))
    assert.equal(false, call_fn(gt, g, "player-bag-has?", {"sword"}))
  end)

  it("full? flips true at capacity", function()
    local gt, g = fresh(SRC)
    call_fn(gt, g, "player-bag-give", {"sword"})
    call_fn(gt, g, "player-bag-give", {"shield"})
    call_fn(gt, g, "player-bag-give", {"potion"})
    assert.equal(false, call_fn(gt, g, "player-bag-full?"))
    -- enum has 3 items so we can't actually reach max=4 with distinct values,
    -- but full?'s == 4 comparison is what we're testing — confirm size is 3
    -- and full? is false.
    assert.equal(3, call_fn(gt, g, "player-bag-count"))
  end)

  it("E4-test-1: full? actually flips true when enum cardinality == $max",
     function()
    -- Match the enum cardinality to $max so the bag can actually fill
    -- up and the (size $name) = $max comparison fires.
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
type ItemKind = Enum(sword, shield, potion)
import "@stdlib/inventory"
inventory player-bag ItemKind 3
scene main:
  the end
]]
    local gt, g = fresh(src)
    call_fn(gt, g, "player-bag-give", {"sword"})
    assert.equal(false, call_fn(gt, g, "player-bag-full?"))
    call_fn(gt, g, "player-bag-give", {"shield"})
    assert.equal(false, call_fn(gt, g, "player-bag-full?"))
    call_fn(gt, g, "player-bag-give", {"potion"})
    assert.equal(3,    call_fn(gt, g, "player-bag-count"))
    assert.equal(true, call_fn(gt, g, "player-bag-full?"),
      "full? should flip true when size == max")
    -- Taking an item drops below capacity → full? back to false.
    call_fn(gt, g, "player-bag-take", {"sword"})
    assert.equal(false, call_fn(gt, g, "player-bag-full?"))
  end)

  it("clear! empties the inventory", function()
    local gt, g = fresh(SRC)
    call_fn(gt, g, "player-bag-give", {"sword"})
    call_fn(gt, g, "player-bag-give", {"potion"})
    call_fn(gt, g, "player-bag-clear!")
    assert.equal(0,    call_fn(gt, g, "player-bag-count"))
    assert.equal(true, call_fn(gt, g, "player-bag-empty?"))
  end)
end)

describe("stdlib/inventory — errors", function()
  it("rejects a multi-segment path as the $name slot", function()
    -- $name is used inside `$name-give`, a composite identifier slot, so
    -- multi-segment paths fail with MACRO_DECL_EMIT (same constraint as
    -- the existing `counter` macro).
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
type ItemKind = Enum(sword)
import "@stdlib/inventory"
inventory player/bag ItemKind 4
scene main:
  the end
]]
    local _, errs = compile(src)
    local saw = nil
    for _, e in ipairs(errs) do
      if e.code == "MACRO_DECL_EMIT" then saw = e end
    end
    assert.is_not_nil(saw,
      "expected MACRO_DECL_EMIT for multi-segment $name; got: " ..
      tostring(errs[1] and errs[1].message))
  end)

  it("rejects a non-integer $max", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
type ItemKind = Enum(sword)
import "@stdlib/inventory"
inventory player-bag ItemKind unbounded
scene main:
  the end
]]
    local _, errs = compile(src)
    local saw = nil
    for _, e in ipairs(errs) do
      if e.code == "MACRO_DECL_EMIT" and e.message:find("Set capacity", 1, true) then
        saw = e
      end
    end
    assert.is_not_nil(saw,
      "expected MACRO_DECL_EMIT about Set capacity")
  end)
end)

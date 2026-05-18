-- tests/stdlib/stat_spec.lua
-- §E3 stdlib/stat.sb — `stat $name $min $max` decl-macro.

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

local function fresh(src)
  local gt, errs = compile(src)
  assert(#errs == 0, "compile errors: " .. tostring(errs[1] and errs[1].message))
  local g = engine.new(gt); g:init()
  return gt, g
end

local function call_fn(gt, g, name, args)
  local ctx = eval.new_ctx(g._state, gt.fns, "test", gt)
  local arg_nodes = {}
  for _, a in ipairs(args or {}) do
    arg_nodes[#arg_nodes+1] = ast.int_lit(a)
  end
  return eval.call_fn(name, arg_nodes, ctx)
end

local SRC = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/stat"
stat player-health 0 100
scene main:
  done
]]

describe("stdlib/stat — compile", function()
  it("emits an Int state with the given min/max and a default of $max", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    local st = find_state(gt, "player-health")
    assert.is_not_nil(st)
    assert.equal("int", st.type_desc.tag)
    assert.equal(0,   st.type_desc.min)
    assert.equal(100, st.type_desc.max)
    -- Default = 100 so the stat starts "full".
    local def = st.default
    assert.equal(100, def and (def.value or def))
  end)

  it("emits all expected helper fns", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    for _, fn in ipairs({
      "player-health-heal", "player-health-hurt", "player-health-set",
      "player-health-restore", "player-health-deplete",
      "player-health-full?", "player-health-empty?",
      "player-health-current",
    }) do
      assert.is_not_nil(gt.fns[fn], "missing emitted fn: " .. fn)
    end
  end)

  it("two stats side by side don't collide", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/stat"
stat player-health 0 100
stat player-mana   0 50
scene main:
  done
]]
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    assert.equal(100, find_state(gt, "player-health").type_desc.max)
    assert.equal(50,  find_state(gt, "player-mana").type_desc.max)
  end)
end)

describe("stdlib/stat — runtime", function()
  it("starts at $max (= 'full')", function()
    local gt, g = fresh(SRC)
    assert.equal(100,   call_fn(gt, g, "player-health-current"))
    assert.equal(true,  call_fn(gt, g, "player-health-full?"))
    assert.equal(false, call_fn(gt, g, "player-health-empty?"))
  end)

  it("heal/hurt clamp via Int(0,100) and update current", function()
    local gt, g = fresh(SRC)
    call_fn(gt, g, "player-health-hurt", {30})
    assert.equal(70, call_fn(gt, g, "player-health-current"))
    call_fn(gt, g, "player-health-heal", {5})
    assert.equal(75, call_fn(gt, g, "player-health-current"))
    -- Clamp at min: hurt past 0
    call_fn(gt, g, "player-health-hurt", {500})
    assert.equal(0,    call_fn(gt, g, "player-health-current"))
    assert.equal(true, call_fn(gt, g, "player-health-empty?"))
  end)

  it("restore/deplete jump to bounds; set arbitrary value", function()
    local gt, g = fresh(SRC)
    call_fn(gt, g, "player-health-deplete")
    assert.equal(0, call_fn(gt, g, "player-health-current"))
    call_fn(gt, g, "player-health-restore")
    assert.equal(100, call_fn(gt, g, "player-health-current"))
    call_fn(gt, g, "player-health-set", {42})
    assert.equal(42, call_fn(gt, g, "player-health-current"))
  end)
end)

describe("stdlib/stat — errors", function()
  it("rejects a multi-segment $name (composite-name constraint)", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/stat"
stat player/health 0 100
scene main:
  done
]]
    local _, errs = compile(src)
    local saw = nil
    for _, e in ipairs(errs) do
      if e.code == "MACRO_DECL_EMIT" then saw = e end
    end
    assert.is_not_nil(saw,
      "expected MACRO_DECL_EMIT for multi-segment $name")
  end)

  it("rejects a non-integer $min", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/stat"
stat player-health foo 100
scene main:
  done
]]
    local _, errs = compile(src)
    local saw = nil
    for _, e in ipairs(errs) do
      if e.code == "MACRO_DECL_EMIT" and e.message:find("Int min bound", 1, true) then
        saw = e
      end
    end
    assert.is_not_nil(saw,
      "expected MACRO_DECL_EMIT about Int min bound")
  end)
end)

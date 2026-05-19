-- tests/stdlib/dialog_spec.lua
-- §E2 stdlib/dialog.sb — `dialog-topic $owner $topic` decl-macro.

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
    arg_nodes[#arg_nodes+1] = ast.symbol_lit(a)
  end
  return eval.call_fn(name, arg_nodes, ctx)
end

local SRC = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/dialog"
dialog-topic meredith family-history
scene main:
  done
]]

describe("stdlib/dialog — compile", function()
  it("emits a Bool state at $owner-asked-$topic defaulting to false", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    local st = find_state(gt, "meredith-asked-family-history")
    assert.is_not_nil(st)
    assert.equal("bool", st.type_desc.tag)
    -- default is false
    local def = st.default
    assert.equal(false, def and (def.value == nil and def or def.value))
  end)

  it("emits four helper fns with the conventional names", function()
    local gt, errs = compile(SRC)
    assert.equal(0, #errs)
    for _, fn in ipairs({
      "meredith-asked-family-history?",
      "meredith-not-asked-family-history?",
      "mark-meredith-family-history-asked!",
      "meredith-reset-family-history!",
    }) do
      assert.is_not_nil(gt.fns[fn], "missing emitted fn: " .. fn)
    end
  end)

  it("two topics for the same owner don't collide", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/dialog"
dialog-topic meredith family-history
dialog-topic meredith locked-study
scene main:
  done
]]
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    assert.is_not_nil(find_state(gt, "meredith-asked-family-history"))
    assert.is_not_nil(find_state(gt, "meredith-asked-locked-study"))
    assert.is_not_nil(gt.fns["meredith-asked-family-history?"])
    assert.is_not_nil(gt.fns["meredith-asked-locked-study?"])
    assert.is_not_nil(gt.fns["mark-meredith-family-history-asked!"])
    assert.is_not_nil(gt.fns["mark-meredith-locked-study-asked!"])
  end)

  it("two owners and the same topic name don't collide", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/dialog"
dialog-topic meredith family-history
dialog-topic landlord family-history
scene main:
  done
]]
    local gt, errs = compile(src)
    assert.equal(0, #errs)
    assert.is_not_nil(find_state(gt, "meredith-asked-family-history"))
    assert.is_not_nil(find_state(gt, "landlord-asked-family-history"))
    assert.is_not_nil(gt.fns["meredith-asked-family-history?"])
    assert.is_not_nil(gt.fns["landlord-asked-family-history?"])
  end)
end)

describe("stdlib/dialog — runtime", function()
  it("starts in the not-asked state", function()
    local gt, g = fresh(SRC)
    assert.equal(false, call_fn(gt, g, "meredith-asked-family-history?"))
    assert.equal(true,  call_fn(gt, g, "meredith-not-asked-family-history?"))
  end)

  it("mark!/reset! round-trip flips the flag and the helpers track it", function()
    local gt, g = fresh(SRC)
    call_fn(gt, g, "mark-meredith-family-history-asked!")
    assert.equal(true,  call_fn(gt, g, "meredith-asked-family-history?"))
    assert.equal(false, call_fn(gt, g, "meredith-not-asked-family-history?"))
    call_fn(gt, g, "meredith-reset-family-history!")
    assert.equal(false, call_fn(gt, g, "meredith-asked-family-history?"))
    assert.equal(true,  call_fn(gt, g, "meredith-not-asked-family-history?"))
  end)

  it("two topics for one owner are independently tracked", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/dialog"
dialog-topic meredith family-history
dialog-topic meredith locked-study
scene main:
  done
]]
    local gt, g = fresh(src)
    call_fn(gt, g, "mark-meredith-family-history-asked!")
    assert.equal(true,  call_fn(gt, g, "meredith-asked-family-history?"))
    assert.equal(false, call_fn(gt, g, "meredith-asked-locked-study?"))
    call_fn(gt, g, "mark-meredith-locked-study-asked!")
    assert.equal(true,  call_fn(gt, g, "meredith-asked-family-history?"))
    assert.equal(true,  call_fn(gt, g, "meredith-asked-locked-study?"))
    call_fn(gt, g, "meredith-reset-family-history!")
    assert.equal(false, call_fn(gt, g, "meredith-asked-family-history?"))
    assert.equal(true,  call_fn(gt, g, "meredith-asked-locked-study?"))
  end)
end)

describe("stdlib/dialog — guards in scenes", function()
  it("compiles a scene that gates choices on the emitted helper fns", function()
    -- The whole point of the macro: it has to be ergonomic to write a
    -- talk-NPC scene that reads `not-asked?` in a choice guard and calls
    -- `mark-asked!` inside the choice body. Compile-only check; the
    -- runtime behaviour around choice guards is covered elsewhere.
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/dialog"
dialog-topic meredith family-history
scene main:
  Talk to Meredith.

  * [meredith-not-asked-family-history?] Ask about her family.
    mark-meredith-family-history-asked!
    say Meredith: I came here as a boy.
    -> main

  * [meredith-asked-family-history?] You have already asked about that.
    -> main

  * Stop talking.
    pass
]]
    local _, errs = compile(src)
    assert.equal(0, #errs,
      "scene with dialog guards must compile cleanly; got: " ..
      tostring(errs[1] and errs[1].message))
  end)
end)

describe("stdlib/dialog — errors", function()
  it("rejects a multi-segment $owner (composite-name constraint)", function()
    -- $owner is used inside `$owner-asked-$topic`, a COMPOSITE_IDENT slot,
    -- so a multi-segment path fails with MACRO_DECL_EMIT (same constraint
    -- as `counter`, `stat`, and `inventory`).
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/dialog"
dialog-topic npcs/meredith family-history
scene main:
  done
]]
    local _, errs = compile(src)
    local saw = nil
    for _, e in ipairs(errs) do
      if e.code == "MACRO_DECL_EMIT" then saw = e end
    end
    assert.is_not_nil(saw,
      "expected MACRO_DECL_EMIT for multi-segment $owner; got: " ..
      tostring(errs[1] and errs[1].message))
  end)

  it("rejects a multi-segment $topic", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/dialog"
dialog-topic meredith locked/study
scene main:
  done
]]
    local _, errs = compile(src)
    local saw = nil
    for _, e in ipairs(errs) do
      if e.code == "MACRO_DECL_EMIT" then saw = e end
    end
    assert.is_not_nil(saw,
      "expected MACRO_DECL_EMIT for multi-segment $topic")
  end)

  it("rejects calling dialog-topic with the wrong arity", function()
    local src = [[
module test
  version: 1.0
engine-config:
  entry-scene: main
import "@stdlib/dialog"
dialog-topic meredith
scene main:
  done
]]
    local _, errs = compile(src)
    local saw = nil
    for _, e in ipairs(errs) do
      if e.code == "MACRO_DECL_EMIT" and e.message:find("expects 2", 1, true) then
        saw = e
      end
    end
    assert.is_not_nil(saw,
      "expected MACRO_DECL_EMIT about arity; got: " ..
      tostring(errs[1] and errs[1].message))
  end)
end)

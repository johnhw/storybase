-- tests/runtime/j_i2_spec.lua
-- J-I2 — scene-body choice descent into for / when / if blocks, and
-- enum-case iteration (Shape C).  See todo.md §J-I2.

local engine_mod   = require("runtime.engine")
local compiler_mod = require("compiler.compiler")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function compile(src)
  local gt, diags = compiler_mod.compile(src, "test.sb")
  local errors = {}
  for _, d in ipairs(diags or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return gt, errors
end

local function make_engine(src)
  local gt, errs = compile(src)
  assert.equal(0, #errs, "compile errors: " ..
    (errs[1] and (errs[1].msg or "?") or ""))
  local eng = engine_mod.new(gt, {
    io_out = { write = function() end },
    io_in  = { read  = function() return "" end },
  })
  eng:init()
  return eng, gt
end

local function labels(choices)
  local out = {}
  for _, c in ipairs(choices) do out[#out + 1] = c.label end
  return out
end

-- ── Shape A: for-loop choice emission ────────────────────────────────────────

describe("J-I2: choices inside for-loops", function()

  it("emits one choice per iteration with {var} interpolation", function()
    local eng = make_engine([[
module ji2-for
  version: 1.0
engine-config:
  entry-scene: hall
scene hall:
  for s in [`stone, `lake, `tower]:
    * Visit {s}
      -> hall
]])
    local _, ch = eng:render_scene("hall")
    assert.same({ "Visit stone", "Visit lake", "Visit tower" }, labels(ch))
    assert.equal(1, ch[1].index)
    assert.equal(3, ch[3].index)
  end)

  it("per-iteration guard filters individual choices", function()
    local eng = make_engine([[
module ji2-guard
  version: 1.0
engine-config:
  entry-scene: hall
state world/available: Set(Symbol, 8) = {`a, `c}
scene hall:
  for s in [`a, `b, `c]:
    * [contains? world/available s] Pick {s}
      -> hall
]])
    local _, ch = eng:render_scene("hall")
    assert.same({ "Pick a", "Pick c" }, labels(ch))
    assert.equal(1, ch[1].index)
    assert.equal(2, ch[2].index)
  end)

  it("iterates (path-list family) emitting one choice per member", function()
    -- `generate` runs at engine:init() so the family is populated before
    -- render_scene is called.  This avoids needing to step a setup scene.
    local eng = make_engine([[
module ji2-family
  version: 1.0
engine-config:
  entry-scene: hall
type RoomRec:
  door-open: Bool = true
state rooms/{r}: RoomRec  max: 8
generate init-rooms:
  spawn! rooms `parlour RoomRec(door-open: true)
  spawn! rooms `kitchen RoomRec(door-open: true)
  spawn! rooms `cellar  RoomRec(door-open: true)
scene hall:
  for r in (path-list rooms):
    * Go to {r}
      -> hall
]])
    local _, ch = eng:render_scene("hall")
    -- path_list returns keys in lexicographic order, so choices appear in
    -- that order regardless of spawn order.
    assert.same({ "Go to cellar", "Go to kitchen", "Go to parlour" }, labels(ch))
  end)

  it("empty iteration falls through to else-body choices", function()
    local eng = make_engine([[
module ji2-empty
  version: 1.0
engine-config:
  entry-scene: hall
scene hall:
  for x in []:
    * Visit {x}
      -> hall
  else:
    * Nothing to visit
      -> hall
]])
    local _, ch = eng:render_scene("hall")
    assert.same({ "Nothing to visit" }, labels(ch))
  end)

end)

-- ── Shape A: choice descent into when / if ───────────────────────────────────

describe("J-I2: choices inside when / if blocks", function()

  it("when-cond gates a group of choices", function()
    local src = [[
module ji2-when
  version: 1.0
engine-config:
  entry-scene: room
state world/key: Bool = false
fn take-key:
  set! world/key true
scene room:
  * Pick up the key
    take-key
    -> room
  when world/key:
    * Unlock the door
      -> exit-scene
    * Lock the door
      -> room
scene exit-scene:
  You leave.
]]
    local eng = make_engine(src)
    local _, ch = eng:render_scene("room")
    assert.same({ "Pick up the key" }, labels(ch))
    -- Execute choice 1 directly so we can drive state without needing stdin.
    eng:do_choice("room", 1)
    local _, ch2 = eng:render_scene("room")
    assert.same({ "Pick up the key", "Unlock the door", "Lock the door" }, labels(ch2))
    assert.equal(2, ch2[2].index)
    assert.equal(3, ch2[3].index)
  end)

  it("if/else emits choices from the matching branch only", function()
    local eng = make_engine([[
module ji2-ifelse
  version: 1.0
engine-config:
  entry-scene: room
state world/mode: Bool = false
scene room:
  if world/mode:
    * In-mode choice
      -> room
  else:
    * Off-mode A
      -> room
    * Off-mode B
      -> room
]])
    local _, ch = eng:render_scene("room")
    assert.same({ "Off-mode A", "Off-mode B" }, labels(ch))
  end)

end)

-- ── Shape A: nesting & ordering ──────────────────────────────────────────────

describe("J-I2: nested blocks and visible-index ordering", function()

  it("for inside when both descend; visible indices are contiguous", function()
    local eng = make_engine([[
module ji2-nest
  version: 1.0
engine-config:
  entry-scene: hall
state world/ready: Bool = true
scene hall:
  * Always-first
    -> hall
  when world/ready:
    for s in [`a, `b]:
      * Take {s}
        -> hall
  * Always-last
    -> hall
]])
    local _, ch = eng:render_scene("hall")
    assert.same(
      { "Always-first", "Take a", "Take b", "Always-last" },
      labels(ch)
    )
    for i, c in ipairs(ch) do assert.equal(i, c.index) end
  end)

  it("nested-block visible count contributes to following choice indices", function()
    local eng = make_engine([[
module ji2-count
  version: 1.0
engine-config:
  entry-scene: hall
state world/seen: Bool = true
scene hall:
  for s in [`a, `b, `c, `d]:
    * [world/seen] Pick {s}
      -> hall
  * Done
    -> hall
]])
    local _, ch = eng:render_scene("hall")
    assert.same({ "Pick a", "Pick b", "Pick c", "Pick d", "Done" }, labels(ch))
    assert.equal(5, ch[5].index)
  end)

end)

-- ── do_choice execution carries iter bindings ───────────────────────────────

describe("J-I2: do_choice with iteration variables", function()

  it("selecting a looped choice executes body with the correct iter binding", function()
    -- The choice body interpolates {i} into a state path; do_choice must
    -- propagate the for-loop binding into the executing context so the
    -- correct family member is mutated.
    local eng = make_engine([[
module ji2-exec
  version: 1.0
engine-config:
  entry-scene: hall
type ItemRec:
  taken: Bool = false
state items/{i}: ItemRec  max: 8
generate init-items:
  spawn! items `apple ItemRec(taken: false)
  spawn! items `bread ItemRec(taken: false)
  spawn! items `coin  ItemRec(taken: false)
scene hall:
  for i in (path-list items):
    * Take {i}
      set! items/{i}/taken true
      -> hall
]])
    local _, ch = eng:render_scene("hall")
    assert.equal(3, #ch)
    -- Pick the second choice (bread) — body should set items/bread/taken,
    -- leaving apple and coin untouched.
    eng:do_choice("hall", 2)
    assert.equal(false, eng._state:get("items/apple/taken"))
    assert.equal(true,  eng._state:get("items/bread/taken"))
    assert.equal(false, eng._state:get("items/coin/taken"))
  end)

  it("guarded looped choice: visible index maps past hidden iterations", function()
    -- world/available = {a, c} → visible choices are "Pick a" (idx 1) and
    -- "Pick c" (idx 2).  Selecting idx 2 must execute with s=c, not s=b.
    local eng = make_engine([[
module ji2-exec-guard
  version: 1.0
engine-config:
  entry-scene: hall
state world/available: Set(Symbol, 8) = {`a, `c}
state world/picked: Symbol = `none
scene hall:
  for s in [`a, `b, `c]:
    * [contains? world/available s] Pick {s}
      set! world/picked s
      -> done
scene done:
  Done.
]])
    eng:do_choice("hall", 2)
    assert.equal("c", eng._state:get("world/picked"))
  end)

end)

-- ── Shape C: enum-case iteration ────────────────────────────────────────────

describe("J-I2 (Shape C): enum-case iteration", function()

  it("for s in EnumKind: iterates the variant symbols", function()
    local eng = make_engine([[
module ji2-enum
  version: 1.0
engine-config:
  entry-scene: hall
type Direction = north | south | east | west
scene hall:
  for d in Direction:
    * Go {d}
      -> hall
]])
    local _, ch = eng:render_scene("hall")
    assert.same(
      { "Go north", "Go south", "Go east", "Go west" },
      labels(ch)
    )
  end)

  it("enum iteration also works in fn bodies", function()
    -- Shape C is implemented in eval.eval_for_iter so it applies to every
    -- for-loop, not just scene-body ones.  Verify it: a generate block
    -- (which is a fn-body-shaped block run at init) loops over the enum
    -- and increments a counter once per variant.
    local eng = make_engine([[
module ji2-enum-fn
  version: 1.0
engine-config:
  entry-scene: hall
type Coin = copper | silver | gold
state world/count: Int(0, 99) = 0
generate enumerate-coins:
  for c in Coin:
    inc! world/count 1
scene hall:
  Done.
]])
    assert.equal(3, eng._state:get("world/count"))
  end)

  it("non-enum iter falls through to eval_expr (list-literal still works)", function()
    -- Sanity check that the enum-resolution shortcut does not interfere
    -- with the original behaviour: a list-literal iter still evaluates
    -- as a plain list expression.
    local eng = make_engine([[
module ji2-noshadow
  version: 1.0
engine-config:
  entry-scene: hall
state world/count: Int(0, 99) = 0
generate count-list:
  for x in [10, 20, 30]:
    inc! world/count x
scene hall:
  Done.
]])
    assert.equal(60, eng._state:get("world/count"))
  end)

end)

-- ── Replay & log integration ────────────────────────────────────────────────

describe("J-I2: log records visible index for replay", function()

  it("do_choice on a looped choice logs the visible index, replayable", function()
    local src = [[
module ji2-log
  version: 1.0
engine-config:
  entry-scene: hall
type ItemRec:
  taken: Bool = false
state items/{i}: ItemRec  max: 8
generate init-items:
  spawn! items `red   ItemRec(taken: false)
  spawn! items `green ItemRec(taken: false)
  spawn! items `blue  ItemRec(taken: false)
scene hall:
  for i in (path-list items):
    * Take {i}
      set! items/{i}/taken true
      -> hall
]]
    local eng = make_engine(src)
    -- path_list is lexicographic, so choices render as Take blue (1),
    -- Take green (2), Take red (3).
    eng:do_choice("hall", 3)  -- Take red
    -- Find the choice log entry.
    local found = nil
    for _, entry in ipairs(eng._log:entries()) do
      if entry.kind == "choice" then found = entry end
    end
    assert.is_not_nil(found)
    assert.equal("hall", found.scene)
    assert.equal(3, found.idx)
    -- Replay a fresh engine: apply the same choice index and confirm the
    -- same item was taken — proves iteration order is deterministic.
    local eng2 = make_engine(src)
    eng2:do_choice("hall", 3)
    assert.equal(true,  eng2._state:get("items/red/taken"))
    assert.equal(false, eng2._state:get("items/blue/taken"))
  end)

end)

-- ── BFS / counterfactual integration ────────────────────────────────────────

describe("J-I2: BFS reaches looped choices", function()

  it("can_reach finds a state behind a for-loop choice", function()
    -- BFS exploration of all visible choices.  If the choice enumerator
    -- couldn't see for-loop choices, can_reach would never find goal=true.
    local src = [[
module ji2-bfs
  version: 1.0
engine-config:
  entry-scene: hall
state world/goal: Bool = false
scene hall:
  for s in [`a, `b, `c]:
    * Pick {s}
      when s = `c:
        set! world/goal true
      -> done-scene
scene done-scene:
  Done.
]]
    local eng = make_engine(src)
    local search = require("runtime.search")
    -- Build initial (cache, stack) the way search expects.
    local cache = {}
    for k, v in pairs(eng._state._cache or {}) do cache[k] = v end
    local stack = {}
    for _, s in ipairs(eng._scene_stack or {}) do stack[#stack + 1] = s end
    local reached = search.can_reach(eng._game, cache, stack,
      function(c) return c["world/goal"] == true end,
      3)
    assert.is_true(reached)
  end)

end)

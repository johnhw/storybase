-- tests/runtime/ending_spec.lua
-- Runtime tests for §F2: ending detection during eng:step(), narration
-- rendering of the ending body, and verify-block round-trip via search.lua.

local compiler  = require("compiler.compiler")
local engine    = require("runtime.engine")
local verify    = require("runtime.verify")

local function compile(src)
  local game, diags = compiler.compile(src, "e.sb")
  assert.is_false(diags:has_errors(),
    "compile failed: " .. ((diags.errors[1] or {}).message or "?"))
  return game
end

-- A minimal sink for engine output so unit tests don't spam stdout.
local function silent_io()
  local out = setmetatable({ _buf = {} }, {})
  out.write = function(self, s) self._buf[#self._buf+1] = s end
  out.read  = function() return "" end
  return out
end

-- ── eng:check_ending and eng:_render_ending ────────────────────────────────

describe("ending — eng:check_ending", function()

  it("returns nil when no ending condition is true", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  done: Bool = false
scene main:
  * Done
    -> main
ending good when: world/done:
  "Won."
]])
    local eng = engine.new(game, { seed = 1 }); eng:init()
    assert.is_nil(eng:check_ending())
  end)

  it("returns the matching ending descriptor when its condition fires", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  done: Bool = false
scene main:
  * Done
    -> main
ending good when: world/done:
  "Won."
]])
    local eng = engine.new(game, { seed = 1 }); eng:init()
    eng._state:set("world/done", true, "test")
    local hit = eng:check_ending()
    assert.is_not_nil(hit)
    assert.equal("good", hit.name)
  end)

  it("returns the first ending in declaration order on overlap", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  a: Bool = false
  b: Bool = false
scene main:
  * Done
    -> main
ending first when: world/a:
  "First."
ending second when: world/b:
  "Second."
]])
    local eng = engine.new(game, { seed = 1 }); eng:init()
    eng._state:set("world/a", true, "t")
    eng._state:set("world/b", true, "t")
    assert.equal("first", eng:check_ending().name)
  end)

  it("renders narration body via _render_ending", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  done: Bool = false
scene main:
  * Done
    -> main
ending good when: world/done:
  "A hero returns."
  "The bell rings."
]])
    local eng = engine.new(game, { seed = 1 }); eng:init()
    eng._state:set("world/done", true, "t")
    local hit = eng:check_ending()
    local narr = eng:_render_ending(hit)
    -- Collect narration text segments
    local texts = {}
    for _, item in ipairs(narr) do
      if item.text then texts[#texts+1] = item.text end
    end
    assert.equal("A hero returns.", texts[1])
    assert.equal("The bell rings.", texts[2])
  end)
end)

-- ── eng:step terminates when ending fires ──────────────────────────────────

describe("ending — eng:step termination", function()

  it("step() returns false after a choice triggers an ending", function()
    -- Driver auto-picks the first visible choice.
    local choices_picked = {}
    local driver = {}
    driver.render = function(_, _) end
    driver.prompt = function(_, choices)
      choices_picked[#choices_picked+1] = #choices
      return 1
    end
    driver.notify = function() end

    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  done: Bool = false
scene main:
  * Win
    set! world/done true
    -> main
ending good when: world/done:
  "End."
]])
    local eng = engine.new(game, { seed = 1, driver = driver }); eng:init()
    -- One step suffices: the driver picks "Win", the choice body sets
    -- world/done, post_action runs, the post-action ending check fires
    -- and step() returns false.
    local cont = eng:step()
    assert.is_false(cont, "engine terminated via ending")
    assert.equal("good", eng._ended_at)
  end)

  it("fires before prompt when init or generate already meets the condition", function()
    local prompted = false
    local driver = {
      render = function(_, _) end,
      prompt = function(_, _) prompted = true; return 1 end,
      notify = function() end,
    }
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  done: Bool = true
scene main:
  * Done
    -> main
ending good when: world/done:
  "Pre-empted."
]])
    local eng = engine.new(game, { seed = 1, driver = driver }); eng:init()
    local cont = eng:step()
    assert.is_false(cont)
    assert.is_false(prompted)
    assert.equal("good", eng._ended_at)
  end)
end)

-- ── verify round-trip via the auto-emitted clauses ─────────────────────────

describe("ending — auto-verify integration", function()

  it("auto-reachability verify passes for a clearly-reachable ending", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  done: Bool = false
scene main:
  * Win
    set! world/done true
    -> main
ending good when: world/done:
  "End."
]])
    local results = verify.run_all(game)
    -- One reachability clause (no exclusivity since only one ending).
    assert.equal(1, #results)
    assert.is_true(results[1].pass, "ending 'good' is reachable")
  end)

  it("auto-exclusivity verify catches simultaneously-true endings", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state world:
  a: Bool = false
  b: Bool = false
scene main:
  * Both
    set! world/a true
    set! world/b true
    -> main
ending first when: world/a:
  "A."
ending second when: world/b:
  "B."
]])
    local results = verify.run_all(game)
    local excl
    for _, r in ipairs(results) do
      if r.label and r.label:match("mutually exclusive") then excl = r end
    end
    assert.is_not_nil(excl, "exclusivity verify ran")
    assert.is_false(excl.pass, "violation flagged when both fire simultaneously")
  end)

  it("auto-exclusivity verify passes when conditions stay disjoint", function()
    local game = compile([[
module t
  version: 1.0
engine-config:
  entry-scene: main
state player:
  status: Status = `alive
type Status = alive | dead | escaped
scene main:
  * Die
    set! player/status `dead
    -> main
  * Escape
    set! player/status `escaped
    -> main
ending death when: player/status = `dead:
  "Dead."
ending escape when: player/status = `escaped:
  "Escaped."
]])
    local results = verify.run_all(game)
    for _, r in ipairs(results) do
      assert.is_true(r.pass, "all auto-verifies pass: " .. tostring(r.label))
    end
  end)
end)

-- tests/ui/kernel_spec.lua
-- Unit + integration tests for the presentation kernel (ui/kernel.lua).
-- Covers the M1 acceptance bullets from ui_idea.md §M1:
--   * Subscription registry + dispatcher.
--   * State cache, synced via `mutation`.
--   * Adapter shims so `lib/storybase.lua:on()` go through the kernel.
--   * Tests: subscribe / unsubscribe / coalesced event bursts /
--     state-cache invariants.

local kernel_mod = require("ui.kernel")
local sb         = require("lib.storybase")

-- ── 1. Subscription registry (standalone, no engine) ─────────────────────────

describe("ui.kernel — subscription registry", function()
  it("delivers an emitted event to a single subscriber", function()
    local k = kernel_mod.new()
    local seen
    k:on("hello", function(p) seen = p end)
    k:emit("hello", { msg = "hi" })
    assert.equals("hi", seen.msg)
  end)

  it("delivers to multiple subscribers in registration order", function()
    local k = kernel_mod.new()
    local order = {}
    k:on("e", function() order[#order+1] = "a" end)
    k:on("e", function() order[#order+1] = "b" end)
    k:on("e", function() order[#order+1] = "c" end)
    k:emit("e", {})
    assert.same({ "a", "b", "c" }, order)
  end)

  it("isolates listener errors via pcall (others still fire)", function()
    local k = kernel_mod.new()
    local survived = 0
    k:on("e", function() error("boom") end)
    k:on("e", function() survived = survived + 1 end)
    assert.has_no_error(function() k:emit("e", {}) end)
    assert.equals(1, survived)
  end)

  it("returns an unsubscribe handle from on()", function()
    local k = kernel_mod.new()
    local fired = 0
    local off = k:on("e", function() fired = fired + 1 end)
    k:emit("e", {})
    off()
    k:emit("e", {})
    assert.equals(1, fired)
  end)

  it("off() with the original fn removes that subscription only", function()
    local k = kernel_mod.new()
    local a, b = 0, 0
    local fn_a = function() a = a + 1 end
    local fn_b = function() b = b + 1 end
    k:on("e", fn_a); k:on("e", fn_b)
    k:off("e", fn_a)
    k:emit("e", {})
    assert.equals(0, a)
    assert.equals(1, b)
  end)

  it("a listener that unsubscribes itself during dispatch is safe", function()
    local k = kernel_mod.new()
    local fired = 0
    local off
    local fn = function()
      fired = fired + 1
      if off then off() end
    end
    off = k:on("e", fn)
    k:emit("e", {})
    k:emit("e", {})
    assert.equals(1, fired)
  end)

  it("wildcard listener receives every event with its name", function()
    local k = kernel_mod.new()
    local seen = {}
    k:on("*", function(name, p) seen[#seen+1] = { name, p } end)
    k:emit("a", { v = 1 })
    k:emit("b", { v = 2 })
    assert.equals("a", seen[1][1]); assert.equals(1, seen[1][2].v)
    assert.equals("b", seen[2][1]); assert.equals(2, seen[2][2].v)
  end)

  it("rejects non-string event names", function()
    local k = kernel_mod.new()
    assert.has_error(function() k:on(42, function() end) end)
  end)

  it("rejects non-function handlers", function()
    local k = kernel_mod.new()
    assert.has_error(function() k:on("e", "not a fn") end)
  end)
end)

-- ── 2. State cache invariants (standalone) ───────────────────────────────────

describe("ui.kernel — state cache", function()
  it("mirrors mutation.new into the cache before listeners fire", function()
    local k = kernel_mod.new()
    local seen_during_handler
    k:on("mutation", function(_)
      -- Inside the mutation handler, get_state should already see the new value.
      seen_during_handler = k:get_state("player/hp")
    end)
    k:emit("mutation", { path = "player/hp", old = 10, new = 7, fn = "hurt!" })
    assert.equals(7, seen_during_handler)
    assert.equals(7, k:get_state("player/hp"))
  end)

  it("accumulates cache entries across multiple mutations", function()
    local k = kernel_mod.new()
    k:emit("mutation", { path = "player/hp",   old = 10, new = 7,  fn = "f" })
    k:emit("mutation", { path = "player/gold", old = 0,  new = 50, fn = "f" })
    assert.equals(7,  k:get_state("player/hp"))
    assert.equals(50, k:get_state("player/gold"))
  end)

  it("get_state_all returns the merged cache", function()
    local k = kernel_mod.new()
    k:emit("mutation", { path = "a", old = nil, new = 1 })
    k:emit("mutation", { path = "b", old = nil, new = 2 })
    local all = k:get_state_all()
    assert.equals(1, all.a)
    assert.equals(2, all.b)
  end)
end)

-- ── 3. Integration with the engine (via lib/storybase) ───────────────────────

local KERNEL_SRC = [[
module kernel-test
  version: 1.0
engine-config:
  entry-scene: start
schema-version: 1
state player:
  hp:    Int(0, 100) = 100
  gold:  Int(0, 9999) = 0
state world:
  flag: Bool = false

scene start:
  * Hurt
    dec! player/hp 3
    -> start
  * Earn
    inc! player/gold 5
    -> start
  * Push room
    => room
  * Flip
    set! world/flag true
    -> start
  * End -> end-scene
scene room:
  In the room.
  * Back
    <-
scene end-scene:
  Goodbye.
]]

describe("ui.kernel — wired through lib/storybase", function()
  it("library game:on('mutation') reaches the kernel and includes tick/seq", function()
    local g = sb.from_source(KERNEL_SRC, "kernel-test"); assert.is_not_nil(g)
    g:init()
    local events = {}
    g:on("mutation", function(p) events[#events+1] = p end)
    g:choose(1)  -- Hurt: -3 → hp=97
    local hp_evt
    for _, e in ipairs(events) do
      if e.path == "player/hp" then hp_evt = e; break end
    end
    assert.is_not_nil(hp_evt)
    assert.equals(100, hp_evt.old)
    assert.equals(97,  hp_evt.new)
    assert.is_number(hp_evt.tick)
    assert.is_number(hp_evt.seq)
  end)

  it("library game:on('choice-made') fires with {scene, index, label}", function()
    local g = sb.from_source(KERNEL_SRC, "kernel-test"); assert.is_not_nil(g)
    g:init()
    local seen
    g:on("choice-made", function(p) seen = p end)
    g:choose(2)  -- Earn
    assert.is_not_nil(seen)
    assert.equals("start", seen.scene)
    assert.equals(2,        seen.index)
    assert.equals("Earn",   seen.label)
  end)

  it("library game:on('choice') still fires for backward compatibility", function()
    local g = sb.from_source(KERNEL_SRC, "kernel-test"); assert.is_not_nil(g)
    g:init()
    local fired = 0
    g:on("choice", function() fired = fired + 1 end)
    g:choose(1); g:choose(1)
    assert.equals(2, fired)
  end)

  it("library game:on('scene-change') now fires (audit dead-letter is fixed)", function()
    local g = sb.from_source(KERNEL_SRC, "kernel-test"); assert.is_not_nil(g)
    g:init()
    local changes = {}
    g:on("scene-change", function(p) changes[#changes+1] = p end)
    g:choose(3)  -- "Push room" → enter "room"
    -- At least one scene-change should have fired (start → room).
    assert.is_true(#changes >= 1,
      "expected at least one scene-change after push! room")
    local saw_room = false
    for _, c in ipairs(changes) do
      if c.to == "room" then saw_room = true; break end
    end
    assert.is_true(saw_room, "expected scene-change to room in payload")
  end)

  it("kernel state cache reflects mutations made by player choices", function()
    local g = sb.from_source(KERNEL_SRC, "kernel-test"); assert.is_not_nil(g)
    g:init()
    -- HP starts at 100. After three "Hurt" choices: 100 → 97 → 94 → 91.
    g:choose(1); g:choose(1); g:choose(1)
    assert.equals(91, g._kernel:get_state("player/hp"))
  end)

  it("kernel state cache is seeded with the initial state on attach", function()
    local g = sb.from_source(KERNEL_SRC, "kernel-test"); assert.is_not_nil(g)
    g:init()
    -- HP default is 100; should be visible immediately without any mutation.
    assert.equals(100, g._kernel:get_state("player/hp"))
    assert.equals(0,   g._kernel:get_state("player/gold"))
  end)

  it("get_scene() returns name, narration, choices", function()
    local g = sb.from_source(KERNEL_SRC, "kernel-test"); assert.is_not_nil(g)
    g:init()
    local s = g._kernel:get_scene()
    assert.is_not_nil(s)
    assert.equals("start", s.name)
    assert.is_table(s.choices)
    assert.is_true(#s.choices >= 4)
  end)

  it("get_schema() returns the compiled schema", function()
    local g = sb.from_source(KERNEL_SRC, "kernel-test"); assert.is_not_nil(g)
    g:init()
    local schema = g._kernel:get_schema()
    assert.is_not_nil(schema)
    assert.is_table(schema.states or {})
  end)

  it("multiple subscribers to the same library event all receive payloads", function()
    local g = sb.from_source(KERNEL_SRC, "kernel-test"); assert.is_not_nil(g)
    g:init()
    local a, b = 0, 0
    g:on("mutation", function() a = a + 1 end)
    g:on("mutation", function() b = b + 1 end)
    g:choose(1)
    assert.equals(a, b)
    assert.is_true(a >= 1)
  end)

  it("a coalesced burst of mutations delivers them all in order", function()
    -- A single fn call can mutate multiple paths; each mutation should reach
    -- the kernel in dispatch order (no coalescing in M1 — see ui_event_audit
    -- §4.2 for the deferral note).
    local SRC = [[
module burst-test
  version: 1.0
engine-config:
  entry-scene: main
state world:
  a: Int(0, 99) = 0
  b: Int(0, 99) = 0
  c: Int(0, 99) = 0
scene main:
  * Burst
    set! world/a 1
    set! world/b 2
    set! world/c 3
    -> main
  * End -> end-scene
scene end-scene:
  Done.
]]
    local g = sb.from_source(SRC, "burst"); assert.is_not_nil(g)
    g:init()
    local order = {}
    g:on("mutation", function(p) order[#order+1] = p.path end)
    g:choose(1)
    -- world/a, world/b, world/c should arrive in source order.
    -- (Mutations from a single fn body are dispatched in the order they
    -- appear; later phases may inject others — filter to ours.)
    local ours = {}
    for _, p in ipairs(order) do
      if p == "world/a" or p == "world/b" or p == "world/c" then
        ours[#ours+1] = p
      end
    end
    assert.same({ "world/a", "world/b", "world/c" }, ours)
  end)
end)

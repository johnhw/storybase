-- tests/runtime/demo34_spec.lua
-- Integration tests for demo34_silent_stair.sb (H1 showcase).
--
-- Acceptance criteria mirror the bullet list in the demo header:
--   1. Goal-only NPCs work end-to-end (BFS plans + executes the heist).
--   2. The goal "switches" via the precondition chain
--      (pocket-crown must run between moving in and moving out).
--   3. Two H1 actors compose: the vault-guard reaches his patrol post.
--   4. Closing the stair door mid-route forces the thief to idle.
--   5. The hand-written `verify-eventually world/won` passes.

local engine_mod   = require("runtime.engine")
local compiler_mod = require("compiler.compiler")
local verify_mod   = require("runtime.verify")

local DEMO_PATH = "demos/demo34_silent_stair.sb"

local function compile_demo()
  local gt, diags = compiler_mod.compile_file(DEMO_PATH)
  local errs = {}
  for _, d in ipairs(diags and diags.errors or {}) do
    if d.level == "error" then errs[#errs + 1] = d end
  end
  return gt, errs
end

local function make_engine()
  local gt, errs = compile_demo()
  assert.equals(0, #errs, errs[1] and errs[1].message or "compile errors")
  assert.is_not_nil(gt)
  local eng = engine_mod.new(gt, {
    io_out = { write = function() end },
    io_in  = { read  = function() return "" end },
  })
  eng:init()
  return eng
end

local function find_choice(choices, label_pattern)
  for _, c in ipairs(choices) do
    if c.label:find(label_pattern, 1, true) then return c.index end
  end
  return nil
end

describe("demo34 — The Silent Stair (H1 showcase)", function()

  it("compiles cleanly with no errors", function()
    local gt, errs = compile_demo()
    assert.equals(0, #errs, errs[1] and errs[1].message or "compile errors")
    assert.is_not_nil(gt)
    -- Sanity-check the actor records have goal/actions wiring.
    assert.is_not_nil(gt.actors.thief.goal)
    assert.same({ "move-to", "pocket-crown", "escape" }, gt.actors.thief.actions)
    assert.equal(12, gt.actors.thief.search_depth)
    assert.is_not_nil(gt.actors.guard.goal)
    assert.same({ "guard-step" }, gt.actors.guard.actions)
  end)

  it("the engine-config wires npc-speed: 3", function()
    local gt = compile_demo()
    assert.equal(3, tonumber(gt.schema.engine_config["npc-speed"]))
  end)

  -- ── Acceptance criterion 1 + 3: goal-only NPCs work; multi-actor composition

  it("the thief reaches the gate with the crown and wins via Wait choices", function()
    local eng = make_engine()
    -- Drive briefing → corridor.
    local _, choices = eng:render_scene("briefing")
    local begin_idx = find_choice(choices, "Begin")
    assert.is_not_nil(begin_idx)
    eng:do_choice("briefing", begin_idx)
    eng:post_action_chain()

    -- Inside the corridor scene, "Wait" is the first available choice;
    -- with npc-speed: 3 the heist completes within a handful of choices.
    for _ = 1, 6 do
      if eng._state:get("world/won") then break end
      local _, ch = eng:render_scene("corridor")
      local widx = find_choice(ch, "Wait")
      assert.is_not_nil(widx, "expected a Wait choice in corridor")
      eng:do_choice("corridor", widx)
      eng:post_action_chain()
    end

    assert.is_true(eng._state:get("world/won"),
      "thief failed to reach world/won within 6 Wait choices")
    assert.equal("gate", eng._state:get("thief/at"))
    -- Multi-actor proof: the vault-guard's own H1 plan parked him in the study.
    assert.equal("study", eng._state:get("guard/at"))
  end)

  -- ── Acceptance criterion 2: goal switches via precondition chain

  it("the thief picks up the crown before escaping (precondition staging)", function()
    local eng = make_engine()
    eng:do_choice("briefing", 1)
    eng:post_action_chain()

    -- Set values are stored as arrays; scan for crown.
    local function has_crown(inv)
      if not inv then return false end
      for _, v in pairs(inv) do
        if v == "crown" then return true end
      end
      return false
    end

    local saw_crown_before_win = false
    for _ = 1, 6 do
      if eng._state:get("world/won") then break end
      if has_crown(eng._state:get("thief/inventory")) then
        saw_crown_before_win = true
      end
      eng:do_choice("corridor", 1)  -- Wait
      eng:post_action_chain()
    end

    assert.is_true(saw_crown_before_win,
      "crown was never observed in inventory mid-heist — the BFS skipped pocket-crown")
    assert.is_true(eng._state:get("world/won"))
  end)

  -- ── Acceptance criterion 4: closing the stair door makes the thief idle

  it("closing the stair door blocks the thief and fires the no-progress hook", function()
    local eng = make_engine()
    eng:do_choice("briefing", 1)
    eng:post_action_chain()

    -- Close the stair door BEFORE the thief reaches stair.  After the
    -- briefing tick the thief sits at vault (npc-speed: 3 → 4 ticks per
    -- choice → parlor→hall→stair→landing→vault on tick 1).  We instead
    -- close the door, then reset the thief and verify idle behaviour with
    -- a fresh engine since after tick-1 he's past the stair already.
    eng = make_engine()
    -- Close the door before any tick by directly mutating state.
    eng._state:set("stair-door/open", false, "test-setup")
    -- Now drive the briefing→corridor transition, ticking actors.
    eng._h1_no_progress = nil
    eng:do_choice("briefing", 1)
    eng:post_action_chain()

    -- With stair-door closed the thief cannot reach the vault.  Each
    -- post_action_chain therefore yields a no-progress event from the
    -- thief.  The thief should still be on the south side (parlor or hall).
    assert.is_true(
      eng._state:get("thief/at") == "parlor" or
      eng._state:get("thief/at") == "hall",
      "thief should have idled south of the closed stair door, got: "
        .. tostring(eng._state:get("thief/at")))
    assert.is_not_nil(eng._h1_no_progress,
      "expected no_progress hook to have accumulated at least one actor name")

    local saw_thief = false
    for _, n in ipairs(eng._h1_no_progress) do
      if n == "thief" then saw_thief = true end
    end
    assert.is_true(saw_thief,
      "expected the thief in the no-progress list, got: "
        .. table.concat(eng._h1_no_progress, ","))
    assert.is_false(eng._state:get("world/won"))
  end)

  -- ── Acceptance criterion 5: hand-written verify-eventually passes

  it("verify-eventually world/won passes under the bounded BFS", function()
    local gt = compile_demo()
    local results = verify_mod.run_all(gt)
    -- Find the hand-written winnable verify; it must be in results.
    local winnable
    for _, r in ipairs(results) do
      if r.label and r.label:find("winnable", 1, true) then winnable = r end
    end
    assert.is_not_nil(winnable, "expected the 'winnable' verify result")
    assert.is_true(winnable.pass,
      "verify-eventually world/won failed: "
        .. tostring(winnable.fail_msg or "(no message)"))
  end)
end)

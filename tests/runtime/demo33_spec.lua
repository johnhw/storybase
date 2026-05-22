-- tests/runtime/demo33_spec.lua
-- Integration tests for demo33_apothecary.sb (showcase for §J-I2).
--
-- Each test corresponds to one of the four acceptance criteria documented
-- in todo.md §K1: initial choice count, looped-choice execution with iter
-- bindings, if/else branch flip on shop/moonpetal depletion, and the
-- end-of-day when-gate.

local engine_mod   = require("runtime.engine")
local compiler_mod = require("compiler.compiler")

local DEMO_PATH = "demos/demo33_apothecary.sb"

local function compile_demo()
  local result, diags = compiler_mod.compile_file(DEMO_PATH)
  local errors = {}
  for _, d in ipairs(diags and diags.errors or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return result, errors
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

local function labels(choices)
  local out = {}
  for _, c in ipairs(choices) do out[#out + 1] = c.label end
  return out
end

local function find_choice(choices, label)
  for _, c in ipairs(choices) do
    if c.label == label then return c.index end
  end
  return nil
end

describe("demo33 — The Apothecary's Counter", function()

  it("compiles cleanly", function()
    local gt, errs = compile_demo()
    assert.equals(0, #errs, errs[1] and errs[1].message or "compile errors")
    assert.is_not_nil(gt)
  end)

  -- ── Acceptance criterion 1 ────────────────────────────────────────────────

  it("initial counter scene exposes 4×4 + 1 + 4×2 = 25 choices", function()
    local eng = make_engine()
    local _, ch = eng:render_scene("counter")
    -- 16 standard remedy choices + 8 premium choices + 1 fever-compress.
    assert.equals(25, #ch)
    -- Standard remedy choices: 4 patients × 4 Remedy variants.
    local std = 0
    for _, c in ipairs(ch) do
      if c.label:match("^Give ") then std = std + 1 end
    end
    assert.equals(16, std)
    -- Premium choices: 4 patients × 2 Premium variants (moonpetal=2 → still gated
    -- by current stock check shop/moonpetal > 0, true initially).
    local prem = 0
    for _, c in ipairs(ch) do
      if c.label:match("^Brew ") then prem = prem + 1 end
    end
    assert.equals(8, prem)
    -- Exactly one fever-compress choice (only bethe has fever).
    local fever = 0
    for _, c in ipairs(ch) do
      if c.label:match("^Apply cool compress") then fever = fever + 1 end
    end
    assert.equals(1, fever)
  end)

  it("indices are 1..25 and labels reflect for-loop iter bindings", function()
    local eng = make_engine()
    local _, ch = eng:render_scene("counter")
    for i, c in ipairs(ch) do
      assert.equals(i, c.index)
    end
    -- First choice block covers arlin × Remedy (4 standard + 2 premium).
    assert.equals("Give poultice to arlin", ch[1].label)
    assert.equals("Brew dragonbalm for arlin", ch[6].label)
    -- bethe's block opens at index 7 with one extra (compress) slot.
    assert.equals("Give poultice to bethe", ch[7].label)
    assert.equals("Apply cool compress to bethe", ch[11].label)
  end)

  -- ── Acceptance criterion 2 ────────────────────────────────────────────────

  it("selecting 'Give tonic to bethe' marks bethe treated and bumps served", function()
    local eng = make_engine()
    local _, ch = eng:render_scene("counter")
    local idx = find_choice(ch, "Give tonic to bethe")
    assert.is_not_nil(idx, "expected 'Give tonic to bethe' in choice list")

    eng:do_choice("counter", idx)

    assert.is_true(eng._state:get("patients/bethe/treated"))
    assert.equals(1, eng._state:get("shop/served"))
    -- last-note reflects the iter binding (r=tonic, p=bethe).
    assert.equals("Prepared a tonic for bethe.",
      eng._state:get("shop/last-note"))

    -- bethe row vanishes from the next render; other three still waiting.
    local _, ch2 = eng:render_scene("counter")
    assert.is_nil(find_choice(ch2, "Give tonic to bethe"))
    assert.is_nil(find_choice(ch2, "Apply cool compress to bethe"))
    assert.is_not_nil(find_choice(ch2, "Give tonic to arlin"))
    assert.is_not_nil(find_choice(ch2, "Give tonic to corwin"))
    assert.is_not_nil(find_choice(ch2, "Give tonic to dell"))
  end)

  -- ── Acceptance criterion 3 ────────────────────────────────────────────────

  it("moonpetal depletion flips if/else: premium choices replaced by narration", function()
    local eng = make_engine()

    -- Burn both moonpetals on two premium brews (arlin then bethe).
    local _, ch = eng:render_scene("counter")
    eng:do_choice("counter", find_choice(ch, "Brew elixir-of-moon for arlin"))
    local _, ch2 = eng:render_scene("counter")
    eng:do_choice("counter", find_choice(ch2, "Brew dragonbalm for bethe"))

    assert.equals(0, eng._state:get("shop/moonpetal"))

    local _, ch3 = eng:render_scene("counter")
    -- No premium choices should be visible for the remaining patients.
    for _, c in ipairs(ch3) do
      assert.is_nil(c.label:match("^Brew "),
        "unexpected premium choice after moonpetal depletion: " .. c.label)
    end
    -- corwin and dell still have their standard rows.
    assert.is_not_nil(find_choice(ch3, "Give poultice to corwin"))
    assert.is_not_nil(find_choice(ch3, "Give poultice to dell"))
  end)

  -- ── Acceptance criterion 4 ────────────────────────────────────────────────

  it("treating all four patients surfaces 'Close up shop' via outer when-gate", function()
    local eng = make_engine()

    -- Pick the first available standard-remedy choice for each patient.
    local patients = { "arlin", "bethe", "corwin", "dell" }
    for _, p in ipairs(patients) do
      local _, ch = eng:render_scene("counter")
      local idx = find_choice(ch, "Give poultice to " .. p)
      assert.is_not_nil(idx, "missing 'Give poultice to " .. p .. "'")
      eng:do_choice("counter", idx)
    end

    assert.equals(4, eng._state:get("shop/served"))

    local _, ch_end = eng:render_scene("counter")
    -- The only remaining visible choice should be 'Close up shop'.
    assert.equals(1, #ch_end)
    assert.equals("Close up shop", ch_end[1].label)

    -- Selecting it routes to end-day.
    eng:do_choice("counter", ch_end[1].index)
    local _, ch_done = eng:render_scene("end-day")
    assert.equals(1, #ch_done)
    assert.equals("Rest well", ch_done[1].label)
  end)

  -- ── Iter binding flow through fn call ────────────────────────────────────

  it("looped-choice body propagates both iter bindings (p and r) into fn args", function()
    local eng = make_engine()
    local _, ch = eng:render_scene("counter")
    local idx = find_choice(ch, "Give salve to corwin")
    assert.is_not_nil(idx)
    eng:do_choice("counter", idx)
    -- Only corwin should be treated; salve/corwin should appear in the note.
    assert.is_true(eng._state:get("patients/corwin/treated"))
    assert.is_false(eng._state:get("patients/arlin/treated"))
    assert.is_false(eng._state:get("patients/bethe/treated"))
    assert.is_false(eng._state:get("patients/dell/treated"))
    assert.equals("Prepared a salve for corwin.",
      eng._state:get("shop/last-note"))
  end)
end)

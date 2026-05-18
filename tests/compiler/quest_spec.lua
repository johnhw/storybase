-- tests/compiler/quest_spec.lua
-- Tests for §E1: `quest` declaration parsing, desugar (state + helper fns),
-- and the auto-emitted reachability verify block.

local compiler = require("compiler.compiler")
local parser   = require("compiler.parser")
local lexer    = require("compiler.lexer")
local ast      = require("compiler.ast")

local HEADER = [[
module quest-test
  version: 1.0
engine-config:
  entry-scene: start
state player:
  has-key:   Bool      = false
  has-torch: Bool      = false
  has-crown: Bool      = false
  gold:      Int(0, 1000) = 0
scene start:
  * Begin
    -> start
]]

local function compile(extra, opts)
  return compiler.compile(HEADER .. extra, "q.sb", opts)
end

local function lex_parse(src)
  local toks = lexer.tokenize(src, "q.sb")
  return parser.parse(toks, "q.sb")
end

-- ── Parser ────────────────────────────────────────────────────────────────

describe("quest decl — parser", function()

  it("parses a minimal quest with one step", function()
    local root, diags = lex_parse(HEADER .. [[
quest tiny:
  step do-it:
    pass
]])
    assert.equal(0, #diags)
    local found
    for _, d in ipairs(root.decls) do
      if d.kind == ast.K.QUEST_DECL then found = d end
    end
    assert.is_not_nil(found)
    assert.equal("tiny", found.name)
    assert.equal(1, #found.steps)
    assert.equal("do-it", found.steps[1].name)
  end)

  it("parses description, prereq, reward, multiple steps", function()
    local root, diags = lex_parse(HEADER .. [[
quest crown:
  description: "Recover the crown."
  prereq:      player/has-key
  step talk-king:
    pass
  step explore:
    requires: player/has-torch
    pass
  step retrieve:
    requires: player/has-crown
    pass
  reward:
    inc! player/gold 500
]])
    assert.equal(0, #diags)
    local found
    for _, d in ipairs(root.decls) do
      if d.kind == ast.K.QUEST_DECL then found = d end
    end
    assert.is_not_nil(found)
    assert.equal("Recover the crown.", found.description)
    assert.is_not_nil(found.prereq)
    assert.equal(3, #found.steps)
    assert.equal("talk-king",  found.steps[1].name)
    assert.equal("explore",    found.steps[2].name)
    assert.equal("retrieve",   found.steps[3].name)
    assert.is_nil(found.steps[1].requires)
    assert.is_not_nil(found.steps[2].requires)
    assert.is_not_nil(found.steps[3].requires)
    assert.is_not_nil(found.reward)
    assert.is_true(#found.reward >= 1)
  end)

  it("rejects a quest with no name", function()
    local _, diags = lex_parse(HEADER .. [[
quest:
  step thing:
    pass
]])
    -- A quest with no name is invalid; the parser should emit BAD_DECLARATION.
    local got
    for _, d in ipairs(diags) do
      if d.code == ast.E.BAD_DECLARATION then got = d end
    end
    assert.is_not_nil(got)
  end)
end)

-- ── Desugar (compiler.expand_quests) ──────────────────────────────────────

describe("quest decl — desugar", function()

  it("emits state paths for active/complete + each step", function()
    local game, diags = compile([[
quest mini:
  step a:
    pass
  step b:
    pass
]])
    assert.is_false(diags:has_errors(),
      "compile errors: " .. (diags.all and diags.all[1] and diags.all[1].message or ""))
    -- Collect emitted state paths.
    local paths = {}
    for _, s in ipairs(game.schema.states) do
      paths[s.path] = true
    end
    assert.is_true(paths["quests/mini/active"]   ~= nil,
      "missing quests/mini/active")
    assert.is_true(paths["quests/mini/complete"] ~= nil,
      "missing quests/mini/complete")
    assert.is_true(paths["quests/mini/a"]        ~= nil,
      "missing quests/mini/a")
    assert.is_true(paths["quests/mini/b"]        ~= nil,
      "missing quests/mini/b")
  end)

  it("emits helper fns: -active?, -complete?, -step-N?, -start!, -do-N", function()
    local game, _ = compile([[
quest mini:
  step a:
    pass
  step b:
    pass
]])
    assert.is_not_nil(game.fns["quest-mini-active?"])
    assert.is_not_nil(game.fns["quest-mini-complete?"])
    assert.is_not_nil(game.fns["quest-mini-step-a?"])
    assert.is_not_nil(game.fns["quest-mini-step-b?"])
    assert.is_not_nil(game.fns["quest-mini-start!"])
    assert.is_not_nil(game.fns["quest-mini-do-a"])
    assert.is_not_nil(game.fns["quest-mini-do-b"])
  end)

  it("collects quest metadata into game_table.quests", function()
    local game, _ = compile([[
quest mini:
  description: "Tiny."
  step only:
    pass
]])
    assert.equal(1, #game.quests)
    assert.equal("mini", game.quests[1].name)
    assert.equal("Tiny.", game.quests[1].description)
    assert.equal(1, #game.quests[1].steps)
    assert.equal("only", game.quests[1].steps[1].name)
  end)

  it("reports duplicate quest names", function()
    local _, diags = compile([[
quest twin:
  step a:
    pass

quest twin:
  step b:
    pass
]])
    local got
    for _, d in ipairs(diags.all or {}) do
      if d.code == ast.E.DUPLICATE_NAME and d.message:match("quest") then
        got = d
      end
    end
    assert.is_not_nil(got)
  end)

  it("reports duplicate step names within a quest", function()
    local _, diags = compile([[
quest mini:
  step dup:
    pass
  step dup:
    pass
]])
    local got
    for _, d in ipairs(diags.all or {}) do
      if d.code == ast.E.DUPLICATE_NAME and d.message:match("step") then
        got = d
      end
    end
    assert.is_not_nil(got)
  end)
end)

-- ── Auto-emitted verify ───────────────────────────────────────────────────

describe("quest decl — auto-verify", function()

  it("emits a 'reachable to completion' verify per quest", function()
    local game, _ = compile([[
quest one:
  step a:
    pass
quest two:
  step b:
    pass
]])
    local labels = {}
    for _, v in ipairs(game.verifies) do
      if v._auto and v.label:match("reachable to completion") then
        labels[#labels+1] = v.label
      end
    end
    table.sort(labels)
    assert.same({
      "quest 'one' is reachable to completion",
      "quest 'two' is reachable to completion",
    }, labels)
  end)

  it("auto-verify clause is verify-eventually on quest-<name>-complete?", function()
    local game, _ = compile([[
quest solo:
  step a:
    pass
]])
    local v
    for _, vv in ipairs(game.verifies) do
      if vv._auto and vv.label:match("reachable to completion") then v = vv end
    end
    assert.is_not_nil(v)
    assert.equal(1, #v.clauses)
    assert.equal("eventually", v.clauses[1].kind)
    local cond = v.clauses[1].condition
    assert.is_not_nil(cond)
    assert.equal(ast.K.FN_CALL, cond.kind)
    assert.equal("quest-solo-complete?", cond.name)
  end)

  it("strips auto-verifies in production mode", function()
    local game, _ = compile([[
quest solo:
  step a:
    pass
]], { production = true })
    assert.equal(0, #game.verifies)
    -- Quest metadata is still emitted; desugar is part of the program.
    assert.equal(1, #game.quests)
    assert.is_not_nil(game.fns["quest-solo-complete?"])
  end)
end)

-- ── Runtime behaviour of the desugared fns ────────────────────────────────

describe("quest decl — runtime", function()

  local engine_mod = require("runtime.engine")

  local RUN_HEADER = [[
module quest-rt
  version: 1.0
engine-config:
  entry-scene: hub
state player:
  has-key:   Bool         = false
  has-torch: Bool         = false
  gold:      Int(0, 1000) = 0
scene hub:
  * pass
    -> hub
]]

  local function fresh_engine(body)
    local game, diags = compiler.compile(RUN_HEADER .. body, "rt.sb")
    assert.is_false(diags:has_errors(),
      "compile errors: " ..
      (diags.all and diags.all[1] and diags.all[1].message or ""))
    local eng = engine_mod.new(game, { io_out = function() end })
    eng:init()
    return eng, game
  end

  it("start! flips active=true only when not active/complete and prereq holds", function()
    local eng = fresh_engine([[
quest q:
  prereq: player/has-key
  step a:
    pass
]])
    assert.equal(false, eng._state:get("quests/q/active"))
    -- prereq false → no-op
    eng:make_ctx("test")  -- ctx unused, just exercising the wiring
    local ok, ret = pcall(function()
      local ctx = eng:make_ctx("test")
      local eval = require("runtime.eval")
      return eval.call_fn("quest-q-start!", {}, ctx)
    end)
    assert.is_true(ok)
    assert.equal(false, eng._state:get("quests/q/active"),
      "start! is a no-op until prereq holds")
    -- Satisfy prereq, retry
    eng._state:set("player/has-key", true, "test")
    local eval = require("runtime.eval")
    eval.call_fn("quest-q-start!", {}, eng:make_ctx("test"))
    assert.equal(true, eng._state:get("quests/q/active"))
  end)

  it("do-<step> advances and completing the last step fires reward + complete", function()
    local eng = fresh_engine([[
quest q:
  step a:
    pass
  step b:
    pass
  reward:
    inc! player/gold 100
]])
    local eval = require("runtime.eval")
    eval.call_fn("quest-q-start!", {}, eng:make_ctx("test"))
    assert.equal(true,  eng._state:get("quests/q/active"))
    eval.call_fn("quest-q-do-a", {}, eng:make_ctx("test"))
    assert.equal(true,  eng._state:get("quests/q/a"))
    assert.equal(false, eng._state:get("quests/q/complete"))
    assert.equal(0,     eng._state:get("player/gold"))
    eval.call_fn("quest-q-do-b", {}, eng:make_ctx("test"))
    assert.equal(true,  eng._state:get("quests/q/b"))
    assert.equal(true,  eng._state:get("quests/q/complete"))
    assert.equal(false, eng._state:get("quests/q/active"))
    assert.equal(100,   eng._state:get("player/gold"))
  end)

  it("do-<step> is gated by requires:", function()
    local eng = fresh_engine([[
quest q:
  step gated:
    requires: player/has-torch
    pass
]])
    local eval = require("runtime.eval")
    eval.call_fn("quest-q-start!", {}, eng:make_ctx("test"))
    eval.call_fn("quest-q-do-gated", {}, eng:make_ctx("test"))
    assert.equal(false, eng._state:get("quests/q/gated"),
      "do-gated is a no-op while requires: false")
    eng._state:set("player/has-torch", true, "test")
    eval.call_fn("quest-q-do-gated", {}, eng:make_ctx("test"))
    assert.equal(true,  eng._state:get("quests/q/gated"))
    assert.equal(true,  eng._state:get("quests/q/complete"))
  end)

  it("query fns -active? / -complete? / -step-N? return path values", function()
    local eng = fresh_engine([[
quest q:
  step a:
    pass
]])
    local eval = require("runtime.eval")
    assert.equal(false, eval.call_fn("quest-q-active?",   {}, eng:make_ctx("t")))
    assert.equal(false, eval.call_fn("quest-q-complete?", {}, eng:make_ctx("t")))
    assert.equal(false, eval.call_fn("quest-q-step-a?",   {}, eng:make_ctx("t")))
    eval.call_fn("quest-q-start!", {}, eng:make_ctx("t"))
    assert.equal(true,  eval.call_fn("quest-q-active?",   {}, eng:make_ctx("t")))
    eval.call_fn("quest-q-do-a", {}, eng:make_ctx("t"))
    assert.equal(false, eval.call_fn("quest-q-active?",   {}, eng:make_ctx("t")))
    assert.equal(true,  eval.call_fn("quest-q-complete?", {}, eng:make_ctx("t")))
    assert.equal(true,  eval.call_fn("quest-q-step-a?",   {}, eng:make_ctx("t")))
  end)
end)

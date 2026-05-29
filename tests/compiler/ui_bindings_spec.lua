-- tests/compiler/ui_bindings_spec.lua
-- Tests for §M4: author UI bindings (parser + schema).
--
--   ui_idea.md §5.1 — `ui:` block on a state decl
--   ui_idea.md §5.2 — `ui-panel <name>:` top-level decl
--   ui_idea.md §M4  — milestone summary

local lexer   = require("compiler.lexer")
local parser  = require("compiler.parser")
local checker = require("compiler.checker")
local codegen = require("compiler.codegen")
local ast     = require("compiler.ast")

local function compile(src, opts)
  local tokens     = lexer.tokenize(src, "test")
  local tree, diag = parser.parse(tokens, "test")
  local typed      = checker.check(tree, "test")
  local gt, diags  = codegen.emit(typed, opts)
  return gt, diags, diag, tree
end

local function state_by_path(gt, path)
  for _, s in ipairs(gt.schema.states or {}) do
    if s.path == path or (s.family == path) then return s end
  end
  return nil
end

local function panel_by_name(gt, name)
  for _, p in ipairs(gt.ui_panels or {}) do
    if p.name == name then return p end
  end
  return nil
end

-- ============================================================
-- §5.1 — ui: block on state decls
-- ============================================================

describe("ui bindings — ui: block on state scalar", function()
  it("parses a simple ui: block without errors", function()
    local _, diags, pdiags = compile([[
state player/hp: Int(0, 100) = 100
  ui:
    kind: stat-bar
]])
    assert.are.equal(0, #diags)
    assert.are.equal(0, #pdiags)
  end)

  it("attaches the ui block to the parsed state_scalar AST node", function()
    local _, _, _, tree = compile([[
state player/hp: Int(0, 100) = 100
  ui:
    kind: stat-bar
    label: "Health"
]])
    local found
    for _, d in ipairs(tree.decls) do
      if d.kind == ast.K.STATE_SCALAR then found = d; break end
    end
    assert.is_not_nil(found)
    assert.is_table(found.ui)
    assert.is_table(found.ui.fields)
    assert.are.equal("kind", found.ui.fields[1].name)
    assert.are.equal("stat-bar", found.ui.fields[1].value.value)
  end)

  it("emits schema.states[*].ui as a flat key→value map", function()
    local gt = compile([[
state player/hp: Int(0, 100) = 100
  ui:
    kind: stat-bar
    label: "Health"
    color-good: "#4ade80"
    color-bad: "#ef4444"
]])
    local s = state_by_path(gt, "player/hp")
    assert.is_not_nil(s)
    assert.is_table(s.ui)
    assert.are.equal("stat-bar", s.ui.kind)
    assert.are.equal("Health", s.ui.label)
    assert.are.equal("#4ade80", s.ui["color-good"])
    assert.are.equal("#ef4444", s.ui["color-bad"])
  end)

  it("leaves states without ui blocks with state.ui == nil", function()
    local gt = compile("state player/hp: Int(0, 100) = 100")
    local s = state_by_path(gt, "player/hp")
    assert.is_not_nil(s)
    assert.is_nil(s.ui)
  end)

  it("does not interfere with the default value", function()
    local gt = compile([[
state player/hp: Int(0, 100) = 42
  ui:
    kind: stat-bar
]])
    local s = state_by_path(gt, "player/hp")
    -- codegen wraps scalar defaults as {tag=..., value=...}
    assert.are.equal(42, s.default and s.default.value)
  end)

  it("accepts integer, float, bool, and ident values", function()
    local gt = compile([[
state player/hp: Int(0, 100) = 100
  ui:
    kind: stat-bar
    width: 20
    ratio: 0.5
    show-numbers: true
    style: rounded
]])
    local s = state_by_path(gt, "player/hp")
    assert.are.equal(20, s.ui.width)
    assert.are.equal(0.5, s.ui.ratio)
    assert.are.equal(true, s.ui["show-numbers"])
    assert.are.equal("rounded", s.ui.style)
  end)
end)

describe("ui bindings — ui: block on state family", function()
  it("attaches ui block to a state_family AST node", function()
    local gt, diags = compile([[
type NpcMood = happy | neutral | grumpy
state npcs/{npc}: NpcMood max: 10
  ui:
    kind: stat
    label: "Mood"
]])
    assert.are.equal(0, #diags)
    local s
    for _, st in ipairs(gt.schema.states) do
      if st.kind == "family" and st.family == "npcs" then s = st; break end
    end
    assert.is_not_nil(s)
    assert.is_table(s.ui)
    assert.are.equal("stat", s.ui.kind)
    assert.are.equal("Mood", s.ui.label)
  end)
end)

-- ============================================================
-- §5.2 — ui-panel decl
-- ============================================================

describe("ui bindings — ui-panel decl", function()
  it("parses a minimal ui-panel without errors", function()
    local _, _, pdiags = compile([[
ui-panel status:
  layout: vstack
]])
    assert.are.equal(0, #pdiags)
  end)

  it("emits a ui_panels list with the declared panel", function()
    local gt = compile([[
ui-panel status:
  layout: vstack
  position: top
]])
    assert.is_table(gt.ui_panels)
    assert.are.equal(1, #gt.ui_panels)
    local p = gt.ui_panels[1]
    assert.are.equal("status", p.name)
    assert.are.equal("vstack", p.layout)
    assert.are.equal("top", p.position)
  end)

  it("emits the children list with widget references", function()
    local gt = compile([[
state player/hp:   Int(0, 100) = 100
state player/mana: Int(0, 100) = 50
state player/gold: Int(0, 1000) = 0

ui-panel status:
  layout: vstack
  position: top
  children:
    - stat-bar player/hp
    - stat-bar player/mana
    - text "Gold: {player/gold}"
]])
    local p = panel_by_name(gt, "status")
    assert.is_not_nil(p)
    assert.is_table(p.children)
    assert.are.equal(3, #p.children)
    assert.are.equal("stat-bar", p.children[1].kind)
    assert.are.equal("player/hp", p.children[1].arg)
    assert.are.equal("stat-bar", p.children[2].kind)
    assert.are.equal("player/mana", p.children[2].arg)
    assert.are.equal("text", p.children[3].kind)
    assert.are.equal("Gold: {player/gold}", p.children[3].arg)
  end)

  it("accepts children without the leading '-' bullet", function()
    local gt = compile([[
state player/hp: Int(0, 100) = 100

ui-panel status:
  children:
    stat-bar player/hp
    text "Stats"
]])
    local p = panel_by_name(gt, "status")
    assert.is_not_nil(p)
    assert.are.equal(2, #p.children)
    assert.are.equal("stat-bar", p.children[1].kind)
    assert.are.equal("text", p.children[2].kind)
  end)

  it("allows multiple ui-panel decls", function()
    local gt = compile([[
ui-panel header:
  layout: hstack
ui-panel footer:
  layout: hstack
]])
    assert.are.equal(2, #gt.ui_panels)
    assert.is_not_nil(panel_by_name(gt, "header"))
    assert.is_not_nil(panel_by_name(gt, "footer"))
  end)

  it("attaches an optional doc string", function()
    local gt = compile([[
"The player's health and mana stats."
ui-panel status:
  layout: vstack
]])
    local p = panel_by_name(gt, "status")
    assert.are.equal("The player's health and mana stats.", p.doc)
  end)
end)

-- ============================================================
-- Production strip + ui-runtime flag
-- ============================================================

describe("ui bindings — production strip", function()
  local src = [[
state player/hp: Int(0, 100) = 100
  ui:
    kind: stat-bar
    label: "Health"

ui-panel status:
  layout: vstack
  children:
    - stat-bar player/hp
]]

  it("retains ui bindings by default (non-production)", function()
    local gt = compile(src)
    local s = state_by_path(gt, "player/hp")
    assert.is_table(s.ui)
    assert.are.equal("stat-bar", s.ui.kind)
    assert.are.equal(1, #gt.ui_panels)
  end)

  it("strips ui bindings in production builds", function()
    local gt = compile(src, { production = true })
    local s = state_by_path(gt, "player/hp")
    assert.is_nil(s.ui)
    assert.are.equal(0, #gt.ui_panels)
  end)

  it("retains ui bindings in production when ui-runtime is true", function()
    local src_rt = [[
engine-config:
  ui-runtime: true

]] .. src
    local gt = compile(src_rt, { production = true })
    local s = state_by_path(gt, "player/hp")
    assert.is_table(s.ui)
    assert.are.equal("stat-bar", s.ui.kind)
    assert.are.equal(1, #gt.ui_panels)
  end)

  it("strips when ui-runtime is explicitly false", function()
    local src_rt = [[
engine-config:
  ui-runtime: false

]] .. src
    local gt = compile(src_rt, { production = true })
    local s = state_by_path(gt, "player/hp")
    assert.is_nil(s.ui)
    assert.are.equal(0, #gt.ui_panels)
  end)
end)

-- ============================================================
-- Sanity: existing state-decl semantics unchanged
-- ============================================================

describe("ui bindings — non-interference with existing parsing", function()
  it("a state decl with no trailing block still parses cleanly", function()
    local gt, diags, pdiags = compile("state player/hp: Int(0, 100) = 100")
    assert.are.equal(0, #pdiags)
    assert.are.equal(0, #diags)
    assert.is_not_nil(state_by_path(gt, "player/hp"))
  end)

  it("an inline-record state decl is unaffected", function()
    local _, _, pdiags = compile([[
state player:
  hp:   Int(0, 100) = 100
  mana: Int(0, 100) = 50
]])
    assert.are.equal(0, #pdiags)
  end)

  it("game_table.ui_panels is an empty list when no panels are declared", function()
    local gt = compile("state player/hp: Int(0, 100) = 100")
    assert.is_table(gt.ui_panels)
    assert.are.equal(0, #gt.ui_panels)
  end)
end)

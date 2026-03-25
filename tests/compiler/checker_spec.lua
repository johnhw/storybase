-- tests/compiler/checker_spec.lua
-- Tests for compiler/checker.lua (passes 1 & 2)

local lexer   = require("compiler.lexer")
local parser  = require("compiler.parser")
local checker = require("compiler.checker")
local ast     = require("compiler.ast")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function compile(src)
  local tokens = lexer.tokenize(src, "test")
  local tree   = parser.parse(tokens, "test")
  local typed, diags = checker.check(tree, "test")
  return typed, diags
end

local function check_ok(src)
  local _, diags = compile(src)
  local errs = {}
  for _, d in ipairs(diags) do
    if d.level == "error" then table.insert(errs, d.code .. ": " .. d.message) end
  end
  assert.are.equal(0, #errs, "unexpected errors: " .. table.concat(errs, "; "))
end

local function check_err(src, expected_code)
  local _, diags = compile(src)
  for _, d in ipairs(diags) do
    if d.level == "error" and d.code == expected_code then return d end
  end
  local found = {}
  for _, d in ipairs(diags) do table.insert(found, d.code) end
  error("expected error " .. expected_code .. " but got: " .. table.concat(found, ", "))
end

local function symtab(src)
  local typed = compile(src)
  return typed.symtab
end

-- ============================================================
-- Pass 1 — Schema collection
-- ============================================================

describe("checker pass 1 — type collection", function()
  it("collects enum types into symtab", function()
    local st = symtab("type Status = alive | dead")
    assert.is_not_nil(st.types["Status"])
    assert.are.equal(ast.K.TYPE_ENUM, st.types["Status"].kind)
  end)

  it("collects alias types into symtab", function()
    local st = symtab("type Health = Int(0, 100)")
    assert.is_not_nil(st.types["Health"])
    assert.are.equal(ast.K.TYPE_ALIAS, st.types["Health"].kind)
  end)

  it("collects record types into symtab", function()
    local st = symtab("type Player:\n  hp: Int(0, 100)")
    assert.is_not_nil(st.types["Player"])
    assert.are.equal(ast.K.TYPE_RECORD, st.types["Player"].kind)
  end)

  it("collects variant types into symtab", function()
    local st = symtab("type Msg:\n  | ping:")
    assert.is_not_nil(st.types["Msg"])
    assert.are.equal(ast.K.TYPE_VARIANT, st.types["Msg"].kind)
  end)

  it("emits DUPLICATE_NAME for two types with the same name", function()
    check_err(
      "type Status = alive | dead\ntype Status = yes | no",
      ast.E.DUPLICATE_NAME
    )
  end)

  it("emits DUPLICATE_NAME for shadowing a built-in type", function()
    check_err("type Bool = yes | no", ast.E.DUPLICATE_NAME)
  end)
end)

describe("checker pass 1 — state collection", function()
  it("collects scalar state into symtab", function()
    local st = symtab("type P:\n  hp: Int(0,100)\nstate player: P")
    assert.is_not_nil(st.states["player"])
  end)

  it("collects inline-record state into symtab", function()
    local st = symtab("state world:\n  turn: Int(0, 9999) = 0")
    assert.is_not_nil(st.states["world"])
  end)

  it("collects entity family state into symtab", function()
    local st = symtab("type Npc:\n  hp: Int(0,100)\nstate npcs/{npc}: Npc  max: 20")
    assert.is_not_nil(st.states["npcs/{npc}"])
  end)

  it("emits DUPLICATE_NAME for duplicate state path", function()
    check_err(
      "type P:\n  hp: Int(0,100)\nstate player: P\nstate player: P",
      ast.E.DUPLICATE_NAME
    )
  end)
end)

describe("checker pass 1 — relation collection", function()
  it("collects relation into symtab", function()
    local st = symtab("type L = a | b\nrelation exits: L -> Set(L, 4)")
    assert.is_not_nil(st.relations["exits"])
  end)

  it("emits DUPLICATE_NAME for duplicate relation", function()
    check_err(
      "type L = a | b\nrelation exits: L -> Set(L, 4)\nrelation exits: L -> Set(L, 2)",
      ast.E.DUPLICATE_NAME
    )
  end)
end)

-- ============================================================
-- Pass 2 — Type resolution
-- ============================================================

describe("checker pass 2 — type resolution", function()
  it("resolves named type in alias", function()
    local typed = compile("type Status = alive | dead\ntype S2 = Status")
    local alias = typed.decls[2]
    assert.are.equal(ast.K.TYPE_ALIAS, alias.kind)
    assert.is_not_nil(alias.type_expr.resolved)
    assert.are.equal(ast.K.TYPE_ENUM, alias.type_expr.resolved.kind)
  end)

  it("resolves built-in types without error", function()
    check_ok("type H = Int(0, 100)\ntype F = Float\ntype S = String")
  end)

  it("emits UNDEFINED_TYPE for unknown named type in alias", function()
    check_err("type H = NotDeclared", ast.E.UNDEFINED_TYPE)
  end)

  it("emits UNDEFINED_TYPE for unknown type in record field", function()
    check_err("type Rec:\n  x: NotDeclared", ast.E.UNDEFINED_TYPE)
  end)

  it("emits UNDEFINED_TYPE for unknown from-type in relation", function()
    check_err("type L = a | b\nrelation r: NotDeclared -> Set(L, 4)", ast.E.UNDEFINED_TYPE)
  end)

  it("resolves named type in state scalar", function()
    local typed = compile("type Status = alive | dead\nstate s: Status")
    local sd = typed.decls[2]
    assert.is_not_nil(sd.type_expr.resolved)
  end)

  it("resolves named type in state family", function()
    local typed = compile("type Npc:\n  hp: Int(0,100)\nstate npcs/{npc}: Npc  max: 5")
    local sf = typed.decls[2]
    assert.is_not_nil(sf.type_expr.resolved)
  end)

  it("resolves nested type expressions (Set(T, N))", function()
    check_ok("type L = a | b\ntype S = Set(L, 10)")
  end)

  it("resolves Option(T)", function()
    check_ok("type L = a | b\ntype O = Option(L)")
  end)

  it("resolves UMap(K, V)", function()
    check_ok("type L = a | b\ntype M = UMap(String, L)")
  end)
end)

-- ============================================================
-- Pass 2 — Int bounds
-- ============================================================

describe("checker pass 2 — Int bounds", function()
  it("accepts well-formed Int bounds", function()
    check_ok("type H = Int(0, 100)")
  end)

  it("emits BAD_INT_BOUNDS when min > max", function()
    check_err("type H = Int(100, 0)", ast.E.BAD_INT_BOUNDS)
  end)

  it("accepts equal bounds (single-value int)", function()
    check_ok("type Zero = Int(0, 0)")
  end)
end)

-- ============================================================
-- Pass 2 — Record mixin (with)
-- ============================================================

describe("checker pass 2 — record mixin", function()
  it("accepts a valid mixin", function()
    check_ok("type Base:\n  hp: Int(0,100)\ntype Child:\n  with Base\n  mp: Int(0,50)")
  end)

  it("emits UNDEFINED_TYPE for unknown mixin", function()
    check_err("type Child:\n  with UnknownBase", ast.E.UNDEFINED_TYPE)
  end)

  it("emits TYPE_MISMATCH when mixin target is not a record", function()
    check_err(
      "type Status = alive | dead\ntype Child:\n  with Status",
      ast.E.TYPE_MISMATCH
    )
  end)

  it("emits CONFLICTING_WITH when two mixins share a field name", function()
    check_err([[
type A:
  x: Int(0, 10)
type B:
  x: Int(0, 20)
type C:
  with A
  with B
]], ast.E.CONFLICTING_WITH)
  end)

  it("allows default override from same record after mixin", function()
    -- 'x' from Base is overridden in Child — this is legal
    check_ok([[
type Base:
  x: Int(0, 100) = 10
type Child:
  with Base
  x: Int(0, 100) = 50
]])
  end)

  it("attaches resolved mixin declaration to with_mixin node", function()
    local typed = compile("type Base:\n  hp: Int(0,100)\ntype Child:\n  with Base")
    local child = typed.decls[2]
    assert.are.equal(ast.K.TYPE_RECORD, child.kind)
    local with_node = child.fields[1]
    assert.are.equal(ast.K.WITH_MIXIN, with_node.kind)
    assert.is_not_nil(with_node.resolved)
    assert.are.equal(ast.K.TYPE_RECORD, with_node.resolved.kind)
  end)
end)

-- ============================================================
-- Pass 2 — Variant branch fields
-- ============================================================

describe("checker pass 2 — variant branch fields", function()
  it("resolves field types in variant branches", function()
    check_ok("type NpcId = a | b\ntype Msg:\n  | alert: threat: NpcId")
  end)

  it("emits UNDEFINED_TYPE for unknown type in variant branch", function()
    check_err("type Msg:\n  | alert: threat: NoSuchType", ast.E.UNDEFINED_TYPE)
  end)
end)

-- ============================================================
-- Integration
-- ============================================================

describe("checker — integration", function()
  it("checks a full schema snippet without errors", function()
    check_ok([[
type Status    = alive | dead | unconscious
type Location  = village | forest | dungeon
type Health    = Int(0, 100)
type Gold      = Int(0, 9999)

type Entity:
  health:   Health   = 50
  status:   Status   = 'alive
  location: Location = 'village

type Player:
  with Entity
  gold: Gold = 30

state player: Player

state world:
  turn:    Int(0, 9999) = 0
  chapter: Location     = 'village

state npcs/{npc}: Entity  max: 20

relation exits: Location -> Set(Location, 6)
]])
  end)

  it("attaches symtab to the AST root", function()
    local typed = compile("type Status = alive | dead")
    assert.is_not_nil(typed.symtab)
    assert.is_not_nil(typed.symtab.types)
    assert.is_not_nil(typed.symtab.states)
    assert.is_not_nil(typed.symtab.relations)
  end)
end)

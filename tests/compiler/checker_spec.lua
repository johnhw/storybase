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

-- ============================================================
-- Pass 3 — Pure / transaction inference
-- ============================================================

-- Helper: get the first fn_decl from a compiled snippet
local function first_fn(src)
  local typed, _ = compile(src)
  for _, d in ipairs(typed.decls) do
    if d.kind == ast.K.FN_DECL then return d end
  end
  return nil
end

describe("checker pass 3 — purity inference", function()
  it("classifies a no-mutation fn as pure (is_transaction=false)", function()
    local fn = first_fn("fn compute:\n  42")
    assert.is_not_nil(fn)
    assert.is_false(fn.is_transaction)
  end)

  it("classifies a fn with set! as a transaction", function()
    local fn = first_fn("fn update:\n  set! player/health 100")
    assert.is_not_nil(fn)
    assert.is_true(fn.is_transaction)
  end)

  it("classifies a fn with inc! as a transaction", function()
    local fn = first_fn("fn add-gold:\n  inc! player/gold 10")
    assert.is_true(fn.is_transaction)
  end)

  it("classifies a fn with dec! as a transaction", function()
    local fn = first_fn("fn spend:\n  dec! player/gold 5")
    assert.is_true(fn.is_transaction)
  end)

  it("classifies a fn with only path reads as pure", function()
    local fn = first_fn("fn alive?:\n  player/status")
    assert.is_false(fn.is_transaction)
  end)

  it("classifies a fn with mutation inside when-block as transaction", function()
    local fn = first_fn([[
fn update:
  when player/health <= 0:
    set! player/status 'dead]])
    assert.is_true(fn.is_transaction)
  end)

  it("classifies a fn with mutation inside if-block as transaction", function()
    local fn = first_fn([[
fn maybe-heal:
  if player/alive:
    inc! player/health 10]])
    assert.is_true(fn.is_transaction)
  end)

  it("emits PURE_CALLS_MUT if pre: contains a mutation", function()
    check_err([[
fn bad:
  pre: set! player/health 100
  pass]], ast.E.PURE_CALLS_MUT)
  end)

  it("emits PURE_CALLS_MUT if post: contains a mutation", function()
    check_err([[
fn bad:
  post: set! player/health 100
  pass]], ast.E.PURE_CALLS_MUT)
  end)

  it("does not emit errors for valid pre:/post: expressions", function()
    check_ok([[
fn take-damage amount:
  pre: player/health > 0
  post: player/health >= 0
  dec! player/health amount]])
  end)
end)

-- ── Pass 4: perceives enforcement ─────────────────────────────────────────────

local function check_warn(src, expected_code)
  local _, diags = compile(src)
  for _, d in ipairs(diags) do
    if d.level == "warning" and d.code == expected_code then return d end
  end
  error("expected warning " .. expected_code .. " but got: "
    .. table.concat((function()
        local t = {}
        for _, d in ipairs(diags) do t[#t+1] = d.level .. ":" .. d.code end
        return t
      end)(), ", "))
end

describe("checker: perceives enforcement (pass 4)", function()
  local ACTOR_SRC = [[
state player:
  gold: Int(0,999) = 50
  location: Int(0,10) = 0
state npcs/{npc}: Int(0,9) max: 4
actor guard:
  state:     npcs/guard
  perceives: [player/location, npcs/guard/*]
  inbox:     List(Int, 4)
  behavior:  guard-behavior
  priority:  20
]]

  it("emits PERCEIVES_VIOLATION warning when behavior reads unperceived path", function()
    local d = check_warn(ACTOR_SRC .. [[
fn guard-behavior:
  when player/gold > 100:
    set! npcs/guard/alert true
]], ast.E.PERCEIVES_VIOLATION)
    assert.is_not_nil(d)
    assert.is_true(d.message:find("player/gold") ~= nil)
  end)

  it("does not warn when behavior reads only perceived paths", function()
    local _, diags = compile(ACTOR_SRC .. [[
fn guard-behavior:
  when player/location = 5:
    set! npcs/guard/alert true
]])
    local warns = {}
    for _, d in ipairs(diags) do
      if d.code == ast.E.PERCEIVES_VIOLATION then warns[#warns+1] = d end
    end
    assert.equal(0, #warns)
  end)

  it("does not warn when actor has empty perceives list (perceives all)", function()
    local _, diags = compile([[
state player:
  gold: Int(0,999) = 50
state npcs/{npc}: Int(0,9) max: 4
actor bot:
  state:     npcs/bot
  inbox:     List(Int, 4)
  behavior:  bot-behavior
  priority:  10
fn bot-behavior:
  when player/gold > 50:
    set! npcs/bot/active true
]])
    local warns = {}
    for _, d in ipairs(diags) do
      if d.code == ast.E.PERCEIVES_VIOLATION then warns[#warns+1] = d end
    end
    assert.equal(0, #warns)
  end)

  it("does not warn when behavior reads actor's own state path", function()
    local _, diags = compile(ACTOR_SRC .. [[
fn guard-behavior:
  when npcs/guard/alert = true:
    pass
]])
    local warns = {}
    for _, d in ipairs(diags) do
      if d.code == ast.E.PERCEIVES_VIOLATION then warns[#warns+1] = d end
    end
    assert.equal(0, #warns)
  end)
end)

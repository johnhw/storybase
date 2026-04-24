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

local function check_warn(src, expected_code)
  local _, diags = compile(src)
  for _, d in ipairs(diags) do
    if d.level == "warning" and d.code == expected_code then return d end
  end
  local found = {}
  for _, d in ipairs(diags) do found[#found+1] = d.level .. ":" .. d.code end
  error("expected warning " .. expected_code .. " but got: " .. table.concat(found, ", "))
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
-- Pass 1 — Scene collection and SceneId enum
-- ============================================================

describe("checker pass 1 — scene collection and SceneId", function()
  it("collects scene names into symtab.scenes", function()
    local st = symtab("scene main:\n  Hello.\n  * Go\n    -> main")
    assert.is_not_nil(st.scenes["main"])
  end)

  it("auto-generates SceneId enum with all scene names", function()
    local st = symtab("scene main:\n  Hello.\n  * Go\n    -> main\nscene forest:\n  Trees.\n  * Back\n    -> main")
    local scene_id = st.types["SceneId"]
    assert.is_not_nil(scene_id)
    assert.are.equal(ast.K.TYPE_ENUM, scene_id.kind)
    -- values are sorted alphabetically
    assert.are.same({"forest", "main"}, scene_id.values)
  end)

  it("emits DUPLICATE_NAME for duplicate scene", function()
    check_err(
      "scene main:\n  Hello.\n  * Go\n    -> main\nscene main:\n  Dup.\n  * Go\n    -> main",
      ast.E.DUPLICATE_NAME
    )
  end)

  it("SceneId is available as a valid type reference", function()
    check_ok(
      "scene a:\n  Hello.\n  * Go\n    -> a\nstate current-scene: SceneId"
    )
  end)

  it("SceneId is empty enum when no scenes declared", function()
    local st = symtab("type S = a | b")
    local scene_id = st.types["SceneId"]
    assert.is_not_nil(scene_id)
    assert.are.same({}, scene_id.values)
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

  it("accepts SymbolOf referencing a declared family", function()
    check_ok("type Npc:\n  hp: Int(0,100)\nstate npcs/{npc}: Npc  max: 5\nstate target: SymbolOf(npcs)")
  end)

  it("emits UNDEFINED_TYPE for SymbolOf referencing unknown family", function()
    check_err("state target: SymbolOf(nonexistent)", ast.E.UNDEFINED_TYPE)
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
-- Pass 2 — Default value type-checking
-- ============================================================

describe("checker pass 2 — default value type-checking", function()
  it("accepts correct Bool default", function()
    check_ok("state active: Bool = true")
  end)

  it("rejects wrong-kind default for Bool", function()
    check_err("state active: Bool = 42", ast.E.BAD_DEFAULT)
  end)

  it("accepts Int default within bounds", function()
    check_ok("state hp: Int(0, 100) = 50")
  end)

  it("rejects Int default above maximum", function()
    check_err("state hp: Int(0, 10) = 50", ast.E.BAD_DEFAULT)
  end)

  it("rejects wrong-kind default for Int", function()
    check_err("state hp: Int(0, 100) = true", ast.E.BAD_DEFAULT)
  end)

  it("accepts valid enum default", function()
    check_ok("type S = alive | dead\nstate status: S = 'alive")
  end)

  it("rejects out-of-range enum default", function()
    check_err("type S = alive | dead\nstate status: S = 'unknown", ast.E.BAD_DEFAULT)
  end)

  it("accepts valid inline-enum default", function()
    check_ok("state mode: Enum(fast, slow) = 'fast")
  end)

  it("rejects out-of-range inline-enum default", function()
    check_err("state mode: Enum(fast, slow) = 'medium", ast.E.BAD_DEFAULT)
  end)

  it("accepts empty_set default for Set", function()
    check_ok("type T = a | b\nstate flags: Set(T, 5) = (set)")
  end)

  it("rejects non-set default for Set", function()
    check_err("type T = a | b\nstate flags: Set(T, 5) = 'a", ast.E.BAD_DEFAULT)
  end)

  it("accepts empty_list default for List", function()
    check_ok("type T = a | b\nstate items: List(T, 5) = []")
  end)

  it("rejects non-list default for List", function()
    check_err("type T = a | b\nstate items: List(T, 5) = 'a", ast.E.BAD_DEFAULT)
  end)

  it("checks defaults on record type fields", function()
    check_err("type Rec:\n  hp: Int(0, 100) = 200", ast.E.BAD_DEFAULT)
  end)

  it("checks defaults on inline-record state fields", function()
    check_err("state world:\n  hp: Int(0, 100) = 200", ast.E.BAD_DEFAULT)
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

  it("emits TYPE_MISMATCH when mixin field is overridden with different type", function()
    check_err([[
type Base:
  hp: Int(0, 100)
type Child:
  with Base
  hp: Bool
]], ast.E.TYPE_MISMATCH)
  end)

  it("emits TYPE_MISMATCH when mixin field override has different Int bounds", function()
    check_err([[
type Base:
  hp: Int(0, 100)
type Child:
  with Base
  hp: Int(0, 200)
]], ast.E.TYPE_MISMATCH)
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
-- Pass 2 — warn-untyped-symbol
-- ============================================================

describe("checker pass 2 — warn-untyped-symbol", function()
  it("emits WARN_UNTYPED_SYMBOL for bare Symbol in state scalar", function()
    local d = check_warn("state tag: Symbol", ast.E.UNTYPED_SYMBOL)
    assert.is_not_nil(d)
  end)

  it("emits WARN_UNTYPED_SYMBOL for Symbol in record field", function()
    local d = check_warn("type Rec:\n  tag: Symbol", ast.E.UNTYPED_SYMBOL)
    assert.is_not_nil(d)
  end)

  it("does not warn for SymbolOf(family)", function()
    local _, diags = compile(
      "type Npc:\n  hp: Int(0,100)\nstate npcs/{npc}: Npc  max: 5\nstate target: SymbolOf(npcs)")
    for _, d in ipairs(diags) do
      if d.code == ast.E.UNTYPED_SYMBOL then
        error("unexpected WARN_UNTYPED_SYMBOL")
      end
    end
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

-- ============================================================
-- Pass 5 — Discrete/Superficial boundary enforcement
-- ============================================================

describe("checker: superficial-in-condition (pass 5)", function()

  it("warns SUPERFICIAL_IN_COND when String path used in = comparison", function()
    local _, diags = compile([[
state player:
  name: String = "Alice"
fn check-name:
  if player/name = "Bob":
    pass
]])
    local found = nil
    for _, d in ipairs(diags) do
      if d.code == ast.E.SUPERFICIAL_IN_COND then found = d; break end
    end
    assert.is_not_nil(found, "expected SUPERFICIAL_IN_COND warning")
    assert.is_true(found.message:find("player/name") ~= nil)
  end)

  it("warns SUPERFICIAL_IN_COND when Float path used in < comparison", function()
    local _, diags = compile([[
state world:
  ratio: Float = 0.0
fn check-ratio:
  if world/ratio < 0.5:
    pass
]])
    local found = nil
    for _, d in ipairs(diags) do
      if d.code == ast.E.SUPERFICIAL_IN_COND then found = d; break end
    end
    assert.is_not_nil(found, "expected SUPERFICIAL_IN_COND warning")
  end)

  it("does NOT warn when Int path used in comparison", function()
    local _, diags = compile([[
state world:
  gold: Int(0, 9999) = 0
fn check-gold:
  if world/gold > 100:
    pass
]])
    for _, d in ipairs(diags) do
      assert.is_not_equal(ast.E.SUPERFICIAL_IN_COND, d.code)
    end
  end)

  it("does NOT warn when Bool path used in comparison", function()
    local _, diags = compile([[
state world:
  done: Bool = false
fn check-done:
  if world/done = true:
    pass
]])
    for _, d in ipairs(diags) do
      assert.is_not_equal(ast.E.SUPERFICIAL_IN_COND, d.code)
    end
  end)

  it("warns SUPERFICIAL_IN_COND for String in inline state record field", function()
    local _, diags = compile([[
state player:
  name: String = "X"
  hp: Int(0, 100) = 50
fn check-player:
  when player/name = "Hero":
    pass
]])
    local found = nil
    for _, d in ipairs(diags) do
      if d.code == ast.E.SUPERFICIAL_IN_COND then found = d; break end
    end
    assert.is_not_nil(found, "expected SUPERFICIAL_IN_COND warning for player/name")
  end)

  it("warns SUPERFICIAL_IN_COND for String field in named-type state", function()
    local _, diags = compile([[
type Hero:
  name: String = "X"
  hp: Int(0, 100) = 50
state player: Hero
fn check-player:
  when player/name = "Hero":
    pass
]])
    local found = nil
    for _, d in ipairs(diags) do
      if d.code == ast.E.SUPERFICIAL_IN_COND then found = d; break end
    end
    assert.is_not_nil(found, "expected SUPERFICIAL_IN_COND warning for player/name via named type")
  end)

end)

describe("checker: random-superficial (pass 5)", function()

  it("warns RANDOM_SUPERFICIAL when random-choice assigned to String field", function()
    local _, diags = compile([[
state player:
  name: String = "Alice"
  options: List(String, 5)
fn randomize:
  set! player/name (random-choice player/options)
]])
    local found = nil
    for _, d in ipairs(diags) do
      if d.code == ast.E.RANDOM_SUPERFICIAL then found = d; break end
    end
    assert.is_not_nil(found, "expected RANDOM_SUPERFICIAL warning")
    assert.is_true(found.message:find("player/name") ~= nil)
  end)

  it("does NOT warn when random-int assigned to Int field", function()
    local _, diags = compile([[
state world:
  seed: Int(0, 999) = 0
fn randomize:
  set! world/seed (random-int 0 999)
]])
    for _, d in ipairs(diags) do
      assert.is_not_equal(ast.E.RANDOM_SUPERFICIAL, d.code)
    end
  end)

  it("warns SUPERFICIAL_PARAM when String path passed to user-defined fn", function()
    local _, diags = compile([[
state world:
  label: String = "hello"
  count: Int(0, 10) = 0
fn use-label n:
  pass
fn caller:
  use-label world/label
]])
    local found
    for _, d in ipairs(diags) do
      if d.code == ast.E.SUPERFICIAL_PARAM then found = d; break end
    end
    assert.is_not_nil(found, "expected SUPERFICIAL_PARAM warning")
    assert.is_truthy(found.message:find("label"))
    assert.is_truthy(found.message:find("use%-label"))
  end)

  it("does not warn SUPERFICIAL_PARAM when Int path passed to user-defined fn", function()
    local _, diags = compile([[
state world:
  count: Int(0, 10) = 0
fn use-count n:
  pass
fn caller:
  use-count world/count
]])
    for _, d in ipairs(diags) do
      assert.is_not_equal(ast.E.SUPERFICIAL_PARAM, d.code)
    end
  end)

end)

-- ============================================================
-- Pass 6 — Write-set analysis
-- ============================================================

describe("checker pass 6 — write-set analysis", function()

  -- Helper: compile and return the fn_decl node with the given name
  local function get_fn(src, fn_name)
    local typed, _ = compile(src)
    for _, node in ipairs(typed.decls or {}) do
      if node.kind == ast.K.FN_DECL and node.name == fn_name then
        return node
      end
    end
    return nil
  end

  -- Helper: compile and return the scene_decl node with the given name
  local function get_scene(src, scene_name)
    local typed, _ = compile(src)
    for _, node in ipairs(typed.decls or {}) do
      if node.kind == ast.K.SCENE_DECL and node.name == scene_name then
        return node
      end
    end
    return nil
  end

  -- Helper: collect only warnings with the given code
  local function get_warnings(src, code)
    local _, diags = compile(src)
    local found = {}
    for _, d in ipairs(diags) do
      if d.level == "warning" and d.code == code then
        found[#found+1] = d
      end
    end
    return found
  end

  it("annotates fn write_set with a static set! path", function()
    local fn = get_fn([[
state world:
  gold: Int(0, 9999) = 0
fn earn:
  set! world/gold 100
]], "earn")
    assert.is_not_nil(fn)
    assert.is_not_nil(fn.write_set)
    assert.is_true(fn.write_set["world/gold"] == true)
  end)

  it("annotates fn write_set with multiple mutation paths", function()
    local fn = get_fn([[
state player:
  hp:   Int(0, 100) = 100
  gold: Int(0, 999) = 0
fn heal-and-pay:
  set! player/hp   50
  set! player/gold 10
]], "heal-and-pay")
    assert.is_not_nil(fn)
    assert.is_true(fn.write_set["player/hp"]   == true)
    assert.is_true(fn.write_set["player/gold"] == true)
  end)

  it("annotates fn write_set with inc!/dec! paths", function()
    local fn = get_fn([[
state world:
  counter: Int(0, 9999) = 0
fn tick:
  inc! world/counter 1
]], "tick")
    assert.is_not_nil(fn)
    assert.is_true(fn.write_set["world/counter"] == true)
  end)

  it("annotates fn write_set with spawn! family wildcard", function()
    local fn = get_fn([[
state npcs/{npc}: Int(0, 100)  max: 8
fn do-spawn:
  spawn! npcs 'bob 42
]], "do-spawn")
    assert.is_not_nil(fn)
    assert.is_true(fn.write_set["npcs/*"] == true)
  end)

  it("annotates fn write_set with despawn! family wildcard", function()
    local fn = get_fn([[
state npcs/{npc}: Int(0, 100)  max: 8
fn do-despawn:
  despawn! npcs 'bob
]], "do-despawn")
    assert.is_not_nil(fn)
    assert.is_true(fn.write_set["npcs/*"] == true)
  end)

  it("infers wildcard for {var} from for-in path-list loop", function()
    local SRC = [[
state npcs/{npc}: Int(0, 100)  max: 8
fn reset-all:
  for npc in (path-list npcs):
    set! npcs/{npc} 0
]]
    local fn = get_fn(SRC, "reset-all")
    assert.is_not_nil(fn)
    assert.is_true(fn.write_set["npcs/*"] == true)
    -- No WRITE_UNTYPED_VAR since var is loop-bound
    local warnings = get_warnings(SRC, ast.E.WRITE_UNTYPED_VAR)
    assert.equal(0, #warnings)
  end)

  it("emits WRITE_UNTYPED_VAR for unbound {var} in interp path", function()
    local warnings = get_warnings([[
state npcs/{npc}: Int(0, 100)  max: 8
fn bad-write key:
  set! npcs/{key} 0
]], ast.E.WRITE_UNTYPED_VAR)
    assert.is_true(#warnings >= 1)
    assert.is_true(warnings[1].message:find("key") ~= nil)
  end)

  it("annotates scene write_set from choice bodies", function()
    local sc = get_scene([[
state world:
  score: Int(0, 9999) = 0
scene main:
  * Score
    inc! world/score 1
    -> main
  * Stop
    -> end-scene
scene end-scene:
  Done.
]], "main")
    assert.is_not_nil(sc)
    assert.is_not_nil(sc.write_set)
    assert.is_true(sc.write_set["world/score"] == true)
  end)

  it("write_set is empty for a fn with no mutations", function()
    local fn = get_fn([[
state world:
  val: Int(0, 9) = 0
fn read-only:
  let x = world/val:
    pass
]], "read-only")
    assert.is_not_nil(fn)
    local count = 0
    for _ in pairs(fn.write_set or {}) do count = count + 1 end
    assert.equal(0, count)
  end)

end)

-- ============================================================
-- Recursive scene detection
-- ============================================================

describe("checker — recursive scene detection", function()
  local function get_recursive_warns(src)
    local _, diags = compile(src)
    local found = {}
    for _, d in ipairs(diags) do
      if d.level == "warning" and d.code == ast.E.RECURSIVE_SCENE then
        found[#found+1] = d
      end
    end
    return found
  end

  it("emits WARN_RECURSIVE_SCENE when scene gotos itself", function()
    local warns = get_recursive_warns([[
scene loop:
  -> loop
]])
    assert.equal(1, #warns)
    assert.is_truthy(warns[1].message:find("loop"))
  end)

  it("emits WARN_RECURSIVE_SCENE when scene enters itself", function()
    local warns = get_recursive_warns([[
scene recurse:
  => recurse
]])
    assert.equal(1, #warns)
  end)

  it("does not warn when goto targets a different scene", function()
    local warns = get_recursive_warns([[
scene a:
  -> b
scene b:
  Done.
]])
    assert.equal(0, #warns)
  end)

  it("emits warning for self-goto inside when block", function()
    local warns = get_recursive_warns([[
state hp: Int(0, 100) = 100
scene retry:
  when hp > 0:
    -> retry
]])
    assert.equal(1, #warns)
  end)

  it("does not warn for computed goto (dynamic target)", function()
    local warns = get_recursive_warns([[
state hp: Int(0, 100) = 100
scene dynamic:
  when hp > 0:
    -> other
scene other:
  Done.
]])
    assert.equal(0, #warns)
  end)
end)

-- ── Pass 3b: transaction-in-pure-context checks ───────────────────────────────

describe("checker pass 3b — transaction in pure context", function()

  it("transitively promotes fn to transaction when it calls a transaction fn", function()
    -- mutate-b calls mutate-a (transaction) → mutate-b is also classified as transaction
    local src = [[
fn mutate-a:
  inc! world/gold 1
fn mutate-b:
  mutate-a
state world:
  gold: Int(0, 9999) = 0
]]
    local tokens = require("compiler.lexer").tokenize(src, "test")
    local tree   = require("compiler.parser").parse(tokens, "test")
    local typed, _ = checker.check(tree, "test")
    local fn_b
    for _, n in ipairs(typed.decls) do
      if n.kind == "fn_decl" and n.name == "mutate-b" then fn_b = n end
    end
    assert.is_not_nil(fn_b, "fn mutate-b not found")
    assert.is_true(fn_b.is_transaction, "mutate-b should be transitively classified as transaction")
  end)

  it("does not error when a pure fn calls another pure fn", function()
    check_ok([[
fn double x:
  x * 2
fn quadruple x:
  double (double x)
]])
  end)

  it("emits TRANSACTION_IN_PURE when pre: block calls a transaction fn", function()
    check_err([[
state world:
  gold: Int(0, 9999) = 0
fn earn:
  inc! world/gold 10
fn spend amount:
  pre: (earn)
  dec! world/gold amount
]], ast.E.TRANSACTION_IN_PURE)
  end)

  it("does not error for pre: calling a pure fn", function()
    check_ok([[
state world:
  gold: Int(0, 9999) = 0
fn enough?:
  world/gold >= 10
fn spend amount:
  pre: (enough?)
  dec! world/gold amount
]])
  end)

  it("emits TRANSACTION_IN_FIND when transaction fn called in find where clause", function()
    check_err([[
family npcs:
  health: Int(0, 100) = 100
fn heal k:
  set! npcs/{k}/health 100
fn bad-find:
  find npcs where: (heal 'a)
]], ast.E.TRANSACTION_IN_FIND)
  end)

  it("does not error when pure fn called in find where clause", function()
    check_ok([[
family npcs:
  health: Int(0, 100) = 100
fn alive? k:
  npcs/{k}/health > 0
fn list-alive:
  find npcs where: (alive? 'a)
]])
  end)

  it("emits TRANSACTION_IN_VERIFY when transaction fn in verify always condition", function()
    check_err([[
state world:
  gold: Int(0, 9999) = 0
fn mutate:
  inc! world/gold 1
engine-config:
  entry-scene: main
scene main:
  * Go
    -> main
verify "bad":
  verify-always (mutate)
]], ast.E.TRANSACTION_IN_VERIFY)
  end)

  it("does not error for transaction fn in verify after: call position", function()
    check_ok([[
state world:
  gold: Int(0, 9999) = 0
fn earn:
  inc! world/gold 10
engine-config:
  entry-scene: main
scene main:
  * Go
    -> main
verify "earn ok":
  after (earn):
    world/gold > 0
]])
  end)

end)

-- ── Pass 3b: uses-bounded auto-tag ────────────────────────────────────────────

describe("checker pass 3b — uses_bounded tag", function()

  local function first_fn_with_name(src, name)
    local typed, _ = compile(src)
    if not typed then return nil end
    for _, node in ipairs(typed.decls) do
      if node.kind == "fn_decl" and node.name == name then return node end
    end
    return nil
  end

  it("tags a fn as uses_bounded when it calls a bounded computation", function()
    local fn = first_fn_with_name([[
bounded roll-die:
  returns: Int(1, 6)
  distribution: uniform
  lua: math.random(1, 6)
fn use-die:
  roll-die
]], "use-die")
    assert.is_not_nil(fn, "fn 'use-die' not found")
    assert.is_true(fn.uses_bounded == true, "expected uses_bounded=true")
  end)

  it("does not tag a fn that does not call any bounded computation", function()
    local fn = first_fn_with_name([[
bounded roll-die:
  returns: Int(1, 6)
  distribution: uniform
  lua: math.random(1, 6)
fn pure-fn:
  42
]], "pure-fn")
    assert.is_not_nil(fn, "fn 'pure-fn' not found")
    assert.is_falsy(fn.uses_bounded, "expected uses_bounded to be falsy")
  end)

end)

-- ── Pass 7: Contract Validation ───────────────────────────────────────────────

describe("checker pass 7 — contract validation", function()

  local function get_warns(src)
    local _, diags = compile(src)
    local warns = {}
    for _, d in ipairs(diags) do
      if d.level == "warning" then warns[#warns+1] = d end
    end
    return warns
  end

  -- PRE_NOT_BOOL

  it("warns PRE_NOT_BOOL when pre: is an integer literal", function()
    local _, diags = compile([[
fn bad:
  pre: 42
  pass
]])
    local found
    for _, d in ipairs(diags) do
      if d.code == ast.E.PRE_NOT_BOOL then found = d; break end
    end
    assert.is_not_nil(found, "expected PRE_NOT_BOOL warning")
  end)

  it("warns PRE_NOT_BOOL when pre: is a string literal", function()
    local _, diags = compile([[
fn bad:
  pre: "hello"
  pass
]])
    local found
    for _, d in ipairs(diags) do
      if d.code == ast.E.PRE_NOT_BOOL then found = d; break end
    end
    assert.is_not_nil(found, "expected PRE_NOT_BOOL warning")
  end)

  it("does not warn PRE_NOT_BOOL for a comparison expression", function()
    check_ok([[
state world:
  gold: Int(0, 9999) = 0
fn spend:
  pre: world/gold > 0
  dec! world/gold 1
]])
  end)

  it("does not warn PRE_NOT_BOOL for a Bool path", function()
    check_ok([[
state player:
  alive: Bool = true
fn act:
  pre: player/alive
  pass
]])
  end)

  -- POST_NOT_BOOL

  it("warns POST_NOT_BOOL when post: is a symbol literal", function()
    local _, diags = compile([[
fn bad:
  post: 'foo
  pass
]])
    local found
    for _, d in ipairs(diags) do
      if d.code == ast.E.POST_NOT_BOOL then found = d; break end
    end
    assert.is_not_nil(found, "expected POST_NOT_BOOL warning")
  end)

  it("does not warn POST_NOT_BOOL for a comparison with path@before", function()
    check_ok([[
state world:
  gold: Int(0, 9999) = 100
fn earn amount:
  post: world/gold >= world/gold@before
  inc! world/gold amount
]])
  end)

  -- PATH_BEFORE_INVALID

  it("emits PATH_BEFORE_INVALID when path@before used in pre: block", function()
    check_err([[
state world:
  gold: Int(0, 9999) = 100
fn spend amount:
  pre: world/gold >= world/gold@before
  dec! world/gold amount
]], ast.E.PATH_BEFORE_INVALID)
  end)

  it("emits PATH_BEFORE_INVALID when path@before used in fn body", function()
    check_err([[
state world:
  gold: Int(0, 9999) = 100
fn show:
  world/gold@before
]], ast.E.PATH_BEFORE_INVALID)
  end)

  it("does not error when path@before used in fn post: block", function()
    check_ok([[
state world:
  gold: Int(0, 9999) = 100
fn earn amount:
  post: world/gold > world/gold@before
  inc! world/gold amount
]])
  end)

  it("emits PATH_BEFORE_INVALID when path@before used in verify always clause", function()
    check_err([[
state world:
  gold: Int(0, 9999) = 100
engine-config:
  entry-scene: main
scene main:
  * Go
    -> main
verify "bad":
  verify-always world/gold@before >= 0
]], ast.E.PATH_BEFORE_INVALID)
  end)

  it("does not error when path@before used in verify after assertion body", function()
    check_ok([[
state world:
  gold: Int(0, 9999) = 100
fn earn:
  inc! world/gold 10
engine-config:
  entry-scene: main
scene main:
  * Go
    -> main
verify "earn ok":
  after (earn):
    world/gold > world/gold@before
]])
  end)

end)

-- ── Pass 3b: lambda purity ────────────────────────────────────────────────────

describe("checker pass 3b — lambda purity (LAMBDA_CALLS_MUT)", function()
  local BASE = [[
state world:
  count: Int(0, 100) = 0
engine-config:
  entry-scene: main
scene main:
  * Go
    -> main
]]

  it("pure lambda (single expression) compiles without error", function()
    check_ok(BASE .. [[
fn run:
  let f = fn(x): x > 0:
    pass
]])
  end)

  it("pure lambda (multi-line body) compiles without error", function()
    check_ok(BASE .. [[
fn run:
  let f = fn(x):
    x > 0:
    pass
]])
  end)

  it("emits LAMBDA_CALLS_MUT when lambda body contains set!", function()
    check_err(BASE .. [[
fn run:
  let f = fn(x): set! world/count 1:
    pass
]], ast.E.LAMBDA_CALLS_MUT)
  end)

  it("emits LAMBDA_CALLS_MUT when lambda body contains inc!", function()
    check_err(BASE .. [[
fn run:
  let f = fn(x): inc! world/count 1:
    pass
]], ast.E.LAMBDA_CALLS_MUT)
  end)

  it("lambda passed as argument with mutation is also caught", function()
    check_err(BASE .. [[
fn run:
  let items = [1, 2, 3]:
    let f = fn(x): set! world/count 1:
      pass
]], ast.E.LAMBDA_CALLS_MUT)
  end)
end)

-- ============================================================
-- SUPERFICIAL_IN_COND warning
-- ============================================================

describe("checker — SUPERFICIAL_IN_COND warning", function()
  local BASE = [[
module sc-test
  version: 1.0
engine-config:
  entry-scene: main
scene main:
  * Go -> main
]]

  it("String path in if condition emits SUPERFICIAL_IN_COND", function()
    check_warn(BASE .. [[
state world:
  label: String = "hello"
fn test:
  if world/label = "hello":
    pass
]], ast.E.SUPERFICIAL_IN_COND)
  end)

  it("Float path in comparison emits SUPERFICIAL_IN_COND", function()
    check_warn(BASE .. [[
state world:
  ratio: Float = 0.5
fn test:
  if world/ratio > 0.3:
    pass
]], ast.E.SUPERFICIAL_IN_COND)
  end)

  it("discrete Bool path in condition does NOT emit SUPERFICIAL_IN_COND", function()
    check_ok(BASE .. [[
state world:
  flag: Bool = false
fn test:
  if world/flag:
    pass
]])
  end)
end)

-- ============================================================
-- WRITE_UNTYPED_VAR warning
-- ============================================================

describe("checker — WRITE_UNTYPED_VAR warning", function()
  local BASE = [[
module wuv-test
  version: 1.0
engine-config:
  entry-scene: main
scene main:
  * Go -> main
]]

  it("untyped interpolated variable in write path emits WRITE_UNTYPED_VAR", function()
    check_warn(BASE .. [[
state world:
  x: Int(0, 99) = 0
fn writer somevar:
  set! world/{somevar} 5
]], ast.E.WRITE_UNTYPED_VAR)
  end)

  it("loop var from path-list does NOT emit WRITE_UNTYPED_VAR (SymbolOf inferred)", function()
    check_ok(BASE .. [[
state npcs/{npc}: Bool  max: 5
fn clear-all:
  for npc in (path-list npcs):
    set! npcs/{npc} false
]])
  end)
end)

-- ── speaker / say ─────────────────────────────────────────────────────────────
describe("speaker declarations", function()
  local BASE = [[
engine-config:
  entry-scene: s
scene s:
  * Done -> s
]]

  local function check_hint(src, code)
    local _, diags = compile(src)
    for _, d in ipairs(diags) do
      if d.level == "hint" and d.code == code then return d end
    end
    local found = {}
    for _, d in ipairs(diags) do table.insert(found, d.level .. ":" .. d.code) end
    error("expected hint " .. code .. " but got: " .. table.concat(found, ", "))
  end

  it("declared speaker passes with no diagnostic", function()
    check_ok([[
speaker aldric:
  display: "Aldric"
  color: "#c8a96e"
engine-config:
  entry-scene: s
scene s:
  say aldric: Hello.
  * Done -> s
]])
  end)

  it("duplicate speaker declaration emits DUPLICATE_NAME error", function()
    check_err([[
speaker aldric:
  display: "Aldric"
speaker aldric:
  display: "Aldric 2"
engine-config:
  entry-scene: s
scene s:
  * Done -> s
]], "DUPLICATE_NAME")
  end)

  it("undeclared static speaker name emits UNDECLARED_SPEAKER hint", function()
    local d = check_hint([[
engine-config:
  entry-scene: s
scene s:
  say ghost: Boo!
  * Done -> s
]], "UNDECLARED_SPEAKER")
    assert.truthy(d.message:find("ghost"))
  end)

  it("dynamic speaker expression emits no diagnostic", function()
    check_ok([[
state current-speaker: String
engine-config:
  entry-scene: s
scene s:
  say (current-speaker): Hello.
  * Done -> s
]])
  end)

  it("speaker decl is registered in symtab.speakers", function()
    local st = symtab([[
speaker mira:
  display: "Mira"
  color: "#7ab8c2"
engine-config:
  entry-scene: s
scene s:
  * Done -> s
]])
    assert.truthy(st.speakers["mira"])
    assert.equal("mira", st.speakers["mira"].name)
  end)

  it("say in fn body marks fn as transaction (impure)", function()
    local typed = compile([[
speaker aldric:
  display: "Aldric"
engine-config:
  entry-scene: s
fn speak:
  say 'aldric "Hello."
scene s:
  * Done -> s
]])
    local fn_decl
    for _, d in ipairs(typed.decls) do
      if d.kind == "fn_decl" and d.name == "speak" then fn_decl = d; break end
    end
    assert.truthy(fn_decl)
    assert.is_true(fn_decl.is_transaction)
  end)
end)

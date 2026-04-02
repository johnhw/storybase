-- tests/compiler/parser_spec.lua
-- Tests for compiler/parser.lua

local lexer  = require("compiler.lexer")
local parser = require("compiler.parser")
local ast    = require("compiler.ast")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function parse(src)
  local tokens, lex_diags = lexer.tokenize(src, "test")
  local tree,   parse_diags = parser.parse(tokens, "test")
  local diags = {}
  for _, d in ipairs(lex_diags)   do table.insert(diags, d) end
  for _, d in ipairs(parse_diags) do table.insert(diags, d) end
  return tree, diags
end

local function decl(src)
  local tree = parse(src)
  return tree.decls[1]
end

local function no_errors(src)
  local _, diags = parse(src)
  for _, d in ipairs(diags) do
    if d.level == "error" then return false end
  end
  return true
end

local function error_codes(src)
  local _, diags = parse(src)
  local codes = {}
  for _, d in ipairs(diags) do
    if d.level == "error" then table.insert(codes, d.code) end
  end
  return codes
end

-- ── Module declarations ───────────────────────────────────────────────────────

describe("parser — module declarations", function()
  it("parses a bare module declaration", function()
    local d = decl("module combat")
    assert.are.equal(ast.K.MODULE_DECL, d.kind)
    assert.are.equal("combat", d.name)
    assert.is_nil(d.version)
  end)

  it("parses a module with version", function()
    local d = decl("module combat\n  version: 3")
    assert.are.equal(ast.K.MODULE_DECL, d.kind)
    assert.are.equal("combat", d.name)
    assert.are.equal(3, d.version)
  end)

  it("records source position", function()
    local d = decl("module foo")
    assert.are.equal(1, d.pos.line)
    assert.are.equal(1, d.pos.col)
  end)
end)

-- ── Import declarations ───────────────────────────────────────────────────────

describe("parser — import declarations", function()
  it("parses a flat import", function()
    local d = decl('import "combat.sb"')
    assert.are.equal(ast.K.IMPORT_DECL, d.kind)
    assert.are.equal("combat.sb", d.path)
    assert.is_nil(d.alias)
  end)

  it("parses a namespaced import", function()
    local d = decl('import "enemies.sb" as E')
    assert.are.equal(ast.K.IMPORT_DECL, d.kind)
    assert.are.equal("enemies.sb", d.path)
    assert.are.equal("E", d.alias)
  end)
end)

-- ── schema-version ────────────────────────────────────────────────────────────

describe("parser — schema-version", function()
  it("parses schema-version", function()
    local d = decl("schema-version: 3")
    assert.are.equal(ast.K.SCHEMA_VERSION, d.kind)
    assert.are.equal(3, d.version)
  end)
end)

-- ── engine-config ─────────────────────────────────────────────────────────────

describe("parser — engine-config", function()
  it("parses engine-config block", function()
    local d = decl("engine-config:\n  entry-scene: main\n  scene-stack-max: 16")
    assert.are.equal(ast.K.ENGINE_CONFIG, d.kind)
    assert.are.equal(2, #d.keys)
    assert.are.equal("entry-scene",    d.keys[1].key)
    assert.are.equal("main",           d.keys[1].value)
    assert.are.equal("scene-stack-max", d.keys[2].key)
    assert.are.equal(16,               d.keys[2].value)
  end)

  it("parses boolean config values", function()
    local d = decl("engine-config:\n  strict-contracts: false")
    assert.are.equal(false, d.keys[1].value)
  end)
end)

-- ── time-model ────────────────────────────────────────────────────────────────

describe("parser — time-model", function()
  it("parses axes and wrap", function()
    local d = decl("time-model:\n  axes: [day, hour, minute]\n  wrap: [none, 24, 60]")
    assert.are.equal(ast.K.TIME_MODEL, d.kind)
    assert.are.same({"day", "hour", "minute"}, d.axes)
    assert.are.same({"none", 24, 60}, d.wrap)
  end)
end)

-- ── Type expressions ──────────────────────────────────────────────────────────

describe("parser — type expressions", function()
  it("parses Bool", function()
    local d = decl("type HasKey = Bool")
    assert.are.equal(ast.K.TYPE_BOOL, d.type_expr.kind)
  end)

  it("parses Int(min, max)", function()
    local d = decl("type Health = Int(0, 100)")
    assert.are.equal(ast.K.TYPE_INT, d.type_expr.kind)
    assert.are.equal(0,   d.type_expr.min)
    assert.are.equal(100, d.type_expr.max)
  end)

  it("parses Enum(v1, v2)", function()
    local d = decl("type Dir = Enum(north, south, east)")
    assert.are.equal(ast.K.TYPE_ALIAS, d.kind)
    assert.are.equal(ast.K.TYPE_ENUM_INLINE, d.type_expr.kind)
    assert.are.same({"north", "south", "east"}, d.type_expr.values)
  end)

  it("parses Option(T)", function()
    local d = decl("type MaybeHealth = Option(Int(0, 100))")
    assert.are.equal(ast.K.TYPE_OPTION, d.type_expr.kind)
    assert.are.equal(ast.K.TYPE_INT, d.type_expr.inner.kind)
  end)

  it("parses Set(T, max)", function()
    local d = decl("type ItemSet = Set(ItemKind, 10)")
    assert.are.equal(ast.K.TYPE_SET, d.type_expr.kind)
    assert.are.equal(10, d.type_expr.max)
    assert.are.equal("ItemKind", d.type_expr.inner.name)
  end)

  it("parses List(T, max)", function()
    local d = decl("type ItemList = List(ItemKind, 5)")
    assert.are.equal(ast.K.TYPE_LIST, d.type_expr.kind)
    assert.are.equal(5, d.type_expr.max)
  end)

  it("parses Symbol", function()
    local d = decl("type Tag = Symbol")
    assert.are.equal(ast.K.TYPE_SYMBOL, d.type_expr.kind)
  end)

  it("parses SymbolOf(Family)", function()
    local d = decl("type NpcId = SymbolOf(npcs)")
    assert.are.equal(ast.K.TYPE_SYMBOL_OF, d.type_expr.kind)
    assert.are.equal("npcs", d.type_expr.family)
  end)

  it("parses String", function()
    local d = decl("type Label = String")
    assert.are.equal(ast.K.TYPE_STRING, d.type_expr.kind)
  end)

  it("parses Float", function()
    local d = decl("type Volume = Float")
    assert.are.equal(ast.K.TYPE_FLOAT, d.type_expr.kind)
  end)

  it("parses UList(T)", function()
    local d = decl("type Log = UList(String)")
    assert.are.equal(ast.K.TYPE_ULIST, d.type_expr.kind)
  end)

  it("parses UMap(K, V)", function()
    local d = decl("type Registry = UMap(String, Int(0, 9999))")
    assert.are.equal(ast.K.TYPE_UMAP, d.type_expr.kind)
  end)

  it("parses named type reference", function()
    local d = decl("type MyAlias = SomeRecord")
    assert.are.equal(ast.K.TYPE_NAMED, d.type_expr.kind)
    assert.are.equal("SomeRecord", d.type_expr.name)
  end)

  it("parses function type", function()
    local d = decl("type Pred = (Int(0,100) -> Bool)")
    assert.are.equal(ast.K.TYPE_FN, d.type_expr.kind)
    assert.are.equal(1, #d.type_expr.param_types)
    assert.are.equal(ast.K.TYPE_INT,  d.type_expr.param_types[1].kind)
    assert.are.equal(ast.K.TYPE_BOOL, d.type_expr.return_type.kind)
  end)
end)

-- ── Type enum ─────────────────────────────────────────────────────────────────

describe("parser — type enum declarations", function()
  it("parses a basic enum", function()
    local d = decl("type Status = alive | dead | unconscious")
    assert.are.equal(ast.K.TYPE_ENUM, d.kind)
    assert.are.equal("Status", d.name)
    assert.are.same({"alive", "dead", "unconscious"}, d.values)
  end)

  it("parses a two-value enum", function()
    local d = decl("type Coin = heads | tails")
    assert.are.equal(ast.K.TYPE_ENUM, d.kind)
    assert.are.equal(2, #d.values)
  end)

  it("attaches doc string to enum", function()
    local d = decl('"Player status."\ntype Status = alive | dead')
    assert.are.equal(ast.K.TYPE_ENUM, d.kind)
    assert.are.equal("Player status.", d.doc)
  end)

  it("records source position", function()
    local d = decl("type Status = alive | dead")
    assert.are.equal(1, d.pos.line)
  end)
end)

-- ── Type alias ────────────────────────────────────────────────────────────────

describe("parser — type alias declarations", function()
  it("parses Int alias", function()
    local d = decl("type Health = Int(0, 100)")
    assert.are.equal(ast.K.TYPE_ALIAS, d.kind)
    assert.are.equal("Health", d.name)
    assert.are.equal(ast.K.TYPE_INT, d.type_expr.kind)
    assert.are.equal(0,   d.type_expr.min)
    assert.are.equal(100, d.type_expr.max)
  end)

  it("parses named type alias", function()
    local d = decl("type MyHealth = Health")
    assert.are.equal(ast.K.TYPE_ALIAS, d.kind)
    assert.are.equal(ast.K.TYPE_NAMED, d.type_expr.kind)
    assert.are.equal("Health", d.type_expr.name)
  end)
end)

-- ── Type record ───────────────────────────────────────────────────────────────

describe("parser — type record declarations", function()
  it("parses a simple record", function()
    local d = decl("type Entity:\n  health: Health = 50\n  status: Status = 'alive")
    assert.are.equal(ast.K.TYPE_RECORD, d.kind)
    assert.are.equal("Entity", d.name)
    assert.are.equal(2, #d.fields)
    assert.are.equal(ast.K.RECORD_FIELD, d.fields[1].kind)
    assert.are.equal("health", d.fields[1].name)
    assert.are.equal(ast.K.TYPE_NAMED, d.fields[1].type_expr.kind)
    assert.are.equal("Health", d.fields[1].type_expr.name)
    assert.are.equal(ast.K.INT_LIT, d.fields[1].default.kind)
    assert.are.equal(50, d.fields[1].default.value)
    assert.are.equal(ast.K.SYMBOL_LIT, d.fields[2].default.kind)
    assert.are.equal("alive", d.fields[2].default.name)
  end)

  it("parses a record field with no default", function()
    local d = decl("type Entity:\n  health: Health")
    assert.are.equal(1, #d.fields)
    assert.is_nil(d.fields[1].default)
  end)

  it("parses record with mixin", function()
    local src = "type Npc:\n  with Entity\n  disposition: Disposition = 'neutral"
    local d = decl(src)
    assert.are.equal(ast.K.TYPE_RECORD, d.kind)
    assert.are.equal(2, #d.fields)
    assert.are.equal(ast.K.WITH_MIXIN, d.fields[1].kind)
    assert.are.equal("Entity", d.fields[1].type_name)
    assert.are.equal(ast.K.RECORD_FIELD, d.fields[2].kind)
  end)

  it("attaches doc string to record", function()
    local d = decl('"An NPC."\ntype Npc:\n  hp: Int(0, 100)')
    assert.are.equal("An NPC.", d.doc)
  end)
end)

-- ── Type variant ──────────────────────────────────────────────────────────────

describe("parser — type variant declarations", function()
  it("parses a variant with branches", function()
    local src = "type Msg:\n  | alert: threat: NpcId\n  | trade-offer: item: ItemKind"
    local d = decl(src)
    assert.are.equal(ast.K.TYPE_VARIANT, d.kind)
    assert.are.equal("Msg", d.name)
    assert.are.equal(2, #d.branches)
    assert.are.equal(ast.K.VARIANT_BRANCH, d.branches[1].kind)
    assert.are.equal("alert", d.branches[1].name)
    assert.are.equal(1, #d.branches[1].fields)
    assert.are.equal("threat", d.branches[1].fields[1].name)
    assert.are.equal("trade-offer", d.branches[2].name)
  end)

  it("parses a variant branch with no fields", function()
    local d = decl("type Signal:\n  | ping:\n  | pong:")
    assert.are.equal(ast.K.TYPE_VARIANT, d.kind)
    assert.are.equal(2, #d.branches)
    assert.are.equal(0, #d.branches[1].fields)
  end)
end)

-- ── State scalar ──────────────────────────────────────────────────────────────

describe("parser — state scalar declarations", function()
  it("parses a simple state scalar", function()
    local d = decl("state player: Player")
    assert.are.equal(ast.K.STATE_SCALAR, d.kind)
    assert.are.equal(ast.K.PATH_EXPR, d.path.kind)
    assert.are.same({"player"}, d.path.segments)
    assert.are.equal(ast.K.TYPE_NAMED, d.type_expr.kind)
    assert.are.equal("Player", d.type_expr.name)
    assert.is_nil(d.default)
  end)

  it("parses a state scalar with a record constructor default", function()
    local d = decl('state player: Player = Player(name: "Hero")')
    assert.are.equal(ast.K.STATE_SCALAR, d.kind)
    assert.are.equal(ast.K.RECORD_CONSTRUCTOR, d.default.kind)
    assert.are.equal("Player", d.default.type_name)
    assert.are.equal(1, #d.default.fields)
    assert.are.equal("name", d.default.fields[1].name)
  end)

  it("parses a state scalar with integer default", function()
    local d = decl("state score: Int(0, 9999) = 0")
    assert.are.equal(ast.K.INT_LIT, d.default.kind)
    assert.are.equal(0, d.default.value)
  end)

  it("parses a state scalar with bool default", function()
    local d = decl("state active: Bool = false")
    assert.are.equal(ast.K.BOOL_LIT, d.default.kind)
    assert.are.equal(false, d.default.value)
  end)

  it("parses a state scalar with path (player/health)", function()
    local d = decl("state player/health: Int(0, 100)")
    assert.are.equal(ast.K.STATE_SCALAR, d.kind)
    assert.are.same({"player", "health"}, d.path.segments)
  end)

  it("parses a state scalar with empty-set default", function()
    local d = decl("state flags: Set(QuestFlag, 20) = (set)")
    assert.are.equal(ast.K.EMPTY_SET, d.default.kind)
  end)

  it("attaches doc string", function()
    local d = decl('"Player state."\nstate player: Player')
    assert.are.equal("Player state.", d.doc)
  end)
end)

-- ── State inline record ───────────────────────────────────────────────────────

describe("parser — state inline record declarations", function()
  it("parses an inline record state", function()
    local src = "state world:\n  turn: Int(0, 9999) = 0\n  chapter: Chapter = 'intro"
    local d = decl(src)
    assert.are.equal(ast.K.STATE_RECORD, d.kind)
    assert.are.same({"world"}, d.path.segments)
    assert.are.equal(2, #d.fields)
    assert.are.equal("turn",    d.fields[1].name)
    assert.are.equal("chapter", d.fields[2].name)
    assert.are.equal(ast.K.INT_LIT,    d.fields[1].default.kind)
    assert.are.equal(ast.K.SYMBOL_LIT, d.fields[2].default.kind)
  end)
end)

-- ── State family ──────────────────────────────────────────────────────────────

describe("parser — state family declarations", function()
  it("parses a state family", function()
    local d = decl("state npcs/{npc}: Npc  max: 20")
    assert.are.equal(ast.K.STATE_FAMILY, d.kind)
    assert.are.equal("npcs", d.family)
    assert.are.equal("npc",  d.var)
    assert.are.equal(ast.K.TYPE_NAMED, d.type_expr.kind)
    assert.are.equal("Npc",  d.type_expr.name)
    assert.are.equal(20,     d.max)
  end)

  it("parses a family with deeper path", function()
    local d = decl("state zones/{zone}: Zone  max: 10")
    assert.are.equal(ast.K.STATE_FAMILY, d.kind)
    assert.are.equal("zones", d.family)
    assert.are.equal("zone",  d.var)
    assert.are.equal(10, d.max)
  end)
end)

-- ── Relation declarations ─────────────────────────────────────────────────────

describe("parser — relation declarations", function()
  it("parses a basic relation", function()
    local d = decl("relation exits: Location -> Set(Location, 6)")
    assert.are.equal(ast.K.RELATION_DECL, d.kind)
    assert.are.equal("exits", d.name)
    assert.are.equal("Location", d.from_type)
    assert.are.equal(ast.K.TYPE_SET, d.to_type_expr.kind)
    assert.are.equal(0, #d.initial_data)
  end)

  it("parses a relation with static data block", function()
    local src = "relation exits: Location -> Set(Location, 6):\n  'village: {'forest}\n  'forest: {'village}"
    local d = decl(src)
    assert.are.equal(ast.K.RELATION_DECL, d.kind)
    assert.are.equal(2, #d.initial_data)
    assert.are.equal(ast.K.SYMBOL_LIT, d.initial_data[1].key.kind)
    assert.are.equal("village", d.initial_data[1].key.name)
  end)

  it("attaches doc string", function()
    local d = decl('"Exits.\"\nrelation exits: Location -> Set(Location, 6)')
    assert.are.equal("Exits.", d.doc)
  end)
end)

-- ── Multiple declarations ─────────────────────────────────────────────────────

describe("parser — multiple declarations", function()
  it("parses multiple top-level declarations", function()
    local src = "type Status = alive | dead\ntype Health = Int(0, 100)\nstate player: Player"
    local tree = parse(src)
    assert.are.equal(3, #tree.decls)
    assert.are.equal(ast.K.TYPE_ENUM,    tree.decls[1].kind)
    assert.are.equal(ast.K.TYPE_ALIAS,   tree.decls[2].kind)
    assert.are.equal(ast.K.STATE_SCALAR, tree.decls[3].kind)
  end)

  it("returns a PROGRAM node", function()
    local tree = parse("type Status = alive | dead")
    assert.are.equal(ast.K.PROGRAM, tree.kind)
    assert.is_not_nil(tree.decls)
  end)

  it("returns empty program for empty source", function()
    local tree = parse("")
    assert.are.equal(ast.K.PROGRAM, tree.kind)
    assert.are.equal(0, #tree.decls)
  end)
end)

-- ── Default values ────────────────────────────────────────────────────────────

describe("parser — default values", function()
  it("parses empty list default", function()
    local d = decl("state waypoints: List(Location, 10) = []")
    assert.are.equal(ast.K.EMPTY_LIST, d.default.kind)
  end)

  it("parses symbol default", function()
    local d = decl("state mood: Disposition = 'neutral")
    assert.are.equal(ast.K.SYMBOL_LIT, d.default.kind)
    assert.are.equal("neutral", d.default.name)
  end)

  it("parses string default", function()
    local d = decl('state name: String = "Unknown"')
    assert.are.equal(ast.K.STRING_LIT, d.default.kind)
    assert.are.equal("Unknown", d.default.value)
  end)
end)

-- ── Error recovery ────────────────────────────────────────────────────────────

describe("parser — error recovery", function()
  it("continues after bad top-level token", function()
    local src = "!!! bad\ntype Status = alive | dead"
    local tree, diags = parse(src)
    -- Should still parse the type decl
    assert.are.equal(ast.K.TYPE_ENUM, tree.decls[#tree.decls].kind)
    assert.is_true(#diags > 0)
  end)

  it("emits UNEXPECTED_TOKEN for garbage at top level", function()
    local codes = error_codes("42\ntype Status = alive | dead")
    assert.is_true(#codes > 0)
  end)

  it("continues after bad type declaration", function()
    local src = "type\ntype Status = alive | dead"
    local tree, diags = parse(src)
    -- The second type decl should parse
    local found = false
    for _, d in ipairs(tree.decls) do
      if d.kind == ast.K.TYPE_ENUM then found = true end
    end
    assert.is_true(found)
    assert.is_true(#diags > 0)
  end)

  it("returns no errors for valid schema-only source", function()
    local src = [[
schema-version: 1
type Status = alive | dead
type Health = Int(0, 100)
state player: Player
]]
    assert.is_true(no_errors(src))
  end)
end)

-- ── Integration: a realistic schema snippet ───────────────────────────────────

describe("parser — integration", function()
  it("parses a complete schema-only snippet without errors", function()
    local src = [[
module game

schema-version: 1

engine-config:
  entry-scene: village
  scene-stack-max: 16

time-model:
  axes: [day, hour, tick]
  wrap: [none, 24, none]

type Status = alive | dead | unconscious
type Location = village | forest | dungeon
type Health = Int(0, 100)
type Gold = Int(0, 9999)

"The player record type."
type Player:
  health: Health = 100
  status: Status = 'alive
  gold:   Gold   = 30

"The player's state."
state player: Player = Player(health: 100)

state world:
  turn: Int(0, 9999) = 0
  chapter: Location  = 'village

"NPCs."
state npcs/{npc}: Player  max: 20

"Movement graph."
relation exits: Location -> Set(Location, 6):
  'village: {'forest}
  'forest: {'village, 'dungeon}
]]
    local tree, diags = parse(src)
    -- Count errors only (not warnings)
    local errs = 0
    for _, d in ipairs(diags) do
      if d.level == "error" then errs = errs + 1 end
    end
    assert.are.equal(0, errs)
    assert.is_true(#tree.decls >= 10)
  end)
end)

-- ============================================================
-- Phase 2 — Expressions, Statements, Functions, Scenes
-- ============================================================

-- Helper: parse a fn declaration body from indented source lines.
-- src should be the indented body (e.g. "  set!  player/x 1")
local function parse_fn(name_and_params, body_src)
  local indent = body_src:gsub("([^\n]+)", "  %1")
  local src = "fn " .. name_and_params .. ":\n" .. indent
  local tree, diags = parse(src)
  return tree.decls[1], diags
end

-- Helper: return the body stmts of the first fn_decl
local function fn_body(src)
  local fd, diags = parse_fn("test", src)
  return fd and fd.body or {}, diags
end

-- Helper: return first stmt
local function first_stmt(src)
  local stmts, diags = fn_body(src)
  return stmts[1], diags
end

-- Helper: parse a scene declaration
local function parse_scene(name_and_body)
  local tree, diags = parse("scene " .. name_and_body)
  return tree.decls[1], diags
end

-- ── Literal expressions ───────────────────────────────────────────────────────

describe("parser — literal expressions", function()
  it("parses integer literal in expression position", function()
    local s, _ = first_stmt("42")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.INT_LIT, s.expr.kind)
    assert.are.equal(42, s.expr.value)
  end)

  it("parses binary subtraction resulting in negative-like expression", function()
    -- The lexer does not produce negative integer literals; -7 is two tokens.
    -- Unary minus is written as 0 - 7 or via binary subtraction.
    local s, _ = first_stmt("0 - 7")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.BINARY_OP, s.expr.kind)
    assert.are.equal("-", s.expr.op)
    assert.are.equal(0, s.expr.left.value)
    assert.are.equal(7, s.expr.right.value)
  end)

  it("parses float literal", function()
    local s, _ = first_stmt("3.14")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.FLOAT_LIT, s.expr.kind)
  end)

  it("parses bool true literal", function()
    local s, _ = first_stmt("true")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.BOOL_LIT, s.expr.kind)
    assert.are.equal(true, s.expr.value)
  end)

  it("parses bool false literal", function()
    local s, _ = first_stmt("false")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.BOOL_LIT, s.expr.kind)
    assert.are.equal(false, s.expr.value)
  end)

  it("parses string literal", function()
    local s, _ = first_stmt('"hello"')
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.STRING_LIT, s.expr.kind)
    assert.are.equal("hello", s.expr.value)
  end)

  it("parses symbol literal", function()
    local s, _ = first_stmt("'alive")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.SYMBOL_LIT, s.expr.kind)
    assert.are.equal("alive", s.expr.name)
  end)
end)

-- ── Path expressions ──────────────────────────────────────────────────────────

describe("parser — path expressions", function()
  it("parses a two-segment state path", function()
    local s, _ = first_stmt("player/health")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.PATH_EXPR, s.expr.kind)
    assert.are.equal(2, #s.expr.segments)
    assert.are.equal("player", s.expr.segments[1])
    assert.are.equal("health", s.expr.segments[2])
  end)

  it("parses an interpolated path", function()
    local s, _ = first_stmt("npcs/{npc}/hp")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.INTERP_PATH, s.expr.kind)
    assert.are.equal(3, #s.expr.segments)
    assert.are.equal("npcs", s.expr.segments[1])
    assert.are.equal("npc", s.expr.segments[2].interp)
    assert.are.equal("hp", s.expr.segments[3])
  end)
end)

-- ── Binary operator expressions ───────────────────────────────────────────────

describe("parser — binary operators", function()
  it("parses addition", function()
    local s, _ = first_stmt("1 + 2")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    local e = s.expr
    assert.are.equal(ast.K.BINARY_OP, e.kind)
    assert.are.equal("+", e.op)
    assert.are.equal(1, e.left.value)
    assert.are.equal(2, e.right.value)
  end)

  it("parses subtraction", function()
    local s, _ = first_stmt("10 - 3")
    assert.are.equal(ast.K.BINARY_OP, s.expr.kind)
    assert.are.equal("-", s.expr.op)
  end)

  it("parses multiplication with higher precedence than addition", function()
    local s, _ = first_stmt("1 + 2 * 3")
    local e = s.expr
    -- Should be: 1 + (2 * 3)
    assert.are.equal("+", e.op)
    assert.are.equal(1, e.left.value)
    assert.are.equal("*", e.right.op)
    assert.are.equal(2, e.right.left.value)
    assert.are.equal(3, e.right.right.value)
  end)

  it("parses equality comparison", function()
    local s, _ = first_stmt("player/health = 100")
    local e = s.expr
    assert.are.equal(ast.K.BINARY_OP, e.kind)
    assert.are.equal("=", e.op)
    assert.are.equal(ast.K.PATH_EXPR, e.left.kind)
  end)

  it("parses not-equal comparison", function()
    local s, _ = first_stmt("x != 0")
    assert.are.equal("!=", s.expr.op)
  end)

  it("parses less-than", function()
    local s, _ = first_stmt("a < b")
    assert.are.equal("<", s.expr.op)
  end)

  it("parses greater-than-or-equal", function()
    local s, _ = first_stmt("gold >= 10")
    assert.are.equal(">=", s.expr.op)
  end)

  it("parses boolean 'and'", function()
    local s, _ = first_stmt("a and b")
    assert.are.equal(ast.K.BINARY_OP, s.expr.kind)
    assert.are.equal("and", s.expr.op)
  end)

  it("parses boolean 'or'", function()
    local s, _ = first_stmt("a or b")
    assert.are.equal("or", s.expr.op)
  end)

  it("parses 'not' prefix operator", function()
    local s, _ = first_stmt("not player/alive")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.UNARY_OP, s.expr.kind)
    assert.are.equal("not", s.expr.op)
  end)

  it("'not' binds tighter than 'and'", function()
    local s, _ = first_stmt("a and not b")
    -- Should be: a and (not b)
    local e = s.expr
    assert.are.equal("and", e.op)
    assert.are.equal(ast.K.UNARY_OP, e.right.kind)
    assert.are.equal("not", e.right.op)
  end)

  it("parses nil-coalesce ??", function()
    local s, _ = first_stmt("x ?? 0")
    assert.are.equal(ast.K.NIL_COALESCE, s.expr.kind)
  end)
end)

-- ── Function call expressions ─────────────────────────────────────────────────

describe("parser — function calls", function()
  it("parses zero-arg function call", function()
    local s, _ = first_stmt("base-damage")
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    assert.are.equal(ast.K.FN_CALL, s.expr.kind)
    assert.are.equal("base-damage", s.expr.name)
    assert.are.equal(0, #s.expr.args)
  end)

  it("parses one-arg function call with integer", function()
    local s, _ = first_stmt("take-damage 15")
    local e = s.expr
    assert.are.equal(ast.K.FN_CALL, e.kind)
    assert.are.equal("take-damage", e.name)
    assert.are.equal(1, #e.args)
    assert.are.equal(15, e.args[1].value)
  end)

  it("parses multi-arg function call", function()
    local s, _ = first_stmt("clamp x 0 100")
    local e = s.expr
    assert.are.equal("clamp", e.name)
    assert.are.equal(3, #e.args)
  end)

  it("parses function call with symbol arg", function()
    local s, _ = first_stmt("spawn-enemy 'goblin")
    local e = s.expr
    assert.are.equal(1, #e.args)
    assert.are.equal(ast.K.SYMBOL_LIT, e.args[1].kind)
  end)

  it("parses function call with path arg", function()
    local s, _ = first_stmt("min player/health player/max-health")
    local e = s.expr
    assert.are.equal(2, #e.args)
    -- Path tokens produce path_expr nodes; bare idents produce fn_call nodes
    assert.are.equal(ast.K.PATH_EXPR, e.args[1].kind)
    assert.are.equal(ast.K.PATH_EXPR, e.args[2].kind)
  end)
end)

-- ── Match expression ──────────────────────────────────────────────────────────

describe("parser — match expression", function()
  it("parses a match with symbol arms", function()
    local fd, diags = parse_fn("test", [[
match player/class:
  'warrior: 20
  'rogue: 14
  'mage: 8]])
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local s = fd.body[1]
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    local m = s.expr
    assert.are.equal(ast.K.MATCH_EXPR, m.kind)
    assert.are.equal(3, #m.arms)
    assert.are.equal(ast.K.PATH_EXPR, m.expr.kind)
  end)

  it("parses a match arm with wildcard _", function()
    -- Note: bare 'x:' is lexed as NAMED_ARG; parse_match_expr handles this.
    local fd, diags = parse_fn("test", [[
match x:
  1: 'one
  _: 'other]])
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local s = fd.body[1]
    assert.are.equal(ast.K.EXPR_STMT, s.kind)
    local m = s.expr
    assert.are.equal(ast.K.MATCH_EXPR, m.kind)
    assert.are.equal(2, #m.arms)
    assert.are.equal("_", m.arms[2].pattern)
  end)
end)

-- ── If expression ─────────────────────────────────────────────────────────────

describe("parser — if/else in code context", function()
  it("parses a bare if (no else)", function()
    local fd, diags = parse_fn("test", [[
if player/alive:
  pass]])
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local s = fd.body[1]
    assert.are.equal(ast.K.IF_EXPR, s.kind)
    assert.is_nil(s.else_body)
  end)

  it("parses an if/else", function()
    local fd, diags = parse_fn("test", [[
if player/alive:
  pass
else:
  pass]])
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local s = fd.body[1]
    assert.are.equal(ast.K.IF_EXPR, s.kind)
    assert.is_not_nil(s.else_body)
  end)
end)

-- ── When statement ────────────────────────────────────────────────────────────

describe("parser — when statement", function()
  it("parses a when block", function()
    local fd, diags = parse_fn("test", [[
when player/health <= 0:
  set! player/status 'dead]])
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local s = fd.body[1]
    assert.are.equal(ast.K.WHEN_STMT, s.kind)
    assert.are.equal(ast.K.BINARY_OP, s.condition.kind)
    assert.are.equal("<=", s.condition.op)
    assert.are.equal(1, #s.body)
    assert.are.equal(ast.K.SET_MUT, s.body[1].kind)
  end)
end)

-- ── Mutation primitives ───────────────────────────────────────────────────────

describe("parser — mutation primitives", function()
  it("parses set!", function()
    local s = first_stmt("set! player/health 100")
    assert.are.equal(ast.K.SET_MUT, s.kind)
    assert.are.equal(ast.K.PATH_EXPR, s.path.kind)
    assert.are.equal(100, s.value.value)
  end)

  it("parses inc!", function()
    local s = first_stmt("inc! player/gold 10")
    assert.are.equal(ast.K.INC_MUT, s.kind)
    assert.are.equal(10, s.amount.value)
  end)

  it("parses dec!", function()
    local s = first_stmt("dec! player/health 5")
    assert.are.equal(ast.K.DEC_MUT, s.kind)
    assert.are.equal(5, s.amount.value)
  end)

  it("parses add!", function()
    local s = first_stmt("add! player/friends 'bob")
    assert.are.equal(ast.K.ADD_MUT, s.kind)
  end)

  it("parses remove!", function()
    local s = first_stmt("remove! player/friends 'alice")
    assert.are.equal(ast.K.REMOVE_MUT, s.kind)
  end)

  it("parses clear!", function()
    local s = first_stmt("clear! player/friends")
    assert.are.equal(ast.K.CLEAR_MUT, s.kind)
  end)

  it("parses push!", function()
    local s = first_stmt("push! player/log 'event")
    assert.are.equal(ast.K.PUSH_MUT, s.kind)
  end)

  it("parses pop!", function()
    local s = first_stmt("pop! player/log")
    assert.are.equal(ast.K.POP_MUT, s.kind)
  end)

  it("parses undo!", function()
    local s = first_stmt("undo!")
    assert.are.equal(ast.K.UNDO_MUT, s.kind)
    assert.is_nil(s.steps)
  end)

  it("parses spawn!", function()
    local s = first_stmt("spawn! npcs 'goblin rec")
    assert.are.equal(ast.K.SPAWN_MUT, s.kind)
    assert.are.equal("npcs", s.family)
  end)

  it("parses despawn!", function()
    local s = first_stmt("despawn! npcs 'goblin")
    assert.are.equal(ast.K.DESPAWN_MUT, s.kind)
  end)
end)

-- ── Function declarations ─────────────────────────────────────────────────────

describe("parser — fn declarations", function()
  it("parses a no-param function", function()
    local d = decl("fn compute-score:\n  42")
    assert.are.equal(ast.K.FN_DECL, d.kind)
    assert.are.equal("compute-score", d.name)
    assert.are.equal(0, #d.params)
  end)

  it("parses a one-param function", function()
    local d = decl("fn double x:\n  x")
    assert.are.equal(ast.K.FN_DECL, d.kind)
    assert.are.equal("double", d.name)
    assert.are.equal(1, #d.params)
    assert.are.equal("x", d.params[1])
  end)

  it("parses a two-param function", function()
    local d = decl("fn add x y:\n  x")
    assert.are.equal("add", d.name)
    assert.are.equal(2, #d.params)
    assert.are.equal("x", d.params[1])
    assert.are.equal("y", d.params[2])
  end)

  it("parses pre: with a single inline expression", function()
    local d = decl("fn foo:\n  pre: x > 0\n  pass")
    assert.are.equal(ast.K.FN_DECL, d.kind)
    assert.are.equal(1, #d.pre)
  end)

  it("parses post: with a single inline expression", function()
    local d = decl("fn foo:\n  post: player/health >= 0\n  pass")
    assert.are.equal(1, #d.post)
  end)

  it("parses pre: with an indented block of conditions", function()
    local fd, diags = parse_fn("foo", [[
pre:
  amount > 0
  player/status = 'alive
pass]])
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    assert.are.equal(2, #fd.pre)
  end)

  it("parses fn body with mutation and when", function()
    local fd, diags = parse_fn("take-damage amount", [[
dec! player/health amount
when player/health <= 0:
  set! player/status 'dead]])
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    assert.are.equal(2, #fd.body)
    assert.are.equal(ast.K.DEC_MUT, fd.body[1].kind)
    assert.are.equal(ast.K.WHEN_STMT, fd.body[2].kind)
  end)

  it("records fn source position", function()
    local d = decl("fn my-fn:\n  pass")
    assert.are.equal(1, d.pos.line)
  end)
end)

-- ── Scene declarations ────────────────────────────────────────────────────────

describe("parser — scene declarations", function()
  it("parses a minimal scene with narration", function()
    local d, diags = parse_scene("room:\n  You are in a room.")
    local errs = 0
    for _, e in ipairs(diags) do if e.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    assert.are.equal(ast.K.SCENE_DECL, d.kind)
    assert.are.equal("room", d.name)
    assert.are.equal(1, #d.body)
    assert.are.equal(ast.K.NARRATION_LINE, d.body[1].kind)
  end)

  it("parses unconditional choice", function()
    local d, diags = parse_scene("room:\n  * Go north\n    -> north-room")
    local errs = 0
    for _, e in ipairs(diags) do if e.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local choice = d.body[1]
    assert.are.equal(ast.K.CHOICE, choice.kind)
    assert.is_nil(choice.guard)
    assert.are.equal(1, #choice.body)
    assert.are.equal(ast.K.SCENE_GOTO, choice.body[1].kind)
  end)

  it("parses conditional choice with guard", function()
    local d, _ = parse_scene(
      "room:\n  * [not player/has-key] Pick up key\n    set! player/has-key true")
    local choice = d.body[1]
    assert.are.equal(ast.K.CHOICE, choice.kind)
    assert.is_not_nil(choice.guard)
    assert.are.equal(ast.K.UNARY_OP, choice.guard.kind)
    assert.are.equal("not", choice.guard.op)
  end)

  it("parses conditional narration line", function()
    local d, _ = parse_scene("room:\n  [player/has-key] You hold the key.")
    local cn = d.body[1]
    assert.are.equal(ast.K.COND_NARRATION, cn.kind)
    assert.is_not_nil(cn.condition)
    assert.is_not_nil(cn.text)
  end)

  it("parses scene goto (->)", function()
    local d, _ = parse_scene("room:\n  -> north-room")
    assert.are.equal(ast.K.SCENE_GOTO, d.body[1].kind)
    assert.are.equal("north-room", d.body[1].target)
  end)

  it("parses scene enter (=>)", function()
    local d, _ = parse_scene("room:\n  => sub-scene")
    assert.are.equal(ast.K.SCENE_ENTER, d.body[1].kind)
    assert.are.equal("sub-scene", d.body[1].target)
  end)

  it("parses scene exit (<-)", function()
    local d, _ = parse_scene("room:\n  <-")
    assert.are.equal(ast.K.SCENE_EXIT, d.body[1].kind)
  end)

  it("parses if/else inside a scene body", function()
    local d, diags = parse_scene([[room:
  if player/has-key:
    The door opens.
  else:
    The door stays shut.]])
    local errs = 0
    for _, e in ipairs(diags) do if e.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local s = d.body[1]
    assert.are.equal(ast.K.IF_EXPR, s.kind)
    assert.is_not_nil(s.else_body)
  end)

  it("parses inline expression in narration", function()
    local d, diags = parse_scene("start:\n  Health: {player/health} points.")
    local errs = 0
    for _, e in ipairs(diags) do if e.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local line = d.body[1]
    assert.are.equal(ast.K.NARRATION_LINE, line.kind)
    -- text should contain a string part and an inline_expr part
    local has_inline = false
    for _, part in ipairs(line.text) do
      if type(part) == "table" and part.kind == ast.K.INLINE_EXPR then
        has_inline = true
      end
    end
    assert.is_true(has_inline)
  end)
end)

-- ── Phase 2 integration: test02 and test03 ───────────────────────────────────

describe("parser — Phase 2 integration", function()
  it("parses test02_choices.sb without errors", function()
    local f = io.open("tests/test02_choices.sb", "r")
    local src = f:read("*a"); f:close()
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
  end)

  it("test02: finds fn_decl, scene_decl nodes", function()
    local f = io.open("tests/test02_choices.sb", "r")
    local src = f:read("*a"); f:close()
    local tree, _ = parse(src)
    local fns, scenes = 0, 0
    for _, d in ipairs(tree.decls) do
      if d.kind == ast.K.FN_DECL   then fns   = fns   + 1 end
      if d.kind == ast.K.SCENE_DECL then scenes = scenes + 1 end
    end
    assert.are.equal(1, fns)
    assert.are.equal(2, scenes)
  end)

  it("parses test03_types.sb without errors", function()
    local f = io.open("tests/test03_types.sb", "r")
    local src = f:read("*a"); f:close()
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
  end)

  it("test03: finds multiple fn_decl and scene_decl nodes", function()
    local f = io.open("tests/test03_types.sb", "r")
    local src = f:read("*a"); f:close()
    local tree, _ = parse(src)
    local fns, scenes = 0, 0
    for _, d in ipairs(tree.decls) do
      if d.kind == ast.K.FN_DECL   then fns   = fns   + 1 end
      if d.kind == ast.K.SCENE_DECL then scenes = scenes + 1 end
    end
    assert.is_true(fns >= 6)
    assert.are.equal(1, scenes)
  end)
end)

-- ── Phase 4 parser additions ─────────────────────────────────────────────────

describe("parser — match arm with pass body", function()
  it("parses '_: pass' inline arm without error", function()
    local src = [[
fn check msg:
  match msg:
    alert {threat}:
      set! state/x 1
    _: pass
]]
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
  end)

  it("parses inline mutation in match arm without error", function()
    local src = [[
fn check msg:
  match msg:
    alert {x}:
      set! state/x 1
    dismiss {y}:
      set! state/x 0
    _: pass
]]
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
  end)
end)

describe("parser — variant record constructor in parens", function()
  it("parses (Type/variant field: val) as record constructor", function()
    local src = [[
fn send-alert:
  send! guard (ActorMsg/alert threat: 'x, location: 'village)
]]
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    -- find the send! in the fn body
    local fn = tree.decls[1]
    assert.equal(ast.K.FN_DECL, fn.kind)
    local stmt = fn.body[1]
    assert.equal(ast.K.SEND_MUT, stmt.kind)
    local msg = stmt.msg
    assert.equal(ast.K.RECORD_CONSTRUCTOR, msg.kind)
    assert.equal("ActorMsg/alert", msg.type_name)
  end)

  it("parses (Type/variant) with no fields as record constructor", function()
    local src = [[
fn send-dismiss:
  send! guard (ActorMsg/dismiss reason: 'neutral)
]]
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
  end)
end)

describe("parser — send! mutation", function()
  it("parses actor name and message expression", function()
    local src = [[
fn notify:
  send! guard (ActorMsg/alert threat: 'enemy, location: 'forest)
]]
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local fn = tree.decls[1]
    local stmt = fn.body[1]
    assert.equal(ast.K.SEND_MUT, stmt.kind)
    -- actor should be fn_call("guard", [])
    assert.equal(ast.K.FN_CALL, stmt.actor.kind)
    assert.equal("guard", stmt.actor.name)
  end)
end)

describe("parser — Phase 4 integration: test06_actors.sb", function()
  it("parses test06_actors.sb without errors", function()
    local f = io.open("tests/test06_actors.sb", "r")
    local src = f:read("*a"); f:close()
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
  end)

  it("test05_log_and_time.sb parses without errors", function()
    local f = io.open("tests/test05_log_and_time.sb", "r")
    local src = f:read("*a"); f:close()
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
  end)
end)

describe("parser — actor declaration", function()
  it("parses actor with all fields", function()
    local src = [[
actor blacksmith:
  state:     npcs/blacksmith
  perceives: [player/location, player/inventory]
  inbox:     List(ActorMsg, 4)
  behavior:  blacksmith-behavior
  priority:  10
]]
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local node = tree.decls[1]
    assert.equal(ast.K.ACTOR_DECL, node.kind)
    assert.equal("blacksmith", node.name)
    assert.equal("npcs/blacksmith", node.state_path)
    assert.equal("blacksmith-behavior", node.behavior)
    assert.equal(10, node.priority)
    assert.equal(2, #node.perceives)
    assert.equal("player/location", node.perceives[1])
    assert.equal("player/inventory", node.perceives[2])
    assert.equal(ast.K.TYPE_LIST, node.inbox_type.kind)
  end)

  it("parses actor with wildcard perceives", function()
    local src = [[
actor guard:
  state:     npcs/guard
  perceives: [player/location, npcs/*/location, npcs/guard/*]
  inbox:     List(ActorMsg, 4)
  behavior:  guard-behavior
  priority:  20
]]
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local node = tree.decls[1]
    assert.equal(ast.K.ACTOR_DECL, node.kind)
    assert.equal("guard", node.name)
    assert.equal(20, node.priority)
    assert.equal(3, #node.perceives)
    -- wildcard paths are stored as reconstructed strings
    assert.equal("npcs/*/location", node.perceives[2])
    assert.equal("npcs/guard/*", node.perceives[3])
  end)

  it("attaches doc string to actor_decl", function()
    local src = [[
"The village blacksmith."
actor blacksmith:
  state:    npcs/blacksmith
  behavior: blacksmith-behavior
  priority: 10
]]
    local tree, diags = parse(src)
    local node = tree.decls[1]
    assert.equal(ast.K.ACTOR_DECL, node.kind)
    assert.equal("The village blacksmith.", node.doc)
  end)
end)

describe("parser — schedule declaration", function()
  it("parses schedule with every: and offset:", function()
    local src = [[
schedule daily-tax:
  every:  [day: +1]
  offset: [hour: 6]
  fn:
    dec!  player/gold 5
    inc!  world/tax-due 5
]]
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local node = tree.decls[1]
    assert.equal(ast.K.SCHEDULE_DECL, node.kind)
    assert.equal("daily-tax", node.name)
    assert.not_nil(node.trigger.every)
    assert.equal(1, #node.trigger.every)
    assert.equal("day", node.trigger.every[1].axis)
    assert.equal(1, node.trigger.every[1].value)
    assert.not_nil(node.trigger.offset)
    assert.equal("hour", node.trigger.offset[1].axis)
    assert.equal(6, node.trigger.offset[1].value)
    assert.equal(2, #node.body)
  end)

  it("parses schedule with at:", function()
    local src = [[
schedule mid-point:
  at: [tick: +20]
  fn:
    when player/chapter = 'intro:
      set! player/chapter 'mid
]]
    local tree, diags = parse(src)
    local errs = 0
    for _, d in ipairs(diags) do if d.level == "error" then errs = errs + 1 end end
    assert.are.equal(0, errs)
    local node = tree.decls[1]
    assert.equal(ast.K.SCHEDULE_DECL, node.kind)
    assert.equal("mid-point", node.name)
    assert.not_nil(node.trigger.at)
    assert.equal("tick", node.trigger.at[1].axis)
    assert.equal(20, node.trigger.at[1].value)
    assert.equal(1, #node.body)
  end)

  it("attaches doc string to schedule_decl", function()
    local src = [[
"Reset dispositions each morning."
schedule morning-reset:
  every: [day: +1]
  fn:
    pass
]]
    local tree, diags = parse(src)
    local node = tree.decls[1]
    assert.equal(ast.K.SCHEDULE_DECL, node.kind)
    assert.equal("Reset dispositions each morning.", node.doc)
  end)
end)

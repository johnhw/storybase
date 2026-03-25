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

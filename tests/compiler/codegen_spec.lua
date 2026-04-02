-- tests/compiler/codegen_spec.lua
-- Tests for compiler/codegen.lua (Phase 1)

local lexer   = require("compiler.lexer")
local parser  = require("compiler.parser")
local checker = require("compiler.checker")
local codegen = require("compiler.codegen")
local ast     = require("compiler.ast")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function compile(src)
  local tokens = lexer.tokenize(src, "test")
  local tree   = parser.parse(tokens, "test")
  local typed  = checker.check(tree, "test")
  local gt, diags = codegen.emit(typed)
  return gt, diags
end

local function schema(src)
  local gt = compile(src)
  return gt and gt.schema
end

-- ============================================================
-- Game table structure
-- ============================================================

describe("codegen — game table structure", function()
  it("returns a game table with schema, fns, verifies, watches", function()
    local gt = compile("type Status = alive | dead")
    assert.is_not_nil(gt)
    assert.is_table(gt.schema)
    assert.is_table(gt.fns)
    assert.is_table(gt.verifies)
    assert.is_table(gt.watches)
  end)

  it("returns no codegen errors for a valid schema", function()
    local _, diags = compile("type Status = alive | dead")
    assert.are.equal(0, #diags)
  end)
end)

-- ============================================================
-- schema.types
-- ============================================================

describe("codegen — schema.types (enum)", function()
  it("emits an enum type descriptor", function()
    local sc = schema("type Status = alive | dead | unconscious")
    assert.is_not_nil(sc)
    assert.are.equal(1, #sc.types)
    local t = sc.types[1]
    assert.are.equal("enum", t.kind)
    assert.are.equal("Status", t.name)
    assert.are.same({"alive", "dead", "unconscious"}, t.values)
  end)

  it("includes doc string in enum descriptor", function()
    local sc = schema('"Player status."\ntype Status = alive | dead')
    assert.are.equal("Player status.", sc.types[1].doc)
  end)
end)

describe("codegen — schema.types (alias)", function()
  it("emits an alias type descriptor with type_desc", function()
    local sc = schema("type Health = Int(0, 100)")
    local t = sc.types[1]
    assert.are.equal("alias", t.kind)
    assert.are.equal("Health", t.name)
    assert.are.equal("int", t.type_desc.tag)
    assert.are.equal(0,   t.type_desc.min)
    assert.are.equal(100, t.type_desc.max)
  end)
end)

describe("codegen — schema.types (record)", function()
  it("emits a record type descriptor with fields", function()
    local sc = schema("type Player:\n  health: Int(0,100) = 100\n  alive: Bool = true")
    local t = sc.types[1]
    assert.are.equal("record", t.kind)
    assert.are.equal("Player", t.name)
    assert.are.equal(2, #t.fields)
    assert.are.equal("health", t.fields[1].name)
    assert.are.equal("int",    t.fields[1].type_desc.tag)
    assert.are.equal("int",    t.fields[1].default.tag)
    assert.are.equal(100,      t.fields[1].default.value)
    assert.are.equal("bool",   t.fields[2].type_desc.tag)
  end)

  it("emits mixin references in field list", function()
    local sc = schema("type Base:\n  hp: Int(0,100)\ntype Child:\n  with Base\n  mp: Int(0,50)")
    local child = sc.types[2]
    assert.are.equal("record", child.kind)
    -- First entry should be the mixin marker
    assert.are.equal("Base", child.fields[1].mixin)
    assert.are.equal("mp",   child.fields[2].name)
  end)
end)

describe("codegen — schema.types (variant)", function()
  it("emits a variant type descriptor with branches", function()
    local sc = schema("type Msg:\n  | ping:\n  | pong: count: Int(0, 9)")
    local t = sc.types[1]
    assert.are.equal("variant", t.kind)
    assert.are.equal("Msg", t.name)
    assert.are.equal(2, #t.branches)
    assert.are.equal("ping", t.branches[1].name)
    assert.are.equal(0, #t.branches[1].fields)
    assert.are.equal("pong", t.branches[2].name)
    assert.are.equal(1, #t.branches[2].fields)
    assert.are.equal("count", t.branches[2].fields[1].name)
  end)
end)

-- ============================================================
-- schema.states
-- ============================================================

describe("codegen — schema.states", function()
  it("emits a scalar state descriptor", function()
    local sc = schema("type P:\n  hp: Int(0,100)\nstate player: P")
    local s = sc.states[1]
    assert.are.equal("scalar", s.kind)
    assert.are.equal("player", s.path)
    assert.are.equal("named", s.type_desc.tag)
    assert.are.equal("P", s.type_desc.name)
    assert.is_nil(s.default)
  end)

  it("emits a scalar state with default", function()
    local sc = schema("state score: Int(0,9999) = 0")
    local s = sc.states[1]
    assert.are.equal("int", s.default.tag)
    assert.are.equal(0, s.default.value)
  end)

  it("emits multi-segment path", function()
    local sc = schema("state player/health: Int(0,100)")
    assert.are.equal("player/health", sc.states[1].path)
  end)

  it("emits an inline-record state descriptor", function()
    local sc = schema("state world:\n  turn: Int(0,9999) = 0\n  active: Bool = false")
    local s = sc.states[1]
    assert.are.equal("record", s.kind)
    assert.are.equal("world", s.path)
    assert.are.equal(2, #s.fields)
    assert.are.equal("turn",   s.fields[1].name)
    assert.are.equal("active", s.fields[2].name)
  end)

  it("emits a family state descriptor", function()
    local sc = schema("type Npc:\n  hp: Int(0,100)\nstate npcs/{npc}: Npc  max: 20")
    local s = sc.states[1]
    assert.are.equal("family", s.kind)
    assert.are.equal("npcs",   s.family)
    assert.are.equal("npc",    s.var)
    assert.are.equal(20,       s.max)
    assert.are.equal("named",  s.type_desc.tag)
  end)
end)

-- ============================================================
-- schema.relations
-- ============================================================

describe("codegen — schema.relations", function()
  it("emits a relation descriptor", function()
    local sc = schema("type L = a | b\nrelation exits: L -> Set(L, 6)")
    assert.are.equal(1, #sc.relations)
    local r = sc.relations[1]
    assert.are.equal("exits", r.name)
    assert.are.equal("L",     r.from_type)
    assert.are.equal("set",   r.to_type_desc.tag)
  end)
end)

-- ============================================================
-- schema counts
-- ============================================================

describe("codegen — schema counts", function()
  it("counts declared types", function()
    local sc = schema("type A = a|b\ntype B = x|y\ntype C = p|q")
    assert.are.equal(3, sc.type_count)
  end)

  it("counts declared state paths", function()
    local sc = schema("state a: Bool\nstate b: Bool\nstate c: Bool")
    assert.are.equal(3, sc.path_count)
  end)

  it("scene_count is 0 in Phase 1", function()
    local sc = schema("type S = a | b")
    assert.are.equal(0, sc.scene_count)
  end)
end)

-- ============================================================
-- schema.version and config
-- ============================================================

describe("codegen — schema.version and config", function()
  it("emits schema version", function()
    local sc = schema("schema-version: 5")
    assert.are.equal(5, sc.version)
  end)

  it("emits engine config", function()
    local sc = schema("engine-config:\n  entry-scene: main\n  scene-stack-max: 16")
    assert.are.equal("main", sc.engine_config["entry-scene"])
    assert.are.equal(16,     sc.engine_config["scene-stack-max"])
  end)

  it("emits time model", function()
    local sc = schema("time-model:\n  axes: [day, hour]\n  wrap: [none, 24]")
    assert.is_not_nil(sc.time_model)
    assert.are.same({"day","hour"}, sc.time_model.axes)
  end)
end)

-- ============================================================
-- State-space size
-- ============================================================

describe("codegen — state-space size", function()
  it("computes size for Bool state", function()
    local sc = schema("state active: Bool")
    -- Bool = 2; total with no other states = 2
    assert.are.equal(2, sc.state_space_size)
  end)

  it("computes size for Int state", function()
    local sc = schema("state hp: Int(0, 4)")
    -- Int(0,4) = 5 values
    assert.are.equal(5, sc.state_space_size)
  end)

  it("computes product for multiple states", function()
    local sc = schema("state a: Bool\nstate b: Bool")
    -- 2 * 2 = 4
    assert.are.equal(4, sc.state_space_size)
  end)

  it("reports 'unbounded' for String state", function()
    local sc = schema("state desc: String")
    assert.are.equal("unbounded", sc.state_space_size)
  end)

  it("computes size for enum alias", function()
    local sc = schema("type S = alive | dead | unk\nstate status: S")
    -- enum has 3 values
    assert.are.equal(3, sc.state_space_size)
  end)
end)

-- ============================================================
-- Default value descriptors
-- ============================================================

describe("codegen — default value descriptors", function()
  it("emits bool default", function()
    local sc = schema("state active: Bool = false")
    assert.are.equal("bool",  sc.states[1].default.tag)
    assert.are.equal(false,   sc.states[1].default.value)
  end)

  it("emits symbol default", function()
    local sc = schema("type S = alive|dead\nstate status: S = 'alive")
    assert.are.equal("symbol", sc.states[1].default.tag)
    assert.are.equal("alive",  sc.states[1].default.name)
  end)

  it("emits string default", function()
    local sc = schema('state name: String = "Unknown"')
    assert.are.equal("string",  sc.states[1].default.tag)
    assert.are.equal("Unknown", sc.states[1].default.value)
  end)

  it("emits empty_set default", function()
    local sc = schema("type F = a|b\nstate flags: Set(F, 5) = (set)")
    assert.are.equal("empty_set", sc.states[1].default.tag)
  end)

  it("emits record constructor default", function()
    local sc = schema('state player: Player = Player(name: "Hero")')
    local d = sc.states[1].default
    assert.are.equal("record",  d.tag)
    assert.are.equal("Player",  d.type_name)
    assert.are.equal("string",  d.fields.name.tag)
    assert.are.equal("Hero",    d.fields.name.value)
  end)
end)

-- ============================================================
-- Integration: full schema-only compile
-- ============================================================

describe("codegen — integration milestone", function()
  it("compiles a complete schema-only file to a valid game table", function()
    local src = [[
module game

schema-version: 1

engine-config:
  entry-scene: village
  scene-stack-max: 16

time-model:
  axes: [day, hour, tick]
  wrap: [none, 24, none]

type Status   = alive | dead | unconscious
type Location = village | forest | dungeon
type Health   = Int(0, 100)
type Gold     = Int(0, 9999)

type Player:
  health:   Health   = 100
  status:   Status   = 'alive
  location: Location = 'village
  gold:     Gold     = 30

state player: Player

state world:
  turn:    Int(0, 9999) = 0
  chapter: Location     = 'village

state npcs/{npc}: Player  max: 20

relation exits: Location -> Set(Location, 6)
]]
    local gt, diags = compile(src)

    -- No codegen errors
    assert.are.equal(0, #diags)

    -- Game table structure
    assert.is_table(gt.schema)
    assert.is_table(gt.fns)
    assert.is_table(gt.verifies)
    assert.is_table(gt.watches)

    -- Schema counts
    assert.are.equal(5, gt.schema.type_count)    -- Status,Location,Health,Gold,Player
    assert.are.equal(3, gt.schema.path_count)    -- player, world, npcs/{npc}
    assert.are.equal(1, gt.schema.relation_count)
    assert.are.equal(0, gt.schema.scene_count)

    -- Version and config
    assert.are.equal(1, gt.schema.version)
    assert.are.equal("village", gt.schema.engine_config["entry-scene"])

    -- Time model
    assert.are.same({"day","hour","tick"}, gt.schema.time_model.axes)

    -- Types list
    assert.are.equal(5, #gt.schema.types)

    -- States list
    assert.are.equal(3, #gt.schema.states)

    -- Relations list
    assert.are.equal(1, #gt.schema.relations)
    assert.are.equal("exits", gt.schema.relations[1].name)
  end)
end)

-- ============================================================
-- Function and scene emission (Phase 3)
-- ============================================================

describe("codegen — fn emission", function()
  it("emits fn descriptor with body nodes", function()
    local gt = compile([[
fn pickup-key:
  pre:  not player/has-key
  set!  player/has-key true
state player/has-key: Bool = false
]])
    assert.is_table(gt.fns)
    local fn = gt.fns["pickup-key"]
    assert.is_not_nil(fn)
    assert.equal("pickup-key", fn.name)
    assert.is_table(fn.pre)
    assert.is_table(fn.body)
    assert.equal(1, #fn.pre)
    assert.equal(1, #fn.body)
    assert.equal("set_mut", fn.body[1].kind)
  end)

  it("marks transaction fn correctly", function()
    local gt = compile([[
fn do-nothing:
  pass
]])
    local fn = gt.fns["do-nothing"]
    assert.is_not_nil(fn)
    -- pass stmt means no mutations; is_transaction = false
    assert.is_false(fn.is_transaction)
  end)
end)

describe("codegen — scene emission", function()
  it("emits scene descriptor with body nodes", function()
    local gt = compile([[
engine-config:
  entry-scene: room
scene room:
  You are in a room.
  * Go north
    -> north-room
]])
    assert.is_table(gt.scenes)
    local scene = gt.scenes["room"]
    assert.is_not_nil(scene)
    assert.equal("room", scene.name)
    assert.is_table(scene.body)
    assert.is_true(#scene.body >= 2)  -- narration_line + choice
  end)
end)

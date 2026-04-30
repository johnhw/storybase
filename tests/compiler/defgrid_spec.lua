-- tests/compiler/defgrid_spec.lua
-- Compiler pipeline tests for the `defgrid` declaration.
--
-- Covers:
--   Parser     — recognises syntax, produces DEFGRID_DECL node
--   Checker    — validates dimensions, cell-type, duplicate detection
--   Codegen    — emits grids into game_table.grids

local compiler_mod = require("compiler.compiler")
local lexer        = require("compiler.lexer")
local parser       = require("compiler.parser")
local checker      = require("compiler.checker")
local codegen      = require("compiler.codegen")
local ast          = require("compiler.ast")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local MIN_HEADER = [[
module test
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main
scene main:
  * Done
    -> main
]]

--- Compile a source string containing the given grid snippet (after the header).
local function compile_grid(grid_src)
  local src = MIN_HEADER .. "\n" .. grid_src
  local result, diags = compiler_mod.compile(src, "test.sb")
  return result, diags
end

--- Full compile (header + extra types + grid).
local function compile_with(extra, grid_src)
  local src = MIN_HEADER .. "\n" .. extra .. "\n" .. grid_src
  local result, diags = compiler_mod.compile(src, "test.sb")
  return result, diags
end

--- Run only parser + checker stages; return typed AST and diags.
local function parse_check(src)
  local tokens = lexer.tokenize(src, "test")
  local tree   = parser.parse(tokens, "test")
  local typed, diags = checker.check(tree, "test")
  return typed, diags
end

--- Count errors in a diags list.
local function error_count(diags)
  local n = 0
  for _, d in ipairs(diags or {}) do
    if d.level == "error" then n = n + 1 end
  end
  return n
end

--- Find a defgrid_decl node in the typed AST.
local function find_defgrid(typed, name)
  for _, node in ipairs(typed.decls or {}) do
    if node.kind == ast.K.DEFGRID_DECL and node.name == name then
      return node
    end
  end
  return nil
end

-- ── Parser tests ──────────────────────────────────────────────────────────────

describe("defgrid — parser", function()

  it("parses a minimal defgrid declaration", function()
    local src = [[
type Tile = floor | wall
defgrid arena:
  dimensions: 10 x 8
  cell-type: Tile
]]
    local tokens = lexer.tokenize(src, "t")
    local tree   = parser.parse(tokens, "t")
    local node   = nil
    for _, d in ipairs(tree.decls or {}) do
      if d.kind == ast.K.DEFGRID_DECL then node = d end
    end
    assert.is_not_nil(node, "expected DEFGRID_DECL node")
    assert.equal("arena",  node.name)
    assert.equal(10,       node.width)
    assert.equal(8,        node.height)
    assert.equal("Tile",   node.cell_type)
  end)

  it("parses optional default field", function()
    local src = [[
type Tile = floor | wall
defgrid cave:
  dimensions: 5 x 5
  cell-type: Tile
  default: wall
]]
    local tokens = lexer.tokenize(src, "t")
    local tree   = parser.parse(tokens, "t")
    local node   = nil
    for _, d in ipairs(tree.decls or {}) do
      if d.kind == ast.K.DEFGRID_DECL then node = d end
    end
    assert.is_not_nil(node)
    assert.equal("wall", node.default_val)
  end)

  it("parses a hyphenated grid name", function()
    local src = [[
type T = a | b
defgrid world-map:
  dimensions: 20 x 15
  cell-type: T
]]
    local tokens = lexer.tokenize(src, "t")
    local tree   = parser.parse(tokens, "t")
    local node   = nil
    for _, d in ipairs(tree.decls or {}) do
      if d.kind == ast.K.DEFGRID_DECL then node = d end
    end
    assert.is_not_nil(node)
    assert.equal("world-map", node.name)
  end)

  it("parses multiple defgrid declarations", function()
    local src = [[
type T = a | b
defgrid grid1:
  dimensions: 4 x 4
  cell-type: T
defgrid grid2:
  dimensions: 6 x 3
  cell-type: T
]]
    local tokens = lexer.tokenize(src, "t")
    local tree   = parser.parse(tokens, "t")
    local grids  = {}
    for _, d in ipairs(tree.decls or {}) do
      if d.kind == ast.K.DEFGRID_DECL then grids[d.name] = d end
    end
    assert.is_not_nil(grids["grid1"])
    assert.is_not_nil(grids["grid2"])
    assert.equal(4, grids["grid1"].width)
    assert.equal(6, grids["grid2"].width)
  end)

  it("parser does not crash on missing dimensions", function()
    -- Malformed: no dimensions line
    local src = "type T = a\ndefgrid oops:\n  cell-type: T\n"
    local tokens = lexer.tokenize(src, "t")
    local ok = pcall(parser.parse, tokens, "t")
    assert.is_true(ok, "parser should not raise on missing dimensions")
  end)

  it("parser does not crash on completely empty defgrid body", function()
    local src = "defgrid empty:\n"
    local tokens = lexer.tokenize(src, "t")
    local ok = pcall(parser.parse, tokens, "t")
    assert.is_true(ok)
  end)

end)

-- ── Checker tests ─────────────────────────────────────────────────────────────

describe("defgrid — checker", function()

  it("accepts a valid defgrid with declared enum cell-type", function()
    local src = [[
type Tile = floor | wall
defgrid arena:
  dimensions: 10 x 8
  cell-type: Tile
]]
    local typed, diags = parse_check(src)
    assert.equal(0, error_count(diags), "no errors expected")
    -- Confirm node is registered in symtab
    assert.is_not_nil(typed.symtab.grids["arena"])
  end)

  it("registers grid name in symtab.grids", function()
    local src = [[
type T = a | b
defgrid mygrid:
  dimensions: 5 x 5
  cell-type: T
]]
    local typed, diags = parse_check(src)
    assert.equal(0, error_count(diags))
    assert.is_not_nil(typed.symtab.grids and typed.symtab.grids["mygrid"])
  end)

  it("rejects duplicate defgrid names", function()
    local src = [[
type T = a | b
defgrid dup:
  dimensions: 3 x 3
  cell-type: T
defgrid dup:
  dimensions: 4 x 4
  cell-type: T
]]
    local _, diags = parse_check(src)
    assert.is_true(error_count(diags) > 0, "expected DUPLICATE_NAME error")
  end)

  it("rejects undefined cell-type", function()
    local src = [[
defgrid bad:
  dimensions: 5 x 5
  cell-type: NoSuchType
]]
    local _, diags = parse_check(src)
    assert.is_true(error_count(diags) > 0, "expected UNDEFINED_TYPE error")
  end)

  it("rejects missing cell-type", function()
    local src = [[
defgrid nocell:
  dimensions: 5 x 5
]]
    local _, diags = parse_check(src)
    assert.is_true(error_count(diags) > 0, "expected BAD_DECLARATION error for missing cell-type")
  end)

  it("rejects zero width", function()
    -- Parser would leave width=nil for bad input; checker must reject it
    local src = [[
type T = a
defgrid zerow:
  dimensions: 0 x 5
  cell-type: T
]]
    -- 0 is parsed as INTEGER(0) but tg.new rejects 0; checker should emit error
    local _, diags = parse_check(src)
    assert.is_true(error_count(diags) > 0, "expected error for width=0")
  end)

  it("rejects zero height", function()
    local src = [[
type T = a
defgrid zeroh:
  dimensions: 5 x 0
  cell-type: T
]]
    local _, diags = parse_check(src)
    assert.is_true(error_count(diags) > 0, "expected error for height=0")
  end)

  it("accepts built-in types as cell-type (Int, Bool)", function()
    -- Bool is a built-in type so it should be accepted
    local src = [[
defgrid flags:
  dimensions: 4 x 4
  cell-type: Bool
]]
    local _, diags = parse_check(src)
    -- The only errors should be about missing module header etc., not UNDEFINED_TYPE
    local undef_errors = 0
    for _, d in ipairs(diags or {}) do
      if d.level == "error" and d.code == ast.E.UNDEFINED_TYPE then
        undef_errors = undef_errors + 1
      end
    end
    assert.equal(0, undef_errors, "Bool should be accepted as cell-type")
  end)

end)

-- ── Codegen tests ─────────────────────────────────────────────────────────────

describe("defgrid — codegen", function()

  it("emits grids table in game_table", function()
    local gt, diags = compile_with("type Tile = floor | wall", [[
defgrid arena:
  dimensions: 10 x 8
  cell-type: Tile
]])
    assert.equal(0, #(diags.errors or {}),
      "no compile errors expected")
    assert.is_not_nil(gt, "game_table should be non-nil")
    assert.is_table(gt.grids, "game_table.grids should be a table")
  end)

  it("emits correct width and height", function()
    local gt, _ = compile_with("type T = a | b", [[
defgrid mymap:
  dimensions: 12 x 9
  cell-type: T
]])
    assert.is_not_nil(gt and gt.grids and gt.grids["mymap"])
    assert.equal(12, gt.grids["mymap"].width)
    assert.equal(9,  gt.grids["mymap"].height)
  end)

  it("emits cell_type name", function()
    local gt, _ = compile_with("type TileKind = grass | rock | water", [[
defgrid world:
  dimensions: 5 x 5
  cell-type: TileKind
]])
    assert.equal("TileKind", gt.grids["world"].cell_type)
  end)

  it("emits default_val when provided", function()
    local gt, _ = compile_with("type T = floor | wall", [[
defgrid dungeon:
  dimensions: 6 x 6
  cell-type: T
  default: wall
]])
    assert.equal("wall", gt.grids["dungeon"].default_val)
  end)

  it("default_val is nil when not specified", function()
    local gt, _ = compile_with("type T = floor | wall", [[
defgrid nodefault:
  dimensions: 3 x 3
  cell-type: T
]])
    assert.is_nil(gt.grids["nodefault"].default_val)
  end)

  it("emits multiple grids", function()
    local gt, _ = compile_with("type T = a | b", [[
defgrid g1:
  dimensions: 4 x 4
  cell-type: T
defgrid g2:
  dimensions: 8 x 6
  cell-type: T
]])
    assert.is_not_nil(gt.grids["g1"])
    assert.is_not_nil(gt.grids["g2"])
    assert.equal(4, gt.grids["g1"].width)
    assert.equal(8, gt.grids["g2"].width)
  end)

  it("game_table.grids is empty table when no defgrid declared", function()
    local gt, _ = compile_grid("")
    assert.is_table(gt.grids)
    local count = 0
    for _ in pairs(gt.grids) do count = count + 1 end
    assert.equal(0, count)
  end)

end)

-- ── Engine integration tests ──────────────────────────────────────────────────

describe("defgrid — engine integration", function()

  local engine_mod   = require("runtime.engine")
  local tilegrid_mod = require("runtime.tilegrid")

  local GAME_SRC = [[
module grid-test
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main
type Tile = floor | wall
defgrid arena:
  dimensions: 5 x 4
  cell-type: Tile
  default: floor
scene main:
  * Done
    -> main
]]

  it("engine init creates grids from defgrid declarations", function()
    local gt, diags = compiler_mod.compile(GAME_SRC, "test.sb")
    assert.equal(0, #(diags.errors or {}))
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    assert.is_not_nil(eng._grids["arena"])
    assert.equal(5, eng._grids["arena"].width)
    assert.equal(4, eng._grids["arena"].height)
  end)

  it("grid is initialised with default cell value", function()
    local gt, _ = compiler_mod.compile(GAME_SRC, "test.sb")
    local eng   = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local g = eng._grids["arena"]
    assert.is_not_nil(g)
    -- All cells should be "floor" (the default)
    local cells = g.cells
    for i = 1, #cells do
      assert.equal("floor", cells[i], "cell " .. i .. " should default to 'floor'")
    end
  end)

  it("grid cells can be written via grid-set! and read via grid-get builtins", function()
    local gt, _ = compiler_mod.compile(GAME_SRC, "test.sb")
    local eng   = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local g = eng._grids["arena"]

    -- Write directly via tilegrid module
    tilegrid_mod.set(g.cells, g.width, g.height, 2, 1, "wall")
    assert.equal("wall", tilegrid_mod.get(g.cells, g.width, g.height, 2, 1))
    assert.equal("floor", tilegrid_mod.get(g.cells, g.width, g.height, 0, 0))
  end)

  it("grid width/height match the defgrid declaration", function()
    local gt, _ = compiler_mod.compile(GAME_SRC, "test.sb")
    local eng   = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local g = eng._grids["arena"]
    assert.equal(5 * 4, #g.cells)
  end)

  it("ctx.grids is populated in make_ctx", function()
    local gt, _ = compiler_mod.compile(GAME_SRC, "test.sb")
    local eng   = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    local ctx = eng:make_ctx("test")
    assert.is_table(ctx.grids)
    assert.is_not_nil(ctx.grids["arena"])
  end)

end)

-- ── Bug #3 regression: grid-set! persisted in state cache ────────────────────

describe("defgrid — Bug #3 regression: grid-set! logged, saved, BFS-visible", function()
  local engine_mod    = require("runtime.engine")
  local eval_mod      = require("runtime.eval")
  local log_mod       = require("runtime.log")
  local state_mod     = require("runtime.state")

  local GRID_SRC = [[
module grid-persist-test
  version: 1.0
schema-version: 1
engine-config:
  entry-scene: main
type Tile = floor | wall
defgrid arena:
  dimensions: 5 x 4
  cell-type: Tile
  default: floor
fn place-wall:
  grid-set! arena 2 1 'wall
fn remove-wall:
  grid-set! arena 2 1 'floor
scene main:
  * Go
    -> main
]]

  local function make_eng(src)
    local gt, _ = compiler_mod.compile(src or GRID_SRC, "test.sb")
    local eng = engine_mod.new(gt, { io_out = { write = function() end } })
    eng:init()
    return eng, gt
  end

  it("grid-set! writes a log entry into the state cache", function()
    local eng = make_eng()
    local ctx = eng:make_ctx("place-wall")
    eval_mod.call_fn("place-wall", {}, ctx)
    -- __grid/arena/2,1 must appear in the cache
    assert.equal("wall", eng._state._cache["__grid/arena/2,1"])
  end)

  it("grid-get reads from cache override (not just cells)", function()
    local eng = make_eng()
    local ctx = eng:make_ctx("test")
    -- Directly write override into cache (bypassing cells array)
    eng._state._cache["__grid/arena/2,1"] = "wall"
    -- grid-get builtin should see the override
    local get_node = { kind="fn_call", name="grid-get", args={
      { kind="fn_call", name="arena", args={} },
      { kind="int_lit", value=2 },
      { kind="int_lit", value=1 },
    }}
    assert.equal("wall", eval_mod.eval_expr(get_node, ctx))
  end)

  it("grid-set! value survives save/load round-trip", function()
    local tmp = os.tmpname()
    -- First session: set a wall and save
    local eng1, gt1 = make_eng()
    eval_mod.call_fn("place-wall", {}, eng1:make_ctx("place-wall"))
    -- Verify cell changed
    assert.equal("wall", eng1._state._cache["__grid/arena/2,1"])
    -- Write save file
    local log_mod2 = require("runtime.log")
    local f = io.open(tmp, "w")
    f:write("local save={}\n")
    f:write("save.version=1\n")
    f:write("save.scene_stack={'main'}\n")
    f:write("save.entries=\n")
    f:write(log_mod2.serialise_entries(eng1._log:entries()))
    f:write("\nreturn save\n")
    f:close()
    -- Second session: load save and verify grid state is restored
    local eng2 = engine_mod.new(gt1, { io_out = { write = function() end } })
    eng2._state:init_defaults()
    local fn2 = assert(load(assert(io.open(tmp, "r")):read("*a")))
    local save_data = fn2()
    local state_mod2 = require("runtime.state")
    state_mod2.replay(eng2._state, save_data.entries or {})
    eng2:register_actors_schedules()
    eng2:init_grids()
    eng2:apply_grid_cache()
    eng2._scene_stack = { "main" }
    -- Check cache override present
    assert.equal("wall", eng2._state._cache["__grid/arena/2,1"])
    -- Check cells array updated by apply_grid_cache
    local g2 = eng2._grids["arena"]
    local tg  = require("runtime.tilegrid")
    assert.equal("wall", tg.get(g2.cells, g2.width, g2.height, 2, 1))
    -- Check default cell unchanged
    assert.equal("floor", tg.get(g2.cells, g2.width, g2.height, 0, 0))
    os.remove(tmp)
  end)
end)

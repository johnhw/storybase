-- tests/runtime/fn_param_types_spec.lua
-- J-I1 — typed fn parameters.  See todo.md §J-I1.

local engine_mod   = require("runtime.engine")
local compiler_mod = require("compiler.compiler")

local function compile(src)
  local gt, diags = compiler_mod.compile(src, "test.sb")
  return gt, diags
end

local function make_engine(src)
  local gt, diags = compile(src)
  assert.equal(0, #(diags and diags.errors or {}),
    "compile errors: " ..
    ((diags and diags.errors[1] and diags.errors[1].message) or "?"))
  local eng = engine_mod.new(gt, {
    io_out = { write = function() end },
    io_in  = { read  = function() return "" end },
  })
  eng:init()
  return eng, gt
end

local function warnings_with_code(diags, code)
  local matches = {}
  for _, w in ipairs(diags and diags.warnings or {}) do
    if w.code == code then matches[#matches + 1] = w end
  end
  return matches
end

describe("J-I1: typed fn parameters", function()

  -- ── Static (compile-time) behaviour ─────────────────────────────────────────

  it("SymbolOf-typed fn param silences WRITE_UNTYPED_VAR", function()
    local _, diags = compile([[
module ji1-symof
  version: 1.0
engine-config:
  entry-scene: s
state items/{i}: Int(0, 9)  max: 4
fn give-item i: SymbolOf(items):
  set! items/{i} 5
scene s:
  * Done -> s
]])
    assert.equal(0, #diags.errors)
    assert.equal(0, #warnings_with_code(diags, "WRITE_UNTYPED_VAR"))
  end)

  it("named alias for SymbolOf resolves through the alias chain", function()
    local _, diags = compile([[
module ji1-alias
  version: 1.0
engine-config:
  entry-scene: s
type ItemId = SymbolOf(items)
state items/{i}: Int(0, 9)  max: 4
fn give-item i: ItemId:
  set! items/{i} 5
scene s:
  * Done -> s
]])
    assert.equal(0, #diags.errors)
    assert.equal(0, #warnings_with_code(diags, "WRITE_UNTYPED_VAR"))
  end)

  it("untyped param still emits WRITE_UNTYPED_VAR (regression guard)", function()
    local _, diags = compile([[
module ji1-untyped
  version: 1.0
engine-config:
  entry-scene: s
state items/{i}: Int(0, 9)  max: 4
fn give-item i:
  set! items/{i} 5
scene s:
  * Done -> s
]])
    assert.equal(1, #warnings_with_code(diags, "WRITE_UNTYPED_VAR"))
  end)

  it("mixed bare + typed params: typed silences, untyped still warns", function()
    local _, diags = compile([[
module ji1-mixed
  version: 1.0
engine-config:
  entry-scene: s
state items/{i}: Int(0, 9)  max: 4
state things/{t}: Bool  max: 4
fn touch i: SymbolOf(items) t:
  set! items/{i} 1
  set! things/{t} true
scene s:
  * Done -> s
]])
    local ws = warnings_with_code(diags, "WRITE_UNTYPED_VAR")
    assert.equal(1, #ws)
    assert.truthy(ws[1].message:find("'{t}'"),
      "expected warning to be about 't', not 'i'")
  end)

  it("plain Symbol-typed param does NOT silence (must be SymbolOf)", function()
    local _, diags = compile([[
module ji1-bare-sym
  version: 1.0
engine-config:
  entry-scene: s
state world/{k}: Int(0, 9)  max: 4
fn writer k: Symbol:
  set! world/{k} 5
scene s:
  * Done -> s
]])
    assert.equal(1, #warnings_with_code(diags, "WRITE_UNTYPED_VAR"))
  end)

  -- ── Runtime behaviour ───────────────────────────────────────────────────────

  it("typed-param fn collapses N near-identical fns end-to-end", function()
    local eng = make_engine([[
module ji1-spell
  version: 1.0
engine-config:
  entry-scene: shop

type SpellKind = fireball | ice-shard | heal-beam

type SpellRecord:
  mana-cost: Int(0, 50) = 20
  cast: Bool = false

state player/mana: Int(0, 100) = 80
state world/last-cast: String = ""

state spells/{spell}: SpellRecord  max: 8

fn init-spells:
  spawn! spells `fireball   SpellRecord(mana-cost: 20, cast: false)
  spawn! spells `ice-shard  SpellRecord(mana-cost: 15, cast: false)
  spawn! spells `heal-beam  SpellRecord(mana-cost: 25, cast: false)

fn cast-spell s: SymbolOf(spells):
  dec! player/mana spells/{s}/mana-cost
  set! spells/{s}/cast true
  set! world/last-cast (str "cast " s)

scene init:
  Welcome.
  * Begin
    init-spells
    -> shop

scene shop:
  Mana: {player/mana}.
  for s in SpellKind:
    * Cast {s} ({spells/{s}/mana-cost})
      cast-spell s
      -> shop
]])
    -- Start at "init" and click Begin to populate spells, then route to shop.
    local _, choices = eng:render_scene("init")
    eng:do_choice("init", 1)  -- Begin
    -- Now choose ice-shard (index 2 in shop scene).
    local _, ch = eng:render_scene("shop")
    -- Three for-loop choices in SpellKind order: fireball, ice-shard, heal-beam.
    assert.equal(3, #ch)
    eng:do_choice("shop", 2)
    assert.equal(65, eng._state:get("player/mana"))
    assert.equal(true, eng._state:get("spells/ice-shard/cast"))
    assert.equal("cast ice-shard", eng._state:get("world/last-cast"))
  end)

end)

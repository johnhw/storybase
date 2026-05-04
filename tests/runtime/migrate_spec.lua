-- tests/runtime/migrate_spec.lua
-- Tests for runtime/migrate.lua: schema migration operations.
--
-- Run with:  busted tests/

local migrate_mod  = require("runtime.migrate")
local compiler_mod = require("compiler.compiler")
local state_mod    = require("runtime.state")
local log_mod      = require("runtime.log")

local function compile(src)
  local result, diags = compiler_mod.compile(src, "test.sb")
  local errors = {}
  for _, d in ipairs(diags or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return result, errors
end

--- Build a fresh state store with the given cache values already set.
local function make_store(cache_values, schema)
  local l = log_mod.new()
  local s = state_mod.new(schema or {}, l)
  for k, v in pairs(cache_values or {}) do
    s._cache[k] = v
  end
  return s
end

-- ============================================================
-- rename
-- ============================================================

describe("migration rename", function()
  it("transfers value from old path to new path", function()
    local cache = { ["player/hp"] = 75 }
    local migrations = {
      { from_ver = 1, to_ver = 2, ops = {
          { op = "rename", old_path = "player/hp", new_path = "player/health" }
      }}
    }
    local diags = migrate_mod.migrate(cache, migrations, 1, 2, nil)
    assert.equals(0, #(diags.errors or {}))
    assert.is_nil(cache["player/hp"])
    assert.equals(75, cache["player/health"])
  end)

  it("is a no-op when the old path does not exist", function()
    local cache = { ["player/gold"] = 50 }
    local migrations = {
      { from_ver = 1, to_ver = 2, ops = {
          { op = "rename", old_path = "player/hp", new_path = "player/health" }
      }}
    }
    local diags = migrate_mod.migrate(cache, migrations, 1, 2, nil)
    assert.equals(0, #(diags.errors or {}))
    assert.is_nil(cache["player/health"])
    assert.equals(50, cache["player/gold"])
  end)
end)

-- ============================================================
-- drop
-- ============================================================

describe("migration drop", function()
  it("removes the specified path from cache", function()
    local cache = { ["player/notes"] = "some text", ["player/gold"] = 100 }
    local migrations = {
      { from_ver = 1, to_ver = 2, ops = {
          { op = "drop", path = "player/notes" }
      }}
    }
    local diags = migrate_mod.migrate(cache, migrations, 1, 2, nil)
    assert.equals(0, #(diags.errors or {}))
    assert.is_nil(cache["player/notes"])
    assert.equals(100, cache["player/gold"])
  end)
end)

-- ============================================================
-- add
-- ============================================================

describe("migration add", function()
  it("adds a new path when it does not already exist", function()
    local src = [[
module t
  version: 1.0
schema-version: 2
engine-config:
  entry-scene: main

state world:
  gold: Int(0,999) = 0

migration 1 -> 2:
  add world/mana = 50

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    assert.equals(1, #gt.migrations)

    local cache = { ["world/gold"] = 100 }
    local diags = migrate_mod.migrate(cache, gt.migrations, 1, 2, gt)
    assert.equals(0, #(diags.errors or {}))
    assert.equals(50, cache["world/mana"])
    assert.equals(100, cache["world/gold"])
  end)

  it("does not overwrite an existing path", function()
    local src = [[
module t
  version: 1.0
schema-version: 2
engine-config:
  entry-scene: main

state world:
  mana: Int(0,999) = 0

migration 1 -> 2:
  add world/mana = 50

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local cache = { ["world/mana"] = 99 }
    local diags = migrate_mod.migrate(cache, gt.migrations, 1, 2, gt)
    assert.equals(0, #(diags.errors or {}))
    -- value should NOT be overwritten
    assert.equals(99, cache["world/mana"])
  end)
end)

-- ============================================================
-- rename-enum
-- ============================================================

describe("migration rename-enum", function()
  it("renames matching enum values in the cache", function()
    local cache = { ["player/class"] = "fighter", ["world/phase"] = "intro" }
    local migrations = {
      { from_ver = 1, to_ver = 2, ops = {
          { op = "rename-enum", path = "player/class", old_sym = "fighter", new_sym = "warrior" }
      }}
    }
    local diags = migrate_mod.migrate(cache, migrations, 1, 2, nil)
    assert.equals(0, #(diags.errors or {}))
    assert.equals("warrior", cache["player/class"])
    assert.equals("intro",   cache["world/phase"])  -- untouched
  end)
end)

-- ============================================================
-- version ordering and chain
-- ============================================================

describe("migration chain", function()
  it("applies multiple migrations in order", function()
    local cache = { ["player/hp"] = 75, ["player/notes"] = "old" }
    local migrations = {
      { from_ver = 1, to_ver = 2, ops = {
          { op = "rename", old_path = "player/hp", new_path = "player/health" }
      }},
      { from_ver = 2, to_ver = 3, ops = {
          { op = "drop", path = "player/notes" }
      }},
    }
    local diags = migrate_mod.migrate(cache, migrations, 1, 3, nil)
    assert.equals(0, #(diags.errors or {}))
    assert.is_nil(cache["player/hp"])
    assert.is_nil(cache["player/notes"])
    assert.equals(75, cache["player/health"])
  end)

  it("errors when an intermediate migration is missing", function()
    local cache = { ["player/hp"] = 75 }
    local migrations = {
      -- Only 1→2, missing 2→3
      { from_ver = 1, to_ver = 2, ops = {} },
    }
    local diags = migrate_mod.migrate(cache, migrations, 1, 3, nil)
    assert.is_true(#(diags.errors or {}) > 0)
  end)

  it("is a no-op when save version matches game version", function()
    local cache = { ["player/hp"] = 75 }
    local migrations = {
      { from_ver = 1, to_ver = 2, ops = {
          { op = "drop", path = "player/hp" }
      }},
    }
    local diags = migrate_mod.migrate(cache, migrations, 2, 2, nil)
    assert.equals(0, #(diags.errors or {}))
    assert.equals(75, cache["player/hp"])  -- untouched
  end)

  it("errors when save is ahead of game version", function()
    local cache = {}
    local diags = migrate_mod.migrate(cache, {}, 5, 3, nil)
    assert.is_true(#(diags.errors or {}) > 0)
  end)
end)

-- ============================================================
-- Migration parsing (parser + codegen round-trip)
-- ============================================================

describe("migration parsing", function()
  it("parses migration block and emits it in game_table", function()
    local src = [[
module t
  version: 1.0
schema-version: 3
engine-config:
  entry-scene: main

state world:
  gold: Int(0,999) = 0

migration 1 -> 2:
  rename world/gold -> world/treasury
  add world/mana = 0

migration 2 -> 3:
  drop world/mana

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)
    assert.equals(2, #gt.migrations)
    assert.equals(1, gt.migrations[1].from_ver)
    assert.equals(2, gt.migrations[1].to_ver)
    assert.equals(2, #gt.migrations[1].ops)
    assert.equals("rename", gt.migrations[1].ops[1].op)
    assert.equals("add",    gt.migrations[1].ops[2].op)
    assert.equals(2, gt.migrations[2].from_ver)
    assert.equals("drop",   gt.migrations[2].ops[1].op)
  end)
end)

-- ============================================================
-- transform
-- ============================================================

describe("migration transform", function()
  it("applies a scalar transform using the `old' variable", function()
    local src = [[
module t
  version: 1.0
schema-version: 2
engine-config:
  entry-scene: main

state world:
  level: Int(0, 999) = 1

migration 1 -> 2:
  transform world/level:
    fn old: old + 10

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local cache = { ["world/level"] = 5 }
    local diags = migrate_mod.migrate(cache, gt.migrations, 1, 2, gt)
    assert.equals(0, #(diags.errors or {}))
    assert.equals(15, cache["world/level"])
  end)

  it("applies wildcard transform to all family members", function()
    local src = [[
module t
  version: 1.0
schema-version: 2
engine-config:
  entry-scene: main

type Npc:
  health: Int(0, 100) = 50

state npcs/{npc}: Npc  max: 4

migration 1 -> 2:
  transform npcs/*/health:
    fn old: old * 2

scene main:
  * Go
    -> main
]]
    local gt, errs = compile(src)
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local cache = {
      ["npcs/guard/health"]      = 30,
      ["npcs/blacksmith/health"] = 50,
    }
    local diags = migrate_mod.migrate(cache, gt.migrations, 1, 2, gt)
    assert.equals(0, #(diags.errors or {}))
    assert.equals(60, cache["npcs/guard/health"])
    assert.equals(100, cache["npcs/blacksmith/health"])
  end)
end)

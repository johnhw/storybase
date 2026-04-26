-- tests/runtime/migrate_demo14_spec.lua
-- Integration test for demo14's full 1->2->3->4 migration chain.
--
-- Exercises all four migration operation kinds in a single chain:
--   1->2: add   (world/treasury-notes = "")
--   2->3: rename (census-count -> population) + drop (treasury-notes)
--   3->4: transform (population * 100) + rename-enum ('at-war -> 'warring)
--
-- Run with:  busted tests/

local migrate_mod  = require("runtime.migrate")
local compiler_mod = require("compiler.compiler")

local function compile_demo14()
  local result, diags = compiler_mod.compile_file("demos/demo14_kingdoms_records.sb")
  local errors = {}
  for _, d in ipairs(diags and diags.errors or {}) do
    if d.level == "error" then errors[#errors + 1] = d end
  end
  return result, errors
end

describe("demo14 migration chain (1->2->3->4)", function()

  it("compiles demo14 without errors", function()
    local gt, errs = compile_demo14()
    assert.equals(0, #errs, errs[1] and errs[1].message)
    assert.is_not_nil(gt)
  end)

  it("has exactly 3 migration blocks (1->2, 2->3, 3->4)", function()
    local gt, errs = compile_demo14()
    assert.equals(0, #errs, errs[1] and errs[1].message)
    assert.equals(3, #gt.migrations)
    assert.equals(1, gt.migrations[1].from_ver)
    assert.equals(2, gt.migrations[1].to_ver)
    assert.equals(2, gt.migrations[2].from_ver)
    assert.equals(3, gt.migrations[2].to_ver)
    assert.equals(3, gt.migrations[3].from_ver)
    assert.equals(4, gt.migrations[3].to_ver)
  end)

  it("migration 1->2 adds world/treasury-notes = empty string", function()
    local gt, errs = compile_demo14()
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local cache = {
      ["world/year"]           = 1200,
      ["world/census-count"]   = 800,
      ["world/kingdom-status"] = "peaceful",
      ["world/trade-surplus"]  = 150,
      ["world/reports-filed"]  = 0,
    }
    local diags = migrate_mod.migrate(cache, gt.migrations, 1, 2, gt)
    assert.equals(0, #(diags.errors or {}))
    -- treasury-notes should have been added
    assert.equals("", cache["world/treasury-notes"])
    -- original fields unchanged
    assert.equals(800, cache["world/census-count"])
    assert.equals("peaceful", cache["world/kingdom-status"])
  end)

  it("migration 2->3 renames census-count to population and drops treasury-notes", function()
    local gt, errs = compile_demo14()
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local cache = {
      ["world/year"]              = 1200,
      ["world/census-count"]      = 800,
      ["world/kingdom-status"]    = "peaceful",
      ["world/trade-surplus"]     = 150,
      ["world/reports-filed"]     = 0,
      ["world/treasury-notes"]    = "Some notes",
    }
    local diags = migrate_mod.migrate(cache, gt.migrations, 2, 3, gt)
    assert.equals(0, #(diags.errors or {}))
    -- renamed
    assert.is_nil(cache["world/census-count"])
    assert.equals(800, cache["world/population"])
    -- dropped
    assert.is_nil(cache["world/treasury-notes"])
  end)

  it("migration 3->4 scales population by 100 and renames 'at-war to 'warring", function()
    local gt, errs = compile_demo14()
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local cache = {
      ["world/year"]           = 1200,
      ["world/population"]     = 800,
      ["world/kingdom-status"] = "at-war",
      ["world/trade-surplus"]  = 50,
      ["world/reports-filed"]  = 2,
    }
    local diags = migrate_mod.migrate(cache, gt.migrations, 3, 4, gt)
    assert.equals(0, #(diags.errors or {}))
    -- transform
    assert.equals(80000, cache["world/population"])
    -- rename-enum
    assert.equals("warring", cache["world/kingdom-status"])
  end)

  it("full chain 1->4: census-count=800, at-war produces population=80000, warring", function()
    local gt, errs = compile_demo14()
    assert.equals(0, #errs, errs[1] and errs[1].message)

    -- Simulate a v1 save cache
    local cache = {
      ["world/year"]           = 1215,
      ["world/census-count"]   = 800,
      ["world/kingdom-status"] = "at-war",
      ["world/trade-surplus"]  = 75,
      ["world/reports-filed"]  = 15,
    }
    local diags = migrate_mod.migrate(cache, gt.migrations, 1, 4, gt)
    assert.equals(0, #(diags.errors or {}))

    -- census-count gone, population = 800 * 100 = 80000
    assert.is_nil(cache["world/census-count"])
    assert.equals(80000, cache["world/population"])
    -- at-war renamed to warring
    assert.equals("warring", cache["world/kingdom-status"])
    -- treasury-notes added in 1->2 then dropped in 2->3
    assert.is_nil(cache["world/treasury-notes"])
    -- other fields preserved
    assert.equals(1215, cache["world/year"])
    assert.equals(75,   cache["world/trade-surplus"])
    assert.equals(15,   cache["world/reports-filed"])
  end)

  it("full chain 1->4: peaceful status is not renamed", function()
    local gt, errs = compile_demo14()
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local cache = {
      ["world/year"]           = 1200,
      ["world/census-count"]   = 500,
      ["world/kingdom-status"] = "peaceful",
      ["world/trade-surplus"]  = 200,
      ["world/reports-filed"]  = 0,
    }
    local diags = migrate_mod.migrate(cache, gt.migrations, 1, 4, gt)
    assert.equals(0, #(diags.errors or {}))
    -- peaceful should not be changed by rename-enum
    assert.equals("peaceful", cache["world/kingdom-status"])
    assert.equals(50000, cache["world/population"])
  end)

  it("already-at-v4 cache is not modified", function()
    local gt, errs = compile_demo14()
    assert.equals(0, #errs, errs[1] and errs[1].message)

    local cache = {
      ["world/year"]           = 1210,
      ["world/population"]     = 80000,
      ["world/kingdom-status"] = "prosperous",
      ["world/trade-surplus"]  = 300,
      ["world/reports-filed"]  = 10,
    }
    local diags = migrate_mod.migrate(cache, gt.migrations, 4, 4, gt)
    assert.equals(0, #(diags.errors or {}))
    -- nothing should change
    assert.equals(80000,       cache["world/population"])
    assert.equals("prosperous",cache["world/kingdom-status"])
  end)

end)

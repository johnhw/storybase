-- tests/ui/integration/m8_widgets_spec.lua
--
-- §M8 acceptance harness: boots a real kernel, attaches a buffer-backed
-- curses driver, and verifies the schema-driven discovery + reactive
-- repaint flow for each widget kind shipped in M8 (stat, toggle, text,
-- inventory, choice). Mirrors the structure of statbar_reactive_spec but
-- focuses on the new widget vocabulary.

local kernel_mod  = require("ui.kernel")
local session_mod = require("tests.ui.helpers.driver_session")

local function stub_engine(schema, panels)
  return { _game = { schema = schema, ui_panels = panels or {} } }
end

local empty_scene = { narration = {}, choices = {} }

-- ── stat widget ────────────────────────────────────────────────────

describe("M8 integration: stat widget", function()
  it("discovers a stat from a state ui: block", function()
    local schema = {
      states = {
        { kind = "scalar", path = "player/gold",
          type_desc = { tag = "int" },
          ui = { kind = "stat", label = "Gold" } },
      },
    }
    local k = kernel_mod.new(stub_engine(schema))
    k:emit("mutation", { path = "player/gold", new = 42 })

    local s = session_mod.new({ rows = 6, cols = 40 })
    s:driver():attach(k)
    s:render(empty_scene)

    local rows = s:snapshot_rows()
    assert.is_truthy(rows[1]:find("^Gold: 42"))
  end)

  it("repaints reactively on mutation of the bound path", function()
    local schema = {
      states = {
        { kind = "scalar", path = "g", type_desc = { tag = "int" },
          ui = { kind = "stat", label = "G" } },
      },
    }
    local k = kernel_mod.new(stub_engine(schema))
    k:emit("mutation", { path = "g", new = 1 })

    local s = session_mod.new({ rows = 6, cols = 20, frame_history = true })
    s:driver():attach(k)
    s:render(empty_scene)
    s:reset_history()

    k:emit("mutation", { path = "g", new = 2 })
    local hist = s:dirty_history()
    assert.equal(1, #hist)
    for _, r in ipairs(hist[1]) do
      assert.equal(0, r.y, "stat repaint should land on row 0")
    end
    local snap = s:snapshot_history()
    assert.is_truthy(snap[1]:find("G: 2"))
  end)
end)

-- ── toggle widget ──────────────────────────────────────────────────

describe("M8 integration: toggle widget", function()
  it("renders [x] / [ ] for the bound bool", function()
    local schema = {
      states = {
        { kind = "scalar", path = "flag", type_desc = { tag = "bool" },
          ui = { kind = "toggle", label = "Flag" } },
      },
    }
    local k = kernel_mod.new(stub_engine(schema))
    k:emit("mutation", { path = "flag", new = true })

    local s = session_mod.new({ rows = 6, cols = 20 })
    s:driver():attach(k)
    s:render(empty_scene)
    assert.is_truthy(s:snapshot_rows()[1]:find("^%[x%] Flag"))

    k:emit("mutation", { path = "flag", new = false })
    assert.is_truthy(s:snapshot_rows()[1]:find("^%[ %] Flag"))
  end)
end)

-- ── text widget ────────────────────────────────────────────────────

describe("M8 integration: text widget", function()
  it("substitutes a path placeholder from kernel state", function()
    local schema = {
      states = {
        { kind = "scalar", path = "g", type_desc = { tag = "int" } },
      },
    }
    local panels = {
      { name = "hud", children = {
          { kind = "text", arg = "Gold: {g}" },
        } },
    }
    local k = kernel_mod.new(stub_engine(schema, panels))
    k:emit("mutation", { path = "g", new = 99 })

    local s = session_mod.new({ rows = 6, cols = 20 })
    s:driver():attach(k)
    s:render(empty_scene)
    assert.is_truthy(s:snapshot_rows()[1]:find("^Gold: 99"))
  end)

  it("subscribes to every referenced path", function()
    local schema = {
      states = {
        { kind = "scalar", path = "a", type_desc = { tag = "int" } },
        { kind = "scalar", path = "b", type_desc = { tag = "int" } },
      },
    }
    local panels = {
      { name = "hud", children = {
          { kind = "text", arg = "{a}/{b}" },
        } },
    }
    local k = kernel_mod.new(stub_engine(schema, panels))
    k:emit("mutation", { path = "a", new = 1 })
    k:emit("mutation", { path = "b", new = 2 })

    local s = session_mod.new({ rows = 6, cols = 20, frame_history = true })
    s:driver():attach(k)
    s:render(empty_scene)
    s:reset_history()

    -- A mutation on either bound path should fire a repaint.
    k:emit("mutation", { path = "a", new = 5 })
    assert.equal(1, #s:dirty_history())
    k:emit("mutation", { path = "b", new = 6 })
    assert.equal(2, #s:dirty_history())
  end)
end)

-- ── inventory widget ───────────────────────────────────────────────

describe("M8 integration: inventory widget", function()
  it("renders the items of a Set/List/UList state path", function()
    local schema = {
      states = {
        { kind = "scalar", path = "inv",
          type_desc = { tag = "list" },
          ui = { kind = "inventory", label = "Pack", ["max-rows"] = 3 } },
      },
    }
    local k = kernel_mod.new(stub_engine(schema))
    k:emit("mutation", { path = "inv", new = { "sword", "shield" } })

    local s = session_mod.new({ rows = 8, cols = 20 })
    s:driver():attach(k)
    s:render(empty_scene)

    local rows = s:snapshot_rows()
    assert.is_truthy(rows[1]:find("^Pack"))
    assert.is_truthy(rows[2]:find("^%- sword"))
    assert.is_truthy(rows[3]:find("^%- shield"))
  end)

  it("repaints reactively when the bound list changes", function()
    local schema = {
      states = {
        { kind = "scalar", path = "inv", type_desc = { tag = "list" },
          ui = { kind = "inventory", label = "Pack", ["max-rows"] = 2 } },
      },
    }
    local k = kernel_mod.new(stub_engine(schema))
    k:emit("mutation", { path = "inv", new = { "a" } })

    local s = session_mod.new({ rows = 8, cols = 20, frame_history = true })
    s:driver():attach(k)
    s:render(empty_scene)
    s:reset_history()

    k:emit("mutation", { path = "inv", new = { "a", "b" } })
    assert.equal(1, #s:dirty_history())
    assert.is_truthy(s:snapshot_history()[1]:find("%- b"))
  end)
end)

-- ── choice widget ──────────────────────────────────────────────────

describe("M8 integration: choice widget", function()
  it("renders one (*)/( ) marker per enum value", function()
    local schema = {
      states = {
        { kind = "scalar", path = "mood",
          type_desc = { tag = "enum", values = { "happy", "sad" } },
          ui = { kind = "choice", label = "Mood" } },
      },
      types = {},
    }
    local k = kernel_mod.new(stub_engine(schema))
    k:emit("mutation", { path = "mood", new = "sad" })

    local s = session_mod.new({ rows = 8, cols = 20 })
    s:driver():attach(k)
    s:render(empty_scene)

    local rows = s:snapshot_rows()
    -- row 0 = label, rows 1..2 = options.
    assert.is_truthy(rows[1]:find("^Mood"))
    assert.is_truthy(rows[2]:find("^%( %) happy"))
    assert.is_truthy(rows[3]:find("^%(%*%) sad"))
  end)
end)

-- ── layout interaction ─────────────────────────────────────────────

describe("M8 integration: widget strip layout", function()
  it("stacks multiple widgets top-to-bottom with stable y coords",
  function()
    local schema = {
      states = {
        { kind = "scalar", path = "g", type_desc = { tag = "int" },
          ui = { kind = "stat", label = "G" } },
        { kind = "scalar", path = "f", type_desc = { tag = "bool" },
          ui = { kind = "toggle", label = "F" } },
      },
    }
    local k = kernel_mod.new(stub_engine(schema))
    k:emit("mutation", { path = "g", new = 1 })
    k:emit("mutation", { path = "f", new = true })

    local s = session_mod.new({ rows = 8, cols = 20 })
    s:driver():attach(k)
    s:render(empty_scene)

    local rows = s:snapshot_rows()
    assert.is_truthy(rows[1]:find("^G: 1"))
    assert.is_truthy(rows[2]:find("^%[x%] F"))
  end)

  it("an inventory + a stat below it both repaint independently",
  function()
    local schema = {
      states = {
        { kind = "scalar", path = "inv", type_desc = { tag = "list" },
          ui = { kind = "inventory", label = "Pack", ["max-rows"] = 2 } },
        { kind = "scalar", path = "g", type_desc = { tag = "int" },
          ui = { kind = "stat", label = "G" } },
      },
    }
    local k = kernel_mod.new(stub_engine(schema))
    k:emit("mutation", { path = "inv", new = { "a" } })
    k:emit("mutation", { path = "g", new = 1 })

    local s = session_mod.new({ rows = 10, cols = 20, frame_history = true })
    s:driver():attach(k)
    s:render(empty_scene)
    s:reset_history()

    -- Inventory uses 3 rows (label + 2 items), so the stat sits on row 3.
    local rows0 = s:snapshot_rows()
    assert.is_truthy(rows0[1]:find("^Pack"))
    assert.is_truthy(rows0[4]:find("^G: 1"))

    -- A mutation on g shouldn't move the inventory rows.
    k:emit("mutation", { path = "g", new = 7 })
    local rows1 = s:snapshot_rows()
    assert.is_truthy(rows1[1]:find("^Pack"))
    assert.is_truthy(rows1[4]:find("^G: 7"))
  end)
end)

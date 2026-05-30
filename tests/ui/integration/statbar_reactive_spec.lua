-- tests/ui/integration/statbar_reactive_spec.lua
--
-- §M5 integration fixture (ui_idea.md §9.1 item 3): boots a real
-- presentation kernel, attaches a buffer-backed curses driver, scripts
-- mutation events through `kernel:emit`, and asserts the resulting
-- snapshot + dirty-rect log.
--
-- The acceptance criterion for M5 is precisely:
--   "a mutation on the bound path repaints *only* the stat-bar window."
-- That assertion is what this file proves end-to-end against the
-- driver→kernel seam without invoking ncurses or the full engine.

local kernel_mod  = require("ui.kernel")
local session_mod = require("tests.ui.helpers.driver_session")

--- Build a minimal stub engine that the kernel can read schema /
--- bindings from. The kernel's hook installation paths (attach() /
--- _install_hooks / _seed_state_cache) only fire when we call
--- `kernel:attach(engine)`; constructing the kernel with an engine but
--- never calling attach() lets the schema/bindings queries succeed
--- without dragging in state/log/scheduler.
---@param schema  table
---@param panels  table?
---@return table  stub engine
local function stub_engine(schema, panels)
  return {
    _game = { schema = schema, ui_panels = panels or {} },
  }
end

--- Standard schema used across these specs: one bounded-int stat plus a
--- second one that uses a `ui-panel` child reference instead of a
--- state-decl `ui:` block.
local function build_schema()
  return {
    states = {
      { kind = "scalar", path = "player/hp",
        type_desc = { tag = "int", min = 0, max = 10 },
        ui = { kind = "stat-bar", label = "Health" } },
      { kind = "scalar", path = "player/mana",
        type_desc = { tag = "int", min = 0, max = 20 } },
      { kind = "scalar", path = "player/gold",
        type_desc = { tag = "int", min = 0, max = 1000 } },
    },
  }
end

local function build_panels()
  return {
    { name = "status", layout = "vstack",
      children = {
        { kind = "stat-bar", arg = "player/mana" },
      } },
  }
end

-- Render a no-narration "ready" frame so the screen has a baseline
-- against which subsequent mutations produce diff'd rects.
local empty_scene = { narration = {}, choices = {} }

-- ── Discovery ──────────────────────────────────────────────────────

describe("M5 integration: widget discovery from schema + panels", function()
  it("discovers a stat-bar from a state ui: block", function()
    local k = kernel_mod.new(stub_engine(build_schema()))
    local s = session_mod.new({ rows = 8, cols = 40 })
    s:driver():attach(k)
    local widgets = s:driver()._widgets
    assert.equal(1, #widgets)
    assert.equal("player/hp", widgets[1].path)
    assert.equal("Health", widgets[1].label)
  end)

  it("discovers a stat-bar referenced from a ui-panel child", function()
    local k = kernel_mod.new(stub_engine(build_schema(), build_panels()))
    local s = session_mod.new({ rows = 8, cols = 40 })
    s:driver():attach(k)
    local widgets = s:driver()._widgets
    -- player/hp (from state ui:) + player/mana (from panel child).
    assert.equal(2, #widgets)
    local paths = {}
    for _, w in ipairs(widgets) do paths[#paths + 1] = w.path end
    table.sort(paths)
    assert.are.same({ "player/hp", "player/mana" }, paths)
  end)

  it("a state referenced from both state-ui and panel child renders once", function()
    local schema = build_schema()
    -- Manually add player/hp to a panel too.
    local panels = {
      { name = "status", children = {
          { kind = "stat-bar", arg = "player/hp" },
          { kind = "stat-bar", arg = "player/mana" },
        } },
    }
    local k = kernel_mod.new(stub_engine(schema, panels))
    local s = session_mod.new({ rows = 8, cols = 40 })
    s:driver():attach(k)
    -- 2 widgets: player/hp (state-decl, takes precedence) + player/mana.
    assert.equal(2, #s:driver()._widgets)
  end)

  it("skips widget kinds the driver doesn't implement yet", function()
    local schema = {
      states = {
        { kind = "scalar", path = "player/name",
          type_desc = { tag = "string" },
          ui = { kind = "input" } },  -- M7 widget, not M5
      },
    }
    local k = kernel_mod.new(stub_engine(schema))
    local s = session_mod.new({ rows = 8, cols = 40 })
    s:driver():attach(k)
    assert.equal(0, #s:driver()._widgets)
  end)
end)

-- ── Initial paint ──────────────────────────────────────────────────

describe("M5 integration: initial paint of widgets", function()
  it("renders the stat-bar with the initial value from the kernel cache",
  function()
    local k = kernel_mod.new(stub_engine(build_schema()))
    -- Seed initial value via a mutation event (the kernel mirrors the
    -- value into its state cache before fanning out).
    k:emit("mutation", { path = "player/hp", new = 7 })

    local s = session_mod.new({ rows = 8, cols = 40 })
    s:driver():attach(k)
    s:render(empty_scene)

    local rows = s:snapshot_rows()
    -- Row 0 = stat-bar; row 1 = narration; etc.
    assert.is_truthy(rows[1]:find("Health: 7/10"))
    assert.is_truthy(rows[1]:find("%["))
    assert.is_truthy(rows[1]:find("%]"))
  end)

  it("shows a fully-empty bar when value = 0", function()
    local k = kernel_mod.new(stub_engine(build_schema()))
    k:emit("mutation", { path = "player/hp", new = 0 })
    local s = session_mod.new({ rows = 6, cols = 40 })
    s:driver():attach(k)
    s:render(empty_scene)
    local row0 = s:snapshot_rows()[1]
    assert.is_truthy(row0:find("Health: 0/10"))
    -- No `#` glyphs at all when empty.
    assert.is_nil(row0:find("#"))
  end)

  it("shows a fully-filled bar when value = max", function()
    local k = kernel_mod.new(stub_engine(build_schema()))
    k:emit("mutation", { path = "player/hp", new = 10 })
    local s = session_mod.new({ rows = 6, cols = 40 })
    s:driver():attach(k)
    s:render(empty_scene)
    local row0 = s:snapshot_rows()[1]
    assert.is_truthy(row0:find("Health: 10/10"))
    -- The empty trailing region inside [..] should not contain `#`s
    -- right before `]`; here every inner cell is `#`.
    local inside = row0:match("%[(.-)%]")
    assert.is_truthy(inside)
    assert.is_nil(inside:find(" "))  -- no spaces among the fill cells
  end)
end)

-- ── Reactive repaint (the M5 acceptance criterion) ─────────────────

describe("M5 integration: mutation repaints only the widget window",
function()
  it("a single mutation produces dirty rects covering only row 0",
  function()
    local k = kernel_mod.new(stub_engine(build_schema()))
    k:emit("mutation", { path = "player/hp", new = 10 })

    local s = session_mod.new({
      rows = 8, cols = 40, frame_history = true,
    })
    s:driver():attach(k)
    -- Initial full paint.
    s:render(empty_scene)
    -- Slice history so we observe just the post-mutation flush.
    s:reset_history()

    -- Trigger a mutation. The driver's subscription should fire and
    -- recompose; everything outside the stat-bar should diff clean.
    k:emit("mutation", { path = "player/hp", new = 6 })

    local hist = s:dirty_history()
    assert.equal(1, #hist, "exactly one flush should follow the mutation")
    local rects = hist[1]
    assert.is_true(#rects > 0, "the mutation must produce at least one rect")
    for _, r in ipairs(rects) do
      assert.equal(0, r.y,
        "dirty rect y=" .. tostring(r.y) ..
        " — expected all rects on the stat-bar row (y=0)")
    end
  end)

  it("two mutations produce two flushes and the bar shrinks", function()
    local k = kernel_mod.new(stub_engine(build_schema()))
    k:emit("mutation", { path = "player/hp", new = 10 })

    local s = session_mod.new({
      rows = 8, cols = 40, frame_history = true,
    })
    s:driver():attach(k)
    s:render(empty_scene)
    s:reset_history()

    k:emit("mutation", { path = "player/hp", new = 7 })
    k:emit("mutation", { path = "player/hp", new = 4 })

    local hist = s:dirty_history()
    assert.equal(2, #hist)
    local snap_hist = s:snapshot_history()
    assert.is_truthy(snap_hist[1]:find("Health: 7/10"))
    assert.is_truthy(snap_hist[2]:find("Health: 4/10"))
    -- The number of `#` glyphs in the bar strictly decreases.
    local hashes1 = select(2, snap_hist[1]:gsub("#", ""))
    local hashes2 = select(2, snap_hist[2]:gsub("#", ""))
    assert.is_true(hashes1 > hashes2,
      "bar should shrink: was " .. hashes1 .. " then " .. hashes2)
  end)

  it("a mutation on an unbound path does not trigger a repaint", function()
    local k = kernel_mod.new(stub_engine(build_schema()))
    k:emit("mutation", { path = "player/hp", new = 8 })

    local s = session_mod.new({
      rows = 8, cols = 40, frame_history = true,
    })
    s:driver():attach(k)
    s:render(empty_scene)
    s:reset_history()

    k:emit("mutation", { path = "player/gold", new = 42 })

    -- gold has no `ui:` block and no panel reference, so it is unbound.
    -- The driver's subscription must filter it out — no flush at all.
    assert.equal(0, #s:dirty_history())
  end)

  it("a non-mutation event does not trigger a repaint", function()
    local k = kernel_mod.new(stub_engine(build_schema()))
    k:emit("mutation", { path = "player/hp", new = 8 })

    local s = session_mod.new({
      rows = 8, cols = 40, frame_history = true,
    })
    s:driver():attach(k)
    s:render(empty_scene)
    s:reset_history()

    k:emit("scene-change", { from = "town", to = "shop" })
    assert.equal(0, #s:dirty_history())
  end)
end)

-- ── Lifecycle ──────────────────────────────────────────────────────

describe("M5 integration: lifecycle", function()
  it("detach unsubscribes; later mutations do not repaint", function()
    local k = kernel_mod.new(stub_engine(build_schema()))
    k:emit("mutation", { path = "player/hp", new = 8 })

    local s = session_mod.new({
      rows = 6, cols = 40, frame_history = true,
    })
    s:driver():attach(k)
    s:render(empty_scene)
    s:driver():detach()
    s:reset_history()

    -- Without a subscriber, this should fan out to nobody and the
    -- backend grid stays untouched.
    k:emit("mutation", { path = "player/hp", new = 1 })
    assert.equal(0, #s:dirty_history())
  end)

  it("a driver with no widgets is harmless on attach", function()
    local schema = {
      states = {
        { kind = "scalar", path = "player/hp",
          type_desc = { tag = "int", min = 0, max = 10 } },  -- no ui:
      },
    }
    local k = kernel_mod.new(stub_engine(schema))
    local s = session_mod.new({ rows = 6, cols = 40 })
    assert.has_no_errors(function() s:driver():attach(k) end)
    assert.equal(0, #s:driver()._widgets)
  end)
end)

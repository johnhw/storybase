-- tests/ui/driver_session_spec.lua
--
-- Tests for the §M5 session-DSL helper that lifts the boilerplate
-- around `script_keys → render → prompt → snapshot`. Covers the
-- session surface and the new frame-history opt-in on the buffer
-- backend.

local session_mod = require("tests.ui.helpers.driver_session")

local choices = {
  { index = 1, label = "Pick A" },
  { index = 2, label = "Pick B" },
}
local empty_scene = { narration = {}, choices = {} }

describe("driver_session: basics", function()
  it("constructs a buffer-backed driver", function()
    local s = session_mod.new({ rows = 6, cols = 30 })
    local d = s:driver()
    -- The driver should expose its backend handle as a buffer backend.
    local b = d:_backend_handle()
    assert.is_truthy(b.snapshot)
    assert.is_truthy(b.script_keys)
  end)

  it("forwards script_keys + render + choose end-to-end", function()
    local s = session_mod.new({ rows = 8, cols = 40 })
    s:render({
      narration = { { kind = "narration", text = "Hello." } },
      choices = choices,
    })
    local idx = s:choose("1", choices)
    assert.equal(1, idx)
    local snap = s:snapshot()
    assert.is_truthy(snap:find("Hello%."))
    assert.is_truthy(snap:find("1%. Pick A"))
  end)

  it("returns nil from choose on quit", function()
    local s = session_mod.new({ rows = 6, cols = 30 })
    s:render(empty_scene)
    assert.is_nil(s:choose("q", choices))
  end)

  it("snapshot_rows returns one entry per row", function()
    local s = session_mod.new({ rows = 5, cols = 20 })
    s:render(empty_scene)
    assert.equal(5, #s:snapshot_rows())
  end)
end)

describe("driver_session: frame history (opt-in)", function()
  it("returns an empty history when frame_history is off", function()
    local s = session_mod.new({ rows = 6, cols = 30 })
    s:render(empty_scene)
    assert.are.same({}, s:snapshot_history())
    assert.are.same({}, s:dirty_history())
  end)

  it("records a snapshot per flush when frame_history is on", function()
    local s = session_mod.new({
      rows = 6, cols = 30, frame_history = true,
    })
    s:render(empty_scene)  -- flush 1
    s:render(empty_scene)  -- flush 2
    assert.equal(2, #s:snapshot_history())
    assert.equal(2, #s:dirty_history())
  end)

  it("reset_history drops both buffers", function()
    local s = session_mod.new({
      rows = 6, cols = 30, frame_history = true,
    })
    s:render(empty_scene)
    s:reset_history()
    assert.equal(0, #s:snapshot_history())
    assert.equal(0, #s:dirty_history())
    s:render(empty_scene)
    assert.equal(1, #s:snapshot_history())
  end)

  it("dirty rect entries deep-copy cell tables (mutation safety)", function()
    local s = session_mod.new({
      rows = 4, cols = 10, frame_history = true,
    })
    s:render(empty_scene)
    local hist_a = s:dirty_history()
    -- A subsequent flush should not retroactively mutate the prior
    -- recorded list — the entry is a deep copy.
    s:render({
      narration = { { kind = "narration", text = "X" } },
      choices = {},
    })
    local hist_b = s:dirty_history()
    assert.equal(2, #hist_b)
    -- hist_a was a snapshot at length 1 — re-snapshot to confirm the
    -- earlier flush's rect list still has the same dimensions it had.
    assert.equal(#hist_a[1], #hist_b[1])
  end)
end)

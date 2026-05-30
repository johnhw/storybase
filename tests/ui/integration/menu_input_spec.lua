-- tests/ui/integration/menu_input_spec.lua
--
-- §M7 acceptance fixture: prove the menu and input widgets work
-- end-to-end against the driver's view + focus stacks, and that an
-- input widget submitting fires `kernel:call_fn(name, text)` as
-- specified by ui_idea.md §6:
--
--   "Free-text name entry: the driver presents an `input` widget bound
--    to fn `set-name`; on submit it calls
--    `kernel:call_fn("set-name", text)`."
--
-- The two widget specs cover construction / paint / on_key in
-- isolation; this file glues them to the driver and proves the dispatch
-- path. It uses the buffer backend (no ncurses needed) and a real
-- presentation kernel with a host-provided `set_call_fn` capture.

local kernel_mod  = require("ui.kernel")
local session_mod = require("tests.ui.helpers.driver_session")
local menu_mod    = require("cli.drivers.curses.widgets.menu")
local input_mod   = require("cli.drivers.curses.widgets.input")
local K           = require("cli.drivers.curses.keys")

--- Build a minimal stub engine the kernel can read schema/bindings
--- from. Same shape as statbar_reactive_spec — we never call attach(),
--- so no state/log/scheduler is required.
local function stub_engine()
  return { _game = { schema = { states = {} }, ui_panels = {} } }
end

-- Convenience aliases.
local Q   = string.byte("q")
local Y   = string.byte("y")
local N   = string.byte("n")
local ESC = K.ESC

-- A no-narration baseline frame so the underlying compose has
-- something to paint behind any pushed widget.
local empty_scene = { narration = {}, choices = {} }

describe("M7 integration: menu pushed onto the driver", function()
  it("Up/Down arrows navigate the menu while it owns focus", function()
    local s = session_mod.new({ rows = 14, cols = 40 })
    s:render(empty_scene)

    local m = menu_mod.new({
      title = "Game Menu",
      items = {
        { label = "Resume" },
        { label = "Settings" },
        { label = "Quit" },
      },
    })
    s:driver()._view_stack:push(m, s:driver())
    s:driver()._focus:push(m, s:driver())

    assert.equal(1, s:driver()._view_stack:depth())
    assert.equal(1, s:driver()._focus:depth())
    assert.equal(1, m:cursor())

    -- Dispatch keys directly through the focus stack — same path the
    -- driver's read loop uses.
    s:driver()._focus:dispatch(K.KEY_DOWN, s:driver())
    assert.equal(2, m:cursor())
    s:driver()._focus:dispatch(K.KEY_DOWN, s:driver())
    assert.equal(3, m:cursor())
    s:driver()._focus:dispatch(K.KEY_UP, s:driver())
    assert.equal(2, m:cursor())
  end)

  it("Enter activates the highlighted item and calls its action", function()
    local s = session_mod.new({ rows = 14, cols = 40 })
    s:render(empty_scene)

    local fired
    local m = menu_mod.new({
      items = {
        { label = "Run", action = function() fired = "run" end },
        { label = "Stop", action = function() fired = "stop" end },
      },
    })
    s:driver()._view_stack:push(m, s:driver())
    s:driver()._focus:push(m, s:driver())

    s:driver()._focus:dispatch(K.KEY_DOWN, s:driver()) -- move to "Stop"
    s:driver()._focus:dispatch(K.CR,       s:driver()) -- activate
    assert.equal("stop", fired)
  end)

  it("hotkeys jump-and-activate even when an unrelated item is highlighted", function()
    local s = session_mod.new({ rows = 14, cols = 40 })
    s:render(empty_scene)
    local fired = {}
    local m = menu_mod.new({
      items = {
        { label = "Save",  hotkey = "s",
          action = function() fired[#fired + 1] = "save"  end },
        { label = "Load",  hotkey = "l",
          action = function() fired[#fired + 1] = "load"  end },
        { label = "Quit",  hotkey = "q",
          action = function() fired[#fired + 1] = "quit"  end },
      },
    })
    s:driver()._view_stack:push(m, s:driver())
    s:driver()._focus:push(m, s:driver())

    s:driver()._focus:dispatch(string.byte("l"), s:driver())
    s:driver()._focus:dispatch(string.byte("s"), s:driver())
    s:driver()._focus:dispatch(string.byte("q"), s:driver())
    assert.same({ "load", "save", "quit" }, fired)
    assert.equal(3, m:cursor(), "cursor lands on the last-activated item")
  end)

  it("menu paints on top of the base game frame", function()
    local s = session_mod.new({ rows = 14, cols = 40 })
    -- Narration in the base frame to detect overlay layering.
    s:render({
      narration = { { kind = "narration", text = "Crossroads." } },
      choices   = {},
    })
    local m = menu_mod.new({
      title = "Menu",
      items = { { label = "One" }, { label = "Two" } },
    })
    s:driver()._view_stack:push(m, s:driver())
    s:driver()._focus:push(m, s:driver())
    -- Force a recompose: the simplest way is render(empty_scene), which
    -- repaints with the view-stack overlay walked at the end.
    s:render(empty_scene)
    local snap = s:snapshot()
    assert.is_truthy(snap:find("Crossroads.", 1, true),
      "narration should remain visible behind the menu")
    assert.is_truthy(snap:find("Menu", 1, true),
      "menu title should appear on top of the base frame")
  end)
end)

describe("M7 integration: input widget end-to-end", function()
  it("a name-entry input fires kernel:call_fn('set-name', text) on submit", function()
    local k = kernel_mod.new(stub_engine())
    -- Capture call_fn invocations using the host-provided seam
    -- documented in ui/kernel.lua (set_call_fn).
    local captured = {}
    k:set_call_fn(function(name, ...)
      captured[#captured + 1] = { name = name, args = { ... } }
    end)

    local s = session_mod.new({ rows = 12, cols = 40 })
    s:driver():attach(k)
    s:render(empty_scene)

    local w = input_mod.new({
      title   = "Hello",
      prompt  = "Your name?",
      fn_name = "set-name",
    })
    s:driver()._view_stack:push(w, s:driver())
    s:driver()._focus:push(w, s:driver())

    -- Type "Alice" then Enter.
    s:driver()._focus:dispatch(string.byte("A"), s:driver())
    s:driver()._focus:dispatch(string.byte("l"), s:driver())
    s:driver()._focus:dispatch(string.byte("i"), s:driver())
    s:driver()._focus:dispatch(string.byte("c"), s:driver())
    s:driver()._focus:dispatch(string.byte("e"), s:driver())
    s:driver()._focus:dispatch(K.CR,             s:driver())

    assert.equal(1, #captured, "call_fn should have fired exactly once")
    assert.equal("set-name", captured[1].name)
    assert.same({ "Alice" }, captured[1].args)
  end)

  it("backspace edits the buffer before submission", function()
    local k = kernel_mod.new(stub_engine())
    local got
    k:set_call_fn(function(_name, text) got = text end)
    local s = session_mod.new({ rows = 12, cols = 40 })
    s:driver():attach(k)
    s:render(empty_scene)

    local w = input_mod.new({ fn_name = "set-name" })
    s:driver()._view_stack:push(w, s:driver())
    s:driver()._focus:push(w, s:driver())

    -- Type "Bobby", backspace twice ("Bob"), type "bie" → "Bobbie".
    for ch in ("Bobby"):gmatch(".") do
      s:driver()._focus:dispatch(string.byte(ch), s:driver())
    end
    s:driver()._focus:dispatch(K.BS, s:driver())
    s:driver()._focus:dispatch(K.BS, s:driver())
    for ch in ("bie"):gmatch(".") do
      s:driver()._focus:dispatch(string.byte(ch), s:driver())
    end
    s:driver()._focus:dispatch(K.CR, s:driver())
    assert.equal("Bobbie", got)
  end)

  it("ESC cancels: on_cancel fires and call_fn is not invoked", function()
    local k = kernel_mod.new(stub_engine())
    local call_fn_fired = false
    k:set_call_fn(function() call_fn_fired = true end)
    local s = session_mod.new({ rows = 12, cols = 40 })
    s:driver():attach(k)
    s:render(empty_scene)

    local cancelled
    local w = input_mod.new({
      fn_name   = "set-name",
      initial   = "Should not submit",
      on_cancel = function() cancelled = true end,
    })
    s:driver()._view_stack:push(w, s:driver())
    s:driver()._focus:push(w, s:driver())

    s:driver()._focus:dispatch(K.ESC, s:driver())
    assert.is_true(cancelled)
    assert.is_false(call_fn_fired,
      "ESC must not submit; call_fn should remain untouched")
  end)

  it("on_submit can pop the widget off both stacks", function()
    local k = kernel_mod.new(stub_engine())
    local s = session_mod.new({ rows = 12, cols = 40 })
    s:driver():attach(k)
    s:render(empty_scene)

    local driver_ref = s:driver()
    local w
    w = input_mod.new({
      initial   = "X",
      on_submit = function(_self, _text, _drv)
        -- Caller-supplied pop logic mirrors how the driver wires the
        -- quit dialog at the moment.
        driver_ref._view_stack:pop(driver_ref)
        driver_ref._focus:pop(driver_ref)
      end,
    })
    driver_ref._view_stack:push(w, driver_ref)
    driver_ref._focus:push(w, driver_ref)
    assert.equal(1, driver_ref._view_stack:depth())

    driver_ref._focus:dispatch(K.CR, driver_ref)
    assert.equal(0, driver_ref._view_stack:depth())
    assert.equal(0, driver_ref._focus:depth())
  end)

  it("input widget paints the buffer + cursor glyph behind the base frame", function()
    local k = kernel_mod.new(stub_engine())
    local s = session_mod.new({ rows = 12, cols = 40 })
    s:driver():attach(k)
    s:render({ narration = { { kind = "narration", text = "Welcome." } }, choices = {} })

    local w = input_mod.new({
      title  = "Hello",
      prompt = "Name?",
      initial = "Eve",
    })
    s:driver()._view_stack:push(w, s:driver())
    s:driver()._focus:push(w, s:driver())
    s:render({ narration = {}, choices = {} })

    local snap = s:snapshot()
    assert.is_truthy(snap:find("Welcome.", 1, true),
      "narration should remain visible behind the input")
    assert.is_truthy(snap:find("Hello",   1, true), "title should appear")
    assert.is_truthy(snap:find("Name?",   1, true), "prompt should appear")
    assert.is_truthy(snap:find("Eve",     1, true), "initial buffer should appear")
  end)
end)

describe("M7 integration: kernel:call_fn host plumbing", function()
  it("kernel without a call_fn host registered returns nil and does not crash", function()
    local k = kernel_mod.new(stub_engine())
    -- No set_call_fn registered → call_fn is a no-op returning nil.
    assert.is_nil(k:call_fn("set-name", "ignored"))
  end)

  it("set_call_fn replaces the previous handler", function()
    local k = kernel_mod.new(stub_engine())
    local first, second
    k:set_call_fn(function() first = true end)
    k:set_call_fn(function() second = true end)
    k:call_fn("x")
    assert.is_nil(first, "first handler should have been replaced")
    assert.is_true(second)
  end)
end)

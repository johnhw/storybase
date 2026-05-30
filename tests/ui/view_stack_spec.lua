-- tests/ui/view_stack_spec.lua
--
-- Tests for §M6 view stack (cli/drivers/curses/view_stack.lua).
-- The view stack is the driver-local presentation stack used by modal
-- dialogs, inventory popups, and other overlays. It is intentionally
-- decoupled from the engine's scene stack (ui_idea.md §7) and from
-- focus/key dispatch (which lives in `focus.lua`).

local vs_mod = require("cli.drivers.curses.view_stack")

--- Construct a trivial view that records the calls made against it.
--- Useful for asserting lifecycle order without mocking machinery.
local function make_view(name, log)
  return {
    name    = name,
    paint   = function(self, screen, ctx)
      log[#log + 1] = { kind = "paint", name = self.name, ctx = ctx }
    end,
    on_open = function(self, driver)
      log[#log + 1] = { kind = "open",  name = self.name, driver = driver }
    end,
    on_close = function(self, driver)
      log[#log + 1] = { kind = "close", name = self.name, driver = driver }
    end,
  }
end

describe("view_stack: construction", function()
  it("new() returns an empty stack", function()
    local s = vs_mod.new()
    assert.equal(0, s:depth())
    assert.is_true(s:empty())
    assert.is_nil(s:top())
  end)
end)

describe("view_stack: push/pop", function()
  it("push records the view and fires on_open", function()
    local log = {}
    local v = make_view("dialog", log)
    local s = vs_mod.new()
    s:push(v, "driver-tag")
    assert.equal(1, s:depth())
    assert.is_false(s:empty())
    assert.equal(v, s:top())
    assert.equal(1, #log)
    assert.equal("open", log[1].kind)
    assert.equal("driver-tag", log[1].driver)
  end)

  it("pop removes the top view and fires on_close", function()
    local log = {}
    local v = make_view("dialog", log)
    local s = vs_mod.new()
    s:push(v, "drv")
    local popped = s:pop("drv")
    assert.equal(v, popped)
    assert.equal(0, s:depth())
    assert.equal(2, #log)
    assert.equal("close", log[2].kind)
    assert.equal("drv", log[2].driver)
  end)

  it("pop on empty stack is a no-op", function()
    local s = vs_mod.new()
    assert.is_nil(s:pop())
    assert.equal(0, s:depth())
  end)

  it("stack is LIFO", function()
    local log = {}
    local a, b, c = make_view("a", log), make_view("b", log), make_view("c", log)
    local s = vs_mod.new()
    s:push(a); s:push(b); s:push(c)
    assert.equal(3, s:depth())
    assert.equal(c, s:top())
    assert.equal(c, s:pop())
    assert.equal(b, s:top())
    assert.equal(b, s:pop())
    assert.equal(a, s:top())
  end)

  it("rejects pushes without paint()", function()
    local s = vs_mod.new()
    assert.has_error(function() s:push({}) end)
    assert.has_error(function() s:push({ paint = "not-a-function" }) end)
  end)
end)

describe("view_stack: lifecycle hooks are optional", function()
  it("a view without on_open/on_close still pushes/pops cleanly", function()
    local v = { paint = function() end }
    local s = vs_mod.new()
    assert.has_no.errors(function() s:push(v) end)
    assert.equal(v, s:top())
    assert.has_no.errors(function() s:pop() end)
    assert.equal(0, s:depth())
  end)
end)

describe("view_stack: iteration order", function()
  it("each_for_paint walks bottom to top", function()
    local log = {}
    local a, b, c = make_view("a", log), make_view("b", log), make_view("c", log)
    local s = vs_mod.new()
    s:push(a); s:push(b); s:push(c)
    local seen = {}
    s:each_for_paint(function(v, i)
      seen[#seen + 1] = { name = v.name, i = i }
    end)
    assert.same({
      { name = "a", i = 1 },
      { name = "b", i = 2 },
      { name = "c", i = 3 },
    }, seen)
  end)

  it("each_for_paint forwards screen+ctx to the view via the callback", function()
    -- The stack doesn't paint itself — callers paint each view in turn.
    -- This test just verifies the iteration contract is straightforward.
    local s = vs_mod.new()
    local v = { paint = function() end }
    s:push(v)
    local seen_count = 0
    s:each_for_paint(function(view, i)
      seen_count = seen_count + 1
      assert.equal(v, view)
      assert.equal(1, i)
    end)
    assert.equal(1, seen_count)
  end)
end)

describe("view_stack: clear", function()
  it("clears every view and fires on_close in top-down order", function()
    local log = {}
    local a, b, c = make_view("a", log), make_view("b", log), make_view("c", log)
    local s = vs_mod.new()
    s:push(a); s:push(b); s:push(c)
    for _ = 1, #log do table.remove(log, 1) end  -- discard on_open entries
    s:clear("drv")
    assert.equal(0, s:depth())
    assert.same({ "c", "b", "a" }, {
      log[1].name, log[2].name, log[3].name,
    })
    for i = 1, 3 do assert.equal("close", log[i].kind) end
  end)
end)

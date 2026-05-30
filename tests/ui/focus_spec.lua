-- tests/ui/focus_spec.lua
--
-- Tests for §M6 focus stack (cli/drivers/curses/focus.lua).
-- Separate from the view stack: focus owns who receives a keypress.

local focus_mod = require("cli.drivers.curses.focus")

--- Construct a focus handler whose on_key consumes (returns true) iff
--- the key equals the configured trigger. Records every call into log.
local function make_handler(name, trigger, log)
  return {
    name = name,
    on_key = function(self, key, driver)
      log[#log + 1] = { kind = "key", name = self.name, key = key, driver = driver }
      return key == trigger
    end,
    on_focus = function(self, driver)
      log[#log + 1] = { kind = "focus", name = self.name, driver = driver }
    end,
    on_blur = function(self, driver)
      log[#log + 1] = { kind = "blur",  name = self.name, driver = driver }
    end,
  }
end

describe("focus: construction", function()
  it("new() is empty", function()
    local f = focus_mod.new()
    assert.equal(0, f:depth())
    assert.is_true(f:empty())
    assert.is_nil(f:top())
  end)
end)

describe("focus: push/pop", function()
  it("push records the handler and fires on_focus", function()
    local log = {}
    local h = make_handler("a", "y", log)
    local f = focus_mod.new()
    f:push(h, "drv")
    assert.equal(h, f:top())
    assert.equal(1, f:depth())
    assert.equal(1, #log)
    assert.equal("focus", log[1].kind)
    assert.equal("drv", log[1].driver)
  end)

  it("push blurs the previous top before focusing the new top", function()
    local log = {}
    local a = make_handler("a", "y", log)
    local b = make_handler("b", "y", log)
    local f = focus_mod.new()
    f:push(a, "drv")
    for i = #log, 1, -1 do log[i] = nil end  -- discard first push's log
    f:push(b, "drv")
    assert.equal(2, #log)
    assert.equal("blur",  log[1].kind); assert.equal("a", log[1].name)
    assert.equal("focus", log[2].kind); assert.equal("b", log[2].name)
  end)

  it("pop blurs the popped handler and re-focuses the underlying one", function()
    local log = {}
    local a = make_handler("a", "y", log)
    local b = make_handler("b", "n", log)
    local f = focus_mod.new()
    f:push(a); f:push(b)
    for i = #log, 1, -1 do log[i] = nil end
    f:pop("drv")
    assert.equal(2, #log)
    assert.equal("blur",  log[1].kind); assert.equal("b", log[1].name)
    assert.equal("focus", log[2].kind); assert.equal("a", log[2].name)
    assert.equal(a, f:top())
  end)

  it("pop on empty stack is a no-op", function()
    local f = focus_mod.new()
    assert.is_nil(f:pop())
  end)

  it("rejects pushes without on_key", function()
    local f = focus_mod.new()
    assert.has_error(function() f:push({}) end)
    assert.has_error(function() f:push({ on_key = "not-fn" }) end)
  end)

  it("handlers without lifecycle hooks push/pop cleanly", function()
    local h = { on_key = function() return false end }
    local f = focus_mod.new()
    assert.has_no.errors(function() f:push(h) end)
    assert.has_no.errors(function() f:pop() end)
  end)
end)

describe("focus: dispatch", function()
  it("returns false when the stack is empty", function()
    local f = focus_mod.new()
    assert.is_false(f:dispatch("q"))
  end)

  it("routes the key to the top handler", function()
    local log = {}
    local h = make_handler("a", "q", log)
    local f = focus_mod.new()
    f:push(h, "drv")
    for i = #log, 1, -1 do log[i] = nil end
    local handled = f:dispatch("q", "drv")
    assert.is_true(handled)
    assert.equal(1, #log)
    assert.equal("q", log[1].key)
    assert.equal("drv", log[1].driver)
  end)

  it("returns false when the top handler does not consume the key", function()
    local log = {}
    local h = make_handler("a", "q", log)
    local f = focus_mod.new()
    f:push(h)
    assert.is_false(f:dispatch("z"))
  end)

  it("does not fall through to handlers underneath the top", function()
    local log = {}
    local a = make_handler("a", "q", log)
    local b = make_handler("b", "n", log)
    local f = focus_mod.new()
    f:push(a); f:push(b)
    for i = #log, 1, -1 do log[i] = nil end
    -- 'q' is a's trigger, but b is on top — should not be consumed.
    assert.is_false(f:dispatch("q"))
    -- Only b was asked.
    assert.equal(1, #log)
    assert.equal("b", log[1].name)
  end)

  it("normalises truthy non-boolean returns to true", function()
    local h = { on_key = function() return {} end }
    local f = focus_mod.new()
    f:push(h)
    assert.is_true(f:dispatch("x"))
  end)
end)

describe("focus: clear", function()
  it("pops all handlers top-down with on_blur for each", function()
    local log = {}
    local a = make_handler("a", "y", log)
    local b = make_handler("b", "n", log)
    local c = make_handler("c", "?", log)
    local f = focus_mod.new()
    f:push(a); f:push(b); f:push(c)
    for i = #log, 1, -1 do log[i] = nil end
    f:clear("drv")
    -- Each pop blurs the popped + focuses the newly-exposed (down to empty).
    -- Order: blur c, focus b, blur b, focus a, blur a.
    local seen = {}
    for _, e in ipairs(log) do seen[#seen + 1] = e.kind .. ":" .. e.name end
    assert.same({ "blur:c", "focus:b", "blur:b", "focus:a", "blur:a" }, seen)
    assert.equal(0, f:depth())
  end)
end)

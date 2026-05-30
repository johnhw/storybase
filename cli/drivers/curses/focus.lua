-- cli/drivers/curses/focus.lua
--
-- Focus stack and key dispatch (ui_idea.md §8.3 + §M6). Deliberately
-- separate from `view_stack.lua` because the two concerns *can* move
-- independently — a heads-up overlay can paint without grabbing focus,
-- and a "modeless tool window" can keep focus while a different view
-- gets pushed underneath. The M6 modal-dialog use case is the simple
-- common case where both stacks move together.
--
-- A focus handler is a plain table with the shape:
--   {
--     on_key   : function(self, key, driver) -> handled  (required)
--     on_focus : function(self, driver)?
--     on_blur  : function(self, driver)?
--   }
--
-- `on_key` returns truthy iff the handler consumed the key. The
-- driver's read loop only falls through to its base handler (digit
-- choices, q-to-quit) when every focus handler on the stack returned
-- falsy. Today we dispatch only to the top handler — fallthrough to
-- handlers underneath would require explicit opt-in (and the M6
-- modals never want it), so we keep the surface minimal.

local M = {}

--- Construct a new empty focus stack.
---@return table
function M.new()
  local self = {
    _stack = {},
  }

  --- Push `handler` onto the top of the focus stack. Calls
  --- `handler:on_focus(driver)` if defined; calls the previous top's
  --- `on_blur(driver)` so widgets can flip cursor state, etc.
  ---@param handler table
  ---@param driver  table?
  function self:push(handler, driver)
    assert(type(handler) == "table", "focus:push expects a handler table")
    assert(type(handler.on_key) == "function",
      "focus:push handler must expose on_key(self, key, driver)")
    local prev = self:top()
    if prev and prev.on_blur then prev:on_blur(driver) end
    self._stack[#self._stack + 1] = handler
    if handler.on_focus then handler:on_focus(driver) end
  end

  --- Pop the top handler. Fires `on_blur` on the popped handler and
  --- `on_focus` on the newly-exposed one. Returns the popped handler
  --- or nil if the stack was empty.
  ---@param driver table?
  ---@return table?
  function self:pop(driver)
    local n = #self._stack
    if n == 0 then return nil end
    local popped = self._stack[n]
    self._stack[n] = nil
    if popped.on_blur then popped:on_blur(driver) end
    local now_top = self:top()
    if now_top and now_top.on_focus then now_top:on_focus(driver) end
    return popped
  end

  --- Peek at the top handler.
  ---@return table?
  function self:top()
    local n = #self._stack
    if n == 0 then return nil end
    return self._stack[n]
  end

  --- Number of handlers on the stack.
  ---@return integer
  function self:depth()
    return #self._stack
  end

  --- True iff no handlers are stacked.
  ---@return boolean
  function self:empty()
    return #self._stack == 0
  end

  --- Drop every handler, top-down, firing `on_blur` on each. Used by
  --- driver shutdown.
  ---@param driver table?
  function self:clear(driver)
    while #self._stack > 0 do
      self:pop(driver)
    end
  end

  --- Dispatch `key` to the top handler. Returns whatever the handler
  --- returned (truthy = consumed; falsy = fall through to the driver's
  --- base key handling). Returns false if the focus stack is empty so
  --- the caller can branch on the same boolean either way.
  ---@param key    any
  ---@param driver table?
  ---@return boolean
  function self:dispatch(key, driver)
    local top = self:top()
    if not top then return false end
    return top:on_key(key, driver) and true or false
  end

  return self
end

return M

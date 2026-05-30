-- cli/drivers/curses/view_stack.lua
--
-- Driver-local view stack (ui_idea.md §7 + §M6). A *view* is anything
-- the driver wants to paint on top of (or instead of) the underlying
-- game screen — a modal dialog, an inventory popup, a menu overlay.
--
-- This is **not** the engine's scene stack. The engine's scene stack
-- is gameplay state (persisted in saves, reasoned about by `verify`).
-- The view stack is pure presentation — opening an inventory popup
-- does not change the engine's scene, and closing it does not fire a
-- `scene-change`. Save files never see the view stack.
--
-- A view is a plain table with the shape:
--   {
--     z        : optional integer (insertion order is the default),
--     paint    : function(self, screen, ctx)   -- required
--     on_open  : function(self, driver)?       -- optional lifecycle
--     on_close : function(self, driver)?       -- optional lifecycle
--   }
--
-- The view stack stores views in push order; `each_for_paint` iterates
-- bottom-to-top so the painter can overlay them in z-order. Key
-- dispatch is a separate concern owned by `focus.lua` — pushing a view
-- onto the view stack does *not* automatically grab focus. Most modal
-- callers want both; they push to both stacks.

local M = {}

--- Construct a new empty view stack.
---@return table
function M.new()
  local self = {
    _views = {},
  }

  --- Push `view` onto the top of the stack. Calls `view:on_open(driver)`
  --- if defined. The driver is forwarded so the lifecycle hook can stash
  --- references to backend / kernel / focus stack.
  ---@param view   table
  ---@param driver table?
  function self:push(view, driver)
    assert(type(view) == "table", "view_stack:push expects a view table")
    assert(type(view.paint) == "function",
      "view_stack:push view must expose paint(self, screen, ctx)")
    self._views[#self._views + 1] = view
    if view.on_open then view:on_open(driver) end
  end

  --- Pop the top view. Calls `view:on_close(driver)` if defined.
  --- Returns the popped view, or nil if the stack was empty.
  ---@param driver table?
  ---@return table?
  function self:pop(driver)
    local n = #self._views
    if n == 0 then return nil end
    local top = self._views[n]
    self._views[n] = nil
    if top.on_close then top:on_close(driver) end
    return top
  end

  --- Peek at the top view without removing it.
  ---@return table?
  function self:top()
    local n = #self._views
    if n == 0 then return nil end
    return self._views[n]
  end

  --- Number of views currently on the stack.
  ---@return integer
  function self:depth()
    return #self._views
  end

  --- True iff the stack has zero views.
  ---@return boolean
  function self:empty()
    return #self._views == 0
  end

  --- Drop every view, firing `on_close` for each (top-down). Used by
  --- driver shutdown so a partially-open modal doesn't leak across a
  --- detach/attach cycle.
  ---@param driver table?
  function self:clear(driver)
    while #self._views > 0 do
      self:pop(driver)
    end
  end

  --- Iterate views bottom-to-top, invoking `fn(view, index)`. The
  --- driver's compose path uses this to layer overlays on top of the
  --- base game frame. Stable iteration order; views pushed during
  --- iteration are *not* visited this pass (the next compose picks
  --- them up).
  ---@param fn function
  function self:each_for_paint(fn)
    local snapshot = self._views
    for i = 1, #snapshot do
      fn(snapshot[i], i)
    end
  end

  return self
end

return M

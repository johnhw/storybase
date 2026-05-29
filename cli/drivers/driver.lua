-- cli/drivers/driver.lua
--
-- Driver protocol contract for StoryBase UI drivers.
--
-- The canonical specification lives in `ui_idea.md` §3 (driver protocol)
-- and §3.4 (driver lifecycle). This file is the in-tree, machine-checkable
-- restatement of that contract. Every driver under `cli/drivers/<name>/`
-- conforms to the surface declared here.
--
-- ┌───────────────────────────────────────────────────────────────────┐
-- │ Status (2026-05-29)                                               │
-- ├───────────────────────────────────────────────────────────────────┤
-- │ Operational today        : render(scene_output), prompt(choices), │
-- │                            notify(event, data)                    │
-- │                            — called by runtime/engine.lua via the │
-- │                              `opts.driver` pull-mode dispatch.    │
-- │                                                                   │
-- │ Scaffolded (no-op)       : attach(kernel), tick(dt), detach()     │
-- │                            — drivers expose stubs so they satisfy │
-- │                              the full contract; the kernel       │
-- │                              (ui/kernel.lua, §M1 shipped) is now  │
-- │                              wired into lib/storybase + the      │
-- │                              debug server, but no driver yet     │
-- │                              consumes it. §M3 (screen-model      │
-- │                              split) flips curses to event-driven.│
-- └───────────────────────────────────────────────────────────────────┘
--
-- The active dispatch path in `runtime/engine.lua` (see eng:step,
-- search for `self._driver`) calls render+prompt directly. The
-- presentation kernel (`ui/kernel.lua`) shipped at §M1 (2026-05-29)
-- and is used today by `lib/storybase.lua:on(...)` and the debug
-- server's SSE broadcast; event-driven drivers (curses-reactive,
-- browser-sse) will hook in via attach/tick/detach starting at §M3.
-- Until then, attach/tick/detach are reserved names so no driver
-- accidentally shadows them.
--
-- ── Required methods ────────────────────────────────────────────────
--
--   driver:render(scene_output)
--     scene_output = { narration = {...}, choices = {...} }
--     narration items are tables of the form
--       { kind = "narration"|"say", text = string,
--         speaker?, display?, color? }
--     choices are tables of the form { index, label }.
--     Drivers paint the scene; no return value.
--
--   driver:prompt(choices)
--     choices as above. Returns an integer index in [1, #choices],
--     or nil to quit the run loop.
--
--   driver:notify(event, data)
--     Live event hook. Currently optional; existing drivers no-op.
--     Will be subsumed by attach()'s kernel subscription once §M1 lands.
--
-- ── Lifecycle methods (scaffolded; see §M1) ─────────────────────────
--
--   driver:attach(kernel)
--     Subscribe to kernel events; request an initial full paint via
--     kernel:get_state_all() / kernel:get_scene(). Until the kernel
--     exists, drivers implement this as a no-op.
--
--   driver:tick(dt)
--     Called by the host loop with elapsed seconds. The curses driver
--     will use this to advance widget animations and flush dirty
--     regions. Plain/ansi drivers do not need a tick — they are
--     synchronous-pull. No-op stub is correct for them.
--
--   driver:detach()
--     Unsubscribe; release any owned surface (e.g. endwin() for
--     curses). Plain/ansi have no surface to release; no-op stub.
--
-- ── Module shape ────────────────────────────────────────────────────
--
-- Every driver module exposes:
--
--   M.new(opts) -> driver
--
-- where opts is at minimum `{ io_out, io_in }` for terminal drivers.
-- Driver-specific opts (e.g. curses backend = "ncurses"|"buffer") are
-- documented in that driver's init.lua.
--
-- ────────────────────────────────────────────────────────────────────

local M = {}

--- The set of methods a driver must define to satisfy the contract.
-- `render` + `prompt` are operationally required today; the rest are
-- structurally required so the contract is stable as it grows.
M.REQUIRED_METHODS = {
  "render", "prompt", "notify",
  "attach", "tick", "detach",
}

--- Duck-typing check: does `d` look like a driver?
-- Used by tests and by the CLI loader when validating a freshly
-- loaded driver module. Returns (ok, missing_method_or_nil).
---@param d table  candidate driver instance
---@return boolean ok
---@return string? missing  name of the first missing method, if any
function M.is_driver(d)
  if type(d) ~= "table" then return false, "not a table" end
  for _, name in ipairs(M.REQUIRED_METHODS) do
    if type(d[name]) ~= "function" then return false, name end
  end
  return true
end

return M

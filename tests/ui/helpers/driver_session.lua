-- tests/ui/helpers/driver_session.lua
--
-- Lightweight test harness for the curses driver. Wraps the common
-- spec flow `script_keys → render → prompt → snapshot` so widget specs
-- (§M5+) don't re-glue the same five lines.
--
-- Use:
--
--   local session = require("tests.ui.helpers.driver_session")
--
--   local s = session.new({ rows = 10, cols = 40, keys = "1q" })
--   s:render({ narration = {...}, choices = {...} })
--   s:choose("2")                      -- enqueue keys + run prompt
--   assert.equal(golden, s:snapshot()) -- buffer-backend snapshot
--
-- The session always uses the buffer backend (no TTY needed) and the
-- shared `fake_curses` stub is *not* loaded — driver tests that need
-- the ncurses-path can use that helper directly.
--
-- Lifted at §M5 per ui_idea.md §9.1 item 1.

local driver_mod = require("cli.drivers.curses")

local M = {}

--- Construct a new driver session.
---@param opts table?  { rows?, cols?, keys?, frame_history? }
---     rows / cols    : buffer dimensions (default 24×80)
---     keys           : initial scripted-key sequence (string or int[])
---     frame_history  : turn on backend frame history (§9.1 item 2)
---@return table session
function M.new(opts)
  opts = opts or {}
  local driver = driver_mod.new({
    backend       = "buffer",
    rows          = opts.rows or 24,
    cols          = opts.cols or 80,
    keys          = opts.keys,
    frame_history = opts.frame_history,
  })

  local self = {
    _driver  = driver,
    _backend = driver:_backend_handle(),
  }

  --- Enqueue keys onto the buffer backend. Strings expand byte-by-byte;
  --- integer entries pass through as raw key codes.
  ---@param keys string|table
  function self:script_keys(keys)
    local list = {}
    if type(keys) == "string" then
      for i = 1, #keys do list[i] = keys:byte(i) end
    else
      for i = 1, #(keys or {}) do list[i] = keys[i] end
    end
    -- Touch the driver so the backend is initialised; otherwise
    -- script_keys runs against an uninitialised backend (still safe,
    -- but exposes test ordering bugs).
    self._driver:render({ narration = {}, choices = {} })
    self._backend:script_keys(list)
  end

  --- Forward a render to the driver.
  ---@param scene_output table
  function self:render(scene_output)
    self._driver:render(scene_output or {})
  end

  --- Enqueue `keys` (string or table) and run `driver:prompt(choices)`
  --- using the optional `choices` arg. The first matching digit (or q)
  --- in `keys` is consumed by the prompt. Returns whatever `prompt`
  --- returns (1-based choice index, or nil for quit).
  ---@param keys    string|table
  ---@param choices table?
  ---@return integer? idx
  function self:choose(keys, choices)
    self:script_keys(keys)
    return self._driver:prompt(choices or {})
  end

  --- Snapshot the buffer backend as a newline-joined string (trailing
  --- spaces trimmed per row). Mirrors `backend_buffer:snapshot()`.
  ---@return string
  function self:snapshot()
    return self._backend:snapshot()
  end

  --- Per-row snapshot (raw, no trim) — useful when a test wants to
  --- assert exact width.
  ---@return string[]
  function self:snapshot_rows()
    return self._backend:snapshot_rows()
  end

  --- Return the full frame snapshot history (when frame_history is on).
  --- Empty list if the backend did not record history.
  ---@return string[]
  function self:snapshot_history()
    if self._backend.snapshot_history then
      return self._backend:snapshot_history()
    end
    return {}
  end

  --- Return the per-frame dirty-rect history (when frame_history is on).
  --- Each entry is an array of `{y, x, cells}` records from `paint.diff`.
  ---@return table[]
  function self:dirty_history()
    if self._backend.dirty_history then
      return self._backend:dirty_history()
    end
    return {}
  end

  --- Drop any frame history accumulated so far. Useful to isolate
  --- "before mutation" vs "after mutation" history slices.
  function self:reset_history()
    if self._backend.reset_history then
      self._backend:reset_history()
    end
  end

  --- Expose handles for tests that need raw access.
  function self:driver()  return self._driver  end
  function self:backend() return self._backend end

  return self
end

return M

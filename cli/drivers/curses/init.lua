-- cli/drivers/curses/init.lua
-- Curses UI driver for StoryBase (ui_idea.md §M3 + §M5 + §M6).
--
-- The driver paints into a retained 2D cell grid (`screen.lua`) and
-- flushes only dirty regions (`paint.lua`) to a backend. Two backends
-- ship with the driver:
--
--   * backend_curses : the real ncurses surface. Selected by default,
--                      and the only backend that loads `lcurses`.
--   * backend_buffer : an in-memory grid for headless tests and as a
--                      no-tty fallback when lcurses is unavailable.
--
-- Dispatch:
--   * Pull-mode (`render(scene_output)` + `prompt(choices)`) is still
--     the dispatch path for narration and choice input — the engine
--     calls these directly from `eng:step`.
--   * Reactive widgets (§M5) sit alongside: `attach(kernel)` scans the
--     compiled-game schema, instantiates a widget per `ui:` binding,
--     and subscribes the driver to `mutation` so a single state change
--     re-composes the frame and emits a dirty rect for *just* the
--     widget window. The rest of the screen re-paints identically and
--     is therefore diff'd as clean.
--
-- Activate with: `storybase run game.sb --ui curses`.
--
-- Headless tests pick the buffer backend via `opts.backend = "buffer"`
-- and consume the resulting grid via the backend's `snapshot()` helper.

local M = {}

local screen_mod      = require("cli.drivers.curses.screen")
local paint_mod       = require("cli.drivers.curses.paint")
local backend_curses  = require("cli.drivers.curses.backend_curses")
local backend_buffer  = require("cli.drivers.curses.backend_buffer")
local statbar_mod     = require("cli.drivers.curses.widgets.statbar")
local stat_mod        = require("cli.drivers.curses.widgets.stat")
local toggle_mod      = require("cli.drivers.curses.widgets.toggle")
local text_mod        = require("cli.drivers.curses.widgets.text")
local inventory_mod   = require("cli.drivers.curses.widgets.inventory")
local choice_mod      = require("cli.drivers.curses.widgets.choice")
local dialog_mod      = require("cli.drivers.curses.widgets.dialog")
local view_stack_mod  = require("cli.drivers.curses.view_stack")
local focus_mod       = require("cli.drivers.curses.focus")

-- Default geometry when the ncurses backend can't report a size yet (the
-- buffer backend always uses these). Real ncurses ignores them and uses
-- `getmaxyx` after `initscr`.
local DEFAULT_ROWS = 24
local DEFAULT_COLS = 80

--- Probe lcurses availability — the CLI uses this to decide whether to
--- print a "install lcurses" hint when `--ui curses` was requested.
---@return boolean
function M.is_available()
  return backend_curses.is_available()
end

--- Walk the compiled schema and ui_panels and instantiate widget
--- instances for every author-declared `ui:` binding the driver knows
--- how to render. Supports the §M5 / §M8 widget vocabulary: `stat-bar`,
--- `stat`, `toggle`, `text`, `inventory`, `choice`. Unknown kinds are
--- silently skipped so future widget kinds don't error out.
---
--- Populates `self._widgets` (insertion order = display order, each
--- carrying a `_desired_h` integer used by the compose layout) and
--- `self._by_path[path]` (array, for routing mutation events). A widget
--- bound to multiple paths (e.g. `text` with several `{...}` placeholders)
--- registers under every path it depends on.
---@param self    table
---@param schema  table  compiled schema (`{states=..., types=...}`)
---@param panels  table  list of `game_table.ui_panels`
local function collect_widgets(self, schema, panels)
  -- Helper: append `widget` to `self._widgets`, register it against every
  -- path in `paths`, and stamp a desired height. Each path → first widget
  -- registered wins; subsequent registrations under the same path append
  -- to the routing list so a single mutation can repaint multiple widgets.
  local function register(widget, paths, desired_h)
    widget._desired_h = desired_h or 1
    self._widgets[#self._widgets + 1] = widget
    for _, p in ipairs(paths or {}) do
      local bucket = self._by_path[p]
      if not bucket then bucket = {}; self._by_path[p] = bucket end
      bucket[#bucket + 1] = widget
    end
  end

  -- A state path → state-descriptor lookup for the panel pass and for
  -- resolving the `type_desc` of a panel-referenced widget.
  local state_by_path = {}
  for _, s in ipairs((schema and schema.states) or {}) do
    if s.kind == "scalar" and s.path then state_by_path[s.path] = s end
  end

  -- Has this path already produced a "single-path" widget (stat-bar /
  -- stat / toggle / inventory / choice)? When yes, a later reference to
  -- the same path is dropped — state-decl precedes panel walk so the
  -- author's explicit `ui:` block wins.
  local seen_path = {}

  local function add_statbar(spec)
    if not spec.path or seen_path[spec.path] then return end
    local ui = spec.ui_fields or {}
    local w = statbar_mod.new({
      path       = spec.path,
      label      = ui.label,
      type_desc  = spec.type_desc,
      color_good = ui["color-good"],
      color_bad  = ui["color-bad"],
    })
    seen_path[spec.path] = true
    register(w, { spec.path }, 1)
  end

  local function add_stat(spec)
    if not spec.path or seen_path[spec.path] then return end
    local ui = spec.ui_fields or {}
    local w = stat_mod.new({
      path      = spec.path,
      label     = ui.label,
      type_desc = spec.type_desc,
      schema    = schema,
    })
    seen_path[spec.path] = true
    register(w, { spec.path }, 1)
  end

  local function add_toggle(spec)
    if not spec.path or seen_path[spec.path] then return end
    local ui = spec.ui_fields or {}
    local w = toggle_mod.new({
      path      = spec.path,
      label     = ui.label,
      fn_name   = ui.fn,
      on_glyph  = ui["on-glyph"],
      off_glyph = ui["off-glyph"],
    })
    seen_path[spec.path] = true
    register(w, { spec.path }, 1)
  end

  local function add_text(ui_fields)
    local template = ui_fields and ui_fields.template
    if type(template) ~= "string" or template == "" then return end
    local w = text_mod.new({ template = template, schema = schema })
    register(w, w:paths(), #w:paths() > 0 and 1 or 1)
  end

  local function add_inventory(spec)
    if not spec.path or seen_path[spec.path] then return end
    local ui = spec.ui_fields or {}
    local max_h = tonumber(ui["max-rows"]) or 5
    local w = inventory_mod.new({
      path       = spec.path,
      label      = ui.label,
      schema     = schema,
      max_h      = max_h,
      bullet     = ui.bullet,
      fn_name    = ui.fn,
      empty_text = ui["empty-text"],
    })
    seen_path[spec.path] = true
    local header_h = (ui.label and ui.label ~= "") and 1 or 0
    register(w, { spec.path }, max_h + header_h)
  end

  local function add_choice(spec)
    if not spec.path or seen_path[spec.path] then return end
    local ui = spec.ui_fields or {}
    local w = choice_mod.new({
      path      = spec.path,
      label     = ui.label,
      fn_name   = ui.fn,
      schema    = schema,
    })
    seen_path[spec.path] = true
    local header_h = (ui.label and ui.label ~= "") and 1 or 0
    register(w, { spec.path }, #w.values + header_h)
  end

  -- Dispatch table: ui.kind → constructor. Keeping the table local to
  -- collect_widgets lets test code monkey-patch widget modules without
  -- patching this dispatch (the constructors close over module locals).
  local dispatch_state = {
    ["stat-bar"]  = add_statbar,
    ["stat"]      = add_stat,
    ["toggle"]    = add_toggle,
    ["inventory"] = add_inventory,
    ["choice"]    = add_choice,
    -- `text` is also valid on a state decl: the template defaults to
    -- "{path}" when the ui block has no explicit `template`.
    ["text"]      = function(spec)
                      local ui = spec.ui_fields or {}
                      local tmpl = ui.template or ("{" .. spec.path .. "}")
                      add_text({ template = tmpl })
                    end,
  }

  -- Pass 1: scalar `ui:` blocks attached directly to state decls.
  for _, s in ipairs((schema and schema.states) or {}) do
    if s.kind == "scalar" and s.ui and s.ui.kind then
      local builder = dispatch_state[s.ui.kind]
      if builder then
        builder({
          path      = s.path,
          ui_fields = s.ui,
          type_desc = s.type_desc,
        })
      end
    end
  end

  -- Pass 2: ui-panel children. A `stat-bar player/hp` child inherits the
  -- state's own type_desc + ui fields (if any), with the panel acting as
  -- a layout-only reference. `text` panel children pass the panel's `arg`
  -- through as the template directly (so `- text "Gold: {player/gold}"`
  -- renders as written).
  for _, p in ipairs(panels or {}) do
    for _, child in ipairs(p.children or {}) do
      local ck, ca = child.kind, child.arg
      if ck == "text" then
        add_text({ template = ca or "" })
      elseif ck == "stat-bar" or ck == "stat" or ck == "toggle"
             or ck == "inventory" or ck == "choice" then
        local s = state_by_path[ca]
        if s then
          local builder = dispatch_state[ck]
          builder({
            path      = ca,
            ui_fields = s.ui,
            type_desc = s.type_desc,
          })
        end
      end
    end
  end
end

--- Convert engine narration items into plain text lines. `say` items
--- become "Speaker: text"; narration items pass through. Multi-line
--- text is split on newline so each physical line fits one row.
---@param items table?  scene_output.narration
---@return string[]
local function narration_to_lines(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    local text
    if item.kind == "say" then
      local label = item.display or item.speaker or "?"
      text = label .. ": " .. tostring(item.text or "")
    elseif item.text and item.text ~= "" then
      text = tostring(item.text)
    end
    if text then
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
      end
    end
  end
  return out
end

--- Create a new curses driver.
---
--- Opts:
---   backend : "ncurses" (default) | "buffer"
---   curses  : module override for the ncurses backend (test seam)
---   rows    : forced initial geometry; ncurses overrides on init.
---             defaults to 24 (ncurses) or 24 (buffer).
---   cols    : forced initial geometry; ncurses overrides on init.
---             defaults to 80.
---
--- Lifecycle: `M.new` is lightweight — no terminal is touched until
--- the first `render`/`prompt`. That keeps `is_driver()` and tests
--- without a TTY safe.
---@param opts table?
---@return table driver
function M.new(opts)
  opts = opts or {}
  local kind = opts.backend or "ncurses"

  local backend
  if kind == "buffer" then
    backend = backend_buffer.new({
      rows          = opts.rows or DEFAULT_ROWS,
      cols          = opts.cols or DEFAULT_COLS,
      keys          = opts.keys,
      frame_history = opts.frame_history,
    })
  elseif kind == "ncurses" then
    backend = backend_curses.new({ curses = opts.curses })
  else
    error("cli/drivers/curses: unknown backend '" .. tostring(kind) .. "'", 2)
  end

  local driver = {
    _opts        = opts,
    _kind        = kind,
    _backend     = backend,
    _kernel      = nil,
    _initialised = false,
    _screen      = nil,
    _narr_lines  = {},  -- scrollback history (engine-side text lines)
    _widgets     = {},  -- ordered list of widget instances
    _by_path     = {},  -- state path → array of widgets bound to it
    _last_choices = nil,
    _last_active  = false,
    _unsubs      = {},  -- kernel unsubscribe handles
    _view_stack  = view_stack_mod.new(),  -- §M6 driver-local view stack
    _focus       = focus_mod.new(),       -- §M6 focus / key dispatch stack
    _quit_pending = false,                -- set by quit-confirm dialog
  }

  --- Lazily call backend:init on first paint. Errors with a clear
  --- message if lcurses cannot be loaded so callers can fall back to
  --- `--ui plain` rather than seeing an opaque module-load failure.
  local function ensure_init(self)
    if self._initialised then return end
    local rows = opts.rows or DEFAULT_ROWS
    local cols = opts.cols or DEFAULT_COLS
    local ok, reason = self._backend:init(rows, cols)
    if not ok then
      error("cli/drivers/curses: " .. tostring(reason)
            .. " — install lcurses or use --ui plain", 2)
    end
    -- For ncurses, the real terminal size lives in the backend after
    -- init. The buffer backend reports what we passed in.
    local br, bc = self._backend:size()
    if br > 0 and bc > 0 then rows, cols = br, bc end
    self._screen = screen_mod.new(rows, cols)
    self._initialised = true
  end

  --- Compose the screen for one frame: optional widget strip,
  --- narration tail, separator, choices, and the prompt status line.
  --- Returns nothing — paints into the screen's `_cells` grid. The
  --- caller then flushes.
  ---
  --- When the driver is attached to a kernel and has reactive widgets,
  --- each widget paints into a stable-position window at the top of the
  --- screen (z-ordered above narration). Per-widget heights come from
  --- `widget._desired_h` (1 for stat-bar / stat / toggle / text; >1 for
  --- inventory / choice). The whole widget strip is capped so narration
  --- still gets at least one row.
  ---@param self table
  ---@param choices table?
  ---@param choices_active boolean
  local function compose(self, choices, choices_active)
    choices = choices or {}
    local rows = self._screen.rows
    local cols = self._screen.cols
    self._screen:clear()
    self._screen:clear_windows()

    local prompt_h    = 1
    local separator_h = 1
    local choices_h   = #choices
    -- Compute the actual widget strip height: sum of desired heights,
    -- capped so narration gets at least 1 row. Each widget gets its
    -- desired height in full, or 0 if there's no room left.
    local non_widget_h = prompt_h + separator_h + choices_h + 1  -- +1 narr
    local max_strip_h  = rows - non_widget_h
    if max_strip_h < 0 then max_strip_h = 0 end

    local widget_heights = {}
    local strip_h = 0
    for i, w in ipairs(self._widgets) do
      local dh = w._desired_h or 1
      if strip_h + dh > max_strip_h then dh = max_strip_h - strip_h end
      if dh < 0 then dh = 0 end
      widget_heights[i] = dh
      strip_h = strip_h + dh
    end

    local narr_h = rows - prompt_h - separator_h - choices_h - strip_h
    if narr_h < 1 then narr_h = 1 end

    -- Widget strip: stack widgets top-to-bottom, each taking its
    -- pre-computed height.
    local widget_wins = {}
    do
      local y = 0
      for i, w in ipairs(self._widgets) do
        local h = widget_heights[i]
        if h > 0 then
          widget_wins[i] = self._screen:add_window({
            x = 0, y = y, w = cols, h = h,
          })
          y = y + h
        end
      end
    end

    -- Allocate windows so §M5+ widgets can repaint regions individually.
    local narr_y = strip_h
    local narr_win = self._screen:add_window({
      x = 0, y = narr_y, w = cols, h = narr_h,
    })
    local sep_y = narr_y + narr_h
    local sep_win = self._screen:add_window({ x = 0, y = sep_y, w = cols, h = 1 })
    local choices_y = sep_y + separator_h
    local choices_win = self._screen:add_window({
      x = 0, y = choices_y, w = cols, h = math.max(1, choices_h),
    })
    local prompt_win = self._screen:add_window({
      x = 0, y = rows - 1, w = cols, h = 1,
    })

    -- Reactive widgets (only when a kernel is attached so they can query state).
    if self._kernel then
      for i, w in ipairs(self._widgets) do
        local win = widget_wins[i]
        if win then w:paint(self._screen, win, self._kernel) end
      end
    end

    -- Narration: bottom-aligned tail.
    local first = math.max(1, #self._narr_lines - narr_h + 1)
    local wy = 0
    for i = first, #self._narr_lines do
      self._screen:write(narr_win, wy, 0, self._narr_lines[i])
      wy = wy + 1
      if wy >= narr_h then break end
    end

    -- Separator (only drawn if it fits below narration and above prompt).
    if sep_y < rows - prompt_h then
      self._screen:fill(sep_win, 0, 0, cols, 1, "-")
    end

    -- Choices.
    for i, c in ipairs(choices) do
      if i > choices_win.h then break end
      local label = i .. ". " .. tostring(c.label or "")
      self._screen:write(choices_win, i - 1, 0, label)
    end

    -- Prompt.
    local prompt
    if choices_active and #choices > 0 then
      prompt = "Choice (1-" .. #choices .. ", q to quit): "
    else
      prompt = "(press q or ESC to quit)"
    end
    self._screen:write(prompt_win, 0, 0, prompt)

    -- §M6: paint any active overlays on top of the base frame.
    -- Each view allocates its own window via `screen:add_window` and
    -- writes into it; later writes overwrite earlier cells in the
    -- shared grid, so the dialog naturally appears over the game.
    if self._view_stack and not self._view_stack:empty() then
      local ctx = { kernel = self._kernel, driver = self }
      self._view_stack:each_for_paint(function(view)
        view:paint(self._screen, ctx)
      end)
    end
  end

  --- Compose and flush a single frame. Only dirty cells reach the backend.
  local function flush_frame(self)
    local rects = paint_mod.diff(self._screen)
    self._backend:flush(self._screen, rects)
    self._screen:commit()
  end

  -- ── Driver protocol ───────────────────────────────────────────

  function driver:render(scene_output)
    ensure_init(self)
    scene_output = scene_output or {}
    for _, line in ipairs(narration_to_lines(scene_output.narration)) do
      self._narr_lines[#self._narr_lines + 1] = line
    end
    self._last_choices = scene_output.choices
    self._last_active  = false
    -- Paint without an active choice prompt; the engine will follow up
    -- with `prompt()` when it wants input.
    compose(self, scene_output.choices, false)
    flush_frame(self)
  end

  function driver:prompt(choices)
    ensure_init(self)
    self._last_choices = choices
    self._last_active  = true
    compose(self, choices, true)
    flush_frame(self)
    return self:_read_choice(#(choices or {}))
  end

  function driver:notify(_event, _data)
    -- Pull-mode driver. Live event delivery lands via `attach(kernel)`
    -- below; `notify` is retained for forward compatibility with the
    -- driver-protocol contract (cli/drivers/driver.lua).
  end

  --- Re-paint the most recent frame using the latest kernel-cached
  --- state. Called from the mutation subscription so widget windows
  --- pick up new values without waiting for the next engine-driven
  --- render. The frame outside the widget strip re-paints identically
  --- to the prior frame, so `paint.diff` yields rects covering only
  --- the cells the widgets actually changed.
  ---@param self table
  local function recompose_for_mutation(self)
    if not self._initialised or not self._kernel then return end
    if #self._widgets == 0 then return end
    compose(self, self._last_choices, self._last_active)
    flush_frame(self)
  end

  function driver:attach(kernel)
    self._kernel = kernel
    -- Discover widgets from the schema (states with a `ui:` block) and
    -- from ui-panels (children referencing state paths). Subscribe to
    -- the `mutation` event so a state change repaints affected widgets.
    self._widgets = {}
    self._by_path = {}
    if kernel and kernel.get_schema then
      local schema = kernel:get_schema() or {}
      collect_widgets(self, schema, kernel.get_bindings and kernel:get_bindings() or {})
    end
    -- Subscribe regardless of whether widgets exist today — a future
    -- live-reload could grow the widget list and the same subscription
    -- still routes events.
    if kernel and kernel.on and #self._widgets > 0 then
      local unsub = kernel:on("mutation", function(payload)
        if not (payload and payload.path) then return end
        if not self._by_path[payload.path] then return end
        recompose_for_mutation(self)
      end)
      self._unsubs[#self._unsubs + 1] = unsub
    end
  end

  function driver:tick(_dt)
    -- §8.4 frame loop ticks live with M6+ (animations / typewriter).
  end

  function driver:detach()
    -- Drop subscriptions before tearing down the surface so a stray
    -- in-flight mutation cannot fire into a half-closed screen.
    for i = 1, #self._unsubs do
      pcall(self._unsubs[i])
    end
    self._unsubs = {}
    self._widgets = {}
    self._by_path = {}
    -- §M6: tear down any leftover overlays. A clean shutdown is rare
    -- but matters under pcall/abort paths so the next attach starts blank.
    if self._view_stack then self._view_stack:clear(self) end
    if self._focus then self._focus:clear(self) end
    self._quit_pending = false
    self._kernel = nil
    if self._backend and self._backend.close then
      pcall(function() self._backend:close() end)
    end
    self._initialised = false
    self._screen = nil
  end

  -- ── Input dispatch ────────────────────────────────────────────

  local KEY_ESC = 27

  --- Block on the backend's `read_key` and translate keypresses to a
  --- 1-based choice index. Returns nil only when the player confirms
  --- the quit dialog (or the backend's key source is exhausted).
  ---
  --- §M6 dispatch order:
  ---   1. The top focus handler (a modal dialog, if any) gets first dibs.
  ---      If it consumes the key, we recompose (the modal may have
  ---      popped itself) and re-loop — except when its action set
  ---      `_quit_pending`, which exits the loop with nil.
  ---   2. ESC / q / Q open the quit-confirm dialog (curses-only — the
  ---      plain driver still treats these as immediate quit).
  ---   3. Digits 1..#choices return their 1-based index.
  ---   4. Everything else is ignored — loop continues.
  ---@param num_choices integer
  ---@return integer? idx
  function driver:_read_choice(num_choices)
    if not self._initialised then return nil end
    self._quit_pending = false
    while true do
      local key = self._backend:read_key()
      if not key then return nil end

      if self._focus and self._focus:dispatch(key, self) then
        -- The dialog likely popped itself; recompose so the next pass
        -- shows (or no longer shows) the modal frame.
        compose(self, self._last_choices, self._last_active)
        flush_frame(self)
        if self._quit_pending then return nil end
      elseif key == KEY_ESC
         or key == string.byte("q") or key == string.byte("Q") then
        self:_open_quit_dialog()
      elseif key >= string.byte("1") and key <= string.byte("9") then
        local d = key - string.byte("0")
        if d >= 1 and d <= num_choices then return d end
      end
    end
  end

  --- Push a "Really quit?" modal onto the view + focus stacks and
  --- recompose so the user sees it on the next backend read. The
  --- dialog's Yes action sets `_quit_pending`; either Yes, No, or
  --- ESC pops the modal off both stacks via the shared close fn.
  function driver:_open_quit_dialog()
    local self_ref = self
    local function close()
      if not self_ref._view_stack:empty() then
        self_ref._view_stack:pop(self_ref)
      end
      if not self_ref._focus:empty() then
        self_ref._focus:pop(self_ref)
      end
    end
    local d = dialog_mod.new({
      title = "Quit?",
      body  = "Really quit?",
      buttons = {
        { key = "y", label = "Yes",
          action = function() self_ref._quit_pending = true end },
        { key = "n", label = "No" },
      },
      on_select = function() close() end,
      on_cancel = function() close() end,
    })
    self._view_stack:push(d, self)
    self._focus:push(d, self)
    compose(self, self._last_choices, self._last_active)
    flush_frame(self)
  end

  -- ── Driver-private hooks for tests ────────────────────────────

  --- Expose the screen and backend so tests can introspect dirty rects
  --- and snapshot grids. Not part of the driver protocol.
  function driver:_screen_handle() return self._screen end
  function driver:_backend_handle() return self._backend end

  --- §M6 test seams: let specs drive view-stack assertions directly.
  function driver:_view_stack_handle() return self._view_stack end
  function driver:_focus_handle() return self._focus end

  return driver
end

return M

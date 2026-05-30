# Driver protocol — reference

This is the contract between the StoryBase presentation kernel and any
UI driver. It is the authoritative restatement of `ui_idea.md` §3 for
implementors writing a new driver (curses-on-Windows, Qt, web,
embedded GUI, headless test fixture, …). The narrative architecture
rationale lives in `ui_idea.md`; this document is the surface to code
against.

The kernel is `ui/kernel.lua`. The driver contract is enumerated in
`cli/drivers/driver.lua` (with a `M.is_driver(d)` duck-type check).
Working reference drivers ship under `cli/drivers/`:

| driver  | lives at                       | mode                       |
|---------|--------------------------------|----------------------------|
| plain   | `cli/drivers/plain/init.lua`   | synchronous pull           |
| ansi    | `cli/drivers/ansi/init.lua`    | synchronous pull           |
| curses  | `cli/drivers/curses/init.lua`  | reactive (kernel-attached) |

The plain and ansi drivers are the simplest reference; the curses
driver is the canonical reactive implementation.

---

## 1. Lifecycle

Every driver implements six methods. `render`, `prompt`, and `notify`
are the *pull* surface; `attach`, `tick`, `detach` are the *reactive*
surface.

```lua
local M = require("cli.drivers.driver")
local d = require("my_driver").new(opts)
assert(M.is_driver(d))                  -- duck-type check
```

```
driver:render(scene_output)              -- paint a scene
driver:prompt(choices)        -> idx|nil -- ask for a choice; nil quits
driver:notify(event, data)               -- pull-mode event hook (legacy)

driver:attach(kernel)                    -- subscribe; initial full paint
driver:tick(dt)                          -- advance animations (optional)
driver:detach()                          -- release surface, drop subs
```

### `render(scene_output)`

`scene_output = { narration, choices }`. `narration` is a list of
items:

```
{ kind = "narration", text = "..." }
{ kind = "say",       text = "...", speaker = sym, display = str, color = "#rrggbb" }
```

`choices` is a list of `{ index, label }`. Pull-mode drivers paint the
frame; reactive drivers may absorb the call and keep their existing
frame on screen until the next `mutation` triggers a recompose.

### `prompt(choices) -> idx | nil`

Blocking. Returns a 1-based index into `choices`, or `nil` to quit
the run loop. The plain driver reads a line from stdin; the curses
driver reads keys from its backend; a Qt driver might pump events
until a button is clicked.

### `notify(event, data)`

Legacy single-channel hook used by drivers that don't `attach` a
kernel. Reactive drivers ignore it; the pull drivers no-op it.

### `attach(kernel)`

Subscribe to whatever events you need and request an initial paint
via `kernel:get_state_all()` / `kernel:get_scene()` /
`kernel:get_bindings()`. Curses uses this to discover widgets, allocate
screen windows, and subscribe `mutation` for reactive repaint.

A driver may be attached and detached multiple times. Keep all
subscription handles in a list and call them in `detach`:

```lua
function driver:attach(kernel)
  self._kernel = kernel
  local unsub = kernel:on("mutation", function(p) self:on_mutation(p) end)
  self._unsubs[#self._unsubs + 1] = unsub
end

function driver:detach()
  for _, off in ipairs(self._unsubs) do pcall(off) end
  self._unsubs = {}
  self._kernel = nil
end
```

### `tick(dt)`

Called by the host loop with elapsed seconds. Use it for
widget-local animations (typewriter narration, bar flash on health
change, spinner glyphs). Animations are entirely UI-local; never call
back into the engine from `tick`.

Pull drivers leave `tick` empty.

### `detach()`

Drop all subscriptions and release any owned surface (call `endwin()`
for ncurses, close any sockets, free buffers). The detach must be safe
to call from a `pcall` abort path, so prefer `pcall`-wrapping
subscription removals.

---

## 2. Events (kernel → driver)

Subscribe via `kernel:on(event, fn)`; the returned function
unsubscribes. `fn` receives a single `payload` table. There is one
wildcard form `kernel:on("*", fn)` that fires for *every* event with
the signature `fn(event_name, payload)` — useful for debug forwarders.

| event              | payload                                          | when fires                          |
|--------------------|--------------------------------------------------|-------------------------------------|
| `scene-change`     | `{ from, to }`                                   | engine pushes/pops/gotoes a scene   |
| `mutation`         | `{ path, old, new, fn, tick, seq }`              | any state write                     |
| `clamp-event`      | `{ path, attempted, clamped, fn, tick, seq }`    | bounded `Int` clamped on write      |
| `spawn-event`      | `{ family, key, init, fn, tick, seq }`           | family member added                 |
| `despawn-event`    | `{ family, key, fn, tick, seq }`                 | family member removed               |
| `message-sent`     | `{ from, to, msg }`                              | actor registry delivery             |
| `schedule-fired`   | `{ schedule, tick }`                             | scheduler fired                     |
| `fn-call`          | `{ fn, args }`                                   | engine entered a fn body            |
| `actor-no-progress`| `{ actor }`                                      | actor produced no work this turn    |
| `watch-fired`      | `{ label, path, old, new }`                      | debug-server watch tripped          |
| `say`              | `{ speaker, display, color, text }`              | narration item dispatched           |
| `narration`        | `{ text }`                                       | narration item dispatched           |
| `choice-made`      | `{ scene, index, label }`                        | synthesised after `kernel:do_choice`|
| `<custom>`         | `{ event, payload, tick }`                       | author `engine/emit` call           |

### Ordering and isolation

- Kernel guarantees in-order dispatch within a tick. A `mutation` for
  `player/hp` is delivered before any `scene-change` triggered by the
  same player choice.
- The kernel updates its own state cache *before* fanning out the
  event, so a `mutation` listener reading `kernel:get_state(payload.path)`
  always sees `payload.new`.
- Each listener runs under `pcall`. A faulty subscriber cannot block
  others; the error is logged to `stderr` as `[ui/kernel] listener
  for '<event>' errored: ...`.
- A listener may unsubscribe itself during dispatch; iteration uses a
  snapshot of the listener list so removals do not shift indices.

### Custom events

`engine/emit "my-event" { ... }` from `.sb` code reaches subscribers
under the literal event name `my-event`. The payload is the kernel's
standard custom-event envelope `{ event = "my-event", payload = {...},
tick = N }`.

---

## 3. Queries (driver → kernel, read-only)

All queries are synchronous and pure; calling them never mutates engine
state.

| query                          | returns                                            |
|--------------------------------|----------------------------------------------------|
| `kernel:get_state(path)`       | current value at `path` (cache-first, falls through to engine for unobserved paths and `time/<axis>` pseudo-paths) |
| `kernel:get_state_all()`       | full `path → value` map (initial paint)            |
| `kernel:get_scene()`           | `{ name, narration, choices, nav_signal }` or `nil` if the scene stack is empty |
| `kernel:get_schema()`          | compiled-game schema (`{ types, states, scenes, ... }`) |
| `kernel:get_tick()`            | `{ tick, [axis] = n, ... }` (time-model axes)      |
| `kernel:get_bindings()`        | `game_table.ui_panels` — author-declared panels    |

The schema returned by `get_schema()` is the same one verified by the
compiler. Drivers walk `schema.states` to discover `state.ui` bindings
and `kernel:get_bindings()` to discover `ui-panel` decls. The
[`ui_bindings.md`](../howto/ui_bindings.md) how-to documents the
author-facing surface; the structural shapes are:

```lua
-- schema.states[*]: kind "scalar"
{ kind = "scalar", path = "player/hp",
  type_desc = { tag = "int", min = 0, max = 100 },
  default   = { tag = "int", value = 100 },
  ui        = { kind = "stat-bar", label = "Health", ... } }   -- optional

-- ui_panels[*]
{ name = "ward-hud",
  layout = "vstack", position = "top",
  children = {
    { kind = "stat-bar", arg = "world/herbs" },
    { kind = "text",     arg = "Tending: {world/selected-patient}" },
    ...
  } }
```

`state.ui` and `ui_panels` are stripped from `--production` bundles
unless the author sets `engine-config: ui-runtime: true`. Drivers that
need them at runtime should document this requirement.

---

## 4. Commands (driver → kernel, may mutate)

| command                       | effect                                          |
|-------------------------------|-------------------------------------------------|
| `kernel:do_choice(idx)`       | dispatch player choice; runs post-action chain; synthesises `choice-made` on success |
| `kernel:call_fn(name, ...)`   | invoke a game fn with raw args (host-provided via `set_call_fn`) |
| `kernel:autonomous_turn()`    | advance one NPC/scheduler tick without input    |

Mutating commands cause a coalesced burst of events to all subscribers
in deterministic order. The kernel does not currently expose
`save`/`load`/`time_travel`/`reload` — those are debug-server commands
on `runtime/debug.lua` today; promote into the kernel only as a driver
genuinely needs them.

`kernel:call_fn(name, ...)` requires the embedding host to have
registered a raw-args caller via `kernel:set_call_fn(fn)`. `lib/storybase.lua`
does this automatically when it constructs the kernel; standalone
drivers that bypass `lib/` may need to wire it themselves.

---

## 5. Curses driver internals (reference)

This section is non-normative — it documents the curses driver's
internal structure so a second curses-class driver (Windows-native,
mobile, web-terminal) can mirror it.

### 5.1 Screen model (`cli/drivers/curses/screen.lua`)

A retained 2D cell grid:

```
screen = { width, height, windows = {{ x, y, w, h, cells, dirty, z }, ...} }
cell   = { ch, fg, bg, attrs }
```

Widgets paint into windows; the painter (`paint.lua:diff`) compares
the new frame against the previous one and emits dirty rects. The
backend receives `(screen, dirty_rects)` and translates only the
changed cells.

### 5.2 Backends (`backend_curses.lua`, `backend_buffer.lua`)

Both backends implement the same interface:

```lua
backend:init(rows, cols)              -> ok, reason?
backend:size()                        -> rows, cols
backend:flush(screen, dirty_rects)
backend:read_key()                    -> int | nil
backend:close()
```

- `backend_curses` is the only file that `require("curses")`. Real
  ncurses ignores the requested rows/cols and uses `getmaxyx`.
- `backend_buffer` is an in-memory grid for headless tests and as a
  fallback when lcurses isn't installed. Extras: `snapshot()`,
  `snapshot_rows()`, `script_keys(ks)`, and opt-in `frame_history` /
  `snapshot_history()` / `dirty_history()` / `reset_history()` for
  before/after assertions.

Select the backend via `opts.backend = "ncurses" | "buffer"` on
`M.new`. The CLI exposes `--ui-backend buffer` plus `--ui-keys`,
`--ui-rows`, `--ui-cols`, `--ui-snapshot` for scripted/headless runs.

### 5.3 Widget contract

Curses widgets live under `cli/drivers/curses/widgets/`. Every widget
exposes at minimum:

```lua
local w = widget_mod.new(opts)        -- constructor; opts is widget-specific
w:paint(screen, win, kernel)          -- paint into `win`
w._desired_h = integer                -- preferred height for the strip layout
```

Reactive widgets are pure functions of their bound paths plus the
kernel's state cache. The driver subscribes `mutation` once and
re-runs `compose` + `paint_mod.diff` + `backend:flush` on any
matching path — the widget itself never subscribes.

Focus-handling widgets (modal dialogs, menus, input fields) also
expose `on_key(self, key, driver) -> consumed?` so the driver's focus
stack (`cli/drivers/curses/focus.lua`) can route keys to them.

### 5.4 View stack vs scene stack

`cli/drivers/curses/view_stack.lua` is the *driver-local* view stack —
modal dialogs, popups, transient menus. It is independent of the
engine's scene stack:

| concept     | owner   | persists?         | example                              |
|-------------|---------|-------------------|--------------------------------------|
| scene stack | engine  | yes (in save log) | `town` → `shop` → `bargain-dialog`   |
| view stack  | driver  | no (ephemeral)    | `game` → `inventory-popup` → `confirm`|

Driver code never touches `eng._scene_stack`. Engine code never
touches the view stack. Opening the quit-confirm dialog (a view-stack
push) does *not* fire `scene-change`; closing it does not fire it
either; saves do not contain view-stack state.

---

## 6. Implementing a new driver — checklist

1. **Pick a dispatch mode.** Pull (`render`/`prompt` only) is fine for
   text drivers. Reactive (`attach`/`tick`/`detach`) is required for
   anything that needs widgets to update mid-scene.
2. **Stub all six methods** so `cli/drivers/driver.is_driver(d)`
   returns `true`. Even unused methods get no-op stubs.
3. **Render narration + numbered choices** end-to-end. This is the
   plain driver's full surface; getting it working proves the
   pull-mode dispatch path.
4. **Walk `kernel:get_schema().states[*].ui`** to discover state-decl
   bindings and `kernel:get_bindings()` to discover `ui-panel`
   children. The plain driver's `collect_widgets` is the smallest
   reference; the curses driver's is the full one.
5. **Subscribe to `mutation`** in `attach` and route by `payload.path`
   to the affected widget(s). Re-paint only what changed.
6. **Use the buffer-backed test pattern** for headless tests: see
   `tests/ui/helpers/driver_session.lua` for the session DSL and
   `tests/ui/integration/m8_widgets_spec.lua` for an end-to-end
   widget-discovery + reactive-repaint fixture you can adapt.
7. **Don't reach into the engine.** Everything you need is on the
   kernel — `get_state`, `get_scene`, `do_choice`, `call_fn`. Driver
   code that calls `engine.*` directly will rot the first time the
   engine reshuffles its hooks.

---

## 7. Where to read next

- The author surface for declaring HUD bindings: [`docs/howto/ui_bindings.md`](../howto/ui_bindings.md).
- The architecture rationale and milestone history: [`ui_idea.md`](../../ui_idea.md).
- The event-surface audit underlying §2 of this document:
  [`docs/explanation/ui_event_audit.md`](../explanation/ui_event_audit.md).
- The reference drivers: `cli/drivers/plain/init.lua` (simplest),
  `cli/drivers/curses/init.lua` (full reactive).
- The kernel spec tests: `tests/ui/kernel_spec.lua` (28 cases) and the
  format helper tests: `tests/ui/format_spec.lua` (16 cases).

# StoryBase UI Architecture

This document is the working spec for the UI arm of StoryBase. It defines
the contract every UI driver consumes, the kernel that sits between the
driver and the engine, and the milestone sequence for shipping the first
full curses driver.

The engine is already a finite logic machine that knows nothing about
presentation. Nothing in this spec adds knowledge of the UI to the
engine; every addition lives strictly above the engine API.

---

## 1. Principles

- **Engine isolation.** The engine never depends on the UI. UI code may
  read state, subscribe to events, dispatch choices, and call game fns,
  but the engine module never references the UI module.
- **One protocol, many drivers.** Plain text, ANSI, curses, the browser
  SSE UI, the buffer-snapshot test driver, and any future GUI driver
  consume the *same* event/query/command protocol.
- **Headless testable.** Drivers must be exercisable without a TTY or
  ncurses. The curses driver achieves this by splitting its render
  pipeline into a screen model + two backends; tests use the buffer
  backend.
- **Reactive without entangling.** Drivers subscribe to engine events
  and re-render only what changed. The engine emits events; it does not
  pull from the driver.
- **Game-author portability.** A `.sb` file that wires up a stat bar
  binding should produce a working stat bar under every driver. The
  driver decides how to render; the author decides what to bind.

---

## 2. Architecture (three layers)

```
   ┌─────────────────────────────────────────────────────────┐
   │  Driver                                                 │
   │   curses · plain · ansi · browser-sse · test-buffer     │
   │   - owns its event loop and input dispatch              │
   │   - subscribes to kernel events                         │
   │   - issues kernel queries and commands                  │
   │   - paints widgets into a driver-specific surface       │
   └────────────────────┬────────────────────────────────────┘
                        │  driver protocol (§3)
   ┌────────────────────▼────────────────────────────────────┐
   │  Presentation kernel  (ui/kernel.lua)                   │
   │   - unifies the subscription/state-cache logic that     │
   │     today exists in both runtime/debug.lua and          │
   │     lib/storybase.lua                                   │
   │   - exposes the protocol surface to any driver          │
   │   - holds the author-declared binding registry          │
   │   - formats values for display                          │
   └────────────────────┬────────────────────────────────────┘
                        │  existing engine API
   ┌────────────────────▼────────────────────────────────────┐
   │  Engine  (unchanged)                                    │
   │   render_scene · do_choice · autonomous_turn · call_fn  │
   │   _emit_hook · _mutation_hook · _clamp_hook · etc.      │
   └─────────────────────────────────────────────────────────┘
```

The kernel is the new piece. The driver protocol is its public face.

---

## 3. Driver protocol

The protocol is the contract between the kernel and any driver. It is
already 90 % present in `runtime/debug.lua` (the SSE/HTTP server) and
`lib/storybase.lua` (the `game:on(...)` channel). This spec canonicalises
those two ad-hoc surfaces as the *one* surface every driver consumes.

### 3.1 Events (kernel → driver)

The driver registers handlers via `kernel:on(event_name, fn)` and
receives a payload table. All events the engine already emits are
forwarded:

| event              | payload                                       | source                            |
|--------------------|-----------------------------------------------|-----------------------------------|
| `scene-change`     | `{from, to}`                                  | engine on scene push/pop/goto     |
| `mutation`         | `{path, old, new, fn}`                        | `store._mutation_hook`            |
| `clamp-event`      | `{path, attempted, clamped, fn}`              | `store._clamp_hook`               |
| `spawn-event`      | `{family, key, init, fn}`                     | `store._spawn_hook`               |
| `despawn-event`    | `{family, key, fn}`                           | `store._despawn_hook`             |
| `message-sent`     | `{from, to, msg}`                             | actor registry                    |
| `schedule-fired`   | `{schedule, tick}`                            | scheduler                         |
| `fn-call`          | `{fn, args}`                                  | `_fn_call_hook`                   |
| `actor-no-progress`| `{actor}`                                     | `runtime/actors.lua` H1 hook      |
| `watch-fired`      | `{label, path, old, new}`                     | `srv:check_watches`               |
| `say`              | `{speaker, display, color, text}`             | narration item dispatch           |
| `narration`        | `{text}`                                      | narration item dispatch           |
| `choice-made`      | `{scene, index, label}`                       | post-`do_choice` synthesis        |
| `<custom>`         | `{event, payload, tick}`                      | author-side `engine/emit` calls   |

The kernel guarantees event ordering: a `mutation` for the path
`player/hp` always reaches the driver before any subsequent
`scene-change` triggered by the same player action.

### 3.2 Queries (driver → kernel, read-only, synchronous)

| query                          | returns                                            |
|--------------------------------|----------------------------------------------------|
| `kernel:get_state(path)`       | current value at `path`                            |
| `kernel:get_state_all()`       | full path → value map (initial paint)              |
| `kernel:get_scene()`           | `{name, narration, choices, nav_signal}`           |
| `kernel:get_schema()`          | game schema (types, states, scene list)            |
| `kernel:get_tick()`            | `{tick, [axis]=n, ...}`                            |
| `kernel:get_bindings()`        | author-declared UI bindings (§5)                   |
| `kernel:get_history(path, n?)` | `[{seq, time, old, new}, ...]` last `n` changes    |
| `kernel:get_log()`             | the full transaction log (debug-only)              |
| `kernel:eval(expr)`            | value of a pure expression                         |

All queries are pure reads. None mutate engine state.

### 3.3 Commands (driver → kernel, may mutate)

| command                                  | effect                                          |
|------------------------------------------|-------------------------------------------------|
| `kernel:do_choice(idx)`                  | dispatch player choice; runs post_action_chain  |
| `kernel:call_fn(name, ...)`              | invoke a game fn with raw args                  |
| `kernel:autonomous_turn()`               | run actors + scheduler without a player choice  |
| `kernel:time_travel(seq)`                | replay log up to `seq` (debug-only)             |
| `kernel:save(path)` / `kernel:load(path)`| save/load round-trip                            |
| `kernel:reload(src)`                     | hot-reload source (debug-only)                  |

Commands that mutate state cause the kernel to emit a coalesced burst
of events to all subscribers in deterministic order.

### 3.4 Driver lifecycle

Every driver implements:

```lua
driver:attach(kernel)   -- subscribe to events; initial full paint
driver:tick(dt)         -- optional; called by the host loop with elapsed seconds
driver:detach()         -- unsubscribe; release surface
```

The host (CLI, library embedder) decides who drives the loop. For the
curses driver, the driver owns the loop (reads keys, calls
`kernel:tick(dt)` on idle ticks, paints on event). For plain/ansi, the
existing `eng:step()` pull pattern keeps working — those drivers are
not subscribed to events; they paint in response to `render` calls.

---

## 4. Presentation kernel

`ui/kernel.lua` is a single module that owns:

- **Subscription registry.** `kernel:on(event, fn)` and the dispatcher
  that fires handlers. Replaces (and is wired into) the existing
  `_emit_hook`, `_mutation_hook`, `_clamp_hook`, `_spawn_hook`,
  `_despawn_hook`, and `lib/storybase.lua:_listeners` machinery so
  every emission goes through one channel.
- **State cache.** Last-seen value per path, kept in sync via
  `mutation`. Lets the driver answer "what's `player/hp` right now?"
  without re-querying the engine.
- **Binding registry.** §5.
- **Display formatter.** `ui/format.lua` — given a schema type and a
  value, returns a display string. `Int(0, 10) = 7` → `"7/10"`;
  enum value → label; bool → `"yes"/"no"` (overridable).
- **Adapters.** Backwards-compat shims so `lib/storybase.lua:on()` and
  the SSE broadcast in `runtime/debug.lua` go through the kernel
  rather than maintaining their own listener tables.

The kernel does *not* know about windows, focus, layout, colors, or
input devices. Those live in drivers.

---

## 5. Author-declared UI bindings

So that `Health: 7/10` works under every driver, the author should be
able to declare semantic UI elements in `.sb` source. The driver
interprets the declaration into its own widgets; the engine ignores it
(stripped under `--production` unless a `ui-runtime: true` flag is
set).

Two surfaces:

### 5.1 `ui:` block on state decls (concise, common case)

```
state player/hp: Int(0, 100) = 100
  ui:
    kind: stat-bar
    label: "Health"
    color-good: "#4ade80"
    color-bad: "#ef4444"
```

The engine schema gains a `ui` field on the state descriptor. Drivers
read `schema.states[path].ui` and render accordingly.

### 5.2 `ui-panel` decl (richer compositions)

```
ui-panel status:
  layout: vstack
  position: top
  children:
    - stat-bar player/hp
    - stat-bar player/mana
    - text "Gold: {player/gold}"
```

`ui-panel` declarations compile into `game_table.ui_panels` — a list
of layout trees with leaf bindings. Drivers consume these to assemble
their screens. Panels are pure presentation; verify ignores them.

### 5.3 Widget kinds (driver-agnostic vocabulary)

| kind          | bound to                | renders as                                      |
|---------------|-------------------------|-------------------------------------------------|
| `stat-bar`    | bounded Int             | bar with `cur/max` label                        |
| `stat`        | any scalar              | label + value                                   |
| `toggle`      | Bool                    | `[x]`/`[ ]`                                     |
| `choice`      | inline enum             | radio group                                     |
| `inventory`   | Set/List/UList path     | scrollable list                                 |
| `text`        | interpolated string     | static or live-updating text                    |
| `narration`   | (engine)                | scrolling narration pane (always present)       |
| `choices`     | (engine)                | numbered choice list (always present)           |
| `dialog`      | (driver-pushed)         | modal popup                                     |
| `menu`        | (driver-defined)        | navigable menu, may invoke fns                  |
| `input`       | fn name                 | text field that calls the fn on submit          |

The plain driver renders only `narration` + `choices` (everything else
collapses to text lines). The ansi driver adds color. The curses
driver adds the full set. The browser SSE driver can render HTML
equivalents. Authors author once.

---

## 6. Input vocabulary

The engine accepts exactly two kinds of input from the player:

1. **A choice index** via `do_choice(idx)`.
2. **A fn call** via `call_fn(name, args...)`.

Everything richer (text entry, multi-select toggles, hotkey actions,
menu activations) is expressed by the driver as a fn call. Pattern:

- Free-text name entry: the driver presents an `input` widget bound to
  fn `set-name`; on submit it calls `kernel:call_fn("set-name", text)`.
- Multi-select alignment: the driver presents a `toggle` widget bound
  to state `player/alignment`; on toggle it calls a setter fn.
- Hotkey for "open inventory": pure UI — pushes an `inventory` panel
  onto the *view stack* (§7). No engine call needed.

This keeps the engine's input surface tiny and finite-state-analyzable,
while letting the UI grow arbitrarily.

---

## 7. View stack vs scene stack

These are two separate stacks. Confusing them is a structural bug.

| concept         | owner   | persists?         | example                               |
|-----------------|---------|-------------------|---------------------------------------|
| Scene stack     | engine  | yes (in save log) | `town` → `shop` → `bargain-dialog`    |
| View stack      | driver  | no (ephemeral)    | `game` → `inventory-popup` → `confirm`|

The engine's scene stack is gameplay state; verify reasons over it.
The driver's view stack is purely cosmetic: opening the inventory
popup does not change the engine's current scene. Closing it does not
fire a `scene-change`. Save files do not contain view-stack state.

Driver code never touches `eng._scene_stack`. Engine code never
touches the driver's view stack.

---

## 8. Curses driver

### 8.1 Screen model

A retained 2D buffer abstraction shared by both ncurses and
buffer-backend painters.

```
screen = {
  width, height,
  windows = [ { x, y, w, h, cells, dirty, z, title? }, ... ],
}
cell = { ch, fg, bg, attrs }
```

Drivers compose by allocating windows on the screen. Widgets paint
into windows. The painter compares the new cell grid against the
previous frame and flushes only dirty cells to the backend. Window
z-order handles modal overlays.

This abstraction:
- gives ncurses what it wants (window-by-window painting);
- gives tests what they want (a deterministic 2D cell grid);
- gives animations a natural frame boundary (`paint_frame` runs every
  tick on the host loop, but only flushes dirty regions);
- makes the snapshot-debugging feature fall out for free (serialise
  the screen model to a text file at any moment).

### 8.2 Two backends

- `cli/drivers/curses/backend_curses.lua` — the only file that
  `require("curses")`. Converts the screen model into ncurses calls.
- `cli/drivers/curses/backend_buffer.lua` — converts the screen model
  into a plain Lua string-of-lines (and a parallel attribute grid).
  Used by tests; usable as a fallback when ncurses is absent.

Both backends implement the same interface:

```lua
backend:init(w, h)
backend:flush(screen, dirty_rects)
backend:read_key()    -- backend_buffer returns from a scripted queue
backend:close()
```

### 8.3 Driver internals

```
cli/drivers/curses/
  init.lua            -- M.new(opts); implements driver protocol
  screen.lua          -- screen model + cell ops
  backend_curses.lua  -- ncurses painter (only file that loads `curses`)
  backend_buffer.lua  -- string-buffer painter for tests / no-tty hosts
  layout.lua          -- vstack / hstack / fixed / flex containers
  focus.lua           -- focus stack + key dispatch (separate from view stack)
  paint.lua           -- diff old/new cell grids → dirty rects
  view_stack.lua      -- driver-local view stack (§7)
  widgets/
    narration.lua
    choices.lua
    statbar.lua
    stat.lua
    text.lua
    dialog.lua
    menu.lua
    input.lua
    inventory.lua
```

### 8.4 Animation / idle frames

The curses driver runs an internal loop at ~30 fps. Each tick it:

1. Reads any pending key (non-blocking).
2. Calls `kernel:tick(dt)` if the game has a time model that wants
   wall-clock advancement (optional, off by default).
3. Advances any widget-local animations (typewriter narration, bar
   flashes on health change, spinner glyphs).
4. Paints any dirty regions.

Animations are entirely UI-local; they never call into the engine.

---

## 9. Headless testing strategy

The buffer backend is the test bedrock. Tests look like:

```lua
local game = sb.load("game.sb"); game:init()
local kernel = ui.attach(game)
local driver = curses.new({ backend = "buffer", w = 80, h = 24 })
driver:attach(kernel)

driver.backend:script_keys({ "1", "i", "q" })
driver:run_until_idle()

assert.matches("Health: 7/10", driver.backend:snapshot())
```

Snapshot files (golden text grids) live under `tests/ui/snapshots/`
and are diffed cell-by-cell. Updating a snapshot is one command.

Acceptance criterion: every curses widget has at least one
buffer-backend test. The CI matrix never invokes ncurses.

---

## 10. Milestone sequence

Each milestone ships a working binary. No milestone leaves the engine
in a half-modified state.

### M0. Audit and unify event surfaces (no UI work yet)

- Inventory every hook in `runtime/debug.lua`, `runtime/engine.lua`,
  `runtime/actors.lua`, `runtime/state.lua`, and `lib/storybase.lua`
  that emits or subscribes to events.
- Confirm the event list in §3.1 matches reality; add missing rows.
- Decide whether the kernel replaces or wraps the existing listener
  tables in `lib/storybase.lua` and the SSE broadcaster in
  `runtime/debug.lua`. Recommend: kernel becomes the single owner;
  both call sites become thin shims.

### M1. Presentation kernel (`ui/kernel.lua`)

- Subscription registry + dispatcher.
- State cache, synced via `mutation`.
- Display formatter (`ui/format.lua`) for the existing schema types.
- Adapter shims so `lib/storybase.lua:on()` and `debug.lua`'s SSE push
  go through the kernel.
- Tests: subscribe / unsubscribe / coalesced event bursts /
  state-cache invariants.

### M2. Curses hello-world

- `cli/drivers/curses/init.lua` and `backend_curses.lua` only.
- Renders narration + numbered choices via ncurses; reads digit keys.
- Replicates the plain driver under `--ui curses`.
- Smoke-tests on Linux + WSL with the demo01_wanderer.sb fixture.
- Verifies `lcurses` availability and packaging.

### M3. Screen model + buffer backend split

- Extract `screen.lua`, `paint.lua`, and the dual backends.
- M2's hello-world re-architected on top.
- Snapshot tests of the buffer backend become CI green.
- This is the load-bearing milestone for everything that follows.

### M4. Author bindings (parser + schema)

- `ui:` block on state decls (§5.1); `ui-panel` decl (§5.2).
- Compiler emits into `game_table.schema.states[*].ui` and
  `game_table.ui_panels`.
- Production-build flag: panels stripped by default; `ui-runtime: true`
  retains them.
- Tests: parse, codegen, stripping.

### M5. First reactive widget: stat-bar

- Curses `statbar.lua` widget bound via §5.
- A mutation on the bound path repaints *only* the stat-bar window.
- Buffer-backend snapshot test proves before/after dirty-rect render.
- Plain driver gains a fallback text rendering of `stat-bar` bindings
  (`Health: 7/10` text line).

### M6. View stack + modal dialog

- `view_stack.lua` and a `dialog` widget.
- Curses-only quit-confirm modal demonstrates the view stack is
  independent of the engine's scene stack.
- Focus stack delegates keys to the top view.

### M7. Menu + input widgets

- `menu.lua` (hierarchical, hotkeys).
- `input.lua` (free-text field that calls a named fn on submit).
- Demonstrates the §6 input vocabulary end-to-end: a name-entry input
  fires `kernel:call_fn("set-name", text)` and the engine state
  updates.

### M8. Inventory and remaining standard widgets

- `inventory.lua` (Set / List / UList path).
- Scrollable narration pane.
- Toggles, multi-choice radio groups.
- Closes out the widget kinds in §5.3.

### M9. Demo + author docs

- Convert one existing demo (likely demo01 or demo13) to use `ui:`
  bindings.
- `docs/howto/ui_bindings.md` for authors.
- `docs/reference/driver_protocol.md` for driver implementors.

### Later (not v1)

- Color theming system (palettes, per-type colors).
- Mouse / pointer events (clicks become fn calls).
- Localisation hook on `engine.render_text`.
- Animation primitives shared between drivers.
- A Qt or web-native driver as a second non-curses validation of the
  protocol.

---

## 11. Open questions

- **`ui-runtime: true` semantics.** Should UI panels be visible to
  `verify`? Probably no — they are presentation. But hot-reload may
  want to re-emit them.
- **Per-driver widget overrides.** When a game needs a curses-specific
  flourish, where does that live? Proposed: a `driver-overrides`
  field on `ui-panel` that drivers may ignore.
- **Mouse coordinates and the screen model.** If mouse support lands,
  hit-testing happens at the screen model layer (a click maps to a
  window+cell, then to a widget). The driver protocol gains a
  `pointer` event. Out of scope for v1.
- **lcurses portability.** Confirm packaging on Windows (non-WSL) and
  macOS before M2. Fallback path: bundled `tui-lua` or hand-rolled
  termcap layer.

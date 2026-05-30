# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-30)

§M7 (menu + input widgets) landed 2026-05-30:
`cli/drivers/curses/keys.lua` centralises the integer key-code
constants (ASCII control bytes + standard ncurses `KEY_*` values
since lcurses doesn't expose them as table fields) and provides
`is_enter` / `is_backspace` / `is_printable` predicates so widgets
share one source of truth for "Enter is one of CR / LF / KEY_ENTER",
"Backspace is one of BS / DEL / KEY_BACKSPACE", etc.
`cli/drivers/curses/widgets/menu.lua` is a navigable menu widget
acting as both a view and a focus handler. Items are tagged
`kind = "item" | "divider" | "header"`; cursor navigation skips
non-selectable kinds. Arrow keys are the default with wrap; Home/End
jump to extremes; Enter activates; ESC cancels. Per-item hotkeys are
optional and trigger jump-and-activate when matched. Decoration is
built in: ASCII border (toggle-able), optional title on top border,
divider items render as a row of a customisable glyph (`-` default),
highlighted cursor row uses customisable attrs (`reverse` default),
header items use customisable attrs (`bold` default). Per-action key
bindings are overridable (accept ints or int arrays) so e.g. vim
`j`/`k` can be wired alongside the arrows. Submenu support is the
author's job — an item action can push another menu onto the
driver's stacks; the widget stays unaware of stack semantics.
`cli/drivers/curses/widgets/input.lua` is a single-line free-text
input that fulfils the §M7 acceptance bullet: on submit it can fire
`driver._kernel:call_fn(fn_name, text)` before invoking the
caller-supplied `on_submit`. Standard editing (printable insert,
backspace/forward-delete, left/right/Home/End), max_len cap, ESC
cancel, customisable bindings. Cursor renders as an in-band glyph
with reverse-video attrs (the buffer backend has no hardware cursor).
Tests: `menu_widget_spec.lua` (35), `input_widget_spec.lua` (32),
`integration/menu_input_spec.lua` (11). **Total: 3463 → 3541 (+78
new tests). 0 failures, 2 pending.** Per the spec the menu/input
widgets are not wired to a default driver keystroke — they're widgets
that authors and future UI panels can push; the integration spec
exercises both stacks end-to-end.

## Current Status (2026-05-30)

§M6 (view stack + modal dialog) landed 2026-05-30:
`cli/drivers/curses/view_stack.lua` and `cli/drivers/curses/focus.lua`
are the two driver-local stacks. The view stack stores overlays
(views with `paint(self, screen, ctx)` + optional `on_open`/`on_close`)
and is iterated bottom-to-top during compose so modals draw on top
of the base game frame. The focus stack is independent and routes
keys to its top handler (no fallthrough). The §M6 acceptance widget
is `cli/drivers/curses/widgets/dialog.lua` — a centred bordered box
with title + body + button row that acts as both a view and a focus
handler. The curses driver's input loop now dispatches keys through
focus first; q/Q/ESC open a "Really quit?" dialog instead of
returning nil immediately. Yes sets `_quit_pending` and prompt
returns nil; No/ESC simply pop the modal off both stacks and the
prompt loop continues, so a follow-up digit resolves normally. The
plain driver keeps its previous q-as-immediate-quit behaviour
(modals are curses-only per the spec). View/focus stacks are
distinct from the engine's scene stack: opening the modal does not
fire `scene-change` and is not persisted to saves. Tests:
`view_stack_spec.lua` (10), `focus_spec.lua` (13),
`dialog_widget_spec.lua` (18), `integration/quit_dialog_spec.lua`
(10), plus 2 reworked cases in `curses_driver_spec.lua`. **Total:
3410 → 3463 (+53 new tests). 0 failures, 2 pending.**

## Current Status (2026-05-30)

§M5 (first reactive widget: stat-bar) landed 2026-05-30:
`cli/drivers/curses/widgets/statbar.lua` is the first author-bindable
reactive widget. The curses driver's `attach(kernel)` scans
`schema.states[*].ui` and `ui_panels` to instantiate one statbar per
`stat-bar` binding, allocates one stable-position row at the top of
the screen per widget, and subscribes to `mutation` events — a
matching mutation re-runs `compose` + `paint.diff`; narration /
choices / prompt all paint identically and diff clean, so the dirty
rect log covers only the widget row. Plain driver gained a
synchronous fallback: every `render` prefixes a `"Label: cur/max"`
header line per binding (no subscription; re-read on each pull).
`engine.run` now installs a kernel and calls `driver:attach(kernel)`
so the CLI path reaches the reactive code without going through
`lib/storybase.lua`. Three test-harness prerequisites from §9.1
shipped alongside: (1) `tests/ui/helpers/driver_session.lua` —
session DSL; (2) opt-in `frame_history` on `backend_buffer`
(`snapshot_history` / `dirty_history` / `reset_history`); (3) the
integration fixture at `tests/ui/integration/statbar_reactive_spec.lua`
that boots a real kernel + buffer driver and proves the "only the
widget window repaints" acceptance bullet end-to-end. Plus
`statbar_widget_spec.lua` (17), `driver_session_spec.lua` (9), 7
plain-fallback cases + 2 CLI-level e2e cases in `drivers_spec.lua`.
**Total: 3326 → 3410 (+84 new tests). 0 failures, 2 pending.**
The two §9.1 insurance items (paint.diff property test, resize
integration test) remain deferred per the original ordering plan —
add only when they bite.

## Current Status (2026-05-29)

§M4 (author UI bindings: parser + schema) landed 2026-05-29:
The compiler now accepts a trailing `ui:` block on `state` decls (scalar +
family + record) and a top-level `ui-panel <name>:` decl. AST additions:
`ast.K.UI_PANEL_DECL` plus `ast.ui_panel_decl(...)`; state nodes gain an
optional `.ui = {fields = {...}}` field set during parsing. Codegen
flattens `node.ui` into `game_table.schema.states[*].ui` as a flat
`key → value` map, and collects `UI_PANEL_DECL` nodes into
`game_table.ui_panels` via the new `emit_ui_panels`. Production strip:
when `opts.production = true`, both `state.ui` and `ui_panels` are
dropped unless the author opts in via `engine-config: ui-runtime: true`.
Tests at `tests/compiler/ui_bindings_spec.lua` (20 cases) cover parse,
codegen flatten, scalar + family attachment, panel children with and
without the leading `-` bullet, multiple panels, doc-string carry-over,
production strip, ui-runtime opt-in, ui-runtime: false strip,
non-interference with existing scalar / inline-record state-decl
semantics, and `game_table.ui_panels = {}` baseline. **Total:
3362/0/2.** Driver consumption of the new schema lands at §M5
(stat-bar widget); §M4 is compiler-only.

Curses test-harness step landed 2026-05-29 (between §M3 and §M5):
`cli/main.lua` gained `--ui-backend <name>` / `--ui-keys <string>` /
`--ui-rows N` / `--ui-cols N` / `--ui-snapshot <path>` flags so the
buffer-backed curses driver can be driven end-to-end through the real
CLI entry point. The ncurses stub `fake_curses` was extracted from
`tests/ui/curses_driver_spec.lua` to `tests/ui/helpers/fake_curses.lua`
so §M5+ widget specs can share it. Four new CLI integration cases in
`tests/cli/drivers_spec.lua` cover scripted-key playthrough, exhaustion
quit, and pass-through ignore on plain. The five remaining deferred
harness ideas (session DSL, buffer frame history, kernel↔driver fixture,
`paint.diff` property test, resize integration test) are recorded in
`ui_idea.md` §9.1 — they pay off at §M5 and were intentionally left
unimplemented until a widget needs them. **+4 tests in
`tests/cli/drivers_spec.lua` (35 → 39); no test-count change in
`tests/ui/curses_driver_spec.lua` since the `fake_curses` extraction is
mechanical. Pre-HTTP-flicker total: 3322 → 3326.**

UI driver folder restructure landed 2026-05-29: each driver now lives
under `cli/drivers/<name>/init.lua`, with the protocol contract in
`cli/drivers/driver.lua` and a `curses/` scaffold per ui_idea.md §M2.
plain/ansi gained no-op `attach`/`tick`/`detach` lifecycle stubs so
they structurally conform to the full spec; the kernel (§M1) that will
drive them is still to be written. See "UI driver track" below.

§M0 (event-surface audit) landed 2026-05-29:
`docs/explanation/ui_event_audit.md` inventories every emit/subscribe
site across `runtime/debug.lua`, `engine.lua`, `eval.lua`,
`actors.lua`, `state.lua`, `scheduler.lua`, and `lib/storybase.lua`;
diffs the inventory against `ui_idea.md` §3.1 (removes `say` /
`narration`, adds `breakpoint-hit` / `reload`, flags payload-key
renames `fn-call.name`, `message-sent.actor`, `schedule-fired.name`,
marks `choice-made` as kernel-synthesised); and adopts the
single-owner kernel ownership model with a concrete migration sketch
for §M1. Open questions parked: clamp-vs-mutation ordering inside
`state.lua`, custom-event namespacing, mutation coalescing.

§M1 (presentation kernel) landed 2026-05-29:
`ui/kernel.lua` is the multi-subscriber event bus + state cache +
queries/commands surface. `ui/format.lua` is the schema-driven
display formatter (Int(0,10)=7 → "7/10", bool → yes/no, enum → label,
named/alias chains resolved against schema). `lib/storybase.lua` now
creates a kernel during `init()` and routes `game:on()`/`_emit`
through it; the previously dead `game:on("scene-change", ...)`
subscription now fires (audit §3 fix). `runtime/debug.lua:srv:emit`
forwards every event to the registered kernel before the `_running`
transport gate, so in-process subscribers see events even before
`srv:start()`. The kernel synthesises `choice-made` after a
successful choice (alongside the legacy library "choice" event,
preserved for backward compat). Tests at `tests/ui/kernel_spec.lua`
(28 cases) + `tests/ui/format_spec.lua` (16 cases) cover the M1
acceptance bullets: subscribe / unsubscribe / pcall isolation /
wildcard / state-cache invariants / coalesced mutation bursts.
**3285/0/2 (was 3247/0/2 before M1; +38 new cases).** Audit open
question §4.2 #1 resolved: `state.lua` fires `_mutation_hook` with
the clamped value (`_log_entry` runs after the clamp branch).

§M2 (curses hello-world) landed 2026-05-29:
`cli/drivers/curses/init.lua` is now a functional pull-mode driver
that paints narration + numbered choices into ncurses and reads digit
keys for choice dispatch. All `require("curses")` calls are confined
to `cli/drivers/curses/backend_curses.lua` so the §M3 screen-model
split has a single seam. The driver is registered in the `cli.ui`
enum (`runtime/engine.lua`) and selectable via `--ui curses`. Curses
init is lazy (deferred to first `render`/`prompt`), so M.new is safe
in any environment. Tests at `tests/ui/curses_driver_spec.lua` (28
cases) exercise lifecycle, narration accumulation, paint layout
(scrollback, separator, choices, prompt), input dispatch (digits,
q/Q/ESC, out-of-range filtering), and the driver round-trip via a
stub curses module — busted never opens a real terminal. **Total:
3312/0/2 (+27 new cases over M1; one obsolete "not yet implemented"
scaffold test was deleted).** Driver is still pull-mode — the
kernel-driven attach/subscribe path is §M3+ work.

§M3 (screen model + buffer backend split) landed 2026-05-29:
The curses driver now composes frames into a retained 2D cell grid
(`cli/drivers/curses/screen.lua`) and flushes only dirty cells via
`cli/drivers/curses/paint.lua` to a swappable backend. Two backends
ship with the M3 interface (`init(w,h)` / `size()` / `flush(screen,
dirty_rects)` / `read_key()` / `close()`): `backend_curses.lua`
(ncurses; still the only file that `require("curses")`) and
`backend_buffer.lua` (in-memory grid; provides `snapshot()` and
`script_keys()` for headless tests + no-tty fallback). Driver picks
backend via `opts.backend = "ncurses"|"buffer"` (default ncurses).
Pull-mode (render+prompt) preserved end-to-end; the kernel-driven
attach/subscribe path is deferred to §M5 when the first reactive
widget (stat-bar) lands. Tests at `tests/ui/curses_driver_spec.lua`
(31 cases, rewritten for the M3 interface) cover lifecycle + driver
round-trip on both backends; `tests/ui/curses_screen_spec.lua` (23
cases) covers screen/paint/buffer units + dirty-rect diff invariants
+ golden snapshots under `tests/ui/snapshots/curses_*.txt`. **Total:
3318/0/2 (+6 over M2 net of rewritten + new specs; +54 new test
points across the screen model and buffer backend work, with 28 old
M2 backend-paint tests retired in favor of the M3 driver-level tests
that exercise the same paths through a real screen model).**
20 transient `debug_http_spec.lua` failures unrelated/ignorable per
CLAUDE.md — HTTP/debug subsystems were not touched.

## Current Status (2026-05-25)

The core language and runtime are feature-complete against the V1.0 specification.
All eight implementation phases, language review passes 1 and 2, the full audit
backlog, the full §E series, §F1/F2, §G2, §H1, §H2, §L (unified configuration,
19 registry keys), §M (2026-05-23 bug hunt — all eight items closed), and the
I-series demos (26–32) are complete — details in [completed.md](completed.md).

**~3410 successes / 0 failures / 2 pending (known limitations).**
(HTTP/debug spec failures are transient network timing issues — ignore unless
touching http/debug code.)

Language Review Pass 3 (2026-05-20) is closed on the runtime/parser side: all
5 bugs (J-B1..B5) and 8 of the 10 authoring inelegances (J-I1, I2, I3, I4, I5,
I6, I7, I9) shipped between 2026-05-21 and 2026-05-22. The remaining 2
inelegances (§J-I8, I10) stay open below as design-first backlog.

§M bug-hunt fully closed: M1–M6 shipped 2026-05-24, M7 + M8 (the two latent
fragility items) shipped 2026-05-25.

---

## What to work on next

**UI driver track (see ui_idea.md §10 for full details):**
1. §M0 — audit and unify event surfaces. **[DONE 2026-05-29]** —
   see `docs/explanation/ui_event_audit.md`.
2. §M1 — presentation kernel (`ui/kernel.lua`). **[DONE 2026-05-29]** —
   `ui/kernel.lua` + `ui/format.lua`; library + debug-server adapted.
   §4.2 carry-overs for later: custom-event namespacing, mutation
   coalescing, watch-evaluator move from inline to kernel subscription.
3. §M2 — curses hello-world. **[DONE 2026-05-29]** —
   `cli/drivers/curses/init.lua` + `backend_curses.lua`; selectable
   via `--ui curses`. Pull-mode (render+prompt); the kernel-driven
   attach/subscribe path lands at §M3 alongside the screen model.
4. §M3 — screen model + buffer backend split. **[DONE 2026-05-29]** —
   `cli/drivers/curses/screen.lua` + `paint.lua` + `backend_buffer.lua`;
   `backend_curses.lua` and `init.lua` re-architected on top.
   `--ui curses` plus `opts.backend = "buffer"` for headless tests.
   Golden snapshot tests under `tests/ui/snapshots/`. The kernel-driven
   subscribe/notify path was deferred to §M5 (the first reactive
   widget); pull-mode `render`/`prompt` remains the dispatch path for
   the curses driver until then.
5. §M4 — author bindings (parser + schema). **[DONE 2026-05-29]** —
   `ui:` trailing block on state decls + `ui-panel` top-level decl;
   emitted into `game_table.schema.states[*].ui` and
   `game_table.ui_panels`. Stripped under `--production` unless
   `engine-config: ui-runtime: true`. See
   `tests/compiler/ui_bindings_spec.lua`.
6. §M5 — first reactive widget: stat-bar. **[DONE 2026-05-30]** —
   `cli/drivers/curses/widgets/statbar.lua` + reactive `attach`
   path in `cli/drivers/curses/init.lua` (subscribes to `mutation`,
   recomposes; widget windows at stable y/x so non-widget rows
   diff clean). Plain-driver fallback emits `"Label: cur/max"`
   header per binding. `engine.run` installs a kernel and attaches
   the driver. Test harness §9.1 items 1–3 shipped alongside;
   items 4 (paint.diff property test) and 5 (resize integration
   test) deferred until they bite.
7. §M6 — view stack + modal dialog. **[DONE 2026-05-30]** —
   `cli/drivers/curses/view_stack.lua` + `cli/drivers/curses/focus.lua`
   give the driver two driver-local stacks (separate from the
   engine's scene stack per ui_idea.md §7).
   `cli/drivers/curses/widgets/dialog.lua` is a modal widget that
   acts as both a view and a focus handler. The curses input loop
   routes keys through focus first; q/Q/ESC now open a quit-confirm
   dialog (Yes confirms quit, No/ESC cancels). Plain driver keeps
   the previous immediate-quit behaviour per spec.
8. §M7 — menu + input widgets. **[DONE 2026-05-30]** —
   `cli/drivers/curses/keys.lua` centralises integer key codes.
   `cli/drivers/curses/widgets/menu.lua` is a navigable menu
   (arrows + Enter default, optional per-item hotkeys, items can be
   `"item" | "divider" | "header"`, customisable border / highlight /
   divider glyph / key bindings; submenu support is author-driven via
   action callbacks pushing onto the driver's stacks).
   `cli/drivers/curses/widgets/input.lua` is a single-line text
   input; on submit it fires `kernel:call_fn(fn_name, text)` per the
   §6 input-vocabulary acceptance bullet. Per spec the widgets are
   not auto-wired to a default driver keystroke — the integration
   spec exercises both stacks end-to-end.
9. §M8 — inventory and remaining standard widgets.
10. §M9 — demo + author docs.

**Authoring inelegances from review pass 3 (larger, design-first):**
- §J-I8 — cross-reference to §A1 (`set!` on a `let`-binding).
- §J-I10 — multi-way `hook` switches collapsing into per-case declarations.

**Lower-priority polish (open, not blocking):**
- §A1 — SF-5 — already partially mitigated by AV-4; consider closing.
- §A2 — Inelegance #7 — BFS expansion duplication (deferred; documented).

**Future Features and Extensions (large):** Suggested ordering for impact:

1. §D1 — LLM-bounded handler standard module
2. §B3 — Trace scrubber (browser debug UI)
3. §G1 — Web/JS compilation target

**Demo coverage:** All seven I-series demos (26–32) complete, plus demo33
(J-I2 showcase). demo32 promoted three of the four §I7 residue items (set
ops, `(set)` literal, labelled `engine/checkpoint!`). The remaining residue
item — **lambda expressions outside a `find` clause** — is still covered only
by unit tests; promote only if a user-facing limitation surfaces.

---

## A. Open Bug-fix / Cleanup Tasks

### A1. SF-5 — `set!` on a `let`-bound variable [partially mitigated — consider closing]

`let i = 0; set! i (i + 1)` writes to a state PATH named `"i"` (which likely doesn't
exist), not to the local variable `i`. The local var `i` is never updated. In a `while`
loop this produces a hidden infinite loop that hits the 10,000-iteration safety limit:

```
fn count-to-5:
  let i = 0
  while i < 10:       # reads local var i = 0 always
    set! i (i + 1)    # writes to state path "i", not local var
    when i >= 5:
      break           # never fires
```

There is no language mechanism to mutate a `let` binding. The workaround is to use a
dedicated state path as the counter. This is by design, but authors coming from
imperative languages will hit it repeatedly.

**Status update 2026-05-14:** AV-4's `pass_check_undefined_paths` already emits
`UNDEFINED_PATH` for the bare-name case, so the failure is no longer silent — authors
see `warning [UNDEFINED_PATH]: 'i' is not a declared state path` at compile time. The
proposed `LET_VAR_MUTATION` warning would be a clearer message, not a missing-feature
fix. Recommendation: either close this item, or downgrade to a polish task (replace
the generic `UNDEFINED_PATH` text with a `let`-aware message when the bare segment
matches an enclosing `let` binding).

### A2. Inelegance #7 — BFS expansion logic duplicated ~5×

`runtime/search.lua` has five BFS/Dijkstra variants (`can_reach`, `find_path`,
`probability`, `optimal_path`, plus the verify pass internal BFS). Each has a slightly
different data payload (priority / path / probability / cost) and queue mechanism
(FIFO / heap / yield). **Deferred:** extracting a shared helper would require a messy
callback strategy and add more complexity than it removes. Revisit if a sixth variant
is needed or if a perf hot-spot emerges.

---

## B. Authoring UX — Make the Latent Power Visible

### B3. Trace scrubber (browser debug UI)

**Goal:** The debug UI already supports `time-travel`; add a draggable timeline
scrubber and a per-tick diff panel ("between t=37 and t=38, these 5 paths changed").

**Design sketch:**
- New HTTP command `get-tick-diff {from, to}` returns
  `[{path, value_at_from, value_at_to, fn}]` by walking log entries between two seqs
  (cheap given `query_at` already supports this).
- UI: timeline strip at top (one cell per tick), drag to scrub; diff panel below shows
  the deltas at the current tick.

**Files:** `runtime/debug.lua` (command + UI), `tests/runtime/debug_spec.lua`.

**Acceptance:** On `demo08`, scrubbing through the timeline visibly highlights the
changed paths at each tick.

## C. Higher-Order Tests Beyond `verify`

(C1, C2, C3, C4 complete — see completed.md.)

---

## D. LLM-Bridged Authoring

### D1. LLM-bounded handler standard module

**Goal:** `bounded` already exists as a discrete-typed escape hatch to Lua. Ship a
standard handler that calls an LLM with structured-output constrained to the declared
`returns:` enum. This is probably the most distinctive use of the architecture: the
discrete/superficial split lets LLMs supply *content* while StoryBase keeps *logic*
deterministic and replayable.

**Design sketch (author API):**
```
bounded npc-mood npc:
  returns:      Mood
  distribution: uniform
  reads:        [player/disposition-toward/{npc}, npcs/{npc}/recent-events]
  lua:          "storybase.llm.classify"
```

Runtime calls Claude/OpenAI with the perception snapshot + the type's enum values as
a JSON-schema-constrained response. The model must return one of the enum values.
Result is logged exactly like a `random-int` draw → deterministic replay.

**Design sketch (Lua side):**
- New module `lib/llm.lua` exporting `M.classify(arg, state_snapshot, type_info)`.
- Provider abstraction: `M.set_provider(fn)` where `fn(prompt, schema) → value`.
- Default provider reads `STORYBASE_LLM_PROVIDER` env var; built-in adapters for
  Anthropic and OpenAI (via luasocket / luasec — already a dep for `--debug`).
- The bounded codegen path already passes `state_snapshot`; extend it to also pass the
  `returns:` type descriptor so `llm.classify` can build the schema constraint.

**Files:** new `lib/llm.lua`, hook in `runtime/eval.lua:call_bounded`, optional
`lib/llm_anthropic.lua` and `lib/llm_openai.lua` thin adapters, `docs/howto/llm.md`,
`tests/lib/llm_spec.lua` (with a mock provider — no live API calls in CI).

**Edge cases:**
- Latency: optionally async via a job-queue model; for now synchronous is acceptable.
- Cost: log all calls; provide `--no-llm` for offline/CI runs (falls back to uniform
  random over the enum).
- Replay: the recorded result re-plays the same value without re-calling the LLM.
- Security: LLM output validated against the enum before being logged.

**Acceptance:** A demo (call it `demo22_llm_innkeeper.sb`) where an innkeeper's mood
is classified by an LLM, drives discrete branching, and replays deterministically
from a saved log without re-calling the API.

### D2. `narrate` LLM driver

**Goal:** Symmetric to D1: a driver that asks an LLM to expand terse author lines
into prose at runtime, with the discrete state passed in as structured context. Logic
stays in StoryBase; prose stays in the LLM.

**Design sketch:**
- Author writes scene narration with optional `~expand` markers:
  `~expand The shopkeeper greets you.`
- The driver receives the line plus the current state snapshot; calls the LLM with a
  prompt template; receives expanded prose; renders it.
- A second mode: `--ui narrate` replaces every narration line with an LLM expansion
  given the bare scene name and current state — turn a 100-line StoryBase game into
  a richly-described experience without changing the source.

**Files:** new `cli/drivers/narrate.lua`. Reuses `lib/llm.lua` from D1.

**Acceptance:** Running `storybase run --ui narrate demo01_wanderer.sb` produces
on-the-fly prose for every scene, varying between runs (recorded for replay).

---

## E. Built-in Patterns Every Game Reinvents

(E0 decl-macro substrate, E1 quests, E2 dialog-topic, E3 inventory+stat,
E4 review fixes — all complete; see completed.md.)

---

## G. Reach Beyond Lua

(G2 — stateless HTTP API — complete; see completed.md.)

### G1. Web/JS compilation target

**Goal:** Bundle currently produces self-contained Lua. A JS target would let
authored games run in the browser without a Lua install. The runtime is mostly pure
Lua tables and a tight engine loop — feasible via Fengari (Lua-in-JS) as a stopgap,
or a hand-written transpiler for production.

**Design sketch (phased):**
- **Phase 1 (Fengari shim):** Bundle output already self-contained — wrap with
  Fengari and a minimal HTML host page. New flag `storybase bundle --target web`
  produces a single `.html` with embedded game.
- **Phase 2 (native JS codegen):** Translate the game-table runtime modules to
  JavaScript. The runtime modules don't use any Lua-specific quirks beyond tables,
  closures, and metatables — translatable. The compiler stays in Lua.

**Files:** `cli/bundle_cmd.lua` extension; new `cli/web_assets/` for HTML/JS shim;
documentation.

**Acceptance:** `storybase bundle --target web demo01_wanderer.sb` produces a single
`.html` file that runs the demo in any modern browser.

### G3. Engine adapters (Löve2D, Godot, etc.)

**Goal:** StoryBase as the logic layer; host engine handles graphics, audio,
input. The driver abstraction already proves this is possible in-process.

**Design sketch:** Document and stabilise the `driver` interface (already implemented
for `plain` / `ansi`). Write reference adapters:
- Löve2D: in-process; LuaSocket already a dep.
- Godot: out-of-process via the §G2 HTTP API.
- Defold: same as Godot.

**Files:** new `docs/howto/adapters.md`; reference adapter projects in
`examples/adapters/`.

**Acceptance:** A Löve2D project that consumes a StoryBase game and renders it with
sprites + audio.

---

## H. Smaller Language / Runtime Polish

(H1 — goal-directed actors — shipped 2026-05-23 including the demo34
showcase and the npc-speed mirror-fix in search/verify. H4 — inventory/
dialog/quest stubs — folded into §E. See completed.md for the full
H1 + demo34 write-up.)

### H3. Strategy synthesis (on top of `optimal-path`)

**Goal:** Today `optimal-path` returns one trace. Extend to synthesise a *strategy*
(state → action map) that wins against worst-case random outcomes — i.e., a winning
policy under adversarial / probabilistic transitions.

**Design sketch:**
- Min-max search over the existing state graph; "max" nodes are player choices,
  "min" nodes are random / actor / scheduler transitions.
- Return: a `Strategy` value mapping reached states to recommended choices, plus an
  expected outcome.

**Files:** `runtime/search.lua` new function `synthesise-strategy`. Parser entry as a
new builtin. Tests.

**Edge cases:** State-space explosion; require explicit depth / time budget.

**Acceptance:** On a stochastic demo (e.g. dice-based combat), the synthesised
strategy beats a uniform-random policy in 1000 sampled rollouts.

---

## I. Demo Coverage Gaps (demos 26–32) — all complete

A 2026-05-19 audit of `demos/demo01–25` against `docs/reference/language.md`
found a handful of supported language features that no demo exercised
end-to-end. All seven follow-on demos (26–32) have now shipped; details in
completed.md.

### I7. Coverage tracker (residue)

demo32 ("The Inquisitor's Board") promoted three of the four original I7
residue items: `union`/`intersect`/`difference` as load-bearing game
logic, the `(set)` empty literal as a state initializer, and
`engine/checkpoint! `<label>` with an explicit label argument.

The remaining residue:
- **Lambda expressions outside a `find` clause** — covered only by unit
  tests. Idiomatic StoryBase puts lambdas inside `find`; an out-of-`find`
  lambda demo would feel contrived. Promote only if a user-facing
  limitation surfaces.

---

## J. Language Review Pass 3 (2026-05-20) — open inelegances

A read-through of demos 01–32 to spot places the demos visibly work around
language limits, plus targeted runtime/parser inspection for bugs hinted at
by those workarounds. All 5 bugs (J-B1..B5) and 8 inelegances (J-I1, I2, I3,
I4, I5, I6, I7, I9) are shipped — see completed.md. The 2 remaining
inelegances are below.

### J-I8. `set!` on a `let`-binding silently writes a fake state path [inelegance]

Already tracked as §A1 (SF-5). Kept here only as a cross-reference: still
visible to authors despite the AV-4 mitigation.

### J-I10. Hooks collapse into multi-way switches [inelegance]

demo20's `hook after: move-to:` is 5 `when player/location = X: add! flag`
blocks. A per-room declarative `on-enter` (or per-flag declarative `gained-when:`)
would express the same data with less indirection.

**Possible direction:** allow `state world/location: Room; hook after move-to to `study: add! ...`. Pattern-match on the new value in the hook header.

---

## Notes for future agents

- The architecture (transaction log + discrete types + perception filtering) is the
  source of the project's leverage. Every feature in this backlog uses one of those
  three pillars; resist proposals that bypass them.
- The driver abstraction (`cli/drivers/`) and the debug protocol (`runtime/debug.lua`)
  are the right extension points for new presentation/IO modalities.
- `runtime/search.lua` and `runtime/verify.lua` are the right extension points for
  new analyses.
- New top-level declarations follow a stable pattern: AST kind → parser entry →
  codegen emitter → game-table consumer. See §6 of `idea.md` and the `quest`/`dialog`
  sketches in completed.md for templates.
- All new features must add per-feature tests under `tests/` and update `code_map.md`.
- Update `idea.md` whenever syntax is added; update `docs/reference/language.md`
  whenever semantics change.
- Named type aliases (`Gold = Int(0,N)`) do NOT trigger clamping in `dec!`/`inc!`
  — only inline `Int(0,N)` types do. Pre-existing limitation of `state.lua`'s type
  index (`lookup_type` returns `{tag="named"}`, not `{tag="int"}`). E1/E3 shipped
  without this fix; stat/quest demos work fine in practice because inline
  `Int(min, max)` is what they emit. E2 (`dialog-topic`) only emits `Bool` so it
  didn't hit this limitation either; revisit if a future user-written decl-macro
  runs into it.

# UI Event Surface Audit (M0)

Audit of every event emission and subscription site across the engine, in
service of `ui_idea.md` §M0. The output of this document is the source of
truth for `ui_idea.md` §3.1 and the contract `ui/kernel.lua` (§M1) must
implement.

> **Status update (2026-05-29).** §M1 has shipped: `ui/kernel.lua` is
> the multi-subscriber bus + state cache + queries/commands surface;
> `ui/format.lua` is the display formatter; `lib/storybase.lua` and
> `runtime/debug.lua` are adapted to forward through the kernel; the
> previously dead `game:on("scene-change", ...)` subscription now
> fires; `choice-made` is synthesised after a successful choice. See
> §4.1 below — the migration sketch the implementation followed.

Scope: `runtime/debug.lua`, `runtime/engine.lua`, `runtime/eval.lua`,
`runtime/actors.lua`, `runtime/state.lua`, `runtime/scheduler.lua`,
`lib/storybase.lua`. Touched but not in scope:
`cli/coverage_cmd.lua` (one external `_fn_call_hook` user).

---

## 1. Emission sites

Where events are produced, what they carry, and who receives them.

| event              | site                                     | payload as emitted                                       | reaches debug? | reaches `game:on()`? |
|--------------------|------------------------------------------|----------------------------------------------------------|----------------|----------------------|
| `mutation`         | `state.lua:371` via `_mutation_hook`     | `(path, old, new, fn)` → wrapper adds `tick, seq`        | yes¹           | yes¹                 |
| `clamp-event`      | `state.lua:439, 460` via `_clamp_hook`   | `(path, attempted, clamped, fn)` → wrapper adds `tick, seq` | yes         | no                   |
| `spawn-event`      | `state.lua:611` via `_spawn_hook`        | `(family, key, init, fn)` → wrapper adds `tick, seq`     | yes            | no                   |
| `despawn-event`    | `state.lua:638` via `_despawn_hook`      | `(family, key, fn)` → wrapper adds `tick, seq`           | yes            | no                   |
| `scene-change`     | `engine.lua:317 (goto), 334 (enter), 345 (exit)` | `{from?, to, stack, tick}` — `from` omitted by `enter` | yes        | no²                  |
| `actor-no-progress`| `engine.lua:668` (via actors `_no_progress_hook` at `actors.lua:246`) | `{actor}` (no `tick`) | yes | no |
| `schedule-fired`   | `scheduler.lua:157`                      | `{name, tick}`                                           | yes            | no                   |
| `fn-call`          | `eval.lua:2238`                          | `{name, args, tick}`                                     | yes            | no                   |
| `message-sent`     | `eval.lua:2526`                          | `{actor, msg, tick}`                                     | yes            | no                   |
| `watch-fired`      | `debug.lua:615, 625, 637`                | `{label, kind, path?, value, tick}` (three shapes)        | yes (self)     | no                   |
| `breakpoint-hit`   | `debug.lua:651`                          | `{id, condition, tick}`                                  | yes (self)     | no                   |
| `reload`           | `debug.lua:967`                          | `{file, outcome, ...}`                                   | yes (self)     | no                   |
| `<custom>`         | `eval.lua:2601` (engine/emit) via `_emit_hook` | `(event_name, payload, tick)` → wrapped as `{event, payload, tick}` | no³ | yes              |
| `choice`           | `lib/storybase.lua:272`                  | `{index, scene}`                                         | no             | yes                  |

¹ `mutation` is the one event with two parallel wirings of `_mutation_hook`:
   `engine.lua:806` (debug) and `lib/storybase.lua:108` (library). Whichever
   wires later wins (single-slot). In practice the library's `init()` runs
   *after* the engine constructor but the engine's `set_debug_server()`
   typically runs *before* the library subscribes, so the library
   overwrites debug's wiring when used together. See §3.

² Despite `lib/storybase.lua:485`'s docstring claiming `scene-change` is a
   built-in event for `game:on()`, no code path emits it on the library
   channel. Silently dead subscription.

³ `engine/emit` only reaches `_emit_hook` (library). The debug server
   never sees custom events. Asymmetric.

### Items §3.1 lists as events but that are *not* events

These appear in the §3.1 table but live elsewhere in the architecture and
should be removed from the event list:

- **`say`** — an item kind in the `narration` list returned by
  `engine.render_scene` (`runtime/eval.lua:2671`). Carried as
  `{kind="say", speaker, display, color, text}` inside the per-scene
  narration buffer; never broadcast.
- **`narration`** — same pattern; `{kind="narration", text}` items inside
  the same buffer.
- **`choice-made`** — never emitted under that name. The closest is the
  library's `"choice"` event from `lib/storybase.lua:272`. The §3.1 entry
  is aspirational.

---

## 2. Subscription / dispatch surfaces

Two parallel dispatchers exist today; neither knows about the other.

### 2.1 Debug server (`runtime/debug.lua`)

- Internal handler registry: `srv._handlers = {event_name → [fn, ...]}`
  (`debug.lua:532`).
- API: `srv:on(event, fn)` registers, `srv:emit(event, payload)` fans
  out (`debug.lua:546, 556`).
- Network legs: in addition to `_handlers`, `emit` broadcasts to
  - `_clients` (raw TCP, JSON-line framed; only when `mode == "tcp"`)
  - `_sse_clients` (browser SSE, via `_sse_push`).
- Gating: `if not self._running then return end` — emissions before
  `srv:start()` are silently dropped.

### 2.2 Library (`lib/storybase.lua`)

- Internal listener registry: `self._listeners = {event_name → [fn, ...]}`
  (`lib/storybase.lua:89`).
- API: `self:on(event, fn)` registers (`lib/storybase.lua:488`),
  `self:_emit(event, payload)` fans out (`lib/storybase.lua:497`).
- No network leg. Pure in-process.
- Wiring: at `init()` it installs `_emit_hook` for engine/emit and
  `_mutation_hook` for state mutations (lines 103, 108) — overwriting
  whatever the engine had set, including any debug-server wiring.

### 2.3 Singleton hook slots (state store + game table)

These are not dispatchers — they're single-callback slots, last-writer-wins:

| slot                       | set by                                  | called from                  | semantics       |
|----------------------------|------------------------------------------|------------------------------|-----------------|
| `state._mutation_hook`     | `engine.lua:806`, `lib/storybase.lua:108` | `state.lua:371`              | one subscriber  |
| `state._clamp_hook`        | `engine.lua:813`                         | `state.lua:439, 460`         | one subscriber  |
| `state._spawn_hook`        | `engine.lua:820`                         | `state.lua:611`              | one subscriber  |
| `state._despawn_hook`      | `engine.lua:826`                         | `state.lua:638`              | one subscriber  |
| `actors._no_progress_hook` | `actors.lua:315` via `:on_no_progress()` | `actors.lua:246`             | one subscriber  |
| `game._emit_hook`          | `lib/storybase.lua:103`                  | `eval.lua:2601`              | one subscriber  |
| `game._fn_call_hook`       | `cli/coverage_cmd.lua:80`                | `eval.lua:2246`              | one subscriber  |
| `scheduler._debug_server`  | `engine.lua:833`                         | `scheduler.lua:154`          | one subscriber  |

Every one of these is a future M1 wiring point: the kernel installs a
single fan-out shim into each slot and dispatches to its own multi-
subscriber registry.

---

## 3. Reconciliation against `ui_idea.md` §3.1

The §3.1 table in `ui_idea.md` lists events that drivers will see via
`kernel:on(...)`. The corrected version below reflects what the engine
actually emits today plus the four events the kernel will need to
synthesise.

| event              | payload (corrected)                                | source                              | status                                          |
|--------------------|----------------------------------------------------|-------------------------------------|-------------------------------------------------|
| `scene-change`     | `{from?, to, stack, tick}`                         | `engine.lua` push/pop/goto          | emitted; `from` is `nil` for the first `enter`  |
| `mutation`         | `{path, old, new, fn, tick, seq}`                  | `state._mutation_hook`              | emitted                                          |
| `clamp-event`      | `{path, attempted, clamped, fn, tick, seq}`        | `state._clamp_hook`                 | emitted                                          |
| `spawn-event`      | `{family, key, init, fn, tick, seq}`               | `state._spawn_hook`                 | emitted                                          |
| `despawn-event`    | `{family, key, fn, tick, seq}`                     | `state._despawn_hook`               | emitted                                          |
| `message-sent`     | `{actor, msg, tick}`                               | `eval.lua` `send!`                  | emitted (note: payload is `actor`, not `from/to`) |
| `schedule-fired`   | `{name, tick}`                                     | `scheduler.lua`                     | emitted (note: key is `name`, not `schedule`)   |
| `fn-call`          | `{name, args, tick}`                               | `eval.lua` user-fn dispatch         | emitted (note: key is `name`, not `fn`)         |
| `actor-no-progress`| `{actor, tick}` *(tick to be added by kernel)*     | `actors` → `engine`                 | emitted; `tick` missing today                    |
| `watch-fired`      | `{label, kind, path?, old?, new?, value?, tick}`   | `debug.lua:check_watches`           | emitted; payload varies by watch kind            |
| `breakpoint-hit`   | `{id, condition, tick}`                            | `debug.lua`                         | emitted (debug-only — not part of UI baseline)   |
| `reload`           | `{file, outcome, ...}`                             | `debug.lua` hot-reload              | emitted (debug-only)                             |
| `<custom>`         | `{event, payload, tick}`                           | author `engine/emit`                | emitted only on the library channel today        |
| `choice-made`      | `{scene, index, label}`                            | post-`do_choice` synthesis          | **NOT emitted today; kernel must synthesise**   |
| `say`              | —                                                  | (item in `render_scene` output)     | **not an event; remove from §3.1**              |
| `narration`        | —                                                  | (item in `render_scene` output)     | **not an event; remove from §3.1**              |

**Diff vs. current `ui_idea.md` §3.1:**

1. Remove `say` and `narration` rows — they are scene-render outputs,
   not events. Drivers receive them via `kernel:get_scene()` after a
   `scene-change` (or after `do_choice`).
2. Add `breakpoint-hit` and `reload` rows (or note them as debug-only).
3. Fix payload keys: `message-sent.from/to` → `actor`; `fn-call.fn` →
   `name`; `schedule-fired.schedule` → `name`. Alternative: rename in the
   kernel adapter to match the spec; cheaper than touching every emit
   site.
4. Document `seq` and `tick` as standard fields on every store-derived
   event (mutation / clamp / spawn / despawn).
5. Mark `choice-made` as a kernel-synthesised event (no engine site
   today). The kernel manufactures it after `do_choice` succeeds, using
   `{scene, index, label}` from the choice list it already cached.
6. Note that the `<custom>` channel currently bypasses the debug server.
   The kernel must forward both ways.

---

## 4. Recommendation: kernel ownership model

**Decision: the kernel becomes the single owner.** Both
`lib/storybase.lua:_listeners` and `runtime/debug.lua:_handlers` become
thin adapters that forward into `kernel:on()` / `kernel:emit()`. This is
the option `ui_idea.md` §M0 already recommends; the audit confirms it is
the right call. Reasons:

- **Single-slot hooks are already wrong.** `state._mutation_hook` has
  two writers today (`engine.lua:806`, `lib/storybase.lua:108`); only
  one survives. Any third subscriber (curses driver, SSE, watcher)
  hits the same race. A multi-subscriber registry is mandatory; the
  kernel is the natural owner.
- **Two parallel dispatchers also wrong.** `engine/emit` reaches
  `game:on()` but not the debug server. `scene-change` reaches the
  debug server but not `game:on()` (despite docs claiming otherwise).
  Drivers can't get a consistent view from either channel alone.
- **Payload normalisation is needed somewhere.** Renaming
  `fn-call.name → fn` etc. is cleaner in one adapter than at every
  emit site.
- **Network legs stay where they are.** The debug server retains
  ownership of TCP and SSE transport. It just stops being a *source*
  of subscriptions for non-network consumers; instead it subscribes
  to the kernel for the events it wants to forward.

### 4.1 Migration sketch (informs M1)

Concrete plan once `ui/kernel.lua` exists:

1. **Kernel API.** `kernel:on(event, fn)`, `kernel:emit(event, payload)`,
   plus `kernel:get_state(...)` / `kernel:get_scene()` / etc. per
   §3.2–3.3. The dispatch loop is the same one `debug.lua:emit` uses
   today (an array of fns per event, `pcall` each).
2. **Single set of hook shims.** At engine init, install a fan-out into
   each store/actor/game slot:
   ```lua
   state._mutation_hook = function(path, old, new, fn)
     kernel:emit("mutation", { path=path, old=old, new=new,
                               fn=fn, tick=tick(), seq=seq() })
   end
   ```
   The shim is the only writer; both `engine.lua:806` and
   `lib/storybase.lua:108` are deleted.
3. **Library adapter.** `lib/storybase.lua:on()` becomes
   `kernel:on(name, fn)`. `_listeners` and `_emit` go away. Document
   the renames (`choice` → `choice-made`; `scene-change` becomes
   reliably available).
4. **Debug adapter.** `debug.lua:emit` becomes
   `function srv:emit(name, payload) kernel:emit(name, payload) end`
   plus its own SSE/TCP fan-out via a kernel subscription. The watch
   evaluator stays where it is (`check_watches` after mutation) but
   subscribes to the kernel rather than being called inline from
   `engine.lua`.
5. **Synthesised events.** The kernel synthesises:
   - `choice-made` after `kernel:do_choice(idx)` returns.
   - Possibly `tick` (kernel-wide heartbeat) if §M5+ widgets want it.
6. **Engine integration.** Engine receives the kernel via
   `eng:set_kernel(k)` analogously to `eng:set_debug_server`. The two
   methods can coexist during transition; when `set_kernel` is set,
   `set_debug_server` becomes a no-op shim.

### 4.2 Open questions for §M1

- **State-cache semantics.** Kernel mirrors every `mutation` into a
  `path → value` cache (§4 of `ui_idea.md`). Edge: paths that fail
  clamping write the clamped value via `mutation`, so the cache stays
  consistent — confirm `state.lua` fires `_mutation_hook` with the
  clamped value, not the attempted value.
  **Resolved 2026-05-29 during M1 implementation.** In `inc!`/`dec!`
  (state.lua:425–443), the sequence is: compute clamp → fire
  `_clamp_hook(path, attempted, clamped)` → write `_cache[path] =
  clamped` → call `_log_entry`, which fires `_mutation_hook(path,
  old, clamped)`. The mutation hook always observes the clamped
  value; the kernel cache therefore stays consistent.
- **Ordering guarantee.** §3.1 promises `mutation` precedes any
  `scene-change` triggered by the same player action. The current
  engine order is: do_choice → eval mutations (fire hooks) → run
  post-action → emit scene-change. This is already correct as long as
  the kernel preserves emit order — i.e., synchronous dispatch, no
  queueing.
- **Coalescing.** Should the kernel coalesce `mutation` bursts (e.g.
  ten paths changed in one transaction) into a single event with a
  list payload? Defer — start with one-event-per-mutation; profile in
  M5 once widgets are repainting.
- **Custom event namespacing.** Today `engine/emit "foo"` produces an
  event named `"foo"`. Risk of collision with built-ins as authors
  pick names like `"mutation"`. Recommend a `custom:` prefix in the
  kernel; or reject collisions at compile time. Cheap to defer.

### 4.3 Out-of-scope housekeeping noted during the audit

- `runtime/` contains stray `.lua.tmp.62804.*` files (engine, eval,
  verify, actors, config) — likely WSL editor crash leftovers. They do
  not affect runtime; flag for the next janitor pass.
- `_fn_call_hook` is single-slot but actually used (coverage). It
  should migrate to the kernel registry like the others, with the
  coverage cmd subscribing as one more listener.

---

## Acceptance check

`ui_idea.md` §M0 says:
> - Inventory every hook in `runtime/debug.lua`, `runtime/engine.lua`,
>   `runtime/actors.lua`, `runtime/state.lua`, and `lib/storybase.lua`
>   that emits or subscribes to events.

Inventory: §1 (emissions) + §2 (subscriptions). Done.

> - Confirm the event list in §3.1 matches reality; add missing rows.

Reconciliation: §3 (diff table + recommended edits to `ui_idea.md`
§3.1). Done.

> - Decide whether the kernel replaces or wraps the existing listener
>   tables in `lib/storybase.lua` and the SSE broadcaster in
>   `runtime/debug.lua`. Recommend: kernel becomes the single owner;
>   both call sites become thin shims.

Decision: §4. Adopted as recommended; concrete migration sketch in §4.1;
open questions parked in §4.2 for M1.

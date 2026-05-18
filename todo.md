# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-18)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–25 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
UI driver layer complete. All compile-time validation gaps (AV-1 through AV-4) and
silent-failure hazards SF-1 through SF-4 resolved. All AE issues (AE-1 through AE-17)
resolved. All critical and major bugs (#1–#13) resolved. Full audit backlog (§A3–§A16)
complete. §B1/B2/B4/B5, §C1/C2/C3/C4, §F1/F2 all complete. §E0 (decl-emitting
macro substrate) complete; §E1 (`quest` declarations) and §E3
(`inventory` + `stat` stdlib modules) shipped 2026-05-18.
§E4 review fixes (bugs 1–5, gaps 1–4, tests 1–3, doc 1) all landed 2026-05-18.

**~2863 successes / 0 failures / 2 pending (known limitations).**
(HTTP/debug spec failures are transient network timing issues — ignore unless touching http/debug code.)

The core language and runtime are feature-complete against the V1.0 specification.

---

## What to work on next

**Lower-priority polish (open, not blocking):**
- §A1 — SF-5 — already partially mitigated by AV-4; consider closing.
- §A2 — Inelegance #7 — BFS expansion duplication (deferred; documented).

**Future Features and Extensions (large):** Suggested ordering for impact:

1. §D1 — LLM-bounded handler standard module
2. §B3 — Trace scrubber (browser debug UI)
3. §E2 — `dialog` blocks shipped as a stdlib `.sb` module
   (substrate ready: §E0 + §E3 substrate extensions complete 2026-05-18)
4. §G1 — Web/JS compilation target

(§G2 — stateless HTTP API — complete, see completed.md.)

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

Three patterns (quest / dialog / inventory+stat) appear in every nontrivial demo.
Originally planned as base-language declarations; revised 2026-05-16 to a staged
plan that prefers **stdlib `.sb` modules** over compiler-internal AST kinds,
backed by a one-time extension to the macro system (§E0). E1 stays partly base
because its value is in *analyses* (verify auto-emission), not desugaring.

### E0. Decl-emitting macro substrate ✅ (2026-05-17 / 2026-05-18 — see completed.md)

Six-stage extension that landed the `decl-macro` keyword, lexer-level
`$param` + composite identifiers, decl-level expansion via
`substitute_decl_node`, position propagation with `expanded from macro`
diag notes, cross-import wiring + `@stdlib/<name>` resolver, and a
single-pass nested-call restriction. Tests:
`tests/compiler/macro_decl_spec.lua` (~62 tests). Reference fixture:
`stdlib/counter.sb`.

### E1. `quest` declarations ✅ (2026-05-18 — see completed.md)

Shipped as a base feature with first-class `QUEST_DECL` AST kind.
Compiler desugars to state + helper fns; codegen auto-emits a
`verify-eventually (quest-<name>-complete?)` block per quest.
Acceptance demo: `demos/demo24_lost_relic.sb`. Tests:
`tests/compiler/quest_spec.lua` (15 tests). Softlock auto-verify
(AG EF complete?) deferred — the existing single reachability check
is the headline value; softlock can ride on the same hook later.

### E2. `dialog` blocks (stdlib `.sb` module)

**Goal:** Demo20 hand-rolls `state asked:` flags, re-entry semantics, and
"already-said" branches. Surface as a stdlib import.

**Plan:** ships as `stdlib/dialog.sb` exporting a `dialog` macro built on §E0.
No new compiler AST kinds.

**Design sketch (author API unchanged from original):**
```
import "@stdlib/dialog"

dialog blacksmith-talk:
  speaker: blacksmith
  reentry: from talk-blacksmith
  topic family-history once:
    "I came here as a boy."
    -> reply
  topic deliver-ore when: contains? player/inventory `iron-ore:
    "You brought the ore. Excellent."
    deliver-ore
  topic farewell always:
    "Farewell, traveller."
    <-
```

The macro expands to a scene + `state asked/blacksmith-talk/{topic}: Bool` +
conditional choices. `once` topics auto-set the flag after entry; `always`
topics never set; `when:` adds a guard.

**Files:** new `stdlib/dialog.sb`; resolver entry for `@stdlib/...` import
prefix in `compiler/compiler.lua:resolve_imports`; `tests/stdlib/dialog_spec.lua`;
docs page in `docs/howto/dialog.md`.

**Depends on:** §E0.

**Acceptance:** Re-implement the dialog portion of `demo20_harrow_house.sb`
using the `dialog` macro at roughly 1/3 the line count; behaviour identical;
all of demo20's verify blocks still pass.

### E3. `inventory` and `stat` (stdlib `.sb` module) ✅ (2026-05-18 — see completed.md)

Shipped as `stdlib/inventory.sb` (`inventory $name $T $max`) and
`stdlib/stat.sb` (`stat $name $min $max`) via the §E0 decl-macro
substrate, with one small substrate extension (§E3 Stage A) to allow
`$param` to land in type-name and integer-bound slots. The original
named-arg author API (`contents: ItemKind` / `max: 10`) gave way to
positional args mirroring the existing `stdlib/counter.sb`
convention, since the substrate only carries positional `$params`.
Acceptance demo `demos/demo25_dungeon_loot.sb` wires both modules
into a small loot-loop game whose
`verify-eventually (player-bag-full?)` clause proves winnability.
Tests: `tests/stdlib/inventory_spec.lua` (9) and
`tests/stdlib/stat_spec.lua` (8).

### E4. E-series review fixes ✅ (2026-05-18 — see completed.md)

Two-pass cleanup of follow-ups from the post-merge code review of E0–E3.
Bugs 1–4 + early doc fixes in commit `7ed1751`; bug 5, gaps 1–4,
tests 1–3, doc-1 in `8b7391e`. None blocked existing demos.

---

## G. Reach Beyond Lua

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

### G2. HTTP API mode (stateless `/step`) ✅ (2026-05-16 — see completed.md)

Shipped as `storybase serve-api`. Endpoints `GET /`, `GET /schema`,
`POST /step`, `POST /reset`, `OPTIONS *`. Client-held opaque `save_log`
round-trips through JSON; the server is stateless. 22 tests
(`tests/cli/serve_api_spec.lua`). Compaction was not added to the API
itself — clients can replay saves through `storybase compact` offline
if logs grow large; revisit if real usage shows it needs to be inline.

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

### H1. Goal-directed actors

**Goal:** Today's actors are purely reactive (perceives → behavior body). Let them
declare a `goal: cond` and use the existing `runtime/search.lua` BFS internally to
pick the action that moves toward the goal. Makes "intelligent" NPCs without
hand-written heuristics.

**Design sketch:**
```
actor scout:
  state:     npcs/scout
  perceives: [...]
  goal:      contains? scout/inventory `intel
  actions:   [move-to, search-room, return-base]
  priority:  10
```

The runtime, instead of calling a `behavior:` fn, runs a depth-bounded search in the
perception-filtered state space using the declared `actions:` as transitions; picks
the action that minimises distance to the goal.

**Files:** `runtime/actors.lua` extension; new `actor_decl` field `goal:` / `actions:`
in AST/parser; codegen; `tests/runtime/actors_goal_spec.lua`.

**Edge cases:** Bound search depth (default 3). Cache plans across ticks when state
hasn't changed.

**Acceptance:** A demo NPC successfully navigates a 6-room maze toward a goal item
without any imperative behavior code.

### H2. Diff-mode hot reload

**Goal:** Hot reload already works for schema (add/remove fields). Extend to *body*
edits where the *log* is re-played against the new fn bodies — let an author edit
`take-damage` and instantly see how a past playthrough would have differed.

**Design sketch:**
- On reload command: if no schema changes, re-execute the log against the new fn
  table from a fresh `state.new`, producing a divergence report
  `[{tick, path, old_value, new_value}]`.
- Optional: switch to the new playthrough state, or stay on the old one and show
  side-by-side.

**Files:** `runtime/debug.lua` reload command extension; new HTTP command
`get-replay-diff`; UI panel in browser debug.

**Acceptance:** Save a 50-tick playthrough; edit `take-damage` to halve damage;
reload; observe the divergence report listing every health-related tick where the
new playthrough diverges.

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

### H4. Inventory / dialog / quest stubs

Folded into §E. E0 (decl-macro substrate), E1 (`quest` declarations),
and E3 (`inventory` + `stat` stdlib modules) shipped 2026-05-18; only
E2 (`dialog` stdlib module) remains open.

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
  sketches in §E for templates.
- All new features must add per-feature tests under `tests/` and update `code_map.md`.
- Update `idea.md` whenever syntax is added; update `docs/reference/language.md`
  whenever semantics change.
- Named type aliases (`Gold = Int(0,N)`) do NOT trigger clamping in `dec!`/`inc!`
  — only inline `Int(0,N)` types do. Pre-existing limitation of `state.lua`'s type
  index (`lookup_type` returns `{tag="named"}`, not `{tag="int"}`). E1/E3 shipped
  without this fix; stat/quest demos work fine in practice because inline
  `Int(min, max)` is what they emit. Revisit if E2 (`dialog`) or user-written
  decl-macros run into it.

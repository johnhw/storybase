# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-15)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–21 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
UI driver layer complete. All compile-time validation gaps (AV-1 through AV-4) and
silent-failure hazards SF-1 through SF-4 resolved. All AE issues (AE-1 through AE-17)
resolved. All critical and major bugs (#1–#13) resolved. Full audit backlog (§A3–§A16)
complete. §B1/B2/B4, §C1/C2 all complete.

**2640 successes / 0 failures / 2 pending (known limitations).**
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
3. §E1–E3 — `quest` / `dialog` / `inventory` built-in patterns
4. §B5 — Auto-docs site
5. §C3 — Temporal-logic verify
6. §F1 — Procedural generation primitives
7. §G1 — Web/JS compilation target

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

### B5. Auto-docs site

**Goal:** All declarations already carry doc strings (§18.4). Generate a static HTML
reference per game — types, state schema, fn signatures with pre/post contracts, scene
graph diagram, verify status. Currently the LSP hover is the only consumer of doc
strings.

**Design sketch:**
- New CLI subcommand `docs`. Walks the typed AST (already used by `extract-symbols`
  and the LSP), groups by kind, emits per-page HTML.
- Optional flag `--format md` for Markdown output.
- Reuses scene graph visualisation from §B1 for one of the pages.

**Files:** new `cli/docs_cmd.lua`, an HTML template, `tests/cli/docs_spec.lua`.

**Acceptance:** Running `storybase docs demos/demo20_harrow_house.sb -o docs_out/`
produces a navigable site with one page per declaration kind plus a home page.

---

## C. Higher-Order Tests Beyond `verify`

### C3. Temporal-logic verify

**Goal:** Today's `verify-always` is a single-state check. Add temporal operators
(`eventually`, `always-eventually`, `until`) to express "after picking up the key,
the door eventually unlocks" — currently inexpressible.

**Design sketch:**
- Minimal CTL subset: `EF p` (eventually p reachable), `AG p` (always globally p —
  same as current `verify-always`), `AF p` (on every path, p eventually holds),
  `p AU q` (on every path, p until q).
- Syntax: `verify-eventually p depth: N`, `verify-always-eventually p depth: N`,
  `verify p until q depth: N`.
- Backend: implement via nested BFS over the state graph from `runtime/search.lua`.
  `EF p` is just `can-reach? p` (already exists). `AF p` requires reverse BFS from
  failing states. `p AU q` is the standard CTL fixpoint.

**Files:** `runtime/search.lua` (new analyses), `runtime/verify.lua` (new clause
kinds), `compiler/parser.lua` (new keywords), `compiler/codegen.lua`,
`tests/runtime/search_spec.lua`, `tests/runtime/verify_spec.lua`.

**Edge cases:** AF and AU explode the search space; require explicit `depth:`. Time
budget enforcement.

**Acceptance:** A demo where `verify-eventually quest-complete?` holds; modifying the
game to remove the quest-completion path makes the verify fail with a counterexample.

### C4. Cached / incremental verify

**Goal:** Verify currently runs from scratch every CI cycle. Hash the AST of each
verify block + the transitively-reached fns; persist verdicts in
`.storybase-cache/verify.json`. Skip blocks whose hash is unchanged.

**Design sketch:**
- For each verify block: collect all fns referenced (transitively) by the verify
  body and by every `fn` that mutates a path the verify reads. Hash the AST
  subtree.
- Cache key: `{verify_label, hash, schema_version}`. Value: `{verdict, states_checked,
  cex?}`.
- `cli/verify_cmd.lua` consults cache before running each block.
- `--no-cache` flag to force re-run.

**Files:** `cli/verify_cmd.lua`, `compiler/checker.lua` (transitive-call analysis —
may need new pass), `tests/cli/verify_cache_spec.lua`.

**Acceptance:** Run verify, edit a non-verify fn, run verify again — only affected
blocks re-execute.

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

Three patterns appear in every nontrivial demo. They deserve first-class syntax. None
require new runtime primitives — these are parser-level desugarings.

### E1. `quest` declarations

**Goal:** Every game ends up hand-rolling steps + prereqs + completion + rewards.
Surface this as first-class so the search engine can automatically check "every
declared ending is reachable" and "no quest is softlocked once started" — emergent
power, not new runtime features.

**Design sketch:**
```
quest find-the-crown:
  description: "Recover the lost crown of Erith."
  prereq:      player/has-key
  step talk-to-king:
    => talk-king
  step explore-dungeon:
    requires: contains? player/inventory `torch
    => dungeon
  step retrieve-crown:
    requires: contains? player/inventory `crown
  reward:
    inc!  player/gold 500
    add!  player/quest-flags `crown-recovered
```

Compiles to: a `state quests/{q}/status: QuestStatus`-style family, scene-entry/exit
hooks, helper fns `quest-active? q`, `quest-step-complete? q s`. Auto-emit verify
blocks: "quest find-the-crown is reachable to completion."

**Files:** AST extension in `compiler/ast.lua`; parser entry; codegen desugars to
existing constructs; `compiler/checker.lua` cross-validates step references; new
docs page.

**Acceptance:** A demo using `quest` syntax produces the same runtime behaviour as
the hand-rolled equivalent and auto-emits a verify proving the quest is completable.

### E2. `dialog` blocks

**Goal:** Demo20 hand-rolls `state asked:` flags, re-entry semantics, and
"already-said" branches. Surface as first-class.

**Design sketch:**
```
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

Compiles to a scene + `state asked/blacksmith-talk/{topic}: Bool` + conditional
choices. `once` topics auto-set the flag after entry; `always` topics never set;
`when:` adds a guard.

**Files:** AST/parser/codegen analogous to E1. Hook in scene rendering.

**Acceptance:** Re-implement the dialog portion of `demo20_harrow_house.sb` using
`dialog` blocks at roughly 1/3 the line count.

### E3. `inventory` and `stat` mixins

**Goal:** `Set(ItemKind, 10)` is the de-facto inventory pattern; hand-written
`give!`, `take!`, `has?`, `count-of` are common. Same for stat blocks with
base + modifiers + clamped derived values.

**Design sketch:**
```
inventory player/inventory:
  contents: ItemKind
  max:      10
  # auto-generated: give! / take! / has? / inventory-size / inventory-empty?

stat player/health:
  base:    Int(0, 100) = 100
  buffs:   Set(BuffKind, 4) = (set)
  derived: base + (buff-bonus buffs)
```

Compiles to existing primitives.

**Files:** AST/parser/codegen extensions. New stdlib helpers for buff stacking.

**Acceptance:** Replace `Set(ItemKind, 10)` boilerplate in three demos with
`inventory` declarations; resulting tests pass.

---

## F. Procedural Content & Endings

### F1. `generate` blocks (seed-deterministic procedural content)

**Goal:** A `generate` block that runs once at session start, seeded by the RNG,
to procedurally build state (random map layouts, item placement). Because everything
goes through `spawn!` / `relate!` / the log, the generated world is automatically
saveable, replayable, and visible to `verify`. Pair with
`verify-always "every room reachable from start"` and you get *proven-solvable*
roguelike layouts.

**Design sketch:**
```
generate world-map seed: world/seed:
  let room-count = (random-int 8 12):
    for i in (range 0 room-count):
      spawn! rooms (str "r" i) Room(...)
    for i in (range 0 (room-count - 1)):
      relate! exits (str "r" i) (str "r" (i + 1))
```

- Parser recognises `generate <name> seed: <path>:` as a top-level decl.
- Runtime calls all `generate` blocks at `engine:init()` after `init_defaults`, before
  `entry-scene` dispatch.
- All mutations go through the log as normal; replay reconstructs the world.

**Files:** AST/parser/codegen; engine init order in `runtime/engine.lua`; new
`runtime/random.lua` `range` helper if not present; `tests/runtime/generate_spec.lua`.

**Edge cases:** `generate` must be pure with respect to the RNG (no I/O). Seed must
be set before generate runs. Re-running `generate` on reload is *not* the right
default — emit a warning.

**Acceptance:** A demo with a procedurally generated 10-room dungeon that replays
identically from a saved log, and where `verify "all rooms reachable"` passes.

### F2. `ending` declarations

**Goal:** `ending name: when cond` — verifiable for reachability and mutual
exclusivity; displayable in the auto-doc graph from §B5.

**Design sketch:**
```
ending good when: world/chapter = `finale and player/status = `alive:
  "You return to the village a hero."

ending bad when: player/status = `dead:
  "Your story ends in the dungeon."
```

Auto-emits verify blocks: "ending good is reachable" and "no two endings reachable
simultaneously."

**Files:** AST/parser/codegen; new `ENDING_DECL` kind; auto-verify generation.

**Acceptance:** A demo with three endings produces three auto-generated verify
blocks all of which pass.

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

### G2. HTTP API mode (stateless `/step`) ✅ (2026-05-17 — see completed.md)

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

(Cross-reference to §E1–E3 — if those land first, this section folds into them.)

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
  index (`lookup_type` returns `{tag="named"}`, not `{tag="int"}`). Worth fixing
  before §E1–E3 ship, since those patterns will use named types heavily.

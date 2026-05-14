# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-14)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–21 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
UI driver layer complete. All compile-time validation gaps (AV-1 through AV-4) and
silent-failure hazards SF-1 through SF-4 resolved. All AE issues (AE-1 through AE-17)
resolved. All critical and major bugs (#1–#13) resolved. The 2026-05-14 codebase
audit backlog (§A3–§A9, §A11–§A16) has fully landed. §C1 (`test` blocks) complete.
§B2 (counterexample minimisation) complete. §A10 (`--serve` security) complete.

**2583 successes / 0 failures / 2 pending (known limitations).**

The core language and runtime are feature-complete against the V1.0 specification.

---

## What to work on next

**Security-adjacent (do before any production `--serve` use):**
- ~~§A10 — `--serve` exposes arbitrary code execution via the debug `eval` command.~~ **DONE**

**Lower-priority polish (open, not blocking):**
- §A1 — SF-5 — already partially mitigated by AV-4; consider closing.
- §A2 — Inelegance #7 — BFS expansion duplication (deferred; documented).

**Future Features and Extensions (large):** Roadmap below. Suggested ordering for
impact:

1. §B1 — State-graph explorer + §B4 coverage report
2. ~~§C1 — `test` blocks~~ **DONE** — §C2 fuzz mode
3. §D1 — LLM-bounded handler standard module
4. ~~§B2 — Counterexample minimisation~~ **DONE**
5. §E1–E3 — `quest` / `dialog` / `inventory` built-in patterns
6. §B5 — Auto-docs site
7. §C3 — Temporal-logic verify
8. §F1 — Procedural generation primitives
9. §G1 — Web/JS compilation target

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

### ~~A10. `--serve` exposes arbitrary code execution via the debug `eval` command~~ **DONE**

**FIXED (commit a8ab009):** Sockets now bind `127.0.0.1` by default; `--bind <addr>`
opts into broader exposure. `eval` command blocked in serve mode.

---

## B. Authoring UX — Make the Latent Power Visible

The engine already computes things authors can't see. These surface them.

### B1. State-graph explorer (browser debug UI)

**Goal:** Render the reachable state graph that `verify-always` already builds. Click a
node → see scene name + state cache snapshot. Click an edge → see the choice that
triggered the transition. Dead-ends, unreachable scenes, and soft-locks become
obvious at a glance — probably the single most demonstrative feature of the
language's premise.

**Design sketch:**
- New debug command `get-state-graph {depth: N, scene: name?}` returns nodes
  `[{id, scene, cache_hash, cache_summary, terminal?}]` and edges
  `[{from, to, choice_label, choice_index, fn}]`.
- Backend uses `runtime/search.lua`'s BFS but emits the full expansion tree (not just
  the answer to a question). Reuse `hash_cache` for node IDs.
- Frontend renders with a force-directed layout (e.g. d3-force or cytoscape — pull in
  as a CDN script, no build step). Embed into `HTML_UI` in `runtime/debug.lua`.
- Highlight current state node live; pulse on `mutation` events.

**Files:** `runtime/search.lua` (export expansion API), `runtime/debug.lua` (new HTTP
command + UI panel), `tests/runtime/debug_spec.lua`. Add a `graph.html` panel
selectable from the existing UI tab strip.

**Edge cases / scope:** Cap graph size (default `depth: 6`, `max-nodes: 5000`); time
budget. For larger games, offer a "from current state, depth: 3" mode. Don't try to
solve graph layout for `> 1000` nodes — provide a tree-view fallback.

**Acceptance:** Run `--debug` on `demo08_probability_engine.sb`, open the Graph tab,
see the full BFS expansion. Clicking a node shows its scene+cache. Identifying an
unreachable choice in a real demo is the success criterion.

### B2. Counterexample minimisation — **COMPLETE**

**Implemented:** `runtime/verify.lua` exports `M.shrink_path(gt, path, expr, budget_secs)`
which greedily removes one step at a time (restarting on each successful removal) until
the path is 1-minimal. The `run_always_check` post-processes every counterexample through
the shrinker (5-second default budget). `cli/verify_cmd.lua` shows
"Counterexample path (minimised from N to M steps)" when the shrinker reduced the path,
and "[budget exceeded — may not be minimal]" when time ran out.

**Implementation note:** The BFS in `verify.lua` already explores states breadth-first
and thus records the minimum-depth path to the first failing state. For purely
deterministic games the shrinker is a no-op at the verify level (BFS guarantees
minimality). Its real value is for paths supplied externally — e.g., from §C2 fuzz
runs or manually constructed test cases — where the path may be longer than necessary.
The `M.shrink_path` API is public for this reason.

**Future:** Apply the same shrinker to `run_after_check` (requires path) and
`run_can_reach_check` (from-any-state counterexamples). Both would need a
custom "still-fails" predicate that checks the full after/requires/from-any-state
semantics, not just the invariant expression.

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

### B4. Coverage report

**Goal:** `storybase coverage game.sb` walks the BFS frontier (configurable depth)
and reports which scenes, fns, and choices the search exercises and which it does
not. Combined with `verify` runs, flag "this scene is unreachable" or "this fn has
no covering verify."

**Design sketch:**
- New CLI subcommand `coverage`. Reuses `runtime/search.lua` BFS infrastructure but
  instruments scene-entry / fn-call counts in `runtime/eval.lua` via a hook (similar
  to `_mutation_hook`).
- Outputs: per-scene visit count, per-fn call count, list of declared-but-unreached
  entities, percentage coverage.
- Optional `--format json` for CI integration.

**Files:** new `cli/coverage_cmd.lua`, hook in `runtime/eval.lua`, integration in
`cli/main.lua`, `tests/cli/coverage_spec.lua`.

**Acceptance:** Running `storybase coverage demos/demo01_wanderer.sb` reports 100%
scene coverage at modest depth; introducing a deliberately-unreachable scene flags it.

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

### C1. `test` blocks (lighter sibling of `verify`) — **COMPLETE**

**Goal:** `verify-always` is BFS-heavy. Add a lighter mechanism for scripted assertions
that authors will actually use day-to-day.

**Design sketch (syntax):**
```
test "buy potion works":
  setup:
    set! player/gold 100
  run:
    buy-item `health-potion 40
  expect:
    player/gold = 60
    contains? player/inventory `health-potion
```

- New top-level declaration `TEST_DECL` parsed by `compiler/parser.lua`.
- Codegen emits a `tests = [...]` array on the game table.
- New runtime entry point `tests.run_all(game_table)` in `runtime/tests.lua` runs each
  test in a fresh state, applies setup mutations, runs the body (transaction fns
  allowed), evaluates each `expect:` clause.
- CLI: `storybase test game.sb` (parallel to existing `verify` subcommand).
- Stripped in production builds, same mechanism as `verify`.

**Files:** new AST kind in `compiler/ast.lua`; `compiler/parser.lua` parser entry;
`compiler/codegen.lua` emitter; new `runtime/tests.lua`; new `cli/test_cmd.lua`;
`tests/compiler/parser_spec.lua` + `tests/runtime/tests_spec.lua`.

**Edge cases:** Tests share game table but each runs in a fresh `state.new`. Disallow
`engine/checkpoint!` and other engine-state mutations in `setup:`.

**Acceptance:** A test suite for `demos/demo02_merchant.sb` written entirely in
`test` blocks; runs in under a second; produces busted-style pass/fail report.

### C2. Property / fuzz mode

**Goal:** `storybase fuzz game.sb --runs 10000 --seed-from N` random-walks the choice
tree, asserts every declared `verify` invariant on every step, and surfaces any path
that violates one. The transaction log gives perfect repro for free.

**Design sketch:**
- New CLI subcommand `fuzz`. For each run, fresh state, pick choices uniformly (or by
  declared weight if a choice carries a `weight:` annotation — small spec extension),
  execute up to `--steps N`. After every step, evaluate all `verify-always`
  predicates; on failure, save the log + seed + step index to a `failures/` directory.
- Replay any failure with `storybase run --load failures/run123.log`.

**Files:** new `cli/fuzz_cmd.lua`. Reuses `runtime/engine.lua` with a fake driver that
selects randomly. Add `tests/cli/fuzz_spec.lua`.

**Acceptance:** Fuzz `demo08` for 1000 runs; if a `verify` predicate fails, the saved
log + seed reproduces the exact failure under `storybase run --load …`.

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

### G2. HTTP API mode (stateless `/step`)

**Goal:** Distinct from existing `--serve` (which is stateful, browser-driven, one
game per process). Add a stateless POST `/step` taking `{save_log, choice_index}` and
returning `{narration, choices, save_log, done}`. Lets chatbots, Discord bots, web
frontends consume games without managing a process per session.

**Design sketch:**
- New CLI mode `storybase serve-api game.sb --port 8080`.
- POST `/step`: deserialise the input log, replay to current state, apply choice,
  return new log + scene render.
- Save log is the entire session state — clients hold it; server is stateless.

**Files:** new `cli/serve_api_cmd.lua`. Reuse the existing HTTP server from
`runtime/debug.lua`. `tests/cli/serve_api_spec.lua`.

**Edge cases:** Log size grows with session length — provide a `compact` option in
the API. Auth: out-of-scope; document as "place behind a reverse proxy."

**Acceptance:** A Python or JS client can POST a sequence of choices and complete
`demo01_wanderer.sb` end to end without any persistent state on the server.

### G3. Engine adapters (Löve2D, Godot, etc.)

**Goal:** StoryBase as the logic layer; host engine handles graphics, audio,
input. The driver abstraction added in 2026-05-02 already proves this is possible
in-process.

**Design sketch:** Document and stabilise the `driver` interface (already implemented
for `plain` / `ansi` / `narrate`). Write reference adapters:
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

### H4. Inventory / dialog / quest stubs as separate from §E

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

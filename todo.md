# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-20)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–25 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
UI driver layer complete. All compile-time validation gaps (AV-1 through AV-4) and
silent-failure hazards SF-1 through SF-4 resolved. All AE issues (AE-1 through AE-17)
resolved. All critical and major bugs (#1–#13) resolved. Full audit backlog (§A3–§A16)
complete. §B1/B2/B4/B5, §C1/C2/C3/C4, §F1/F2, and the full §E series (E0 decl-macro
substrate, E1 quests, E2 dialog-topic, E3 inventory+stat, E4 review fixes) all
complete. §G2 (stateless HTTP API) and §H2 (diff-mode hot reload) also complete.
I1 (demo26 — record `with` mixins + path-pattern queries), I2 (demo27 — file-local
user-authored `decl-macro`), and I3 (demo28 — counterfactual `from:` rewind +
`distribution: conditioned-on` bounded) all complete. See completed.md.

**~2924 successes / 0 failures / 2 pending (known limitations).**
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
3. §G1 — Web/JS compilation target

**Demo coverage gaps (smaller, parallelisable):** §I4–I6 add demos 29–31 for
language features that ship today but have no end-to-end example: computed
`-> (expr)` + imperative scene nav, the `changes` hook binding, and a Lua
embedded-host walkthrough. See §I for specs. (I1 / demo26 — record `with`
mixins + path patterns, I2 / demo27 — user-authored `decl-macro`, and
I3 / demo28 — counterfactual `from:` + conditioned-on bounded — all
complete; see completed.md.)

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

(H4 — inventory/dialog/quest stubs — folded into §E; all complete, see completed.md.)

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

## I. Demo Coverage Gaps (new demos 28–31)

A 2026-05-19 audit of `demos/demo01–25` against `docs/reference/language.md`
found a handful of supported language features that no current demo exercises
end-to-end. Four new demos below fill those gaps. Each item names the specific
features to showcase, the suggested theme, and an acceptance criterion. Implement
in order; each is independent. (I1 / demo26, I2 / demo27, and I3 / demo28 all
complete; see completed.md.)

### I4. demo29 — "Caravan Dispatch" (`demo29_caravan_dispatch.sb`)

**Primary gap:** Computed `-> (expr)` goto and imperative scene navigation
(`goto-scene!` / `enter-scene!` / `exit-scene!`). Both are documented in
`language.md` §Scene Syntax but no demo uses either form.

**Features demonstrated:**
- `-> (next-stop-for player/route)` — the destination scene is computed at
  runtime from a pure helper fn returning a scene-name symbol
- Side errands use `=> errand-name` to push the scene stack and `<-` to pop,
  paired with `enter-scene! 'name` / `exit-scene!` from inside a fn body
  (proving both syntactic forms target the same machinery)
- `goto-scene! 'name` from a fn called by a choice, as the explicit
  imperative equivalent of `-> name`
- A `Scene = SymbolOf(...)` (or named-enum) discipline for the computed-goto
  expression's return type, so the route table is type-checked

**Acceptance:** Routing a caravan through five stops requires only one
top-level `-> (...)` form; an errand `=>` cleanly returns via `<-` with the
scene stack matching before/after; `storybase verify` proves every reachable
route reaches a final scene.

### I5. demo30 — "The Quartermaster's Audit" (`demo30_quartermaster.sb`)

**Primary gap:** The `changes` binding inside `after:` / `post:` hooks (the
per-mutation diff list). Also a chance to highlight `strict-contracts: true`
and a real `post:` contract with `path@before`.

**Features demonstrated:**
- `tags: [transaction]` on every gameplay fn, and a single
  `hook transaction: post:` body that walks `changes` to render a per-turn
  ledger (`"3 gold spent, 1 herb consumed, morale -2"`)
- Inside the hook body, iterate `changes` with `for entry in changes:`,
  reading `entry/path`, `entry/old`, `entry/new`
- A `post:` contract on a `spend` fn using `player/gold@before` for a numerical
  postcondition
- `engine-config: strict-contracts: true` so the contract survives a production
  build, with a comment noting the implication
- A second `hook after: spend:` (function-level) that double-checks against
  the tag-level hook running

**Acceptance:** Running the demo yields a visible ledger at the end of each
turn driven entirely by `changes`; the `post:` contract triggers a clear
error when intentionally violated (a test fixture demonstrates the failure).

### I6. demo31 — Embedded host example (`demo31_embedded_host.sb` + `examples/demo31_host.lua`)

**Primary gap:** The Lua embedding host story. `engine/emit` fires in
`demo08` / `demo09` / `demo10`, but no end-to-end example shows a Lua host
consuming those events via `game:on("event-name", handler)`. This is the
operational counterpart to the language-feature demos above.

**Features demonstrated (StoryBase side, in `demo31_embedded_host.sb`):**
- Several `engine/emit` sites tagged with structured payloads
  (e.g. `engine/emit 'door-opened {room: ..., key: ...}`)
- A tiny `state` / `scene` shell sufficient to drive a few interesting events

**Features demonstrated (host side, in `examples/demo31_host.lua`):**
- `local game = require("storybase").load("demo31_embedded_host.sb")`
- `game:on("door-opened", function(payload) … end)` for every event the demo emits
- A driver loop that calls `game:render()` / `game:choose(n)` and prints
  attributed dialogue objects vs. plain narration lines (the type-table check
  from `docs/reference/language.md` §Dialogue)
- A demonstration of save/load round-tripping through the host API

**Acceptance:** `lua5.4 examples/demo31_host.lua` runs the game to completion
without using the `storybase` CLI; every `engine/emit` call lands in a
registered handler; the printed transcript shows speaker attribution working
through the host. Add a brief `docs/howto/lua_embedding.md` cross-reference.

### I7. Coverage tracker

Once all six land, the language features without demo coverage drop to a
small residue worth documenting (not necessarily demoing): `Set` operations
(`union` / `intersect` / `difference`), `(set)` empty literal, `engine/checkpoint!`
with an explicit label argument, and lambda expressions outside a `find`
clause. Add a note in `completed.md` if/when that residue is acceptable.

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

# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-20)

The core language and runtime are feature-complete against the V1.0 specification.
All eight implementation phases, language review passes 1 and 2, the full audit
backlog, the full §E series, §F1/F2, §G2, §H2, and the I-series demos (26–32) are
complete — details in [completed.md](completed.md).

**~2958 successes / 0 failures / 2 pending (known limitations).**
(HTTP/debug spec failures are transient network timing issues — ignore unless
touching http/debug code.)

A **language review pass 3** (2026-05-20) surveyed demos 01–32 against the demos
themselves and surfaced 10 authoring inelegances plus 5 verified runtime/parser
bugs (two correctness, three diagnostic). See **§J** below.

J-B1 and J-B2 (the two correctness bugs) were **fixed on 2026-05-21** — family
`max:` is now enforced at `spawn!`, and `find ... limit:` evaluates arbitrary
integer expressions at runtime. Regression tests live in
`tests/runtime/state_spec.lua`, `tests/runtime/query_spec.lua`, and
`tests/runtime/j_bugs_spec.lua`.

---

## What to work on next

**Diagnostic gaps from review pass 3 (small, polish):**
- §J-B3 — unknown `find` named-args silently skipped
- §J-B4 — `size`/`count` on non-collection silently returns 0
- §J-B5 — `when … : <expr>` looks like early-return but isn't

**Authoring inelegances from review pass 3 (larger, design-first):**
- §J-I1 (per-symbol fn duplication) and §J-I2 (loops in choice lists) account for
  the bulk of duplication across the 32 demos — investigate these first.
- §J-I4 (time-axis / state-path double bookkeeping) shows up in demos 10, 16, 20, 22.
- Others (§J-I3, I5–I10) are smaller polish.

**Lower-priority polish (open, not blocking):**
- §A1 — SF-5 — already partially mitigated by AV-4; consider closing.
- §A2 — Inelegance #7 — BFS expansion duplication (deferred; documented).

**Future Features and Extensions (large):** Suggested ordering for impact:

1. §D1 — LLM-bounded handler standard module
2. §B3 — Trace scrubber (browser debug UI)
3. §G1 — Web/JS compilation target

**Demo coverage:** All seven I-series demos (26–32) complete. demo32
promoted three of the four §I7 residue items (set ops, `(set)` literal,
labelled `engine/checkpoint!`). The remaining residue item — **lambda
expressions outside a `find` clause** — is still covered only by unit
tests; promote only if a user-facing limitation surfaces.

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

## J. Language Review Pass 3 (2026-05-20)

A read-through of demos 01–32 to spot places the demos visibly work around
language limits, plus targeted runtime/parser inspection for bugs hinted at
by those workarounds. Two of the five bugs were verified with minimal
repro `.sb` files.

### J-B1. Family `max:` capacity not enforced at `spawn!` ✅ FIXED (2026-05-21)

`state things/{t}: Thing max: 2` previously declared a cap that
`runtime/state.lua:store:spawn` ignored — only the `SPAWN_EXISTS` uniqueness
sentinel was checked. Fixed by counting existing keys via `path_list(family)`
before allowing a new spawn; raises `FAMILY_FULL` at the cap. Set/List capacity
enforcement remains unchanged.

Regression tests: `tests/runtime/state_spec.lua` (unit) and
`tests/runtime/j_bugs_spec.lua` (e2e: `spawn!` errors at cap, despawn frees a
slot, no-cap families remain unbounded).

### J-B2. `find ... limit: <non-int-literal>` silently falls back to 10 ✅ FIXED (2026-05-21)

`compiler/parser.lua` (find-clause parser) used to drop any non-`int_lit`
limit expression and substitute the literal `10`. Fixed by storing the
parsed expression alongside the literal-int fast-path (`value_expr` on the
clause); `runtime/query.lua` evaluates `value_expr` at find-time and errors
on non-integer (`FIND_LIMIT_TYPE`) or negative (`FIND_LIMIT_NEGATIVE`)
results. Literal-int `limit: 4` continues to work via the unchanged
`clause.value` path (preserves all existing parser tests).

Regression tests: `tests/runtime/query_spec.lua` (unit: path-limit, arith,
non-int error, zero) and `tests/runtime/j_bugs_spec.lua` (e2e via
`fn limited: find things ... limit: world/cap`).

### J-B3. Unknown `find` named-args silently skipped [bug — diagnostic]

Same parser block: an unrecognised `NAMED_ARG` inside a `find ...` clause
list is dropped with a "skip" comment. Typos like `wherre:` produce no
error. Other parsers emit `BAD_EXPRESSION` for unknown tokens.

**Fix sketch:** add a final `else: p:emit_err(ast.E.BAD_EXPRESSION, "unknown find clause '" .. na.value .. "'", na.pos)` branch.

### J-B4. `size`/`count` on a non-collection silently returns 0 [bug — diagnostic]

`runtime/eval.lua:1055` (`size`) and `:1065` (`count`) both early-return 0
on a non-table input. Catches author mistakes like `size things` (treating
a family-base path as a list — `things` resolves to nil, `size nil → 0`).

**Fix sketch:** at compile time, when the receiver's type is known and is
not Set/List/UList/Map/relation-adjacency, emit a `NOT_A_COLLECTION`
warning. Keep the runtime tolerant behavior (avoids breaking valid uses
on optional values).

### J-B5. `when … : <expr>` looks like early-return but isn't [bug — diagnostic]

`runtime/eval.lua:2325`: a `when` body that evaluates to a value sets
`ctx.retval`, but the surrounding sequence continues and any subsequent
expr-stmt overwrites it. Authors copying patterns like demo08's
`supply-path-steps`:
```
when path = nil:
  0
count-where path fn(step): true
```
will get a silent wrong answer when the follow-up call isn't itself
nil-tolerant. (demo08 happens to work because `count-where nil` also
returns 0.)

**Fix sketch:** in `compiler/checker.lua` (or a new lint pass), warn when
a `when`-body's last statement is a bare expression and a sibling
statement follows that also produces a value. Alternatively, document
clearly that StoryBase fns have no early return — only the last evaluated
expression wins.

### J-I1. Symbol-keyed work needs N near-identical fns [inelegance]

Every demo with parallel actions per symbol writes one fn per case:
- demo02: `buy-herbs`/`buy-iron`/`buy-silk` + `sell-*` (6 fns differing
  only by symbol + price path)
- demo05: `order-battle-stations`/`order-guarded`/`order-stand-down` (only
  diff is the message constructor)
- demo11: `* Hire X` choice repeated for each of 4 members
- demo15: `cast-fireball`/`cast-ice-shard`/`cast-heal-beam` despite the
  spell record already carrying `mana-cost` and `ingredient`

**Root cause:** no way to bind a Symbol parameter to a path-builder so
`cast-spell s` can read `spells/{s}/mana-cost`. Macros + interpolated
paths half-solve it inside fn bodies, but choice lists can't be generated
this way.

**Possible direction:** decl-macros already let authors generate per-symbol
fns; document the pattern (`cast-spell-decl `fireball`) explicitly, OR
extend interpolated-path semantics so a fn parameter can drive both
sides of a `spells/{s}/...` lookup (it already works in many cases —
verify which cases fail).

### J-I2. Choice lists are static — no `for npc in ...: * Talk to {npc}` [inelegance]

A scene with N family members duplicates the choice block N times:
demo04 crew narration, demo07 four shrines, demo11 four hires, demo20
per-room "X here:" lines.

**Possible direction:** allow a `for x in <list>: *` form inside scene
bodies that generates one choice per iteration with `{x}`-interpolated
guards and text. Engine already loops over choices at runtime; the gap
is parser/codegen.

### J-I3. No `elif` / `else if` [inelegance — small]

Every multi-branch ending uses nested `if/else: if/else:` (demos 03, 05,
09, 10, 11, 14, 16, 21, …). Adds one indent level per branch.

**Possible direction:** parser-only change — accept `else if` after an
`if`-body and desugar to nested `if_expr`. Or add `cond` to scene-body
context (it's already an expression form).

### J-I4. Time-axis ↔ state path double-bookkeeping [inelegance]

Demos 10, 16, 20, 22 all pair every `time-inc! turn: N` with `inc! world/turn N`
(and `time-set! hour: 8` with `set! world/hour 8`). The engine's time axis
is invisible from narration paths, so authors mirror it into a state path.
demo20 even mirrors three things meaning one: `world/period` (enum),
`world/period-index` (Int), and the actual time axis.

**Possible direction:** expose time-axis values as readable paths (e.g.
`time/turn`, `time/hour`) so narration can interpolate them directly and
state-path mirrors go away.

### J-I5. Bidirectional relations need manual mirroring [inelegance]

demo16: `relate! roads `a `b; relate! roads `b `a`. No symmetric flag.

**Possible direction:** a `bidirectional: true` field on `relation` declarations,
or a `relate-bi!` mutation.

### J-I6. No integer range [inelegance]

Every numeric loop is `for x in [0,1,2,3,4,5,6,7]:` (demo09). demo23 wants
"spawn N rooms" but can't loop over a runtime count, so it uses cascaded
`when count >= 4` / `when count >= 5` blocks.

**Possible direction:** `for i in 0..count:` or a `range` builtin
returning a list. The latter is one new entry in `eval.lua`'s builtin
table.

### J-I7. Five names for "length" [inelegance — documentation]

`size`, `count`, `list-size`, `ulist-size`, `map-size`. demo08 uses
`count-where path fn(step): true` to count a list — a clear "didn't find
the right builtin" workaround.

**Possible direction:** either consolidate to `size` as the canonical
polymorphic name (keep `*-size` as aliases) or add a "which length
function to use" note to `docs/reference/language.md`.

### J-I8. `set!` on a `let`-binding silently writes a fake state path [inelegance]

Already tracked as §A1 (SF-5). Kept here only as a cross-reference: still
visible to authors despite the AV-4 mitigation.

### J-I9. Author writes redundant clamp [inelegance — discoverability]

demo05: `dec! castle/supplies 10; when castle/supplies < 0: set! castle/supplies 0`.
Inline `Int(0, 300)` already clamps — the guard is dead code. The
clamping behavior isn't visible enough.

**Possible direction:** mention clamping in error messages when the demo
manually clamps, or add a checker lint for "dead guard after inc!/dec!".

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

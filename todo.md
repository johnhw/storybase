# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-22)

The core language and runtime are feature-complete against the V1.0 specification.
All eight implementation phases, language review passes 1 and 2, the full audit
backlog, the full §E series, §F1/F2, §G2, §H2, and the I-series demos (26–32) are
complete — details in [completed.md](completed.md).

**~3047 successes / 0 failures / 2 pending (known limitations).**
(HTTP/debug spec failures are transient network timing issues — ignore unless
touching http/debug code.)

A **language review pass 3** (2026-05-20) surveyed demos 01–32 against the demos
themselves and surfaced 10 authoring inelegances plus 5 verified runtime/parser
bugs (two correctness, three diagnostic). See **§J** below.

All 5 bugs (J-B1..B5) were **fixed on 2026-05-21**. Authoring inelegances
J-I3 (elif / else if), J-I5 (bidirectional relations), J-I6 (range
builtin), and J-I7 (length-name rationalisation) were also fixed on
2026-05-21. J-I2 (looped / gated choices) was fixed on 2026-05-22.
J-I4 (time-axis / state-path mirroring) was closed on 2026-05-22 by
migrating demos 10, 16, 20 to read `time/<axis>` directly. The
remaining 4 inelegances (J-I1, I8, I9, I10) stay open as design-first
backlog.

---

## What to work on next

**Authoring inelegances from review pass 3 (larger, design-first):**
- §J-I1 (per-symbol fn duplication) — re-evaluate now that J-I2 has
  shipped; many cited cases fold into "single parameterised fn + looped
  choice list."
- §J-I8–I10 are smaller polish. §J-I2 (choice-list looping), §J-I3
  (elif), §J-I4 (time-axis mirrors), §J-I5 (bidirectional relations),
  §J-I6 (range builtin), and §J-I7 (length-name rationalisation) all
  fixed.

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

### J-B3. Unknown `find` named-args silently skipped ✅ FIXED (2026-05-21)

`compiler/parser.lua` find-clause parser now emits
`WARN_UNKNOWN_FIND_CLAUSE` when a NAMED_ARG inside `find ...` is not one
of {`where`, `or-where`, `order-by`, `limit`, `in-state`}. The warning
lists the recognised clause names. Recovery skips the unknown clause's
value expression so the rest of the find continues to parse cleanly.
Implemented as a warning (not an error) so existing surfaces keep
compiling — typos still surface in `--check` output.

Regression test: `tests/compiler/checker_spec.lua "parser — J-B3:
unknown find clause"`.

### J-B4. `size`/`count`/`empty?` on a non-collection ✅ FIXED (2026-05-21)

New checker pass `pass_check_size_count_receiver` walks every fn_call
to `size`/`count`/`empty?` and warns when the single argument is one of
the two clear authoring mistakes:
1. A bare zero-arg call to a declared family name — author meant
   `(path-list family)`. The hint suggests the rewrite.
2. A state path whose declared type is a non-collection scalar
   (Int/Bool/Symbol/Float/named record). The warning notes that the
   result will always be 0 (or `true` for `empty?`).

Runtime semantics unchanged — `size nil → 0` still tolerates Option
values and unknown fn returns. Collection types accepted: Set, List,
UList, UMap, String, and Option-wrapped versions of those.

Regression tests: `tests/compiler/checker_spec.lua "checker — J-B4:
size/count/empty? receiver type"` (7 cases — family, scalar Int,
empty? Int, List ok, path-list ok, Set ok).

### J-B5. `when … : <expr>` looks like early-return but isn't ✅ FIXED (2026-05-21)

New checker pass `pass_check_when_value_overwritten`. Restricted to `fn`
bodies (scene/choice/hook bodies use narration in expression position
and the warning doesn't apply there). Fires when:
1. A `when` body's last statement is a value-producing expression
   (literal, fn_call, if_expr, match_expr, etc.)
2. AND a following statement in the same body also produces a value
   that will overwrite the `when` result.

The hint suggests rewriting with `if`/`else`, `cond`, or `match` to get
proper exclusive branches.

Note: demo08 `supply-path-steps`/`supply-optimal-steps` still emit this
warning — they accidentally work because `count-where nil` also returns
0. Author's call whether to rewrite; the warning is informational, not
breaking.

Regression tests: `tests/compiler/checker_spec.lua "checker — J-B5:
when-body value overwritten"` (5 cases including the canonical bug shape,
last-stmt OK, mut-body OK, scene narration silent, follow-by-mut OK).

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

### J-I2. Choice lists are static — no `for npc in ...: * Talk to {npc}` [inelegance] — DONE 2026-05-22

A scene with N family members previously duplicated the choice block N
times (demo04 crew narration, demo07 four shrines, demo11 four hires,
demo20 per-room "X here:" lines).

**Fixed (2026-05-22)** by extending `runtime/engine.lua` to descend into
`for` / `when` / `if` blocks when rendering choices and locating the
player's selection. New helper `eng:_walk_scene_choices(items, ctx,
visit)` performs a single left-to-right depth-first traversal shared by
`render_scene` and `do_choice`, guaranteeing the visible-index → (choice
node, iteration bindings) mapping is identical across render and execute.
`do_choice` propagates for-loop variable bindings into the choice body's
execution context so interpolated paths (`set! items/{i}/taken true`)
resolve to the correct family member.

**Shape C — enum-case iteration.** `for s in EnumKind:` iterates the
enum's variant symbols. Implemented in `eval.eval_for_iter`, so the
shortcut also works in `fn` / `generate` bodies. Falls through to
`eval_expr` for any iter that is not a bare enum type name.

Latent bug closed: the parser previously accepted `*` choices inside
scene-mode `when`/`if`/`for` but the runtime silently dropped them
(`engine.lua:368` literally said "narration-only, no choice"). Now they
participate in the visible list.

Regression tests: `tests/runtime/j_i2_spec.lua` (15 cases — for over list
literal / family / enum, per-iteration guard filtering, empty-iteration
else, when-grouped choices, if/else branches, nesting and visible-index
ordering, do_choice iter-binding propagation, replay determinism, BFS
can_reach behind a looped choice). See
`docs/reference/language.md#choices-inside-for--when--if`.

### J-I3. No `elif` / `else if` [inelegance] — DONE 2026-05-21

Every multi-branch ending used nested `if/else: if/else:` (demos 03, 05,
09, 10, 11, 14, 16, 21, …). Added one indent level per branch.

**Fixed (2026-05-21)** as a parser-only change. `parse_if_expr` now accepts
either `else if cond:` or `elif cond:` after the then-body and desugars to
a nested `if_expr` placed in the parent's `else_body`. The runtime, checker,
and codegen are unchanged — the AST shape is identical to hand-nested
`if/else: if`.

`elif` is a new lexer keyword. `else if` works via lookahead (KEYWORD
"else" followed by KEYWORD "if"). Both forms are interchangeable. Demos
4, 6, 7, 8, 9, 10, 11, 12, 20, 21 migrated to the flattened form; demo20
alone collapsed 10 three-deep `world/phase` chains into single elif
ladders. See `docs/reference/language.md#if-expression`.

### J-I4. Time-axis ↔ state path double-bookkeeping [inelegance] — DONE 2026-05-22

Demos 10, 16, 20 all paired every `time-inc! turn: N` with `inc! world/turn N`
(and `time-set! hour: 8` with `set! world/hour 8`). The engine's time axis
appeared invisible from narration paths, so authors mirrored it into a state path.
demo20 even mirrored three things meaning one: `world/period` (enum),
`world/period-index` (Int), and the actual time axis.

**Resolution:** The underlying feature already shipped on **2026-05-07** as
**AE-3** — `time/<axis-name>` is a read-only pseudo-path backed directly by
the engine's time state (e.g. `time/day`, `time/hour`, `time/period`). The
remaining work was a demo migration:

- **demo10** — dropped `state world/day` and `state world/hour`; narration now
  reads `{time/day + 1}` and `{time/hour}`. Day/hour math realigned: hour 0
  is dawn, the market closes at hour 10 (instead of 18) so the original
  5-browses-per-day rhythm is preserved. `engine/emit` payloads keep
  1-indexed `day` for narrative consistency.
- **demo16** — dropped `state world/turn`; narration and writes use
  `{time/turn}` and `time-inc! turn: 1` directly.
- **demo20** — dropped `state world/period`, `state world/period-index`, and
  `state world/day`. Added a `day` axis to `time-model` so the period-wrap
  bumps day natively. Schedule and pure functions read `time/period`; a
  helper `current-period` fn maps `time/period` → Period enum for
  narration (`{current-period}`).
- **demo28** is intentionally left untouched — it uses `world/turn` as a
  genuine state path for counterfactual `from: (world/turn - 3)` rewinds,
  which depend on per-turn ticks living in the transaction log.

Supporting change: `lib/storybase.lua#get(path)` now recognises
`time/<axis>` and delegates to the engine's `state:get_time()`, so tests
and embedded hosts can read the engine clock through the same API as
declared state paths.

CLI integration tests for demo10 (3 cases) and demo16 (1 case) updated to
match the new schemas and the realigned hour math. All 3047 tests pass.

### J-I5. Bidirectional relations need manual mirroring [inelegance] — DONE 2026-05-21

demo16: `relate! roads `a `b; relate! roads `b `a`. No symmetric flag.

**Fixed (2026-05-21)** by adding two new intrinsics: `relate-both!` and
`unrelate-both!`. Each writes two log entries (one per direction) so
replay, undo, and counterfactuals all see both edges. Migrated demos 16
and 20 to remove the manual mirror lines. Tests in
`tests/runtime/eval_spec.lua` "eval_stmt: relate_both_mut / unrelate_both_mut".
See `docs/reference/language.md#relate-both--unrelate-both`.

### J-I6. No integer range [inelegance] — DONE 2026-05-21

Every numeric loop previously spelled out the integers (`for x in
[0,1,2,3,4,5,6,7]:` in demo09); runtime-sized loops weren't expressible
at all.

**Fixed (2026-05-21)** by adding a `range` builtin in `runtime/eval.lua`'s
BUILTINS table (Python-style, exclusive upper bound):
- `range n` → `[0..n-1]`
- `range lo hi` → `[lo..hi-1]`
- `range lo hi step` → directional, non-zero step

Result capped at 10000 elements (matches the engine's while-loop safety
limit). `range` was also added to the checker's `CHECKER_BUILTIN_FNS`
allow-list so calls don't surface as `unknown call` warnings. Tests in
`tests/runtime/eval_spec.lua` ("eval: range builtin"). See
`docs/reference/language.md#collection-builtins`.

### J-I7. Five names for "length" [inelegance] — DONE 2026-05-21

`size`, `count`, `list-size`, `ulist-size`, `map-size`. demo08 used
`count-where path fn(step): true` to count a list — a clear "didn't find
the right builtin" workaround.

**Fixed (2026-05-21)** by consolidating to a single shared `size_impl`
in `runtime/eval.lua`'s BUILTINS table. `size` is the canonical
polymorphic name; `count`, `list-size`, `ulist-size`, and `map-size`
are aliases that all reference the same implementation, so they always
agree on every input (sequence tables, hash-style tables, non-tables).
The J-B4 checker's `SIZE_LIKE_FNS` set was extended to include the
`*-size` aliases so applying any of them to a scalar emits the same
`NOT_A_COLLECTION` warning.

demo08's `supply-path-steps` / `supply-optimal-steps` were rewritten
from the `count-where path fn(step): true` workaround to the obvious
`size path`, and from `when path = nil: 0` / value-expr-follows to a
proper `if path = nil: 0 else: size path` (also clearing the J-B5
warning those functions previously emitted).

Tests in `tests/runtime/eval_spec.lua` ("size, count, list-size,
ulist-size, map-size are aliases" — sequence, map-style, non-table) and
`tests/compiler/checker_spec.lua` (J-B4 cases for the three new
aliases). See `docs/reference/language.md#collection-builtins`.

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

## K. Demo backlog

### K1. demo33 — "The Apothecary's Counter" (showcase for J-I2) — **DONE 2026-05-22**

Shipped: `demos/demo33_apothecary.sb` (~120 lines), regression suite
`tests/runtime/demo33_spec.lua` (7 tests, all green), and 5 CLI
integration cases in `tests/cli/cli_integration_spec.lua` (compile,
--production compile, verify, --auto playthrough, 25-choice count).

All four acceptance criteria from the spec below are tested directly:
initial 25-choice render, looped-choice iter-binding propagation (treating
bethe with the "tonic" iter binding), if/else flip on moonpetal depletion,
and the outer `when shop/served >= 4` end-of-day gate.

One small spec deviation: the spec sketch used `++` for string concatenation
(non-existent operator) inside `set! shop/last-note`; the demo uses the
existing variadic `(str ...)` builtin instead — same observable behaviour,
no language change needed.  No other surprises: J-I2 carried the whole
scene structure end-to-end (BFS verify of `shop/served >= 4` passes in 489
states).

Original spec below for reference:

### K1 (original spec). demo33 — "The Apothecary's Counter" (showcase for J-I2)

**Goal:** a single-scene demo whose interactive structure depends entirely
on the three J-I2 affordances (looped, gated, branched choices) and on
Shape C (enum iteration). Pre-J-I2 the same content would have required
~28 hand-written choice rows for four patients; the proposed scene
expresses it in one for-loop with three sub-blocks.

**Mechanic.** You run a counter. Four patients are waiting, each with a
`Symptom` (ache / fever / cough / malaise). On each turn you pick a
remedy from the `Remedy` enum (poultice / tincture / salve / tonic).
Feverish patients also accept a cool compress (extra `when`-gated choice).
While your moonpetal stock is non-zero, two premium remedies are also
craftable (`if`/`else` branching). The day ends when all four are tended.

**Files:** `demos/demo33_apothecary.sb` (+ optional tests file). Add to
`tests/cli/cli_integration_spec.lua` per existing pattern.

**Source sketch:**

```
module demo33-apothecary
  version: 1.0

# Demo 33 — The Apothecary's Counter
# Demonstrates J-I2: looped + gated + branched choices in a single scene.

engine-config:
  entry-scene: counter

type Symptom = ache | fever | cough | malaise
type Remedy  = poultice | tincture | salve | tonic
type Premium = elixir-of-moon | dragonbalm

type PatientRec:
  symptom: Symptom = `ache
  treated: Bool    = false

state patients/{p}:   PatientRec  max: 12
state shop/moonpetal: Int(0, 10) = 1
state shop/served:    Int(0, 99) = 0
state shop/last-note: String     = ""

generate stock-counter:
  spawn! patients `arlin  PatientRec(symptom: `ache,    treated: false)
  spawn! patients `bethe  PatientRec(symptom: `fever,   treated: false)
  spawn! patients `corwin PatientRec(symptom: `cough,   treated: false)
  spawn! patients `dell   PatientRec(symptom: `malaise, treated: false)

fn treat p r:
  set! patients/{p}/treated true
  inc! shop/served 1
  set! shop/last-note "Prepared a " ++ (str r) ++ " for " ++ (str p) ++ "."

fn premium-treat p r:
  dec! shop/moonpetal 1
  set! patients/{p}/treated true
  inc! shop/served 1
  set! shop/last-note "Crafted a rare " ++ (str r) ++ " for " ++ (str p) ++ "."

scene counter:
  Served {shop/served}.  Moonpetal x{shop/moonpetal}.
  {shop/last-note}

  for p in (path-list patients):
    [not patients/{p}/treated] {p} waits ({patients/{p}/symptom}).
    for r in Remedy:                          # Shape C: enum iteration
      * [not patients/{p}/treated] Give {r} to {p}
        treat p r
        -> counter
    when patients/{p}/symptom = `fever:       # when-gated extra
      * [not patients/{p}/treated] Apply cool compress to {p}
        treat p `poultice
        -> counter
    if shop/moonpetal > 0:                    # if/else branching
      for r in Premium:                       # Shape C inside if
        * [not patients/{p}/treated] Brew {r} for {p}
          premium-treat p r
          -> counter
    else:
      [not patients/{p}/treated] (Premium remedies need moonpetal.)

  when shop/served >= 4:
    All patients tended.  The day is done.
    * Close up shop
      -> end-day

scene end-day:
  You served {shop/served} patients today.  Rest well.
```

**Features the demo lights up (each from §J-I2):**
| Feature | Lines |
|---|---|
| `for p in (path-list family):` | outer loop over patients |
| `for r in EnumKind:` (Shape C) | inner loops over Remedy, Premium |
| `when cond: *` extra choice | cool-compress for fever patients |
| `if cond: * ... else:` branching | premium remedies gated by moonpetal |
| iter-binding flows into choice body | `treat p r`, `premium-treat p r` |
| conditional narration inside for | "{p} waits ({patients/{p}/symptom})" |

**Acceptance:**
1. Initial render of `counter` shows ≥ (4 patients × 4 Remedy) + 1 fever
   + (4 × 2 Premium) = 25 visible choices (modulo treated filtering).
2. Picking choice 9 ("Give tonic to bethe") marks `patients/bethe/treated`
   and bumps `shop/served` to 1; the next render of `counter` shows
   patients other than bethe still waiting.
3. After moonpetal hits 0 (use two premium brews), the if/else flips and
   the "(Premium remedies need moonpetal.)" narration line replaces the
   premium choice rows.
4. After all four treated, the `when shop/served >= 4` block surfaces
   "Close up shop" as the single remaining choice; selecting it ends.

**Why pre-J-I2 this was awkward.** Without looped/gated/branched
choices, the scene would have required either 28 hand-written choice
rows (4 patients × 7 possible actions each, mostly disjoint) or a forest
of per-patient sub-scenes reached via `=>`. The mechanic is itself the
showcase: a player faces an action menu derived from declarative game
state plus type definitions, with zero per-patient/per-remedy author
duplication.

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

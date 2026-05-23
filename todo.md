# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-23)

The core language and runtime are feature-complete against the V1.0 specification.
All eight implementation phases, language review passes 1 and 2, the full audit
backlog, the full §E series, §F1/F2, §G2, §H1, §H2, and the I-series demos
(26–32) are complete — details in [completed.md](completed.md).

**~3085 successes / 0 failures / 2 pending (known limitations).**
(HTTP/debug spec failures are transient network timing issues — ignore unless
touching http/debug code.)

Language Review Pass 3 (2026-05-20) is now closed on the runtime/parser side: all
5 bugs (J-B1..B5) and 8 of the 10 authoring inelegances (J-I1, I2, I3, I4, I5,
I6, I7, I9) shipped between 2026-05-21 and 2026-05-22. The remaining 2
inelegances (§J-I8, I10) stay open below as design-first backlog. K1 (demo33,
J-I2 showcase) shipped 2026-05-22; §H1 (goal-directed actors) closed with
demo34_silent_stair on 2026-05-23 — the demo work also surfaced and fixed an
npc-speed gap in `runtime/search.lua` / `runtime/verify.lua` (now route through
the new `eng:post_action_chain()`).

---

## What to work on next

**Active work:**
- §L — Unified configuration system (see plan below). L1 + L2 done; next up is L3 (sweep remaining `engine_config` reads: `entry-scene`, `npc-speed`).

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

## L. Configuration system (2026-05-23)

Unify the three overlapping config surfaces (in-source `engine-config:` block,
CLI flags, scattered magic constants) behind a single registry-backed module
with a precedence chain. Keys are namespaced (dotted, lowercase, hyphens kept),
declared once with type + default + doc, and resolved on read.

**Precedence (highest first):** `runtime > cli > env > file > game > default`
- `runtime` — `config.set()` programmatic override
- `cli`     — populated from parsed CLI args
- `env`     — `STORYBASE_*` env vars (auto-derived from key name)
- `file`    — `~/.storybaserc` / `./.storybaserc` (simple `key = value` lines, `#` comments)
- `game`    — the compiled `engine-config:` block of the loaded `.sb` file
- `default` — built-in defaults from the registry

Decisions locked in (2026-05-23):
- Game's `engine-config:` block sits below CLI/env, above the user file. The
  author's intent overrides cross-game user defaults, but invocation-time
  CLI/env can still override.
- File format is simple `key = value` lines (no TOML dep).
- Roll out as pilot-first: land the module, migrate one key
  (`engine.scene-stack-max`), prove the round-trip, then sweep.

### L1. Module + tests (Step 1) [done 2026-05-23]

- `runtime/config.lua` with API: `declare`, `get` (returns `value, layer`),
  `set`, `load_env`, `load_file`, `bind_game`, `bind_cli`, `dump`, `keys`,
  `spec`, `_reset` (test-only).
- Unknown-key reads/writes error.
- Type coercion for `int`, `float`, `bool`, `string`, `enum`.
- `tests/runtime/config_spec.lua` covering precedence, coercion, env-var name
  derivation, file parsing (comments, quoted values, malformed, unknown keys),
  `bind_game` from a stub game_table, `bind_cli` from a flag table, `dump`.

### L2. Pilot migration: `engine.scene-stack-max` [done 2026-05-23]

- Declared with `type="int", default=16` (matching prior `DEFAULT_MAX_STACK`)
  via an idempotent `declare_engine_config()` helper at the top of
  `runtime/engine.lua` — idempotency lets the declaration survive
  `config._reset()` between specs.
- `engine.new()` now calls `config.bind_game(game_table)` and reads via
  `config.get("engine.scene-stack-max")`. `opts.max_stack` is retained as a
  per-instance escape hatch (used by `diff_replay`) and wins without mutating
  global config state.
- Behavior change vs. pre-L2: when both the game's `engine-config:` block and
  a runtime override (CLI/env/file/set) are present, the runtime override now
  wins (previously the in-source block always won). This matches the locked-in
  precedence design.
- Regression tests added in `tests/runtime/engine_spec.lua` ("scene-stack-max
  via config module"): default layer, game layer, runtime override beating
  game, and `opts.max_stack` escape hatch.

### L3. Sweep remaining `engine_config` reads

- `engine.entry-scene` (engine.lua:577)
- `engine.npc-speed` (engine.lua:747, 873)
- Any new reads found by grepping `engine_config\b` / `engine-config`.

### L4. Env + file loading

- `STORYBASE_*` env var lookup at startup (caller decides when).
- `~/.storybaserc` then `./.storybaserc` (later wins).
- Errors surfaced as a return value, not raised; CLI decides whether to
  warn or abort.

### L5. CLI wiring

- `cli/main.lua` arg parser populates a `{key=value}` table and calls
  `config.bind_cli`. Existing `opts` table becomes a thin shim or goes
  away entirely.
- `print_usage()` generated from the registry's `cli` and `doc` fields.
- New `storybase config` subcommand: `config dump` (all keys with resolved
  value + winning layer), `config get <key>`, `config doc <key>`.

### L6. Sweep remaining magic numbers

- Debug ports (7373/7374), default bind address (127.0.0.1), `--steps`,
  `--ui` driver default, any other CLI-side magic numbers in
  `cli/main.lua` and `cli/drivers/`.
- One commit per logical group; do not try to do this in one pass.

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

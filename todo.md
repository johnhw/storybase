# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-18)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–23 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
UI driver layer complete. All compile-time validation gaps (AV-1 through AV-4) and
silent-failure hazards SF-1 through SF-4 resolved. All AE issues (AE-1 through AE-17)
resolved. All critical and major bugs (#1–#13) resolved. Full audit backlog (§A3–§A16)
complete. §B1/B2/B4/B5, §C1/C2/C3/C4, §F1/F2 all complete. §E0 (decl-emitting
macro substrate) complete and ready for §E2 / §E3 to ride on as stdlib modules.

**~2806 successes / 0 failures / 2 pending (known limitations).**
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
3. §E2 / §E3 — `dialog` / `inventory` / `stat` shipped as stdlib `.sb` modules
   (substrate ready: §E0 complete 2026-05-18)
4. §E1 — `quest` as base feature, layered on the E0 substrate
5. §G1 — Web/JS compilation target

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

### E0. Decl-emitting macro substrate

**Goal:** Make the macro system powerful enough that `dialog` / `inventory` /
`stat` (and any future "pattern every game reinvents") can live as stdlib `.sb`
modules instead of bespoke AST kinds. Today macros (`compiler/compiler.lua:495–533`)
expand statements only, and imports' `exports:` filter excludes `state`, so neither
mechanism can deliver a reusable state-family template.

**What this unlocks:** the three "patterns every game reinvents" become library
code; users can ship their own DSL patterns the same way; the language surface
stays small.

#### Confirmed design decisions (2026-05-17)

- **New keyword `decl-macro`** for declaration-emitting macros, parallel to the
  existing `macro`. The existing `macro` keyword stays stmt-level only; no
  overload. AST gets a new kind `DECL_MACRO_DECL` (parallel to `MACRO_DECL`)
  and a new kind `MACRO_CALL_DECL` (parallel to `MACRO_CALL_STMT`). No
  `body_kind` discriminator field — the AST kind encodes it.
- **Lexer-level `$param` support.** `$IDENT` becomes a new `MACRO_PARAM`
  token. Adjacent `IDENT` / `-` / `MACRO_PARAM` runs with no whitespace
  produce a composite identifier so `fn give-$path item:`, `fn $path-init`,
  and `has-$path?` all work as written. `$` was previously illegal outside
  string literals, so no existing test should regress.
- **Delivery:** six commits on `master`, one per stage below, tests added per
  stage. Bisect- and review-friendly.

#### Current state of the plumbing (already there)

- `expand_macros` already runs after `resolve_imports` and before
  `checker.check` (`compiler/compiler.lua:566–571`). ✓
- `MACRO_DECL` is already in `EXPORTS_FILTERABLE`
  (`compiler/compiler.lua:51,57`); the namespace renamer already rewrites
  `MACRO_CALL_STMT.name` (`compiler/compiler.lua:126`). Cross-import macro
  *names* are wired but untestable today because no macro body can emit
  decls. Stage 5 adds the same wiring for the new `MACRO_CALL_DECL` /
  `DECL_MACRO_DECL` kinds.
- `cli/verify_cache.lua:compute_hash` walks the typed AST post-expansion, so
  cache invalidation comes for free when a macro body that emits `verify`
  blocks is edited.

#### Stage 1 — Decl-bodied `decl-macro` parsing + AST ✅ (2026-05-17)

Done: parse `decl-macro NAME params...:` whose body is a list of decls
(`state`, `fn`, `scene`, `verify`, `actor`, `schedule`, `bounded`, `relation`,
`type`). Params are accepted but ignored at substitution time (no `$`
interpolation yet — that lands in stage 2).

- `compiler/ast.lua`: added `DECL_MACRO_DECL` and `MACRO_CALL_DECL` kinds;
  added `ast.decl_macro_decl(name, params, body, doc, pos)` and
  `ast.macro_call_decl(name, args, body, pos)` constructors; both kinds added
  to `DECL_KINDS` predicate set.
- `compiler/lexer.lua`: `decl-macro` added to the reserved-keyword table.
- `compiler/parser.lua`: forward-declared `parse_decl`; new
  `parse_decl_macro_decl` immediately after `parse_macro_decl`; wired into
  `parse_decl` under the `decl-macro` keyword. Header parses both
  `decl-macro name:` (NAMED_ARG name, no params) and
  `decl-macro name p1 p2:` (IDENT name + IDENT/NAMED_ARG param run). Body
  parses by looping `parse_decl` between INDENT/DEDENT.
- `compiler/compiler.lua` (`expand_macros`): strips `DECL_MACRO_DECL` nodes
  from the program after the existing `MACRO_DECL` strip so the checker /
  codegen don't see them. Placeholder for stage 3, which replaces the strip
  with proper decl-level expansion.
- `tests/compiler/macro_decl_spec.lua`: 11 tests — lexer keyword recognition;
  parser into `DECL_MACRO_DECL` for zero / one / many params, bodies
  containing `state` + `fn` + `verify`, empty body, doc-string preservation,
  source position; pipeline `compile()` accepts a program with a
  `decl-macro` without errors and does not register inner body decls as
  top-level fns.

No regressions: full suite still 2755 passing / 2 pre-existing pending
(unrelated formatter known-limitations).

#### Stage 2 — Lexer `$param` + composite identifiers

**Lexer half ✅ (2026-05-17).** Parser plumbing (storing `name_parts` on AST
nodes at name-consuming sites) is deferred to Stage 2b; lands together with
Stage 3 expansion so the spec coverage isn't theatre.

- `compiler/lexer.lua`: `$IDENT` now emits a `MACRO_PARAM` token (value =
  name string). A no-whitespace run mixing `IDENT` / `MACRO_PARAM` joined by
  `-` collapses into a single `COMPOSITE_IDENT` token whose `value` is a
  parts list — strings and `{kind="macro_param", name=...}` entries,
  consecutive string parts merged at emit time. Trailing `!`/`?` is
  appended to the last string part. Composite continuation does not cross
  whitespace, and a `/` ends the composite (`npcs/$kind` is three tokens —
  PATH-with-`$` is a Stage 3 concern). Bare `$` (no identifier) raises
  `ILLEGAL_CHAR` and the scanner recovers by consuming the lone `$`.
- `tests/compiler/macro_decl_spec.lua`: 16 new lex-level tests covering
  `$path`, `give-$path`, `$path-init`, `$a-$b`, `has-$path?`,
  `give-thing-$path`, `$path?`, plus negative cases (plain ident
  unchanged, whitespace breaks composite, bare `$` errors and recovers,
  source positions).
- `tests/compiler/lexer_spec.lua`: the `$foo` illegal-char fixture (now
  legal) was swapped to `~foo`.

No regressions: 2771 passing, 2 pre-existing pending (unrelated formatter
limitations).

**Stage 2b ✅ + Stage 3 ✅ (2026-05-17).** Parser plumbing + decl-level
expansion pass shipped together.

- `compiler/parser.lua`:
  - `parse_fn_decl` accepts `MACRO_PARAM` and `COMPOSITE_IDENT` for the
    fn name; stores the parts list on `fn.name_parts` and a `$`-bearing
    placeholder in `fn.name` until Stage 3 substitutes it.
  - `parse_state_decl` accepts `MACRO_PARAM` and `COMPOSITE_IDENT`; the
    resulting `STATE_SCALAR.path` is a `PATH_EXPR` whose only segment is
    a `{kind="macro_param", name=...}` or `{kind="composite", parts=...}`
    placeholder table.
  - `parse_mut_path` accepts `MACRO_PARAM` and `COMPOSITE_IDENT` as a
    single-segment mutation target.
  - `parse_atom` accepts `MACRO_PARAM` and `COMPOSITE_IDENT` as
    expression atoms (becomes a `PATH_EXPR` with the same placeholder
    segment shape).
  - `can_start_arg` recognises both token kinds so they're collected as
    function-call arguments.
  - New `parse_macro_call_decl` handles top-level IDENT decls that don't
    match any decl keyword (`counter player-health` etc.); the
    `parse_decl` IDENT branch now falls through to it instead of
    erroring on `UNEXPECTED_TOKEN`.
  - `parse_decl_macro_decl` accepts `MACRO_PARAM` tokens in the header
    so the canonical form `decl-macro counter $path:` works.

- `compiler/compiler.lua`:
  - New `expand_decl_macros` pass runs first inside `expand_macros`.
    Collects every `DECL_MACRO_DECL` into a registry, walks the
    top-level decl list, and at each `MACRO_CALL_DECL` looks up the
    template, builds a `param_map`, deep-copies the body with
    substitutions applied, and splices the result into the program.
    Both template and call nodes are stripped from the AST before the
    checker sees it.
  - `substitute_decl_node` performs the deep-copy + substitution. It
    handles two placeholder shapes inside `PATH_EXPR.segments`:
    `{kind="macro_param", name=X}` (replaced by the bound param's
    segments — supports multi-segment paths via flattening) and
    `{kind="composite", parts=...}` (resolved into one concrete string).
    Resolution of `name_parts` on any node (e.g. `FN_DECL`) follows the
    same rules but always demands a single-segment substitution; passing
    a multi-segment path into a composite name slot raises
    `MACRO_DECL_EMIT`.
  - Every emitted node carries the call site's `pos` and a back-link to
    the macro body's `pos` via `expanded_from` (Stage 4 prep — the
    checker doesn't yet decorate diagnostics with that note, but
    downstream tooling can already use it).
  - `ast.E.MACRO_DECL_EMIT` and `ast.E.UNDEFINED_NAME` codes added.

- `tests/compiler/macro_decl_spec.lua`: 16 new tests covering parser
  `name_parts` capture for fn/state/mut targets, end-to-end expansion of
  a `counter $path:` exemplar (state path, composite fn name, runtime
  mutation through the expanded fn), two call sites without collision,
  error paths (missing macro, arity mismatch, illegal multi-segment
  substitution into a composite name), the legacy stmt-level macro
  system still works, and position propagation onto expanded decls.

Open (deferred to Stage 5–6):
- Cross-import wiring: rename walker for `DECL_MACRO_DECL` /
  `MACRO_CALL_DECL` and `@stdlib/` resolver (Stage 5).
- Docs + acceptance demo (Stage 6).

#### Stage 4 — Position propagation + checker hookup ✅ (2026-05-17)

Goal: when the checker errors on an expanded node, the error points at the
**call site**, with a note pointing at the macro definition.

Strategy: attach the expansion info (`{ macro_name, macro_pos }`) directly
to the pos table of every emitted node, then have the diagnostic
constructor (`ast._diag`) auto-decorate the `note` field whenever it sees
`pos.expanded_from`. This required zero changes to `checker.lua` — every
diagnostic emitter already funnels through `ast.error` / `ast.warning` /
`ast.hint`, so the decoration is uniform.

- `compiler/ast.lua`: new `ast.format_expanded_from(info)` returns
  `"expanded from macro 'NAME' at FILE:LINE"`; `_diag` calls it when
  `pos.expanded_from` is present and appends to any existing note with
  `"; "`. Empty / malformed info is tolerated gracefully.
- `compiler/compiler.lua`: `substitute_decl_node` takes a new
  `expansion_info` parameter and attaches it to every freshly-minted pos
  table; `expand_decl_macros` builds one `{ macro_name = m.name,
  macro_pos = m.pos }` table per macro call and threads it through.
- `tests/compiler/macro_decl_spec.lua`: 7 new Stage 4 tests covering:
  - checker `UNDEFINED_TYPE` on an expanded decl reports the call-site
    line (not the macro body line);
  - the emitted diag's `note` contains `expanded from macro 'NAME'` and
    the macro's file:line;
  - the `DUPLICATE_NAME` edge case (two call sites with the same path)
    reports the *second* call site and carries *both* the existing
    "previous declaration at line N" note and the expansion note,
    joined with `"; "`;
  - clean expansions never decorate unrelated diagnostics;
  - regression: legacy stmt-level `macro` errors are unaffected
    (no spurious `expanded from` notes);
  - `format_expanded_from` happy-path + missing-fields tolerance.

No regressions: full suite 2794 passing / 0 failures / 2 pre-existing
pending (unrelated formatter known-limitations).

#### Stage 5 — Cross-import wiring ✅ (2026-05-18)

`import "@stdlib/counter"` followed by `counter player-health` works;
namespaced `import ... as C` (calling `C.counter ...`) renames cleanly.

- `compiler/compiler.lua:EXPORTS_FILTERABLE`: added `DECL_MACRO_DECL`
  so `module ... exports: [name]` whitelist filtering covers
  decl-macros.
- `compiler/compiler.lua:apply_import_namespace`: rename walker now
  handles `DECL_MACRO_DECL.name` (decl-level alias prefix) and
  `MACRO_CALL_DECL.name` (call-site reference inside an imported
  module's body).
- `compiler/parser.lua:parse_macro_call_decl`: accepts the
  `Alias.macro-name` form by consuming an optional `.` + IDENT after
  the leading name token (parallels the existing fn-call handling at
  `compiler/parser.lua:1200`).
- `compiler/compiler.lua:resolve_import_path`: new `@stdlib/<name>`
  prefix branch. Resolution order is (1) `M._stdlib_dir_override`
  test hook, (2) `STORYBASE_STDLIB_DIR` env var, (3) the repo-relative
  `<repo>/stdlib/` derived from `debug.getinfo(1,"S").source`.
  The `.sb` extension is appended automatically when absent.
- New `stdlib/` directory + `stdlib/counter.sb` fixture: a small
  `counter $path` decl-macro that emits state + inc/dec/reset fns,
  used by Stage 5 acceptance tests and as a reference shape for E2/E3.
- `tests/compiler/macro_decl_spec.lua`: 7 new Stage 5 tests covering
  plain-import call + runtime execution, namespaced call (`C.counter`),
  two namespaced imports of the same file with different paths,
  `exports:` filter inclusion / exclusion of a `decl-macro`, checker
  errors stamping the call-site line/file with the `expanded from
  macro` note, and the `@stdlib/` resolver via both the override hook
  and the default `<repo>/stdlib/` fallback.

Open (Stage 6 only):
- Docs page in `docs/reference/language.md` + acceptance demo.

#### Stage 6 — Docs, acceptance, single-pass restriction ✅ (2026-05-18)

§E0 closed out. Docs landed, acceptance criteria captured as test
fixtures, and the design-spec single-pass restriction got the missing
checker enforcement it called for.

- `docs/reference/language.md`: new "`decl-macro`" subsection under
  Declarations covering the keyword, `$param` interpolation rules
  (whole-ident, composite-ident, path-segment slots, multi-segment
  flatten-vs-stringify behaviour), hygiene model (no rewriting; relies
  on existing `DUPLICATE_DECL`), single-pass restriction (nested
  `decl-macro` calls raise `MACRO_DECL_EMIT`), `expanded from` diag
  note shape, and the `@stdlib/<name>` import prefix + its
  resolution order. The `import` subsection got the `@stdlib/` example;
  `MACRO_DECL_EMIT` added to the error-code table.
- `compiler/compiler.lua:expand_decl_macros`: at template-registration
  time the body is now scanned for `MACRO_CALL_DECL` children and any
  nested decl-macro call raises `MACRO_DECL_EMIT` ("nested decl-macro
  calls are not supported"). Closes the design-spec edge case that
  was previously documented but unenforced — without the check, a
  nested call would silently survive expansion and fail downstream
  with a confusing `UNDEFINED_NAME` from the checker.
- `tests/compiler/macro_decl_spec.lua`: new "E0 Stage 6 — acceptance +
  single-pass restriction" describe block. Four tests: end-to-end
  `import "@stdlib/counter"` + state+fns emitted + fns mutate state
  at runtime; imported `decl-macro` with an `UNDEFINED_TYPE` body
  reports against the call-site file with the `expanded from macro`
  note; nested decl-macro call raises `MACRO_DECL_EMIT` with both
  macro names in the message; regression test that stmt-level `macro`
  calls inside a `decl-macro` body still expand cleanly (no
  false-positive nested-call diag).
- `code_map.md`: documented the Stage 6 single-pass check on the
  compiler entry; rolled the `tests/compiler/macro_decl_spec.lua`
  description forward to cover all six stages (62 tests); cross-linked
  `stdlib/counter.sb` to the new language-reference section.
- Acceptance criterion #3 (existing `tests/compiler/macro_spec.lua`
  still passes) verified: 14/14 unchanged.

No regressions: full suite 2806 passing / 0 failures / 2 pre-existing
pending (unrelated formatter known-limitations).

#### Edge cases (apply across stages)

- Multiple expansions of the same `decl-macro` at different call sites
  with overlapping `$path` values → caught by existing `DUPLICATE_DECL`;
  confirm in a test that the error position is the *second* call site.
- A `decl-macro` body that invokes another `decl-macro` → keep the
  single-pass restriction; emit `MACRO_CROSS_UNIT` (or a new
  `DECL_MACRO_NESTED`) and document.
- `decl-macro` emits a `verify` block → verify-cache hash already covers
  the expanded AST (`cli/verify_cache.lua:174`); add a regression test that
  editing the macro body invalidates the cache for downstream verifies.
- Composite identifiers used as a state path segment that contains `/` →
  forbid; substitution must yield a single segment, not a sub-path. Raise
  `MACRO_DECL_EMIT`.
- `decl-macro` with no `$` params at all should still work (zero-arg
  templates).

#### Effort estimate

Stages 1, 3 are ~half a day each. Stage 2 (lexer + composite identifiers)
is the wildcard at ~2–3 days. Stages 4–6 total ~2 days. Plan ~1.5 weeks
end-to-end.

#### Files touched (summary)

- `compiler/lexer.lua` — `decl-macro` keyword, `$IDENT` MACRO_PARAM token,
  composite-identifier emission.
- `compiler/ast.lua` — new `DECL_MACRO_DECL`, `MACRO_CALL_DECL` kinds; new
  constructors; new `E.MACRO_DECL_EMIT` diag code; `expanded_from` field
  convention.
- `compiler/parser.lua` — `parse_decl_macro_decl`, `parse_macro_call_decl`,
  composite-identifier handling in name-consuming sites.
- `compiler/compiler.lua` — decl-level expansion pass, position
  propagation, `@stdlib/` resolver, namespace renamer extension,
  `EXPORTS_FILTERABLE` update.
- `compiler/checker.lua` — `expanded_from` note decoration on diags.
- `tests/compiler/macro_decl_spec.lua` — new spec, per-stage growth.
- `docs/reference/language.md` — new section.
- `code_map.md` — new entries.
- `stdlib/` — new directory (E2/E3 will populate; E0 may add a fixture).

### E1. `quest` declarations (base feature, layered on §E0)

**Goal:** Every game ends up hand-rolling steps + prereqs + completion + rewards.
Surface this as first-class so the search engine can automatically check "every
declared ending is reachable" and "no quest is softlocked once started" — emergent
power, not new runtime features.

**Why base, not stdlib:** the desugar is mechanical, but the *value* is in
auto-emitted analyses (verify reachability, softlock detection) that need
compiler-internal knowledge of the quest graph. Implementing this in user-space
would require exposing too much of the verify machinery.

**Plan:** ship the desugar via the §E0 substrate where possible, but keep
`QUEST_DECL` as a first-class AST kind so codegen can emit the analysis
`verify` blocks. The "shape" of the desugar (state family, helper fns) lives
in `compiler/codegen.lua` next to actor/schedule emission.

**Design sketch (unchanged from original):**
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
blocks: "quest find-the-crown is reachable to completion" + "no step combination
leaves the player unable to reach completion."

**Files:** `compiler/ast.lua` (new `QUEST_DECL` kind), `compiler/parser.lua`
(parse entry), `compiler/codegen.lua` (desugar + verify auto-emit),
`compiler/checker.lua` (cross-validate step references), new docs page,
`tests/compiler/quest_spec.lua` + new demo.

**Depends on:** §E0 for the state-family/helper-fn emission machinery.

**Acceptance:** A demo using `quest` syntax produces the same runtime behaviour
as the hand-rolled equivalent and auto-emits a verify proving the quest is
completable; intentionally softlocking the quest causes a verify failure with
a counterexample path.

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

### E3. `inventory` and `stat` (stdlib `.sb` module)

**Goal:** `Set(ItemKind, 10)` is the de-facto inventory pattern; hand-written
`give!`, `take!`, `has?`, `count-of` are common. Same for stat blocks with
base + modifiers + clamped derived values.

**Plan:** ships as `stdlib/inventory.sb` and `stdlib/stat.sb`. No new compiler
AST kinds.

**Design sketch (author API unchanged):**
```
import "@stdlib/inventory"
import "@stdlib/stat"

inventory player/inventory:
  contents: ItemKind
  max:      10
  # macro emits: state player/inventory: Set(ItemKind, 10)
  #              fn give-player-inventory item: add! player/inventory item
  #              fn take-player-inventory item: remove! player/inventory item
  #              fn has-player-inventory? item: contains? player/inventory item
  #              fn player-inventory-size: size player/inventory
  #              fn player-inventory-empty?: empty? player/inventory

stat player/health:
  base:    Int(0, 100) = 100
  buffs:   Set(BuffKind, 4) = (set)
  derived: base + (buff-bonus buffs)
```

**Files:** new `stdlib/inventory.sb`, `stdlib/stat.sb`;
`tests/stdlib/inventory_spec.lua` + `tests/stdlib/stat_spec.lua`;
`docs/howto/inventory.md`.

**Depends on:** §E0.

**Acceptance:** Replace `Set(ItemKind, 10)` boilerplate in three demos with
`inventory` declarations; resulting tests + verify blocks pass unchanged.

### E-alt. Fast-win alternative (if §E0 is too speculative)

If the full substrate looks too risky to land cleanly, the minimum-viable
alternative is to teach macros one new trick — **emit a state family whose path
is interpolated from a parameter** — sized just for E2/E3. Implement E1 as
originally specified (base feature). Cost ~3–4 days instead of ~1–2 weeks, but
no general extensibility payoff: future "pattern every game reinvents" needs
another bespoke language change.

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

(Cross-reference to §E0–E3 — folded into them. The staged plan: §E0 ships the
decl-emitting macro substrate, §E2/E3 ride it as stdlib `.sb` modules, §E1
ships as a base feature for the verify-emission analyses.)

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

# StoryBase — Completed Work

Historical record of all completed implementation phases, demos, and spec-gap passes.
Active tasks are in [todo.md](todo.md).

---

## G2 — Stateless HTTP API mode (`serve-api`) ✅ (2026-05-16)

New CLI command `storybase serve-api game.sb [--port N] [--bind addr]
[--seed N] [--production]` that hosts a compiled game over HTTP without
keeping any per-session state. Distinct from `run --serve`, which holds a
single engine in memory and is browser-driven; `serve-api` is the API a
chat-bot, web frontend, or Discord bot connects to: each request carries
the entire save log, the server replays it, applies one choice, and
returns the new save log.

**Endpoints**

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/` | Plain-text usage page |
| `GET`  | `/schema` | JSON summary of states / scenes / entry scene |
| `POST` | `/step` | `{save_log?, choice_index?, seed?, reset?}` → `{scene, narration, choices, state, save_log, done, ended}` |
| `POST` | `/reset` | Alias for `/step` with `reset:true` |
| `OPTIONS` | `*` | CORS preflight (Access-Control-Allow-Origin: `*`) |

**Save-log format.** Same data shape used by `cli/cli_cmd.lua` (scene
stack, log entries, checkpoint stack, scheduler `next_fire` + `fired`
sets) but serialised as a plain Lua table so the JSON codec from
`runtime/debug.lua` can ship it to and from the client. Two requests
with the same save log + choice index produce the same next state —
the determinism is inherited from the transaction log + seeded RNG
pipeline, no fresh randomness is introduced server-side per request.

**Files.**

- `cli/serve_api_cmd.lua` (NEW) — entry, save/restore-over-table,
  step kernel, self-contained HTTP server (non-blocking accept loop
  with `start` / `poll` / `stop` lifecycle for tests; blocking `serve`
  wrapper for production).
- `cli/main.lua` — new `serve-api` dispatcher entry + help text.
- `tests/cli/serve_api_spec.lua` (NEW, 22 tests) — kernel tests
  (fresh start, choice advance, JSON round-trip determinism, invalid
  choice, malformed JSON, reset) + HTTP end-to-end tests (lifecycle,
  GET / and /schema, OPTIONS, multi-step play-through, /reset). Uses
  the same non-blocking `start` / `poll` pattern as
  `runtime/debug.lua`'s HTTP tests, so the server runs in-process.
- `docs/reference/cli.md` — full reference entry with endpoint
  schema and deployment notes (auth / TLS out of scope; deploy
  behind a reverse proxy).
- `code_map.md` — new entries for `cli/serve_api_cmd.lua` and the
  new test file.

**Acceptance.** A client can POST a sequence of `/step` requests to
complete `demo01_wanderer.sb` end to end without any per-session
state on the server (covered by the play-through HTTP test).
Save-log replay is deterministic across JSON round-trips (kernel
test). Invalid input (out-of-range choice, malformed JSON,
non-object body) returns HTTP 400 with `{error: ...}`.

## C3 — Temporal-logic verify ✅ (2026-05-15)

Added a CTL subset for verify blocks alongside the existing `verify-always`
(AG). Three new clause kinds, each backed by a bounded fixpoint over the
state graph produced by `runtime/search.lua:expand_graph`:

| Clause | CTL | Semantics |
|--------|-----|-----------|
| `verify-eventually <p>` | EF p | `p` is reachable on some path |
| `verify-always-eventually <p>` | AF p | every path eventually reaches `p` |
| `verify-until <p> until <q>` | p AU q | every path: `p` holds until `q` |

Each new check returns the standard result shape (`pass`, `fail_msg`,
`counterexample_path`, `states_checked`, `truncated`). For AF and AU,
counterexamples are produced by a greedy walk through the non-AU/non-AF set,
terminating at a terminal state, depth boundary, or cycle — by the fixpoint
definition such a walk always exists when the property fails.

**Bounded semantics.** Boundary nodes (depth == `max_depth`) participate
only via the base predicate; their unexplored successors are treated
conservatively. Increasing depth can only flip failures into passes, never
the other way around.

**Files.**
- `runtime/search.lua`: `verify_eventually`, `verify_always_eventually`,
  `verify_until`, plus helpers (`build_out_adjacency`, `compute_ef_set`,
  `compute_af_set`, `compute_au_set`, `walk_outside_set`, `node_id_map`,
  `find_path_in_graph`).
- `runtime/verify.lua`: dispatches the new clause kinds through `run_all`.
- `compiler/parser.lua`: new branches in `parse_verify_decl`.
- `cli/format_cmd.lua`: formatter emits the new clauses.
- `cli/main.lua`: `verify` help text updated.
- `docs/reference/language.md`, `docs/reference/cli.md`: documented.
- `demos/demo22_quest_temporal.sb`: forced-completion quest where all four
  temporal operators (AG / EF / AF / AU) pass at default depth.
- Tests in `tests/runtime/search_spec.lua` (+9) and
  `tests/runtime/verify_spec.lua` (+5).

## C4 — Cached / incremental verify ✅ (2026-05-15)

`storybase verify` now persists per-block verdicts in
`.storybase-cache/verify.json`. On re-run, blocks whose AST-level hash is
unchanged are reported as `[cached]` and the BFS is skipped.

**Hash inputs (per verify block):**
1. The verify block's own clauses AST (label + clause kinds + conditions).
2. The schema slice (`types`, `states`, `relations`, `engine_config`,
   `time_model`) of the compiled game table.
3. The AST of every fn transitively reachable from the verify body.
4. For BFS-style verifies (always / eventually / always-eventually / until /
   from-any-state / requires): scenes, actors, schedules, bounded
   declarations, and their transitively-reached fns.

Source positions (`pos`, `file`, `line`, `col`) are stripped before
serialisation so formatting changes do not invalidate. Hash is FNV-1a
64-bit; cache is JSON via `runtime.debug.encode_json` for portability.

**Granularity proof.** A two-block file with two fns (one per verify):
editing fn A invalidates only the verify that depends on A; the verify
depending on fn B stays cached. Validated by
`tests/cli/verify_cache_spec.lua`.

**CLI flags (cli/verify_cmd.lua):**
- `--no-cache`       — skip cache lookups (always re-run).
- `--clear-cache`    — delete cache before running.
- `--cache-dir DIR`  — use a non-default cache location.

**Files.**
- `cli/verify_cache.lua` (new): hash + load/save + dependency analysis.
- `cli/verify_cmd.lua`: cache lookup + flag parsing.
- `docs/reference/cli.md`: `--no-cache` / `--clear-cache` / `--cache-dir`
  documented.
- Tests in `tests/cli/verify_cache_spec.lua` (+15): hash determinism,
  cosmetic-edit insensitivity, dep closure granularity, cache I/O,
  end-to-end re-run behaviour.

---

## A11 — `--ui <name>` driver-name whitelist ✅ (2026-05-14)

**Bug.** `cli/main.lua`'s `cmd_run` accepted any string for `--ui <name>` and
fed it straight into `require("cli.drivers." .. ui_name)`. A crafted value like
`--ui ../../foo` would attempt to load arbitrary Lua modules from `package.path`
rather than the legitimate `cli/drivers/` directory. Low blast-radius (the
attacker needs CLI access already), but a textbook trust-the-input footgun and
exactly the kind of thing that grows teeth once `--serve` deployment scenarios
are added.

**Fix.** Added an explicit `ALLOWED_UI_DRIVERS = { plain = true, ansi = true }`
whitelist in `cli/main.lua:316`. Driver names outside the whitelist are
rejected with `error: unknown UI driver '<name>' (available: plain, ansi)` and
exit code 1 *before* any `require` call runs. The post-`require` error branch
was kept (now reporting `failed to load UI driver '<name>': <err>`) for
unexpected runtime breakage inside the driver modules themselves. New drivers
must be added to the whitelist set when they land.

**Tests.** Five new cases in `tests/cli/drivers_spec.lua` under a new
`describe("--ui flag: whitelist", ...)` block: path-traversal name
(`../../foo`), unrelated stdlib name (`os`), dotted name (`foo.bar`), and
the two valid drivers (`plain`, `ansi`) — each invoked through `cli.main`
with `--auto --steps 0` against a minimal temp game file.

**Files touched.** `cli/main.lua`, `tests/cli/drivers_spec.lua`.

---

## A16 — Test-coverage backlog ✅ (2026-05-14)

**2512 successes / 0 failures (non-HTTP) / 2 pending.** +111 new tests across
six new spec files and three extensions. Two bugs uncovered during test writing
were fixed alongside.

### Bugs fixed during test creation

1. **`compiler/types.lua:53` — operator-precedence bug in the `list` case.**
   `(ty.elem_size or 0 + 1) ^ (ty.max or 0)` was parsed by Lua as
   `(ty.elem_size or 1) ^ max` because `or` binds looser than `+`. The
   intent was `((elem_size or 0) + 1) ^ max` so each list slot can be absent
   or one of |T| values. With `elem_size=3` the buggy form gave `3^max`
   instead of `4^max`. The function had no callers (the production state-space
   sizer lives in `codegen.lua`), so this was a latent bug. Fixed to
   `((ty.elem_size or 0) + 1) ^ (ty.max or 0)`. Detected by `tests/compiler/types_spec.lua`.

2. **`cli/migrate_cmd.lua:92,94` — `has_errors` was an implicit global.**
   The variable was assigned without `local`, so it leaked across `M.run`
   calls in the same process. A failed migration would set the global to
   `true`, making the *next* run incorrectly report "Migration failed" even
   without any actual errors. Made `local has_errors = false` before the
   accumulator loop. Regression test in `tests/cli/migrate_cmd_spec.lua`.

### New spec files

- **`tests/compiler/types_spec.lua` (30 tests).** Covers `is_discrete` /
  `is_superficial` and `state_space_size` across all kinds: nil, bool, int
  (inclusive range, single point, spanning zero, inverted bounds), enum
  (with empty / missing values), symbol / symbol_of (bounded + unbounded),
  option (None adds one to inner), set (combinatorial sum with max clamped
  to |T|), list (the fixed `(|T|+1)^max` formula), record (product_size),
  variant (sum_size), missing-field defaults.

- **`tests/compiler/compiler_spec.lua` (16 tests).** Pipeline orchestrator
  contract: happy-path compile, short-circuit on lex/parse/check errors,
  `parse_and_check` success/parse-failure/check-failure, `compile_file` /
  `parse_and_check_file` happy path and FILE_NOT_FOUND, `opts.production`
  pass-through (verify blocks stripped), import resolver error paths
  (missing target file, cycle detection, absolute-path resolution).
  Macro expansion and basic import are already covered in
  `import_spec.lua` and `macro_spec.lua`.

- **`tests/cli/check_cmd_spec.lua` (6 tests).** Drives `check_cmd.M.run`
  with captured stdout/stderr. Exits 1 on: no input file, missing file,
  syntax error, semantic error (invalid enum default). Exits 0 with
  `check passed` and Types/State-paths summary on clean source. Multi-error
  summary line.

- **`tests/cli/repl_cmd_spec.lua` (16 tests).** Drives the interactive REPL
  with a fake `io.stdin` (queue of canned lines) and captured stdout/stderr,
  so the loop can be unit-tested without a TTY. Covers: usage error
  (no file), missing file, banner + EOF, `:help`, `:quit` / `:q`, `:scene`,
  `:state`, `:choices`, unknown command, fn invocation, save/load
  round-trip with mutation, `:tick`, empty lines (no errors), bare
  expression eval.

- **`tests/cli/migrate_cmd_spec.lua` (11 tests).** Usage errors, compilation
  failure paths (bad game / missing game), no-migrations short-circuit,
  save-already-at-game-version short-circuit, successful migration with
  generated output file, `--out` custom destination, corrupt save (lua
  parse error), missing save file, and a regression test guarding the
  `has_errors`-global bug above (a successful run after a failed run
  still reports success).

- **`tests/cli/verify_cmd_spec.lua` (7 tests).** No input file, missing
  file, compilation failure, no verify blocks (clean exit), passing
  verify with PASS line, failing verify with FAIL + label, summary
  counts when one passes and one fails.

### Extensions to existing specs

- **`tests/runtime/scheduler_spec.lua` (+4 tests).** Multi-axis triggers
  finally covered: `at: [day: +2, hour: +3]` requires *both* axes to
  reach their targets (not either-or), multi-axis at-only schedule
  deregisters after firing, multi-axis `every:` advances thresholds for
  *all* axes after each fire. Plus cancel-during-tick: a sibling cancel
  is honoured on the subsequent tick, `cancel_schedule` log entry is
  emitted, cancelling an unknown schedule is a silent no-op.
  Added `force_set_time` helper because the existing helper's axis-table
  representation made `set_time` silently no-op (the schema's
  `axes = {{name="tick",max=...}}` form keys `_time` by table, not by
  string).

- **`tests/runtime/migrate_spec.lua` (+4 tests).** Documents that
  `migrate()` is *not* atomic: a missing 2→3 block in a 1→4 chain leaves
  the 1→2 mutations applied to the cache. Also documents that the chain
  stops at the first missing block (does not skip forward to a later
  block that does exist). And: the CLI's "save without `schema_version`
  defaults to 1" convention is exercised both for the v1→v2 happy path
  and for the same-version no-op path.

- **`tests/lib/storybase_spec.lua` (+15 tests).** Save/load error paths:
  unwritable path (`/proc/...`, tolerant if running as root), missing
  parent directory, missing file on load, file that isn't valid Lua,
  file that returns nil, full round-trip. `register_bounded` handler
  error / wrong-type / nil returns / unregistered — engine must not
  crash. `on("mutation")` event delivery: set! and inc! both fire
  events with `{path, old, new, fn}` payload, fn name is preserved,
  multiple listeners all fire, a raising listener does not block
  later ones.

### Files touched

Code (bug fixes):

- `compiler/types.lua` (list-case precedence fix, 1 line).
- `cli/migrate_cmd.lua` (`has_errors` made local, 1 line).

New tests:

- `tests/compiler/types_spec.lua` — 30 tests.
- `tests/compiler/compiler_spec.lua` — 16 tests.
- `tests/cli/check_cmd_spec.lua` — 6 tests.
- `tests/cli/repl_cmd_spec.lua` — 16 tests.
- `tests/cli/migrate_cmd_spec.lua` — 11 tests.
- `tests/cli/verify_cmd_spec.lua` — 7 tests.

Extended tests:

- `tests/runtime/scheduler_spec.lua` (+4).
- `tests/runtime/migrate_spec.lua` (+4).
- `tests/lib/storybase_spec.lua` (+15).

Backlog (`todo.md`) updated to mark §A16 complete. Only §A10/§A11
(security-adjacent) plus the deferred §A1/§A2 polish items remain in
the audit backlog.

---

## A4 + A9 + A12 + A13 + A14 + A15 — Checker family/reversible, search hash, repo hygiene ✅ (2026-05-14)

**2401 successes / 0 failures (non-HTTP) / 2 pending.** 15 new tests added.

### A4 — UNDEFINED_FAMILY on spawn!/despawn! into undeclared family

**Root cause:** `compiler/checker.lua`'s pass1 collected `state foo/{...}` families
into `symtab.families` but no later pass validated that `SPAWN_MUT.family` or
`DESPAWN_MUT.family` referenced a known family. `spawn! ghosts ...` with no matching
`state ghosts/{...}` declaration compiled clean; runtime then materialised an
unmodelled family with no schema and no type guarantees.

**Fix:** new `pass_check_undefined_families` registered after the other AV passes.
It walks every fn / scene / schedule / hook body (including scene choice bodies and
nested conditional bodies via a local recursive walker), and for each `SPAWN_MUT`
or `DESPAWN_MUT` node verifies `node.family ∈ symtab.families`. Emits
`ast.E.UNDEFINED_FAMILY` (a code that was already defined but unused) with a hint
showing the declaration template:
`note: declare it with: state ghosts/{key}: TypeName`.

**Files touched:** `compiler/checker.lua` (new pass + registration).

**Tests added:** `tests/compiler/checker_spec.lua` — 5 tests: bare spawn into
undeclared family, despawn into undeclared family, accepts well-declared family,
detects spawn buried inside `when:` body, detects spawn inside scene choice body.

### A9 — Reversibility check follows function calls transitively

**Root cause:** `pass3c_check_reversible` walked the body of a `[reversible]`-
tagged fn looking for direct irreversible mutations (`clear!`, `send!`,
`time-inc!`, etc.) but did not follow `FN_CALL` nodes into the callee's body.
A reversible fn calling a helper that did `clear!` passed the check silently,
defeating the whole point of the annotation.

**Fix:** rewrote the pass to do a DFS over the call graph with cycle detection
and memoisation:
- For each user fn, precompute `direct_witness[fn]` (first irreversible
  mutation in its own body) and `calls_out[fn]` (list of user fns it directly
  calls).
- `trace(fn_name, on_stack)` returns a chain `[{caller, calls?, witness?}, ...]`
  when an irreversible mutation is reachable, or `nil` if the fn is clean.
  Cycles are handled by an `on_stack` set; cyclic visits return `nil` locally
  but do not memoise so a different DFS root still computes the right answer.
- Error message expands when the chain is longer than 1:
  `fn 'A' is tagged [reversible] but transitively reaches 'clear!' via 'A' → 'B', 'B' → 'C'`.
  The position is the irreversible mutation itself, not the reversible fn decl.

**Files touched:** `compiler/checker.lua` (new `collect_fn_calls_local` helper
plus rewritten `pass3c_check_reversible`).

**Tests added:** `tests/compiler/checker_spec.lua` — 5 tests: one-hop transitive
(asserts the "→" arrow appears in the message), two-hop chain (asserts both hops
appear), clean helper still passes, recursion through a reversible-clean cycle
doesn't crash or false-positive, error attributed to the irreversible call site
(not the caller).

### A12 — BFS state hash deterministic for Float values

**Root cause:** `runtime/search.lua`'s `hash_state` used `tostring(v)` to render
each cache value. Lua's default `tostring` for floats uses `%.14g`-style
precision, which is platform/locale-influenced and only gives 14 significant
digits. Two semantically-equal states could hash differently across runs. A
second subtlety: `tostring(1)` is `"1"` but `tostring(1.0)` is `"1.0"`, so a
path stored once as int and once as float counted as two distinct BFS nodes.

**Fix:** new local `fmt_hash_val(v)` helper that formats `type(v) == "number"`
with `%.17g` (round-trip-safe for IEEE 754 doubles, and emits integer-valued
floats as `"1"` — same string as integers). Other types fall through to
`tostring`. Routed all four `tostring(v)` call sites inside `hash_state` (scalar,
array items, UMap keys, UMap values) through the helper. Exposed `hash_state`
as `M._hash_state` for tests.

**Files touched:** `runtime/search.lua` (helper + 4 call sites + test export).

**Tests added:** `tests/runtime/search_spec.lua` — 5 tests: int and
integer-valued float hash equally, identical cache hashes idempotently, distinct
floats hash differently, near-equal doubles (via `math.nextafter`) still hash
differently, UMap hashing is order-independent.

### A13 — Cleaned up 47 stray `*.lua.tmp.PID.MS` files

**Root cause:** unknown tool (likely an editor's atomic-write staging) created
files named `<basename>.<ext>.tmp.<PID>.<MILLIS>` next to canonical files. 31 of
them were tracked in git; the rest showed as untracked. The existing
`.gitignore` pattern `*.tmp` matched only files literally ending in `.tmp`, not
`.tmp.PID.MS`.

**Fix:**
- Added `*.tmp.*` to `.gitignore` (catches all variants going forward).
- `git ls-files | grep -E "\.tmp\.[0-9]+\.[0-9]+$" | xargs git rm --cached`
  unstaged the 31 tracked tmp files (working-tree copies preserved at first).
- `find . -regex '\./.*\.tmp\.[0-9]+\.[0-9]+$' -type f` then deleted all 47
  working copies.
- Spot-checked diffs against canonical files first to confirm none held unique
  in-flight work — they were stale older-snapshot dumps.

**Files touched:** `.gitignore`, 47 deleted `*.tmp.*` files.

### A14 — Deleted dead `runtime/counterfactual.lua` stub

**Root cause:** `runtime/counterfactual.lua` had been reduced to a 6-line
`return {}` placeholder ("counterfactual is implemented inline in eval.lua").
Nothing in the codebase required it, but it was still listed in
`cli/bundle_cmd.lua`'s `BUNDLE_MODULES`. With the file deleted, the bundle
command silently emitted broken `package.preload["runtime.counterfactual"]`
entries until its own tests failed.

**Fix:**
- Deleted `runtime/counterfactual.lua`.
- Removed `"runtime.counterfactual"` from `cli/bundle_cmd.lua` `BUNDLE_MODULES`.
- Removed the now-empty section from `code_map.md`.

**Files touched:** `runtime/counterfactual.lua` (deleted), `cli/bundle_cmd.lua`,
`code_map.md`.

### A15 — Refreshed `code_map.md` line-count annotations

Updated 32 stale line-count annotations in `code_map.md`. The biggest drifts
were `compiler/checker.lua` (540 → 2922), `compiler/parser.lua` (2564 → 3479),
`runtime/eval.lua` (~1420 → 2696), and `cli/format_cmd.lua` (~850 → 1427).

**Files touched:** `code_map.md`.

---

## A3 + A7 + A8 — Checker duplicate-decl, verify error-surface, JSON Infinity ✅ (2026-05-14)

**2386 successes / 0 failures (non-HTTP) / 2 pending.** 10 new tests added.

### A3 — Duplicate FN / BOUNDED / MACRO / ACTOR declarations

**Root cause:** `pass1_collect` in `compiler/checker.lua` registered each `FN_DECL`,
`BOUNDED_DECL`, `MACRO_DECL`, and `ACTOR_DECL` into `symtab` with a bare assignment
— no `DUPLICATE_NAME` check, unlike `SCENE_DECL`, `TYPE_*`, `STATE_*`, and
`RELATION_DECL`. Two `fn foo:` declarations in the same file silently shadowed each
other; codegen picked whichever ran last.

**Fix:** wrapped each of the four bare assignments at lines 178-188 with the same
"look up, emit DUPLICATE_NAME with previous-line note, else assign" pattern that
`SCENE_DECL` already uses. The existing `ast.E.DUPLICATE_NAME` code suffices.

**Files touched:** `compiler/checker.lua` (4 declaration kinds).

**Tests added:** `tests/compiler/checker_spec.lua` — 3 tests: duplicate fns error
with `DUPLICATE_NAME` and a previous-line note, duplicate actors error similarly
even with distinct state paths, distinct fn names still compile cleanly.

### A7 — `verify` surfaces evaluation errors instead of swallowing them

**Root cause:** `runtime/verify.lua` used `pcall(eval.eval_expr, ...)` in three
places (`requires:` at line 381, `when:` at line 447, `from-any-state` condition at
line 469) and treated `not ok or not result` identically. A typo or
referenced-but-renamed path in a `requires:` clause caused `ok=false`, which then
hit the same code path as a legitimate `result=false` — the assertion was silently
skipped, the verify reported as `skipped: requires not met in any reachable state`.
Authors lost the safety net without noticing.

**Fix:** at each site, split the error path from the false path:
- `not ok` → return `{pass=false, fail_msg="<clause> clause errored at BFS state N: <err>", counterexample = snap, ...}`.
- `not result` → keep existing behaviour (skip for `requires`/`when`; fail with
  "condition failed" for `from-any-state`).

The `from-any-state` failure message now also distinguishes "errored" from "failed".

**Files touched:** `runtime/verify.lua` (three pcall sites).

**Tests added:** `tests/runtime/verify_spec.lua` — 3 tests using a monkey-patched
`eval.eval_expr` that raises on the first call with a chosen `fn_name`
(`verify-requires`, `verify-when`, `verify-from-any`). Each asserts the result is
`pass=false` with a `fail_msg` containing the expected "X clause errored" / "condition
errored" prefix, and that `skipped` is *not* set.

### A8 — `runtime/debug.lua` emits invalid JSON for ±Infinity

**Root cause:** `M.encode_json` at `runtime/debug.lua:1414` caught NaN (`v ~= v`)
and returned `"null"`, but `math.huge` and `-math.huge` fell through to
`tostring(v)` which yields `"inf"` / `"-inf"` — not valid JSON. Browser SSE
clients silently dropped the affected events.

**Fix:** widened the special-value guard to `v ~= v or v == math.huge or v == -math.huge`;
all three now serialise as JSON `null`.

**Files touched:** `runtime/debug.lua` (one branch).

**Tests added:** `tests/runtime/debug_spec.lua` — 4 tests: NaN, +Infinity, and
-Infinity each encode as `"null"` at top level; a nested `{rate = math.huge}` object
produces `"rate":null` and contains no bare `inf` substring anywhere in the output.

---

## A5 + A6 — Per-instance PCG RNG and shared number formatter ✅ (2026-05-14)

**2376 successes / 0 failures (non-HTTP) / 2 pending.** 21 new tests added.

### A5 — Replace global Lua RNG with per-instance PCG32

**Root cause:** `runtime/random.lua` called `math.randomseed(seed or os.time())` and
all draws went through `math.random(...)`. This mutates Lua's *global* RNG state, so
two engines coexisting in one process clobbered each other's stream. The `os.time()`
fallback also gave two `M.new(nil)` calls in the same second identical seeds.

**Fix:**
- Rewrote `runtime/random.lua` as a per-instance PCG32 (XSH-RR variant, O'Neill 2014)
  with `_state` and `_inc` fields on each rng object. Multiplications wrap via Lua
  5.4's 64-bit integer arithmetic.
- New API: `rng:uniform()`, `rng:save_state()`, `rng:load_state()`, `rng:set_provider(fn)`
  (for test injection / future LLM-style determinism stubs), `rng:seed(s)`. Existing
  methods (`bool`, `int`, `enum`, `choice`, `weighted`) kept their signatures.
- Default seed mixes `os.time()` with `os.clock()` to avoid the same-second collision.

**Removed all global RNG use from production code:**
- `runtime/eval.lua` — six `math.random` fallbacks in the `random-*` builtins removed.
  `M.new_ctx` now allocates a fresh per-ctx PCG so eval can always rely on `ctx.rng`;
  engine-driven contexts overwrite this with the engine's logged RNG.
- `runtime/search.lua` — two `math.random(lo, hi)` fallbacks in the BFS injection
  paths replaced with a module-level fixed-seed PCG (only fires when the injection
  queue is exhausted, a rare defensive path; reproducible per process).
- `cli/cli_cmd.lua` — `math.randomseed(opts.seed)` was a no-op (seed never reached
  the engine); now passes `seed = opts.seed` through to `engine_mod.new`.
- `cli/repl_cmd.lua` — dead `math.randomseed(seed)` removed (REPL routes through
  `lib/storybase.lua` which doesn't yet plumb seed; tracked separately).

**Verification:** `grep -rn "math\.random" compiler/ runtime/ cli/ lib/` returns
matches only inside comments. Test helpers under `tests/fuzz/` and
`tests/cli/format_spec.lua` still use `math.random` for fixture generation —
acceptable since fixtures don't need replay determinism and tests run sequentially.

**Files touched:** `runtime/random.lua` (rewrite), `runtime/eval.lua` (fallbacks
removed, new_ctx now allocates rng), `runtime/search.lua` (fallback PCG),
`cli/cli_cmd.lua` (seed plumbing), `cli/repl_cmd.lua` (dead code removed).

**Tests added:** `tests/runtime/random_spec.lua` — 14 tests covering:
no global state mutation, identical streams from identical seeds, independence under
interleaved draws, save_state / load_state round-trip, uniform distribution, range
coverage, provider interception, log integration, seed() reset.

### A6 — Shared number formatter (replaces `%.14g` everywhere)

**Root cause:** `runtime/log.lua` and `cli/cli_cmd.lua` both used `string.format("%.14g", v)`
for serialising numbers to Lua source. Two issues: (1) `%.14g` loses precision —
IEEE 754 doubles need `%.17g` for exact round-trip; (2) it emits the literal strings
`"inf"` / `"nan"` for special values, both of which fail to `load()`.
`cli/bundle_cmd.lua` already had a correct local implementation.

**Fix:** added `M.fmt_number(v)` to `runtime/log.lua` handling:
- `NaN` → `"(0/0)"`
- `+Infinity` → `"math.huge"`
- `-Infinity` → `"-math.huge"`
- Integer ≤ 2^53 → `"%d"` (no decimal, no scientific notation)
- Other floats → `"%.17g"` (round-trip-safe)

**Replaced all six call sites:** four in `runtime/log.lua` (`ser_val` plus three
inline number-formatting branches in the path/state serialiser) and three in
`cli/cli_cmd.lua` (`ser_cache`, `ser_grids`).

**Verification:** `grep -rn "%.14g" compiler/ runtime/ cli/ lib/` returns only the
comment in `runtime/log.lua` that documents the fix.

**Files touched:** `runtime/log.lua` (new helper + 4 call sites),
`cli/cli_cmd.lua` (3 call sites + require).

**Tests added:** `tests/runtime/fmt_number_spec.lua` — 7 tests covering integers,
large integers, float round-trip precision, NaN, ±Infinity, and the 2^53 integer
boundary.

---

## UI Driver Layer ✅ (2026-05-02)

**2025 tests passing, 0 failing.**

Decoupled all terminal rendering from the game engine via a pluggable driver interface.

### Changes made

- **`runtime/eval.lua`** — Added `kind="say"` to every say object emitted by SAY_STMT.
- **`runtime/engine.lua`** — All narration items are now structured tables:
  - `narration_line` / `cond_narration` → `{kind="narration", text=...}`
  - say items were already tables; now carry `kind="say"` too.
  - Added `eng._driver = opts.driver`; `step()` delegates render/prompt to driver when set, else falls back to built-in plain rendering via `eng:_render_plain()`.
- **`cli/drivers/plain.lua`** (new) — Default driver. Renders `"Speaker: text"` / bare text; numbered choice prompt; reads from stdin.
- **`cli/drivers/ansi.lua`** (new) — ANSI-color driver (`--ui ansi`). Speaker labels colored with ANSI true-color from their `color:` hex field; bold choice indices; dim prompt.
- **`cli/main.lua`** — Added `--ui <name>` flag to `storybase run`; loads `cli/drivers/<name>.lua` and passes it as `opts.driver`.
- **`cli/cli_cmd.lua`** — Updated narration filter to handle structured `{kind, text}` items.
- **`cli/repl_cmd.lua`** — Updated `:choose` narration display for structured items.
- **`lib/storybase.lua`** — Updated `render()` doc comment.
- **Tests updated** — Added `narr_text()` helper to engine_spec, integration tests, cli_cmd_spec; fixed `type(n)=="string"` guards; updated "mixed narration" eval_spec test to expect `kind` fields.
- **`tests/cli/drivers_spec.lua`** (new) — 18 tests covering plain/ansi render, prompt, notify, color escapes, and driver injection via engine opts.

---

## Bug-fix Pass: Bug #1 + Bug #2 (partial) ✅ (2026-05-02)

**~1972 tests passing. ~19 failures: 1 remaining format bug (demo19), 18 pre-existing flaky debug_http port-conflict failures (pass when run in isolation).**

### Bug #1 — `cancel-schedule!` inside a schedule body silently ignored — FIXED

**Root cause:** `sched:tick()` in `runtime/scheduler.lua` created an eval context with
`eval.new_ctx()` but never set `ctx.scheduler = self`, so the `CANCEL_SCHEDULE_MUT` handler
in `eval.lua` silently no-oped.

**Fix:**
- `runtime/scheduler.lua` `sched:tick()`: set `ctx.scheduler`, `ctx.debug`, `ctx.actors`,
  `ctx.rng` after `eval.new_ctx()`.
- `runtime/engine.lua` `eng:init()`: set `self._scheduler._game`, `_actors`, `_rng` so
  schedule bodies can call `engine/emit`, `send!`, `random-int`, etc.

**Regression test:** `tests/runtime/scheduler_spec.lua` — "cancel-schedule! in body cancels
another schedule; ctx.scheduler is wired". Verifies that an `at:` schedule firing `cancel-schedule!`
on a co-firing `every:` schedule actually removes it from `_static` during the same tick.

### Bug #2 — `format --write` silently corrupts source files — MOSTLY FIXED

**Root cause:** `cli/format_cmd.lua` had 8 missing node-kind handlers (emitting
`-- (stmt:X)` / `-- (decl:X)` placeholders) plus ~20 additional pre-existing field-name
mismatches throughout `fmt_expr`, `fmt_type`, and `fmt_decl`.

**All 8 placeholder gaps fixed:**
- `SPEAKER_DECL` in `fmt_decl` — now emits `speaker name:\n  display: "..."\n  color: "..."`
- `SAY_STMT` in `fmt_stmt` — context-aware: NAMED_ARG form for symbol speakers, colon form
  in scene bodies, space-separated quoted-string form in fn bodies
- `RETURN_STMT` in `fmt_stmt` — `return expr`; MATCH_EXPR handled as multi-line block
- `MAP_SET_MUT` in `fmt_stmt` — `map-set! path key value`
- `MAP_DELETE_MUT` in `fmt_stmt` — `map-delete! path key`
- `CHECKPOINT_MUT` in `fmt_stmt` — `engine/checkpoint!` (with optional fn-name)
- `EMIT_MUT` in `fmt_stmt` — `engine/emit event [args]`
- `NARRATION_LINE` in `fmt_stmt` — plain text rendering

**Additional pre-existing fmt_expr / fmt_decl bugs also fixed:**
- `symbol_lit` uses `node.name` not `node.value`
- `match_expr` uses `node.expr` not `node.subject`
- `type_int` uses `min`/`max` not `lo`/`hi`
- `state_family` has `family`/`var` not a `path` expression
- `engine_config` has `keys` list not `entries` table
- `type_record`, `verify_decl`, `watch_when_decl` wrong field names
- `fn_decl` params are plain strings, not `{name, type_expr}`; params go on header line
- `fn_decl` pre/post: unwrap `EXPR_STMT` wrappers; support multi-condition block form
- Forward declaration of `fmt_expr` was after `render_text_segments`, breaking inline `{expr}`
- `EMPTY_MAP` was `{=>}` (caused parser infinite loop); now `{}`
- `EMPTY_LIST` was `(list)` (not handled by `parse_default_value`); now `[]`
- `{=>}` was `"EMPTY_MAP"` literal; actually parser uses `map_lit({})` for `{}`
- `set_lit`, `list_lit`, `map_lit` used wrong field names (`items`/`pairs` vs `elements`/`entries`)
- `SPAWN_MUT`/`DESPAWN_MUT` family is a plain string, not an expression node
- `TYPE_OPTION`, `TYPE_SET`, `TYPE_LIST`, `TYPE_ULIST`, `TYPE_UMAP` use parenthesised
  syntax (`Option(T)`, `Set(T,N)`, etc.) not space-separated
- `TYPE_ENUM` values should not have `'` prefix
- `INTERP_PATH` segments: `{interp="key"}` tables, not expression nodes
- `PATH_AT_BEFORE` was `@@before` (double `@`); now `@before`
- `LAMBDA_EXPR` params format: `fn(k):` not `fn k:`
- `MATCH_ARM` body: single-expression arms emit inline `pattern: expr`
- `IN_STATE_EXPR` handler added: `(in-state state) expr`
- `FOR_STMT` wraps fn-call iterators in `()` to prevent NAMED_ARG colon ambiguity
- `VERIFY_DECL` uses `label` (string) not `name`; clause discriminator is `clause_kind`
- Verify clause handlers: `from_any_state`, `always`, `after`, `requires`, `when`
- `WATCH_WHEN_DECL` uses `condition` not `cond`

**New format regression tests added** (`tests/cli/cli_integration_spec.lua`):
- demo13 (speaker/say/return): no placeholders, idempotent ✅
- demo17 (map-set!/map-delete!): no placeholders, idempotent ✅
- demo08 (engine/emit, engine/checkpoint!): no placeholders, idempotent ✅
- demo19 (engine/emit, watch): no placeholders, idempotent ❌ (watch-when trailing `""` bug)

**Remaining issue:** `watch-when fn-call "label"` — `parse_expr` greedily absorbs the STRING
label as a fn argument when the condition is a bare fn-call. Fix: wrap condition in `()`
in the formatter. See todo.md for details.

---

## Code Review Round 2 — All Bugs, Design Flaws, and False Impls ✅ (2026-04-30)

**~1973 unit tests passing (excluding flaky debug_http network tests). 17 new regression tests added.**

### Bugs Fixed

- **Bug #1 — `deep_copy_cache` / `undo` use `ipairs`** — Changed to `pairs` in both copy loops so UMap (hash-keyed table) values survive `push_checkpoint` and `undo`. Files: `runtime/state.lua:197,235`. Regression test in `tests/runtime/state_spec.lua`.
- **Bug #2 — `relate!/unrelate!` bypass log** — Rewrote to write through state store at `__rel/<name>/<src>` cache keys. `eval.lua` has a local `effective_rel()` helper that merges static+dynamic edges; all relation query builtins and `query.lua:M.find` use it. Edges are now logged, auditable, undoable, counterfactual-safe, and BFS-visible. Files: `runtime/eval.lua`, `runtime/query.lua`. Regression tests in `tests/runtime/eval_spec.lua`.
- **Bug #3 — `grid-set!` not logged** — Now writes to both `g.cells` (for immediate tilegrid access) AND `ctx.state._cache["__grid/<name>/<x>,<y>"]` (for persistence and BFS). `grid-get` checks cache override first. `engine:apply_grid_cache()` added; called after load. BFS `restore_engine` reinits cells from defaults then applies `__grid/*` overrides. Files: `runtime/eval.lua`, `runtime/engine.lua`, `runtime/search.lua`. Regression tests in `tests/compiler/defgrid_spec.lua`.
- **Bug #4 — `PATH_EXPR` single-segment skips `nil_vars`** — Added `nil_vars` check before state-store fallthrough so `let x = nil` reads correctly. File: `runtime/eval.lua:~218`. Regression test in `tests/runtime/eval_spec.lua`.
- **Bug #5 — `set_time` dead else-branch** — Else-branch changed to silent no-op for undeclared axes. File: `runtime/state.lua:~317`. Regression test in `tests/runtime/state_spec.lua`.
- **Bug #6 — `map-values` non-deterministic order** — Now sorts by key before collecting values, matching `map-keys` output order index-for-index. File: `runtime/eval.lua`. Regression test in `tests/runtime/eval_spec.lua`.
- **Bug #7 — `path_list` non-deterministic order** — Added `table.sort(keys)` before returning. File: `runtime/state.lua`. Regression test in `tests/runtime/state_spec.lua`.

### False Implementations Removed

- **False Impl #1 — `counterfactual.lua` dead code** — Replaced stub with one-line redirect comment.
- **False Impl #2 — `sched:schedule()` unreachable stub** — Replaced with `error()`.
- **False Impl #3 — Stale "not implemented" comments** — Removed from `runtime/log.lua` and corrected `runtime/engine.lua` header.

### Design Flaws Fixed

- **Design #1 — `spawn` O(N) uniqueness check** — Replaced full-cache scan with O(1) sentinel check `_cache[prefix] ~= nil`. File: `runtime/state.lua`. Regression test in `tests/runtime/state_spec.lua`.
- **Design #2 — Log serialiser drops extra fields** — `serialise_entries` now iterates all entry keys and serialises unknown fields generically. File: `runtime/log.lua`. Regression tests in `tests/runtime/log_spec.lua`.
- **Design #3 — 0-arg bare-string fallback** — Added comment explaining the trade-off (bare idents needed by builtins, but typos silently return strings). File: `runtime/eval.lua`.

---

## Code Review — Bugs #1–#4 and Inelegances #5–#11 ✅ (2026-04-30)

**1956 unit tests passing.**

### Bugs Fixed

- **Bug #1 — `IF_EXPR` as expression returned `nil`** — `return` signal leaked from if-body into parent ctx; fixed by not propagating `return` signals in expression-form `IF_EXPR` handler. Tests in `tests/runtime/eval_spec.lua`.
- **Bug #2 — UMap silently emptied in BFS/counterfactuals** — all three copy sites (`clone_flat`, `restore_engine`, counterfactual copy in `eval.lua`) already use `pairs`; confirmed and tested. Tests in `tests/runtime/search_spec.lua` and `tests/runtime/counterfactual_spec.lua`.
- **Bug #3 — Actor capture proxy missing `time_set`** — `proxy.set_time` already implemented in `actors.lua:127`; confirmed and tested. Tests in `tests/runtime/actors_spec.lua`.
- **Bug #4 — `deliver_messages` inbox overflow crashed turn** — overflow already handled gracefully (logs and breaks); confirmed and tested. Tests in `tests/runtime/actors_spec.lua`.

### Inelegances Resolved

- **#5** — Deleted dead `match_pattern` function from `eval.lua`.
- **#6** — Replaced sort-per-iteration in `optimal_path` with local binary min-heap (`heap_push`/`heap_pop`) in `search.lua`.
- **#7** — Deferred (BFS expansion logic duplicated ~5×): each BFS function has a different data payload and queue mechanism; shared helper would add more complexity than it removes.
- **#8** — `clone_cache` exported as `M.clone_cache` from `search.lua`; `make_search_cache` in `eval.lua` replaced with 3-line wrapper; also fixed latent `ipairs`→`pairs` bug.
- **#9** — Fixed all 11 `eng._in_bfs = true` occurrences to 4-space indent.
- **#10** — `map-keys` now sorts keys lexicographically before returning.
- **#11** — Added `apply_signal(stack, sig)` local helper in `search.lua`; replaced 5 duplicated signal-handling blocks.

---

## Demos 13–19 + Bug Backlog #1–#8 ✅ (2026-04-28)

**1945 unit tests passing.**

### Demos 13–19 Complete

- **Demo 13 — "The Healer's Ward"** — `speaker`/`say`, `post:` with `@before`,
  multi-line lambdas in `find` queries, entity family `patients/{k}: Patient max: 8`.
  Bugs fixed: `call_lambda` multi-line retval, `before_snapshot` at call time,
  `post:` EXPR_STMT unwrap, multi-line lambda parse, `@before` on INTERP_PATH,
  `query.lua` lambda `where:` clause, `count family where: fn(k):` syntax.

- **Demo 14 — "The Kingdom's Records"** — `schema-version: 4`, full 1→2→3→4
  migration chain: `add`, `rename`+`drop`, `transform fn old: ...`, `rename-enum`.
  `tests/runtime/migrate_demo14_spec.lua` exercises the full chain.

- **Demo 15 — "The Spellwright's Workshop"** — two hygienic macros
  (`with-mana-cost`, `craft-spell`), macro composition in three fns, `post:`+`@before`,
  Set-literal state default.
  Bugs fixed: `parse_default_value` Set literals, `emit_default` SET_LIT/LIST_LIT,
  `resolve_default` set/list tags, checker SET_LIT default, NAMED_ARG in macro `subst`.

- **Demo 16 — "The Cartographer's Web"** — `or-where`, `connected-to via`, 
  `inverse-adjacent?`, `find` with `order-by`+`limit`+`or-where`, `can-reach?` with
  `strategy: 'depth-first`, `find-path` with `strategy: 'breadth-first`, 
  `counterfactual simulate: true`.
  Bugs fixed: `counterfactual do:` parsed stmts not exprs, strategy symbol normalisation.

- **Demo 17 — "The Scholar's Commonplace"** — `UList(String)` + `UMap(String, Int)`,
  all 15 UList pure builtins, all UMap builtins, `for...else:` in scene body.
  Bugs fixed: `serialise_snapshot` dropped UMap hash keys (fixed to use `pairs`),
  `ser_val` hyphenated string keys (fixed to bracket notation).

- **Demo 18 — "The Baker's Queue"** — `path[n]` INDEX_EXPR, `path[a:b]` SLICE_EXPR,
  variable-bound slice `fn window s e: path[s:e]`, `for...else:` in scene body.
  Bugs fixed: SLICE_EXPR in PATH/IDENT branches with NAMED_ARG recovery.

- **Demo 19 — "The Signal Tower"** — debug server showcase: 10× `watch`, 5× `watch-when`,
  `engine-config debug-port`, `verify-always` invariants (448 BFS states), `after (fn): @before`
  verify blocks. `tests/runtime/debug_demo19_spec.lua` (26 tests).

### Bug Backlog #1–#8 Fixed

- **#1 RNG not logged** — `engine` creates `_rng = random_mod.new(seed, log)`; propagated via
  `make_ctx` and `child_ctx`. 7 logging/determinism tests.
- **#2 `query-at`/`query-history`/`query-changes` not callable from `.sb`** — 3 BUILTIN entries
  added to `eval.lua`. `time:` and `last-n:` named args. 5 tests.
- **#3 `random-bool` crash with no argument** — guard changed to
  `(args[1] and eval_expr(args[1], ctx)) or 0.5`. Test added.
- **#4 `[reversible]` tag does nothing** — `pass3c_check_reversible` added to `checker.lua`;
  emits `IRREVERSIBLE_IN_REVERSIBLE` for `clear!`, `time-inc!`, `time-set!`, `send!`,
  `cancel-schedule!`, `schedule!`. 4 tests.
- **#5 Dynamic `schedule!` invisible to BFS** — `search.lua:clone_cache` encodes full scheduler
  state into snapshots via `__sched/<name>/...` keys; `restore_engine` decodes.
  `make_search_cache` helper wired into all 6 BFS builtins. Regression test added.
- **#6 Path patterns in query context** — `**`, `(a|b)`, `!field` patterns in `watch`,
  `query-history`, `query-changes`. `debug.lua:path_matches` handles `!field` negation.
  9 new tests.
- **#7 `within N hops` excludes source** — removed source-exclusion guard in `query.lua:114`.
  4 new tests.
- **#8 `random-enum` O(N) type lookup** — `engine:init()` builds `schema._type_index` once;
  `random-enum` uses it for O(1) lookup.

---

## Stale Task Cleanup ✅ (2026-04-26)

The following items were listed as open in todo.md but had already been completed in Language Review passes 1 and 2. Moved to completed.

### Language Review — QoL / Ergonomics (all done in Pass 2)
- **Free `let` bindings** — already implemented; confirmed and documented.
- **Unified `say` syntax** — `say 'speaker "text"` accepted in scene bodies.
- **Inline `Enum(a,b,c)` unusable as named type** — promotion hint documented, type table clarified.
- **`for` loop `else` clause** — `else:` block runs when collection is empty.
- **`with` mixin conflict error** — already named both source types; confirmed.
- **`SymbolOf(EnumType)`** — checker extended to accept named enum types.

### Language Review — Documentation Gaps (all done in Pass 1)
- **`hook` declarations in `language.md`** — hooks section added.
- **`while` iteration safety limit** — 10,000-iteration cap and error documented.
- **`path@before` propagation into called functions** — documented in reference.
- **`say` ordering guarantee** — buffer/prepend behaviour explicitly documented.

---

## Language Review Pass 2 ✅ COMPLETE (2026-04-26)

1024 unit tests passing. 143 CLI integration tests passing.

### QoL Features Added
- **Free `let` bindings** — already implemented; tests and docs added.
- **`for` loop `else` clause** — `else:` block runs when collection is empty.
- **`UMap` runtime operations** — `map-set!`, `map-delete!`, `map-get`, `map-size`, `map-keys`.
- **`spawn!` shorthand** — `spawn! family 'key` (without record arg) already worked via defaults; confirmed and documented.
- **Unified `say` syntax** — `say 'speaker "text"` form now accepted in scene bodies (colon optional after symbol speaker).
- **`SymbolOf(EnumType)`** — checker extended to accept named enum types (both `type X = a|b` and `type X = Enum(a,b)` forms).
- **Inline Enum promotion hint** — documented that inline `Enum(a,b)` can't be referenced by name; added type table clarification and promotion guide.
- **`with` mixin conflict error** — already named both source types; confirmed and tests passed.

---

## Language Review Pass 1 ✅ COMPLETE (2026-04-25)

1763 tests passing.

### Bugs Fixed
- **`or-where` in `find`** — `query.lua`: rebuilt OR-group logic; consecutive `where` clauses AND within a group, `or-where` starts a new OR branch. Any `find` using `or-where` now gets correct OR semantics.
- **`exports:` filtering enforced** — `compiler/compiler.lua`: replaced `WARN_EXPORTS_NOT_ENFORCED` with actual filter; filterable kinds (fn, type, scene, actor, schedule, bounded, macro) are filtered against the `exports:` list; state/relation/grid/speaker/verify/hook always pass through.
- **`while` iteration limit now errors** — `eval.lua`: changed silent truncation at 10,000 iterations to a raised runtime error.

### Missing Features Added
- **`break` / `continue` in `for` and `while` loops** — added AST nodes, keywords, parser rules, and signal-based eval. Loops intercept break (exit) and continue (next iteration) signals.
- **Early `return` from functions** — `return <expr>` statement added end-to-end. `call_fn` consumes the return signal; return value propagated via `ctx.retval`.
- **`not-in?` builtin** — `(not-in? item collection)` sugar for `not (contains? coll item)`. Works on lists and sets.
- **`empty?` builtin** — was already implemented; confirmed and documented.

### Documentation Updated
- `docs/reference/language.md`: added `hook` section, `while` limit warning, `break`/`continue` section, `return` section, `path@before` propagation note, `say` ordering guarantee, collection builtins table.
- `docs/reference/cli.md`: removed `WARN_EXPORTS_NOT_ENFORCED` from warnings table.

---

## Demo 10 — "The Market Bell" ✅ COMPLETE (2026-04-19)

1706 tests passing. Multi-axis time model demonstrated end-to-end.

- `demos/demo10_market_bell.sb` — two-axis time model (`day` + `hour`, hour wraps at 24)
- `time-inc! hour: 2` in `browse-stalls` advances hour; market auto-closes at hour 18
- `time-inc! day: 1` + `time-set! hour: 8` in `rest` advances to next morning
- `every: [day: +1]` schedule (`morning-bell`) fires each rest: reopens market, randomises prices
- `at: [day: +4]` one-shot schedule (`grand-festival`) fires after 4 rests (player sees Day 5): closes market permanently, cancels morning-bell
- `engine/emit` events: `market-opened`, `market-closed`, `festival-begins`
- `watch` / `watch-when` declarations; 4 `verify` blocks (all pass, 36 BFS states)
- 6 dedicated integration tests in `tests/cli/cli_integration_spec.lua`

**Design note:** engine day clock starts at 0; `at: [day: +4]` fires at engine day=4 (after 4 rests). `world/day` state variable starts at 1 and increments alongside, so the player sees "Day 1 of 5" through "Day 5 of 5". The `offset: [day: 0]` syntax is present to demonstrate offset notation; cross-axis offsets (e.g. `offset: [hour: 6]` on an `every: [day: +1]` schedule) are parsed but not enforced by the scheduler.

---

## Interactive Demo Testing — Demos 01–09 ✅ COMPLETE (2026-04-19)

All nine demos tested end-to-end via `--cli` single-step scripting mode. 1696 tests passing.

- **demo01** — The Wanderer: basic scene flow, choices, state ✓
- **demo02** — The Merchant: inventory/trade mechanics ✓
- **demo03** — The Quest: quest state, multi-scene flow ✓
- **demo04** — The Expedition: entity families, spawn/despawn ✓ (fixed: guard on "Push deeper"; pcall on do_choice)
- **demo05** — The Siege: time-model, actors, schedules ✓
- **demo06** — The Buried Keep: exploration, relations ✓ (fixed: torch-bundle added to vault loot)
- **demo07** — The Wanderer's Oracle: imports, counterfactual, bounded ✓ (no bugs found)
- **demo08** — The Probability Engine: BFS search builtins as gameplay ✓
  - Fixed: `engine.lua:make_ctx` was not propagating `_scene_stack` → `ctx.scene_stack`; BFS builtins always started from entry scene. Fixed + regression test.
  - Fixed: `spy-can-escape?` / `spy-doom-position` used `depth: 5`; simulation requires 6 steps. Fixed depths to 6.
- **demo09** — The Warden's Map: advanced tile grid ✓
  - Fixed: `tilegrid.lua:find_path` allowed corner-cutting diagonals past wall/trap pairs. Diagonal moves now rejected when both cardinal neighbours are non-walkable.

---

## All Completed Tasks from Active Backlog ✅ (2026-04-19)

### Bugs / Spec Gaps

- `import "path" as Alias` silently ignored → `resolve_imports` now emits `UNSUPPORTED_FEATURE`. Tests in `tests/compiler/import_spec.lua`.
- `module ... exports:` not enforced → parser stores `exports:` list; importing emits `WARN_EXPORTS_NOT_ENFORCED`. Tests in `tests/compiler/import_spec.lua`.

### Small Wins

- **Source-context lines in error messages.** `print_diags` in `cli/main.lua` and `cli/check_cmd.lua` accept `source_map` and print offending line + caret.
- **`storybase check` subcommand.** `cli/check_cmd.lua` — lexer+parser+checker only with source-context output.
- **`storybase format` pretty-printer.** `cli/format_cmd.lua` — canonical 2-space-indented output; `--check` and `--write` modes.
- **`--debug` flag on `run`.** `engine.run` accepts `opts.debug_port`; creates TCP debug server.
- **`storybase repl` subcommand.** `cli/repl_cmd.lua` — interactive REPL with `:state`, `:scene`, `:choices`, `:choose N`, `:tick`, `:save/:load`.
- **`at:` one-shot schedule trigger.** Deregister-after-fire for pure `at:`-only schedules. 12 tests in `tests/runtime/scheduler_spec.lua`.

### Medium Features

- **Namespaced imports (`import "path" as E`).** `apply_import_namespace` in `compiler/compiler.lua`; `compiler/parser.lua` extended for `Alias.Name`. 7 tests in `tests/compiler/import_spec.lua`. 1611 tests.
- **Path patterns in `watch` and `verify` forms.** `**` multi-segment wildcards and `(a|b)` alternation in `runtime/debug.lua`; `runtime/verify.lua` exports `match_path_pattern`. Tests in `tests/runtime/debug_spec.lua` (+14) and `tests/runtime/verify_spec.lua` (+9).
- **Browser-based debug UI + interactive play.** HTTP+SSE transport, game-play commands, embedded HTML/JS/CSS, `--serve` flag. 23 tests in `tests/runtime/debug_http_spec.lua`. 1634 tests.
- **`counterfactual` as a language expression.** `from_tick` log replay in `eval.lua`. 4 tests in `tests/runtime/counterfactual_spec.lua`.
- **Demo 07 — The Wanderer's Oracle.** `demos/demo07_oracle.sb` + `demos/oracle_lib.sb`. 1596 tests.
- **Demo 08 — The Probability Engine.** BFS search builtins as gameplay. See demo testing section above.
- **Demo 09 — The Warden's Map.** Advanced tile grid builtins. See demo testing section above.

### Major Features

- **Language Server (LSP).** `cli/lsp.lua` — stdio JSON-RPC 2.0; diagnostics on open/change; hover, definition, completion. 43 tests in `tests/cli/lsp_spec.lua`.
- **Standalone bundler (`storybase bundle`).** `cli/bundle_cmd.lua` — single self-contained Lua file; 14 runtime modules embedded; `--production` strips verify/watch. 20 tests in `tests/cli/bundle_spec.lua`.

### Deferred Items (now complete)

- `engine/checkpoint!` callable form — parser handles as `CHECKPOINT_MUT` node; eval pushes log checkpoint. Tests in `tests/lib/storybase_spec.lua`.
- `engine/emit event args` callable form — parser handles as `EMIT_MUT` node; fires debug server AND `_emit_hook`. Tests in `tests/lib/storybase_spec.lua`.
- Doc string surfacing via public API — `game:docs(name?)` added to `lib/storybase.lua`. Tests in `tests/lib/storybase_spec.lua`.
- Doc string surfacing via debug server schema browser — `get-schema` command in `runtime/debug.lua`. 9 tests in `tests/runtime/debug_spec.lua`.

---

## Demo 06 — "The Buried Keep" ✅ COMPLETE (2026-04-15)

1465 tests passing. All checklist items verified.

### Fixes made for demo06

- `compiler/parser.lua`: relation static-data block now accepts both `{...}` and `[...]` syntax for value sets
- `runtime/engine.lua`: `_render_narration_items` now handles `scene_goto`/`scene_enter` inside when-blocks; `render_scene` propagates nav signal from `when` body
- `compiler/parser.lua`: `in` binary operator added in `parse_cmp`
- `runtime/eval.lua`: `in` binary operator evaluation (array-style and map-style tables)
- `runtime/eval.lua`: `contains?` builtin added
- `runtime/eval.lua`: `size`/`empty?` fixed for map-style tables (`{key=true,...}` from `adjacent?`)
- `runtime/eval.lua`: PATH_EXPR multi-segment access on local table vars (`c/path`)
- `compiler/parser.lua`: `for x in expr:` handles NAMED_ARG tokenization of iterator
- `compiler/parser.lua`: `when condition:` handles NAMED_ARG tokenization of condition
- `compiler/parser.lua`: `relate!`/`unrelate!` use `parse_atom` to prevent greedy arg collection

### Implementation Checklist

- [x] Write `demos/demo06_buried_keep.sb` per the spec above
- [x] Verify it runs cleanly: `lua5.4 cli/main.lua run --auto demos/demo06_buried_keep.sb`
- [x] Add to CLI integration tests: entry in `tests/cli/cli_integration_spec.lua`
- [x] Smoke-test all scenes are reachable (combat, defeat, loot-room, victory, intro, keep — 6 scenes)
- [x] Confirm `migration 1->2` block is present and parses without error
- [x] Confirm `defgrid` + `within-range?` calls execute without runtime error
- [x] Confirm `hook combat: post:` increments `world/kills` after `attack-monster`
- [x] Confirm `hook after: move-to:` decrements torches after each `move-to`
- [x] Confirm `schedule torch-burn` and `wraith-stirs` fire at correct intervals
- [x] Update `code_map.md` to mention demo06
- [x] Make a commit

---

## Spec Gap Pass ✅ COMPLETE (2026-04-15)

All items specified in `idea.md` but missing from the implementation. All are now done.

### §10 Random Sources

- [x] `random-bool p` — Bool with probability p; logs result; search engine branches on true/false
- [x] `random-enum EnumType` — uniform draw from declared enum; logs; search engine branches over all values
- [x] `random-choice list` — uniform draw from a List; logs; search engine branches over all values
- [x] `random-weighted weights list` — weighted draw; logs; search engine branches weighted

### §24 Standard Library

- [x] `str ...` — concatenate any number of values into a String
- [x] `abs val` — absolute value of an Int
- [x] `clamp val lo hi` — clamp Int to [lo, hi]
- [x] `int-to-str n` — Int → String
- [x] `str-to-int s` — String → Option(Int)
- [x] `size set` — Set(T) → Int: number of elements
- [x] `empty? set` — Set(T) → Bool
- [x] `union a b` — Set(T) Set(T) → Set(T)
- [x] `intersect a b` — Set(T) Set(T) → Set(T)
- [x] `list-get list n` — List(T) Int → Option(T)
- [x] `list-size list` — List(T) → Int

### §24 Engine Pseudo-Paths

- [x] `engine/current-scene` — reads as the current SceneId
- [x] `engine/scene-stack` — reads as the scene stack list
- [x] `engine/tick` — reads as the current tick counter
- [x] `engine/time` — reads as the full time tuple

### §9 Hooks and Aspects

- [x] `tag name` — custom tag declaration (parser + codegen)
- [x] `hook before: fn-name:` / `hook after: fn-name:` — declaration parsing + runtime dispatch
- [x] `hook tagname: pre: body` / `hook tagname: post: body` — tag-based hooks
- [x] `changes` variable in `post:` hook blocks — list of `{path, old, new}` records

**Completed this session (2026-04-15, spec-gap pass):**
- `runtime/eval.lua`: added `random-bool`, `random-enum`, `random-choice`, `random-weighted`, `str`, `abs`, `clamp`, `int-to-str`, `str-to-int`, `size`, `empty?`, `union`, `intersect`, `list-get`, `list-size` builtins
- `runtime/eval.lua`: engine pseudo-path reads (`engine/current-scene`, `engine/scene-stack`, `engine/tick`, `engine/time`) via `ctx.engine_ref`
- `runtime/eval.lua`: full hook dispatch in `call_fn` — pre/post hooks by tag and by fn name; `changes` variable in post-hook context
- `runtime/engine.lua`: `ctx.engine_ref = self` in `make_ctx`
- `compiler/ast.lua`: `tag_decl` and `hook_decl` node kinds + constructors
- `compiler/lexer.lua`: `tag` and `hook` keywords
- `compiler/parser.lua`: `parse_tag_decl`, `parse_hook_decl`, `_multi_decl` flattening
- `compiler/codegen.lua`: `emit_tags` and `emit_hooks` → `game_table.tags` and `.hooks`
- `tests/runtime/eval_spec.lua`: +49 tests covering all new builtins, engine pseudo-paths, hook execution
- `tests/compiler/codegen_spec.lua`: +6 tests covering tag/hook codegen

**Completed this session (2026-04-16):**
- `tests/compiler/codegen_spec.lua`: +16 tests covering migration declarations, defgrid declarations, watch emission, verify emission

**Completed this session (2026-04-15):**
- Fixed bug: `relate!`/`unrelate!` were silently no-ops; implemented handlers that mutate `game_table.relations[rel].data`
- `tests/runtime/eval_spec.lua`: +38 tests
- `tests/runtime/state_spec.lua`: +17 tests
- `tests/runtime/log_spec.lua`: +13 tests
- `tests/runtime/engine_spec.lua`: +10 tests
- `tests/compiler/import_spec.lua`: +4 tests
- `tests/lib/storybase_spec.lua`: +7 tests
- `tests/compiler/checker_spec.lua`: +5 tests

---

## CLI Integration Tests ✅ COMPLETE (2026-04-14)

**1292 tests passing.**

- Fixed `cli/verify_cmd.lua`: was treating diagnostic accumulator as plain array
- Fixed `cli/migrate_cmd.lua`: same diags-as-array bug
- Fixed `cli/main.lua`: added `--auto` / `--steps N` non-interactive run mode; fixed require guard; fixed `BOOL_FLAGS`
- Fixed `compiler/codegen.lua`: `state player: Player = Player(...)` now expands correctly; added `collect_type_record_fields` helper
- Created `tests/cli/cli_integration_spec.lua`: 77 tests covering all CLI subcommands against all test*.sb and demo*.sb files
- Updated `CLAUDE.md` with Testing Regime section
- Updated `code_map.md`

---

## Tile Grid Extension ✅ COMPLETE (2026-04-13)

**1214 tests passing.**

- `runtime/tilegrid.lua` — new module: storage helpers, `within_range` (chebyshev/manhattan/euclidean), `visible_from` (float-step raycasting), `find_path` (A* with min-heap), `occupied_by`
- Compiler pipeline wired for `defgrid` declarations: ast.lua, parser.lua, checker.lua, codegen.lua
- Engine integration: `engine.lua` `_grids` field, `init_grids()`, grids in `make_ctx()`
- Eval builtins: `grid-get`, `grid-set!`, `grid-width`, `grid-height`, `within-range?`, `visible-from?`, `path-to`, `occupied-by`
- `tests/runtime/tilegrid_spec.lua` — 83 unit tests
- `tests/compiler/defgrid_spec.lua` — 26 tests

---

## Phase 8 — Macro System, Lua Interop, and Polish ✅ COMPLETE (2026-04-09)

**M Goal:** Full public API; macro system; performance acceptable for 20 NPCs at depth-50 search.

### Macro System

- [x] `macro name params: body` declaration parsing
- [x] Macro expansion pre-pass (before type-check)
- [x] Hygienic expansion (generated names do not collide with user names)
- [x] Error: macro in body expands another macro defined in the same compilation unit
- [x] Error: recursive macro invocation (direct or mutual)
- [x] Expanded form is what the type checker and log see

### Lua Interop (`lib/storybase.lua`)

- [x] `sb.load(file)` → game object
- [x] `sb.from_source(src, name)` → game object
- [x] `game:call(fn_name, arg1, ...)` — invoke transaction function
- [x] `game:get(path)` → current value
- [x] `game:find(family, opts)` → list of matching keys
- [x] `game:on(event_name, handler_fn)` — subscribe to debug/presentation events
- [x] `game:choose(index)` — dispatch player choice by visible index
- [x] `game:eval(expr_string)` → value (pure expressions only)
- [x] `game:counterfactual(fn)` → frozen snapshot
- [x] `game:register_bounded(name, lua_fn)` — register bounded computation handler

### CLI Polish

- [x] `storybase extract-symbols <file>` — scan symbol literals, output candidate `type` declaration
- [x] `storybase compile --production` — emit production build (strips debug-only content)
- [x] `storybase run --seed N` — fix random seed for reproducible runs
- [x] `storybase compact <game.sb> <save.log>` — emit snapshot + delta log to reduce replay time
- [x] `storybase help` / `--help` on all subcommands — fully implemented

### Performance

- [x] State cache snapshot at every checkpoint (O(delta since snapshot) replay)
- [x] Search engine inner loop uses explicit stack (not coroutines) for BFS/DFS
- [x] Search engine coroutine used only at top-level suspension boundary (make_iterator)
- [x] Wall-clock time budget enforced per search call (BUDGET_CHECK_N=50)
- [x] Benchmark: `tests/fuzz/perf_benchmark_spec.lua` — can_reach depth=50 < 10s verified

### Tile Grid Extension

- [x] `defgrid name: dimensions: W x H  cell-type: T` declaration
- [x] Grid as discrete state (flat array in `engine._grids[name].cells`)
- [x] `visible-from?`, `within-range?`, `path-to`, `occupied-by` builtins

### Production Build Mode

- [x] `debug-only` declarations stripped from compiled output
- [x] `pre:` / `post:` contract blocks stripped (unless `strict-contracts: true`)
- [x] `watch` / `watch-when` declarations stripped
- [x] Debug server not started in production builds

### Tests — Phase 8

- [x] `tests/compiler/macro_spec.lua` — basic expansion, hygiene, restriction, recursive error
- [x] `tests/lib/storybase_spec.lua` — all public API methods, counterfactual API, register_bounded
- [x] `tests/fuzz/parser_fuzz_spec.lua` — random token sequences never crash the parser
- [x] `tests/fuzz/log_fuzz_spec.lua` — log replay deterministic under random mutations
- [x] Performance benchmark passes

**M Milestone:** All eight `tests/test0*.sb` files compile, run, and pass `storybase verify`. ✅

---

## Phase 7 — Debug Tooling ✅ COMPLETE (2026-04-09)

**M Goal:** Full dev-mode experience: hot reload, time-travel, watches, TCP debug protocol.

### Debug Server (`runtime/debug.lua`)

- [x] TCP server (requires LuaSocket); falls back to hook mode if LuaSocket absent
- [x] Server disabled entirely in production builds
- [x] Newline-delimited JSON encoder/decoder
- [x] Emitted event: `mutation {path, old, new, fn, tick}`
- [x] Emitted event: `scene-change {from, to, stack, tick}`
- [x] Emitted event: `message-sent {actor, msg, tick}`
- [x] Emitted event: `schedule-fired {name, tick}`
- [x] Emitted event: `fn-call {name, args, tick}` (dev mode only)
- [x] Emitted event: `spawn-event {family, key, init, tick}`
- [x] Emitted event: `despawn-event {family, key, tick}`
- [x] Emitted event: `clamp-event {path, attempted, clamped, tick}`
- [x] Emitted event: `reload {file, outcome, changes, tick}`
- [x] Accepted command: `get-state {pattern}` → `{path: value, ...}`
- [x] Accepted command: `eval {expr}` → value
- [x] Accepted command: `reload {src}` → outcome (hot-reload fns/scenes)
- [x] Accepted command: `set-breakpoint {condition}` → id
- [x] Accepted command: `clear-breakpoint {id}`
- [x] Accepted command: `time-travel {tick}` → frozen snapshot
- [x] Accepted command: `get-log {from, to}` → log entries

### Hot Reload

- [x] Function body changed: apply immediately; state preserved
- [x] New field added to record type: initialise all existing instances with declared default
- [x] Field removed from type: drop value silently
- [x] Enum value added/removed: validation
- [x] Type range narrowed: error if current state out of range
- [x] All changes applied transactionally (validate first, then apply atomically)

### Watches

- [x] `watch-when cond "label"` — register_watch_when, fires on positive edge
- [x] `watch path "label"` — register_watch, fires on non-nil value
- [x] Watch declarations stripped from production builds

### Tests — Phase 7

- [x] `tests/runtime/debug_spec.lua` — all commands, events, hot reload, watches, breakpoints

---

## Phase 6 — Advanced Features ✅ COMPLETE (2026-04-06)

**M Goal:** Counterfactuals, bounded computations, undo, and schema migration all work.

### Counterfactual

- [x] `counterfactual from: T do: transitions` — create branched GameState
- [x] Replay log to tick T then apply transition sequence to a private cache copy
- [x] `GameState` value is immutable (no side effects on live state)
- [x] `(in-state gs) path` — redirect a path read to the GameState copy
- [x] `find ... in-state: gs` clause — redirects find to snapshot cache
- [x] `simulate: true` — include actor steps and scheduled events in the branch
- [x] Nesting depth limit: enforce `max-counterfactual-depth` from engine-config
- [x] Log: append `counterfactual(from: T, transitions: [...])` entry

### Bounded Computations

- [x] `bounded` declaration parsing: `returns:`, `distribution:`, `reads:`, `lua:`
- [x] Codegen emits `game_table.bounded` table with declaration metadata
- [x] Call dispatch in eval.lua: calls `game._bounded_handlers[name](arg, snap)`
- [x] Lua handler registration via `game:register_bounded(name, fn)`
- [x] Log result as a random-draw entry
- [x] `uses-bounded` tag auto-applied to any function calling a `bounded` computation
- [x] Search: branch over `uniform` distribution
- [x] Search: branch over `conditioned-on path` distribution

### Undo

- [x] `undo!` — revert state to the most recent checkpoint
- [x] `undo! steps: N` — revert N checkpoints back
- [x] Append `undo` event to log (audit trail preserved)
- [x] Correctly identify checkpoint boundaries (functions tagged `[checkpoint]`)
- [x] Runtime error if no checkpoint exists in history
- [x] `tags: [checkpoint]` parsed in parser and emitted to compiled fns

### Schema Migration (`runtime/migrate.lua`)

- [x] `schema-version: N` declaration stored and compared on load
- [x] `migration A -> B:` block parsing
- [x] `rename old-path -> new-path`
- [x] `add path = value`
- [x] `drop path`
- [x] `transform path: fn old: expr`
- [x] `transform npcs/*/field:` — wildcard applied per family member
- [x] `rename-enum path old -> new`
- [x] Apply migration chain in ascending version order
- [x] Error: save is at version N but migration N → N+1 is missing
- [x] `storybase migrate <game.sb> <save.log>` CLI command

### Tests — Phase 6

- [x] `tests/runtime/counterfactual_spec.lua` — branching, in-state redirect, isolation, simulate, nesting, log entry, find in-state
- [x] `tests/fuzz/counterfactual_fuzz_spec.lua` — isolation holds under random transitions
- [x] `tests/runtime/migrate_spec.lua` — all migration operations, version chain, error cases
- [x] `tests/runtime/engine_spec.lua` — undo! reverts, undo! steps:N, undo! errors with no checkpoints
- [x] Integration scenario 8: player dies, `undo!` restores pre-death state
- [x] Integration scenario 10: save → migrate → reload → state identical

---

## Phase 5 — Query and Future-State Search ✅ COMPLETE (2026-04-05)

**M Goal:** `storybase verify` passes all verify blocks.

### Query (`runtime/query.lua`)

- [x] `find family` base form with `where`, `or-where`, `order-by`, `limit`, `count` clauses
- [x] `within N hops of <relation> from <src>` reachability filter
- [x] `connected-to <path> via <relation>` any-hop adjacency filter
- [x] Relation queries: `adjacent?`, `reachable?`, `shortest-path`, `reachable-set`, `inverse-adjacent?`
- [x] All with `max-hops:` bound where applicable

### Search Engine (`runtime/search.lua`)

- [x] State graph node: full cache snapshot identified by content hash
- [x] Cycle detection via content hash
- [x] Successor function: all transaction functions reachable from current scene
- [x] Successor function: scheduled events pending at current time
- [x] Successor function: actor behavior steps
- [x] Random source branching: one successor per outcome
- [x] `bounded` computation branching over declared distribution
- [x] Probability weight tracking and propagation
- [x] Probability pruning with approximate-result annotation
- [x] BFS, DFS, and best-first search strategies
- [x] `depth: N` and `budget:` (wall-clock seconds) parameters on all search ops
- [x] Coroutine-based iterator (make_iterator)
- [x] `can-reach?`, `find-path`, `verify-always`, `find-counterexample`, `probability`, `optimal-path` builtins

### Verify Blocks

- [x] Compile `verify` declarations into test cases at load time
- [x] `from-any-state:`, `when:`, `requires`, `after:`, `path@before` clauses
- [x] Failure report: specific failing state + counterexample path
- [x] `storybase verify <file>` CLI command; per-block pass/fail; exit code

### Tests — Phase 5

- [x] `tests/runtime/verify_spec.lua`, `tests/runtime/search_spec.lua`, `tests/runtime/query_spec.lua`
- [x] `tests/fuzz/search_fuzz_spec.lua` — state-space coverage, BFS/DFS agreement

**M Milestone:** `storybase verify tests/test05_log_and_time.sb` and `tests/test06_actors.sb` pass. ✅

---

## Phase 4 — Actors, Messaging, and Scheduling ✅ COMPLETE (2026-04-05)

**M Goal:** The §25 complete example runs including actor behaviors and morning reset schedule.

### Actors (`runtime/actors.lua`)

- [x] Actor registration at load time
- [x] Perception snapshot with perceives filtering (pass4_check_perceives in checker)
- [x] Behavior function dispatch in priority order
- [x] Deferred mutation queue; conflict detection and resolution (higher-priority wins for set/clear; all apply for inc/dec/collection)
- [x] Conflict logging in transaction log
- [x] `send!` — enqueue typed ActorMsg; inbox bounded; delivery step; inbox clearing

### Scheduler (`runtime/scheduler.lua`)

- [x] Static `schedule` declarations registered at load time
- [x] `every: [axis: +N]` trigger with `offset:`
- [x] `at: [axis: N]` one-shot trigger
- [x] `schedule!` imperative: create named scheduled event from within a transaction fn
- [x] `cancel-schedule!` imperative
- [x] Schedule creation/cancellation/firing logged; replay_log reconstructs on load

### Engine — Full Turn Lifecycle

- [x] Six-step lifecycle: player action → message delivery → actor behaviors → mutation application → scheduled events → inbox clearing
- [x] Autonomous turn (steps 2–6 only)
- [x] NPC speed modelling: `npc-speed: N` in engine-config

### Tests — Phase 4

- [x] `tests/runtime/actors_spec.lua` — perception, deferred mutations, conflicts, inbox, scheduling
- [x] Integration scenarios 4–7 (deliver ore, random encounter, morning reset, actor messaging)

**M Milestone:** `tests/test06_actors.sb` runs correctly; §25 complete example runs end-to-end. ✅

---

## Phase 3 — Runtime Core ✅ COMPLETE (2026-04-02)

**M Goal:** A game with player actions and scenes runs end-to-end with a correct transaction log.

### State Store (`runtime/state.lua`)

- [x] Flat Lua table keyed by path string
- [x] `get`, `set!`, `inc!`/`dec!` (clamping), `add!`/`remove!`/`clear!`, `push!`/`pop!`
- [x] Indexed List read/write (`path[n]`) and slice (`path[a:b]`)
- [x] `spawn!`/`despawn!`, `path-exists?`, `path-list`
- [x] `clamp-event` hook; `_spawn_hook`/`_despawn_hook`
- [x] `push_checkpoint`/`undo`

### Transaction Log (`runtime/log.lua`)

- [x] Append with sequential numbering; atomic cache + log update
- [x] `query-at`, `query-history`, `query-changes`
- [x] Serialise/deserialise; snapshot + delta log for fast replay
- [x] Checkpoint markers; `last_checkpoint_seq`

### Engine (`runtime/engine.lua`) — Core

- [x] Scene stack (push/pop/peek); `scene-stack-max` enforcement
- [x] `->` goto, `->()` computed goto, `=>` enter, `<-` exit; imperative equivalents
- [x] Scene rendering: narration, conditional narration, choices, choice guards, inline expressions
- [x] Time model; `time-inc!`; absolute time set
- [x] Save/load via serialised log

### Eval (`runtime/eval.lua`)

- [x] `eval_expr`, `eval_stmt`, `eval_stmts`, `eval_path`, `call_fn`, `render_text`
- [x] All literals, operators, path reads, fn calls, mutations, scene navigation signals
- [x] Built-ins: min, max, path-list, count-where, any?, all?, random-int, tostring, and all spec-gap builtins

### Tests — Phase 3

- [x] `tests/runtime/state_spec.lua`, `tests/runtime/eval_spec.lua`, `tests/runtime/engine_spec.lua`, `tests/runtime/log_spec.lua`
- [x] Integration scenarios 1–3 (village walk, combat, guarded shop)

**M Milestone:** `test02_choices.sb` runs end-to-end with correct transaction log. ✅

---

## Phase 2 — Expressions, Functions, and the Type Boundary ✅ COMPLETE (2026-04-05)

**M Goal:** All function declarations type-check; the discrete/superficial boundary is enforced.

### Parser Extensions

- [x] Infix comparisons with correct precedence
- [x] Prefix function calls (multi-argument, unbounded arity)
- [x] Nil-coalescing `??`, arithmetic, collection literals (set/list/map), `(set)` empty set
- [x] Control flow: `match`, `cond`, `if/else`, `when`, `for`, `while`, `let`
- [x] Lambda expressions `fn(params): body`
- [x] Function declarations: `fn name args: body` with `pre:`, `post:`, `tags:`
- [x] `path@before` in `post:` blocks
- [x] All mutation primitives; relation mutations; `spawn!`/`despawn!`; `send!`; `time-inc!`; `cancel-schedule!`; `undo!`
- [x] Scene navigation sigils; indexed path access; narration inline expressions

### Checker Passes

- [x] Pass 3 (Pure/Transaction Inference): classify every fn; transitive purity; lambda purity rule; `uses-bounded` tag
- [x] Pass 4 (Write-Set Analysis): static write-set; `{var}` interpolation in write position; WRITE_UNTYPED_VAR
- [x] Pass 5 (Discrete/Superficial Boundary): SUPERFICIAL_IN_COND, RANDOM_SUPERFICIAL, SUPERFICIAL_PARAM
- [x] Pass 6 (Contract Validation): PRE_NOT_BOOL, POST_NOT_BOOL, PATH_BEFORE_INVALID
- [x] Pass 7 (Perceives): PERCEIVES_VIOLATION warning for reads outside actor perceives list
- [x] Pass (Recursive Scenes): compile warning for scenes that can push themselves

### Tests — Phase 2

- [x] `tests/compiler/parser_spec.lua` — all expression forms, operator precedence, control flow, mutations, fn/scene declarations
- [x] `tests/compiler/checker_spec.lua` — pure/transaction inference, type boundary, write-set analysis

**M Milestone:** `test02_choices.sb` and `test03_types.sb` compile without errors. ✅

---

## Phase 1 — Core Language (Lexer, Parser, Basic Checker) ✅ COMPLETE (2026-03-26)

**M Goal:** `storybase compile game.sb` produces a valid compiled table for a schema-only file.

### Scaffold

- [x] Directory structure: `compiler/`, `runtime/`, `cli/`, `lib/`, `tests/`
- [x] `compiler/ast.lua` — node constructors and constants
- [x] `compiler/compiler.lua` — pipeline orchestrator
- [x] `cli/main.lua` — entry point and command dispatch
- [x] Structured error table; error accumulator; warning support

### Lexer (`compiler/lexer.lua`)

- [x] LPEG-based; INDENT/DEDENT pre-pass
- [x] All token types: integers, floats, booleans, strings, multiline strings, symbol literals, paths, interpolated paths, named arguments, infix operators, boolean operators, keywords, identifiers, block sigils, collection delimiters
- [x] Whitespace and comment stripping; source position on every token
- [x] Errors: unterminated string, illegal character, mixed tabs/spaces

### Parser (`compiler/parser.lua`) — declarations

- [x] Module header; import (flat and namespaced); schema-version; engine-config; time-model
- [x] Type declarations: enum, range alias, record (with `with` mixin), variant
- [x] State declarations: scalar, inline record, entity family
- [x] Relation declarations with optional static data block
- [x] Doc strings on all declaration kinds
- [x] Error recovery: continues after a bad declaration

### Type Expressions

- [x] Bool, Int(min,max), Enum(…), Option(T), Set(T,max), List(T,max), Symbol, SymbolOf(Family), String, Float, UList(T), UMap(K,V), named types, function types
- [x] State-space size computation for all discrete types
- [x] Discrete/superficial tag on every type

### Checker Passes 1 and 2

- [x] Pass 1: collect all type/state/scene/relation names; forward references; imported names; duplicate detection; undefined type errors
- [x] Pass 2: field type references; record field defaults; Int bounds; `with` mixin rules; entity family `max:`; SymbolOf resolution; `warn-untyped-symbol`

### Codegen (`compiler/codegen.lua`)

- [x] Full game_table emission: schema (types, states, relations), fns, scenes, actors, schedules, verifies, watches, migrations, bounded, tags, hooks, grids

### CLI — Phase 1

- [x] `storybase compile <file>` — diagnostics to stderr; exit code; summary

### Tests — Phase 1

- [x] `tests/compiler/lexer_spec.lua`, `tests/compiler/parser_spec.lua`, `tests/compiler/checker_spec.lua`, `tests/compiler/codegen_spec.lua`

**M Milestone:** `tests/test01_minimal.sb` compiles without errors or warnings. ✅

---

## Import Resolver ✅ COMPLETE (2026-04-04)

- [x] `import "file.sb"` splices declarations before checker
- [x] Cycle detection (IMPORT_CYCLE error)
- [x] Transitive imports
- [x] Duplicate name detection across imported files
- [x] Absolute import paths
- [x] Imported relations

---

## Demo Games 01–05 ✅ COMPLETE (2026-04-04)

| Demo | Features |
|------|----------|
| `demo01_wanderer.sb` | module, Int state, scene narration, `->`, `inc!`, `{expr}` |
| `demo02_merchant.sb` | type enum, multiple state paths, fn, choice guards, `match`, `if/else` |
| `demo03_quest.sb` | Bool flags, `fn` with `pre:`, `when`, `if/else`, Class enum, XP system |
| `demo04_expedition.sb` | entity family, `spawn!`/`despawn!`, `for`/`path-list`, `path-exists?`, `count-where` |
| `demo05_siege.sb` | time-model, actor + behavior, `send!`, schedule, `cancel-schedule!`, `verify-always` |

---

## Demo 21 — `query-at` / `query-history` / `query-changes` ✅ (2026-05-04)

`demos/demo21_merchants_reckoning.sb` — merchant end-of-day audit narrative showcasing all
three log-backed temporal query builtins as first-class gameplay mechanics. CLI integration
tests added to `tests/cli/cli_integration_spec.lua`. `code_map.md` demos table updated.

---

## Authoring Ergonomics (AE) Fixes ✅ (2026-05-04 / 2026-05-07)

### AE-1 — Apostrophes in prose text
Symbol literal sigil changed from `'` to backtick (`` ` ``). Apostrophe now emits
`RAW_TEXT` and is valid in narration prose. Updated: `compiler/lexer.lua`,
`compiler/parser.lua`, `cli/format_cmd.lua`, all demo/test `.sb` files, `idea.md`.

### AE-2 — UTF-8 characters silently corrupted in prose
The `> 127` branch in `compiler/lexer.lua` now decodes the full UTF-8 sequence length and
emits a `RAW_TEXT` token. Em-dashes, arrows, curly quotes, ellipsis etc. appear correctly.

### AE-4 — `query-at` returns nil for paths with declared initial values
`init_defaults` in `runtime/state.lua` now calls `_log_entry` for each default value, so
`query-at` can find initial state. Demo21's third verify block now uses the original wording
and passes.

### AE-5 — No escape for literal `{` in narration
`{{` in source now emits `RAW_TEXT "{"` at the lexer level without incrementing
`paren_depth`. Implemented in `compiler/lexer.lua`.

### AE-6 — Narration lines starting with a keyword produce confusing parse errors
`parse_body_items` in scene mode now appends a note to the last diagnostic after
`parse_if_expr`, `parse_when_stmt`, or `parse_for_stmt` produce errors, suggesting the line
may be narration. Implemented in `compiler/parser.lua`.

### AE-9 — No debug print / trace from `.sb` code
Added two builtins in `runtime/eval.lua`:
- `print` — varargs, space-joined, writes to stderr or `ctx.game._print_sink`
- `log` — levelled (`[DEBUG]`/`[INFO]`/`[WARN]`/`[ERROR]`) with source location
  `file:line (fn-name): msg`; level is a symbol arg (`` `debug ``, `` `info ``, etc.)

Both suppressed silently when `ctx.game.production = true`. Source location comes from
`ctx.call_pos` set at each `FN_CALL` dispatch in `eval_expr` and `eval_stmt`. 24 tests
added to `tests/runtime/eval_spec.lua`.

### AE-12 — No error when `=>` subscene forgets `<-`
`push_scene` in `runtime/engine.lua` now includes the full scene stack in the overflow error
message, showing the chain of `=>` pushes so the author can identify the missing `<-`.

---

## Remaining Polish — Public Function Test Coverage ✅ (2026-05-03)

Every public function in every module verified to have at least one passing and one failing
test. Added: scheduler dead-stub error test; lexer bare-tick and unclosed-interpolation
error tests.

---

## Authoring Ergonomics (AE) Fixes ✅ (2026-05-07 — second batch)

### AE-3 — Time axis / state variable sync
`time/<axis-name>` is now a read-only pseudo-path backed directly by the engine's time
state (e.g. `time/day`, `time/tick`). Authors use `time/day` in narration and guards without
declaring a separate `world/day` variable; `time-inc! day: 1` is the single call needed.
`time-set!` (already implemented but undocumented) documented at the same time.
7 tests added to `eval_spec.lua`. `time-model`, `time-inc!`, `time-set!` sections in
`docs/reference/language.md` updated.

### AE-7 — Actor `perceives:` opt-in contract
`perceives:` is now optional. When omitted the checker skips the check entirely and the
runtime grants full read access. When declared, the check runs as before. `perceives: []`
still means "explicitly perceive nothing external." Root cause: `ast.actor_decl` was
normalising nil to `{}`, making omitted and empty-list indistinguishable. Fixed in
`compiler/ast.lua`, `compiler/parser.lua`, `compiler/checker.lua`. 4 new tests.
`actor` section in `docs/reference/language.md` updated.

### AE-8 — `verify after+requires` checks all BFS-reachable states
When `requires:` is present alongside `after (fn):`, the check now runs from every
BFS-reachable state where `requires` holds, not just the fresh initial state. Without
`requires:`, original single-state behaviour is preserved. Also fixed two latent bugs in
`run_all`: counterexample fields and `states_checked` were not forwarded from
`run_after_check`. Extracted `snap_str()` helper shared by all three check functions.
5 tests added to `verify_spec.lua`. `verify` section in `docs/reference/language.md`
updated with full `after`/`requires` semantics table.

### AE-9 — `print` and `log` debug builtins
Added two builtins in `runtime/eval.lua`: `print` (varargs, space-joined, stderr/sink) and
`log` (levelled `[DEBUG/INFO/WARN/ERROR]` with `file:line (fn): msg` location). Both
suppressed when `ctx.game.production = true`. Output routed via `ctx.game._print_sink`.
Source location via `ctx.call_pos` set at each `FN_CALL` dispatch. 24 tests added.

### AE-10 — Pure function return value semantics documented
Added "Return values" note to `fn` section of `docs/reference/language.md` explaining
single-expression auto-return and multi-statement last-expression rule. Updated `return`
statement section to cross-reference and clarify transaction function restriction.

### AE-11 — Multi-segment loop variable path access documented
Added explanation and temporal-query example to the `for` section of `language.md`. Added
full `query-history` / `query-changes` / `query-at` section to `docs/reference/builtins.md`
(previously entirely absent), with log-entry field table and cross-reference.

---

## Author Experience Pass — Critical & Major Bug Fixes (2026-05-12)

### Bug #8 — Formatter dropped relation static data — FIXED
`storybase format --write` on a file containing a `relation` with a static data block emitted
only the bare `relation name` header; all initial edges were silently lost. **Fix:**
`cli/format_cmd.lua` RELATION_DECL handler now emits `from_type`, `to_type_expr`, and
`initial_data` edges. Exported `M.format_string` for testing. Comprehensive formatter test
bank added (`tests/cli/format_spec.lua`, 169 tests), which uncovered ~18 additional
field-name/structure bugs in `fmt_expr`/`fmt_type`/`fmt_decl` — all fixed. Known remaining
limitations: whitespace normalization in aligned narration (demo11), unhandled macro_decl
nodes (demo15 spellwright).

### Bug #9 — Parser internal error on `nil` as a match arm value — FIXED
Writing `_: nil` (or any arm whose value started with an IDENT token) in an inline `match`
arm caused `attempt to index a nil value (global 'MUTATION_TABLE')`. **Root cause:**
`MUTATION_TABLE` was declared as a `local` at line 1828 in `compiler/parser.lua`, but
`parse_match_expr` was defined at line 1226 — without a forward declaration the function
resolved the global (nil). **Fix:** Added `local MUTATION_TABLE` forward declaration and an
`eol_consumed` flag for a secondary double-NEWLINE-consume bug in mutation handlers.
8 regression tests (4 parser, 4 runtime).

### Bug #10 — `let x = expr:` scoped-body form was broken — FIXED
When the binding value ended with a bare identifier, the lexer tokenised `identifier:` as a
single `NAMED_ARG` token, consuming the colon. The parser never saw the `:` and fell into
the multi-binding continuation loop. **Fix (Option A):** `compiler/parser.lua:parse_let_value`
now checks `p.tokens[p.pos - 1]` after `parse_expr`; if the last consumed token was a
`NAMED_ARG`, `colon_done = true`. 4 regression tests.

### Bug #13 / AE-16 — REPL stuck on computed-goto entry scenes — FIXED
A `main:` scene dispatching via `-> (match player/location: ...)` left the REPL in a scene
with no choices and no way to advance. **Fix:** Added `game:advance_to_choices()` to
`lib/storybase.lua` which follows computed gotos until a scene with displayable choices is
reached. `render()` returns `nav_signal` as third return value. `cli/repl_cmd.lua` calls
`advance_to_choices()` after `game:init()` and after `:choose`. 6 regression tests.

---

## Match Completeness + Find Predicate Binding (2026-05-13)

### Bug #11 — `match` without wildcard silently returned `nil` — FIXED
A `match` expression with no `_:` wildcard returned `nil` when the subject matched no arm.
Downstream `set!` then silently unset the path. **Fix (Option C, A+B):**
(A) Runtime — `eval_match` falls through with a dev-mode `[WARN]` to `_print_sink` / stderr
(suppressed in production).
(B) Checker — new `pass_check_match_completeness` walks fn/scene bodies for MATCH_EXPR over
typed PATH_EXPR enum subjects; emits `INCOMPLETE_MATCH` when not all enum values have arms
and no wildcard. Added `INCOMPLETE_MATCH` to `ast.E`. 9 regression tests.

### Bug #12 — Non-lambda `find where:` predicate returned all entities unfiltered — FIXED
`find enemies where: enemies/{e}/status = \`alive` returned every entity. Only the lambda
form `where: fn(e): ...` worked. **Root cause:** `runtime/query.lua:M.find` bound only
`[family] = key` in the child context; if the condition used a different interpolation
variable (e.g. `{m}` in `where: members/{m}/...`), that variable was unbound. **Fix:**
`collect_interp_vars` pre-scans where-condition AST nodes for single-segment interp
variable names and binds all unresolved ones to the entity key. Parent-context vars are
never overridden. 6 regression tests (query_spec).

---

## Silent-Failure Hazard Fixes — SF-1 through SF-4 (2026-05-13)

### SF-1 — Zero-arg undefined function calls silently returned a string — FIXED
A typo like `move-too` returned the bare string `"move-too"` instead of raising an error.
**Fix (Option A):** In `runtime/eval.lua:call_fn`, when a 0-arg call falls through to the
bare-string return, emit a dev-mode `[WARN]`. Suppression logic lazily builds
`game._known_bare_names` from: relation names, grid names, scene names, named types, family
names, and single-segment scalar/record state paths. `pure` added as a silent no-op.
10 regression tests (eval_spec).

### SF-2 — Invalid enum values assigned without error — FIXED
`set! player/status \`zombie` succeeded silently when `Status = alive | dead`.
**Fix (Option C, A+B):**
(A) `runtime/state.lua` — `get_enum_values(type_desc, schema)` resolves inline enums
(`tag="enum"`), named enum references (`tag="named"`), and alias chains; `warn_invalid_enum`
called from `store:set` emits a dev-mode `[WARN]`. Handles family member field paths via
`lookup_type`. Suppressed in production.
(B) `compiler/checker.lua` — new `pass_check_invalid_enum_writes`; walks SET_MUT nodes with
SYMBOL_LIT values on static PATH_EXPR paths; resolves the path type via `build_path_type_map`;
resolves inline enums, named enums, and TYPE_ALIAS chains via `get_enum_values_checker`;
emits `INVALID_ENUM_VALUE`. INTERP_PATH paths skipped (runtime covers those). `MUT_PATH_KINDS`
and `walk_mut_with_path` refactored into a shared helper used by SF-2 and SF-3.
16 regression tests.

### SF-3 — Writes to undefined state paths silently no-op — FIXED
`set! player/nonexistent-field 5` compiled cleanly and did nothing at runtime.
**Fix (A+B):**
(A) `runtime/state.lua` — `warn_undeclared` helper added before every mutation method (set,
inc, dec, add, remove, clear, push, pop); checks path via `lookup_type(_type_index, path)`
in dev mode. Guards: production flag, `_schema_has_states` sentinel, `__` prefix paths
(engine-internal). Engine propagates `_production` and `_print_sink`. `actors.lua:register`
adds inbox paths to `_type_index` to avoid false positives.
(B) `compiler/checker.lua` — new `pass_check_undefined_paths` walks all mutation nodes; for
static PATH_EXPR paths checks against `build_path_type_map` and `symtab.families`; emits
`UNDEFINED_PATH`. Skips INTERP_PATH (dynamic) and INDEX_EXPR/SLICE_EXPR (unwrap to base).
16 regression tests.

### SF-4 — Transitions to undefined scenes silently ended the game — FIXED
`-> ghost-town` (when `ghost-town` is not declared) now emits `[WARN] goto undefined scene:
'ghost-town'` in dev mode. Same for `=>` (enter_scene). Both `goto_scene` and `enter_scene`
in `runtime/engine.lua` check `self._scenes[name]` and emit via `_print_sink` or stderr.
Suppressed in production. Checker-side covered by AV-2. 7 regression tests (engine_spec).

---

## Compile-Time Validation Gap Fixes — AV-1 through AV-4 (2026-05-13)

### AV-1 — Undefined function calls now caught at compile time
`pass_check_undefined_fns` walks all FN_CALL nodes with full scope tracking (sequential
let bindings, scoped let forms, lambda params, for-loop vars, variant field destructuring).
`CHECKER_BUILTIN_FNS` table mirrors `eval.lua` `BUILTINS`.

### AV-2 — Undefined scene transition targets now caught at compile time
`pass_check_scene_targets` checks all SCENE_GOTO/SCENE_ENTER string-literal targets and
`engine-config entry-scene` against declared scenes.

### AV-3 — Invalid enum literal values now caught at compile time
Extended `pass_check_invalid_enum_writes` (SF-2's pass) to cover ADD_MUT/REMOVE_MUT on
Set(Enum) paths by unwrapping the Set inner type.

### AV-4 — Reads/writes to undeclared state paths now caught at compile time
`pass_check_undefined_read_paths` checks PATH_EXPR nodes in read (expression) positions
using a conservative guard (only when first segment is a known state root or prefix) to
avoid false positives from for-loop variable field accesses. Also fixed
`build_path_type_map` to expand WITH_MIXIN fields recursively. 23 new regression tests
(checker_spec); zero false positives on all demos.

---

## Authoring Ergonomics — Third Batch (2026-05-13)

### AE-13 — Integer division yielded floats in narration — FIXED
`val_to_display` in `runtime/eval.lua` now checks whether a float value has no fractional
part and formats it with `%d` (no ".0"). Purely presentational; semantics unchanged.
3 regression tests.

### AE-14 — Compiler warnings repeated on every `run` — FIXED
Added `--quiet` flag to `storybase run`. When set, warnings are suppressed on stderr;
errors still print unconditionally. `quiet` added to `BOOL_FLAGS`; help text updated.
4 regression tests.

### AE-15 — Multi-line `find` inside parens lost clauses — FIXED
Inside `()` the lexer emits NEWLINE tokens between continuation lines but no
INDENT/DEDENT. The parser's find handler saw NEWLINE → no INDENT → undid the consume.
**Fix:** `compiler/parser.lua:parse_find_clauses_inline` — added newline-skipping clause
continuation path (`newline_skip` parameter). 6 regression tests (3 parser, 3 query).

### AE-17 — Added integer division / floor / ceil / mod builtins
Added to `runtime/eval.lua` and `compiler/checker.lua`:
- `int-div a b` → `math.floor(a / b)` (floor integer quotient)
- `floor n` → `math.floor(n)` (round toward −∞)
- `ceil n` → `math.ceil(n)` (round toward +∞)
- `mod a b` → `a % b` (floor-division remainder; sign matches divisor — same as Python)
11 regression tests.

---

## Spec / Documentation Divergence — SD-1 (2026-05-13)

Updated `idea.md` to match the actual parser syntax:
- §15.2 example and clause table use `where:`, `order-by:`, `limit:` (with colons)
- §15.2 note clarifies non-lambda `where: condition` correctly binds entity variable
- §21.2 counterfactual example: `where:` with colon
- §25 hostile-nearby? example: two `where:` clauses (AND-ed) instead of bare `where...and`
- §24 stdlib table: added `int-div`, `mod`, `floor`, `ceil`

No code changes; Bug #12 already handled the runtime fix.

**Test totals at end of pass: 2383 passing, 0 failing, 2 pending (known limitations).**

---

## Previously Noted Deviations from Plan

- **`types.lua` not created.** Type expression parsing is in `compiler/parser.lua`; type descriptors and state-space size computation are in `compiler/codegen.lua`. A separate file was not needed.
- **`runtime/eval.lua` added.** Not in original plan; cleanly separates AST interpretation from engine turn-loop concerns. Scene navigation uses `ctx.signal` (not Lua exceptions).
- **Debug server uses TCP/NDJSON**, not WebSocket as `idea.md §18.1` specifies. Protocol difference is intentional for simplicity; `idea.md` spec not updated.
- **`as Alias` import namespacing** — parser parses `as` but resolver performs a flat merge. Noted as a known gap; enforcement deferred to active tasks.

---

## §A10 — `--serve` arbitrary code execution via `eval` command ✅ (2026-05-14)

**Fixed (commit a8ab009):** Sockets now bind `127.0.0.1` by default; `--bind <addr>`
opts into broader exposure. The `eval` debug command is blocked entirely in `--serve`
mode. The `--ui <name>` driver name is validated against an explicit whitelist.

---

## §B1 — State-graph explorer (browser debug UI) ✅ (2026-05-14)

`runtime/search.lua` exports `M.expand_graph(gt, cache, stack, opts)` — full BFS
returning `{nodes, edges, truncated, node_count, edge_count}`. Nodes carry
`{id, scene, depth, terminal, cache_summary, cache}`; edges carry
`{from, to, label, choice_index}`. IDs are CSS-safe strings (`"n1"`, `"n2"`, …).

New debug command `get-state-graph {depth, max_nodes, budget}` in `runtime/debug.lua`
calls `expand_graph` from the live engine state. Browser debug UI gains a **Graph**
tab using cytoscape.js (CDN, force-directed `cose` layout). Terminal nodes shown
green; current node highlighted blue. Degrades gracefully if CDN is unavailable.

**Files:** `runtime/search.lua`, `runtime/debug.lua`, `tests/runtime/debug_spec.lua`
(14 new tests).

---

## §B2 — Counterexample minimisation ✅ (2026-05-14)

`runtime/verify.lua` exports `M.shrink_path(gt, path, expr, budget_secs)` which
greedily removes one step at a time (restarting on each successful removal) until
1-minimal. `run_always_check` post-processes every counterexample through the
shrinker (5-second default budget). `cli/verify_cmd.lua` displays
"Counterexample path (minimised from N to M steps)" and "[budget exceeded — may
not be minimal]" when applicable.

For purely deterministic games the shrinker is a no-op (BFS already finds the
shortest path). Its value is for externally-supplied paths (fuzz runs, manual
test cases). `M.shrink_path` is public for this reason.

---

## §B4 — Coverage report ✅ (2026-05-15)

`storybase coverage [--depth N] [--budget N] [--format json] <file>` walks the BFS
frontier via `M.expand_graph` and reports per-scene visit counts and per-fn call
counts. Unreachable scenes and uncovered fns are listed explicitly. `--format json`
emits a CI-friendly JSON object.

`runtime/eval.lua`'s `call_fn` fires `ctx.game._fn_call_hook(name)` before executing
each user fn body; `coverage_cmd` sets this hook on the game table before BFS runs.

**Files:** `cli/coverage_cmd.lua` (new), `runtime/eval.lua` (hook), `cli/main.lua`
(subcommand), `tests/cli/coverage_spec.lua` (17 tests).

---

## §C1 — `test` blocks ✅ (2026-05-13)

New top-level declaration `test "label": setup: ... run: ... expect: ...`. Parsed
by `compiler/parser.lua` (`TEST_DECL`), emitted by `compiler/codegen.lua` into
`game_table.tests`. `runtime/tests.lua` runs each test in a fresh state: applies
`setup:` mutations, executes `run:` fn calls, evaluates each `expect:` clause.

CLI: `storybase test game.sb` (mirrors the `verify` subcommand). Stripped from
production builds. `storybase run --auto` exercises test files safely.

**Files:** `compiler/ast.lua`, `compiler/parser.lua`, `compiler/codegen.lua`,
`runtime/tests.lua` (new), `cli/test_cmd.lua` (new), `cli/main.lua`,
`tests/compiler/test_decl_spec.lua`, `tests/runtime/tests_spec.lua`,
`tests/cli/test_cmd_spec.lua`.

---

## §C2 — Property / fuzz mode ✅ (2026-05-15)

`storybase fuzz [--runs N] [--steps N] [--seed N] [--failures-dir D]
[--max-failures N] [--format json] <file>` random-walks the choice tree using a
fresh engine per run (seeded `base_seed + run_i`). A Park-Miller LCG drives choice
selection via an internal driver. After each step, all `verify-always` clauses from
`game_table.verifies[*].clauses` are evaluated via `eng:make_ctx` + `eval.eval_expr`.
On violation, the engine log is saved as a `.sbd` file replayable with
`storybase run --load`.

**Key note:** named type aliases (`Gold = Int(0,N)`) do NOT clamp in `dec!`/`inc!` —
only inline `Int(0,N)` types do. Pre-existing limitation of `state.lua`'s type index.

**Files:** `cli/fuzz_cmd.lua` (new), `cli/main.lua` (subcommand),
`tests/cli/fuzz_spec.lua` (26 tests).

---

## §B5 — Auto-docs site ✅ (2026-05-15)

`storybase docs [-o <path>] [--format html|md] <file.sb>` walks the typed AST
(`compiler.parse_and_check_file`), groups top-level declarations by kind, and emits
a static reference site. HTML mode (default) writes 14 pages (`index.html` plus one
per declaration kind) and a shared `style.css` into the output directory; the
sidebar shows per-kind counts and a static scene-graph listing on `scenes.html`
follows each scene's `->` / `=>` targets. Markdown mode writes a single `docs.md`
file with sections for every kind.

Doc strings attached to each declaration (§18.4) are surfaced as prose under each
heading. Macros — stripped by `expand_macros` before `parse_and_check_file` returns
— are recovered via a supplementary lex+parse pass on the raw source.

`M.build_pages(typed_ast, filename, format)` is exposed for tests and external use;
it returns `{pages = {[filename] = contents}, groups = {...}}` without touching the
filesystem.

**Files:** `cli/docs_cmd.lua` (new), `cli/main.lua` (subcommand + per-command
help), `docs/reference/cli.md` (entry), `tests/cli/docs_spec.lua` (21 tests).

---

## §F1 — `generate` blocks ✅ (2026-05-16)

Seed-deterministic procedural content. A new `generate <name> [seed: <path>]:`
top-level declaration runs once at engine init — after `init_defaults` and
`init_grids`, before the entry-scene is assigned. Two syntactic forms:

```
generate dungeon-layout seed: world/seed:
  let count = (random-int 3 6):
    spawn! rooms "alpha" `chamber
    relate! exits "alpha" "beta"

generate setup:           # no seed clause — uses engine's current RNG
  set! world/ready true
```

With `seed:`, the engine reads the Int at that state path and calls
`rng:seed(value)` before the body runs, so identical seed values produce
identical worlds independent of the engine-level `--seed`. All mutations flow
through the transaction log, so saved games replay the *generated* world
without re-running the generate block (verified by a dedicated round-trip
test).

**Files:** `compiler/lexer.lua` (`generate` keyword), `compiler/ast.lua`
(`GENERATE_DECL` kind + constructor), `compiler/parser.lua`
(`parse_generate_decl` + dispatch wiring), `compiler/checker.lua`
(symtab.generates registration + iteration in passes 5, undefined-paths,
undefined-fns, undefined-read-paths, invalid-enum-writes, undefined-families,
scene-targets), `compiler/codegen.lua` (`emit_generates` →
`game_table.generates`), `runtime/engine.lua` (`eng:run_generates()` + call
from `eng:init()`), `tests/compiler/generate_spec.lua` (8 tests),
`tests/runtime/generate_spec.lua` (6 tests),
`demos/demo23_procedural_dungeon.sb`.

## §F2 — `ending` declarations ✅ (2026-05-16)

Verifiable end-state declarations:

```
ending escape when: player/escaped and player/alive:
  "You step into the daylight."

ending lost when: not player/alive:
  "Your light goes out."
```

The engine evaluates every ending's `when_expr` on each step (pre-prompt and
post-action). The first true ending in declaration order renders its body
via `_render_narration_items` and terminates the game loop with
`eng._ended_at = <name>`.

The compiler auto-emits two kinds of verify blocks per ending set:

| Auto-verify | Clause kind | Meaning |
|-------------|-------------|---------|
| `ending '<n>' is reachable` | `eventually` (EF) | the ending's `when_expr` is reachable from the entry scene |
| `endings '<a>' and '<b>' are mutually exclusive` | `always` (AG) | no reachable state satisfies both `when_expr` simultaneously |

These auto-verifies use the existing verify-block infrastructure and are
stripped along with hand-written verifies in production builds.

**Keyword conflict mitigation:** older demos use `ending` as an ordinary
scene name (e.g. `demos/demo05_siege.sb` uses `-> ending`). The parser's
`parse_scene_goto` / `parse_scene_enter` were widened to accept KEYWORD
tokens as the target identifier so those demos compile unchanged.

**Files:** `compiler/lexer.lua` (`ending` keyword), `compiler/ast.lua`
(`ENDING_DECL` kind + constructor), `compiler/parser.lua`
(`parse_ending_decl` + dispatch wiring + scene-goto/enter keyword target
relaxation), `compiler/checker.lua` (symtab.endings registration +
when_expr/body iteration in undefined-fns / undefined-read-paths /
scene-targets / pass5), `compiler/codegen.lua` (`emit_endings` +
`emit_ending_verifies` synthesising auto-verify entries),
`runtime/engine.lua` (`eng:check_ending()`, `eng:_render_ending()`, two
ending checks inside `eng:step()`),
`tests/compiler/ending_spec.lua` (9 tests),
`tests/runtime/ending_spec.lua` (9 tests), `demos/demo23_procedural_dungeon.sb`.

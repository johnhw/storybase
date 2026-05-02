# StoryBase — Completed Work

Historical record of all completed implementation phases, demos, and spec-gap passes.
Active tasks are in [todo.md](todo.md).

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

## Previously Noted Deviations from Plan

- **`types.lua` not created.** Type expression parsing is in `compiler/parser.lua`; type descriptors and state-space size computation are in `compiler/codegen.lua`. A separate file was not needed.
- **`runtime/eval.lua` added.** Not in original plan; cleanly separates AST interpretation from engine turn-loop concerns. Scene navigation uses `ctx.signal` (not Lua exceptions).
- **Debug server uses TCP/NDJSON**, not WebSocket as `idea.md §18.1` specifies. Protocol difference is intentional for simplicity; `idea.md` spec not updated.
- **`as Alias` import namespacing** — parser parses `as` but resolver performs a flat merge. Noted as a known gap; enforcement deferred to active tasks.

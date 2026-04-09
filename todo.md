
# StoryBase — Implementation TODO

Phases follow [implementation.md](implementation.md). Check off items as they are completed.
Milestone goals are marked **M**.

---

## Current Status and Next Steps (2026-04-09)

**CLEANUP MODE (ongoing):** All new feature development is paused. Working through every outstanding `[ ]` item top-to-bottom. No deferrals. Each item gets implemented with tests and committed before moving to the next.

**Phase 7/8 in progress** — 1062 tests passing.

**Completed this session (2026-04-09, search engine pass):**
- Search engine — all 12 outstanding `[ ]` items resolved:
  - Scheduled event successors: `clone_cache` includes `_time` as `__time/<axis>` flat keys; `restore_engine` restores them; autonomous tick successor added in `can_reach` and `find_path`
  - Random source branching: `_random_inject` hook in eval.lua `random-int` handler; `trace_random_calls` + `random_outcome_combos` in search.lua enumerate all random outcomes
  - Approximate-result annotation: `probability()` now returns `(prob, approximate)` where `approximate=true` if any branch was pruned
  - Best-first search: `strategy="best-first"` with optional `heuristic(cache)→number` 8th parameter
  - Coroutine iterator: `M.make_iterator()` — coroutine.wrap BFS that yields `(cache, path)` for each matching state
  - Wall-clock budget: added to `probability` and `optimal_path`
  - Fuzz tests: `tests/fuzz/search_fuzz_spec.lua` with 6 property tests
- 16 new tests added (1046 → 1062)

**Next:** Continue with next unchecked `[ ]` items in todo.md after search engine section (line ~604 onward).

**Milestones met:** Phase 1 ✅ Phase 2 ✅ Phase 3 ✅ Phase 4 ✅ Phase 5 (partial) ✅ Phase 6 (partial) ✅ Phase 7 (partial) ✅

**Completed this session (2026-04-05, cleanup pass):**
- Phase 4 block — all outstanding items resolved (979 tests):
  - Perception snapshot compiler rule: pass4_check_perceives (was done, checkbox updated)
  - Conflict logging: actors.lua:apply_deferred logs kind="conflict" (was done, checkbox updated)
  - offset: and schedule! (were done in Phase 6, checkboxes updated)
  - Schedule creation in log: eval.lua logs schedule_created on schedule!
  - Schedule fired in log: now includes schedule_name + next_fire for replay
  - Schedule cancel in log: was done, checkbox updated
  - scheduler:replay_log() — reconstructs dynamic schedule state on load
  - engine.lua: calls replay_log on load path
  - NPC speed modeling: engine-config npc-speed:N runs N extra post_action per player turn
  - Autonomous turn: was done (engine:autonomous_turn), checkbox updated
  - Tests added: perceived enforcement, conflict logging, offset×2, schedule_created log, NPC speed×2
  - Integration scenario 4: deliver ore to blacksmith (integration_spec.lua)

**Completed this session (2026-04-04):**
- Indexed list access `path[n]` / `ident[n]` — parser + eval
- Debug TCP transport: proper socket setup, non-blocking poll, JSON codec (encode + decode)
- `clamp-event` debug hook — state.lua `_clamp_hook`, wired in engine `set_debug_server`
- Perceives enforcement: runtime perception snapshot + checker pass4 PERCEIVES_VIOLATION warning
- `find-path` BFS returning action sequence — search.lua + eval builtin
- `verify-always` builtin — returns Bool (true if invariant holds in all reachable states)
- `find-counterexample` builtin — returns frozen GameState at violation or nil
- Counterexample detail in verify failures — `counterexample` table + human-readable fail_msg
- `simulate: true` in counterfactual — runs actor behaviors + scheduler on copy
- `optimal-path` Dijkstra search — search.lua + 3 tests (1-step optimal, nil unreachable, empty initial)
- `code_map.md` created — comprehensive codebase navigation index
- Checker pass 5: discrete/superficial boundary enforcement — SUPERFICIAL_IN_COND + RANDOM_SUPERFICIAL warnings
- Checker pass 6: write-set analysis — WRITE_UNTYPED_VAR warnings, WRITE_DYNAMIC_PATH errors, write_set annotation on FN_DECL/SCENE_DECL; loop-var SymbolOf inference for `for v in (path-list family)`
- Lua interop API (`lib/storybase.lua`): sb.load/from_source, game:init/render/choose/call/eval/get/set/tick/save/load/on
- Integration scenarios 1-7 (village walk, combat, guarded shop, save/load, random seeds, schedule, actor messaging)
- Fixed engine seed: `engine_mod.new(gt, {seed=N})` now applies math.randomseed(N)
- `storybase extract-symbols <file>` CLI command — walks typed AST, groups SYMBOL_LIT by write target, suggests enum type declarations
- `compiler.parse_and_check` / `parse_and_check_file` — new pipeline entry point returning typed AST (stops before codegen), used by extract-symbols
- `game:find(family, opts)` Lua interop — filters, sorts, limits, counts entity family keys
- `storybase compact <game.sb> <save.log>` CLI — collapses full log into snapshot entries for fast replay
- `game:counterfactual(fn)` Lua interop — isolated branch, fn mutates copy, returns frozen snapshot
- `log:query_at(path, time)` — seq-number and axis-table time bounds implemented
- Import resolver: `import "file.sb"` splices declarations before checker, with cycle detection (IMPORT_CYCLE error), transitive imports
- Demo games: `demo_games.md` spec written; `demo01_wanderer.sb`, `demo02_merchant.sb`, `demo03_quest.sb` implemented and runnable
- BUGFIX: `pre:` condition eval — `expr_stmt` wrapper was not unwrapped before `eval_expr`, causing all pre-conditions to always fail; fixed in `runtime/eval.lua`
- BUGFIX: `path-exists?` builtin — was calling `eval_expr` on PATH_EXPR arg returning the value (e.g. integer), not the path string; now uses `eval_path` when arg is PATH_EXPR/INTERP_PATH
- BUGFIX: `when_stmt` in scene body narration — `render_scene` never handled `when_stmt`, causing conditional narration to silently vanish; added `_render_narration_items` helper and wired `when_stmt`/`if_expr` through it
- Demo games: `demo04_expedition.sb` implemented and runnable (entity families, spawn/despawn, for loops, path-exists?, count-where)
- Demo games: `demo05_siege.sb` implemented and runnable (time-model, actor, send!, behavior/inbox, schedule, cancel-schedule!, verify-always)
- Tests: +153 new tests (741→894)

**Completed this session (Phase 8):**
- Production build mode: `compiler.compile(src, file, {production=true})` strips watches + verifies from game table; `--production` CLI flag now works; `BOOL_FLAGS` set in parse_args prevents flag eating positional args
- Conflict logging in transaction log: `actors.lua:apply_deferred` logs `kind="conflict"` entries when higher-priority actor already claimed a set/clear path
- Schedule events in transaction log: `scheduler.lua:tick` logs `kind="schedule_fired"` on fire; `sched:cancel` logs `kind="cancel_schedule"` on cancel
- `state.lua:replay` updated to skip metadata entries (`checkpoint`, `conflict`, `schedule_fired`, `cancel_schedule`) so they don't corrupt state reconstruction
- `storybase help <subcommand>`: per-subcommand help text for all 6 commands; `help run`, `help verify`, etc.
- Search engine time-budget: `can_reach`/`find_path` accept optional `budget` parameter (seconds); returns (false, true) on timeout; `can-reach?` and `find-path` builtins accept `budget:` named arg; check every 50 iterations
- Tests: +6 new tests (900 total)

**Remaining gaps (Phase 8):**
- `as Alias` namespacing for imports (currently flat merge; parser parses `as` but resolver ignores it)
- Hygienic macro system (`macro` declarations, expansion before type-check)
- Tile grid extension (`defgrid`, spatial queries)

---

## Phase 1 — Core Language (Lexer, Parser, Basic Checker)

**M Goal:** `storybase compile game.sb` produces a valid compiled table for a schema-only file.

### Scaffold

- [x] Create directory structure: `compiler/`, `runtime/`, `cli/`, `lib/`, `tests/`
- [x] `compiler/ast.lua` — node constructor pattern; all declaration, expression, and statement kinds
- [x] `compiler/compiler.lua` — pipeline orchestrator (lexer → parser → checker → codegen)
- [x] `cli/main.lua` — entry point, command dispatch
- [x] Structured error table format `{code, message, file, line, col, note}`
- [x] Error accumulator (collect all errors; no early exit)
- [x] Warning support alongside errors

### Lexer (`compiler/lexer.lua`) ✅ DONE (2026-03-25)

- [x] LPEG imports and module scaffold
- [x] INDENT/DEDENT pre-pass (convert indentation to explicit tokens)
- [x] Token: integers (positive and negative)
- [x] Token: floats
- [x] Token: booleans (`true` / `false`)
- [x] Token: single-line strings with escape sequences (`\n`, `\\`, `\"`)
- [x] Token: multi-line strings (`"""..."""`) with indentation stripping
- [x] Token: symbol literals (`'name`)
- [x] Token: paths (any token containing `/`)
- [x] Token: path with variable interpolation (`{var}` segment)
- [x] Token: named arguments (`name:`)
- [x] Token: infix operators (`=`, `!=`, `<`, `>`, `<=`, `>=`, `+`, `-`, `*`, `/`, `??`)
- [x] Token: boolean operators (`and`, `or`, `not`)
- [x] Token: keywords (`fn`, `state`, `type`, `scene`, `when`, `if`, `else`, `match`, `cond`, `for`, `while`, `let`, `in`, `with`, `import`, `module`, `relation`, `actor`, `schedule`, `bounded`, `macro`, `verify`, `watch`, `watch-when`, `pre`, `post`, `tags`, `true`, `false`, `pass`)
- [x] Token: identifiers (`kebab-case`)
- [x] Token: block sigils (`*`, `->`, `=>`, `<-`)
- [x] Token: collection delimiters (`{`, `}`, `[`, `]`, `(`, `)`)
- [x] Whitespace stripping (spaces, blank lines)
- [x] Comment stripping (`#` to end of line)
- [x] Source position `(file, line, col)` attached to every token
- [x] Error: unterminated string literal
- [x] Error: illegal character
- [x] Error: mixed tabs and spaces

### Parser (`compiler/parser.lua`) — declarations only  ✅ DONE (2026-03-25)

- [x] Module header: `module name version: N`
- [x] `import "file"` (flat)
- [x] `import "file" as Alias` (namespaced)
- [x] Import cycle detection (IMPORT_CYCLE error) — done (2026-04-04)
- [x] `schema-version: N`
- [x] `engine-config:` block with all known keys
- [x] `time-model:` block (`axes:`, `wrap:`)
- [x] `type Name = val | val | ...` (enum)
- [x] `type Name = TypeExpr` (range alias)
- [x] `type Name:` record with `field: Type = default` lines
- [x] `with OtherRecord` mixin inside record
- [x] `type Name:` variant with `| branch: fields` lines
- [x] `state path: Type` (scalar)
- [x] `state path: Type = Constructor(...)` (with default)
- [x] `state path:` inline record block
- [x] `state family/{var}: Type  max: N` (entity family)
- [x] `relation name: T -> Set(T, N):` with optional static data block
- [x] Doc string (string literal immediately before any declaration)
- [x] Error recovery: parser continues after a bad declaration

Note: type expressions (Bool, Int, Enum, Option, Set, List, Symbol, SymbolOf,
String, Float, UList, UMap, named, function) are parsed directly in parser.lua.
A separate types.lua is not needed for Phase 1.

### Type Expressions (`compiler/types.lua`) ✅ DONE inline — no separate file needed

> **Deviation:** A separate `types.lua` was not created. Type expression parsing is handled
> directly in `compiler/parser.lua` (`parse_type_expr`), type descriptors are emitted in
> `compiler/codegen.lua` (`emit_type_desc`), and state-space size computation lives in
> `compiler/codegen.lua` (`state_space_size`). The discrete/superficial tag is deferred to
> Phase 2 when it is actually needed for boundary enforcement.

- [x] `Bool`
- [x] `Int(min, max)`
- [x] `Enum(v1, v2, ...)` (inline)
- [x] `Option(T)`
- [x] `Set(T, max)`
- [x] `List(T, max)`
- [x] `Symbol` (untyped)
- [x] `SymbolOf(Family)`
- [x] `String`, `Float` (superficial)
- [x] `UList(T)`, `UMap(K, V)` (superficial unbounded)
- [x] `RecordName`, `VariantName` (declared named types)
- [x] `(T -> R)`, `(T U -> R)` (function/lambda types)
- [x] State-space size computation for all discrete types (in codegen.lua)
- [x] Discrete / superficial tag on every type — done (2026-04-05)

### Checker — Pass 1 (Schema Collection) ✅ DONE (2026-03-25)

- [x] Collect all declared type names into symbol table
- [x] Collect all state paths (scalar and family)
- [x] Collect all relation names
- [x] Collect all scene names (auto-generate `SceneId` enum) — done (2026-04-05)
- [x] Resolve forward references within the same compilation unit (pass1 collects all names before pass2 resolves)
- [x] Resolve imported names (flat merge; `as Alias` parsed but not namespaced) — done (2026-04-04)
- [x] Error: duplicate type/state/scene/relation name
- [x] Error: undefined type reference

### Checker — Pass 2 (Basic Type-Check) ✅ DONE (2026-03-25)

- [x] Field types reference declared types (or built-in type expressions)
- [x] Record field defaults are type-correct — done (2026-04-05)
- [x] `Int(min, max)` bounds well-formed (`min <= max`)
- [x] `with` mixin: all fields spliced at the `with` point
- [x] `with` mixin: default override accepted (override after mixin allowed; no error emitted)
- [x] `with` mixin: type override rejected — done (2026-04-05)
- [x] `with` mixin: conflicting field from two different `with` sources → error
- [x] Entity family `max: N` stored and used for state-space computation
- [x] `SymbolOf(Family)` — family name resolves to a declared entity family — done (2026-04-05)
- [x] `warn-untyped-symbol` for bare `Symbol` in any discrete position — done (2026-04-05)

### Codegen (`compiler/codegen.lua`) ✅ DONE (2026-03-26)

- [x] Emit compiled game table (serialisable Lua value)
- [x] Schema section: types, state paths, relations (scenes=0 in Phase 1)
- [x] Function stubs (fns/verifies/watches are empty tables in Phase 1)

### CLI — Phase 1 ✅ DONE (scaffolded with initial commit)

- [x] `storybase compile <file>` command
- [x] Print diagnostics to stderr with file/line/col
- [x] Exit code 0 on success, non-zero on any error
- [x] Print summary (type count, state path count, scenes, state-space size)

### Tests — Phase 1 ✅ DONE (2026-03-26)

- [x] `tests/compiler/lexer_spec.lua` — all token types
- [x] `tests/compiler/lexer_spec.lua` — indentation / INDENT / DEDENT
- [x] `tests/compiler/lexer_spec.lua` — source positions on all tokens
- [x] `tests/compiler/lexer_spec.lua` — error cases (unterminated, illegal char, mixed indent)
- [x] `tests/compiler/parser_spec.lua` — all declaration forms
- [x] `tests/compiler/parser_spec.lua` — module and import
- [x] `tests/compiler/parser_spec.lua` — error recovery (continues after bad declaration)
- [x] `tests/compiler/checker_spec.lua` — pass 1: undefined type reference
- [x] `tests/compiler/checker_spec.lua` — pass 1: duplicate name
- [x] `tests/compiler/checker_spec.lua` — pass 2: type mismatch in field default — done (2026-04-05)
- [x] `tests/compiler/checker_spec.lua` — pass 2: `with` mixin rules
- [x] `tests/compiler/checker_spec.lua` — pass 2: `warn-untyped-symbol` — done (2026-04-05)
- [x] `tests/compiler/codegen_spec.lua` — all schema section emitters (31 tests)

**M Milestone:** `tests/test01_minimal.sb` compiles without errors or warnings. ✅ DONE (2026-03-26)

---

## Phase 2 — Expressions, Functions, and the Type Boundary

**M Goal:** All function declarations type-check; the discrete/superficial boundary is enforced.

### Parser Extensions ✅ DONE (2026-03-30)

- [x] Infix comparisons with correct precedence (`*`/`/` > `+`/`-` > comparisons > `not` > `and` > `or` > `??`)
- [x] Prefix function calls (multi-argument, unbounded arity)
- [x] Nil-coalescing `??` (right side lazy)
- [x] Arithmetic operators (infix)
- [x] Inline path interpolation `{varname}` within a path segment
- [x] Collection literal: set `(set)` (empty), `[]` empty list
- [x] Collection literal: list `['a, 'b]`
- [x] Collection literal: set `{'a, 'b}` — done (2026-04-05)
- [x] Collection literal: map `{k: v, ...}` — done (2026-04-05)
- [x] `match expr: arm1: val, arm2: val, _: val` (expression and statement forms)
- [x] `cond: cond1: body, cond2: body, _: body` — done (Phase 3+)
- [x] `if cond: body` / `if cond: body else: body`
- [x] `when cond: body` (no else)
- [x] `for var in expr: body` — done (Phase 3+)
- [x] `while cond: body` — done (Phase 3+)
- [x] `let name = expr ...: body` — done (Phase 3+)
- [x] Lambda expression `fn(params): body` — done (already implemented; checkbox not updated; tests added 2026-04-05)
- [x] Function declaration `fn name args: body`
- [x] `pre:` and `post:` blocks inside function declarations
- [x] `tags: [name, ...]` inside function declarations (parsed/skipped)
- [x] `path@before` expression in `post:` blocks — done (already implemented; checkbox not updated)
- [x] All mutation primitives: `set!`, `inc!`, `dec!`, `add!`, `remove!`, `clear!`, `push!`, `pop!`
- [x] Relation mutations: `relate!`, `unrelate!`
- [x] `spawn!`, `despawn!`
- [x] `send!`
- [x] `time-inc!` — done (2026-04-02)
- [x] `undo!`, `undo! steps: N` (stub — no-op; full implementation deferred to Phase 5)
- [x] `cancel-schedule!` — done (2026-04-03)
- [x] Scene navigation sigils in scene bodies: `->`, `->()`, `=>`, `<-`
- [x] Indexed path access: `path[n]`, `path[-n]` (INDEX_EXPR in parser + eval) — slice `path[a:b]` deferred to Phase 8
- [x] Narration inline expressions: `{expr}` inside scene text lines

**Deviation:** `_` added to lexer `is_alpha` (required for wildcard in match arms; previously illegal char).
**Deviation:** `match subject:` where `subject` is a bare identifier: the lexer tokenises `name:` as `NAMED_ARG`; `parse_match_expr` now handles both forms.

### Checker — Pass 3 (Pure/Transaction Inference) ✅ DONE (2026-04-05)

- [x] Classify every function as pure or transaction — annotated on fn_decl as `is_transaction`
- [x] Pure: calls no mutation primitives directly (transitive call-graph deferred)
- [x] Transaction: calls any mutation primitive directly
- [x] Error (PURE_CALLS_MUT): mutation primitive in `pre:` or `post:` block
- [x] Transitive purity inference: fn calling transaction fn is promoted to transaction (2026-04-05)
- [x] Error (TRANSACTION_IN_PURE): pre:/post: block calls a transaction fn (2026-04-05)
- [x] Error (TRANSACTION_IN_FIND): transaction fn called inside `find where` clause (2026-04-05)
- [x] Error (TRANSACTION_IN_VERIFY): transaction fn called inside `verify` condition (2026-04-05)
- [x] Lambda purity rule (LAMBDA_CALLS_MUT) — lambdas may not contain mutation primitives
- [x] `uses-bounded` tag: auto-applied to fn calling a bounded computation (2026-04-05)

### Checker — Pass 4 (Write-Set Analysis)

- [x] Compute static write-set for every transaction function — done (implemented as pass6_write_sets)
- [x] `{var}` interpolation legal in write position — done (implemented as pass6_write_sets)
- [x] Error: untyped variable in write position — done (WRITE_UNTYPED_VAR warning in pass6_write_sets)

### Checker — Pass 5 (State-Space Computation)

- [x] Compute state-space size for all discrete types (done in Phase 1 codegen)
- [x] Total game state-space size reported in compile summary
- [x] `warn-untyped-symbol` for `Symbol` in any logic position — done (2026-04-05)

### Checker — Pass 7 (Contract Validation) ✅ DONE (2026-04-05)

- [x] Warning (PRE_NOT_BOOL): pre: condition is obviously non-boolean (literal/arithmetic) (2026-04-05)
- [x] Warning (POST_NOT_BOOL): post: condition is obviously non-boolean (literal/arithmetic) (2026-04-05)
- [x] Error (PATH_BEFORE_INVALID): path@before outside fn post: block or verify after: assertion (2026-04-05)

### Compiler Boundary Enforcement (partial: direct path checks only)

- [x] Warning (SUPERFICIAL_IN_COND): superficial path in comparison — done (pass5_check_boundary)
- [x] Warning (RANDOM_SUPERFICIAL): random assigned to superficial field — done (pass5_check_boundary)
- [ ] Warning (SUPERFICIAL_PARAM): superficial value passed to fn expecting discrete — deferred (needs full expression type inference)

### Codegen — Full Functions ✅ DONE (2026-04-01)

- [x] scene_count now correctly computed from AST (2026-03-30)
- [x] Emit fn bodies as raw AST trees (params, pre, post, body, is_transaction, doc)
- [x] Emit scene declarations (name, body as AST node list)
- [x] Emit actor declarations into `game_table.actors` (2026-04-02)
- [x] Emit schedule declarations into `game_table.schedules` (2026-04-02)
- [x] Emit verify/watch — done (2026-04-03)

### Tests — Phase 2 ✅ DONE (2026-03-30)

- [x] `tests/compiler/parser_spec.lua` — expression forms and operator precedence (63 tests added)
- [x] `tests/compiler/parser_spec.lua` — control flow: when/if/match (with wildcard)
- [x] `tests/compiler/parser_spec.lua` — all mutation primitives
- [x] `tests/compiler/parser_spec.lua` — fn declarations: params, pre:, post:, body
- [x] `tests/compiler/parser_spec.lua` — scene declarations: narration, choices, guards, goto, enter, exit
- [x] `tests/compiler/parser_spec.lua` — integration: test02/test03 parse without errors
- [x] `tests/compiler/checker_spec.lua` — pure/transaction inference (10 tests)
- [x] `tests/compiler/checker_spec.lua` — discrete/superficial boundary — done (checker pass 5 tests exist)
- [x] `tests/compiler/checker_spec.lua` — write-set analysis — done (checker pass 6 tests exist)

**M Milestone:** `tests/test02_choices.sb` and `tests/test03_types.sb` compile without errors. ✅ DONE (2026-03-30)

---

## Phase 3 — Runtime Core

**M Goal:** A game with player actions and scenes runs end-to-end with a correct transaction log.

### State Store (`runtime/state.lua`) ✅ DONE (2026-04-01)

- [x] Flat Lua table keyed by path string (the cache)
- [x] `get(path)` → value or nil for uninstantiated paths
- [x] `set!(path, value)` — update cache, append log entry
- [x] `inc!(path, amount)` — add with clamping to declared `Int(min, max)` range
- [x] `dec!(path, amount)` — subtract with clamping
- [x] `add!(path, value)` — add to Set; idempotent (no duplicate)
- [x] `remove!(path, value)` — remove from Set (no-op if absent)
- [x] `clear!(path)` — empty a Set or List
- [x] `push!(path, value)` — append to List
- [x] `pop!(path)` — remove and return last element of List; error if empty
- [x] Indexed List read: `path[n]` (positive and negative indices) — INDEX_EXPR in eval.lua
- [x] Indexed List write: `set! path[n] value` — done (2026-04-05)
- [x] List slice read: `path[a:b]` — done (2026-04-05)
- [x] `spawn!(family, key, record)` — instantiate family member; error if key exists
- [x] `despawn!(family, key)` — remove family member; subsequent reads return nil
- [x] `path-exists?(path)` — Bool predicate
- [x] `path-list(family)` — List of all instantiated keys
- [x] `clamp-event` hook fires in debug mode on every clamped inc!/dec! — done (already implemented; checkbox not updated)

### Transaction Log (`runtime/log.lua`) ✅ PARTIAL (2026-04-01)

- [x] Append log entry: `{seq, fn, path, old, new}`
- [x] Sequential numbering with no gaps
- [x] Atomic: cache update and log append happen together (no partial state)
- [x] `query-at(path, time)` — value at a specific time — implemented: seq-number and axis-table bounds (2026-04-04)
- [x] `query-history(path)` — ordered list of all changes for a path
- [x] `query-changes(path, last-n)` — most recent N changes
- [x] Serialise log to file (Lua table format) — done (log.serialise_entries, engine write_save)
- [x] Deserialise log file and replay to reconstruct cache — done (state_mod.replay, engine read_save)
- [x] Snapshot: save full cache state at a given sequence number — done (log.serialise_snapshot, state.replay_from_snapshot; 2026-04-05)
- [x] Load from snapshot + delta log (faster replay) — done (engine writes .snap alongside save; reads it on load; 2026-04-05)
- [x] Round-trip test: serialise → deserialise → identical cache — done (log_spec.lua, engine_spec.lua)

### Engine (`runtime/engine.lua`) — Core ✅ PARTIAL (2026-04-01)

- [x] Scene stack: push, pop, peek current scene
- [x] `scene-stack-max` enforcement (runtime error on overflow)
- [x] Recursive scene detection (compile warning) — done (pass_recursive_scenes in checker.lua; 2026-04-05)
- [x] `->` goto: transition without stack change
- [x] `->` computed goto: evaluate `SceneId` expression — done (Phase 3+; eval.lua SCENE_GOTO handles expr targets)
- [x] `=>` enter: push caller, transition to named scene
- [x] `<-` exit: pop stack, return to previous scene
- [x] `goto-scene!`, `enter-scene!`, `exit-scene!` imperative equivalents (via signals)
- [x] Scene rendering: emit narration lines to presentation layer
- [x] Scene conditional narration: `[cond] text` shown only when cond holds
- [x] Scene choices: enumerate with `*` sigil
- [x] Choice guard: `* [cond] text` hidden when cond is false
- [x] Player choice dispatch by index into the visible (not total) choice list
- [x] Inline narration expressions: evaluate `{expr}` and convert to display string
- [x] Time model: declare axes and wrap behaviour at startup — done (state.lua init_time from schema.time_model)
- [x] `time-inc!` with named axis and explicit value — done (Phase 3+)
- [x] Absolute time set via time literal — done (time-set! mutation; 2026-04-05)
- [x] Basic turn lifecycle: player action → post-action phases — done (full 6-step lifecycle in Phase 4)

### Save / Load ✅ DONE (2026-04-02)

- [x] `storybase run <file>` — compile, initialise state from defaults, start turn loop
- [x] Save: serialise log to a `.save` file — done (engine write_save, log.serialise_entries)
- [x] Load: deserialise log, replay to current state, resume — done (engine read_save, state_mod.replay)

### CLI — Phase 3 ✅ DONE (2026-04-01)

- [x] `storybase run <file>` command
- [x] Simple text REPL: display current scene narration and numbered choices
- [x] Accept choice index from stdin; dispatch to engine
- [x] `storybase run <file> --save <path>` / `--load <path>` — done (2026-04-02)

### Eval (`runtime/eval.lua`) ✅ DONE (2026-04-01) — NEW MODULE (deviation from plan)

> **Deviation:** A separate `runtime/eval.lua` tree-walking evaluator was added (not in original
> plan). It cleanly separates AST interpretation from engine turn-loop concerns and makes
> eval_spec.lua independent. Scene navigation uses `ctx.signal` (not Lua exceptions) so
> eval_stmts can stop cleanly after a scene transition.

- [x] `new_ctx(state, fns, fn_name)` — evaluation context with vars, signal slot
- [x] `eval_expr(node, ctx)` — all literal kinds, path_expr, interp_path, binary_op, unary_op,
  nil_coalesce, fn_call, if_expr, match_expr, cond_expr
- [x] `eval_stmt(node, ctx)` — when_stmt, for_stmt (basic), while_stmt, let_stmt, all mutations,
  scene_goto, scene_enter, scene_exit, pass_stmt, expr_stmt
- [x] `eval_stmts(stmts, ctx)` — stops early on signal
- [x] `eval_path(node, ctx)` — resolves interp_path segments from vars
- [x] `call_fn(name, args, ctx)` — user fns with pre-condition check; built-ins: min, max,
  path-list, count-where, any?, all?, random-int, tostring
- [x] `render_text(text, ctx)` — plain strings + inline_expr segments

### Tests — Phase 3 ✅ DONE (2026-04-01)

- [x] `tests/runtime/state_spec.lua` — get, set!, inc!/dec! clamping
- [x] `tests/runtime/state_spec.lua` — Set mutations (add!, remove!, clear!)
- [x] `tests/runtime/state_spec.lua` — List mutations (push!, pop!, empty-pop error)
- [x] `tests/runtime/state_spec.lua` — spawn!/despawn!, nil reads after despawn
- [x] `tests/runtime/state_spec.lua` — path-exists?, path-list, init_defaults
- [x] `tests/runtime/state_spec.lua` — transaction log: sequential numbering, query_history, query_changes
- [x] `tests/runtime/eval_spec.lua` — all literal types, path reads, interp_path
- [x] `tests/runtime/eval_spec.lua` — all binary/unary operators, nil_coalesce
- [x] `tests/runtime/eval_spec.lua` — if_expr, when_stmt, set_mut/inc_mut/dec_mut
- [x] `tests/runtime/eval_spec.lua` — scene navigation signals; eval_stmts stops on signal
- [x] `tests/runtime/eval_spec.lua` — user fn calls, pre-condition failure, built-in min/max
- [x] `tests/runtime/eval_spec.lua` — render_text with inline_expr
- [x] `tests/runtime/engine_spec.lua` — scene stack push/pop/goto/enter/exit/overflow
- [x] `tests/runtime/engine_spec.lua` — compile + run test02_choices.sb integration tests
- [x] `tests/runtime/engine_spec.lua` — choice guard evaluation (visible index dispatch)
- [x] `tests/runtime/engine_spec.lua` — goto signal returned; log records state change
- [x] `tests/runtime/engine_spec.lua` — simulated turn loop (2-turn sequence)
- [x] `tests/runtime/log_spec.lua` — serialise → deserialise → identical cache — done (2026-04-03)
- [x] `tests/runtime/engine_spec.lua` — save/load round-trip test — done (2026-04-03)
- [x] Integration scenario 1: player walks village → forest → dungeon (2026-04-04)
- [x] Integration scenario 2: combat state machine (attack, potion, flee) (2026-04-04)
- [x] Integration scenario 3: buy potion with gold guard (2026-04-04)

**M Milestone:** `test02_choices.sb` runs end-to-end with correct transaction log. ✅ DONE (2026-04-01)

**M Milestone (pending):** `tests/test04_control_flow.sb` and `tests/test05_log_and_time.sb`
(excluding verify/schedule) run interactively.

---

## Phase 4 — Actors, Messaging, and Scheduling ✅ DONE (2026-04-02/03)

**M Goal:** The §25 complete example runs including actor behaviors and the morning reset schedule.

### Actors (`runtime/actors.lua`) ✅ DONE

- [x] Actor registration at load time (from compiled game table)
- [x] Perception snapshot: behavior reads delegate to real state via capture proxy (full perceives filtering deferred to Phase 6)
- [x] Perception snapshot: enforce compiler rule (behavior fn may only read perceived paths) — done (pass4_check_perceives in checker.lua; 2026-04-05)
- [x] Behavior function dispatch: call behavior fn with proxy as read/capture context
- [x] Deferred mutation queue: collect all writes from all behavior functions
- [x] Conflict detection: two actors writing the same path in the same turn
- [x] Conflict resolution: higher-priority actor's write wins (set/clear); all apply (inc/dec/collection)
- [x] Conflict logging: all conflicts appended to transaction log — done (actors.lua:apply_deferred; 2026-04-05)
- [x] `send!` — enqueue typed `ActorMsg` to named actor's inbox
- [x] Inbox bounded (`List(ActorMsg, N)`): runtime error if inbox is full (2026-04-03)
- [x] Message delivery step: move pending messages from send queue into inboxes
- [x] Inbox clearing at end of each turn
- [x] Unhandled inbox messages are dropped (no dead-letter queue)
- [x] Variant pattern matching for inbox messages (`match msg: branch {fields}: ...`)

### Scheduler (`runtime/scheduler.lua`) ✅ DONE

- [x] Static `schedule` declarations registered at load time
- [x] `every: [axis: +N]` trigger: fire at regular intervals
- [x] `at: [axis: N]` trigger: fire once at absolute time
- [x] `offset: [axis: N]` applied to `every:` triggers — done (scheduler.lua:register; 2026-04-03)
- [x] `schedule!` imperative: create a named scheduled event from within a transaction fn — done (eval.lua SCHEDULE_MUT; 2026-04-03)
- [x] `cancel-schedule!` imperative: cancel a named scheduled event (2026-04-03)
- [x] Pending schedule queue is itself discrete logged state — done (schedule_created logged; scheduler:replay_log on load; 2026-04-05)
- [x] Schedule creation and cancellation appear in the transaction log — done (schedule_created + cancel_schedule entries; 2026-04-05)
- [x] Scheduled event appears in the log when it fires — done (schedule_fired entry with schedule_name + next_fire; 2026-04-05)

### Engine — Full Turn Lifecycle ✅ DONE

- [x] Step 1: Player action (optional — skipped for autonomous turns)
- [x] Step 2: Message delivery (pending → inboxes)
- [x] Step 3: Actor behaviors dispatched in priority order; mutations deferred
- [x] Step 4: Deferred mutations applied in priority order
- [x] Step 5: Scheduled events whose trigger time has arrived are fired
- [x] Step 6: Inbox clearing
- [x] Autonomous turn (no player input): steps 2–6 only — done (engine:autonomous_turn(); 2026-04-04)
- [x] NPC speed modelling: run N autonomous turns per player turn — done (engine-config npc-speed; 2026-04-05)

### Tests — Phase 4 ✅ DONE

- [x] `tests/runtime/actors_spec.lua` — capture proxy (basic delegation test)
- [x] `tests/runtime/actors_spec.lua` — perceived vs. unperceived path enforcement — done (capture proxy returns nil; 2026-04-05)
- [x] `tests/runtime/actors_spec.lua` — deferred mutations applied after all behaviors
- [x] `tests/runtime/actors_spec.lua` — conflict detection and priority resolution
- [x] `tests/runtime/actors_spec.lua` — conflict logging — done (log has kind="conflict"; 2026-04-05)
- [x] `tests/runtime/actors_spec.lua` — inbox overflow runtime error (2026-04-03)
- [x] `tests/runtime/actors_spec.lua` — inbox cleared each turn; unhandled msgs dropped
- [x] `tests/runtime/actors_spec.lua` — `every:` fires at correct intervals
- [x] `tests/runtime/actors_spec.lua` — `at:` fires once only
- [x] `tests/runtime/actors_spec.lua` — `offset:` applied correctly — done (2026-04-05)
- [x] `tests/runtime/actors_spec.lua` — `cancel-schedule!` prevents future fires (2026-04-03)
- [x] `tests/runtime/actors_spec.lua` — pending queue appears in log — done (schedule_created entry; 2026-04-05)
- [x] `tests/runtime/engine_spec.lua` — full six-step lifecycle (implicit in integration tests)
- [x] `tests/runtime/engine_spec.lua` — autonomous turn (steps 2–6 only) — tested via game:tick in integration_spec (2026-04-04)
- [x] Integration scenario 4: deliver ore to blacksmith — done (integration_spec.lua; 2026-04-05)
- [x] Integration scenario 5: random encounter with fixed seed (reproducible) (2026-04-04)
- [x] Integration scenario 6: morning reset schedule fires (2026-04-04)
- [x] Integration scenario 7: actor messaging (2026-04-04)

**M Milestone:** `tests/test06_actors.sb` runs correctly; §25 complete example runs end-to-end. ✅ DONE

---

## Phase 5 — Query and Future-State Search

**M Goal:** `storybase verify` passes all five verify blocks from §25.

### Query (`runtime/query.lua`)

- [x] `find family` base form (2026-04-03)
- [x] `where <condition>` clause (multiple clauses are ANDed) (2026-04-03)
- [x] `or-where <condition>` clause (disjunction with preceding where) (2026-04-03)
- [x] `within N hops of <relation> from <src>` reachability filter (2026-04-05)
- [x] `connected-to <path> via <relation>` any-hop adjacency filter (2026-04-05)
- [x] `order-by <path> asc|desc` sort (2026-04-03)
- [x] `limit N` cap result list (2026-04-03)
- [x] `count` return integer instead of list (2026-04-03)
- [x] `find` is a pure expression; result type is `List(SymbolOf(family), limit)` or `Int` (2026-04-03)
- [x] Relation query: `adjacent?` — Set of nodes 1 hop from source (2026-04-03)
- [x] Relation query: `reachable?` — Bool reachability check (2026-04-03)
- [x] Relation query: `reachable?` with `max-hops:` bound (2026-04-05)
- [x] Relation query: `shortest-path` — List of nodes (2026-04-03)
- [x] Relation query: `reachable-set` with `max-hops:` bound (2026-04-03)
- [x] Relation query: `inverse-adjacent?` — Set of nodes that lead into source (2026-04-03)

### Search Engine (`runtime/search.lua`)

- [x] State graph node: full cache snapshot identified by content hash (2026-04-03)
- [x] Cycle detection via content hash (do not re-expand visited nodes) (2026-04-03)
- [x] Successor function: enumerate all transaction functions reachable from current scene (2026-04-03)
- [x] Successor function: scheduled events pending at the current time (autonomous tick successor; time axes included in BFS state) (2026-04-09)
- [x] Successor function: actor behavior steps (as a single aggregate transition) (post_action) (2026-04-03)
- [x] Random source branching: one successor per outcome (trace-then-enumerate; random-int hook) (2026-04-09)
- [x] `bounded` computation branching: branch over declared `distribution` (2026-04-03)
- [x] Probability weight tracking and propagation along paths (probability() function) (2026-04-03)
- [x] Probability pruning: skip branches below configurable threshold (threshold param) (2026-04-03)
- [x] Approximate-result annotation when pruning has occurred (probability() returns (prob, approx)) (2026-04-09)
- [x] BFS search strategy (2026-04-03)
- [x] DFS search strategy (2026-04-03)
- [x] Best-first search strategy (configurable heuristic; strategy="best-first" + heuristic param) (2026-04-09)
- [x] `depth: N` parameter honoured by all search operations (2026-04-03)
- [x] `strategy:` parameter honoured by all search operations (bfs/dfs/best-first for can_reach/find_path) (2026-04-09)
- [x] Coroutine-based iterator at top-level suspension boundary (M.make_iterator) (2026-04-09)
- [x] Wall-clock time budget per search call (budget param on all search ops) (2026-04-09)
- [x] `can-reach? <condition>` — Bool (2026-04-03)
- [x] `can-reach?` with `depth:` (2026-04-03)
- [x] `find-path <condition>` — action sequence or nil (2026-04-03)
- [x] `verify-always <condition>` — Bool (holds in all BFS states to depth) (2026-04-03)
- [x] `find-counterexample <condition>` — failing state + path, or nil (2026-04-03)
- [x] `probability <condition> depth: N` — Float (2026-04-03)
- [x] `optimal-path <condition> by: min-turns` — optimal action sequence (2026-04-03)

### Verify Blocks

- [x] Compile `verify` declarations into test cases at load time (2026-04-03)
- [x] `from-any-state:` clause — parsed; treated as always-pass (deferred to Phase 6)
- [x] `when <cond>:` clause — parsed; treated as always-pass (deferred to Phase 6)
- [x] `requires <cond>` clause — skip verify if precondition not met (2026-04-03)
- [x] `after <transition>:` clause — apply transition then check assertions (2026-04-03)
- [x] `path@before` in `after:` blocks (2026-04-03)
- [x] Failure report: specific failing state + counterexample path (action sequence) — done (2026-04-05)

### CLI — Phase 5

- [x] `storybase verify <file>` command (2026-04-03)
- [x] Report pass / fail per named verify block (2026-04-03)
- [x] Print counterexample detail (state dump + action sequence) on failure — done (2026-04-05)
- [x] Exit code 0 if all pass, non-zero if any fail (2026-04-03)

### Tests — Phase 5

- [x] `tests/runtime/verify_spec.lua` — verify-always passes when invariant holds (2026-04-03)
- [x] `tests/runtime/verify_spec.lua` — verify-always fails when invariant violated (2026-04-03)
- [x] `tests/runtime/verify_spec.lua` — after-check passes with correct path@before assertion (2026-04-03)
- [x] `tests/runtime/verify_spec.lua` — after-check fails when assertion wrong (2026-04-03)
- [x] `tests/runtime/verify_spec.lua` — requires skips when precondition not met (2026-04-03)
- [x] `tests/runtime/verify_spec.lua` — requires runs when precondition met (2026-04-03)
- [x] `tests/runtime/verify_spec.lua` — multiple verify blocks reported independently (2026-04-03)
- [x] Integration: `storybase verify tests/test05_log_and_time.sb` — all 3 blocks pass (2026-04-03)
- [x] Integration: `storybase verify tests/test05_log_and_time.sb` — all 3 blocks pass ✅
- [x] `tests/runtime/search_spec.lua` — `can-reach?` BFS search (2026-04-03)
- [x] `tests/runtime/query_spec.lua` — `find`/`where`/`order-by`/`limit`/`count`, relation queries (2026-04-03)
- [x] `tests/compiler/parser_spec.lua` — find expression parsing, schedule! mutation (2026-04-03)
- [x] `tests/compiler/codegen_spec.lua` — bounded declarations (2026-04-03)
- [x] `tests/test06_actors.sb` verify blocks: `from-any-state`/`when` blocks fully validated — `storybase verify tests/test06_actors.sb` passes (2026-04-04)
- [x] `tests/runtime/search_spec.lua` — `find-path`, `probability`, `optimal_path` (2026-04-03)
- [x] `tests/fuzz/search_fuzz_spec.lua` — state-space coverage, BFS/DFS agreement, can_reach==find_path (2026-04-09)

**M Milestone:** `storybase verify tests/test05_log_and_time.sb` ✅ and `storybase verify tests/test06_actors.sb` (Phase 6, needs `can-reach?`).

---

## Phase 6 — Advanced Features + Phase 5 Overflow

**M Goal:** Counterfactuals, bounded computations, undo, and schema migration all work.
Also completing Phase 5 overflow: find/query engine, relation queries, `can-reach?`/`find-path`, `schedule!`.

### Phase 5 Overflow — Query Engine

- [x] `path-exists?` builtin in eval.lua (2026-04-03)
- [x] `find family` base form + `where`, `or-where`, `order-by`, `limit`, `count` clauses (2026-04-03)
- [x] Relation queries: `adjacent`, `reachable` (BFS), `shortest-path`, `reachable-set`, `inverse-adjacent` (2026-04-03)
- [x] `can-reach?` with `depth:` — Bool future-state BFS search (2026-04-03)
- [ ] `find-path` — action sequence or nil — Phase 7
- [ ] `probability` — Float — Phase 7
- [x] `schedule!` imperative: create a named scheduled event from within a fn (2026-04-03)
- [x] `offset:` applied to `every:` schedule triggers (2026-04-03)
- [x] `from-any-state:` clause in verify — runs check exprs from every BFS state (2026-04-03)
- [x] `when cond:` clause in verify — filters BFS states by condition (2026-04-03)

### Counterfactual (`runtime/eval.lua` — inline in eval_expr)

- [x] `counterfactual from: T do: transitions` — create branched GameState (2026-04-03)
- [x] Replay log to tick T then apply transition sequence to a private cache copy (2026-04-03)
- [x] `GameState` value is immutable (no side effects on live state) (2026-04-03)
- [x] `(in-state gs) path` — redirect a path read to the GameState copy (2026-04-03)
- [x] `(in-state gs)` redirect works in all pure query operations (`find`, `can-reach?`, etc.) (2026-04-06)
- [x] `find ... in-state: gs` clause — parser + eval; redirects find to snapshot cache (2026-04-06)
- [x] `simulate: true` — include actor steps and scheduled events in the branch (2026-04-06)
- [x] Nesting depth limit: enforce `max-counterfactual-depth` from engine-config (2026-04-06)
- [ ] GameState garbage-collected when it leaves scope
- [x] Log: append `counterfactual(from: T, transitions: [...])` entry (visible in debug) (2026-04-06)

### Bounded Computations

- [x] `bounded` declaration parsing: `returns:`, `distribution:`, `reads:`, `lua:` (2026-04-03)
- [x] Codegen emits `game_table.bounded` table with declaration metadata (2026-04-03)
- [x] Call dispatch in eval.lua: calls `game._bounded_handlers[name](arg, snap)` (2026-04-03)
- [x] Lua handler registration via `game:register_bounded(name, fn)` public API (2026-04-04, lib/storybase.lua)
- [ ] Log result as a random-draw entry `{source, result, seed}` — Phase 8
- [x] `uses-bounded` tag auto-applied to any function calling a `bounded` computation (2026-04-05, checker pass3b)
- [x] Search: branch over `uniform` distribution — BFS enumerates all Int outcomes (2026-04-06)
- [x] Search: branch over `conditioned-on path` distribution — same enumeration; conditioned-on treated as uniform for search purposes (2026-04-06)

### Undo

- [x] `undo!` — revert state to the most recent checkpoint (2026-04-03)
- [x] `undo! steps: N` — revert N checkpoints back (2026-04-03)
- [x] Append `undo` event to log (audit trail preserved) (2026-04-03)
- [x] Correctly identify checkpoint boundaries (functions tagged `[checkpoint]`) (2026-04-03)
- [x] Runtime error if no checkpoint exists in history (2026-04-03)
- [x] `tags: [checkpoint]` parsed in parser and emitted to compiled fns (2026-04-03)

### Schema Migration (`runtime/migrate.lua`)

- [x] `schema-version: N` declaration stored and compared on load (Phase 3)
- [x] `migration A -> B:` block parsing (2026-04-03)
- [x] `rename old-path -> new-path` — path renamed, value transferred (2026-04-03)
- [x] `add path = value` — new path initialised with value (2026-04-03)
- [x] `drop path` — path removed silently (2026-04-03)
- [x] `transform path: fn old: expr` — function applied to each matching value (2026-04-03)
- [x] `transform npcs/*/field:` — wildcard applied per family member (2026-04-03)
- [x] `rename-enum path old -> new` — enum literal renamed in a specific path (2026-04-03)
- [x] Apply migration chain in ascending version order (2026-04-03)
- [x] Error: save is at version N but migration N → N+1 is missing (2026-04-03)

### CLI — Phase 6

- [x] `storybase migrate <game.sb> <save.log>` — apply outstanding migrations, write upgraded copy (2026-04-03)

### Tests — Phase 6

- [x] `tests/runtime/counterfactual_spec.lua` — branched state differs from live state (2026-04-03)
- [x] `tests/runtime/counterfactual_spec.lua` — `(in-state)` path redirect (2026-04-03)
- [x] `tests/runtime/counterfactual_spec.lua` — mutations in branch do not affect live state (2026-04-03)
- [x] `tests/runtime/counterfactual_spec.lua` — `simulate: true` includes actor steps (2026-04-06)
- [x] `tests/runtime/counterfactual_spec.lua` — nesting depth limit enforced (2026-04-06)
- [x] `tests/runtime/counterfactual_spec.lua` — log entry appended (2026-04-06)
- [x] `tests/runtime/counterfactual_spec.lua` — `find ... in-state: gs` redirects to snapshot (2026-04-06)
- [ ] `tests/fuzz/counterfactual_fuzz_spec.lua` — isolation holds under random transitions
- [x] `tests/runtime/migrate_spec.lua` — rename (2026-04-03)
- [x] `tests/runtime/migrate_spec.lua` — add and drop (2026-04-03)
- [x] `tests/runtime/migrate_spec.lua` — rename-enum (2026-04-03)
- [x] `tests/runtime/migrate_spec.lua` — version chain applied in order (2026-04-03)
- [x] `tests/runtime/migrate_spec.lua` — missing intermediate version → error (2026-04-03)
- [x] `tests/runtime/migrate_spec.lua` — migration parsing round-trip (2026-04-03)
- [x] `tests/runtime/engine_spec.lua` — undo! reverts to checkpoint state (2026-04-03)
- [x] `tests/runtime/engine_spec.lua` — undo! steps: N reverts N checkpoints (2026-04-03)
- [x] `tests/runtime/engine_spec.lua` — undo! errors with no checkpoints (2026-04-03)
- [x] `tests/runtime/migrate_spec.lua` — transform (scalar and family wildcard) — done (2026-04-03)
- [x] Integration scenario 8: player dies, `undo!` restores pre-death state (2026-04-03)
- [x] Integration scenario 10: save → migrate → reload → state identical (2026-04-03)

---

## Phase 7 — Debug Tooling

**M Goal:** Full dev-mode experience: hot reload, time-travel, watches, WebSocket protocol.

### Debug Server (`runtime/debug.lua`)

- [x] TCP/WebSocket server stub (starts in "hook" mode; falls back if LuaSocket absent) (2026-04-03)
- [ ] Full TCP/WebSocket server (requires LuaSocket) — Phase 8
- [ ] Server disabled entirely in production builds — Phase 8
- [x] Newline-delimited JSON encoder (M.encode_json) (2026-04-03)
- [x] Emitted event: `mutation {path, old, new, fn, tick}` — wired via state._mutation_hook (2026-04-03)
- [x] Emitted event: `scene-change {from, to, stack, tick}` — wired via engine goto/enter/exit (2026-04-03)
- [ ] Emitted event: `message-sent {actor, msg, tick}` — Phase 8
- [ ] Emitted event: `schedule-fired {name, tick}` — Phase 8
- [ ] Emitted event: `fn-call {name, args, tick}` (dev mode only) — Phase 8
- [ ] Emitted event: `spawn-event {family, key, init, tick}` — Phase 8
- [ ] Emitted event: `despawn-event {family, key, tick}` — Phase 8
- [ ] Emitted event: `clamp-event {path, attempted, clamped, tick}` — Phase 8
- [ ] Emitted event: `reload {file, outcome, changes, tick}` — Phase 8
- [x] Accepted command: `get-state {pattern}` → `{path: value, ...}` (2026-04-03)
- [x] Accepted command: `eval {expr}` → value (pure expressions only) (2026-04-03)
- [x] Accepted command: `reload {src}` → outcome (hot-reload fns/scenes) (2026-04-03)
- [x] Accepted command: `set-breakpoint {condition}` → id (2026-04-03)
- [x] Accepted command: `clear-breakpoint {id}` (2026-04-03)
- [x] Accepted command: `time-travel {tick}` → frozen snapshot (live state unaffected) (2026-04-03)
- [x] Accepted command: `get-log {from, to}` → log entries (2026-04-03)

### Hot Reload

- [x] Function body changed: apply immediately; state preserved (2026-04-03)
- [ ] New field added to record type: initialise all existing instances with declared default — Phase 8
- [ ] Field removed from type: drop value silently — Phase 8
- [ ] Enum value added/removed: validation — Phase 8
- [ ] Type range narrowed: error if current state out of range — Phase 8
- [ ] All changes applied transactionally — Phase 8

### Watches and Doc Strings

- [x] `watch-when cond "label"` declaration: register_watch_when, fires on positive edge (2026-04-03)
- [x] `watch path "label"` declaration: register_watch, fires on non-nil value (2026-04-03)
- [ ] Watch declarations tagged `debug-only` and stripped from production builds — Phase 8
- [ ] Doc string surfacing — Phase 8

### Production Build Mode

- [ ] `debug-only` declarations stripped from compiled output — Phase 8
- [ ] `pre:` / `post:` contract blocks stripped (unless `strict-contracts: true`) — Phase 8
- [ ] `watch` / `watch-when` declarations stripped — Phase 8
- [ ] Debug server not started — Phase 8

### Tests — Phase 7

- [x] `tests/runtime/debug_spec.lua` — `get-state` pattern matching returns correct paths (2026-04-03)
- [x] `tests/runtime/debug_spec.lua` — `time-travel` returns frozen state; live state unchanged (2026-04-03)
- [x] `tests/runtime/debug_spec.lua` — reload function body: state preserved, new logic active (2026-04-03)
- [ ] `tests/runtime/debug_spec.lua` — reload enum value added/removed: validation — Phase 8
- [x] `tests/runtime/debug_spec.lua` — `watch-when` fires when condition becomes true (edge detection) (2026-04-03)
- [x] `tests/runtime/debug_spec.lua` — `watch` fires on matching mutation (2026-04-03)
- [x] `tests/runtime/debug_spec.lua` — mutation event received via on() handler (2026-04-03)
- [x] `tests/runtime/debug_spec.lua` — scene-change event emitted on goto_scene (2026-04-03)
- [x] `tests/runtime/debug_spec.lua` — breakpoint set/clear (2026-04-03)
- [x] `tests/runtime/debug_spec.lua` — get-log slicing (2026-04-03)

---

## Phase 8 — Macro System, Lua Interop, and Polish

**M Goal:** Full public API; macro system; performance acceptable for 20 NPCs at depth-50 search.

### Macro System

- [x] `macro name params: body` declaration parsing
- [x] Macro expansion pre-pass (before type-check)
- [x] Hygienic expansion (generated names do not collide with user names)
- [x] Error: macro in body expands another macro defined in the same compilation unit
- [x] Error: recursive macro invocation (direct or mutual)
- [x] Expanded form is what the type checker and log see

### Lua Interop (`lib/storybase.lua`)

- [x] `sb.load(file)` → game object (2026-04-04)
- [x] `sb.from_source(src, name)` → game object (2026-04-04)
- [x] `game:call(fn_name, arg1, ...)` — invoke transaction function (2026-04-04)
- [x] `game:get(path)` → current value (2026-04-04)
- [x] `game:find(family, opts)` → list of matching keys (opts: where fn, order_by, order_dir, limit, count) (2026-04-04)
- [x] `game:on(event_name, handler_fn)` — subscribe to debug/presentation events (2026-04-04)
- [x] `game:choose(index)` — dispatch player choice by visible index (2026-04-04)
- [x] `game:eval(expr_string)` → value (pure expressions only) (2026-04-04)
- [x] `game:counterfactual(fn)` → frozen snapshot — branch game, run fn(branch), return snapshot with :get/:current_scene (2026-04-04)
- [x] `game:register_bounded(name, lua_fn)` — register bounded computation handler (2026-04-04)

### CLI Polish

- [x] `storybase extract-symbols <file>` — scan symbol literals, output candidate `type` declaration (2026-04-04)
- [ ] `storybase compile --production` — emit production build (strips debug-only content)
- [x] `storybase run --seed N` — fix random seed for reproducible runs (already wired via engine opts) (2026-04-04)
- [x] `storybase compact <game.sb> <save.log>` — emit snapshot + delta log to reduce replay time (2026-04-04)
- [ ] `storybase help` / `--help` on all subcommands

### Performance

- [ ] State cache snapshot at every checkpoint (O(delta since snapshot) replay)
- [ ] Search engine inner loop uses explicit stack (not coroutines) for BFS/DFS
- [ ] Search engine coroutine used only at top-level suspension boundary
- [ ] Wall-clock time budget enforced per search call
- [ ] Benchmark: §25 complete example, 20 NPCs, `can-reach?` at depth 50 completes in < 10 s

### Tile Grid Extension (optional)

- [ ] `defgrid name: dimensions: W x H  cell-type: T` declaration
- [ ] Grid as discrete state (one `T` per cell)
- [ ] `visible-from? grid pos1 pos2` — raycasting Bool
- [ ] `within-range? grid pos1 pos2 range: N` — Bool
- [ ] `path-to grid pos1 pos2` — A* List of positions
- [ ] `occupied-by grid pos` — entity key or nil

### Tests — Phase 8

- [x] `tests/compiler/macro_spec.lua` — basic expansion
- [x] `tests/compiler/macro_spec.lua` — hygiene (no name collision)
- [x] `tests/compiler/macro_spec.lua` — same-unit expansion restriction enforced
- [x] `tests/compiler/macro_spec.lua` — recursive macro error
- [ ] `tests/lib/interop_spec.lua` — all public API methods: call, get, find, on, choose, eval
- [ ] `tests/lib/interop_spec.lua` — counterfactual API from Lua
- [ ] `tests/lib/interop_spec.lua` — register_bounded and call convention
- [ ] `tests/fuzz/parser_fuzz_spec.lua` — random token sequences never crash the parser
- [ ] `tests/fuzz/log_fuzz_spec.lua` — log replay is deterministic under random mutations
- [ ] Performance benchmark passes (20 NPCs, depth-50 search < 10 s)

**M Milestone:** All eight `tests/test0*.sb` files compile, run, and (where applicable) pass `storybase verify` without errors.

---

## Ongoing

- [ ] Every public function in every module has at least one passing and one failing test
- [ ] No module writes to Lua global state
- [ ] All files begin `local M = {}` and end `return M`
- [ ] Line length ≤ 120 characters throughout
- [ ] All error codes use `UPPER_SNAKE` constants defined in `compiler/ast.lua` or `runtime/engine.lua`
- [ ] `busted tests/` passes with zero failures before each phase milestone is signed off

## Long term tasks (after engine is stable)

- Write documentation, including a public API reference and a guide for writing games.
  - This should include an API spec (complete), a tutorial-style guide to writing games with the engine, a how-to guide, and a reference for the language syntax and semantics.
  - Read https://danielsieger.com/blog/2023/04/24/framework-for-better-documentation.html for ideas on structuring the documentation before starting. Write a summary of the key points in this todo list to guide the writing process.
  - Remember to create todo points for each aspect of the documentation.
  - The API spec should cover all public functions and their expected inputs, outputs, and side effects. It should also include examples of how to use each function in the context of a game.
  - The tutorial guide should walk through the process of creating a game from start to finish, demonstrating how to use the various features of the engine. It should start with a simple game and gradually introduce more complex features, showing how they can be used together to create engaging interactive fiction.
  - The language reference should provide a comprehensive overview of the syntax and semantics of the StoryBase language, including all expression forms, control flow constructs, mutation primitives, and scene declaration features. It should also include examples of each construct in use.
  - The documentation should be written in a clear and accessible style, with plenty of examples and explanations to help new users understand how to use the engine effectively. It should also be kept up to date with any changes or additions to the engine's features.

- Write a series of example games, from a very basic test toy to a relatively complete (but still basic) adventure with multiple scenes, NPCs, and a complex state machine.
  - To execute this task, write down specifications for each of the games (say 5), including a list of features that the game demonstrates. 
  - When designing the games, start with a simple "Hello World" style interactive fiction that demonstrates basic scene navigation and state mutation. Then incrementally add features in subsequent games, such as player choices, guards, transactions, actors with behaviors, scheduled events, and finally a game that uses the search and verify capabilities.
  - Choose a consistent theme and setting for the games (e.g., a fantasy adventure, a sci-fi exploration, a mystery puzzle) to make them more engaging and cohesive as a suite of examples.
  - *BEFORE WRITING ANY CODE* write down the specifications and plans for the games in `demo_games.md`, including a breakdown of which features are demonstrated in each game and how they build on each other.
  - Refine the specifications so that they are clear and detailed enough to guide the implementation phase, but avoid over-specifying to allow for creative freedom during development.
  - Then implement each game as a `demo*.sb` file, and add any missing features to the compiler/runtime as needed to support the game.
  - Annotate the game files with comments explaining how the features are implemented in the code, and how they interact with the engine.
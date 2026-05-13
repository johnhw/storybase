# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-12)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–21 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
Code review rounds 1, 2, and 3 fully resolved.
UI driver layer complete. All twelve authoring ergonomics issues (AE-1 through AE-12) resolved.

Author experience review (2026-05-10) identified 17 open issues in five categories (bugs,
silent failures, validation gaps, ergonomics, spec divergence). See sections below.

Bug #8 (formatter) resolved 2026-05-12. Comprehensive formatter test bank added
(`tests/cli/format_spec.lua`, 169 tests). The fix resolved Bug #8 plus ~18 additional
formatter field-name/structure bugs found by the new tests. Known remaining formatter
limitations: whitespace normalization in aligned narration (demo11), unhandled macro_decl
nodes (demo15 spellwright).

Bug #9 (parser crash on nil match arm) resolved 2026-05-12. Root cause: `MUTATION_TABLE`
lacked a forward declaration so `parse_match_expr` saw the global (nil) instead of the
local. Fixed with a forward declaration + secondary eol double-consume fix. 8 regression
tests added.

Bug #10 (`let x = expr:` scoped-body form) resolved 2026-05-12. Root cause: `parse_let_value`
called `parse_expr` and returned `colon_done=false` even when `parse_expr` internally
consumed a NAMED_ARG as its last token (the lexer folds `word:` into one token). Fixed by
checking `p.tokens[p.pos-1]` after `parse_expr` and setting `colon_done=true` if it was a
NAMED_ARG. 4 regression tests added.

Bug #13 (REPL stuck on computed-goto entry scenes) resolved 2026-05-12. Added
`game:advance_to_choices()` to `lib/storybase.lua` which follows computed gotos until
reaching a scene with displayable choices. Modified `render()` to return `nav_signal` as
third return value. Updated `cli/repl_cmd.lua` to call `advance_to_choices()` after
`game:init()` and after `:choose` to prevent getting stuck in dispatch scenes. 6
regression tests added.

Bug #11 (match without wildcard silently returns nil) resolved 2026-05-13.
Two-layer fix: (A) runtime warning emitted to `_print_sink` / stderr (suppressed in
production mode) when `eval_match` falls through with no matching arm; (B) new checker
pass `pass_check_match_completeness` that walks fn/scene bodies for MATCH_EXPR nodes
whose subject is a typed PATH_EXPR over a named or inline enum, and emits
`INCOMPLETE_MATCH` warning when not all enum values have arms and no wildcard is present.
Added `INCOMPLETE_MATCH` to `ast.E`. 9 regression tests added (4 eval_spec, 6
checker_spec counting both pass and no-warn cases).

Bug #12 (non-lambda `find where:` predicate with variable name ≠ family name) resolved
2026-05-13. Root cause: `query.lua:M.find` bound only `[family] = key` in the child
context; if the condition used a different interpolation variable (e.g. `{m}` in
`find members where: members/{m}/...`), that variable was unbound and fell back to the
literal string, making the condition evaluate identically for all entities. Fix:
`collect_interp_vars` pre-scans all where-condition AST nodes for single-segment interp
variable names and binds all unresolved ones to the entity key in the child context.
Parent-context vars are never overridden. 6 regression tests added (query_spec).

SF-1 (zero-arg undefined function calls silently return a string) resolved 2026-05-13.
Option A: in `runtime/eval.lua:call_fn`, when a 0-arg call falls through to the
bare-string return, emit a dev-mode `[WARN]` (suppressed in production). Suppression
logic lazily builds `game._known_bare_names` from: relation names, grid names, scene
names, named types, family names, and single-segment scalar/record state paths — all
valid non-function bare-identifier uses. Also added `pure` as a silent no-op (it is a
purity annotation that has no runtime semantics). 10 regression tests added (eval_spec).

SF-2 (invalid enum values assigned without error) resolved 2026-05-13.
Option C (A+B combined): (A) `runtime/state.lua` — `get_enum_values(type_desc, schema)`
resolves inline enums (`tag="enum"`), named enum references (`tag="named"`), and alias
chains; `warn_invalid_enum(store, path, value)` called from `store:set` emits dev-mode
`[WARN]` when a string value is not in the resolved enum values set. Handles family
member field paths via `lookup_type`. Suppressed in production mode.
(B) `compiler/checker.lua` — new `pass_check_invalid_enum_writes` pass; walks SET_MUT
nodes with SYMBOL_LIT values on static PATH_EXPR paths; resolves the path type via
`build_path_type_map`; resolves inline enums, named enums, and TYPE_ALIAS chains via
`get_enum_values_checker`; emits `INVALID_ENUM_VALUE` warning. INTERP_PATH paths skipped
(covered by runtime check). `MUT_PATH_KINDS` and `walk_mut_with_path` refactored to a
shared helper section used by both SF-2 and SF-3 passes.
16 regression tests added (8 state_spec runtime, 8 checker_spec compile-time).

SF-3 (writes to undefined state paths silently no-op) resolved 2026-05-13.
Option C (A + B): (A) `runtime/state.lua` — `warn_undeclared` helper added before
every mutation method (set, inc, dec, add, remove, clear, push, pop); checks path via
`lookup_type(_type_index, path)` in dev mode and emits warning. Guards: production flag,
`_schema_has_states` sentinel (cached before actor inbox registrations to avoid false
positives when actors add paths to an otherwise-empty type_index), `__` prefix paths
(engine-internal like `__rel/edges/`). Engine propagates `_production` and `_print_sink`
to store; `actors.lua:register` adds inbox paths to `_type_index` to exempt them.
(B) `compiler/checker.lua` — new `pass_check_undefined_paths` pass walks all mutation
nodes in fn/scene/schedule/hook bodies; for static PATH_EXPR paths checks against
`build_path_type_map` and `symtab.families`; emits `UNDEFINED_PATH` warning; skips
INTERP_PATH (dynamic) and INDEX_EXPR/SLICE_EXPR by unwrapping to base.
16 regression tests added (8 state_spec for runtime, 8 checker_spec for compile-time).

All four compile-time validation gaps (AV-1 through AV-4) resolved 2026-05-13.

AE-15 (multi-line find inside parens) resolved 2026-05-13. Root cause: lexer emits no
INDENT/DEDENT inside `()`, so the parser's NEWLINE+INDENT detect path was never taken
for paren-context multi-line finds. Fix: added newline-skipping clause continuation path
in `compiler/parser.lua:parse_find_clauses_inline`. 6 regression tests added.

AE-17 (integer division / floor / ceil / remainder) resolved 2026-05-13. Added `int-div`,
`floor`, `ceil`, `mod` builtins. `mod` uses floor-division remainder (Python sign
convention). 11 regression tests added.

AV-1: `pass_check_undefined_fns` walks all FN_CALL nodes with full scope tracking
(sequential let bindings, scoped let forms, lambda params, for-loop vars, variant
field destructuring). CHECKER_BUILTIN_FNS table mirrors eval.lua BUILTINS.
AV-2: `pass_check_scene_targets` checks all SCENE_GOTO/SCENE_ENTER string literal
targets and engine-config entry-scene against declared scenes.
AV-3: Extended `pass_check_invalid_enum_writes` to cover ADD_MUT/REMOVE_MUT on
Set(Enum) paths by unwrapping the Set inner type.
AV-4: `pass_check_undefined_read_paths` checks PATH_EXPR nodes in read (expression)
positions using a conservative guard (only when first segment is a known state root
or prefix) to avoid false positives from for-loop variable field accesses.
Also fixed `build_path_type_map` to expand WITH_MIXIN fields recursively.
23 new regression tests added (checker_spec). Zero false positives on all demos.

**2383 tests passing, 0 failing, 2 pending (known limitations).**

---

## What to work on next

Recommended order:
1. **Silent-failure hazards** (SF-5) — SF-1 through SF-4 resolved.
2. **Spec divergence** (SD-1) — align `find` block syntax with documentation.
3. All AE issues (AE-13 through AE-17) are now resolved.

---

## Remaining Open Work

- [ ] **Inelegance #7** — BFS expansion logic duplicated ~5×. Deferred: each BFS function
  has a different data payload (priority/path/prob/cost) and queue mechanism
  (FIFO/heap/yield). Extracting a shared helper would require a messy callback strategy and
  add more complexity than it removes.

---

## Critical Bugs (data loss / internal crash)

- [x] **Bug #8 — Formatter drops relation static data.** *(fixed 2026-05-12)*
  `storybase format --write` on a file containing a `relation` with a static data block
  emits only the bare `relation name` header; all initial edges are lost. Any author using
  `--write` destroys their map graph permanently with no warning.

  **Fix applied:** `cli/format_cmd.lua` RELATION_DECL handler now correctly emits
  `from_type`, `to_type_expr`, and `initial_data` edges. Also exported `M.format_string`
  for testing, and fixed ~18 additional field-name/structure bugs discovered by the new
  test bank (`tests/cli/format_spec.lua`, 169 tests).

- [x] **Bug #9 — Parser internal error on `nil` as a match arm value.** *(fixed 2026-05-12)*
  Writing `_: nil` (or any arm whose value started with an IDENT token) in an inline
  `match` arm caused `attempt to index a nil value (global 'MUTATION_TABLE')`.

  **Root cause:** `MUTATION_TABLE` was declared as a `local` at line 1828 in
  `compiler/parser.lua`, but `parse_match_expr` was defined at line 1226. Without a
  forward declaration, `MUTATION_TABLE` inside the function resolved to the global
  (nil), crashing on any IDENT-valued arm body.

  **Fix:** Added `local MUTATION_TABLE` forward declaration before `parse_match_expr`
  and changed the assignment from `local MUTATION_TABLE = {` to `MUTATION_TABLE = {`.
  Also fixed a secondary double-skip bug: mutation handlers call `skip_to_eol()`
  internally (consuming the NEWLINE), so the match arm code was double-consuming it
  and eating the next arm. Fixed with `eol_consumed` flag.

  `nil` arm values correctly return Lua nil at runtime via the existing
  `call_fn("nil")` → `nil` special-case in `eval.lua`.
  8 regression tests added (4 parser, 4 runtime).

---

## Major Bugs (wrong behaviour, not crash)

- [x] **Bug #10 — `let x = expr:` scoped-body form is broken.** *(fixed 2026-05-12)*
  The spec documents `let x = value: body` as a scoped binding form. When the binding
  value ended with a bare identifier, the lexer tokenised `identifier:` as a single
  `NAMED_ARG` token, consuming the colon. The parser never saw the `:` and fell into the
  multi-binding continuation loop, emitting a confusing error.

  **Fix (Option A):** In `compiler/parser.lua:parse_let_value`, after calling `parse_expr`,
  check `p.tokens[p.pos - 1]`. If the last consumed token was a `NAMED_ARG`, set
  `colon_done = true` — the colon was already consumed by the lexer as part of that token.
  4 regression tests added (single-binding bare-ident case, expression-ending-with-ident
  case, path/expr case that already worked, multi-binding case).

- [x] **Bug #11 — `match` without wildcard silently returns `nil`; downstream `set!` silently
  unsets the path.** *(fixed 2026-05-13)*
  When a `match` expression has no `_:` wildcard arm and the subject matches no arm, the
  expression returns `nil` with no warning. If the result is then stored with `set!`, the
  target path is silently unset — it disappears from state and shows as blank in narration.
  The checker does not warn on incomplete matches.

  Example:
  ```
  type Class = warrior | mage | rogue | ranger

  fn class-damage:
    let dmg = match player/class:
      `warrior: 15
      `mage:    10
      `rogue:   12
      # ranger unhandled — returns nil silently
    set! player/damage dmg   # unsets player/damage when class = `ranger
  ```

  **Options:**
  - **A (runtime):** In `eval_match` (`runtime/eval.lua`), after all arms fail and the
    result would be `nil`, emit a runtime warning via `engine/emit` or `io.stderr` naming
    the match location and subject value. Low cost.
  - **B (checker):** In `compiler/checker.lua`, during `pass2_check`, detect `MATCH_EXPR`
    nodes over typed enum subjects and warn `INCOMPLETE_MATCH` when no `_:` arm is present
    and not all enum values are covered. This catches the issue at compile time.
  - **C:** Combine A and B. Checker warns, runtime warns in dev mode.
  - **D (spec-compatible):** Treat unhandled match as a compile error, not warning. The
    spec is silent on this but making it an error would be safest. Possibly too strict.

  Recommended: **B** (checker warning). Add `INCOMPLETE_MATCH` to `ast.E`, emit in
  `pass2_check` for MATCH_EXPR over named enum types.

- [x] **Bug #12 — Non-lambda `find where:` predicate returns all entities unfiltered.** *(fixed 2026-05-13)*
  When a plain expression (not a lambda) is passed to `where:` in a `find`/`count`
  expression, the condition is not applied per-entity — all members of the family are
  returned regardless. Only the lambda form correctly binds the entity variable:

  ```
  # BROKEN — ignores the condition, returns all enemies:
  find enemies where: enemies/{e}/status = `alive

  # CORRECT — filters as expected:
  find enemies where: fn(e): enemies/{e}/status = `alive
  ```

  The spec (§15.2) shows the non-lambda form as valid syntax with implicit variable binding.

  **Root cause:** In `runtime/query.lua:M.find`, the `where` clause handler checks whether
  the condition is a lambda and, if so, calls it with the entity key. For a plain expression,
  it evaluates the expression once (without binding the entity key variable) and uses that
  single boolean result for all entities.

  **Fix:** When the `where` condition is a plain expression node (not a lambda), evaluate it
  once per entity inside a child context that binds the entity variable name (the family
  variable from the `find` clause) to the current entity key. The family variable name is
  available from the `FIND_EXPR` node. Update `query.lua:M.find` to inject this binding
  for non-lambda `where` predicates. Add tests in `tests/runtime/query_spec.lua`.

- [x] **Bug #13 — REPL unusable when `entry-scene` is a computed-goto scene.** *(fixed 2026-05-12)*
  The common pattern of a `main:` scene that dispatches via `-> (match player/location: ...)`
  means the REPL starts in that scene, which has no choices. `:choices` shows
  "(no choices)" and the REPL is stuck — there is no command to follow a goto.

  **Fix:** In `cli/repl_cmd.lua`, after `eng:init()`, follow any unconditional navigation
  signal produced by `eng:render_scene(entry)` — i.e., advance through computed gotos until
  a scene with displayable choices is reached, exactly as `engine:step()` does. This is a
  small change mirroring the existing `nav_signal` handling in `engine:step`.

---

## Silent Failure Hazards

These produce no error at compile or runtime, making the resulting bugs very difficult to
locate. All five are high-priority from an authoring-experience perspective.

- [x] **SF-1 — Zero-arg undefined function calls silently return a string.** *(fixed 2026-05-13)*
  A typo in a zero-argument call — `move-too` instead of `move-to` — returns the string
  `"move-too"` instead of raising an error. State is unchanged and the game continues as if
  nothing happened. This is documented in `runtime/eval.lua:call_fn` as a "known limitation"
  because zero-arg calls are lexically indistinguishable from bare identifiers (variable
  reads, relation names, enum values) passed as arguments to builtins.

  **Options:**
  - **A:** After compilation, the checker knows all user-defined function names. In
    `eval.lua:call_fn`, if `#args == 0` and the name is not in `ctx.vars`, not in
    `BUILTINS`, not in `ctx.game.bounded`, and not in `ctx.fns`, emit a runtime warning
    (in dev mode) before returning the string. A name in any of those tables is a valid
    non-function use; anything else is suspicious.
  - **B:** In `compiler/checker.lua pass2_check`, when a `FN_CALL` node with 0 args
    appears in a statement position (not as a fn-argument), check whether the name resolves
    to a declared function. If not, emit `UNDEFINED_FN` warning. This is a compile-time
    catch but harder to implement (need to distinguish statement-position calls from
    bare-identifier uses without full type inference).
  - **C:** No fix — document the limitation clearly. Lowest cost, lowest value.

  Recommended: **A** (dev-mode runtime warning). Small change to `eval.lua`.

- [x] **SF-2 — Invalid enum values assigned without error.** *(fixed 2026-05-13)*
  `set! player/status \`zombie` succeeds silently when `Status = alive | dead`. The
  illegal value is stored in state and displayed. No compile-time or runtime check exists.

  **Options:**
  - **A (runtime, dev mode):** In `runtime/state.lua:store:set`, when the path has a
    declared enum type in the schema, validate the incoming value against the declared
    values and emit a warning (or error in strict mode) if it is not a member. The schema
    is available via `store._schema`.
  - **B (checker):** In `compiler/checker.lua`, when a `SET_MUT` assigns a `SYMBOL_LIT`
    to a typed path, check that the symbol is a valid member of the path's enum type. This
    is feasible for static paths but harder for interpolated paths (`npcs/{npc}/status`).
  - **C:** Combine A and B. Checker catches static cases; runtime catches dynamic ones.

  Recommended: **A** first (cheap, catches all cases), then **B** to move detection earlier.

- [x] **SF-3 — Writes to undefined state paths silently no-op.** *(fixed 2026-05-13)*
  `set! player/nonexistent-field 5` compiles cleanly and does nothing at runtime — no log
  entry, no error, no warning. The same applies to `inc!`, `dec!`, `add!`, etc.

  **Fix (runtime, dev mode):** In `runtime/state.lua:store:set` (and `inc`, `dec`, etc.),
  check whether the target path matches any declared state schema key (prefix-match for
  family paths). If not, emit a warning in dev mode. The schema paths are available from
  `store._schema.states`. Add a dev-mode flag check so production builds are unaffected.

- [x] **SF-4 — Transitions to undefined scenes silently end the game.** *(fixed 2026-05-13)*
  `-> ghost-town` when `ghost-town` is not declared now emits `[WARN] goto undefined scene: 'ghost-town'`
  in dev mode. Same for `=>` (enter_scene). Both `goto_scene` and `enter_scene` in
  `runtime/engine.lua` check `self._scenes[name]` and emit via `_print_sink` (or stderr
  when no sink is set). Warning suppressed when `production = true`.
  Checker-side (AV-2) was already resolved 2026-05-13.
  7 regression tests added (engine_spec).

- [ ] **SF-5 — `set!` on a `let`-bound variable silently misfires.**
  `let i = 0; set! i (i + 1)` writes to a state PATH named `"i"` (which likely doesn't
  exist), not to the local variable `i`. The local var `i` is never updated. In a while
  loop, this produces an infinite loop that hits the 10,000-iteration safety limit:

  ```
  fn count-to-5:
    let i = 0
    while i < 10:       # reads local var i = 0 always
      set! i (i + 1)    # writes to state path "i", not local var
      when i >= 5:
        break           # never fires
  ```

  There is no language mechanism to mutate a `let` binding. The workaround is to use
  a dedicated state path as the counter. This is by design, but authors coming from
  imperative languages will hit this repeatedly.

  **Options:**
  - **A (compile-time error/warning):** In `checker.lua`, when a `SET_MUT` node targets
    a single-segment path (no `/`) that matches a name bound in an enclosing `let`, emit
    a warning `LET_VAR_MUTATION` explaining that `let` bindings are immutable and `set!`
    is writing to a state path, not the local variable.
  - **B (runtime warning):** In `eval.lua:eval_stmt` for `SET_MUT`, before writing to
    state, check whether the path is a bare identifier that exists in `ctx.vars`; if so,
    emit a dev-mode warning.
  - **C (language change):** Introduce a `mut!` or `set-local!` primitive for local
    variable mutation. This is a larger spec/language change and should not be done without
    explicit decision.

  Recommended: **A** (checker warning). Simple to implement, catches the error at compile
  time without changing language semantics.

---

## Compile-Time Validation Gaps

The checker validates types and structure but does not cross-validate names across
declaration categories. All four of these allow structural errors to compile cleanly.

- [x] **AV-1 — Undefined function calls pass the checker.** *(fixed 2026-05-13)*
  `fn example:` calling `undefined-fn arg` compiles without error. The checker does not
  resolve function names against the declared function table. Add a pass that walks all
  `FN_CALL` nodes and reports `UNDEFINED_FN` for names not in `symtab.fns`, `BUILTINS`,
  `symtab.bounded`, or a set of built-in operator names (`min`, `max`, `str`, etc.).
  Zero-arg calls are ambiguous (see SF-1) and should be warned separately.

- [x] **AV-2 — Undefined scene transition targets pass the checker.** *(fixed 2026-05-13)*
  `-> undefined-scene` and `=> undefined-scene` compile cleanly. Add a check in pass 2:
  for `SCENE_GOTO` and `SCENE_ENTER` nodes whose target is a string literal (not a computed
  expression), verify the target name exists in `symtab.scenes`. Emit `UNDEFINED_SCENE`.
  Also verify that `entry-scene` in `engine-config` names a declared scene.

- [x] **AV-3 — Invalid enum literal values pass the checker.** *(fixed 2026-05-13)*
  `set! player/status \`zombie` (where `Status = alive | dead`) compiles cleanly. In pass 2,
  when a `SET_MUT` or `ADD_MUT` assigns a `SYMBOL_LIT` to a path whose declared type is a
  named enum (resolvable via `symtab.states` → `symtab.types`), check that the symbol is a
  member of that enum. Emit `INVALID_ENUM_VALUE`. Covers static paths; interpolated paths
  (`npcs/{npc}/status`) cannot be checked statically but the runtime check in SF-2 covers
  those.

- [x] **AV-4 — Reads/writes to undeclared state paths pass the checker.** *(fixed 2026-05-13)*
  `player/nonexistent-field` in any read or write position compiles cleanly. In pass 2,
  for every `PATH_EXPR` and `INTERP_PATH` node, resolve the path prefix against
  `symtab.states` and `symtab.families`. If no declared state covers this path, emit
  `UNDEFINED_PATH` warning (warning not error, to allow partial schemas and forward refs
  in multi-file games). Exclude query patterns (`*`, `**`, `|`) from the check. This is
  the most complex of the four validation gaps; tackle after AV-1 through AV-3.

---

## Authoring Ergonomics

- [x] **AE-13 — Integer division yields floats in narration.** *(fixed 2026-05-13)*
  `player/health / 2` evaluates to `50.0` (Lua number division), which renders as "50.0"
  in narration. This looks unprofessional in game output.

  **Fix applied (Option C):** `val_to_display` in `runtime/eval.lua` now checks whether a
  float value has no fractional part and formats it with `%d` (no ".0"). Purely
  presentational; semantics unchanged. 3 regression tests added to `eval_spec.lua`.

- [x] **AE-14 — Compiler warnings repeat on every `storybase run`.** *(fixed 2026-05-13)*
  Warnings from the compile pass (e.g. `WRITE_UNTYPED_VAR`, `SUPERFICIAL_IN_COND`) are
  printed every time `storybase run` is invoked. During development this makes output very
  noisy and obscures actual game output.

  **Fix applied:** Added `--quiet` flag to `storybase run`. When set, warnings are suppressed
  on stderr; errors still print unconditionally. `quiet` added to `BOOL_FLAGS`; both short
  and long help text updated. 4 regression tests added to `cli_integration_spec.lua`.

- [x] **AE-15 — `find` result cannot be used inline as a `set!` argument.** *(fixed 2026-05-13)*
  Single-line `(find family where: fn(e): cond count)` already worked. The bug was
  specifically with **multi-line** find inside parens:
  ```
  set! world/count (find enemies
    where: fn(e): enemies/{e}/alive
    count)
  ```
  Inside `()` the lexer emits NEWLINE tokens between continuation lines but no INDENT/DEDENT.
  The parser's find handler saw NEWLINE → no INDENT → undid the NEWLINE consume, leaving
  the where:/count clauses unparsed and returning `find enemies` with no clauses.

  **Fix:** In `compiler/parser.lua`, in the "NEWLINE, no INDENT" else branch of the find
  handler: instead of always undoing, skip newlines and check whether the next token is a
  valid find clause (NAMED_ARG or `count`). If yes, call `parse_find_clauses_inline(true)`
  which skips newlines between clause iterations. If no clauses found, still restore position.
  The `newline_skip` parameter was added to `parse_find_clauses_inline()`.
  6 regression tests added (3 parser_spec, 3 query_spec runtime).

- [x] **AE-16 — REPL gets stuck in computed-goto entry scenes.** *(fixed 2026-05-12 with Bug #13)*
  Same root cause as Bug #13; fix also covers the `:choose` command which now calls
  `game:advance_to_choices()` after each choice execution.

- [x] **AE-17 — No integer-division operator / floor division.** *(fixed 2026-05-13)*
  Added four arithmetic builtins to `runtime/eval.lua` and `compiler/checker.lua`:
  - `int-div a b` → `math.floor(a / b)` (floor integer quotient)
  - `floor n` → `math.floor(n)` (round toward −∞)
  - `ceil n` → `math.ceil(n)` (round toward +∞)
  - `mod a b` → `a % b` (floor-division remainder; sign matches divisor — same as Python)

  `mod` uses Lua's `%` operator which is already floor-division remainder (Python sign
  convention): `-7 mod 3 = 2`, `7 mod -3 = -2`.
  11 regression tests added (eval_spec).

---

## Spec / Documentation Divergence

- [ ] **SD-1 — `find` block syntax in spec uses bare `where` keyword; implementation
  requires `where:` NAMED_ARG and lambda.**
  The spec (§15.2) shows:
  ```
  find npc
    where    npcs/{npc}/disposition = `hostile
    order-by npcs/{npc}/health asc
    limit    5
  ```
  The actual parser requires:
  ```
  find npcs
    where:   fn(npc): npcs/{npc}/disposition = `hostile
    order-by: npcs/{npc}/health
    limit:   5
  ```
  An author following the spec literally will get no parse error (clauses are silently
  skipped) but the filter won't work.

  **Options:**
  - **A:** Fix Bug #12 (non-lambda `where:` expression form) so that `where: condition`
    (without lambda) correctly binds the entity variable and filters. Then update spec to
    use `where:` (with colon) to match the lexer. Demos and documentation updated together.
  - **B:** Add the no-colon `where`/`order-by`/`limit` keyword form to the parser as
    synonyms for the NAMED_ARG form. More parser complexity but closer to spec text.
  - **C:** Update the spec to reflect the actual syntax (`where:`, lambda required).
    Lowest code cost; breaks the nice spec example but at least authors are not misled.

  Recommended: **A** (fix Bug #12) + update spec §15.2 to use `where:` syntax.

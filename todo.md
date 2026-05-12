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

**2287 tests passing, 0 failing, 2 pending (known limitations).**

---

## What to work on next

Recommended order:
1. **Silent-failure hazards** (SF-1 through SF-5) — invisible correctness problems.
2. **Compile-time validation** (AV-1 through AV-4) — improve checker so authoring
   errors surface at `storybase check` instead of at runtime.
3. **Ergonomics** (AE-13 through AE-17) — quality-of-life improvements.
4. **Spec divergence** (SD-1) — align `find` block syntax with documentation.

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

- [ ] **SF-1 — Zero-arg undefined function calls silently return a string.**
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

- [ ] **SF-2 — Invalid enum values assigned without error.**
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

- [ ] **SF-3 — Writes to undefined state paths silently no-op.**
  `set! player/nonexistent-field 5` compiles cleanly and does nothing at runtime — no log
  entry, no error, no warning. The same applies to `inc!`, `dec!`, `add!`, etc.

  **Fix (runtime, dev mode):** In `runtime/state.lua:store:set` (and `inc`, `dec`, etc.),
  check whether the target path matches any declared state schema key (prefix-match for
  family paths). If not, emit a warning in dev mode. The schema paths are available from
  `store._schema.states`. Add a dev-mode flag check so production builds are unaffected.

- [ ] **SF-4 — Transitions to undefined scenes silently end the game.**
  `-> ghost-town` when `ghost-town` is not declared causes the engine to navigate to an
  empty scene, which has no choices, so the engine returns "done" (game over) with no
  explanation.

  **Fix:** In `runtime/engine.lua:goto_scene` (and `enter_scene`, `exit_scene`), check
  whether the target name exists in `self._scenes`. If not, emit a runtime error (in dev
  mode) or at minimum a `log` warning. A missing scene is never intentional and should
  never be silent.

  Also fix in the checker: in `compiler/checker.lua`, during pass 2, when a `SCENE_GOTO`
  or `SCENE_ENTER` node targets a string literal scene name, verify it exists in
  `symtab.scenes`. Emit `UNDEFINED_SCENE` error. (Computed gotos cannot be checked
  statically.)

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

- [ ] **AV-1 — Undefined function calls pass the checker.**
  `fn example:` calling `undefined-fn arg` compiles without error. The checker does not
  resolve function names against the declared function table. Add a pass that walks all
  `FN_CALL` nodes and reports `UNDEFINED_FN` for names not in `symtab.fns`, `BUILTINS`,
  `symtab.bounded`, or a set of built-in operator names (`min`, `max`, `str`, etc.).
  Zero-arg calls are ambiguous (see SF-1) and should be warned separately.

- [ ] **AV-2 — Undefined scene transition targets pass the checker.**
  `-> undefined-scene` and `=> undefined-scene` compile cleanly. Add a check in pass 2:
  for `SCENE_GOTO` and `SCENE_ENTER` nodes whose target is a string literal (not a computed
  expression), verify the target name exists in `symtab.scenes`. Emit `UNDEFINED_SCENE`.
  Also verify that `entry-scene` in `engine-config` names a declared scene.

- [ ] **AV-3 — Invalid enum literal values pass the checker.**
  `set! player/status \`zombie` (where `Status = alive | dead`) compiles cleanly. In pass 2,
  when a `SET_MUT` or `ADD_MUT` assigns a `SYMBOL_LIT` to a path whose declared type is a
  named enum (resolvable via `symtab.states` → `symtab.types`), check that the symbol is a
  member of that enum. Emit `INVALID_ENUM_VALUE`. Covers static paths; interpolated paths
  (`npcs/{npc}/status`) cannot be checked statically but the runtime check in SF-2 covers
  those.

- [ ] **AV-4 — Reads/writes to undeclared state paths pass the checker.**
  `player/nonexistent-field` in any read or write position compiles cleanly. In pass 2,
  for every `PATH_EXPR` and `INTERP_PATH` node, resolve the path prefix against
  `symtab.states` and `symtab.families`. If no declared state covers this path, emit
  `UNDEFINED_PATH` warning (warning not error, to allow partial schemas and forward refs
  in multi-file games). Exclude query patterns (`*`, `**`, `|`) from the check. This is
  the most complex of the four validation gaps; tackle after AV-1 through AV-3.

---

## Authoring Ergonomics

- [ ] **AE-13 — Integer division yields floats in narration.**
  `player/health / 2` evaluates to `50.0` (Lua number division), which renders as "50.0"
  in narration. This looks unprofessional in game output.

  **Options:**
  - **A:** Add an `int-div` builtin (`int-div a b` → `math.floor(a/b)`).
  - **B:** Add a `floor` builtin (maps to `math.floor`).
  - **C:** When rendering an inline expression (`{expr}`) in narration, if the result is a
    Lua number with no fractional part, format it as an integer (no ".0"). This is purely
    presentational and does not change semantics.
  - **D:** Overload `/` to perform integer division when both operands are `Int` typed.
    This is a language-semantic change and may surprise authors who need float results.

  Recommended: **C** first (trivial, fixes the display everywhere) plus **A** for cases
  where authors explicitly want integer quotients in logic.

- [ ] **AE-14 — Compiler warnings repeat on every `storybase run`.**
  Warnings from the compile pass (e.g. `WRITE_UNTYPED_VAR`, `SUPERFICIAL_IN_COND`) are
  printed every time `storybase run` is invoked. During development this makes output very
  noisy and obscures actual game output.

  **Fix:** In `cli/main.lua` run subcommand, suppress warning output when warnings are not
  errors (i.e. `check passed (N warnings)`). Optionally accept a `--warn` flag to re-enable
  them. Errors still print unconditionally.

- [ ] **AE-15 — `find` result cannot be used inline as a `set!` argument.**
  `set! world/count (find enemies where: fn(e): ... count)` fails at parse time. The `find`
  block form cannot be nested inside a parenthesised argument position. Authors must wrap
  the query in a dedicated function.

  **Root cause:** `parse_atom` handles `find`/`count` only when they appear at the start of
  an expression; when inside `()`, the argument-list parser consumes `e` (the family name)
  as the single argument and expects `)`, not the `where:` clause.

  **Fix:** The inline `find` form (all clauses on one line, using NAMED_ARG syntax) already
  works when not inside `()`. Investigate why `(find family where: fn(k): cond count)` fails
  and fix the parenthesised case. May require `parse_atom` to detect `find`/`count`
  regardless of surrounding paren context.

- [x] **AE-16 — REPL gets stuck in computed-goto entry scenes.** *(fixed 2026-05-12 with Bug #13)*
  Same root cause as Bug #13; fix also covers the `:choose` command which now calls
  `game:advance_to_choices()` after each choice execution.

- [ ] **AE-17 — No integer-division operator / floor division.**
  Related to AE-13 but distinct: authors writing game logic (not just narration) sometimes
  need integer quotients, e.g. `damage / 2` in an `inc!` expression. A `floor` or `int-div`
  builtin would let them write `set! player/damage (int-div raw-damage 2)` cleanly. Tracked
  separately from AE-13 which covers the narration-display aspect.

  **Fix:** Add `int-div a b` to `BUILTINS` in `runtime/eval.lua` returning
  `math.floor(a / b)`. Add `floor n` as an alias. Document in spec §24.

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

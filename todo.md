
# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-04-25)

All eight implementation phases complete. Demos 01–12 tested end-to-end via `--cli` mode.
**1763 tests passing.**

Language review pass in progress: bugs fixed, break/continue/return added, not-in? added, exports filtering enforced, documentation updated. Remaining: QoL ergonomics tasks.

---

## Active Tasks

### Language Review — QoL / Ergonomics (in progress)

- [x] **Free `let` bindings (no mandatory body scope)** — already implemented; added tests and documentation.
- [x] **`for` loop `else` clause** — implemented: `else:` block after `for` body runs when collection is empty. Tests added, docs updated.
- [x] **`UList` / `UMap` runtime support** — `UList` fully works with `push!`/`pop!`/`size`/`for`. Added `map-set!`, `map-delete!`, `map-get`, `map-size`, `map-keys` for `UMap`. Tests and docs added.
- [x] **`with` mixin conflict error should name both source types** — already implemented; error message names both types.
- [ ] **`spawn!` shorthand using declared type defaults** — `spawn! npcs 'bob Npc()` requires spelling out all fields even when `Npc` declares defaults. Add `spawn! npcs 'bob` or `spawn! npcs 'bob Npc.default` that fills in declared defaults.
- [ ] **Unify `say` syntax between scene bodies and function bodies** — scene form uses `say speaker: text`, fn form uses `say 'speaker "text"`. Consider accepting both forms in both contexts, or document the distinction more clearly as intentional.
- [ ] **Inline `Enum(a, b, c)` unusable as a named type** — `state foo: Enum(up, down)` works, but the type can't be referenced by name in function signatures or other state declarations. Any reuse must be promoted to a `type` declaration. Consider allowing type aliases for inline enums, or emit a hint suggesting promotion.
- [ ] **`SymbolOf` on named enum types** — currently `SymbolOf(F)` requires `F` to be an entity family with backing state. Add `SymbolOf(EnumType)` so a typed symbol can be used without declaring a family, e.g. as a map key or option value over a declared enum.

---

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] ANSI colour output in CLI for attributed dialogue.
- [ ] **`UList` / `UMap` runtime support** — types exist in the checker but have no runtime operations (no map-get, map-set!, list-append for UList). Either add builtins or document them as pure-declaration stubs.

---

## Language Review — QoL / Ergonomics

- [ ] **Free `let` bindings (no mandatory body scope)** — `let x = expr:` always requires a `:` body block. Add statement-level `let x = expr` (no colon, no body) as a simple local binding within the enclosing function scope.
- [ ] **Unify `say` syntax between scene bodies and function bodies** — scene form uses `say speaker: text`, fn form uses `say 'speaker "text"`. Consider accepting both forms in both contexts, or document the distinction more clearly as intentional.
- [ ] **Inline `Enum(a, b, c)` unusable as a named type** — `state foo: Enum(up, down)` works, but the type can't be referenced by name in function signatures or other state declarations. Any reuse must be promoted to a `type` declaration. Consider allowing type aliases for inline enums, or emit a hint suggesting promotion.
- [ ] **`for` loop `else` clause** — after a `for` body that never executed (empty collection), there is no hook. Add `else:` branch on `for` to handle the empty-iteration case without a flag.
- [ ] **`with` mixin conflict error should name both source types** — when two `with` clauses contribute a conflicting field name, the error message should say which two types collide.
- [ ] **`SymbolOf` on named enum types** — currently `SymbolOf(F)` requires `F` to be an entity family with backing state. Add `SymbolOf(EnumType)` so a typed symbol can be used without declaring a family, e.g. as a map key or option value over a declared enum.

---

## Language Review — Documentation Gaps

- [ ] **Document `hook` declarations in `language.md`** — parser and eval fully support `hook before: fn-name:`, `hook after: fn-name:`, and tag-based `hook tag-name: pre:/post:` bodies, but the feature has no entry in the language reference.
- [ ] **Document `while` iteration safety limit** — authors need to know the 10,000-iteration cap exists (and once changed to an error, what the error looks like).
- [ ] **Document `path@before` propagation into called functions** — the reference says "`path@before` in `post:` blocks only", but the snapshot is propagated into functions called from within post. This is useful behaviour that should be described.
- [ ] **Clarify `say` ordering guarantee** — document explicitly that `say` calls inside functions called from a choice body accumulate in a pending buffer and are prepended to the next scene's narration, including nested function calls.

---

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] ANSI colour output in CLI for attributed dialogue.

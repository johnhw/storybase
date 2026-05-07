# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-07)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–21 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
Code review rounds 1, 2, and 3 fully resolved.
UI driver layer complete: `--ui plain` (default) and `--ui ansi` implemented.
Authoring ergonomics issues AE-1, AE-2, AE-4, AE-5, AE-6, AE-9, AE-12 resolved.

**2070 tests passing, 0 failing.**

---

## Next Up

Remaining authoring ergonomics issues, roughly in priority order:

1. **AE-10** / **AE-11** — Documentation gaps (low effort, high value for authors)
2. **AE-8** — Document `verify` limitation (low effort)
3. **AE-3** — Time axis / state variable sync (design decision needed)
4. **AE-7** — Actor `perceives:` friction (larger change)
5. **Inelegance #7** — BFS duplication (deferred; low priority)

---

## Remaining Polish

- [ ] **Inelegance #7** — BFS expansion logic duplicated ~5×. Deferred: each BFS function
  has a different data payload (priority/path/prob/cost) and queue mechanism
  (FIFO/heap/yield). Extracting a shared helper would require a messy callback strategy and
  add more complexity than it removes.

---

## Authoring Ergonomics Issues (open)

### Lexer / Parser

*(No open lexer/parser AEs.)*

### Runtime / Semantics

- [ ] **AE-3 — Engine time axis and state variable are independent and must be kept in sync
  manually.** `time-inc! day: 1` advances the engine time axis (used by `query-at`,
  `query-history`). `inc! world/day 1` advances a game state variable. They are completely
  independent; a demo author must do both. Fix candidates: (a) a `time-axis: world/day`
  annotation that makes `time-inc!` also advance the state variable, or (b) a
  `time-model: day-var: world/day` unification field. Affects: `runtime/eval.lua`,
  `compiler/parser.lua`, `idea.md`.

- [ ] **AE-8 — `verify` `after (fn):` always starts from a fresh initial state, not from
  arbitrary reachable states.** Authors cannot write "after buying from any state where we
  have enough gold, gold decreases." The `from-any-state:` + `requires:` workaround is more
  complex. Fix: document this clearly as a known limitation in `docs/reference/language.md`,
  and consider whether `after (fn):` should optionally sample from BFS-explored states.

### Missing Features

- [ ] **AE-7 — Actor `perceives:` must be kept in sync manually.** Every path an actor reads
  must appear in `perceives:`. Adding a read without updating `perceives:` is a compile error.
  During iteration this is constant friction. Fix: add a `perceives: *` wildcard escape hatch
  for dev mode, or auto-infer `perceives` from the behavior function's static read-set
  (the checker already computes write-sets; read-sets are symmetric). Affects:
  `compiler/checker.lua`, `runtime/actors.lua`.

### Documentation Gaps

- [ ] **AE-10 — Return value semantics for multi-statement pure functions undocumented.**
  Single-expression pure functions auto-return (spec §7.1 examples). Multi-statement pure
  functions use explicit `return` (demo15). The rule is not stated: does the last expression
  auto-return, or is `return` required? Clarify in `docs/reference/language.md` §7.

- [ ] **AE-11 — Multi-segment path access on loop variables undocumented.** `{entry/time/day}`
  in a `for` loop body works because eval checks whether the first path segment is a
  `ctx.vars` key and then navigates table fields. This is a critical feature for rendering
  log entries but appears in no documentation. Add an explicit example to
  `docs/reference/language.md` in the `for` loop and temporal query sections.

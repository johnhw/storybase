
# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-04-30)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–19 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
All code-review bugs #1–#4 and inelegances #5–#11 resolved (see completed.md).
All code-review round 2 bugs, design flaws, and false implementations resolved (see below).
**~1973 unit tests passing (busted tests/, excluding flaky debug_http network tests).**

---

## Code Review Round 2 — All Resolved (2026-04-30)

### Bugs Fixed

- [x] Bug #1 — `deep_copy_cache` / `undo` use `ipairs` → changed to `pairs` so UMap (hash-keyed) values survive checkpoints and undo. Regression test added.
- [x] Bug #2 — `relate!/unrelate!` bypass log → now write through state store at `__rel/<name>/<src>` keys; `query.lua` and `eval.lua` merge static+dynamic edges via `effective_rel`. Counterfactual-safe, logged, undoable, BFS-visible. Regression tests added.
- [x] Bug #3 — `grid-set!` not logged → now writes to both cells array AND `__grid/<name>/<x>,<y>` cache entry; `grid-get` checks cache override first; engine load path calls `init_grids` + `apply_grid_cache`; BFS `restore_engine` applies overrides too. Regression tests added.
- [x] Bug #4 — `PATH_EXPR` single-segment read skips `nil_vars` → added `nil_vars` check before state store fallthrough. Regression test added.
- [x] Bug #5 — `set_time` dead else-branch creates undeclared axes → else-branch now silently ignores undeclared axes. Regression test added.
- [x] Bug #6 — `map-values` non-deterministic order → sorted by key (same as `map-keys`). Regression test added.
- [x] Bug #7 — `path_list` non-deterministic order → `table.sort(keys)` added. Regression test added.

### False Implementations Fixed

- [x] False Impl #1 — `counterfactual.lua` dead code → replaced with one-line redirect comment.
- [x] False Impl #2 — `sched:schedule()` unreachable stub → replaced with `error()`.
- [x] False Impl #3 — Stale "not implemented" comments → removed from `log.lua` and `engine.lua`.

### Design Flaws Fixed

- [x] Design #1 — `spawn` O(N) uniqueness check → replaced with O(1) sentinel check. Regression test added.
- [x] Design #2 — Log serialiser drops extra fields → now preserves all unknown fields generically. Regression tests added.
- [x] Design #3 — 0-arg bare-string fallback comment → comment added explaining the trade-off.

---

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] ANSI colour output in CLI for attributed dialogue.
- [ ] Inelegance #7 — BFS expansion logic duplicated ~5×. Deferred: each BFS function has a different data payload (priority/path/prob/cost) and queue mechanism (FIFO/heap/yield). Extracting a shared helper would require a messy callback strategy and add more complexity than it removes.

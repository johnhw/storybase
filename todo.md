# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-02)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–20 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
Code review rounds 1, 2, and 3 fully resolved.
UI driver layer complete: `--ui plain` (default) and `--ui ansi` implemented.

Code review round 3 identified a cluster of UMap-related bugs in BFS machinery
(`ipairs` vs `pairs`) — all fixed (2026-05-02).  Regression tests added.

**2029 tests passing, 0 failing.**

---

## Next Up

No known bugs. See Remaining Polish below.

---

## Remaining Polish

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] Inelegance #7 — BFS expansion logic duplicated ~5×. Deferred: each BFS function has a different data payload (priority/path/prob/cost) and queue mechanism (FIFO/heap/yield). Extracting a shared helper would require a messy callback strategy and add more complexity than it removes.

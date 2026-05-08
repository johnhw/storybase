# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-08)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–21 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
Code review rounds 1, 2, and 3 fully resolved.
UI driver layer complete. All twelve authoring ergonomics issues (AE-1 through AE-12) resolved.

**2085 tests passing, 0 failing.**

---

## Remaining Open Work

- [ ] **Inelegance #7** — BFS expansion logic duplicated ~5×. Deferred: each BFS function
  has a different data payload (priority/path/prob/cost) and queue mechanism
  (FIFO/heap/yield). Extracting a shared helper would require a messy callback strategy and
  add more complexity than it removes.

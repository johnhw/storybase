# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-04-30)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–19 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
Code review rounds 1 and 2 fully resolved (bugs, inelegances, false impls, design flaws).
**1973 unit tests passing (busted tests/).**

---

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] ANSI colour output in CLI for attributed dialogue.
- [ ] Inelegance #7 — BFS expansion logic duplicated ~5×. Deferred: each BFS function has a different data payload (priority/path/prob/cost) and queue mechanism (FIFO/heap/yield). Extracting a shared helper would require a messy callback strategy and add more complexity than it removes.

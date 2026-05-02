# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-02)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–20 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
Code review rounds 1 and 2 fully resolved.

All previously-identified bugs and gaps are now resolved:

- **Bug #1 (cancel-schedule!) — FIXED.**
- **Bug #2 (format --write / watch-when label absorption) — FIXED.**
- **Gap #1 (breakpoints never checked) — FIXED.**
- **Gap #2 (fn-call event no test) — FIXED.**
- **Untested #1 (schedule! end-to-end + save/load replay) — DONE.**
- **Untested #2 (log round-trip special entry kinds) — DONE.**
- **Untested #3 (List push overflow) — DONE.**
- **Untested #4 (message-sent debug event) — DONE.**
- **Untested #5 (format --write .bak backup) — DONE.**

**2007 tests passing, 0 failing.**

---

## Next Up

No critical bugs or gaps remain. Remaining items are low-priority polish:

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] ANSI colour output in CLI for attributed dialogue.
- [ ] Inelegance #7 — BFS expansion logic duplicated ~5×. Deferred: each BFS function has a different data payload (priority/path/prob/cost) and queue mechanism (FIFO/heap/yield). Extracting a shared helper would require a messy callback strategy and add more complexity than it removes.

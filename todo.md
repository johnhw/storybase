# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-02)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–20 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
Code review rounds 1 and 2 fully resolved.

**Bug #1 (cancel-schedule!) — FIXED.**
**Bug #2 (format --write corruption) — FIXED.** All placeholder gaps and fmt mismatches
resolved. All four demo format regression tests pass (demo08, demo13, demo17, demo19).
**Gap #1 (breakpoints never checked) — FIXED.** Condition compiled at set-breakpoint time,
evaluated in check_watches(), positive-edge "breakpoint-hit" event emitted; tests added.
**Gap #2 (fn-call event no test) — FIXED.** Dedicated test added in debug_spec.lua.

**1997 tests passing, 0 failing.**

---

## Next Up: Untested Components

### Untested #1 — `schedule!` (dynamic imperative scheduling) end-to-end
**File:** `runtime/eval.lua` SCHEDULE_MUT handler (line ~2305)
**Status:** AST/parser/actors/BFS regression tests exist, but no test that schedules a fn
  at runtime via `schedule! 'name every: [...] fn: fn-name` and verifies it fires in
  subsequent turns and persists across save/load.
**Tests to add:** Integration test: call a fn that does `schedule! 'counter every: [tick:1]
  fn: inc-count`, run 3 autonomous turns, assert counter = 3. Also test save/load preserves
  the dynamic schedule.

### Untested #2 — Log round-trip for special entry kinds
**File:** `runtime/log.lua`, `tests/runtime/log_spec.lua`
**Status:** Normal mutation entries round-trip tested; `schedule_fired`, `schedule_created`,
  `cancel_schedule`, `checkpoint`, `undo`, `inbox_overflow`, `conflict` are not.
**Tests to add:** One parameterised test per special entry kind through
  `serialise_entries` → `deserialise`.

### Untested #3 — `List` push overflow (bounded list at capacity)
**File:** `runtime/state.lua` line ~452 (`error("LIST_OVERFLOW...")`)
**Tests to add:** Test that `store:push(path, val)` on a full list raises an error.

### Untested #4 — `message-sent` debug event
**File:** `runtime/eval.lua` line ~2297
**Tests to add:** One test: send a message from a fn body with a debug server wired, assert
  the `message-sent` event fires with the correct actor name.

### Untested #5 — `format --write` creates a `.bak` backup
**File:** `cli/format_cmd.lua`
**Tests to add:** One test: run `format --write` on a temp file, assert `file.bak` exists
  and contains the original source.

---

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] ANSI colour output in CLI for attributed dialogue.
- [ ] Inelegance #7 — BFS expansion logic duplicated ~5×. Deferred: each BFS function has a different data payload (priority/path/prob/cost) and queue mechanism (FIFO/heap/yield). Extracting a shared helper would require a messy callback strategy and add more complexity than it removes.

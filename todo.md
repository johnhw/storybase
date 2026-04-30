
# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-04-30)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–19 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
All bugs #1–#4 from the code review are verified/fixed with tests.
Inelegances #5,#6,#8,#9,#10,#11 resolved; #7 deferred as not worth the risk.
**1956 unit tests passing (busted tests/).**

---

## Active Tasks

### Code Review — Bugs (2026-04-28)

Findings from a systematic review of the codebase. Fix in priority order.

---

#### Bug #1 — `IF_EXPR` as expression always returns `nil` (HIGH)

**File:** `runtime/eval.lua:497–513`

When `if/else` is used as an expression (e.g. `let x = if cond then 1 else 2`), the
expression-form handler declares `local result` but never assigns it from `sub.retval`,
so it always returns `nil`. The comment "Return the last expression value from then_body"
is wrong.

Compare: the statement-form handler (line 2178) correctly does
`if sub.retval ~= nil then ctx.retval = sub.retval end`.

**Fix:** Replace both `return result` lines in the expression-form handler with
`return sub.retval`.

**Test:** Add an eval_spec test: `let x = if true then 42 else 0` should yield `x = 42`;
`let y = if false then 1 else 99` should yield `y = 99`.

- [x] Fix `eval.lua:497–513` — code already used `return sub.retval`; secondary bug was that `return` signal leaked from if-body into parent ctx; fixed by not propagating `return` signals in expression-form IF_EXPR handler
- [x] Add tests to `tests/runtime/eval_spec.lua` (direct AST tests + compiled-code tests)

---

#### Bug #2 — UMap state silently emptied in BFS and counterfactuals (HIGH)

**Files:** `runtime/search.lua:27–38` (`clone_flat`), `runtime/search.lua:172–179`
(`restore_engine`), `runtime/eval.lua:344–370` (counterfactual copy)

All three cache-copy sites use `ipairs` to copy table values:

```lua
local copy = {}
for i, item in ipairs(v) do copy[i] = item end
```

`UMap(K,V)` is a hash table (string keys). `ipairs` stops at the first non-integer index,
so every UMap in state is silently emptied during:
- `clone_flat` → affects all BFS builtins: `can-reach?`, `find-path`, `probability`,
  `optimal-path`, `verify-always`, `find-counterexample`
- `restore_engine` → BFS engine snapshots lose UMap contents
- counterfactual copy in `eval.lua` → `counterfactual` expressions see empty UMaps

**Fix:** Replace `ipairs` with `pairs` in these three copy loops. Must preserve
both integer and string keys. Also check `search.lua:restore_engine` deep-copy block.

**Test:** Add a search_spec test where state contains a `UMap` and `can-reach?` checks
a condition that depends on map contents.

- [x] Fix `search.lua:clone_flat` — already uses `pairs`
- [x] Fix `search.lua:restore_engine` cache restore block — already uses `pairs`
- [x] Fix `eval.lua` counterfactual copy blocks — already uses `pairs`
- [x] Add tests to `tests/runtime/search_spec.lua` (fixed invalid source syntax) and `tests/runtime/counterfactual_spec.lua` (pre-existing)

---

#### Bug #3 — Actor capture proxy missing `time_set` (MEDIUM)

**File:** `runtime/actors.lua:123`

The capture proxy implements `inc_time` but not `time_set`. If an actor behavior calls
`time-set!`, it calls the real store's `set_time` directly rather than going through
the deferred capture mechanism, bypassing priority arbitration and applying immediately.

**Fix:** Add `proxy.time_set` analogous to `proxy.inc_time`.

- [x] `proxy.set_time` already implemented in `actors.lua:127`
- [x] Test already exists in `tests/runtime/actors_spec.lua` (bug #3 describe block)

---

#### Bug #4 — `deliver_messages` inbox overflow crashes turn (MEDIUM)

**File:** `runtime/actors.lua:184`

`deliver_messages` throws an unguarded `error("INBOX_OVERFLOW: ...")`. The call chain
`post_action → deliver_messages` has no `pcall` wrapper, so inbox overflow aborts the
whole turn instead of being handled gracefully. `run_behaviors` wraps eval in `pcall`;
`deliver_messages` should do the same.

**Fix:** Wrap the overflow case in an error handler (log the overflow, skip the
message) or wrap the entire delivery loop in `pcall` and surface as a log entry.

- [x] `deliver_messages` already handles overflow gracefully (logs and breaks)
- [x] Test already exists in `tests/runtime/actors_spec.lua` (inbox overflow describe block)

---

### Code Review — Inelegances (2026-04-28)

Lower-priority quality improvements identified in the same review pass.

---

#### Inelegance #5 — Dead code: `match_pattern` function ✓

- [x] Deleted `match_pattern` from `eval.lua`

---

#### Inelegance #6 — `optimal_path` sorts entire open list each iteration ✓

- [x] Replaced sort-per-iteration with local binary min-heap in `search.lua`; heap_push/heap_pop added at top of file

---

#### Inelegance #7 — BFS expansion logic duplicated ~5×

Deferred: each BFS function has a different data payload (priority/path/prob/cost) and
queue mechanism (FIFO/heap/yield). Extracting a shared helper would require a messy
callback strategy and add more complexity than it removes.

---

#### Inelegance #8 — `make_search_cache` duplicates `search.lua:clone_cache` ✓

- [x] `clone_cache` exported as `M.clone_cache` from search.lua
- [x] `make_search_cache` in eval.lua replaced with a 3-line wrapper calling `search_mod.clone_cache`
- [x] Also fixed the latent Bug #2 in eval.lua: inline copy used `ipairs` (dropped UMap hash keys); now uses `clone_cache` which uses `pairs`

---

#### Inelegance #9 — Indentation inconsistency: `eng._in_bfs = true` ✓

- [x] Fixed all 11 occurrences to 4-space indent

---

#### Inelegance #10 — `map-keys` returns keys in non-deterministic order ✓

- [x] `map-keys` now sorts keys lexicographically before returning

---

#### Inelegance #11 — Navigation signal handling duplicated ~10× ✓

- [x] Added `apply_signal(stack, sig)` local helper at top of search.lua
- [x] Replaced all 5 duplicated signal-handling blocks in search.lua with `apply_signal(new_stack, sig)`
- Note: engine.lua and cli_cmd.lua use a different pattern (calling eng methods directly) — not unified as those operate on engine objects, not raw stacks

---

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] ANSI colour output in CLI for attributed dialogue.

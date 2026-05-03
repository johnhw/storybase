# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-03)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–21 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
Code review rounds 1, 2, and 3 fully resolved.
UI driver layer complete: `--ui plain` (default) and `--ui ansi` implemented.

**2041 tests passing, 0 failing.**

All significant language features now have polished numbered demos.

Bug fixed: CLI `--cli` save/restore (`restore_engine` in `cli/cli_cmd.lua`) did not
repopulate `eng._log._entries` after replay, causing `query-history`, `query-changes`,
and `query-at` to return empty results after the first step.  Fix: append saved entries
back into `eng._log._entries` and restore `eng._log._seq`.

---

## Next Up

- [x] Write `demos/demo21_merchants_reckoning.sb` (design below)
- [x] Add CLI integration test entries for demo21 in `tests/cli/cli_integration_spec.lua`
- [x] Update `code_map.md` demos table with demo21 entry once written

---

## Demo 21 — `query-at` / `query-history` / `query-changes`

**File:** `demos/demo21_merchants_reckoning.sb`

**Goal:** Showcase all three log-backed temporal query builtins as first-class gameplay
mechanics.  These are the only significant language features with no polished numbered demo
(only a test fixture, `tests/test05_log_and_time.sb`, uses `query-history`).

### Narrative frame

A travelling merchant performs *the reckoning* — a ritual end-of-day audit in which the
chronicle (the transaction log) is consulted to reconstruct what happened.  The player
makes several trade and travel choices across multiple days, building up history, then
enters the reckoning scene to review it via the three query forms.

### Features to demonstrate

| Builtin | Example syntax | Narrative use |
|---------|---------------|---------------|
| `query-history` | `query-history player/gold` | Full ledger — every gold change with day and direction |
| `query-changes` | `query-changes player/location last-n: 3` | Recent road — last 3 locations visited |
| `query-at` | `query-at player/gold time: {day: d}` | Opening fortune — what was gold at start of a named day |
| Wildcard pattern | `query-history player/*` | Broad audit — every player state change combined |

### Types and state

```
time-model:
  axes: [day]
  wrap: [none]

type Location = crossroads | town | market | forest | inn | ruins
type Gold     = Int(0, 500)

state player:
  gold:     Gold     = 100
  location: Location = 'crossroads

state world:
  day: Int(0, 30) = 1
```

### Scene outline

- **`crossroads`** — hub scene; navigate to town / market / forest / inn; choice to "take the
  reckoning" (→ `reckoning`) once `world/day > 1` so there is non-trivial history.
- **`town`** — sell found goods (+gold); rest (advance day + return).
- **`market`** — buy provisions (−gold); sell surplus (+gold); return.
- **`forest`** — explore; may change location to ruins; return.
- **`inn`** — pay for lodging (−gold); rest advances day; return.
- **`reckoning`** — three-part audit with sub-choices:
  - *Consult the ledger* → `reckoning-ledger`: `for entry in (query-history player/gold):`
    renders each change as "Day N: N gold → N gold".
  - *Trace the road* → `reckoning-route`: `for entry in (query-changes player/location last-n: 3):`
    renders last three locations.
  - *Recall opening fortune* → `reckoning-fortune`: inline `{gold-on-day 1}` using a helper
    fn that calls `query-at player/gold time: {day: 1}`.
  - *Close the reckoning* → back to crossroads.

### Key functions

```
fn travel dest:
  set! player/location dest

fn earn-gold amount:
  tags: [checkpoint]
  inc!  player/gold amount

fn spend-gold amount:
  pre:  player/gold >= amount
  tags: [checkpoint]
  dec!  player/gold amount

fn advance-day:
  tags: [checkpoint]
  inc!  world/day 1
  time-inc! day: 1

fn gold-on-day d:   # query-at with variable time axis value
  query-at player/gold time: {day: d}
```

### Rendering log entries in narration

Log entry records have `time`, `old`, `new`, and `path` fields.  Access via path
interpolation in `for` bodies:

```
for entry in (query-history player/gold):
  Day {entry/time/day}: {entry/old} → {entry/new} gold
```

Confirm that `entry/time/day` resolves correctly (first segment = loop var, subsequent
segments = table field navigation).  If it does not, use `tostring entry` as a fallback
for the demo and file a bug.

### Verify blocks

```
verify "gold never goes negative":
  verify-always player/gold >= 0

verify "spend-gold reduces gold by exactly the amount":
  requires player/gold >= 30
  after (spend-gold 30):
    player/gold = player/gold@before - 30

verify "query-at day 1 returns initial gold before any trade on day 1":
  after (advance-day):
    gold-on-day 1 = 100
```

The third verify checks that `query-at` with the initial time returns the correct snapshot
value — a direct test of the builtin's semantics, not just game logic.

### Implementation notes

- Build up enough choices that the reckoning scenes are non-trivial: at least 2 earn/spend
  actions and 1 day advance before reaching `reckoning`.
- Use `[world/day > 1]` guard on the "take the reckoning" choice so there is always
  something in the log.
- The wildcard query `query-history player/*` in the broad-audit variant is optional; include
  it only if confirmed to work correctly in the for-loop context (see eval_spec tests for
  wildcard path patterns).
- Prefer simple, readable narration over exhaustive coverage — the goal is clarity, not
  exhaustiveness.

---

## Remaining Polish

- [x] Every public function in every module has at least one passing and one failing test.
  - Verified across all runtime and compiler modules (2026-05-03).
  - Added: scheduler dead-stub error test; lexer bare-tick and unclosed-interpolation error tests.
- [ ] Inelegance #7 — BFS expansion logic duplicated ~5×. Deferred: each BFS function has a different data payload (priority/path/prob/cost) and queue mechanism (FIFO/heap/yield). Extracting a shared helper would require a messy callback strategy and add more complexity than it removes.

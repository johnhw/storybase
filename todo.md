
# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-04-26)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–14 tested end-to-end via `--cli` mode.
**1792 unit tests passing (busted tests/ excluding debug_http and cli_integration).
158 CLI integration tests passing.**

**Parser bug fixed in Demo 14 implementation:**
- `parse_migration_decl`: trailing `p:skip_to_eol()` after each op was unconditional, causing
  ops following a multi-line `transform` block to be silently swallowed. Now each single-line
  op branch calls `p:skip_to_eol()` itself; `transform` (which handles its own block) does not.

Next up: demos 15–16 covering macros and advanced find queries.
See **Active Tasks** below.

**Language bugs fixed in Demo 13 implementation:**
- `call_lambda`: multi-line lambda body retval now captured (`result = sub.retval`)
- `call_fn`: `before_snapshot` now created at function call time for `post:` checking
- `call_fn`: `post:` conditions correctly unwrap EXPR_STMT (mirrors `pre:` handling)
- `parse_lambda`: now supports multi-line body (NEWLINE/INDENT after `:`)
- INTERP_PATH atom: `@before` suffix now parsed (for `patients/{key}/health@before`)
- `query.lua` `where:` clause: lambdas are now called with the entity key, not just evaluated
- `count family where: fn(k):` now parsed as FIND_EXPR with count clause (not builtin)
- `state patients: Patient max:` must use `state patients/{k}: Patient max:` (family syntax)

---

## Active Tasks

### New Demos — Feature Coverage Gaps

Four demos are planned to cover language features with no (or only token) demo coverage.
Do not start implementation until all specs are agreed. Implement in order 13 → 16.

---

#### Demo 13 — "The Healer's Ward" (speaker/say + post-conditions + multi-line lambdas)

**File:** `demos/demo13_healers_ward.sb`

**Theme:** A healer managing a small infirmary. Patients arrive, are diagnosed, treated, and
discharged. Simple resource management (herbs, bandages) drives choices.

**Features to demonstrate:**

- `speaker` declarations with `display:` and `color:` metadata for healer, nurse, and each patient
- `say` in scene bodies — bare identifier form: `say aldric: text`, block form (multi-line), and
  dynamic form: `say (patient/speaker): text` (speaker resolved from state)
- `say` in function bodies — dialogue emitted inside `treat-patient` fn is prepended to the
  next scene narration (demonstrating the buffering guarantee)
- `say 'speaker "text"` symbol-literal form used in at least one function body
- `post:` conditions with `path@before` — e.g. after `treat-patient`, assert
  `patient/health >= patient/health@before`
- Multi-line lambda in a `find` query — find patients needing urgent care using a multi-line
  `fn(p):` body that checks multiple fields (not just a single inline expression)
- Entity family `patients` with fields: `name`, `condition` (enum), `health` (Int), `speaker`
  (Symbol), `treated` (Bool)
- At least 3 named speakers declared; at least one speaker used dynamically via state lookup

**Scenes:** `ward` (overview, choices), `examine-patient` (examine one patient), `treat-patient`
(apply treatment, say lines from both healer and patient, post: contract enforced),
`rest` (end of day, discharge treated patients), `out-of-supplies` (defeat state)

**Verify block:** from-any-state, assert that a fully-treated patient always has health > 0.

**Implementation checklist:**
- [x] Write `demos/demo13_healers_ward.sb`
- [x] Confirm `say` block form, dynamic form, and function-body buffering all work
- [x] Confirm `post:` block fires and raises error when violated (test with a bad pre-state)
- [x] Confirm multi-line lambda in `find` evaluates correctly
- [x] Add 4–6 CLI integration tests in `tests/cli/cli_integration_spec.lua`
- [x] Run `busted tests/` — all tests green (1784 unit + 151 CLI)
- [ ] Update `code_map.md`
- [x] Commit

---

#### Demo 14 — "The Kingdom's Records" (schema migration: rename, transform, rename-enum)

**File:** `demos/demo14_kingdoms_records.sb`

**Theme:** A royal archivist maintaining kingdom census records over four schema versions.
The game itself is simple (browse and update records), but the migration chain is the centrepiece.

**Features to demonstrate:**

- `schema-version: 4` at file top
- `migration 1 -> 2:` — `add` a new field (`world/treasury-notes` String = `""`)
- `migration 2 -> 3:` — `rename world/census-count -> world/population` and
  `drop world/treasury-notes`
- `migration 3 -> 4:` — `transform world/population: fn old: old * 100`
  (converts a rounded-hundreds value to an exact count) AND
  `rename-enum world/kingdom-status old-name -> new-name` (e.g. rename `at-war` → `warring`)
- A `verify` block exercises the migration path via the `storybase migrate` CLI
- Game loop: view records, update a field, file a report (advances year), review history

**Implementation note:** The demo `.sb` file should parse and run at schema-version 4 with
no save file (fresh start). The migration chain is exercised by the `storybase migrate` CLI
command against a hand-crafted v1 save fixture in `tests/fixtures/kingdoms_v1.sbd`, if feasible,
or via a unit test in the migration spec.

**Implementation checklist:**
- [x] Write `demos/demo14_kingdoms_records.sb` with `schema-version: 4` and all four migrations
- [x] Confirm all four migration kinds parse and compile without errors
- [x] Write `tests/runtime/migrate_demo14_spec.lua` exercising the full 1→2→3→4 chain
- [x] Add CLI integration tests (compile + run --auto)
- [x] Run `busted tests/` — all tests green (1792 unit + 158 CLI)
- [x] Update `code_map.md`
- [ ] Commit

---

#### Demo 15 — "The Spellwright's Workshop" (macro system)

**File:** `demos/demo15_spellwright.sb`

**Theme:** A wizard's workshop where spells are crafted by combining components. Many spells
share the same structure (ingredient check → mana cost → effect), making macros the natural tool.

**Features to demonstrate:**

- At least **two macro declarations** covering distinct patterns:
  1. `macro with-mana-cost cost body:` — wraps a body to first check `player/mana >= cost`,
     deduct mana, then execute body. Shows a resource-guard pattern.
  2. `macro craft-spell name ingredient body:` — wraps with ingredient check + logging + body.
     Shows a multi-param macro with a named body.
- Macro invocations in at least three different functions (reducing visible repetition)
- A `verify` block that checks a property of the macro-expanded code (e.g., `can-reach?` the
  `out-of-mana` scene from the workshop when mana starts low)
- At least one macro that uses a generated local name (demonstrating hygiene — the generated
  name must not collide with user-defined names)
- Post-condition on a spell-casting function using `path@before` (piggybacks on Demo 13 coverage
  but in a different context)
- Entity family `spells` (name, component, mana-cost, learned Bool)

**Scenes:** `workshop` (overview), `examine-shelf` (list known spells), `cast-spell`
(choose and cast; macro-expanded guard), `gather-components` (replenish ingredients),
`transcribe` (learn a new spell recipe), `out-of-mana` (defeat/rest state)

**Implementation checklist:**
- [ ] Write `demos/demo15_spellwright.sb` with two macro declarations
- [ ] Confirm macro expansion runs without error (compile + run)
- [ ] Confirm hygiene: generated names do not shadow user names (add a test in
  `tests/compiler/macro_spec.lua` using the demo source)
- [ ] Add CLI integration tests
- [ ] Run `busted tests/` — all tests green
- [ ] Update `code_map.md`
- [ ] Commit

---

#### Demo 16 — "The Cartographer's Web" (advanced find queries + search options + counterfactual simulate)

**File:** `demos/demo16_cartographers_web.sb`

**Theme:** A cartographer mapping a network of cities connected by roads and sea lanes.
Trade routes must be planned, supply lines checked, and future states explored.

**Features to demonstrate:**

- **`or-where`** — `find cities where (city/has-market = true) or-where (city/coastal = true)`
  to locate trade hubs; at least two `or-where` uses in different queries
- **`connected-to <path> via <relation>`** — check whether a remote city is connected to the
  capital via the `roads` relation: `find cities connected-to capital-city via roads`
- **`inverse-adjacent?`** — find all cities that have roads leading INTO a given city:
  `let inbound = inverse-adjacent? roads 'port-haven`
- **`find` with `order-by` and `limit`** combined with `or-where` in one query
- **`can-reach?` with `strategy: depth-first`** — verify a trade route is possible
- **`find-path` with `strategy: breadth-first` and `budget: 2`** — find optimal route under time budget
- **`counterfactual simulate: true`** — preview the effect of opening a new trade route
  including a scheduled `market-fluctuation` event and a trader NPC actor step
- Relation `roads` (bidirectional adjacency between cities)
- Entity family `cities` with fields: `name`, `population` (Int), `has-market` (Bool),
  `coastal` (Bool), `controlled-by` (enum)
- `schedule market-fluctuation every: [turn: +3]` — drives actor/schedule inclusion in simulate

**Scenes:** `map-room` (main hub), `survey-region` (run find queries, display results),
`plan-route` (use find-path with strategy/budget), `open-trade-route` (mutate roads relation,
use counterfactual simulate: true to preview), `crisis` (a city becomes cut off — verify
connected-to returns false)

**Verify block:** from-any-state with `strategy: breadth-first` and `depth: 6` — assert
capital is always connected to at least one coastal city.

**Implementation checklist:**
- [ ] Write `demos/demo16_cartographers_web.sb`
- [ ] Confirm `or-where` returns union of results (not intersection)
- [ ] Confirm `connected-to via` returns correct set
- [ ] Confirm `inverse-adjacent?` returns correct reverse-adjacency set
- [ ] Confirm `strategy:` and `budget:` params are accepted by `can-reach?` and `find-path`
- [ ] Confirm `counterfactual simulate: true` includes the scheduled event in the branch
- [ ] Add CLI integration tests
- [ ] Run `busted tests/` — all tests green
- [ ] Update `code_map.md`
- [ ] Commit

---

### Remaining Coverage Gaps (not yet scheduled as demos)

- **Bounded computation Lua handler** (`game:register_bounded`) — this is an embedding-API
  feature, not a `.sb` feature. A future `examples/bounded_lua_interop.lua` embedder script
  (alongside a matching `.sb` file) is the right vehicle, not a CLI demo. Deferred.
- **Multi-line lambda bodies** — will be covered naturally in Demo 13 (`find` query in
  `healers_ward.sb`). No additional demo needed.
- **`time-set!`** — covered adequately by demo10. No additional demo needed.
- **Custom tags and hooks** — covered by demo06. No additional demo needed beyond current coverage.

---

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] ANSI colour output in CLI for attributed dialogue.
- [ ] **`UList` runtime support** — `UList(T)` type exists in the checker but has no runtime
  operations (no list-append etc.). Either add builtins or document as a pure-declaration stub.
  (`UMap` is fully implemented as of pass 2.)
- [ ] Bounded computation Lua handler demo — `examples/bounded_lua_interop.lua` embedder script.


# StoryBase — Implementation Guide

---

## 1. Style Requirements

### 1.1 Language and Runtime

The implementation is written in **Lua 5.4** throughout. The parser uses **LPEG** for all lexing and grammar rules. No other external dependencies are permitted in the core; the debug server may use a minimal WebSocket library.

### 1.2 File and Module Layout

```
storybase/
  compiler/
    lexer.lua          -- tokenisation (LPEG)
    parser.lua         -- AST construction (LPEG)
    ast.lua            -- AST node constructors and predicates
    types.lua          -- type representation, state-space computation
    checker.lua        -- type checker, pure/transaction inference, write-set analysis
    codegen.lua        -- emit compiled game table
    compiler.lua       -- pipeline orchestrator
  runtime/
    state.lua          -- path store, O(1) read cache
    log.lua            -- transaction log: append, replay, query
    engine.lua         -- turn lifecycle, scene stack, time model
    scheduler.lua      -- schedule queue
    actors.lua         -- perception snapshots, deferred mutations, inbox
    random.lua         -- reproducible random sources
    search.lua         -- future-state search (BFS/DFS/best-first)
    query.lua          -- find, relation queries
    counterfactual.lua -- branched GameState
    migrate.lua        -- schema migration chain
    debug.lua          -- WebSocket dev server, hot reload, watches
  cli/
    main.lua           -- entry point: storybase <command>
    verify_cmd.lua     -- storybase verify
    migrate_cmd.lua    -- storybase migrate
    extract_cmd.lua    -- storybase extract-symbols
  lib/
    storybase.lua      -- public Lua interop API (game:call, game:get, etc.)
  tests/
    (mirror of compiler/ and runtime/ structure)
```

Every file begins with `local M = {}` and ends with `return M`. No module may write to global state; all shared state is passed explicitly.

### 1.3 Naming Conventions

| Thing | Convention | Example |
|-------|-----------|---------|
| Lua modules | `snake_case` file, `M` locally | `local M = {}` |
| Public functions | `snake_case` | `M.parse_file` |
| Private functions | `_snake_case` | `local function _resolve_path` |
| Constants | `UPPER_SNAKE` | `MAX_STACK = 16` |
| AST node kinds | string constants in `ast.lua` | `"fn_decl"`, `"match_expr"` |
| Type tags | string constants in `types.lua` | `"discrete"`, `"superficial"` |
| Error codes | `UPPER_SNAKE` strings | `"SUPERFICIAL_IN_COND"` |

### 1.4 Error Handling

All compiler errors are represented as structured tables, never bare Lua `error()` strings:

```lua
{ code    = "SUPERFICIAL_IN_COND",
  message = "String value in conditional expression",
  file    = "game.sb",
  line    = 42,
  col     = 7,
  note    = "player/name has type String (superficial)" }
```

The compiler accumulates all errors and returns them together rather than stopping at the first. Runtime errors (precondition failures, inbox overflow, spawn-at-capacity, etc.) follow the same structure and are routed through the debug hook system in dev mode.

### 1.5 Code Style

- **Indentation:** 2 spaces, no tabs.
- **Line length:** 100 characters soft limit; 120 hard limit.
- **Semicolons:** omitted (Lua convention).
- **String quotes:** double quotes for prose/messages, single quotes for short internal tokens/keys.
- **LPEG patterns:** defined as module-level locals prefixed by their grammar role:
  ```lua
  local P, R, S, C, Ct, Cg = lpeg.P, lpeg.R, lpeg.S, lpeg.C, lpeg.Ct, lpeg.Cg
  local tok_ident    = R('az','AZ') * (R('az','AZ','09') + P'-')^0
  local tok_integer  = (P'-')^-1 * R'09'^1
  ```
- **Comments:** inline comments for non-obvious logic only; doc-comments (`---`) on all public functions.
- **Tests:** every public function has at least one passing and one failing test.

---

## 2. Overall Architecture

### 2.1 Compiler Pipeline

```
Source text
    │
    ▼
┌─────────┐
│  Lexer  │  LPEG tokeniser — produces token stream with source positions
└────┬────┘
     │ token stream
     ▼
┌─────────┐
│  Parser │  LPEG grammar — produces untyped AST
└────┬────┘
     │ AST
     ▼
┌─────────────┐
│   Checker   │  Type checker / analyser (multiple passes):
│             │    1. Schema pass — collect all type/state/relation/scene names
│             │    2. Type-check pass — enforce discrete/superficial boundary,
│             │       check field types, resolve SymbolOf families
│             │    3. Pure/transaction inference — classify every function
│             │    4. Write-set analysis — compute static write-sets
│             │    5. State-space computation — bound sizes for search
│             │    6. Contract validation — verify pre/post well-formedness
│             │  Produces: typed AST + symbol table + diagnostics
└────┬────────┘
     │ typed AST
     ▼
┌──────────┐
│ Codegen  │  Emit compiled game table (Lua value, serialisable)
└────┬─────┘
     │ compiled game table
     ▼
  Runtime
```

### 2.2 Runtime Subsystems

```
┌──────────────────────────────────────────────────────────┐
│                        Engine                            │
│  (turn lifecycle, scene stack, time model)               │
│                                                          │
│  ┌───────────┐  ┌──────────┐  ┌──────────────────────┐  │
│  │   State   │  │   Log    │  │      Scheduler       │  │
│  │  (cache)  │◄─┤(ground   │  │ (pending event queue)│  │
│  │           │  │  truth)  │  └──────────────────────┘  │
│  └───────────┘  └──────────┘                            │
│                                                          │
│  ┌──────────────────────┐  ┌──────────────────────────┐  │
│  │       Actors         │  │         Search           │  │
│  │ (perception, inbox,  │  │ (BFS/DFS/best-first over │  │
│  │  deferred mutations) │  │  future state graph)     │  │
│  └──────────────────────┘  └──────────────────────────┘  │
│                                                          │
│  ┌─────────────────────┐   ┌──────────────────────────┐  │
│  │   Counterfactual    │   │   Debug / Hot Reload     │  │
│  │  (branched states)  │   │   (WebSocket, watches)   │  │
│  └─────────────────────┘   └──────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### 2.3 State Store

The state store maintains two representations simultaneously:

- **The log** — append-only sequence of `{seq, time, fn, path, old, new}` entries. This is the ground truth. Saving a game means serialising the log.
- **The cache** — a flat Lua table keyed by path string, holding the current projected value. This gives O(1) reads. Every `set!`, `inc!`, etc. updates the cache and appends to the log atomically.

On load, the log is replayed to reconstruct the cache. For long logs a periodic snapshot (full cache dump at a sequence number) can be stored alongside the log to make replay O(log size since last snapshot) rather than O(total log size).

### 2.4 Future-State Search

The search engine operates on a **symbolic state** — a copy of the state cache — and applies successor functions (all reachable transaction functions + scheduled events + actor steps) to enumerate the future state graph.

Key implementation properties:
- Each node in the search graph is a full state cache snapshot. Nodes are identified by a hash of their content to detect cycles.
- Random sources are branched: `random-int 0 5` produces 6 successor states, one per outcome, each weighted.
- `bounded` computations branch over their declared `distribution` (uniform or conditioned).
- Branches below the configurable `probability-threshold` (default 0.01, engine-config settable) are pruned.
- The search engine is implemented as a coroutine-based iterator so it can be suspended mid-search for streaming results and to respect wall-clock time budgets.

### 2.5 Debug Server

The debug server runs as a coroutine alongside the engine in dev mode. It opens a TCP socket on the configured port (default 7373) and speaks a newline-delimited JSON protocol over it. Hot reload is triggered by the `reload` command or file-system watch events. The server is compiled out entirely in production builds (`debug-only` tag).

---

## 3. Testing Plan

### 3.1 Framework

Use **[busted](https://github.com/lunarmodules/busted)** (the standard Lua BDD test framework). Run with:

```
busted tests/
```

Test files mirror the source layout: `tests/compiler/lexer_spec.lua` tests `compiler/lexer.lua`, etc.

### 3.2 Lexer Tests (`tests/compiler/lexer_spec.lua`)

| Test group | Coverage |
|-----------|----------|
| Token types | integer, float, bool, string, multi-line string, symbol, path, path-with-interpolation, named-arg, operators, keywords |
| Whitespace | leading/trailing, blank lines, comment stripping |
| Indentation | correctly emits INDENT/DEDENT tokens; mixed levels |
| Error cases | unterminated string, illegal character, mixed tabs/spaces |
| Source positions | every token carries correct `(file, line, col)` |

### 3.3 Parser Tests (`tests/compiler/parser_spec.lua`)

| Test group | Coverage |
|-----------|----------|
| Type declarations | enum, range alias, record with `with`, variant |
| State declarations | scalar, inline record, entity family, doc string |
| Expressions | all operators, precedence, inline grouping, `??` |
| Control flow | `when`, `if/else`, `match`, `cond`, `for`, `while`, `let` |
| Lambda expressions | single-expr, multi-line, nested |
| Collection literals | set, list, map; disambiguation rule |
| Scenes | narration, conditional narration, choices, guards, all sigils |
| Functions | declaration, pre/post, tags, pure vs transaction |
| Mutation primitives | all forms including indexed list access |
| Module / import | flat and namespaced import, cycle detection |
| Error recovery | parser continues after a bad expression to collect further errors |

### 3.4 Type Checker Tests (`tests/compiler/checker_spec.lua`)

One test per compiler rule. Priority cases:

| Rule | Positive | Negative |
|------|---------|---------|
| Discrete in condition | `player/health > 0` | `player/name = "Alice"` |
| Superficial assignment | assigning string computed from enum | assigning random output to String |
| Random → discrete only | `random-int 0 5` → Int | `random-choice ["a","b"]` → String |
| Write-path restriction | typed `{npc}` interpolation | untyped `{p}` in write position |
| Pure/transaction inference | pure fn with only reads | pure fn calling `set!` |
| `SymbolOf` family typing | `for npc in path-list npcs` typed correctly | using unresolved symbol in path |
| `with` mixin | field splice, default override | type override attempt |
| Conflicting `with` fields | non-conflicting two mixins | same field from two mixins |
| `perceives` enforcement | accessing declared path in behavior | accessing undeclared path |
| Lambda purity | lambda with read | lambda calling `set!` |
| Import cycles | two files, no cycle | A imports B imports A |

### 3.5 Runtime Unit Tests

**State store** (`tests/runtime/state_spec.lua`):
- Path read/write, nil for uninstantiated family members
- `inc!`/`dec!` clamping; `clamp-event` fires in debug mode
- `add!` to Set, `push!` to List, overflow behaviour
- `spawn!` / `despawn!`; reads after despawn return nil
- Log append and replay produces identical cache

**Transaction log** (`tests/runtime/log_spec.lua`):
- Sequential numbering, no gaps
- `query-at` returns correct value at a past time
- `query-history` returns ordered change list
- `undo!` appends undo event, state matches checkpoint
- Log round-trips through serialisation/deserialisation

**Scheduler** (`tests/runtime/scheduler_spec.lua`):
- `every:` fires at correct intervals
- `at:` fires once at correct tick
- `offset:` applied correctly
- `cancel-schedule!` prevents future fires
- Pending queue appears in log and is included in search

**Actors** (`tests/runtime/actors_spec.lua`):
- Perception snapshot contains only declared paths
- Deferred mutation applied after all behaviors
- Conflict resolution: higher-priority actor wins, conflict logged
- Inbox cleared each turn; unhandled messages are dropped
- `send!` to full inbox raises runtime error

**Turn lifecycle** (`tests/runtime/engine_spec.lua`):
- Full six-step cycle with player action
- Autonomous turn (no player input): steps 2–6 only
- Time advances once per turn unless already advanced
- Actor-driven turns (NPC speed scenario): n autonomous turns per player turn

### 3.6 Integration Tests (`tests/integration/`)

Each integration test loads the complete example from §25 of the spec and exercises a scenario end-to-end.

| Scenario | Verifies |
|---------|---------|
| Player walks village → forest → dungeon | Location state, time advancement, `move-to` |
| Combat: attack, enemy attacks, potion, flee | Combat state machine, saturation arithmetic, computed gotos |
| Buy health potion, insufficient gold | `can-afford?` guard, choice visibility, gold decrement |
| Deliver ore to blacksmith | Multi-step quest flag progression, actor behavior |
| Random encounter (seeded) | Reproducible random, spawn!, enter-combat |
| Morning reset schedule fires | Scheduler, autonomous turn, NPC location reset |
| Blacksmith alert → guard becomes hostile | Actor messaging, send!/inbox, deferred mutations |
| Player dies, undo restores | Checkpoint, undo!, log audit trail |
| Complete example verify blocks | All five `verify` assertions pass via search engine |
| Save → reload → state identical | Log serialise/deserialise, cache reconstruction |

### 3.7 Search Engine Tests (`tests/runtime/search_spec.lua`)

| Test | Description |
|------|-------------|
| `can-reach?` basic | Reachable state found within depth |
| `can-reach?` unreachable | Returns false, does not hang |
| `find-path` returns action sequence | Sequence, when applied, reaches goal |
| `verify-always` satisfied | Holds in all futures to depth N |
| `verify-always` violated | Returns counterexample state + path |
| `probability` | Float result in [0,1]; extreme cases (0 and 1) |
| Random branching | Each random outcome explored; probability weights sum to 1 |
| `bounded` branching | Branches over declared distribution |
| Cycle detection | Loop in state graph does not cause infinite search |
| Probability pruning | Branches below threshold skipped; result noted as approximate |

### 3.8 Migration Tests (`tests/runtime/migrate_spec.lua`)

- `rename`: path renamed, value preserved
- `add`: new path initialised to declared value
- `drop`: path removed silently
- `transform`: function applied to each value
- `rename-enum`: enum literal renamed in all matching paths
- Chain: version 1 → 2 → 3 applied in order
- Missing intermediate version: error

### 3.9 Debug / Hot Reload Tests (`tests/runtime/debug_spec.lua`)

- `get-state` with pattern returns correct paths
- `eval` pure expression returns correct value
- `time-travel` returns frozen state; live state unaffected
- `reload` function body: state preserved, new logic applied
- `reload` new enum value: legal immediately
- `reload` removed enum value: error if held by current state
- `reload` narrowed range: error if current state out of range
- Watch fires on matching mutation; `watch-when` fires on condition becoming true

### 3.10 Property / Fuzz Tests (`tests/fuzz/`)

Run with a configurable seed count (default 1000 in CI).

- **Parser fuzz**: random token sequences never crash the parser (graceful error only)
- **State-space arithmetic**: computed sizes always ≥ actual reachable state count (for small hand-crafted examples where the true count is known)
- **Log replay determinism**: replay of any log always produces same final cache
- **Counterfactual isolation**: mutations in a counterfactual never appear in live state

---

## 4. Implementation Phases

### Phase 1 — Core Language (Lexer, Parser, Basic Checker)

**Goal:** `storybase compile game.sb` produces a valid compiled table for a schema-only file with no logic.

Deliverables:
- Lexer with full token set and source positions
- Parser producing AST for: type declarations, state declarations, relation declarations, engine-config, module header, import
- Checker pass 1 (schema collection): all type names, state paths, relation names resolved
- Checker pass 2 (basic type-check): field types valid, defaults type-correct, bounded integers well-formed
- Structured diagnostics output
- `storybase compile` CLI command

Tests: lexer suite, parser suite (declarations only), checker type-error cases.

---

### Phase 2 — Expressions, Functions, and the Type Boundary

**Goal:** All function declarations type-check correctly; the discrete/superficial boundary is enforced.

Deliverables:
- Parser for all expression forms: infix, prefix, `??`, path interpolation, lambdas, collection literals, `match`, `cond`, `if/else`, `when`, `for`, `while`, `let`
- Checker pass 3 (pure/transaction inference)
- Checker pass 4 (write-set analysis)
- Checker pass 5 (state-space computation)
- Compiler boundary enforcement: errors for superficial-in-condition, random→superficial, etc.
- `warn-untyped-symbol` warning

Tests: full expression parser suite, all checker rule tests.

---

### Phase 3 — Runtime Core

**Goal:** A game with player actions, scenes, and no actors runs end-to-end and produces a correct transaction log.

Deliverables:
- State store (cache + log)
- All scalar and collection mutation primitives
- Saturation arithmetic with `clamp-event`
- Scene stack: `->`, `=>`, `<-`, computed gotos, `goto-scene!` etc.
- Basic turn lifecycle (player action → schedule → time advance)
- Time model: `time-inc!`, absolute/relative time literals
- Save/load via log serialisation
- `storybase run` REPL for interactive testing

Tests: state store unit tests, log unit tests, engine lifecycle tests, integration scenario 1–3.

---

### Phase 4 — Actors, Messaging, and Scheduling

**Goal:** The complete example in §25 runs correctly including all actor behaviors and the morning reset schedule.

Deliverables:
- Actor declaration and registration
- Perception snapshot construction and enforcement
- Behavior function dispatch
- Deferred mutation queue with conflict resolution
- Actor messaging: `send!`, inbox delivery, `ActorMsg` variant matching
- Scheduler: `every:`, `at:`, `offset:`, `schedule!`, `cancel-schedule!`
- Full six-step turn lifecycle including autonomous turns
- NPC speed modelling (autonomous turns between player turns)

Tests: actor unit tests, scheduler unit tests, integration scenarios 4–7.

---

### Phase 5 — Query and Future-State Search

**Goal:** `storybase verify` passes all five verify blocks from §25.

Deliverables:
- `find` form with all clauses (`where`, `or-where`, `within`, `connected-to`, `order-by`, `limit`, `count`)
- Relation queries: `adjacent?`, `reachable?`, `shortest-path`, `reachable-set`, `inverse-adjacent?`
- Search engine (BFS, DFS, best-first): `can-reach?`, `find-path`, `verify-always`, `find-counterexample`, `probability`, `optimal-path`
- `verify` block evaluation with all clause types
- `storybase verify` CLI command
- Probability pruning; approximate-result annotation

Tests: search engine unit tests, all integration verify blocks, property tests.

---

### Phase 6 — Advanced Features

**Goal:** Counterfactuals, bounded computations, undo, and migration all work.

Deliverables:
- `counterfactual` form: `from:`, `do:`, `simulate:`, nesting depth limit
- `(in-state gs)` path redirect in all pure queries
- `bounded` declarations and registration; `uses-bounded` tag
- Lua handler registration and call convention (`state_snapshot` table)
- `undo!` with checkpoint targeting; log audit entries
- Schema migration chain: all migration operations, `storybase migrate` CLI

Tests: counterfactual unit tests, migration unit tests, integration scenarios 8–10.

---

### Phase 7 — Debug Tooling

**Goal:** Full dev-mode experience: hot reload, time-travel, watches, WebSocket protocol.

Deliverables:
- WebSocket debug server (port 7373; disabled in production)
- All emitted events: `mutation`, `scene-change`, `message-sent`, `schedule-fired`, `fn-call`, `spawn-event`, `despawn-event`, `clamp-event`, `reload`
- All accepted commands: `get-state`, `eval`, `reload`, `set-breakpoint`, `clear-breakpoint`, `time-travel`, `get-log`
- Hot reload with all behaviour variants from §18.2
- `watch` and `watch-when` declarations (stripped from production)
- Doc string surfacing in schema browser
- Production build mode: strips `debug-only` declarations, contracts (unless `strict-contracts: true`), watch declarations

Tests: debug/hot reload unit tests, WebSocket protocol conformance.

---

### Phase 8 — Macro System, Lua Interop, and Polish

**Goal:** Full public API; macro system; performance acceptable for a game with 20 NPCs and depth-50 search.

Deliverables:
- Hygienic macro system: `macro` declarations, expansion before type-check
- Full `storybase.lua` Lua interop API: `load`, `call`, `get`, `find`, `on`, `choose`, `eval`, `counterfactual`, `register_bounded`
- `storybase extract-symbols` CLI
- State cache snapshot optimisation for long logs
- Search engine coroutine budget (wall-clock time limit per search call)
- Tile grid extension (`defgrid`, spatial queries)

Tests: macro expansion tests, Lua interop tests, performance benchmarks.

---

## 5. Dependency and Risk Notes

| Area | Risk | Mitigation |
|------|------|-----------|
| LPEG indentation parsing | Indentation-sensitive grammars are non-trivial in LPEG | Implement a pre-pass that converts indentation to explicit INDENT/DEDENT tokens; parser then treats them as ordinary terminals |
| Future-state search performance | State-space explosion for complex games | Implement early in Phase 5 with aggressive cycle detection and probability pruning; expose `depth:` and time-budget parameters |
| Hot reload correctness | Schema changes can leave state in invalid intermediate forms | Apply changes transactionally: validate entire new schema against current state before committing any change |
| Lua coroutine overhead for search | Search may spawn thousands of coroutines | Use an explicit stack-based BFS/DFS iterator rather than coroutines for inner search loop; use coroutines only at the top-level suspension boundary |
| Log growth in long sessions | Unbounded log can make save files large and replay slow | Implement snapshot-at-checkpoint in Phase 3; document log compaction CLI in Phase 8 |


# StoryBase — Implementation TODO

Phases follow [implementation.md](implementation.md). Check off items as they are completed.
Milestone goals are marked **M**.

---

## Current Status and Next Steps (2026-03-26)

**Phase 1 COMPLETE ✅** — `lua5.4 cli/main.lua compile tests/test01_minimal.sb` outputs
"Compilation succeeded" with 0 errors/warnings. 410 tests passing.

**Fixes made to reach milestone:**
- Parser: Phase-2+ declarations (scene, fn, actor, etc.) now silently skipped instead of erroring.
- Lexer: CRLF line endings normalised to LF at start of tokenize.
- Lexer: `.` (period) added as an OP token (needed for member-access expressions in Phase 2).

**Immediate next steps (Phase 2):**
1. Expression parser: literals, identifiers, binary ops, function calls, member access, match, cond
2. Statement parser: let, assignment, if/else, for, while, pass, return
3. Scene declarations: narration blocks, choice blocks, scene transitions
4. Checker pass 3: expression type inference and checking
5. Codegen: emit `fns`, `verifies`, `watches` entries
6. Test milestone: `lua5.4 cli/main.lua compile tests/test02_choices.sb` (no errors)

**Known gaps in Phase 1 (deferred to later phases):**
- Scene declaration support (Phase 2)
- Import resolution (Phase 2)
- Record field default type-checking (Phase 2)
- `SymbolOf(Family)` family-name resolution (Phase 2)
- `warn-untyped-symbol` warning (Phase 2)

---

## Phase 1 — Core Language (Lexer, Parser, Basic Checker)

**M Goal:** `storybase compile game.sb` produces a valid compiled table for a schema-only file.

### Scaffold

- [x] Create directory structure: `compiler/`, `runtime/`, `cli/`, `lib/`, `tests/`
- [x] `compiler/ast.lua` — node constructor pattern; all declaration, expression, and statement kinds
- [x] `compiler/compiler.lua` — pipeline orchestrator (lexer → parser → checker → codegen)
- [x] `cli/main.lua` — entry point, command dispatch
- [x] Structured error table format `{code, message, file, line, col, note}`
- [x] Error accumulator (collect all errors; no early exit)
- [x] Warning support alongside errors

### Lexer (`compiler/lexer.lua`) ✅ DONE (2026-03-25)

- [x] LPEG imports and module scaffold
- [x] INDENT/DEDENT pre-pass (convert indentation to explicit tokens)
- [x] Token: integers (positive and negative)
- [x] Token: floats
- [x] Token: booleans (`true` / `false`)
- [x] Token: single-line strings with escape sequences (`\n`, `\\`, `\"`)
- [x] Token: multi-line strings (`"""..."""`) with indentation stripping
- [x] Token: symbol literals (`'name`)
- [x] Token: paths (any token containing `/`)
- [x] Token: path with variable interpolation (`{var}` segment)
- [x] Token: named arguments (`name:`)
- [x] Token: infix operators (`=`, `!=`, `<`, `>`, `<=`, `>=`, `+`, `-`, `*`, `/`, `??`)
- [x] Token: boolean operators (`and`, `or`, `not`)
- [x] Token: keywords (`fn`, `state`, `type`, `scene`, `when`, `if`, `else`, `match`, `cond`, `for`, `while`, `let`, `in`, `with`, `import`, `module`, `relation`, `actor`, `schedule`, `bounded`, `macro`, `verify`, `watch`, `watch-when`, `pre`, `post`, `tags`, `true`, `false`, `pass`)
- [x] Token: identifiers (`kebab-case`)
- [x] Token: block sigils (`*`, `->`, `=>`, `<-`)
- [x] Token: collection delimiters (`{`, `}`, `[`, `]`, `(`, `)`)
- [x] Whitespace stripping (spaces, blank lines)
- [x] Comment stripping (`#` to end of line)
- [x] Source position `(file, line, col)` attached to every token
- [x] Error: unterminated string literal
- [x] Error: illegal character
- [x] Error: mixed tabs and spaces

### Parser (`compiler/parser.lua`) — declarations only  ✅ DONE (2026-03-25)

- [x] Module header: `module name version: N`
- [x] `import "file"` (flat)
- [x] `import "file" as Alias` (namespaced)
- [ ] Import cycle detection (compile error) — deferred to checker
- [x] `schema-version: N`
- [x] `engine-config:` block with all known keys
- [x] `time-model:` block (`axes:`, `wrap:`)
- [x] `type Name = val | val | ...` (enum)
- [x] `type Name = TypeExpr` (range alias)
- [x] `type Name:` record with `field: Type = default` lines
- [x] `with OtherRecord` mixin inside record
- [x] `type Name:` variant with `| branch: fields` lines
- [x] `state path: Type` (scalar)
- [x] `state path: Type = Constructor(...)` (with default)
- [x] `state path:` inline record block
- [x] `state family/{var}: Type  max: N` (entity family)
- [x] `relation name: T -> Set(T, N):` with optional static data block
- [x] Doc string (string literal immediately before any declaration)
- [x] Error recovery: parser continues after a bad declaration

Note: type expressions (Bool, Int, Enum, Option, Set, List, Symbol, SymbolOf,
String, Float, UList, UMap, named, function) are parsed directly in parser.lua.
A separate types.lua is not needed for Phase 1.

### Type Expressions (`compiler/types.lua`) ✅ DONE inline — no separate file needed

> **Deviation:** A separate `types.lua` was not created. Type expression parsing is handled
> directly in `compiler/parser.lua` (`parse_type_expr`), type descriptors are emitted in
> `compiler/codegen.lua` (`emit_type_desc`), and state-space size computation lives in
> `compiler/codegen.lua` (`state_space_size`). The discrete/superficial tag is deferred to
> Phase 2 when it is actually needed for boundary enforcement.

- [x] `Bool`
- [x] `Int(min, max)`
- [x] `Enum(v1, v2, ...)` (inline)
- [x] `Option(T)`
- [x] `Set(T, max)`
- [x] `List(T, max)`
- [x] `Symbol` (untyped)
- [x] `SymbolOf(Family)`
- [x] `String`, `Float` (superficial)
- [x] `UList(T)`, `UMap(K, V)` (superficial unbounded)
- [x] `RecordName`, `VariantName` (declared named types)
- [x] `(T -> R)`, `(T U -> R)` (function/lambda types)
- [x] State-space size computation for all discrete types (in codegen.lua)
- [ ] Discrete / superficial tag on every type — deferred to Phase 2

### Checker — Pass 1 (Schema Collection) ✅ DONE (2026-03-25)

- [x] Collect all declared type names into symbol table
- [x] Collect all state paths (scalar and family)
- [x] Collect all relation names
- [ ] Collect all scene names (auto-generate `SceneId` enum) — deferred to Phase 2
- [x] Resolve forward references within the same compilation unit (pass1 collects all names before pass2 resolves)
- [ ] Resolve imported names (flat and namespaced) — deferred to Phase 2
- [x] Error: duplicate type/state/scene/relation name
- [x] Error: undefined type reference

### Checker — Pass 2 (Basic Type-Check) ✅ DONE (2026-03-25)

- [x] Field types reference declared types (or built-in type expressions)
- [ ] Record field defaults are type-correct — deferred to Phase 2 (defaults emitted but not type-checked)
- [x] `Int(min, max)` bounds well-formed (`min <= max`)
- [x] `with` mixin: all fields spliced at the `with` point
- [x] `with` mixin: default override accepted (override after mixin allowed; no error emitted)
- [ ] `with` mixin: type override rejected — deferred to Phase 2
- [x] `with` mixin: conflicting field from two different `with` sources → error
- [x] Entity family `max: N` stored and used for state-space computation
- [ ] `SymbolOf(Family)` — family name resolves to a declared entity family — deferred to Phase 2
- [ ] `warn-untyped-symbol` for bare `Symbol` in any discrete position — deferred to Phase 2

### Codegen (`compiler/codegen.lua`) ✅ DONE (2026-03-26)

- [x] Emit compiled game table (serialisable Lua value)
- [x] Schema section: types, state paths, relations (scenes=0 in Phase 1)
- [x] Function stubs (fns/verifies/watches are empty tables in Phase 1)

### CLI — Phase 1 ✅ DONE (scaffolded with initial commit)

- [x] `storybase compile <file>` command
- [x] Print diagnostics to stderr with file/line/col
- [x] Exit code 0 on success, non-zero on any error
- [x] Print summary (type count, state path count, scenes, state-space size)

### Tests — Phase 1 ✅ DONE (2026-03-26)

- [x] `tests/compiler/lexer_spec.lua` — all token types
- [x] `tests/compiler/lexer_spec.lua` — indentation / INDENT / DEDENT
- [x] `tests/compiler/lexer_spec.lua` — source positions on all tokens
- [x] `tests/compiler/lexer_spec.lua` — error cases (unterminated, illegal char, mixed indent)
- [x] `tests/compiler/parser_spec.lua` — all declaration forms
- [x] `tests/compiler/parser_spec.lua` — module and import
- [x] `tests/compiler/parser_spec.lua` — error recovery (continues after bad declaration)
- [x] `tests/compiler/checker_spec.lua` — pass 1: undefined type reference
- [x] `tests/compiler/checker_spec.lua` — pass 1: duplicate name
- [ ] `tests/compiler/checker_spec.lua` — pass 2: type mismatch in field default — deferred to Phase 2
- [x] `tests/compiler/checker_spec.lua` — pass 2: `with` mixin rules
- [ ] `tests/compiler/checker_spec.lua` — pass 2: `warn-untyped-symbol` — deferred to Phase 2
- [x] `tests/compiler/codegen_spec.lua` — all schema section emitters (31 tests)

**M Milestone:** `tests/test01_minimal.sb` compiles without errors or warnings. ✅ DONE (2026-03-26)

---

## Phase 2 — Expressions, Functions, and the Type Boundary

**M Goal:** All function declarations type-check; the discrete/superficial boundary is enforced.

### Parser Extensions

- [ ] Infix comparisons with correct precedence (`*`/`/` > `+`/`-` > comparisons > `not` > `and` > `or` > `??`)
- [ ] Prefix function calls (multi-argument, unbounded arity)
- [ ] Nil-coalescing `??` (right side lazy)
- [ ] Arithmetic operators (infix)
- [ ] Inline path interpolation `{varname}` within a path segment
- [ ] Collection literal: set `{'a, 'b}` / `(set)` (empty)
- [ ] Collection literal: list `['a, 'b]` / `[]` (empty)
- [ ] Collection literal: map `{k: v, ...}` / `{}` (empty)
- [ ] Collection literal disambiguation rule (first element followed by `:` → map)
- [ ] `match expr: arm1: val, arm2: val, _: val` (expression and statement forms)
- [ ] `cond: cond1: body, cond2: body, _: body`
- [ ] `if cond: body` / `if cond: body else: body`
- [ ] `when cond: body` (no else)
- [ ] `for var in expr: body`
- [ ] `while cond: body`
- [ ] `let name = expr ...: body` (sequential bindings)
- [ ] Lambda expression `fn(params): single-expr`
- [ ] Lambda expression `fn(params):` multi-line body block
- [ ] Function declaration `fn name args: body`
- [ ] `pre:` and `post:` blocks inside function declarations
- [ ] `tags: [name, ...]` inside function declarations
- [ ] `path@before` expression in `post:` blocks
- [ ] All mutation primitives: `set!`, `inc!`, `dec!`, `add!`, `remove!`, `clear!`, `push!`, `pop!`
- [ ] Relation mutations: `relate!`, `unrelate!`
- [ ] `spawn!`, `despawn!`
- [ ] `send!`
- [ ] `time-inc!`
- [ ] `undo!`, `undo! steps: N`
- [ ] Scene navigation primitives: `goto-scene!`, `enter-scene!`, `exit-scene!`
- [ ] Scene navigation sigils in scene bodies: `->`, `->()`, `=>`, `<-`
- [ ] Indexed path access: `path[n]`, `path[-n]`, `path[a:b]`
- [ ] Narration inline expressions: `{expr}` inside scene text lines

### Checker — Pass 3 (Pure/Transaction Inference)

- [ ] Classify every function as pure or transaction (no annotation required)
- [ ] Pure: calls no mutation primitives directly or transitively
- [ ] Transaction: calls any mutation primitive directly or transitively
- [ ] Error: pure function calls mutation primitive
- [ ] Error: pure function called from write position
- [ ] Error: transaction function called inside `find where` clause
- [ ] Error: transaction function called inside `verify` condition
- [ ] Lambda purity: lambdas are always pure; error if lambda body calls mutation
- [ ] `uses-bounded` tag auto-applied to any function calling a `bounded` computation

### Checker — Pass 4 (Write-Set Analysis)

- [ ] Compute static write-set for every transaction function
- [ ] Static paths always legal in write position
- [ ] `{var}` interpolation legal in write position only if `var` has a declared `SymbolOf` type
- [ ] Error: untyped variable in write position
- [ ] Error: dynamic path construction (`path-join` etc.) in write position

### Checker — Pass 5 (State-Space Computation)

- [ ] Compute state-space size for all discrete types
- [ ] Correct formula for `List(T, max)`: Σ |T|^i for i = 0..max
- [ ] Total game state-space size reported in compile summary
- [ ] `warn-untyped-symbol` for `Symbol` in any logic position (search precision warning)

### Checker — Pass 6 (Contract Validation)

- [ ] `pre:` conditions are pure boolean expressions
- [ ] `post:` conditions are pure boolean expressions
- [ ] `path@before` references are valid paths present in the enclosing function's write-set
- [ ] `perceives:` enforcement: error if behavior function reads a path not covered by perceives patterns

### Compiler Boundary Enforcement

- [ ] Error: superficial value in any conditional (`if`, `when`, `cond`, `match`)
- [ ] Error: superficial value passed where discrete type expected
- [ ] Error: random source producing a superficial value
- [ ] Allowed: superficial value computed from discrete (e.g. `match` → `String`)

### Codegen — Full Functions

- [ ] Emit all function declarations with typed AST
- [ ] Emit scene declarations with narration, choices, guards, sigils
- [ ] Emit actor declarations, behavior references, perceives patterns
- [ ] Emit schedule declarations
- [ ] Emit verify blocks
- [ ] Emit watch declarations (tagged `debug-only`)

### Tests — Phase 2

- [ ] `tests/compiler/parser_spec.lua` — all expression forms and operator precedence
- [ ] `tests/compiler/parser_spec.lua` — all control flow forms (when/if/match/cond/for/while/let)
- [ ] `tests/compiler/parser_spec.lua` — lambda (single-expr, multi-line)
- [ ] `tests/compiler/parser_spec.lua` — collection literals and disambiguation rule
- [ ] `tests/compiler/parser_spec.lua` — all mutation primitives
- [ ] `tests/compiler/parser_spec.lua` — pre:/post:/tags: in function declarations
- [ ] `tests/compiler/checker_spec.lua` — discrete/superficial boundary (all positive and negative cases)
- [ ] `tests/compiler/checker_spec.lua` — pure/transaction inference (all cases)
- [ ] `tests/compiler/checker_spec.lua` — write-set analysis and restrictions
- [ ] `tests/compiler/checker_spec.lua` — `perceives:` enforcement
- [ ] `tests/compiler/checker_spec.lua` — lambda purity rule
- [ ] `tests/compiler/checker_spec.lua` — import cycles

**M Milestone:** `tests/test02_choices.sb` and `tests/test03_types.sb` compile without errors.

---

## Phase 3 — Runtime Core

**M Goal:** A game with player actions and scenes runs end-to-end with a correct transaction log.

### State Store (`runtime/state.lua`)

- [ ] Flat Lua table keyed by path string (the cache)
- [ ] `get(path)` → value or nil for uninstantiated paths
- [ ] `set!(path, value)` — update cache, append log entry
- [ ] `inc!(path, amount)` — add with clamping to declared `Int(min, max)` range
- [ ] `dec!(path, amount)` — subtract with clamping
- [ ] `add!(path, value)` — add to Set; error/reject if at max capacity
- [ ] `remove!(path, value)` — remove from Set (no-op if absent)
- [ ] `clear!(path)` — empty a Set or List
- [ ] `push!(path, value)` — append to List; runtime error if at max capacity
- [ ] `pop!(path)` — remove and return last element of List; error if empty
- [ ] Indexed List read: `path[n]` (positive and negative indices)
- [ ] Indexed List write: `path[n] = value`
- [ ] List slice read: `path[a:b]`
- [ ] `spawn!(family, key, record)` — instantiate family member; error if key exists
- [ ] `despawn!(family, key)` — remove family member; subsequent reads return nil
- [ ] `path-exists?(path)` — Bool predicate
- [ ] `path-list(family)` — List of all instantiated keys
- [ ] `clamp-event` hook fires in debug mode on every clamped inc!/dec!

### Transaction Log (`runtime/log.lua`)

- [ ] Append log entry: `{seq, time, fn, path, old, new}`
- [ ] Sequential numbering with no gaps
- [ ] Atomic: cache update and log append happen together (no partial state)
- [ ] `query-at(path, time)` — value at a specific time
- [ ] `query-history(path, from, to)` — ordered list of `{time, old, new}`
- [ ] `query-changes(path, last-n)` — most recent N changes
- [ ] Serialise log to file (JSON or Lua table format)
- [ ] Deserialise log file and replay to reconstruct cache
- [ ] Snapshot: save full cache state at a given sequence number
- [ ] Load from snapshot + delta log (faster replay)
- [ ] Round-trip test: serialise → deserialise → identical cache

### Engine (`runtime/engine.lua`) — Core

- [ ] Scene stack: push, pop, peek current scene
- [ ] `scene-stack-max` enforcement (runtime error on overflow)
- [ ] Recursive scene detection (compile warning)
- [ ] `->` goto: transition without stack change
- [ ] `->` computed goto: evaluate `SceneId` expression
- [ ] `=>` enter: push caller, transition to named scene
- [ ] `<-` exit: pop stack, return to previous scene
- [ ] `goto-scene!`, `enter-scene!`, `exit-scene!` imperative equivalents
- [ ] Scene rendering: emit narration lines to presentation layer
- [ ] Scene conditional narration: `[cond] text` shown only when cond holds
- [ ] Scene choices: enumerate with `*` sigil
- [ ] Choice guard: `* [cond] text` hidden when cond is false
- [ ] Player choice dispatch by index into the visible (not total) choice list
- [ ] Inline narration expressions: evaluate `{expr}` and convert to display string
- [ ] Time model: declare axes and wrap behaviour at startup
- [ ] `time-inc!` with named axis and explicit value
- [ ] Absolute time set via time literal
- [ ] Basic turn lifecycle: player action → schedule check → time advance

### Save / Load

- [ ] `storybase run <file>` — compile, initialise state from defaults, start turn loop
- [ ] Save: serialise log to a `.log` file
- [ ] Load: deserialise log, replay to current state, resume

### CLI — Phase 3

- [ ] `storybase run <file>` command
- [ ] Simple text REPL: display current scene narration and numbered choices
- [ ] Accept choice index from stdin; dispatch to engine
- [ ] `storybase run <file> --save <path>` / `--load <path>`

### Tests — Phase 3

- [ ] `tests/runtime/state_spec.lua` — get, set!, inc!/dec! clamping
- [ ] `tests/runtime/state_spec.lua` — Set mutations (add!, remove!, clear!, overflow)
- [ ] `tests/runtime/state_spec.lua` — List mutations (push!, pop!, overflow, indexed access)
- [ ] `tests/runtime/state_spec.lua` — spawn!/despawn!, nil reads after despawn
- [ ] `tests/runtime/state_spec.lua` — path-exists?, path-list
- [ ] `tests/runtime/log_spec.lua` — sequential numbering, atomic updates
- [ ] `tests/runtime/log_spec.lua` — query-at, query-history, query-changes
- [ ] `tests/runtime/log_spec.lua` — serialise → deserialise → identical cache
- [ ] `tests/runtime/engine_spec.lua` — scene stack push/pop/overflow
- [ ] `tests/runtime/engine_spec.lua` — all navigation sigils and imperatives
- [ ] `tests/runtime/engine_spec.lua` — choice guard evaluation
- [ ] `tests/runtime/engine_spec.lua` — time advance
- [ ] Integration scenario 1: player walks village → forest → dungeon
- [ ] Integration scenario 2: combat state machine (attack, potion, flee)
- [ ] Integration scenario 3: buy potion with gold guard

**M Milestone:** `tests/test04_control_flow.sb` and `tests/test05_log_and_time.sb` (excluding verify/schedule) run interactively.

---

## Phase 4 — Actors, Messaging, and Scheduling

**M Goal:** The §25 complete example runs including actor behaviors and the morning reset schedule.

### Actors (`runtime/actors.lua`)

- [ ] Actor registration at load time (from compiled game table)
- [ ] Perception snapshot: build filtered state copy from `perceives:` path patterns
- [ ] Perception snapshot: enforce compiler rule (behavior fn may only read perceived paths)
- [ ] Behavior function dispatch: call behavior fn with snapshot as read context
- [ ] Deferred mutation queue: collect all writes from all behavior functions
- [ ] Conflict detection: two actors writing the same path in the same turn
- [ ] Conflict resolution: higher-priority actor's write wins
- [ ] Conflict logging: all conflicts appended to transaction log
- [ ] `send!` — enqueue typed `ActorMsg` to named actor's inbox
- [ ] Inbox bounded (`List(ActorMsg, N)`): runtime error if inbox is full
- [ ] Message delivery step: move pending messages from send queue into inboxes
- [ ] Inbox clearing at end of each turn
- [ ] Unhandled inbox messages are dropped (no dead-letter queue)
- [ ] Variant pattern matching for inbox messages (`match msg: branch {fields}: ...`)

### Scheduler (`runtime/scheduler.lua`)

- [ ] Static `schedule` declarations registered at load time
- [ ] `every: [axis: +N]` trigger: fire at regular intervals
- [ ] `at: [axis: N]` trigger: fire once at absolute time
- [ ] `offset: [axis: N]` applied to `every:` triggers
- [ ] `schedule!` imperative: create a named scheduled event from within a transaction fn
- [ ] `cancel-schedule!` imperative: cancel a named scheduled event
- [ ] Pending schedule queue is itself discrete logged state
- [ ] Schedule creation and cancellation appear in the transaction log
- [ ] Scheduled event appears in the log when it fires

### Engine — Full Turn Lifecycle

- [ ] Step 1: Player action (optional — skipped for autonomous turns)
- [ ] Step 2: Message delivery (pending → inboxes)
- [ ] Step 3: Actor behaviors dispatched in priority order; mutations deferred
- [ ] Step 4: Deferred mutations applied in priority order
- [ ] Step 5: Scheduled events whose trigger time has arrived are fired
- [ ] Step 6: Inbox clearing; `time-inc! tick:` if time not yet advanced this turn
- [ ] Autonomous turn (no player input): steps 2–6 only
- [ ] NPC speed modelling: run N autonomous turns per player turn

### Tests — Phase 4

- [ ] `tests/runtime/actors_spec.lua` — perception snapshot construction
- [ ] `tests/runtime/actors_spec.lua` — perceived vs. unperceived path enforcement
- [ ] `tests/runtime/actors_spec.lua` — deferred mutations applied after all behaviors
- [ ] `tests/runtime/actors_spec.lua` — conflict detection and priority resolution
- [ ] `tests/runtime/actors_spec.lua` — conflict logging
- [ ] `tests/runtime/actors_spec.lua` — inbox overflow runtime error
- [ ] `tests/runtime/actors_spec.lua` — inbox cleared each turn; unhandled msgs dropped
- [ ] `tests/runtime/scheduler_spec.lua` — every: fires at correct intervals
- [ ] `tests/runtime/scheduler_spec.lua` — at: fires once only
- [ ] `tests/runtime/scheduler_spec.lua` — offset: applied correctly
- [ ] `tests/runtime/scheduler_spec.lua` — cancel-schedule! prevents future fires
- [ ] `tests/runtime/scheduler_spec.lua` — pending queue appears in log
- [ ] `tests/runtime/engine_spec.lua` — full six-step lifecycle
- [ ] `tests/runtime/engine_spec.lua` — autonomous turn (steps 2–6 only)
- [ ] `tests/runtime/engine_spec.lua` — time advances once per turn
- [ ] Integration scenario 4: deliver ore to blacksmith
- [ ] Integration scenario 5: random encounter with fixed seed (reproducible)
- [ ] Integration scenario 6: morning reset schedule fires
- [ ] Integration scenario 7: blacksmith alert → guard becomes hostile

**M Milestone:** `tests/test06_actors.sb` runs correctly; §25 complete example runs end-to-end.

---

## Phase 5 — Query and Future-State Search

**M Goal:** `storybase verify` passes all five verify blocks from §25.

### Query (`runtime/query.lua`)

- [ ] `find family` base form
- [ ] `where <condition>` clause (multiple clauses are ANDed)
- [ ] `or-where <condition>` clause (disjunction with preceding where)
- [ ] `within N hops of <relation> from <src>` reachability filter
- [ ] `connected-to <path> via <relation>` any-hop adjacency filter
- [ ] `order-by <path> asc|desc` sort
- [ ] `limit N` cap result list
- [ ] `count` return integer instead of list
- [ ] `find` is a pure expression; result type is `List(SymbolOf(family), limit)` or `Int`
- [ ] Relation query: `adjacent?` — Set of nodes 1 hop from source
- [ ] Relation query: `reachable?` — Bool reachability check
- [ ] Relation query: `reachable?` with `max-hops:` bound
- [ ] Relation query: `shortest-path` — List of nodes
- [ ] Relation query: `reachable-set` with `max-hops:` bound
- [ ] Relation query: `inverse-adjacent?` — Set of nodes that lead into source

### Search Engine (`runtime/search.lua`)

- [ ] State graph node: full cache snapshot identified by content hash
- [ ] Cycle detection via content hash (do not re-expand visited nodes)
- [ ] Successor function: enumerate all transaction functions reachable from current scene
- [ ] Successor function: scheduled events pending at the current time
- [ ] Successor function: actor behavior steps (as a single aggregate transition)
- [ ] Random source branching: one successor per outcome, each with probability weight
- [ ] `bounded` computation branching: branch over declared `distribution`
- [ ] Probability weight tracking and propagation along paths
- [ ] Probability pruning: skip branches below configurable threshold (default 0.01)
- [ ] Approximate-result annotation when pruning has occurred
- [ ] BFS search strategy
- [ ] DFS search strategy
- [ ] Best-first search strategy (configurable heuristic)
- [ ] `depth: N` parameter honoured by all search operations
- [ ] `strategy:` parameter honoured by all search operations
- [ ] Coroutine-based iterator at top-level suspension boundary
- [ ] Wall-clock time budget per search call (configurable)
- [ ] `can-reach? <condition>` — Bool
- [ ] `can-reach?` with `depth:` and `strategy:`
- [ ] `find-path <condition>` — action sequence or nil
- [ ] `verify-always <condition>` — Bool (holds in all futures to depth)
- [ ] `find-counterexample <condition>` — failing state + path, or nil
- [ ] `probability <condition> depth: N` — Float
- [ ] `optimal-path <condition> by: min-turns` — optimal action sequence

### Verify Blocks

- [ ] Compile `verify` declarations into test cases at load time
- [ ] `from-any-state:` clause — check holds from every reachable state
- [ ] `when <cond>:` clause — restrict to states satisfying the condition
- [ ] `requires <cond>` clause — skip verify if precondition not met
- [ ] `after <transition>:` clause — apply transition then check assertions
- [ ] `path@before` in `after:` blocks
- [ ] Failure report: specific failing state, counterexample path, log excerpt

### CLI — Phase 5

- [ ] `storybase verify <file>` command
- [ ] Report pass / fail per named verify block
- [ ] Print counterexample detail (state dump + action sequence) on failure
- [ ] Exit code 0 if all pass, non-zero if any fail

### Tests — Phase 5

- [ ] `tests/runtime/search_spec.lua` — `can-reach?` finds reachable state
- [ ] `tests/runtime/search_spec.lua` — `can-reach?` returns false for unreachable (no hang)
- [ ] `tests/runtime/search_spec.lua` — `find-path` returns sequence that reaches goal
- [ ] `tests/runtime/search_spec.lua` — `verify-always` passes when property holds
- [ ] `tests/runtime/search_spec.lua` — `verify-always` returns counterexample when violated
- [ ] `tests/runtime/search_spec.lua` — `probability` result in [0,1]; extreme cases 0 and 1
- [ ] `tests/runtime/search_spec.lua` — random source branching (weights sum to 1)
- [ ] `tests/runtime/search_spec.lua` — `bounded` branching over distribution
- [ ] `tests/runtime/search_spec.lua` — cycle detection (loop does not cause infinite search)
- [ ] `tests/runtime/search_spec.lua` — probability pruning (branches skipped; result annotated)
- [ ] `tests/fuzz/search_fuzz_spec.lua` — state-space computed size ≥ actual reachable count
- [ ] Integration scenario 9: all five §25 verify blocks pass
- [ ] `tests/test05_log_and_time.sb` — all three verify blocks pass
- [ ] `tests/test06_actors.sb` — all three verify blocks pass

**M Milestone:** `storybase verify tests/test05_log_and_time.sb` and `storybase verify tests/test06_actors.sb` all pass.

---

## Phase 6 — Advanced Features

**M Goal:** Counterfactuals, bounded computations, undo, and schema migration all work.

### Counterfactual (`runtime/counterfactual.lua`)

- [ ] `counterfactual from: T do: transitions` — create branched GameState
- [ ] Replay log to tick T then apply transition sequence to a private cache copy
- [ ] `GameState` value is immutable (no side effects on live state)
- [ ] `(in-state gs) path` — redirect a path read to the GameState copy
- [ ] `(in-state gs)` redirect works in all pure query operations (`find`, `can-reach?`, etc.)
- [ ] `find ... in-state: gs` clause
- [ ] `simulate: true` — include actor steps and scheduled events in the branch
- [ ] Nesting depth limit: enforce `max-counterfactual-depth` from engine-config
- [ ] GameState garbage-collected when it leaves scope
- [ ] Log: append `counterfactual(from: T, transitions: [...])` entry (visible in debug)

### Bounded Computations

- [ ] `bounded` declaration parsing: `returns:`, `distribution:`, `reads:`, `lua:`
- [ ] Lua handler registration: `game:register_bounded(name, fn)`
- [ ] Call convention: `fn(arg, state_snapshot)` where snapshot is read-only table of `reads:` paths
- [ ] Log result as a random-draw entry `{source, result, seed}`
- [ ] `uses-bounded` tag auto-applied to any function calling a `bounded` computation
- [ ] Search: branch over `uniform` distribution
- [ ] Search: branch over `conditioned-on path` distribution using current path value as prior

### Undo

- [ ] `undo!` — revert state to the most recent checkpoint
- [ ] `undo! steps: N` — revert N checkpoints back
- [ ] Append `undo` event to log (audit trail preserved; no log entries deleted)
- [ ] Correctly identify checkpoint boundaries (functions tagged `checkpoint` or auto-checkpoint)
- [ ] Runtime error if no checkpoint exists in history

### Schema Migration (`runtime/migrate.lua`)

- [ ] `schema-version: N` declaration stored and compared on load
- [ ] `migration A -> B:` block parsing
- [ ] `rename old-path -> new-path` — path renamed, value transferred
- [ ] `add path = value` — new path initialised with value
- [ ] `drop path` — path removed silently
- [ ] `transform path: fn old: expr` — function applied to each matching value
- [ ] `transform npcs/*/field:` — wildcard applied per family member
- [ ] `rename-enum path old -> new` — enum literal renamed in a specific path
- [ ] Apply migration chain in ascending version order on load
- [ ] Error: save is at version N but migration N → N+1 is missing

### CLI — Phase 6

- [ ] `storybase migrate <save.log>` — apply outstanding migrations, write upgraded copy

### Tests — Phase 6

- [ ] `tests/runtime/counterfactual_spec.lua` — branched state differs from live state
- [ ] `tests/runtime/counterfactual_spec.lua` — `(in-state)` path redirect
- [ ] `tests/runtime/counterfactual_spec.lua` — mutations in branch do not affect live state
- [ ] `tests/runtime/counterfactual_spec.lua` — `simulate: true` includes actor steps
- [ ] `tests/runtime/counterfactual_spec.lua` — nesting depth limit enforced
- [ ] `tests/fuzz/counterfactual_fuzz_spec.lua` — isolation holds under random transitions
- [ ] `tests/runtime/migrate_spec.lua` — rename
- [ ] `tests/runtime/migrate_spec.lua` — add and drop
- [ ] `tests/runtime/migrate_spec.lua` — transform (scalar and family wildcard)
- [ ] `tests/runtime/migrate_spec.lua` — rename-enum
- [ ] `tests/runtime/migrate_spec.lua` — version chain applied in order
- [ ] `tests/runtime/migrate_spec.lua` — missing intermediate version → error
- [ ] Integration scenario 8: player dies, `undo!` restores pre-death state
- [ ] Integration scenario 10: save → migrate → reload → state identical

---

## Phase 7 — Debug Tooling

**M Goal:** Full dev-mode experience: hot reload, time-travel, watches, WebSocket protocol.

### Debug Server (`runtime/debug.lua`)

- [ ] TCP/WebSocket server listening on configured port (default 7373) in dev mode
- [ ] Server disabled entirely in production builds
- [ ] Newline-delimited JSON protocol
- [ ] Emitted event: `mutation {path, old, new, fn, tick}`
- [ ] Emitted event: `scene-change {from, to, stack, tick}`
- [ ] Emitted event: `message-sent {actor, msg, tick}`
- [ ] Emitted event: `schedule-fired {name, tick}`
- [ ] Emitted event: `fn-call {name, args, tick}` (dev mode only)
- [ ] Emitted event: `spawn-event {family, key, init, tick}`
- [ ] Emitted event: `despawn-event {family, key, tick}`
- [ ] Emitted event: `clamp-event {path, attempted, clamped, tick}`
- [ ] Emitted event: `reload {file, outcome, changes, tick}`
- [ ] Accepted command: `get-state {pattern}` → `{path: value, ...}`
- [ ] Accepted command: `eval {expr}` → value (pure expressions only)
- [ ] Accepted command: `reload {file}` → outcome
- [ ] Accepted command: `set-breakpoint {condition}` → id
- [ ] Accepted command: `clear-breakpoint {id}`
- [ ] Accepted command: `time-travel {tick}` → frozen GameState (live state unaffected)
- [ ] Accepted command: `get-log {from, to}` → log entries

### Hot Reload

- [ ] Function body changed: apply immediately; state preserved
- [ ] New field added to record type: initialise all existing instances with declared default; log `field-added`
- [ ] Field removed from type: drop value silently; log `field-removed`
- [ ] Enum value added: legal immediately
- [ ] Enum value removed: error if any current state holds that value
- [ ] Type range narrowed: error if current state is out of new range
- [ ] New state path added: initialise to declared default
- [ ] Scene text changed: re-render current scene (presentation layer)
- [ ] Scene choices changed: re-enter current scene (exit then enter)
- [ ] Schema version bumped: run migration chain
- [ ] All changes applied transactionally: validate entire new schema before committing any change

### Watches and Doc Strings

- [ ] `watch path "label"` declaration: poll path on every `mutation` event
- [ ] `watch-when cond "label"` declaration: fire when condition becomes true
- [ ] Watch declarations tagged `debug-only` and stripped from production builds
- [ ] Doc string surfacing: `get-state` (or schema-browser command) returns attached doc strings

### Production Build Mode

- [ ] `debug-only` declarations stripped from compiled output
- [ ] `pre:` / `post:` contract blocks stripped (unless `strict-contracts: true` in engine-config)
- [ ] `watch` / `watch-when` declarations stripped
- [ ] Debug server not started

### Tests — Phase 7

- [ ] `tests/runtime/debug_spec.lua` — `get-state` pattern matching returns correct paths
- [ ] `tests/runtime/debug_spec.lua` — `eval` pure expression returns correct value
- [ ] `tests/runtime/debug_spec.lua` — `time-travel` returns frozen state; live state unchanged
- [ ] `tests/runtime/debug_spec.lua` — reload function body: state preserved, new logic active
- [ ] `tests/runtime/debug_spec.lua` — reload enum value added: legal immediately
- [ ] `tests/runtime/debug_spec.lua` — reload enum value removed: error if held by current state
- [ ] `tests/runtime/debug_spec.lua` — reload range narrowed: error if out of new range
- [ ] `tests/runtime/debug_spec.lua` — `watch` fires on matching mutation
- [ ] `tests/runtime/debug_spec.lua` — `watch-when` fires when condition becomes true
- [ ] `tests/runtime/debug_spec.lua` — all emitted events present in protocol
- [ ] `tests/runtime/debug_spec.lua` — all accepted commands handled correctly

---

## Phase 8 — Macro System, Lua Interop, and Polish

**M Goal:** Full public API; macro system; performance acceptable for 20 NPCs at depth-50 search.

### Macro System

- [ ] `macro name params: body` declaration parsing
- [ ] Macro expansion pre-pass (before type-check)
- [ ] Hygienic expansion (generated names do not collide with user names)
- [ ] Error: macro in body expands another macro defined in the same compilation unit
- [ ] Error: recursive macro invocation (direct or mutual)
- [ ] Expanded form is what the type checker and log see

### Lua Interop (`lib/storybase.lua`)

- [ ] `sb.load(file)` → game object
- [ ] `game:call(fn_name, arg1, ...)` — invoke transaction function
- [ ] `game:get(path)` → current value
- [ ] `game:find(family, clause_table)` → list of matching keys
- [ ] `game:on(event_name, handler_fn)` — subscribe to debug/presentation events
- [ ] `game:choose(index)` — dispatch player choice by visible index
- [ ] `game:eval(expr_string)` → value (pure expressions only)
- [ ] `game:counterfactual(opts, fn)` → GameState
- [ ] `game:register_bounded(name, lua_fn)` — register bounded computation handler

### CLI Polish

- [ ] `storybase extract-symbols <file>` — scan symbol literals, output candidate `type` declaration
- [ ] `storybase compile --production` — emit production build (strips debug-only content)
- [ ] `storybase run --seed N` — fix random seed for reproducible runs
- [ ] `storybase compact <save.log>` — emit snapshot + delta log to reduce replay time
- [ ] `storybase help` / `--help` on all subcommands

### Performance

- [ ] State cache snapshot at every checkpoint (O(delta since snapshot) replay)
- [ ] Search engine inner loop uses explicit stack (not coroutines) for BFS/DFS
- [ ] Search engine coroutine used only at top-level suspension boundary
- [ ] Wall-clock time budget enforced per search call
- [ ] Benchmark: §25 complete example, 20 NPCs, `can-reach?` at depth 50 completes in < 10 s

### Tile Grid Extension (optional)

- [ ] `defgrid name: dimensions: W x H  cell-type: T` declaration
- [ ] Grid as discrete state (one `T` per cell)
- [ ] `visible-from? grid pos1 pos2` — raycasting Bool
- [ ] `within-range? grid pos1 pos2 range: N` — Bool
- [ ] `path-to grid pos1 pos2` — A* List of positions
- [ ] `occupied-by grid pos` — entity key or nil

### Tests — Phase 8

- [ ] `tests/compiler/macro_spec.lua` — basic expansion
- [ ] `tests/compiler/macro_spec.lua` — hygiene (no name collision)
- [ ] `tests/compiler/macro_spec.lua` — same-unit expansion restriction enforced
- [ ] `tests/compiler/macro_spec.lua` — recursive macro error
- [ ] `tests/lib/interop_spec.lua` — all public API methods: call, get, find, on, choose, eval
- [ ] `tests/lib/interop_spec.lua` — counterfactual API from Lua
- [ ] `tests/lib/interop_spec.lua` — register_bounded and call convention
- [ ] `tests/fuzz/parser_fuzz_spec.lua` — random token sequences never crash the parser
- [ ] `tests/fuzz/log_fuzz_spec.lua` — log replay is deterministic under random mutations
- [ ] Performance benchmark passes (20 NPCs, depth-50 search < 10 s)

**M Milestone:** All eight `tests/test0*.sb` files compile, run, and (where applicable) pass `storybase verify` without errors.

---

## Ongoing

- [ ] Every public function in every module has at least one passing and one failing test
- [ ] No module writes to Lua global state
- [ ] All files begin `local M = {}` and end `return M`
- [ ] Line length ≤ 120 characters throughout
- [ ] All error codes use `UPPER_SNAKE` constants defined in `compiler/ast.lua` or `runtime/engine.lua`
- [ ] `busted tests/` passes with zero failures before each phase milestone is signed off

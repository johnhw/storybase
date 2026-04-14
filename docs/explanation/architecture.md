# Architecture

This document explains how StoryBase is structured and why. For file-by-file detail, see [`code_map.md`](../../code_map.md). For the design rationale behind the major constraints, see [`design_philosophy.md`](design_philosophy.md).

---

## The Compilation Pipeline

```
source.sb
  → compiler/lexer.lua       tokenize → tokens[]
  → compiler/parser.lua      parse    → AST
  → compiler/checker.lua     check    → typed AST + symtab
  → compiler/codegen.lua     emit     → game_table
```

Each stage is a pure transformation — no global state, no side effects. The output of each stage is the only input to the next.

### Lexer (`compiler/lexer.lua`)

The lexer produces a flat token stream. Key responsibilities:
- **INDENT/DEDENT synthesis:** Python-style indentation becomes explicit tokens before the parser sees them. This is done in a pre-pass over the raw token stream.
- **Path tokens:** any token containing `/` is emitted as a `PATH` token rather than an identifier. This means `player/health` is a single token, not three.
- **Named arguments:** `foo:` at the start of an argument position is a `NAMED_ARG` token.

### Parser (`compiler/parser.lua`)

Recursive descent. The parser's output is an AST of typed node objects. Key decisions:
- All block structure comes from INDENT/DEDENT, not from braces or `end` keywords.
- Scene syntax (narration, `*` choices, `->` navigation) is parsed by a separate `parse_scene_body` function.
- Error recovery: the parser continues after a bad declaration, accumulating errors rather than stopping at the first one.

### Checker (`compiler/checker.lua`)

Four passes over the AST:

1. **pass1_collect** — build the symbol table (`symtab`) from all declarations. After this pass, all type names, function names, state paths, and scene names are known.
2. **pass2_check** — type and reference validation. Verifies that all referenced names are declared, types are used correctly, and the discrete/superficial boundary is respected.
3. **pass3_infer_purity** — classify every function as pure or transaction. A function is pure if it calls no mutation primitive directly or transitively. The compiler uses this to enforce that pure contexts (guards, `find` clauses, `verify` conditions) don't call transaction functions.
4. **pass4_check_perceives** — warn when an actor's behavior function reads a path not listed in its `perceives:` declaration.

### Codegen (`compiler/codegen.lua`)

Transforms the typed AST into the **game table** — a plain Lua table that contains everything the runtime needs. The game table is self-contained; it has no references back to the AST or compiler.

The game table has sections for: schema (types, states, relations), functions (as raw AST subtrees), scenes, actors, schedules, verify blocks, watches, bounded computations, tile grids, and migrations.

**Production mode** (`opts.production = true`): verify blocks, watch declarations, and `pre:`/`post:` bodies are stripped from the game table. Functions are emitted without their contract annotations.

---

## The Game Table

The game table is the contract between compiler and runtime:

```
game_table.schema     — types, states, relations, engine config, time model
game_table.fns        — function bodies as AST trees
game_table.scenes     — scene bodies as AST trees
game_table.actors     — actor declarations
game_table.schedules  — schedule declarations
game_table.verifies   — verify block bodies (empty in production)
game_table.watches    — watch expressions (empty in production)
game_table.grids      — defgrid declarations
game_table.migrations — migration blocks
```

Nothing in the runtime imports the compiler. All information flows through the game table.

---

## The Runtime

The runtime is split into independent modules with defined responsibilities:

```
runtime/engine.lua      Game loop coordinator
runtime/state.lua       Flat path-keyed state store
runtime/log.lua         Transaction log (ground truth)
runtime/eval.lua        Expression and statement evaluator
runtime/actors.lua      Actor registry and behavior runner
runtime/scheduler.lua   Time-triggered event scheduler
runtime/search.lua      BFS / Dijkstra over future states
runtime/verify.lua      Verify block runner (offline model checker)
runtime/query.lua       Relation and family queries
runtime/random.lua      Seeded, logged RNG
runtime/debug.lua       TCP debug server
runtime/counterfactual.lua  State branching for what-if queries
runtime/migrate.lua     Schema migration runner
runtime/tilegrid.lua    2D tile grid algorithms
```

### State Store and Log (`state.lua`, `log.lua`)

State is a flat key-value cache: `{["player/health"] = 85, ...}`. The cache is always a projection of the log.

Every mutation goes through `store:set(path, value, fn_name)` (or similar) which:
1. Appends a log entry `{seq, time, fn, path, old, new, op}`.
2. Updates the cache.

The log is the ground truth. `store:replay(entries)` reconstructs the cache from scratch by replaying log entries, used on `--load`.

### Evaluator (`eval.lua`)

`eval.lua` is the heart of the runtime. It recursively evaluates AST nodes:
- `eval_expr(node, ctx)` — evaluate an expression, returning a value.
- `eval_stmt(node, ctx)` — execute a statement (mutation or control flow).

The evaluation context `ctx` carries: the state store, the function table, local variable bindings, and optional debug server reference.

Built-in functions (BUILTINS table) are resolved in `call_fn` before user-defined functions. Search builtins (`can-reach?`, `find-path`, etc.) call into `search.lua`. Grid builtins call into `tilegrid.lua`.

### Engine (`engine.lua`)

The engine coordinates the turn lifecycle:

1. **render** — call `eval_stmts` on the current scene's body, collecting narration lines and visible choices.
2. **do_choice** — evaluate the body of the selected choice, collecting mutations and a navigation signal.
3. **post_action** — deliver messages, run actor behaviors, apply deferred mutations, fire scheduled events.

The engine uses `io_out` and `io_in` for terminal I/O, which can be replaced by the Lua API (`lib/storybase.lua`) for embedding.

### Actors (`actors.lua`)

The actor registry runs behaviors in two phases to achieve order-independence:
1. Each actor reads from a *perception snapshot* (a frozen filtered copy of state).
2. All mutations are deferred into a queue.
3. After all behaviors run, deferred mutations are applied in priority order.

When two actors try to write the same path, the higher-priority actor wins; the conflict is logged.

### Scheduler (`scheduler.lua`)

Schedules are time-triggered: each `every: [axis: +N]` schedule fires when the game time advances past its next trigger time. The scheduler maintains a list of pending schedules with their next-fire times. `sched:tick(fns)` advances time and fires any triggered schedules.

Dynamic schedules created with `schedule!` are tracked in the log (they are logged state, not just runtime state), so they survive save/load.

### Search (`search.lua`)

Search performs BFS over `(cache_snapshot, scene_stack)` pairs:

1. Start from the current `(cache, stack)`.
2. Clone the cache, simulate rendering the current scene, enumerate all visible choices.
3. For each choice, clone the engine, call `do_choice`, then `post_action` (to include actor/scheduler transitions).
4. Collect the resulting `(cache, stack)` pairs as child nodes.
5. Deduplicate via a content hash of `(cache, stack)`.
6. Repeat until the condition is met or depth is exhausted.

Random sources are handled by `_random_inject`: during search, `random-int` calls are intercepted to enumerate all outcomes rather than pick one.

### Debug Server (`debug.lua`)

The debug server is an optional TCP server using LuaSocket. It speaks NDJSON line-by-line. Clients connect and receive a stream of events (mutations, scene changes, watch fires, etc.) and can send commands (get-state, time-travel, reload).

The server is wired into the engine via hooks:
- `store._clamp_hook` — fires `clamp-event` on Int saturation.
- `store._spawn_hook` / `store._despawn_hook` — fire spawn/despawn events.
- `ctx.debug` — passed through the evaluation context so eval.lua can emit `fn-call` events.

---

## Data Flow Summary

```
Source file
  ↓ [compile]
Game table (static, immutable)
  ↓ [engine.new]
Engine (stateful)
  ├── State store + log  (current game state)
  ├── Evaluator          (reads state, applies mutations)
  ├── Actor registry     (behavior functions, deferred writes)
  ├── Scheduler          (time triggers)
  ├── Search engine      (BFS over cloned states)
  └── Debug server       (TCP events, reload)
```

The game table flows one way: compiled once, consumed by the runtime. The runtime's stateful components (store, log, actor inbox) are the only mutable state. All mutable state is managed through the store, which ensures everything ends up in the log.

---

## Module System and Import Resolution

The compiler's `resolve_imports` step (in `compiler/compiler.lua`) runs between parsing and type-checking. It:

1. Reads all `import "file.sb"` declarations.
2. Lexes, parses, and recursively resolves imports in each imported file.
3. Splices the imported declarations into the current file's AST before the checker runs.
4. Detects cycles and emits `IMPORT_CYCLE`.

State paths from imported modules are global: they contribute to the shared path namespace as-is. Type names and function names are namespaced if imported `as E`.

---

## Key Design Decisions

**Why a flat game table instead of passing the AST to the runtime?**
The game table is a stable, version-agnostic contract. The compiler can change its internal representation without affecting the runtime, and vice versa. It also makes the game table serialisable in principle, useful for caching compiled games.

**Why emit function bodies as raw AST trees?**
The eval loop is an AST interpreter, not a bytecode VM. This makes the evaluator simple and debuggable — you can log exactly which AST node is being evaluated. It also means the debugger can surface source-level information without a separate source-map.

**Why separate actor deferred writes from immediate eval?**
If actor A writes a path during its behavior and actor B reads that path in the same behavior step, the result would depend on whether A ran before or after B. Deferred writes eliminate this ordering dependency and make actor behavior reproducible regardless of registration order.

**Why store the scene stack in the state log?**
Scene navigation is state. If you save/load without the scene stack, you reload in the wrong scene. Including the scene stack in the log (it is recorded as part of each do_choice) means save/load is complete without any special-casing.

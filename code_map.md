# StoryBase Code Map

Quick-reference index. All paths relative to repo root. Line numbers are approximate anchors.

---

## Pipeline Overview

```
source.sb
  → compiler/lexer.lua       tokenize(source, file) → tokens[]
  → compiler/parser.lua      parse(tokens, file) → AST
  → compiler/checker.lua     check(ast, file) → typed AST + diags
  → compiler/codegen.lua     emit(typed_ast) → game_table + diags
  → runtime/engine.lua       new(game_table, opts) → engine
```

Entry points: `compiler/compiler.lua` — `M.compile(source, file)` / `M.compile_file(path)` (full pipeline); `M.parse_and_check(source, file)` / `M.parse_and_check_file(path)` (stops before codegen, returns typed AST)

---

## compiler/

### `compiler/ast.lua` (877 lines)
AST node constructors and constants. Import as `local ast = require("compiler.ast")`.

**Constants:**
- `ast.K.*` — all node kind strings (see below)
- `ast.E.*` — error codes (e.g. `UNDEFINED_TYPE`, `DUPLICATE_DECL`)
- `ast.W.*` — warning codes (e.g. `PERCEIVES_VIOLATION`, `IMPURE_IN_PURE`)

**Helpers:**
- `ast.pos(file, line, col)` → pos table
- `ast.error(code, msg, pos, note?)` → diag table
- `ast.warning(code, msg, pos, note?)` → diag table
- `ast.is_mut(node)` → bool — true if node is a mutation statement kind

**Declaration kinds (`ast.K.*`):**
```
PROGRAM, MODULE_DECL, IMPORT_DECL, SCHEMA_VERSION, ENGINE_CONFIG, TIME_MODEL
TYPE_ENUM, TYPE_ALIAS, TYPE_RECORD, TYPE_VARIANT
STATE_SCALAR, STATE_RECORD, STATE_FAMILY
RELATION_DECL, FN_DECL, ACTOR_DECL, SCHEDULE_DECL
BOUNDED_DECL, VERIFY_DECL, WATCH_DECL, WATCH_WHEN_DECL
SCENE_DECL, MACRO_DECL, MIGRATION_DECL, DEFGRID_DECL
```

**Type expression kinds:**
```
TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING
TYPE_ENUM_INLINE, TYPE_OPTION, TYPE_SET, TYPE_LIST, TYPE_ULIST, TYPE_UMAP
TYPE_SYMBOL, TYPE_SYMBOL_OF, TYPE_NAMED, TYPE_FN
```

**Literal/expression kinds:**
```
INT_LIT, FLOAT_LIT, BOOL_LIT, STRING_LIT, MULTILINE_STRING, SYMBOL_LIT
PATH_EXPR, INTERP_PATH, PATH_AT_BEFORE, INDEX_EXPR, SLICE_EXPR
BINARY_OP, UNARY_OP, NIL_COALESCE, FN_CALL, NAMED_ARG
IF_EXPR, WHEN_STMT, MATCH_EXPR, COND_EXPR
FOR_STMT, WHILE_STMT, LET_STMT, LAMBDA_EXPR
PASS_STMT, EXPR_STMT
SET_LIT, LIST_LIT, MAP_LIT, EMPTY_SET, EMPTY_LIST, EMPTY_MAP
FIND_EXPR, RECORD_CONSTRUCTOR, COUNTERFACTUAL_EXPR
```

**Mutation statement kinds:**
```
SET_MUT, INC_MUT, DEC_MUT, ADD_MUT, REMOVE_MUT, CLEAR_MUT
PUSH_MUT, POP_MUT, SPAWN_MUT, DESPAWN_MUT
GOTO_STMT, ENTER_STMT, EXIT_STMT, SEND_MUT
MATCH_ARM, COND_ARM
CHECKPOINT_MUT   -- engine/checkpoint! [fn-name]
EMIT_MUT         -- engine/emit event [args]
```

---

### `compiler/lexer.lua` (490 lines)
- `M.tokenize(source, filename)` → `{tokens=[], errors=[]}`
- Handles INDENT/DEDENT pre-pass, all token types, NAMED_ARG (`foo:`), COMPUTED_GOTO, PATH tokens (`a/b/c`)
- Token shape: `{type=STRING, value=ANY, line=N, col=N}`

---

### `compiler/parser.lua` (2564 lines)
- `M.parse(tokens, filename)` → `(ast_root, diags[])`
- Recursive descent; parser state `p` carries cursor + error accumulator
- Key parse functions (all local): `parse_decl`, `parse_expr`, `parse_primary`, `parse_stmt`, `parse_type_expr`, `parse_scene_body`
- `parse_primary` IDENT branch: checks for `[` before arg-collection loop to produce `INDEX_EXPR` instead of `FN_CALL`

---

### `compiler/checker.lua` (540 lines)
- `M.check(ast_root, filename)` → `(typed_ast, diags[])`
- Attaches `ast_root.symtab = {types={}, states={}, relations={}}` for codegen
- Four passes (all local):
  - `pass1_collect` (line 98) — build symtab from declarations
  - `pass2_check` (line 316) — type/reference validation
  - `pass3_infer_purity` (line 375) — mark `fn.pure=true` if no mutations
  - `pass4_check_perceives` (line 478) — warn `PERCEIVES_VIOLATION` for reads outside actor's `perceives:` list
- `collect_path_reads(node, into)` (line 431) — recursively collect PATH_EXPR reads from an AST subtree

---

### `compiler/codegen.lua` (~650 lines)
- `M.emit(typed_ast, opts?)` → `(game_table, diags[])`
- `opts.production = true` → strips verifies and watches from game_table; sets `game_table.production = true`
- Produces the **game_table** structure (see below)
- Local emitters: `emit_types`, `emit_states`, `emit_relations`, `emit_engine_config`, `emit_time_model`, `emit_fns`, `emit_scenes`, `emit_actors`, `emit_schedules`, `emit_verifies`, `emit_watches`, `emit_bounded`, `emit_migrations`

---

### `compiler/types.lua` (60 lines)
- `M.DISCRETE` / `M.SUPERFICIAL` — type category constants
- `M.is_discrete(ty)` / `M.is_superficial(ty)` — classify a type descriptor
- `M.state_space_size(ty)` → number — cardinality of a type

---

### `compiler/compiler.lua` (~245 lines)
- `M.compile(source, filename, opts?)` → `(game_table, diags)`
- `M.compile_file(filepath, opts?)` → `(game_table, diags)`
- `M.parse_and_check(source, filename)` → `(typed_ast, diags)` — stops before codegen; returns AST with `.decls`
- `M.parse_and_check_file(filepath)` → `(typed_ast, diags)`
- `opts.production = true` → passed to codegen to strip debug-only content
- Runs lexer → parser → resolve_imports → checker → codegen in sequence
- `resolve_imports` splices imported declarations (from `import "file.sb"`) before type-check; cycle detection via IMPORT_CYCLE error

---

## Game Table Structure

Produced by `codegen.emit`; consumed by all runtime modules.

```lua
game_table = {
  schema = {
    version          = string,
    type_count       = number,
    path_count       = number,
    scene_count      = number,
    relation_count   = number,
    state_space_size = number|"unbounded",
    types            = { [name] = type_desc },
    states           = { [path] = {type_desc, default_desc} },
    relations        = { [name] = {edges=...} },
    engine_config    = { ["entry-scene"]=str, ["scene-stack-max"]=n, ... },
    time_model       = { axes={...}, default_axis=str },
  },
  fns        = { [name] = {params, body, pre, post, tags, pure} },
  scenes     = { [name] = {name, choices=[{text, guard, body}]} },
  actors     = { [name] = {name, priority, perceives, state_path, behaviors} },
  schedules  = { [name] = {name, trigger, body} },
  verifies   = [ {label, clauses=[{kind, condition, body}]} ],  -- empty in production builds
  watches    = [ {label, path_or_cond, kind} ],                 -- empty in production builds
  migrations = [ {from_version, body} ],
  bounded    = { [name] = {reads, body} },
  production = bool,  -- true if compiled with opts.production
}
```

---

## runtime/

### `runtime/state.lua` (578 lines)
Path-keyed flat store backed by the transaction log.

- `M.new(schema, log)` → store
- `M.replay(store, entries)` — reconstruct cache from log entries

**store methods:**
```
store:get(path)              → value
store:path_exists(path)      → bool
store:path_list(family)      → [key, ...]
store:get_time()             → {tick, [axis]=n, ...}
store:inc_time(axis, amount)
store:set(path, val, fn)
store:inc(path, amount, fn)      -- clamps to Int range; fires _clamp_hook if clamped
store:dec(path, amount, fn)      -- clamps to Int range; fires _clamp_hook if clamped
store:add(path, val, fn)         -- set/list add
store:remove(path, val, fn)      -- set/list remove
store:clear(path, fn)
store:push(path, val, fn)        -- list push
store:pop(path, fn)              -- list pop
store:spawn(family, key, record, fn)
store:despawn(family, key, fn)
store:push_checkpoint(fn_name)   -- save undo point
store:undo(steps)                -- roll back N checkpoints
store:init_defaults()            -- apply schema defaults to cache
```

**Internal fields:**
- `store._cache` — flat `{[path]=value}` table (read directly by search/verify BFS)
- `store._log` — transaction log object
- `store._mutation_hook` — optional `function(path, old, new_val, fn_name)` called on every state write (used by `lib/storybase.lua` to fire `game:on("mutation", ...)` events)
- `store._clamp_hook` — optional `function(path, attempted, clamped, fn_name)` called on clamp
- `store._spawn_hook` — optional `function(family, key, init, fn_name)` called after spawn
- `store._despawn_hook` — optional `function(family, key, fn_name)` called after despawn

---

### `runtime/eval.lua` (~1420 lines)
Expression and statement evaluator. All evaluation goes through here.

- `M.new_ctx(state, fns, fn_name, game)` → ctx
- `M.eval_expr(node, ctx)` → value
- `M.eval_stmt(node, ctx)`
- `M.eval_stmts(stmts, ctx)`
- `M.eval_path(node, ctx)` → path string (resolves interpolations)
- `M.call_fn(name, args, ctx)` → value
- `M.render_text(text, ctx)` → string
- `M.child_ctx_vars(ctx, vars)` → new ctx with extra var bindings

**ctx fields:**
```lua
ctx = {
  state            = store,
  fns              = game_table.fns,
  vars             = {},          -- local variable bindings
  fn_name          = string,
  game             = game_table,
  signal           = nil,         -- scene navigation signal
  retval           = nil,
  before_snapshot  = nil,         -- set during verify after-check
  scene_stack      = {},          -- used by search builtins
  debug            = srv?,        -- debug server (nil in production/non-debug)
}
```

**Built-in functions (BUILTINS table, line ~524):**
```
path-list        → list of live family keys
min, max
count-where      → count items matching predicate
any?, all?
random-int
tostring
path-exists?     → bool (uses eval_path on PATH_EXPR args, not eval_expr)
can-reach?       → bool  (BFS, optional depth: N, budget: secs)
find-path        → [{scene, label, index}, ...]  (BFS path, optional depth: N, budget: secs)
verify-always    → bool  (BFS negation check)
probability      → float  (weighted BFS, optional depth:/threshold:)
optimal-path     → [{scene, label, index}, ...]  (Dijkstra, optional by:/depth:)
find-counterexample → frozen GameState | nil
-- UMap builtins (all paths must contain "/"):
map-get          path key → value | nil
map-size         path → Int
map-keys         path → List
map-values       path → List
map-contains-key? path key → Bool
map-set          path key value → new UMap  (pure)
map-delete       path key → new UMap  (pure)
map-merge        path-a path-b → new UMap  (pure)
-- UList builtins (all paths must contain "/"):
ulist-size       path → Int
ulist-get        path index → T | nil
ulist-first      path → T | nil
ulist-last       path → T | nil
ulist-index-of   path value → Int | nil
ulist-contains?  path value → Bool
ulist-append     path value → new UList  (pure)
ulist-prepend    path value → new UList  (pure)
ulist-remove-at  path index → new UList  (pure)
ulist-remove     path value → new UList  (pure)
ulist-concat     path-a path-b → new UList  (pure)
ulist-slice      path from to → new UList  (pure)
ulist-reverse    path → new UList  (pure)
ulist-map        path fn(v): expr → new UList  (pure)
ulist-filter     path fn(v): condition → new UList  (pure)
-- Tile grid builtins (require ctx.grids populated by engine):
grid-get         grid-name x y → cell value
grid-set!        grid-name x y value → nil (mutation)
grid-width       grid-name → integer
grid-height      grid-name → integer
within-range?    grid-name x1 y1 x2 y2 [range: N] [metric: str] → bool
visible-from?    grid-name x1 y1 x2 y2 [solid: {values}] → bool
path-to          grid-name x1 y1 x2 y2 [blocked: {values}] [diag: bool] → [{x,y}] | nil
occupied-by      grid-name family-name x y → key | nil
```

**Dispatch order in `call_fn`:** vars → BUILTINS → bounded defs → user fns → bare string fallback

**Mutation statements (eval_stmt):** SET_MUT, INC_MUT, DEC_MUT, ADD_MUT, REMOVE_MUT, CLEAR_MUT, PUSH_MUT, POP_MUT, SPAWN_MUT, DESPAWN_MUT

---

### `runtime/engine.lua` (509 lines)
Game loop coordinator.

- `M.new(game_table, opts)` → eng  (opts: `io_out`, `io_in`, `seed`, `debug_server`)
- `M.run(game_table, opts)` — blocking REPL loop

**eng methods:**
```
eng:init()                    -- init_defaults + register actors/schedules
eng:register_actors_schedules()
eng:current_scene()           → name
eng:goto_scene(name)
eng:push_scene(name)
eng:pop_scene()
eng:enter_scene(name)
eng:exit_scene()
eng:render_scene(name)        → (text, choices[])
eng:do_choice(scene_name, idx) → nav_signal
eng:post_action()             -- run actors + scheduler after player choice
eng:autonomous_turn()         -- actors + scheduler only (no player input)
eng:step()                    -- render + read input + do_choice
eng:set_debug_server(srv)     -- wire debug server + clamp_hook
eng:make_ctx(fn_name)         → eval ctx
eng:render_text(text, ctx)    → string
eng:out(s)                    -- write to io_out
eng:inp()                     → string  -- read from io_in
```

**Internal fields:** `eng._state`, `eng._log`, `eng._fns`, `eng._scenes`, `eng._scene_stack`, `eng._actors`, `eng._scheduler`, `eng._grids`
**Grid initialisation:** `eng:init_grids()` — creates flat cell arrays from `game_table.grids`; called by `eng:init()`.
**ctx.grids:** populated in `make_ctx()`; points to `eng._grids` (name → `{cells,width,height,cell_type,default_val}`)

---

### `runtime/search.lua` (~540 lines)
BFS / Dijkstra over `(cache_snapshot, scene_stack)` pairs.

- `M.can_reach(game_table, cache, stack, condition_fn, depth, budget?)` → `(bool|nil, timed_out_bool)` — returns `nil` (not `false`) on budget timeout so callers can distinguish "not reachable" from "unknown"
- `M.find_path(game_table, cache, stack, condition_fn, depth, budget?)` → `[{scene, label, index}, ...]` | nil
- `M.probability(game_table, cache, stack, condition_fn, depth, threshold)` → float 0..1
- `M.optimal_path(game_table, cache, stack, condition_fn, depth, cost_fn)` → path | nil  (Dijkstra)
- `M.new(state, game, opts)` → search object (alternative stateful API, less used)

**BFS node:** `{stack=[], cache={}, depth=N}`  
**Cycle detection:** content hash of `cache + stack` via local `hash_cache`  
**Note:** `probability` does NOT use cycle dedup (all paths must be counted separately)  
**Time budget:** `budget` in seconds (nil = no limit); clock checked every `BUDGET_CHECK_N=50` iterations

---

### `runtime/verify.lua` (464 lines)
Verify block runner (offline model-checker).

- `M.run_all(game_table)` → `[{label, pass, fail_msg?, skipped?, reason?, states_checked?, counterexample?, counterexample_n?}]`

**Clause kinds handled:**
- `"always"` → BFS check: `verify-always expr`
- `"after"` → single-state check: `after (fn args): assertions`
- `"requires"` → precondition for skipping `after` check
- `"from_any_state"` → check expression holds from every BFS-reachable state
- `"when"` → filter for `from_any_state` snapshots

**BFS depth:** `DEFAULT_BFS_DEPTH = 5`

---

### `runtime/actors.lua` (~330 lines)
Actor registry and behavior runner.

- `M.new(state, log)` → registry

**registry methods:**
```
registry:register(actor_def)      -- register actor from game_table.actors
registry:send(actor_name, msg)    -- push to actor inbox
registry:deliver_messages()       -- move inbox to actor state paths
registry:run_behaviors(fns)       -- run each actor's behavior fn with perception snapshot
registry:apply_deferred()         -- commit deferred writes; logs kind="conflict" on priority clash
registry:clear_inboxes()
```

**Perception filtering:** `make_capture_proxy(state, priority, name, perceives, state_path)` — creates read-only proxy where `get(path)` returns nil for paths not in `perceives` list (actor's own `state_path` subtree always readable).

**Conflict logging:** when a lower-priority actor's `set`/`clear` write is discarded because a higher-priority actor already wrote the same path, a `kind="conflict"` entry is appended to the transaction log.

---

### `runtime/log.lua` (246 lines)
Transaction log. Ground truth for all state changes.

- `M.new()` → log
- `M.serialise_entries(entries)` → string (line-delimited)
- `M.deserialise(str)` → entries[]

**log methods:**
```
log:append(entry)                    -- low-level append
log:seq()                            → current seq number
log:entries()                        → all entries
log:entries_after(seq_from)          → entries after seq
log:entries_up_to(seq_to)            → entries up to seq
log:query_at(path, time)             → value at time
log:query_history(path, from, to)    → [{seq, time, value}, ...]
log:query_changes(path, last_n)      → last N changes
log:checkpoint(fn_name)              -- append checkpoint marker
log:last_checkpoint_seq(steps)       → seq of Nth-from-last checkpoint
log:serialise()                      → string
```

**Entry shape:** `{seq=N, time={tick=N,...}, path=str, value=ANY, fn=str, op=str}`

---

### `runtime/debug.lua` (~1390 lines)
Debug server: watches, NDJSON TCP transport, HTTP/SSE browser UI, event emission.

- `M.new(engine, opts)` → srv  (opts: `port` default 7777)
- `M.encode_json(v)` → string
- `M.decode_json(s)` → value
- `M.HTML_UI` — embedded single-file HTML/JS/CSS debug UI (~10 KB)

**srv methods:**
```
srv:start()                          -- bind TCP socket, listen
srv:stop()
srv:poll()                           -- non-blocking: accept clients, read commands
srv:start_http(port)                 -- bind HTTP listener (browser UI); default port 7374
srv:stop_http()                      -- close HTTP listener and all client/SSE sockets
srv:poll_http()                      -- non-blocking: accept HTTP connections, advance state machine
srv:_http_response(sock, status, ctype, body, extra_hdrs?)  -- write HTTP/1.1 response + CORS
srv:_sse_push(event_name, payload)   -- send data:<json>\n\n to all SSE clients; prunes dead sockets
srv:on(event_name, fn)               -- register event handler
srv:emit(event_name, payload)        -- fire event → TCP broadcast + SSE push
srv:_broadcast(msg)                  -- send NDJSON line to all TCP clients
srv:register_watch(path, label)
srv:register_watch_when(cond_expr, label)
srv:check_watches()                  -- evaluate watch conditions, emit "watch-triggered"
srv:handle_command(cmd, payload)     -- dispatch incoming command
```

**HTTP routes:** `GET /` → HTML UI, `GET /events` → SSE stream, `POST /command` → JSON API, `OPTIONS *` → CORS preflight
**Built-in events:** `mutation`, `scene-change`, `clamp-event`, `spawn-event`, `despawn-event`, `message-sent`, `schedule-fired`, `fn-call`, `reload`, `watch-fired`
**Commands (TCP + HTTP):** `get-state`, `get-scene`, `do-choice`, `get-tick`, `get-mode`, `get-schema`, `eval`, `get-log`, `time-travel`, `set-breakpoint`, `clear-breakpoint`, `reload`
**HTTP server state:** `_http_socket`, `_http_clients`, `_sse_clients`, `_serve_mode`
**Hot reload schema migration:** `reload` command validates Int range, enum values, adds new fields, drops removed fields atomically

---

### `runtime/scheduler.lua` (~160 lines)
Time-triggered event scheduler.

- `M.new(state, log)` → sched

**sched methods:**
```
sched:register(name, trigger, body)  -- register schedule from game_table.schedules
sched:tick(fns)                      -- advance time, fire triggered schedules; logs kind="schedule_fired"
sched:schedule(name, opts, fn)       -- dynamic schedule (stub)
sched:cancel(name)                   -- cancel schedule; logs kind="cancel_schedule" if active
```

---

### `runtime/tilegrid.lua` (~260 lines)
Optional tile grid extension algorithms. Required by eval.lua grid builtins.

- `M.new(width, height, default_value)` → flat 1-indexed cell array (size = w×h)
- `M.idx(width, height, x, y)` → integer (1-based) | nil (OOB)
- `M.in_bounds(width, height, x, y)` → bool
- `M.get(cells, width, height, x, y)` → value | nil
- `M.set(cells, width, height, x, y, value)` → bool (false = OOB)
- `M.within_range(x1, y1, x2, y2, range, metric?)` → bool (metrics: chebyshev|manhattan|euclidean)
- `M.visible_from(cells, w, h, x1, y1, x2, y2, opaque_set?)` → bool (float-step ray, tests intermediate cells only)
- `M.find_path(cells, w, h, x1, y1, x2, y2, blocked_set?, allow_diag?)` → `[{x,y},...]` | nil (A* with binary min-heap)
- `M.occupied_by(state_cache, family, x, y)` → key string | nil (scans `family/KEY/x` + `family/KEY/y` paths)

**Coordinate system:** 0-based (x, y); (0,0) = top-left.
**Cell storage:** `cells[y*width + x + 1]` (1-based flat Lua array).

---

### `runtime/counterfactual.lua` (60 lines)
- `M.create(live_state, log, from_tick, transitions, simulate, depth, max_depth)` → counterfactual state
- Branches a copy of state at `from_tick`, replays `transitions`, optionally runs actor+scheduler (`simulate=true`)

---

### `runtime/query.lua` (~250 lines)
Relation and family queries. `where:` clauses support both expressions and lambda predicates (lambda is called with the entity key).

- `M.find(ctx, family, clauses)` → `[key, ...]`  (family member filter)
- `M.adjacent(relation, source)` → `[target, ...]`
- `M.reachable(relation, source, target, max_hops)` → bool
- `M.reachable_set(relation, source, max_hops)` → `{key=true, ...}`
- `M.shortest_path(relation, source, target)` → `[node, ...]` | nil
- `M.inverse_adjacent(relation, target)` → `[source, ...]`

---

### `runtime/random.lua` (89 lines)
Seeded RNG backed by log.

- `M.new(seed, log)` → rng

**rng methods:**
```
rng:bool(p)              → bool  (p = probability of true)
rng:int(min, max)        → int
rng:enum(values)         → value
rng:choice(list)         → value
rng:weighted(weights, list) → value
```

---

### `runtime/migrate.lua` (182 lines)
- `M.migrate(cache, migrations, save_version, game_version, game_table)` → migrated cache
- Runs migration blocks in version order from `save_version` up to `game_version`

---

## cli/

### `cli/main.lua` (~550 lines)
- `M.main(argv)` — top-level dispatcher
- Subcommands: `check`, `compile`, `run`, `format`, `repl`, `verify`, `migrate`, `extract-symbols`, `compact`, `help`
- Flags: `--save` / `--load` / `--seed N` / `--auto` / `--steps N` / `--debug` / `--serve` for `run`; `--production` for `compile`/`run`
- `BOOL_FLAGS` set prevents boolean flags from eating the following positional arg
- `--auto` / `--steps N`: non-interactive run mode; fake `io_in` always returns "1"; `--steps N` limits turns
- `--debug`: starts debug TCP server (port 7373) + HTTP UI server (port 7374); game runs via stdin; browser panels read-only
- `--serve`: starts HTTP UI server only (port 7374); no stdin loop; browser drives game via `do-choice`; `_serve_mode=true`
- `print_diags(diags, source_map?)` prints errors with source-context lines + caret indicator
- Per-subcommand help: `storybase help <subcommand>` shows detailed usage

### `cli/check_cmd.lua` (~115 lines)
- `M.run(args)` — run lexer → parser → checker (no codegen); print errors/warnings with source context
- Faster feedback than `compile`; exits 0 on success (warnings allowed), 1 on errors

### `cli/format_cmd.lua` (~850 lines)
- `M.run(args)` — parse AST and emit canonical indented output
- Flags: `--check` (compare only, exit 1 if differs), `--write` (rewrite in-place with .bak backup)
- Default: write formatted source to stdout

### `cli/repl_cmd.lua` (~175 lines)
- `M.run(args)` — load a .sb file and start an interactive expression REPL
- Meta-commands: `:state <path>`, `:scene`, `:choices`, `:choose N`, `:tick`, `:save`, `:load`, `:help`, `:quit`
- Evaluates pure expressions and calls transaction functions interactively

### `cli/verify_cmd.lua` (79 lines)
- `M.run(args)` — compile + `verify_mod.run_all` + pretty-print results

### `cli/migrate_cmd.lua` (145 lines)
- `M.run(args)` — load save file, run migrations, write output

### `cli/extract_cmd.lua` (~220 lines)
- `M.run(args)` — walk typed AST (via `parse_and_check_file`), collect SYMBOL_LIT nodes grouped by SET_MUT target path, output candidate `type Name = val | val` declarations

### `cli/bundle_cmd.lua` (~290 lines)
- `M.run(args)` — compile a .sb file and emit a single self-contained Lua file
- Embeds 14 runtime modules as `package.preload` entries (compiler excluded)
- `serialize(val)` — recursive Lua-value-to-source-literal serialiser (handles NaN/±Inf, cycles detection, sequence vs map tables)
- `BUNDLE_MODULES` list controls which modules are embedded (in dependency order)
- Bundle includes a `BUNDLED_ASSETS` table + `asset_load()` helper as extension point for future asset embedding
- Bundled game accepts: `--seed N`, `--save <path>`, `--load <path>` at runtime
- Flags: `--output <path>` (default: same dir as .sb with .lua extension), `--production`

### `cli/lsp.lua` (~340 lines)
Language Server Protocol server. Communicates over stdio using JSON-RPC 2.0.
- `M.run()` — main loop; reads messages from stdin, dispatches handlers, writes responses to stdout
- `M.build_syms(typed_ast)` → `{[name]=sym}` — extract flat symbol map from typed AST + symtab; each entry has `{kind, pos, doc, detail}`
- `M.word_at(lines, line0, char0)` → `string|nil` — extract identifier/path under 0-based cursor
- `M.make_lsp_diags(diags)` → `table[]` — convert StoryBase diagnostics to LSP format

**Supported LSP methods:**
- `initialize` — returns server capabilities (hover, definition, completion, diagnostics)
- `textDocument/didOpen`, `textDocument/didChange`, `textDocument/didClose` — document lifecycle; publishes diagnostics on open/change
- `textDocument/hover` — doc string + kind + param list for symbol under cursor
- `textDocument/definition` — jump to declaration position
- `textDocument/completion` — names, state paths, types, scenes filtered by prefix; trigger characters `/` and `-`

**Symbol kinds collected:** `type`, `state`, `relation`, `scene`, `grid`, `fn`, `actor`, `schedule`, `bounded`, `macro`

### `cli/compact_cmd.lua` (~115 lines)
- `M.run(args)` — replay save log into fresh state, write compact save with one entry per path
- Usage: `storybase compact <game.sb> <save.log> [--out <out.log>]`

### `cli/cli_cmd.lua` (~340 lines)
Single-step scripting mode for `storybase run --cli save.sbd`.
- `M.run(game_table, save_path, opts)` — main entry point; reads `opts.input` as a choice index (or `q`/`quit`/`exit`), executes one step, writes save, emits JSON to `opts.output`
- Save format: `save.sbd` Lua chunk (scene stack, log, state snapshot, checkpoint stack) + `save.sbd.snap` for fast replay
- JSON output: `{type, scene, narration, choices, state, done, saved}` for state; `{type="quit"}`, `{type="done"}`, `{type="error", message}`
- `opts.reset = true` — restart from initial state; `opts.seed` — RNG seed

---

## lib/

### `lib/storybase.lua` (~420 lines)
Public Lua API for embedding StoryBase in another Lua program.
- `M.load(filepath)` → game object (compiles from file)
- `M.from_source(source, filename?)` → game object (compiles from string)
- `M._make_game(game_table)` → game object with methods:
  - `game:init()` — initialise from defaults; must call before anything else
  - `game:render()` → narration list, choices list
  - `game:current_scene()` → scene name string
  - `game:choose(index)` → bool; dispatch player choice + post_action
  - `game:call(fn_name, ...)` → retval; invoke named function with raw Lua args
  - `game:eval(expr_string)` → value, err; evaluate pure expression string
  - `game:get(path)` → value; read state path
  - `game:set(path, value)` — write state path directly
  - `game:tick()` — one autonomous turn (post_action only)
  - `game:save(filepath)` → ok, err; write save file
  - `game:load(filepath)` → ok, err; restore from save file
  - `game:on(event, handler)` — subscribe to "choice", "mutation", "scene-change", or any custom `engine/emit` event name
  - `game:register_bounded(name, fn)` — register bounded computation handler
  - `game:docs(name?)` — return doc string(s) from compiled game table; no arg returns all docs as a table, name arg returns the doc for that entity

---

## tests/

| File | What it tests |
|------|--------------|
| `tests/compiler/ast_spec.lua` | AST node constructors |
| `tests/compiler/lexer_spec.lua` | Tokenizer |
| `tests/compiler/parser_spec.lua` | Parser (includes INDEX_EXPR tests) |
| `tests/compiler/checker_spec.lua` | Checker passes 1-6 (schema, types, purity, perceives, boundary, write-sets) |
| `tests/compiler/codegen_spec.lua` | Game table emission; production build mode |
| `tests/compiler/import_spec.lua` | Import resolver (basic, FILE_NOT_FOUND, IMPORT_CYCLE, transitive) |
| `tests/compiler/defgrid_spec.lua` | defgrid parser, checker, codegen, engine integration (26 tests) |
| `tests/lib/storybase_spec.lua` | Public Lua interop API; find(), counterfactual() |
| `tests/runtime/integration_spec.lua` | End-to-end gameplay scenarios (walk, combat, guarded shop, save/load) |
| `tests/runtime/state_spec.lua` | Store CRUD, clamping, undo, spawn/despawn |
| `tests/runtime/eval_spec.lua` | Expr/stmt evaluation; pre: fix; path-exists? fix |
| `tests/runtime/engine_spec.lua` | Engine init, render, choice, save/load |
| `tests/runtime/actors_spec.lua` | Actor registry, perception filtering |
| `tests/runtime/search_spec.lua` | can_reach, find_path, probability, optimal_path; time-budget |
| `tests/runtime/verify_spec.lua` | verify block runner (always/after/requires/counterexample) |
| `tests/runtime/log_spec.lua` | Log append, query, serialise/deserialise, query_at |
| `tests/runtime/query_spec.lua` | Relation queries |
| `tests/runtime/counterfactual_spec.lua` | Counterfactual branching |
| `tests/runtime/debug_spec.lua` | TCP server, clamp-event, JSON codec; hot reload schema migration; spawn/despawn events |
| `tests/runtime/debug_http_spec.lua` | HTTP/SSE transport: lifecycle, GET /, POST /command, get-scene/do-choice, SSE events (23 tests) |
| `tests/runtime/migrate_spec.lua` | Migration runner unit tests (all op kinds, chain ordering) |
| `tests/runtime/migrate_demo14_spec.lua` | Integration test for demo14's full 1→4 migration chain |
| `tests/runtime/tilegrid_spec.lua` | Tile grid algorithms: storage, within_range, visible_from, find_path, occupied_by (83 tests) |
| `tests/cli/extract_symbols_spec.lua` | extract-symbols CLI command |
| `tests/cli/compact_spec.lua` | compact CLI command |
| `tests/cli/bundle_spec.lua` | bundle CLI command: output validity, execution, --production, save/load, error cases (20 tests) |
| `tests/cli/cli_integration_spec.lua` | Full CLI integration tests: all subcommands (check/compile/run/format/repl/verify/migrate) against all test*.sb + demo*.sb files; also import alias, exports:, source-context error output tests |
| `tests/cli/lsp_spec.lua` | LSP server unit tests: build_syms (types/states/fns/actors/docs), word_at (word extraction, paths, hyphens), make_lsp_diags (severity, positions), integration with real parse+check (43 tests) |
| `tests/cli/cli_cmd_spec.lua` | `--cli` single-step mode: fresh start, state persistence, reset, quit, error handling, game completion, checkpoint+undo (demo08), state fields, subprocess integration (35 tests) |
| `tests/runtime/scheduler_spec.lua` | Scheduler unit tests: every:/at:/offset: triggers, cancel, deregister, end-to-end pipeline |
| `tests/test01_minimal.sb` – `test06_actors.sb` | Integration .sb files (test suite) |
| `tests/fuzz/parser_fuzz_spec.lua` | Property test: random input never crashes parser |
| `tests/fuzz/log_fuzz_spec.lua` | Property test: log serialise/deserialise round-trip; replay determinism |
| `tests/fuzz/perf_benchmark_spec.lua` | Performance benchmark: can_reach depth=50, probability, find_path |
| `tests/runtime/ulist_spec.lua` | UList(T) and UMap(K,V) builtin tests: all 15 pure UList ops, 8 UMap ops, mutation primitives, Lua interop (60 tests) |

Run all tests: `busted tests/`

---

## examples/

Standalone Lua scripts demonstrating the StoryBase embedding API. Run from the repo root.

| File | What it demonstrates |
|------|----------------------|
| `examples/bounded_interop_game.sb` | Merchant/courier game: `UList(String)` ledger, `bounded` reputation handler, entity family with `max:`, `advance-season`, `hire-courier`, `complete-contract` |
| `examples/bounded_lua_interop.lua` | Comprehensive embedding API walkthrough: `sb.load`, `game:init`, `game:register_bounded`, `game:on("mutation")`, `game:call`, `game:get`, `game:find`, `game:eval`, `game:counterfactual`, `game:save`/`game:load`, `game:docs`; all UList and UMap builtins exercised |

Run: `lua5.4 examples/bounded_lua_interop.lua`

---

## demos/

Example games demonstrating progressive language features. All runnable with `storybase run demos/<file>`.

| File | Features demonstrated |
|------|-----------------------|
| `demo01_wanderer.sb` | module, Int state, scene narration, `->`, `inc!`, `{expr}` |
| `demo02_merchant.sb` | type enum, multiple state paths, fn, choice guards, `match`, `if/else` |
| `demo03_quest.sb` | Bool flags, `fn` with `pre:`, `when`, `if/else`, Class enum, XP system |
| `demo04_expedition.sb` | entity family (`state crew/{m}`), `spawn!`/`despawn!`, `for`/`path-list`, `path-exists?`, `count-where` |
| `demo05_siege.sb` | time-model, actor + behavior, `send!`, schedule, `cancel-schedule!`, `verify-always` |
| `demo06_buried_keep.sb` | schema-version + migration, record types, static/dynamic relations with `{...}` data, `relate!`/`unrelate!`, `defgrid`/`within-range?`, tag+hook, watch/watch-when, `in` operator, `contains?`, `size`/`empty?` on map-style sets, `union`/`intersect`, `any?`/`all?`, `push!`/`pop!`, actor+inbox, `match` on variant, `spawn!`/`despawn!`, `count-where`, `path-exists?`, `verify-always`, `for` over `path-list` |
| `demo07_oracle.sb` | two-file split via `import` (oracle_lib.sb), `bounded` computation (oracle-weather with `?? 'clear` fallback), `counterfactual` for pure preview functions called from scene narration |
| `oracle_lib.sb` | shared types (`Shrine`, `WeatherKind`), state, relation (`paths`), pure helpers — imported by demo07_oracle.sb |
| `demo08_probability_engine.sb` | `probability`, `can-reach?`, `find-path`, `optimal-path`, `find-counterexample` as in-game mechanics; `engine/emit`, `engine/checkpoint!`, `undo!`; explicit lambda `fn(x): ...`; `verify after requires`; `if/else` in fn bodies; `nil` literal |
| `demo09_wardens_map.sb` | `grid-get`/`grid-set!` (tile cell read/write), `visible-from?` (guard LOS), `path-to` (shortest route with blocked-set), `occupied-by` (cell collision check); `while` loop, `cond` expression, inline `Enum(a,b,c)` type, lambda in `count-where`, `engine/emit`, `verify from-any-state:` |
| `demo10_market_bell.sb` | multi-axis `time-model` (`axes: [day, hour]`, `wrap: [none, 24]`), `time-inc!` on hour axis (browsing) and day axis (rest), `time-set!` (reset hour to morning), `every: [day: +1]` schedule (morning-bell), `at: [day: +4]` one-shot schedule (grand-festival), `cancel-schedule!`, `engine/emit`, `watch`/`watch-when`, `verify-always`, `verify after` |
| `demo11_expedition_guild.sb` | type aliases (`type Gold = Int(0,500)`), `Option(T)` + `??`, `find` with `where:`/`order-by:`/`limit:`/`count`, computed `goto` via `-> (fn arg)`, multiline strings, `verify after requires`, `@before` in verify |
| `demo12_codex.sb` + `codex_lib.sb` | two-file split via `import "codex_lib.sb" as Herb` (namespaced alias), cross-file `Option(Herb.RemedyKind)`, cross-file fn calls (`Herb.assess-stock`, `Herb.dry-garden`), cross-file scene nav (`=> Herb.harvest`), state family (`garden/{p}: GardenBed`), multiline strings, `verify after` across files with cross-file `requires` |
| `demo13_healers_ward.sb` | `speaker` declarations with `display:`/`color:`, all `say` forms (bare-id, block, dynamic `(expr):`), `say` in fn bodies (buffered → prepended to next scene), `post:` with `path@before` on both plain and interpolated paths, multi-line lambda body in `find patients where: fn(k):\n  let...\n  return`, `count family where: fn(k):` syntax, entity family `patients/{k}: Patient max: 8` |
| `demo14_kingdoms_records.sb` | `schema-version: 4`, full migration chain 1→2→3→4: `add` (String field), `rename` + `drop`, `transform` (`fn old: old * 100`), `rename-enum` (`'at-war → 'warring`); `post:` on `advance-year`; simple game loop with census browse/update/advance |
| `demo15_spellwright.sb` | hygienic macros: `with-mana-cost cost body:` (resource-guard + hygienic `let`) and `craft-spell ingredient body:` (ingredient-check + body-splice); both macros composed in three spell-casting fns; `post:` with `@before`; entity family `spells/{spell}: SpellRecord`; Set-literal state default `Set(ComponentKind, 10) = {'dragonscale, ...}`; `verify` blocks |
| `demo16_cartographers_web.sb` | advanced find queries: `or-where` (trade hubs = markets ∪ coastal), `connected-to 'capital-city via roads`, `inverse-adjacent? roads 'port-city`; `find` with `order-by + limit + or-where`; `can-reach?` with `strategy: 'depth-first`; `find-path` with `strategy: 'breadth-first`; `counterfactual simulate: true` (route-bonus schedule fires in branch); `relate!/unrelate!` dynamic road mutations; entity family `cities/{city}: CityRecord` |

---

## Key Cross-Cutting Patterns

**Compile-time path:** `source → tokens → AST → typed AST (symtab) → game_table`

**Runtime path:** `game_table → engine → store + log + actors + sched + rng`

**BFS pattern (search, verify):**
1. Build initial `{cache=store._cache copy, stack=[entry_scene]}` node
2. Hash `(cache, stack)` for cycle detection
3. For each node: call `eng:render_scene` → enumerate choices → `eng:do_choice` + `post_action`
4. Collect resulting `(cache, stack)` pairs as children

**State path format:** `"namespace/subpath"` — e.g. `"world/gold"`, `"npcs/bot/health"`, `"player/inventory"`

**Clamp hook:** `store._clamp_hook = function(path, attempted, clamped, fn_name)` — set by `engine:set_debug_server`

**Navigation signals:** `{type="goto"|"enter"|"exit", target=name?}` — returned by `do_choice`, propagated through `eval_stmt` via `ctx.signal`

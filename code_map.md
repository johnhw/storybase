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

### `compiler/ast.lua` (1007 lines)
AST node constructors and constants. Import as `local ast = require("compiler.ast")`.

**Constants:**
- `ast.K.*` — all node kind strings (see below)
- `ast.E.*` — error codes (e.g. `UNDEFINED_TYPE`, `DUPLICATE_DECL`, `MACRO_DECL_EMIT`)
- `ast.W.*` — warning codes (e.g. `PERCEIVES_VIOLATION`, `IMPURE_IN_PURE`)

**Helpers:**
- `ast.pos(file, line, col)` → pos table
- `ast.error(code, msg, pos, note?)` → diag table
- `ast.warning(code, msg, pos, note?)` → diag table
- `ast.is_mut(node)` → bool — true if node is a mutation statement kind
- `ast.format_expanded_from(info)` → string — §E0 Stage 4 helper that
  formats `{macro_name, macro_pos}` into a `"expanded from macro 'N' at
  F:L"` note; `_diag` calls it automatically when `pos.expanded_from`
  is set, so any diagnostic carrying a stamped expansion pos is decorated
  for free

**Declaration kinds (`ast.K.*`):**
```
PROGRAM, MODULE_DECL, IMPORT_DECL, SCHEMA_VERSION, ENGINE_CONFIG, TIME_MODEL
TYPE_ENUM, TYPE_ALIAS, TYPE_RECORD, TYPE_VARIANT
STATE_SCALAR, STATE_RECORD, STATE_FAMILY
RELATION_DECL, FN_DECL, ACTOR_DECL, SCHEDULE_DECL
BOUNDED_DECL, VERIFY_DECL, WATCH_DECL, WATCH_WHEN_DECL
SCENE_DECL, MACRO_DECL, DECL_MACRO_DECL, MACRO_CALL_DECL, MIGRATION_DECL, DEFGRID_DECL
TEST_DECL, GENERATE_DECL, ENDING_DECL
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

### `compiler/lexer.lua` (530 lines)
- `M.tokenize(source, filename)` → `{tokens=[], errors=[]}`
- Handles INDENT/DEDENT pre-pass, all token types, NAMED_ARG (`foo:`), COMPUTED_GOTO, PATH tokens (`a/b/c`)
- Token shape: `{type=STRING, value=ANY, line=N, col=N}`
- §E0 Stage 2 tokens: `MACRO_PARAM` (bare `$ident`, value=name) and
  `COMPOSITE_IDENT` (no-whitespace `IDENT`/`$IDENT` run joined by `-`,
  value=parts list of strings and `{kind="macro_param", name=...}` entries;
  trailing `!`/`?` folded into the last string part)

---

### `compiler/parser.lua` (3479 lines)
- `M.parse(tokens, filename)` → `(ast_root, diags[])`
- Recursive descent; parser state `p` carries cursor + error accumulator
- Key parse functions (all local): `parse_decl`, `parse_expr`, `parse_primary`, `parse_stmt`, `parse_type_expr`, `parse_scene_body`
- `parse_primary` IDENT branch: checks for `[` before arg-collection loop to produce `INDEX_EXPR` instead of `FN_CALL`
- §E0 Stage 2b: `parse_fn_decl`, `parse_state_decl`, `parse_mut_path`,
  and `parse_atom` accept `MACRO_PARAM`/`COMPOSITE_IDENT` in name and
  path positions; AST nodes carry a `name_parts` field (composite case)
  or a `PATH_EXPR.segments` entry of shape `{kind="macro_param",name=X}`
  / `{kind="composite",parts=...}` until Stage 3 expansion substitutes
  them. `parse_decl`'s IDENT branch falls through to
  `parse_macro_call_decl` (new) for unknown idents.
- §E0 Stage 5: `parse_macro_call_decl` consumes an optional `.` +
  IDENT after the leading name so `Alias.macro-name` from a
  namespaced import (`import "lib" as Alias`) parses cleanly (mirrors
  the existing `parse_atom` fn-call branch at line 1200).
- §J-I3 (2026-05-21): `parse_if_expr` accepts `elif cond:` or
  `else if cond:` after the then-body, desugaring to a nested `if_expr`
  in `else_body`. `elif` is a new lexer keyword; `else if` is handled
  via two-token lookahead. AST shape is identical to hand-nested
  `if/else: if`, so checker/codegen/runtime need no changes.

---

### `compiler/checker.lua` (2922 lines)
- `M.check(ast_root, filename)` → `(typed_ast, diags[])`
- Attaches `ast_root.symtab = {types={}, states={}, relations={}}` for codegen
- Four passes (all local):
  - `pass1_collect` (line 98) — build symtab from declarations
  - `pass2_check` (line 316) — type/reference validation
  - `pass3_infer_purity` (line 375) — mark `fn.pure=true` if no mutations
  - `pass4_check_perceives` (line 478) — warn `PERCEIVES_VIOLATION` for reads outside actor's `perceives:` list
- `collect_path_reads(node, into)` (line 431) — recursively collect PATH_EXPR reads from an AST subtree

---

### `compiler/codegen.lua` (910 lines)
- `M.emit(typed_ast, opts?)` → `(game_table, diags[])`
- `opts.production = true` → strips verifies and watches from game_table; sets `game_table.production = true`
- Produces the **game_table** structure (see below)
- Local emitters: `emit_types`, `emit_states`, `emit_relations`, `emit_engine_config`, `emit_time_model`, `emit_fns`, `emit_scenes`, `emit_actors`, `emit_schedules`, `emit_verifies`, `emit_watches`, `emit_bounded`, `emit_migrations`, `emit_quests` (§E1)
- §E1 auto-verify: `emit_quest_verifies` synthesises one
  `verify-eventually (quest-<name>-complete?)` clause per `QUEST_DECL`,
  appended to `game_table.verifies` (skipped in production builds).
- §E4-gap-2: `emit_quests` exposes `prereq` and `reward` (and
  `steps[].requires`) on each `game_table.quests` entry as raw AST
  nodes — sufficient for tooling that walks the AST shape directly.
  Downstream tools should treat them as opaque or dispatch on
  `ast.K.*` constants. If a more stable representation becomes
  necessary later, build it on top of these fields without renaming
  them.

---

### `compiler/types.lua` (~170 lines)
- `M.DISCRETE` / `M.SUPERFICIAL` — type category constants
- `M.is_discrete(ty)` / `M.is_superficial(ty)` — classify a type descriptor
- `M.state_space_size(ty)` → number — cardinality of a type (exact integer
  for small types; loses precision past 2^53 — use `state_space_log2` instead)
- `M.state_space_log2(ty)` → float — log2 of cardinality, accurate for
  arbitrarily large finite state spaces. Composite types accept either size
  (`inner_size`/`elem_size`/`product_size`/`sum_size`) or pre-computed log2
  (`inner_l2`/`elem_l2`/`product_l2`/`sum_l2`) inputs.
- `M._log2(x)` / `M._log2_add(a, b)` — helpers re-exported for codegen

---

### `compiler/compiler.lua` (~700 lines)
- `M.compile(source, filename, opts?)` → `(game_table, diags)`
- `M.compile_file(filepath, opts?)` → `(game_table, diags)`
- `M.parse_and_check(source, filename)` → `(typed_ast, diags)` — stops before codegen; returns AST with `.decls`
- `M.parse_and_check_file(filepath)` → `(typed_ast, diags)`
- `M._stdlib_dir_override` → test hook; takes precedence over the env
  var when set (see §E0 Stage 5 below)
- `opts.production = true` → passed to codegen to strip debug-only content
- Runs lexer → parser → resolve_imports → checker → codegen in sequence
- `resolve_imports` splices imported declarations (from `import "file.sb"`) before type-check; cycle detection via IMPORT_CYCLE error.
- §E0 Stage 5 import resolver extensions:
  - `resolve_import_path` recognises `@stdlib/<name>` and routes to the
    stdlib dir. Resolution order: `M._stdlib_dir_override` →
    `STORYBASE_STDLIB_DIR` env var → repo-relative `<repo>/stdlib/`
    (derived from this file's `debug.getinfo` source). `.sb` is
    appended automatically if absent.
  - `apply_import_namespace` renames `DECL_MACRO_DECL.name` and
    `MACRO_CALL_DECL.name` (so `import "lib" as C` rewrites both the
    template name and any internal call site).
  - `EXPORTS_FILTERABLE` includes `DECL_MACRO_DECL`, so
    `module ... exports: [name]` whitelist filtering works for
    decl-macros.
- `expand_macros` runs two sub-passes: §E0 Stage 3 `expand_decl_macros`
  splices `MACRO_CALL_DECL` sites with `DECL_MACRO_DECL` bodies (deep-copy
  + `$param` substitution into `PATH_EXPR.segments` and `name_parts`),
  then the legacy stmt-level walker expands `MACRO_CALL_STMT`. Both
  `DECL_MACRO_DECL`/`MACRO_CALL_DECL` and `MACRO_DECL` nodes are stripped
  before the checker runs. Errors: `UNDEFINED_NAME` for unknown macro;
  `MACRO_DECL_EMIT` for arity/substitution mismatch. §E0 Stage 6 adds
  the single-pass restriction: at template-registration time the body is
  scanned for `MACRO_CALL_DECL` children and any nested decl-macro call
  raises `MACRO_DECL_EMIT` ("nested decl-macro calls are not supported").
- §E0 Stage 4: every emitted node gets a fresh pos table stamped with the
  call site's `(file, line, col)` plus a `pos.expanded_from =
  { macro_name, macro_pos }`. The node itself also carries
  `node.expanded_from = <body's original pos>` for tooling. Diagnostics
  raised by the checker (or any later pass) against expanded nodes are
  auto-decorated with `"expanded from macro 'NAME' at FILE:LINE"`
  inside `ast._diag` — no checker-side change needed.
- §E3 substrate extension (drove inventory / stat): three new
  substitution sites inside `substitute_decl_node`:
    * `TYPE_NAMED.name` resolves a `{kind="macro_param", name=X}`
      placeholder to a single identifier via `_resolve_type_name_param`.
    * `TYPE_INT.{min,max}`, `TYPE_SET.max`, `TYPE_LIST.max` accept
      the same placeholder and resolve via `_resolve_int_param`
      (must bind to an `INT_LIT`).
    * A single-segment `PATH_EXPR` whose lone segment is a
      `$param` and whose bound value is a literal node is replaced
      in place by that literal via `_literal_substitution` — supports
      `set! $path $max`, `state $p: T = $max`, `if $count > 0`, etc.
  Parser side: `parse_type_expr` learns a `parse_int_bound` helper
  that accepts either `INTEGER` or `MACRO_PARAM` for `Int` / `Set` /
  `List` bounds, plus `MACRO_PARAM` as a leading type-name token.
  `parse_default_value` accepts `MACRO_PARAM`, emitting a
  single-segment placeholder PATH_EXPR.
- §E1 `expand_quests` (between `expand_macros` and the checker) walks
  the top-level decl list; for every `QUEST_DECL` it emits a fixed set
  of state/fn AST nodes (`quests/<Q>/active`, `quests/<Q>/complete`,
  `quests/<Q>/<sᵢ>`, plus `quest-<Q>-active?` / `-complete?` /
  `-step-<sᵢ>?` / `-start!` / `-do-<sᵢ>`) and splices them into the
  program.  The original `QUEST_DECL` is retained so codegen can attach
  the auto-verify entry.  Reports `DUPLICATE_NAME` for two quests with
  the same name or two steps with the same name in one quest.

---

## stdlib/

Shipped `.sb` modules importable via the `@stdlib/<name>` prefix
(resolved by `compiler/compiler.lua:resolve_import_path`, §E0 Stage 5).
The resolver looks up `M._stdlib_dir_override` first (test hook), then
`STORYBASE_STDLIB_DIR` env var, then defaults to `<repo>/stdlib/`.

### `stdlib/counter.sb`
A reference decl-macro: `counter $path` emits a bounded-int state at
`$path` plus `$path-inc`, `$path-dec`, `$path-reset` mutating fns. Used
by the §E0 Stage 5 cross-import acceptance tests and the §E0 Stage 6
end-to-end acceptance test; serves as a template for the larger E2/E3
stdlib modules. Authored in line with the
"Decl-emitting macros" section of `docs/reference/language.md`.

### `stdlib/inventory.sb` (§E3)
`inventory $name $T $max` emits a `Set($T, $max)` state at `$name`
plus 7 helper fns (`$name-give`, `-take`, `-has?`, `-count`,
`-empty?`, `-full?`, `-clear!`).  Relies on the §E3 substrate
extension that lets `$T` slot into a type-name position and `$max`
slot into both the `Set` capacity and the `full?` comparison literal.

### `stdlib/stat.sb` (§E3)
`stat $name $min $max` emits an `Int($min, $max) = $max` state plus 8
helper fns (`$name-heal`, `-hurt`, `-set`, `-restore`, `-deplete`,
`-full?`, `-empty?`, `-current`).  Default-value slot in
`= $max` and the `set! $name $max` body lean on the §E3 literal-into-
expression-context substitution rule.

### `stdlib/dialog.sb` (§E2)
`dialog-topic $owner $topic` emits a `{$owner}-asked-{$topic}: Bool`
state and four conventional helpers (`$owner-asked-$topic?`,
`$owner-not-asked-$topic?`, `mark-$owner-$topic-asked!`, and
`$owner-reset-$topic!`). Compresses the per-topic asked-flag
boilerplate that talk-style scenes (`demos/demo20_harrow_house.sb`)
hand-roll today. Uses only the §E0 COMPOSITE_IDENT substrate;
state path is a single fused segment because the PATH lexer
doesn't currently scan `/$param` chains. Both args must be
single-segment kebab-case.

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
    state_space_size = number|"unbounded",   -- exact int when ≤ 2^53; else "unbounded"
    state_space_log2 = number,               -- log2 of cardinality, always finite-float
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
  tests      = [ {label, setup=[stmts], run=[stmts], expect=[exprs]} ],  -- empty in production builds
  migrations = [ {from_version, body} ],
  bounded    = { [name] = {reads, body} },
  generates  = [ {name, seed_path, body, doc} ],            -- §F1
  endings    = [ {name, when_expr, body, doc} ],            -- §F2
  quests     = [ {name, description, steps=[{name}], doc} ],-- §E1
  production = bool,  -- true if compiled with opts.production
}
```

---

## runtime/

### `runtime/config.lua` (~330 lines)
Registry-backed configuration with a precedence chain. Every tunable knob
is `declare`'d once (type + default + doc); reads of undeclared keys error.

**Precedence (highest first):** `runtime > cli > env > file > game > default`
- `runtime` — `config.set(key, v)` programmatic override
- `cli`     — populated by `config.bind_cli({...})` from parsed args
- `env`     — `STORYBASE_*` env vars, populated by `config.load_env()`
  (auto-derived name: `engine.scene-stack-max` → `STORYBASE_ENGINE_SCENE_STACK_MAX`)
- `file`    — simple `key = value` lines, populated by `config.load_file(path)`
- `game`    — compiled `engine-config:` block, populated by `config.bind_game(game_table)`
  (block keys are namespaced under `engine.*`)
- `default` — built-in defaults from the registry

**API:**
- `declare(key, spec)` — spec = `{type, default, doc, enum?, env?, cli?, coerce?}`
- `get(key)` → `(value, layer)` — `layer` names the winning source
- `set(key, value)` — runtime override; pass nil to clear
- `load_env(getenv?)`, `load_file(path)` → `(ok, errors)`
- `load_startup({home, cwd, getenv})` → `(errors, sources)` — loads
  `<home>/.storybaserc`, then `<cwd>/.storybaserc` (later wins), then
  env vars. Missing files silently skipped. Called once at CLI startup.
- `bind_game(game_table)`, `bind_cli(args)` — both clear their layer on
  call, so `bind_cli(nil)` / `bind_game(nil)` are valid clears.
- `dump()` → `{[key] = {value, layer, doc}}`
- `format_help()` → string — one line per registered key
  (`  key   (type, default=…)  — doc`), used by `cli/main.lua` for help.
- `keys()`, `spec(key)`, `_reset()` (test-only)

Type coercion: `int`, `float`, `bool` (true/yes/on/1 vs false/no/off/0),
`string`, `enum`. Custom `coerce = fn(raw) -> value, err` overrides built-ins.

### `runtime/state.lua` (722 lines)
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

### `runtime/eval.lua` (2696 lines)
Expression and statement evaluator. All evaluation goes through here.

- `M.new_ctx(state, fns, fn_name, game)` → ctx
- `M.eval_expr(node, ctx)` → value
- `M.eval_stmt(node, ctx)`
- `M.eval_stmts(stmts, ctx)`
- `M.eval_path(node, ctx)` → path string (resolves interpolations)
- `M.call_fn(name, args, ctx)` → value
- `M.render_text(text, ctx)` → string
- `M.child_ctx_vars(ctx, vars)` → new ctx with extra var bindings
- `M.eval_for_iter(node, ctx)` → list — used by `for` loops (J-I2 Shape C):
  if the iter is a bare identifier matching a declared `enum` type,
  returns the enum's variant symbols; otherwise delegates to `eval_expr`.
  Builds `schema._type_index` lazily on first call.

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
range            n | lo hi | lo hi step → List(Int) (Python-style, exclusive hi; capped at 10000)
query-at         path [time: value] → value at given time bound (or current if omitted)
query-history    path → [{time, old, new}, ...] (all recorded changes)
query-changes    path [last-n: N] → [{time, old, new}, ...] (most recent N changes)
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
**Coverage hook:** before executing a user fn body, `call_fn` fires `ctx.game._fn_call_hook(name)` if set — used by `cli/coverage_cmd.lua` to count fn invocations during BFS

**Mutation statements (eval_stmt):** SET_MUT, INC_MUT, DEC_MUT, ADD_MUT, REMOVE_MUT, CLEAR_MUT, PUSH_MUT, POP_MUT, SPAWN_MUT, DESPAWN_MUT

---

### `runtime/engine.lua` (800 lines)
Game loop coordinator.

- `M.new(game_table, opts)` → eng  (opts: `io_out`, `io_in`, `seed`, `debug_server`, `driver`, `max_stack`)
  - Declares engine-side config keys via an idempotent
    `declare_engine_config()` helper with `runtime/config.lua`:
    `engine.scene-stack-max` (int, default 16), `engine.entry-scene`
    (string, no default), `engine.npc-speed` (int, default 0). Calls
    `config.bind_game(game_table)` and resolves values through
    `config.get`. `opts.max_stack` is a per-instance escape hatch that
    beats the resolved scene-stack-max without mutating global state.
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
eng:render_scene(name)        → (narration, choices[])
eng:do_choice(scene_name, idx) → nav_signal
eng:_walk_scene_choices(items, ctx, visit) → bool  -- J-I2: shared
                              -- left-to-right depth-first walk of scene-body
                              -- items, calling visit(choice_node, ctx) for each
                              -- visible choice; descends into for_stmt /
                              -- when_stmt / if_expr bodies so nested * choices
                              -- participate in the visible list. Used by
                              -- render_scene (populate visible list) and
                              -- do_choice (locate player-selected choice).
eng:post_action()             -- run actors + scheduler after player choice
eng:post_action_chain()       -- post_action + N extras per engine-config npc-speed (used by search.lua / verify.lua so reachability mirrors the live loop)
eng:autonomous_turn()         -- actors + scheduler only (no player input)
eng:step()                    -- render + (driver or stdin) prompt + do_choice
eng:_render_plain(narration)  -- built-in plain-text rendering (no driver)
eng:set_debug_server(srv)     -- wire debug server + clamp_hook
eng:make_ctx(fn_name)         → eval ctx
eng:render_text(text, ctx)    → string
eng:out(s)                    -- write to io_out
eng:inp()                     → string  -- read from io_in
eng:run_generates()           -- §F1: execute every generate block once
eng:check_ending()            → ending|nil  -- §F2: first matching ending
eng:_render_ending(ending)    → narration list  -- §F2
```

**Narration item structure** (returned by `render_scene`):
- `{kind="narration", text=string}` — plain scene narration line
- `{kind="say", speaker, display, color, text}` — speaker dialogue; `color` is hex string or nil

**Driver interface** (`opts.driver`): if set, `step()` delegates to `driver:render(scene_output)` and `driver:prompt(choices)` instead of built-in I/O. `scene_output = {narration=[...], choices=[...]}`.

**Internal fields:** `eng._state`, `eng._log`, `eng._fns`, `eng._scenes`, `eng._scene_stack`, `eng._actors`, `eng._scheduler`, `eng._grids`, `eng._driver`
**Grid initialisation:** `eng:init_grids()` — creates flat cell arrays from `game_table.grids`; called by `eng:init()`.
**ctx.grids:** populated in `make_ctx()`; points to `eng._grids` (name → `{cells,width,height,cell_type,default_val}`)

---

### `runtime/search.lua` (1140 lines)
BFS / Dijkstra over `(cache_snapshot, scene_stack)` pairs.

- `M.can_reach(game_table, cache, stack, condition_fn, depth, budget?)` → `(bool|nil, timed_out_bool)` — returns `nil` (not `false`) on budget timeout so callers can distinguish "not reachable" from "unknown"
- `M.find_path(game_table, cache, stack, condition_fn, depth, budget?)` → `[{scene, label, index}, ...]` | nil
- `M.probability(game_table, cache, stack, condition_fn, depth, threshold)` → float 0..1
- `M.optimal_path(game_table, cache, stack, condition_fn, depth, cost_fn)` → path | nil  (Dijkstra)
- `M.expand_graph(game_table, cache, stack, opts)` → `{nodes, edges, truncated, node_count, edge_count}` — full BFS expansion for the Graph tab; opts: `depth` (6), `max_nodes` (2000), `budget` (10s); nodes have `{id="nN", scene, depth, terminal, cache_summary, cache}`; edges have `{from, to, label, choice_index}`
- `M.verify_eventually(game_table, cache, stack, cond_fn, depth?, budget?)` → result table — EF: condition reachable. Result includes `pass`, `counterexample_path` (witness path on pass, or empty on fail), `states_checked`, `truncated`.
- `M.verify_always_eventually(game_table, cache, stack, cond_fn, depth?, budget?)` → result table — AF: every path eventually satisfies condition. Bounded fixpoint over `expand_graph`. Counterexample = greedy walk through non-AF nodes.
- `M.verify_until(game_table, cache, stack, p_fn, q_fn, depth?, budget?)` → result table — AU: p until q. Bounded fixpoint over `expand_graph`.
- `M.new(state, game, opts)` → search object (alternative stateful API, less used)

**BFS node:** `{stack=[], cache={}, depth=N}`  
**Cycle detection:** content hash of `cache + stack` via local `hash_cache`  
**Note:** `probability` does NOT use cycle dedup (all paths must be counted separately)  
**Time budget:** `budget` in seconds (nil = no limit); clock checked every `BUDGET_CHECK_N=50` iterations

---

### `runtime/tests.lua` (72 lines)
Test block runner (lighter sibling of verify.lua).

- `M.run_all(game_table)` → `[{label, pass, fail_msg?}]`

Each test runs in a fresh state initialised to game defaults:
1. Apply `setup` mutation statements
2. Execute `run` function-call statements
3. Evaluate each `expect` boolean expression; fail on first false result

Stripped from production builds (`game_table.tests = {}` when `opts.production`).

---

### `runtime/verify.lua` (700+ lines)
Verify block runner (offline model-checker).

- `M.run_all(game_table)` → `[{label, pass, fail_msg?, skipped?, reason?, states_checked?, counterexample?, counterexample_n?, counterexample_path?, counterexample_path_original_len?, counterexample_shrink_budget_exceeded?, truncated?}]`
- `M.shrink_path(game_table, path, condition_expr, budget_secs?)` → `(minimised_path, budget_exceeded_bool)` — greedy 1-minimal delta-debugger; exported for external use (e.g., fuzz test counterexamples)
- `M.match_path_pattern(pattern, path)` → bool — path wildcard/alternation matching

**Clause kinds handled:**
- `"always"` → BFS check: `verify-always expr` (AG)
- `"eventually"` → BFS reachability: `verify-eventually expr` (EF) — via `runtime/search.lua:verify_eventually`
- `"always_eventually"` → bounded AF fixpoint: `verify-always-eventually expr` — via `runtime/search.lua:verify_always_eventually`
- `"until"` → bounded AU fixpoint: `verify-until p until q` — via `runtime/search.lua:verify_until`
- `"after"` → single-state check: `after (fn args): assertions`
- `"requires"` → precondition for skipping `after` check
- `"from_any_state"` → check expression holds from every BFS-reachable state
- `"when"` → filter for `from_any_state` snapshots

**BFS depth:** `DEFAULT_BFS_DEPTH = 5`; **Shrink budget:** `DEFAULT_SHRINK_BUDGET_SECS = 5.0`; **CTL fixpoint depth/budget:** `DEFAULT_CTL_DEPTH = 5`, `DEFAULT_CTL_BUDGET = 30`

**Counterexample path fields** (set on `run_always_check` failures):
- `counterexample_path` — `[{scene, label, index}]` minimised action sequence leading to the violation
- `counterexample_path_original_len` — original path length before shrinking (nil if already minimal)
- `counterexample_shrink_budget_exceeded` — true if the 5-second shrink budget ran out

---

### `runtime/actors.lua` (364 lines)
Actor registry and behavior runner.

- `M.new(state, log)` → registry

**registry methods:**
```
registry:register(actor_def)      -- register actor from game_table.actors
registry:send(actor_name, msg)    -- push to actor inbox
registry:deliver_messages()       -- move inbox to actor state paths
registry:run_behaviors(fns)       -- run each actor (behavior fn OR §H1 goal-driven planner) with perception snapshot
registry:apply_deferred()         -- commit deferred writes; logs kind="conflict" on priority clash
registry:clear_inboxes()
registry:set_game(game)           -- §H1: inject compiled game table for planner schema/fn lookups
registry:on_no_progress(fn)       -- §H1: subscribe to "actor has no plan" signal
```

**Perception filtering:** `make_capture_proxy(state, priority, name, perceives, state_path)` — creates read-only proxy where `get(path)` returns nil for paths not in `perceives` list (actor's own `state_path` subtree always readable).

**Conflict logging:** when a lower-priority actor's `set`/`clear` write is discarded because a higher-priority actor already wrote the same path, a `kind="conflict"` entry is appended to the transaction log.

**§H1 goal-directed dispatch:** when `actor.goal` + `actor.actions` are set (no `behavior:`), `run_behaviors` delegates to `runtime/actor_search.find_plan` to pick the next action via bounded BFS; the chosen call flows through the same capture proxy as a regular behavior dispatch (perception filtering + priority conflict resolution still apply). On no-progress, the registry's `_no_progress_hook` fires; the engine surfaces it via the `actor-no-progress` debug event and a `_h1_no_progress` accumulator list on the engine.

---

### `runtime/actor_search.lua` (~280 lines, §H1)
Goal-directed actor planner. Bounded BFS over `(cache_snapshot, action, args) → cache'` transitions.

- `M.find_plan(real_state, game, actor)` → `{name, arg_nodes}` | nil — main entry called from `runtime/actors.lua:run_behaviors`
- `M.clear_plan_cache(actor)` — drop the per-actor stash (hot reload, tests)
- Defaults: `DEFAULT_DEPTH = 3`, `DEFAULT_BUDGET_MS = 50`, `MAX_ARGS_PER_ACTION = 64`, `MAX_FRONTIER = 2000`
- Argument enumeration: `Bool`, bounded `Int` (≤ 16 cardinality), inline `Enum`, `SymbolOf(family)` (live keys via cache scan), `TYPE_NAMED` resolved through one level of alias
- State forking: a fresh `runtime/state.new(schema, log)` sandbox per BFS edge is seeded from a `clone_cache` of the parent snapshot; the action fn runs through `eval.call_fn` so clamping, type-index, and pre/post conditions all behave exactly like the engine path
- Plan cache: after a fresh BFS commits the first step, the remaining plan is stashed under the **post-step** cache hash; next tick consumes one entry if the real state has not drifted (correct under contention — a stale cached step fails its pre-check inside `apply_action` and is discarded)
- Test hooks exported: `_hash_cache`, `_clone_cache`, `_enumerate_param`, `_family_live_keys`, `_cartesian`, `_build_type_lookup`, `_apply_action`, `_eval_goal`

---

### `runtime/log.lua` (428 lines)
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

### `runtime/debug.lua` (1577 lines)
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
**Commands (TCP + HTTP):** `get-state`, `get-scene`, `do-choice`, `get-tick`, `get-mode`, `get-schema`, `eval`, `get-log`, `time-travel`, `set-breakpoint`, `clear-breakpoint`, `reload`, `get-replay-diff`, `get-state-graph`, `get-watches`
**`get-state-graph` payload:** `{depth?, max_nodes?, budget?}` → `{nodes, edges, node_count, edge_count, truncated, current_node_id}`; uses `M.expand_graph` from `runtime/search.lua`
**HTTP server state:** `_http_socket`, `_http_clients`, `_sse_clients`, `_serve_mode`
**Hot reload schema migration:** `reload` command validates Int range, enum values, adds new fields, drops removed fields atomically
**H2 diff-mode hot reload:** `get-replay-diff {src}` compiles new source, runs `runtime/diff_replay.replay` against the live engine's log, and returns `{ok, diffs, final_diff, choices_replayed, aborted?}`. Live engine is untouched.

---

### `runtime/scheduler.lua` (260 lines)
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

### `runtime/tilegrid.lua` (363 lines)
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

### `runtime/query.lua` (386 lines)
Relation and family queries. `where:` clauses support both expressions and lambda predicates (lambda is called with the entity key).

- `M.find(ctx, family, clauses)` → `[key, ...]`  (family member filter)
- `M.adjacent(relation, source)` → `[target, ...]`
- `M.reachable(relation, source, target, max_hops)` → bool
- `M.reachable_set(relation, source, max_hops)` → `{key=true, ...}`
- `M.shortest_path(relation, source, target)` → `[node, ...]` | nil
- `M.inverse_adjacent(relation, target)` → `[source, ...]`

---

### `runtime/random.lua` (217 lines)
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

### `runtime/diff_replay.lua` (~210 lines)
H2: diff-mode hot reload. Re-runs the recorded player inputs against a freshly
compiled game table and reports per-tick state divergence vs the original
playthrough. The live engine and its log are untouched; a throwaway engine
runs the new fn bodies.

- `M.replay(eng, new_gt, opts?)` → `{ok, diffs, final_diff, choices_replayed, aborted?, new_cache, new_scene_stack}`

**Inputs to the replay come from the live engine's log:**
- `kind == "choice"` entries (added by `engine:do_choice`) carry `{scene, idx}`
- `kind == "random"` entries are fed back via `rng:set_provider` so deterministic
  draws stay aligned; calls past the recorded sequence fall through to PCG
- Schema is assumed to match (use the existing `reload` for schema migration)

**Diff entry shape:** `{step, tick, path, old_value, new_value}` — emitted at
each tick where (old, new) for that path changes. Paths that re-converge to
equality are dropped from running state, so a fresh divergence will be re-reported.

**Wired into `runtime/debug.lua`** as the `get-replay-diff {src}` command.

---

## cli/

### `cli/main.lua` (642 lines)
- `M.main(argv)` — top-level dispatcher
- Subcommands: `check`, `compile`, `run`, `format`, `repl`, `verify`, `migrate`, `extract-symbols`, `compact`, `config`, `help`
- Flags: `--save` / `--load` / `--seed N` / `--auto` / `--steps N` / `--debug` / `--serve` / `--ui <name>` for `run`; `--production` for `compile`/`run`
- Global `--config <key>=<value>` (or `--config=<key>=<value>`): repeatable;
  `extract_cli_overrides` strips them out of `argv` before dispatch and
  routes them through `runtime.config.bind_cli`. Malformed pairs, unknown
  keys, and coercion failures go to stderr but never abort.
- Startup sequence (in `M.main`): `require("runtime.engine")` (declares
  engine keys) → `config.load_startup()` (loads `~/.storybaserc`,
  `./.storybaserc`, env vars) → `extract_cli_overrides` → dispatch.
- `BOOL_FLAGS` set prevents boolean flags from eating the following positional arg
- `--auto` / `--steps N`: non-interactive run mode; fake `io_in` always returns "1"; `--steps N` limits turns
- `--debug`: starts debug TCP server (port 7373) + HTTP UI server (port 7374); game runs via stdin; browser panels read-only
- `--serve`: starts HTTP UI server only (port 7374); no stdin loop; browser drives game via `do-choice`; `_serve_mode=true`
- `--ui <name>`: load `cli/drivers/<name>.lua` and pass as `driver` in engine opts (default: `plain`)
- `print_diags(diags, source_map?)` prints errors with source-context lines + caret indicator
- Per-subcommand help: `storybase help <subcommand>` shows detailed usage

### `cli/drivers/plain.lua`
Plain-text UI driver (default). Renders narration as `"Speaker: text"` or bare text; numbered choice prompt; reads from stdin. Implements `{render, prompt, notify}`.

### `cli/drivers/ansi.lua`
ANSI-color UI driver (`--ui ansi`). Same interface as `plain`; applies ANSI true-color (`\27[38;2;R;G;Bm`) to speaker labels using their `color:` hex field; bold choice indices; dim prompt text.

### `cli/check_cmd.lua` (135 lines)
- `M.run(args)` — run lexer → parser → checker (no codegen); print errors/warnings with source context
- Faster feedback than `compile`; exits 0 on success (warnings allowed), 1 on errors

### `cli/config_cmd.lua` (~155 lines)
- `M.run(args)` — implements `storybase config <subcommand>` (see L5)
- Subcommands: `dump [file.sb]` (column table of key/layer/value over the
  full registry; optional file path → `config.bind_game` so the game
  layer is reflected), `get <key> [file.sb]` (machine-friendly single
  value, blank line if unset), `doc <key>` (full spec block — type,
  default, auto-derived env var, declared CLI flag, doc, current
  resolved value with winning layer).
- Bare invocation / `help` prints usage. Unknown subcommand → rc=1.
- Honours the global `--config key=value` flags (applied by
  `cli/main.lua` before dispatch).

### `cli/format_cmd.lua` (1427 lines)
- `M.run(args)` — parse AST and emit canonical indented output
- Flags: `--check` (compare only, exit 1 if differs), `--write` (rewrite in-place with .bak backup)
- Default: write formatted source to stdout

### `cli/repl_cmd.lua` (257 lines)
- `M.run(args)` — load a .sb file and start an interactive expression REPL
- Meta-commands: `:state <path>`, `:scene`, `:choices`, `:choose N`, `:tick`, `:save`, `:load`, `:help`, `:quit`
- Evaluates pure expressions and calls transaction functions interactively

### `cli/test_cmd.lua` (58 lines)
- `M.run(args)` — compile + `tests_mod.run_all` + pretty-print results
- Returns 0 if all pass, 1 if any fail or on compile error

### `cli/coverage_cmd.lua`
- `M.run(args)` — compile + BFS via `runtime/search.lua`'s `expand_graph` + per-scene/fn coverage report
- Flags: `--depth N` (BFS depth, default 8), `--budget N` (seconds, default 30), `--format json`
- Sets `game_table._fn_call_hook` before BFS; `runtime/eval.lua`'s `call_fn` fires the hook on every user fn call
- Outputs: per-scene visit count, per-fn call count, lists of unreachable scenes and uncovered fns, percentage totals
- Exit 0 on success (even partial coverage), 1 on compile/argument error

### `cli/fuzz_cmd.lua`
- `M.run(args)` — compile + random-walk the choice tree + check `verify-always` invariants after every step
- Flags: `--runs N` (default 1000), `--steps N` (default 50), `--seed N` (base seed, default `os.time()`), `--failures-dir D` (default `failures`), `--max-failures N` (default 10), `--format json`
- Per run: fresh engine seeded with `base_seed + run_i`, random driver using Park-Miller LCG, step loop up to max_steps
- On violation: saves the engine log to `<failures-dir>/run{i}_seed{N}.sbd` (replayable with `storybase run --load`)
- Collects `verify-always` clauses from all `verify` blocks in `game_table.verifies[*].clauses`
- Exit 0 if no violations found, 1 if any violation or compile/argument error

### `cli/verify_cmd.lua` (~160 lines)
- `M.run(args)` — compile + per-block cache lookup via `cli/verify_cache.lua` + `verify_mod.run_all` (one-block sub-game-table per uncached entry) + pretty-print
- Flags: `--no-cache` (skip lookup), `--clear-cache` (delete file first), `--cache-dir DIR` (default `.storybase-cache`)
- Output marks cached entries with `[cached]` and reports `(N cached)` in the summary line

### `cli/verify_cache.lua` (~250 lines, §C4)
Persistent cache for verify-block results.
- `M.compute_hash(verify_entry, game_table)` → hex string — FNV-1a 64-bit of (verify-block AST + schema slice + transitively-reached fns + (for BFS verifies) scenes/actors/schedules/bounded)
- `M.load(cache_dir?)` → `{version, entries}` — tolerates missing/malformed/old-version files
- `M.save(cache, cache_dir?)` → `(ok, err?)` — creates dir if missing
- `M.get(cache, hash)` → entry | nil
- `M.put(cache, hash, result)` — strips non-serialisable fields before storing
- AST serialiser skips `pos`/`file`/`line`/`col` so cosmetic edits don't invalidate
- Cache file format: `.storybase-cache/verify.json` (JSON via `runtime.debug.encode_json`)

### `cli/migrate_cmd.lua` (141 lines)
- `M.run(args)` — load save file, run migrations, write output

### `cli/extract_cmd.lua` (220 lines)
- `M.run(args)` — walk typed AST (via `parse_and_check_file`), collect SYMBOL_LIT nodes grouped by SET_MUT target path, output candidate `type Name = val | val` declarations

### `cli/docs_cmd.lua` (§B5)
- `M.run(args)` — compile via `compiler.parse_and_check_file`, group typed AST decls by kind, and emit a static reference site
- `M.build_pages(typed_ast, filename, format, out_name?)` → `{pages = {[file] = contents}, groups = {...}}` — pure renderer, exposed for tests
- HTML mode (default): 14 pages (`index.html` + one per declaration kind) plus `style.css`; sidebar nav with per-kind counts; scene-graph listing on `scenes.html`
- Markdown mode (`--format md`): single `docs.md` file with sections for each kind
- Flags: `-o`/`--output <path>` (output dir for HTML, output file for md), `--format html|md`
- Macros are recovered via a supplementary lexer+parser pass on the raw source since `expand_macros` strips MACRO_DECL nodes before `parse_and_check_file` returns
- Reuses doc strings (§18.4) and the `fmt_type` / `fmt_expr` patterns from `cli/format_cmd.lua` (lifted locally — not exported there)

### `cli/bundle_cmd.lua` (395 lines)
- `M.run(args)` — compile a .sb file and emit a single self-contained Lua file
- Embeds 14 runtime modules as `package.preload` entries (compiler excluded)
- `serialize(val)` — recursive Lua-value-to-source-literal serialiser (handles NaN/±Inf, cycles detection, sequence vs map tables)
- `BUNDLE_MODULES` list controls which modules are embedded (in dependency order)
- Bundle includes a `BUNDLED_ASSETS` table + `asset_load()` helper as extension point for future asset embedding
- Bundled game accepts: `--seed N`, `--save <path>`, `--load <path>` at runtime
- Flags: `--output <path>` (default: same dir as .sb with .lua extension), `--production`

### `cli/lsp.lua` (509 lines)
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

### `cli/compact_cmd.lua` (146 lines)
- `M.run(args)` — replay save log into fresh state, write compact save with one entry per path
- Usage: `storybase compact <game.sb> <save.log> [--out <out.log>]`

### `cli/serve_api_cmd.lua` (§G2)
- `M.run(args)` — CLI entry: compile + start a stateless HTTP API server on `--port` (default 8080)
- `M.start(game_table, opts)` → server (binds non-blocking listener; reuses `LuaSocket`)
- `M.poll(server)` → integer count — accept + dispatch any pending connections (used by tests)
- `M.stop(server)` — close the listener; outstanding connections close themselves
- `M.serve(game_table, opts)` — blocking loop: `poll` + `socket.sleep(0.01)` until process exit
- HTTP routes: `GET /` (text usage), `GET /schema` (compiled schema summary), `POST /step` (stateless step), `POST /reset` (alias for step with reset:true), `OPTIONS *` (CORS preflight)
- POST /step contract: `{save_log?, choice_index?, seed?, reset?}` → `{scene, narration, choices, state, save_log, done, ended}`
- Save-log serialization is identical to `cli/cli_cmd.lua` but plain Lua tables (no Lua source); flows through `runtime.debug.encode_json` / `decode_json` so the client can hold opaque session state across requests
- Internal helpers exported for tests: `M._save_to_table`, `M._restore_from_table`, `M._handle_step`, `M._schema_summary`
- Distinct from `runtime/debug.lua`'s `--serve` HTTP server (which is stateful, one engine per process, browser UI)

### `cli/cli_cmd.lua` (583 lines)
Single-step scripting mode for `storybase run --cli save.sbd`.
- `M.run(game_table, save_path, opts)` — main entry point; reads `opts.input` as a choice index (or `q`/`quit`/`exit`), executes one step, writes save, emits JSON to `opts.output`
- Save format: `save.sbd` Lua chunk (scene stack, log, state snapshot, checkpoint stack) + `save.sbd.snap` for fast replay
- JSON output: `{type, scene, narration, choices, state, done, saved}` for state; `{type="quit"}`, `{type="done"}`, `{type="error", message}`
- `opts.reset = true` — restart from initial state; `opts.seed` — RNG seed

---

## lib/

### `lib/storybase.lua` (574 lines)
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
| `tests/runtime/actors_goal_spec.lua` | §H1 goal-directed actors: parser/checker/codegen plumbing; `runtime/actor_search.lua` unit pieces (hash, clone, enumerate, cartesian, family-live-keys); E2E 6-room maze planning; idle + no-progress hook; goal-flip via precondition chain (pick-up-key → escape); priority conflict between two H1 actors; plan cache hit (post-step hash); `search-depth` bound; SymbolOf(family) action arg enumeration (24 tests) |
| `tests/runtime/search_spec.lua` | can_reach, find_path, probability, optimal_path; time-budget; temporal (EF/AF/AU) verifiers |
| `tests/runtime/verify_spec.lua` | verify block runner (always/after/requires/counterexample, plus eventually/always-eventually/until) |
| `tests/runtime/log_spec.lua` | Log append, query, serialise/deserialise, query_at |
| `tests/runtime/query_spec.lua` | Relation queries |
| `tests/runtime/counterfactual_spec.lua` | Counterfactual branching |
| `tests/runtime/debug_spec.lua` | TCP server, clamp-event, JSON codec; hot reload schema migration; spawn/despawn events |
| `tests/runtime/debug_http_spec.lua` | HTTP/SSE transport: lifecycle, GET /, POST /command, get-scene/do-choice, SSE events (23 tests) |
| `tests/runtime/debug_demo19_spec.lua` | Debug feature integration tests using demo19 (signal tower): get-state, get-log, time-travel, watch-when, mutation events, clamp-event, hot reload, get-schema (26 tests) |
| `tests/runtime/diff_replay_spec.lua` | H2 diff-mode hot reload: choice logging, core replay, 50-tick acceptance, random-draw replay, get-replay-diff debug command (12 tests) |
| `tests/runtime/migrate_spec.lua` | Migration runner unit tests (all op kinds, chain ordering) |
| `tests/runtime/migrate_demo14_spec.lua` | Integration test for demo14's full 1→4 migration chain |
| `tests/runtime/demo33_spec.lua` | Integration tests for demo33 (J-I2 showcase): compiles cleanly; initial counter scene exposes 25 choices (4×4 standard + 8 premium + 1 fever-compress); selecting 'Give tonic to bethe' propagates both iter bindings into `treat p r` and marks bethe treated; moonpetal depletion flips the if/else branch; treating all four patients surfaces 'Close up shop' via the outer `when` gate (7 tests) |
| `tests/runtime/demo34_spec.lua` | Integration tests for demo34 (H1 showcase): compiles cleanly with actor goal/actions wiring; engine-config npc-speed: 3 is honoured; thief reaches gate with crown via Wait choices; precondition staging (pocket-crown before escape); closing stair door fires no-progress hook; hand-written `verify-eventually world/won` passes (6 tests) |
| `tests/runtime/fn_param_types_spec.lua` | J-I1 typed fn parameters: `SymbolOf(F)` annotation silences WRITE_UNTYPED_VAR; alias-resolved types also work; plain `Symbol` and untyped params still warn; mixed bare + typed isolates the warning to the untyped var; end-to-end runtime case where one `cast-spell s: SymbolOf(spells)` fn drives a J-I2 for-loop of choices (6 tests) |
| `tests/runtime/tilegrid_spec.lua` | Tile grid algorithms: storage, within_range, visible_from, find_path, occupied_by (83 tests) |
| `tests/cli/extract_symbols_spec.lua` | extract-symbols CLI command |
| `tests/cli/compact_spec.lua` | compact CLI command |
| `tests/cli/bundle_spec.lua` | bundle CLI command: output validity, execution, --production, save/load, error cases (20 tests) |
| `tests/cli/cli_integration_spec.lua` | Full CLI integration tests: all subcommands (check/compile/run/format/repl/verify/migrate) against all test*.sb + demo*.sb files; also import alias, exports:, source-context error output tests |
| `tests/cli/lsp_spec.lua` | LSP server unit tests: build_syms (types/states/fns/actors/docs), word_at (word extraction, paths, hyphens), make_lsp_diags (severity, positions), integration with real parse+check (43 tests) |
| `tests/cli/cli_cmd_spec.lua` | `--cli` single-step mode: fresh start, state persistence, reset, quit, error handling, game completion, checkpoint+undo (demo08), state fields, subprocess integration (35 tests) |
| `tests/cli/serve_api_spec.lua` | §G2 `storybase serve-api`: handle_step kernel (fresh start, choice advance, JSON round-trip determinism, invalid choice, malformed body), HTTP lifecycle (start/stop), GET / and /schema, OPTIONS preflight, POST /step and /reset end-to-end (22 tests) |
| `tests/cli/drivers_spec.lua` | UI drivers: plain render/prompt/notify, ansi color escapes, --ui driver injection via engine.new (18 tests) |
| `tests/runtime/scheduler_spec.lua` | Scheduler unit tests: every:/at:/offset: triggers, cancel, deregister, multi-axis at:/every:, cancel-during-tick, end-to-end pipeline (22 tests) |
| `tests/runtime/generate_spec.lua` | §F1 generate at runtime: body runs during eng:init, seed_path reseeds RNG, declaration-order execution, spawn! populates families, save/load determinism via state.replay (6 tests) |
| `tests/runtime/ending_spec.lua` | §F2 ending at runtime: check_ending nil/first-match, _render_ending narration, eng:step termination (post-action + pre-prompt), auto-verify pass/fail round-trip via verify.run_all (9 tests) |
| `tests/compiler/types_spec.lua` | compiler/types.lua state_space_size + state_space_log2 arithmetic (bool/int/enum/symbol/option/set/list/record/variant; log-sum-exp; > 2^53 inputs) (43 tests) |
| `tests/compiler/test_decl_spec.lua` | TEST_DECL parser (label forms, sections, multiple blocks, 'test' as ident); codegen (game_table.tests, production strip) (14 tests) |
| `tests/compiler/generate_spec.lua` | §F1 `generate` decl: parser (with/without seed_path, error paths), codegen (game_table.generates entry, duplicate-name diag), checker (UNDEFINED_PATH / UNDEFINED_FN propagate into body) (8 tests) |
| `tests/compiler/ending_spec.lua` | §F2 `ending` decl: parser (with/without when:), codegen (game_table.endings, auto-emit reachability + pairwise exclusivity verify, production strip), duplicate-name diag (9 tests) |
| `tests/compiler/macro_decl_spec.lua` | §E0 decl-macro substrate, all stages (Stage 1 lexer + parser into `DECL_MACRO_DECL`; Stage 2 lexer `$param` / composite identifiers; Stage 2b/3 parser name-interpolation + expansion pass; Stage 4 `expanded_from` diag decoration; Stage 5 cross-import + `@stdlib/` resolver; Stage 6 acceptance + single-pass restriction); plus §E3 type-name + int-bound substitution (Stage A: `Set($T, $n)`, `Int($lo, $hi)`, default-slot `= $max`, literal-into-expression context) (69 tests) |
| `tests/compiler/quest_spec.lua` | §E1 `quest` decl: parser (description/prereq/step/requires/reward shape), desugar (state paths emitted, helper fns emitted, metadata in game_table.quests, duplicate quest + duplicate step diags), auto-verify (label, clause shape, production strip), runtime (start! / do-N / query fns / reward fires when all steps complete) (15 tests) |
| `tests/stdlib/inventory_spec.lua` | §E3 `@stdlib/inventory`: compile (state shape, 7 emitted fns, two-instance non-collision), runtime (start empty, give/take/has?/full? round-trip, clear!), error paths (multi-segment $name, non-int $max) (9 tests) |
| `tests/stdlib/stat_spec.lua` | §E3 `@stdlib/stat`: compile (Int state shape with default=$max, 8 emitted fns), runtime (start at $max, heal/hurt clamping, restore/deplete/set jumps), error paths (multi-segment $name, non-int $min) (8 tests) |
| `tests/stdlib/dialog_spec.lua` | §E2 `@stdlib/dialog`: compile (Bool state shape with default=false, 4 emitted fns), non-collision across two topics per owner and across two owners with the same topic, runtime mark!/reset! flag round-trip and helper tracking, scene with choice guards bound to the emitted helpers compiles, error paths (multi-segment $owner, multi-segment $topic, wrong arity) (11 tests) |
| `tests/runtime/tests_spec.lua` | runtime/tests.lua: basic pass/fail, setup/run sections, multiple expects, fresh-state isolation, multiple tests (19 tests) |
| `tests/cli/test_cmd_spec.lua` | `storybase test` subcommand: usage errors, pass/fail exit codes, no-tests, compile errors (7 tests) |
| `tests/compiler/compiler_spec.lua` | Pipeline orchestrator: stop-on-error, parse_and_check, compile_file file errors, opts.production, import resolver error paths (16 tests) |
| `tests/cli/check_cmd_spec.lua` | `storybase check` subcommand unit tests: clean / missing / syntax / semantic / multi-error paths (6 tests) |
| `tests/cli/config_cmd_spec.lua` | `storybase config` subcommand (dump/get/doc) plus the global `--config key=value` plumbing routed through `cli.main`: dump headers + runtime/game layers, get value/unset/unknown/missing-arg, doc full render + unknown key, bare usage + unknown subcommand, --config cli-layer win + single-token form + malformed/unknown/coercion-failure reporting + trailing --config (18 tests) |
| `tests/cli/repl_cmd_spec.lua` | `storybase repl` subcommand unit tests via mocked stdio: meta-commands, fn invocation, save/load round-trip (16 tests) |
| `tests/cli/migrate_cmd_spec.lua` | `storybase migrate` subcommand unit tests: usage, compile fail, no-migrations, version match, success, --out, corrupt save, missing save (11 tests) |
| `tests/cli/verify_cmd_spec.lua` | `storybase verify` subcommand unit tests: usage, compile fail, no verify blocks, PASS, FAIL, summary (7 tests) |
| `tests/cli/verify_cache_spec.lua` | §C4 verify cache: hash determinism, AST/dep-closure granularity, cache I/O, end-to-end `--no-cache` / `--clear-cache` (15 tests) |
| `tests/cli/coverage_spec.lua` | `storybase coverage` subcommand: argument errors, 100% coverage, unreachable scene detection, uncovered fn detection, JSON format, --depth flag (17 tests) |
| `tests/cli/docs_spec.lua` | `storybase docs` subcommand: HTML page emission per kind, Markdown emission, sidebar/current-page marking, HTML escaping, demo round-trips, macro recovery (21 tests) |
| `tests/cli/fuzz_spec.lua` | `storybase fuzz` subcommand: argument errors, no-verify mode, passing invariants, failing invariants, .sbd save files, JSON format, --runs/--steps/--seed flags, main dispatcher (26 tests) |
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
| `examples/demo31_host.lua` | §I6 embedded-host walkthrough. Pairs with `demos/demo31_embedded_host.sb`. Subscribes via `game:on(<emit-event>, …)` to all six `engine/emit` kinds the game declares (`door-opened`, `signal-sent`, `ship-spotted`, `ship-saved`, `storm-began`, `night-ended`), drives the scene loop with `game:render` + `game:pick`, mixes in direct `game:call` mutations and a `game:tick` to fire the scheduler, and round-trips state through `game:save` + fresh `sb.load` + `game:load`. Acceptance: every emit kind lands in a handler at least once before the script exits; speaker attribution (display + color) prints for both declared speakers. |

Run: `lua5.4 examples/bounded_lua_interop.lua` or `lua5.4 examples/demo31_host.lua`

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
| `demo16_cartographers_web.sb` | advanced find queries: `or-where` (trade hubs = markets ∪ coastal), `connected-to 'capital-city via roads`, `inverse-adjacent? roads 'port-city`; `find` with `order-by + limit + or-where`; `can-reach?` with `strategy: 'depth-first`; `find-path` with `strategy: 'breadth-first`; `counterfactual simulate: true` (route-bonus schedule fires in branch); `relate-both!/unrelate-both!` symmetric road mutations (§J-I5); entity family `cities/{city}: CityRecord` |
| `demo17_scholars_commonplace.sb` | `UList(String)` + `UMap(String, Int)` state; all 15 UList pure builtins (`ulist-size`, `ulist-slice` with negative indices, `ulist-reverse`, `ulist-filter`, `ulist-append`, `ulist-contains?`, `ulist-concat`, etc.); all UMap builtins (`map-get`, `map-size`, `map-keys`, `map-contains-key?`, `map-merge`); `push!/pop!` + `map-set!/map-delete!` mutations; `for...else:` in scene body with `{var}` interpolation |
| `demo18_bakers_queue.sb` | `UList(String)` order queue; `path[n]` INDEX_EXPR on state path; `path[a:b]` SLICE_EXPR with literal bounds; `fn window s e: path[s:e]` SLICE_EXPR with variable bounds (NAMED_ARG lexer fix); `for...else:` in scene body (else branch fires when list empty); `push!/pop!/clear!` mutations |
| `demo19_signal_tower.sb` | debug server showcase: 10× `watch` (live path values in browser), 5× `watch-when` (positive-edge conditional alerts), `engine-config debug-port`, `verify-always` invariants (beacon/visibility safety enforced by BFS, 448 states), `after (fn): @before` postcondition verify; storm-extinguishes-beacon game logic; serves as the subject for `debug_demo19_spec.lua` |
| `demo20_harrow_house.sb` | time-model (`period` axis, wrap: 8), actor + schedule driving NPC spawn/despawn, static + dynamic relations (house-exits room graph, room-items), `bounded` computation (dialog-intent classifier with `??` fallback), `Set(KnowledgeFlag)` accumulation driving phase transitions, `hook after:` for room-discovery flags, `verify` invariants (phase monotone, rapport bounds, ending prereqs); three-phase arc (prosaic → uneasy → revelation) |
| `demo21_merchants_reckoning.sb` | `query-history path` (full ledger via `for` loop), `query-changes path last-n: N` (last 3 locations), `query-at path time: {axis: val}` (gold at named day via `fn gold-on-day d:`), wildcard `query-history player/*` (broad audit); `time-model` single `day` axis, `time-inc! day: 1`; `for…else:` over query results in scene bodies; multi-segment path access `{entry/time/day}` in loop narration; `verify-always`, `after (earn-gold 30)` post-condition verify |
| `demo22_quest_temporal.sb` | Temporal-logic verify showcase (§C3): all four CTL operators on a forced-completion three-task quest — `verify-always` (AG safety), `verify-eventually` (EF reachability), `verify-always-eventually` (AF forced outcome), `verify-until p until q` (AU "p holds until q"). Pairs with `cli/verify_cache.lua` to demonstrate `[cached]` re-runs. |
| `demo23_procedural_dungeon.sb` | §F1 + §F2: a procedurally-generated 3–5 room dungeon. `generate dungeon-layout seed: world/seed` spawns rooms via `random-int`; two `ending` declarations (`escape`, `lost`) drive the auto-emitted reachability + pairwise-exclusivity verify blocks. |
| `demo24_lost_relic.sb` | §E1 `quest` declaration: prereq + three steps (one bare, two with `requires:`) + reward; demonstrates desugar (state paths and helper fns emitted by `compiler.expand_quests`) and the auto-emitted `verify-eventually (quest-lost-relic-complete?)`. Five-choice forward path so verify passes under the default CTL depth. |
| `demo25_dungeon_loot.sb` | §E3 stdlib showcase: `import "@stdlib/inventory"` + `import "@stdlib/stat"` instantiated as `inventory player-bag LootKind 3` and `stat player-health 0 10`. Three-item loot loop with quaff-potion healing and an unlock gated on `player-bag-full?`; `verify-eventually (player-bag-full?)` proves the loop is winnable under bounded BFS. |
| `demo26_bestiary.sb` | §I1 record-mixin + path-pattern showcase: `Entity`/`Combatant: with Entity`/`Mount: with Entity`/`Warbeast: with Combatant + with Mount` (two-parent mixin) plus species records `Wolf`/`Bear`/`Drake`; three `watch` declarations exercising all path-pattern forms (`bestiary/*/alert` wildcard, `bestiary/(wolves\|bears)/hp` alternation, `bestiary/!drake/morale` negation); `query-history bestiary/**/status` recursive wildcard surfaced in narration and used inside a `verify from-any-state` safety net. |
| `demo27_grimoire.sb` | §I2 user-authored `decl-macro` showcase: a file-local `decl-macro spell $name $cost $power $max` that expands into two state paths, six helper fns, and one `verify-eventually` per call site. Exercises `$param` substitution in composite single-segment names, the `Int(0, $max)` integer-bound slot, and whole-expression literal substitution (`dec! player/mana $cost`, `spell-$name-uses < $max`). Three single-line `spell` calls (`fireball`, `mend`, `ward`) materialise three full spell subsystems; `storybase verify` proves each spell is reachable from the initial state. |
| `demo28_seers_chamber.sb` | §I3 counterfactual rewind + conditioned-on bounded showcase. `time-model: axes: [tick]` plus `time-inc! tick: 1` give the log real per-turn ticks; the vision-bowl scene previews a no-rewind control alongside `counterfactual from: (world/turn - 3) do: …` and `counterfactual from: … simulate: true do: …` so the three branches visibly diverge in `world/wisdom`. A `bounded omen-of-season` declaration uses `distribution: conditioned-on world/season` (parser fix for single-token `conditioned-on` bundled with the demo). Verify ships 3/3 PASS. |
| `demo29_caravan_dispatch.sb` | §I4 computed-goto + imperative-scene-nav showcase. A single dispatcher scene `leg-arrival: -> (caravan/at)` routes the caravan through five `Stop`-typed stops (`type Stop = depot \| riverbend \| midmoor \| pass-watch \| highmarket`). Errands push/pop the scene stack via both syntactic forms: `=> inspect-cargo` / `<-` from scene bodies, and `enter-scene! \`water-refill` / `exit-scene!` from fn bodies (`pump-water-errand` / `finish-errand`). A `shortcut-to-highmarket` fn uses `goto-scene! \`highmarket` as the imperative equivalent of `-> highmarket`. Bundled language wiring: parser `MUTATION_TABLE` entries for the three bang forms; eval handlers for `GOTO_SCENE_MUT` / `ENTER_SCENE_MUT` / `EXIT_SCENE_MUT`; checker's AV-2 undefined-scene pass extended to the bang forms; `runtime/verify.lua` and `runtime/search.lua` follow unconditional scene-body `nav_signal` as a free transition so `verify-eventually` chases through dispatcher scenes; `lib/storybase.lua` `choose()` settles via the same auto-advance. Verify ships 3/3 PASS. |
| `demo30_quartermaster.sb` | §I5 `changes`-binding + `strict-contracts` showcase. Every gameplay fn carries `tags: [transaction]`; a single `hook transaction: post:` walks the `changes` binding (`for entry in changes: push! audit/ledger (str entry/path " : " entry/old " → " entry/new)`) refilling a `UList(String)` once per tagged call. A second `hook after: spend:` increments an fn-level counter so both hook flavors fire independently for the same call (proven by `audit/transactions-run` vs `audit/spend-hook-fires` in the camp scene). `fn spend amount: post: player/gold = player/gold@before - amount` is the `path@before` flagship; `engine-config: strict-contracts: true` keeps it live under `--production`. Bundled language fixes: `cli/verify_cmd.lua` sub-game-table now carries hooks/tags/relations/grids/speakers/generates/quests/endings (previously dropped, so hook-driven verify blocks silently failed at BFS state 1); `runtime/eval.lua` `str` builtin renders `false`/`true` as `"false"`/`"true"` (previously `false → ""` due to Lua's `v ~= nil and v or ""` idiom). Verify ships 4/4 PASS. |
| `demo31_embedded_host.sb` | §I6 embedded-host showcase (game-side half — pairs with `examples/demo31_host.lua`). A small lighthouse-keeper game shaped so a Lua host can demonstrate every interesting hook on `lib/storybase.lua`. Six `engine/emit` sites in fn bodies, choice bodies, and a schedule body, each with a structured record payload (`door-opened`, `signal-sent`, `ship-spotted`, `ship-saved`, `storm-began`, `night-ended`). Two declared `speaker`s (keeper, captain) drive `say` lines exercising both fn-body and scene-body forms; the host script uses them to demonstrate `item.kind == "say"` dispatch. Minimal `time-model: axes: [day]` so `time-inc! day: 1` in `rest` advances the scheduler clock and lets `game:tick()` fire the `storm-watch` schedule (`at: [day: +1]`). Bundled doc fix: `docs/reference/language.md` §"Narration output format" and `docs/howto/lua_embedding.md` previously documented plain narration as Lua strings, but the engine has always emitted both narration and dialogue as `{kind, text, …}` tables (the contract all `cli/drivers/*` already consume); both docs now match the implementation and tell hosts to dispatch on `item.kind`. Verify ships 2/2 PASS. |
| `demo33_apothecary.sb` | §K1 / §J-I2 showcase: looped + gated + branched choices in a single scene, plus Shape C enum-case iteration. Four `PatientRec`-typed patients (`patients/{p}` family, populated by a `generate stock-counter` block) waiting at the counter; the `counter` scene's outer `for p in (path-list patients)` loop carries three sub-blocks — `for r in Remedy:` (Shape C enum iter — four standard remedies), `when patients/{p}/symptom = \`fever: *` (one extra cool-compress choice gated by symptom), and `if shop/moonpetal > 0: for r in Premium: *` with `else: <narration>` (two premium remedies that consume one `Int(0,10)` moonpetal each, falling back to "Premium remedies need moonpetal" text). Outer `when shop/served >= 4:` adds the closing "Close up shop" choice. Iter bindings `p` and `r` flow into `treat p r` and `premium-treat p r` fn args; the variadic `(str ...)` builtin renders the post-treatment note with the actual bindings (e.g. "Prepared a salve for corwin."). Initial render exposes 25 choices (4×4 standard + 4×2 premium + 1 fever-compress); the per-choice guard `[not patients/{p}/treated]` peels treated patients out of subsequent renders. Verify ships 2/2 PASS on 489 BFS states. |
| `demo34_silent_stair.sb` | §H1 showcase: goal-directed actors only. A mansion heist with a thief (`goal: world/won`, actions `[move-to, pocket-crown, escape]`, depth 12) and a vault-guard (`goal: guard/at = \`study`, action `[guard-step]`) — both with ZERO behavior bodies. The runtime `actor_search` BFS plans the thief's 10-step heist (parlor→hall→stair→landing→vault→pocket→landing→stair→hall→gate→escape) and consumes it across ticks; the precondition chain (pocket-crown only fires in vault; escape requires crown∈inv + at gate) naturally stages the actions. `engine-config: npc-speed: 3` compresses the 10-action plan into ~3 player choices so the default verify depth (5) catches it. The hall↔stair edge is runtime-gated by `stair-door/open`; closing it (player choice) wipes the only path to the vault and the thief idles, surfacing through the `actor-no-progress` debug event. Bundled language fix: `eng:post_action_chain()` (engine method) loops `post_action` `npc-speed` extra times; `runtime/search.lua` (6 sites) and `runtime/verify.lua` (1 site) now use it so reachability mirrors the live step loop. Verify ships 3/3 PASS on 8 BFS states. |
| `demo32_inquisitors_board.sb` | §I7 residue showcase: set ops as load-bearing game logic + labelled `engine/checkpoint!`. Three witness testimony sets (`testimony/marshall`, `testimony/maid`, `testimony/pilgrim`, each `Set(Suspect, 5)`) with deliberate overlap; eleven pure fns built on the set builtins exercise `union` nested (`all-named = union (union a b) c`), `intersect` both pairwise (`marshall-and-maid`, etc.) and triple-nested (`triple-corroborated = intersect (intersect a b) c`), and `difference` in both senses — unique attribution (`unique-to-pilgrim = difference w (union others)`) and the win-driver `outstanding-leads = difference all-named board/exonerated`. `board/exonerated: Set(Suspect, 5) = (set)` covers the empty-set literal as a state initializer. Each destructive move (`exonerate`, `marshall-recants` / `maid-recants`, `maid-new-tip`) opens with `engine/checkpoint! \`<label>` (`before-exonerate`, `before-recant`, `before-new-tip`) so `undo! 1` rewinds exactly that move with semantic context — bare `engine/checkpoint!` is already covered by demo08, this demo focuses on the labelled form. Four verify blocks include two `from-any-state` invariants phrased directly on `difference` (subset check without a subset builtin) and `intersect` (non-overlap of exonerated/outstanding); 4/4 PASS on 430 BFS states. |
| `demo_dialog_smith.sb` | §E2 stdlib showcase: three `dialog-topic` calls (`family-history`, `deliver-ore`, `forge-secret`) drive a small blacksmith conversation, with later topics gated on earlier ones via the emitted `*-asked?` helpers. Per-topic `verify-eventually` blocks prove each topic is reachable to its asked state under bounded BFS (10 states checked). |
| `demo02_merchant_tests.sb` | Test suite for demo02_merchant.sb: 11 test blocks covering buy/sell fns, port bonus, round-trip, and defaults; uses `import`, `setup:`/`run:`/`expect:` sections |

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

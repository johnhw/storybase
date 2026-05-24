# CLI Reference

All commands are invoked as:

```
lua5.4 cli/main.lua <command> [options] [file]
```

If StoryBase is installed on your `PATH` as `storybase`, you may use `storybase` instead.

---

## Commands

### `check`

Run the lexer, parser, and type checker only (no code generation). Faster than `compile`; use for quick error feedback during development.

```
storybase check <file.sb>
```

Diagnostics include source-context lines with a caret pointing to the offending column:

```
path/to/file.sb:12:5: error [UNDEFINED_TYPE]: unknown type 'Weapn'
  state player/weapon: Weapn = 'sword
      ^
```

**Exit codes:** `0` = no errors (warnings allowed), `1` = one or more errors.

---

### `compile`

Compile a `.sb` file and report all errors and warnings. Does not run the game.

```
storybase compile [--production] <file.sb>
```

**Options:**

| Flag | Description |
|------|-------------|
| `--production` | Compile in production mode: strips `verify`, `watch`, and `pre:`/`post:` contract blocks from the output (unless `strict-contracts: true` is set in `engine-config`). |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Compiled successfully (errors = 0) |
| 1 | One or more compile errors |

**Output format:**

Diagnostics are written to stderr:

```
path/to/file.sb:12:5: error [UNDEFINED_TYPE]: unknown type 'Weapn'
path/to/file.sb:7:1: warning [PERCEIVES_VIOLATION]: actor reads player/health which is not in its perceives: list
```

---

### `run`

Compile and run a game interactively in the terminal.

```
storybase run [options] <file.sb>
```

**Options:**

| Flag | Description |
|------|-------------|
| `--production` | Run a production build (see `compile --production`). |
| `--seed N` | Fix the random seed to `N` for reproducible runs. |
| `--save <path>` | Write the transaction log to `<path>` on exit. |
| `--load <path>` | Load a transaction log from `<path>` before starting. Applies any outstanding schema migrations. |
| `--auto` | Non-interactive mode: always pick choice 1. Useful for automated testing. |
| `--steps N` | Limit to `N` turns then exit. Requires `--auto`. |
| `--debug` | Start the TCP debug server (port 7373) and browser UI server (port 7374). Browser panels are read-only; game is driven from stdin. |
| `--serve` | Start the browser UI server (port 7374) only. No stdin loop; the browser drives the game via `do-choice`. Implies `--debug` behaviour except no stdin interaction. |

**Interaction:**

At each scene the engine prints:

1. Narration text.
2. A numbered list of available choices (choices whose guard condition is false are hidden).
3. A `> ` prompt.

Type the choice number and press Enter.

**Save format:**

Save files are newline-delimited JSON (NDJSON), one log entry per line. They are human-readable and diff-friendly. Use `compact` to shrink large save files.

---

### `verify`

Compile the file and run all `verify` blocks, reporting pass/fail for each.

```
storybase verify <file.sb> [--no-cache] [--clear-cache] [--cache-dir DIR]
```

**Output:**

```
PASS  "castle hp stays non-negative"  (checked 47 states)
FAIL  "player always has a way out"
      counterexample: player/location=dungeon, world/gate-open=false
```

**Result cache.** Verify results are cached at `.storybase-cache/verify.json`
keyed by an AST-level hash of each block plus the schema and the fns the
block transitively reaches. Re-runs that hit the cache print `[cached]`
next to the block label and skip the BFS. Editing a fn outside a block's
dependency closure does not invalidate that block.

| Flag | Effect |
|------|--------|
| `--no-cache`       | Skip the cache (always run every block) |
| `--clear-cache`    | Delete the cache file before running |
| `--cache-dir DIR`  | Use `DIR` instead of `.storybase-cache` |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | All verify blocks passed |
| 1 | One or more verify blocks failed |

No `--production` flag — verify blocks are only meaningful in development mode.

---

### `test`

Compile the file and run all `test` blocks. Each block runs from a fresh state initialised to schema defaults: it applies `setup` mutations, executes `run` function calls, then evaluates `expect` boolean expressions and fails on the first false result.

```
storybase test <file.sb>
```

**Output:**

```
Testing mygame.sb (3 block(s))...
  PASS  "fresh game starts with full HP"
  FAIL  "talking to merchant decreases gold"
        expected: player/gold = 90, got 100

1 passed, 2 failed
```

Tests are stripped from production builds (`game_table.tests = {}` when `--production`), so this command is intended for the development loop only.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | All test blocks passed (or no test blocks present) |
| 1 | One or more failed, or compile error |

---

### `fuzz`

Random-walk the choice tree of a game and check every `verify-always` invariant after each step. On violation, the engine log is saved so the failing path can be replayed with `storybase run <file> --load <failure.sbd>`.

```
storybase fuzz [--runs N] [--steps N] [--seed N]
               [--failures-dir D] [--max-failures N]
               [--format json] <file.sb>
```

| Flag | Default | Description |
|------|---------|-------------|
| `--runs N` | `1000` | Number of random-walk runs. |
| `--steps N` | `50` | Max steps per run. |
| `--seed N` | `os.time()` | Base random seed; run `i` uses `seed + i`. |
| `--failures-dir D` | `failures` | Directory for saved failure logs. |
| `--max-failures N` | `10` | Stop saving logs after N failures (the run keeps going). |
| `--format json` | — | Emit a JSON summary instead of human-readable text. |

**Exit codes:** `0` if no invariants violated, `1` if any violation found or on error.

---

### `coverage`

Walk the BFS frontier of a game and report which scenes and functions are reachable within the given search depth. Useful as a smoke check that no scene is orphaned and that every fn is exercised by some reachable path.

```
storybase coverage [--depth N] [--budget N] [--format json] <file.sb>
```

| Flag | Default | Description |
|------|---------|-------------|
| `--depth N` | `8` | BFS depth limit. |
| `--budget N` | `30` | Time budget in seconds. |
| `--format json` | — | Emit a JSON object instead of human-readable text. |

**Exit codes:** `0` on success (even if coverage is incomplete because of the budget), `1` on error.

---

### `migrate`

Apply any outstanding schema migration blocks to a save log file, producing an updated save.

```
storybase migrate <game.sb> <save.log> [--out <output.log>]
```

If `--out` is omitted, the migrated log is printed to stdout.

The command compares the `schema-version` embedded in the save log against the current version declared in the `.sb` file and runs migration blocks in version order.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Migration applied successfully |
| 1 | Compile error, or migration block raised an error |

---

### `extract-symbols`

Scan a `.sb` file for symbol literals used in `set!` / `add!` mutations and suggest `type` declarations.

```
storybase extract-symbols <file.sb>
```

**Example output:**

```
-- Symbols found at player/class:
type Class = warrior | mage | rogue

-- Symbols found at player/status:
type Status = alive | dead | unconscious
```

This is a code-quality tool. Replacing untyped `Symbol` state with a named enum makes state-space bounds precise and eliminates `warn-untyped-symbol` warnings.

---

### `compact`

Replay a save log and emit a compact snapshot — one entry per path — plus any log entries that cannot be represented as a snapshot (random draws, checkpoints). The result is a smaller file that loads faster.

```
storybase compact <game.sb> <save.log> [--out <output.log>]
```

If `--out` is omitted, the compacted log is printed to stdout.

The original log is never modified.

---

### `format`

Parse a `.sb` file and write canonical formatted output.

```
storybase format [--check] [--write] <file.sb>
```

| Flag | Description |
|------|-------------|
| (none) | Write formatted source to stdout. |
| `--check` | Exit 1 if the file is not already formatted; do not modify it. |
| `--write` | Rewrite the file in-place (creates a `.bak` backup). |

Canonical formatting uses 2-space indentation and consistent spacing around operators.

---

### `repl`

Load a `.sb` file and start an interactive expression REPL for live state inspection and debugging.

```
storybase repl <file.sb>
```

Type any pure StoryBase expression to evaluate it. Meta-commands:

| Command | Description |
|---------|-------------|
| `:state <path>` | Print the value at a state path |
| `:scene` | Print the current scene name |
| `:choices` | List available choices |
| `:choose N` | Dispatch choice N |
| `:tick` | Run one autonomous turn |
| `:save` / `:load` | Save or load state |
| `:help` | Show help |
| `:quit` | Exit |

---

### `bundle`

Compile a `.sb` file and emit a self-contained Lua file that runs with a stock `lua5.4` binary (no StoryBase installation needed).

```
storybase bundle [--output <path>] [--production] <file.sb>
```

| Flag | Description |
|------|-------------|
| `--output <path>` | Output path (default: same directory as `.sb` file, with `.lua` extension). |
| `--production` | Compile in production mode before bundling (strips verify/watch blocks). |

The bundled file embeds the full runtime and the compiled game table. At runtime it accepts `--seed N`, `--save <path>`, and `--load <path>`.

---

### `docs`

Walk the typed AST of a `.sb` file and emit a static reference site: one page per declaration kind (types, state, fns, scenes, actors, schedules, bounded, macros, speakers, grids, hooks, verify) plus an overview home page. Doc strings (§18.4) on each declaration are surfaced as prose.

```
storybase docs [-o <path>] [--format html|md] <file.sb>
```

| Flag | Description |
|------|-------------|
| `-o`, `--output <path>` | Output directory (HTML mode) or file (Markdown mode). Defaults: `./docs_out/` for HTML, `./docs.md` for Markdown. |
| `--format html\|md` | Output format. Default is `html`. |

The HTML output includes a sidebar with one entry per declaration kind, a summary card grid, and a static scene-graph listing (each scene's `->` / `=>` targets). Macros — which are stripped by macro-expansion before the typed AST is built — are recovered via a supplementary lex+parse pass so they appear in the docs when present.

**Exit codes:** `0` on success, `1` on compile or argument error.

---

### `serve-api`

Start a stateless HTTP API server that hosts the compiled game. Unlike `run --serve` (which keeps a single session in memory and is browser-driven), every request is independent: clients carry the full save log between calls. Multiple chat-bot, web, or Discord frontends can share a single server process without per-session locking.

```
storybase serve-api [--port N] [--bind addr] [--seed N] [--production] <file.sb>
```

| Flag | Description |
|------|-------------|
| `--port N` | Listen port (default: `8080`). |
| `--bind addr` | Bind address (default: `127.0.0.1`). |
| `--seed N` | Default seed for fresh-start games when the client omits its own seed. |
| `--production` | Compile with `verify` / `watch` stripped before serving. |

**Endpoints**

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/` | Plain-text usage page describing the API. |
| `GET`  | `/schema` | JSON summary of the compiled schema (state paths, scenes, entry scene). |
| `POST` | `/step` | Take one game step; see request/response below. |
| `POST` | `/reset` | Alias for `/step` with `reset: true`. |
| `OPTIONS` | `*` | CORS preflight (Access-Control-Allow-Origin: `*`). |

**`POST /step` request** (JSON):

```json
{
  "save_log":     <opaque object from previous response> | null,
  "choice_index": 1,            // 1-based; omit/null = render only
  "seed":         42,           // honoured only on fresh start
  "reset":        false         // if true, ignore save_log
}
```

**`POST /step` response** (JSON):

```json
{
  "scene":     "village",
  "narration": [ { "kind": "narration", "text": "..." }, ... ],
  "choices":   [ { "index": 1, "label": "Leave the village" }, ... ],
  "state":     { "world/gold": 42, ... },
  "save_log":  { ... },         // opaque; pass back unchanged next call
  "done":      false,
  "ended":     null             // ending name (string) when game finished, else null
}
```

Error responses use HTTP status `400` and the body `{ "error": "..." }`.

**Save-log determinism.** The save log is the same transaction log used by `storybase run --save / --load`, serialised as a plain JSON object. Two requests with the same save log and choice index produce the same next state. Logs grow with session length; if needed, clients can replay them through `storybase compact` offline.

**Auth and TLS.** Out of scope. Place the server behind a reverse proxy (Caddy, nginx) for HTTPS, authentication, and rate limiting in production deployments.

**Exit codes:** `0` if the listener was started and the loop exits cleanly (typically the process is killed externally); `1` if the file fails to compile or the listener cannot bind.

---

### `lsp`

Start the StoryBase Language Server Protocol (LSP) server. Communicates over stdio using JSON-RPC 2.0. Intended to be launched by editor integrations.

```
storybase lsp
```

Supported LSP capabilities:

- **Diagnostics** — published on every `textDocument/didOpen` and `textDocument/didChange`.
- **Hover** — doc string, kind, and parameter list for the symbol under the cursor.
- **Go to definition** — jump to the declaration of a type, function, scene, actor, etc.
- **Completion** — names, state paths, types, and scenes filtered by prefix; trigger characters `/` and `-`.

---

### `config`

Inspect the configuration registry. Values are resolved through the precedence chain `runtime > cli > env > file > game > default`; the command reports both the resolved value and the winning layer.

```
storybase config <subcommand> [args]
```

| Subcommand | Description |
|------------|-------------|
| `dump [file.sb]` | List every declared key with its resolved value and winning layer. If `file.sb` is given, its `engine-config:` block is bound first so the `game` layer is reflected. |
| `get <key> [file.sb]` | Print just the value for `<key>`. |
| `doc <key>` | Show the full spec for `<key>` — type, default, env var, CLI flag, doc, and current resolved value. |

CLI overrides use the global `--config <key>=<value>` flag (repeatable, accepted by any subcommand). They land in the `cli` layer and win over `env` / `file` / `game` / `default`.

**Examples:**

```
storybase config dump
storybase config dump demos/demo01_wanderer.sb
storybase config get engine.scene-stack-max
storybase config doc engine.npc-speed
storybase --config engine.npc-speed=2 run demos/demo01_wanderer.sb
```

---

### `help`

Show usage information.

```
storybase help
storybase help <command>
```

`help <command>` shows detailed options for a specific subcommand.

---

## Diagnostic Format

All diagnostics use the format:

```
<file>:<line>:<col>: <level> [<CODE>]: <message>
  note: <additional context>     (optional)
```

`<level>` is `error` or `warning`. `<CODE>` is an `UPPER_SNAKE_CASE` identifier (e.g. `UNDEFINED_TYPE`, `DUPLICATE_NAME`, `PERCEIVES_VIOLATION`).

**Common error codes:**

| Code | Meaning |
|------|---------|
| `UNDEFINED_TYPE` | Reference to a type name that was not declared |
| `UNDEFINED_NAME` | Reference to an undeclared function, scene, or variable |
| `DUPLICATE_NAME` | Two declarations with the same name |
| `IMPORT_CYCLE` | Circular import between modules |
| `FILE_NOT_FOUND` | `import` target file does not exist |
| `TYPE_MISMATCH` | Value used where a different type is expected |
| `IMPURE_IN_PURE` | Mutation primitive called from a pure context |
| `WRITE_PATH_DYNAMIC` | Dynamic path construction in a write position |
| `SUPERFICIAL_IN_COND` | Superficial type used in a conditional expression |
| `UNSUPPORTED_FEATURE` | Feature not yet implemented (e.g., `import "f" as Alias` — use flat import instead) |

**Common warning codes:**

| Code | Meaning |
|------|---------|
| `PERCEIVES_VIOLATION` | Actor reads a path not listed in its `perceives:` block |
| `IMPURE_IN_PURE` | (warning variant) Function inferred as impure but used in pure context |
| `UNTYPED_SYMBOL` | `Symbol` used where a typed `SymbolOf(Family)` would give better bounds |

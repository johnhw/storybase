# CLI Reference

All commands are invoked as:

```
lua5.4 cli/main.lua <command> [options] [file]
```

If StoryBase is installed on your `PATH` as `storybase`, you may use `storybase` instead.

---

## Commands

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
storybase verify <file.sb>
```

**Output:**

```
PASS  "castle hp stays non-negative"  (checked 47 states)
FAIL  "player always has a way out"
      counterexample: player/location=dungeon, world/gate-open=false
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | All verify blocks passed |
| 1 | One or more verify blocks failed |

No `--production` flag — verify blocks are only meaningful in development mode.

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

`<level>` is `error` or `warning`. `<CODE>` is an `UPPER_SNAKE_CASE` identifier (e.g. `UNDEFINED_TYPE`, `DUPLICATE_DECL`, `PERCEIVES_VIOLATION`).

**Common error codes:**

| Code | Meaning |
|------|---------|
| `UNDEFINED_TYPE` | Reference to a type name that was not declared |
| `DUPLICATE_DECL` | Two declarations with the same name |
| `IMPORT_CYCLE` | Circular import between modules |
| `FILE_NOT_FOUND` | `import` target file does not exist |
| `TYPE_MISMATCH` | Value used where a different type is expected |
| `IMPURE_IN_PURE` | Mutation primitive called from a pure context |
| `WRITE_PATH_DYNAMIC` | Dynamic path construction in a write position |

**Common warning codes:**

| Code | Meaning |
|------|---------|
| `PERCEIVES_VIOLATION` | Actor reads a path not listed in its `perceives:` block |
| `IMPURE_IN_PURE` | (warning variant) Function inferred as impure but used in pure context |
| `UNTYPED_SYMBOL` | `Symbol` used where a typed `SymbolOf(Family)` would give better bounds |

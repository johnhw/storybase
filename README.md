# StoryBase

**WARNING: This is an experimental project exploring vibecoded development. All code is authored by Claude! This is not intended for production use. It's a learning exercise and a sandbox for trying out new ideas.**

**StoryBase** is a domain-specific language for authoring adventure and RPG games. It gives you:

- A **typed, discrete-state engine** that is fully searchable and verifiable.
- A **transaction log** as the single source of truth — automatic save/load, full replay, time-travel debugging.
- **Bounded future-state search** — ask "can the player die in the next ten turns?" and get an exact answer.
- **Structured actors and messaging** — NPC behavior functions with perception filtering, typed inbox messages, and deferred-write conflict resolution.
- **First-class debugging** — TCP JSON debug server, embedded browser UI, watch expressions, hot reload, and counterfactual traces.
- **Language tooling** — LSP server (hover, go-to-definition, completion, diagnostics), formatter, REPL, and standalone bundler.

---

## Requirements

- **Lua 5.4** (`lua5.4`)
- **Busted** test framework (`busted`)
- **LPeg** parsing library (`lpeg`)
- **LuaSocket** (`luasocket`) — required for the debug server

Install on Debian/Ubuntu:

```bash
sudo apt install lua5.4 lua-busted lua-lpeg lua-socket
```

---

## Quick Start

### 1. Write a game

Create `hello.sb`:

```
module hello
  version: 1.0

engine-config:
  entry-scene: start

state world:
  visited: Int(0, 9) = 0

scene start:
  You stand at the crossroads. The wind stirs the dust.
  You have visited {world/visited} place(s).
  * Head north into the forest.
    inc! world/visited 1
    -> forest
  * Head south toward the village.
    inc! world/visited 1
    -> village

scene forest:
  Tall pines close around you. The air smells of pine needles.
  You have visited {world/visited} place(s).
  * Return to the crossroads.
    -> start

scene village:
  Smoke curls from cottage chimneys. Children play in the square.
  You have visited {world/visited} place(s).
  * Return to the crossroads.
    -> start
```

### 2. Run it

```bash
lua5.4 cli/main.lua run hello.sb
```

You will see:

```
You stand at the crossroads. The wind stirs the dust.
You have visited 0 place(s).
1) Head north into the forest.
2) Head south toward the village.
> 1

Tall pines close around you. The air smells of pine needles.
You have visited 1 place(s).
1) Return to the crossroads.
>
```

### 3. Check for errors

```bash
lua5.4 cli/main.lua compile hello.sb
```

### 4. Run the built-in demos

```bash
lua5.4 cli/main.lua run demos/demo01_wanderer.sb   # minimal scenes
lua5.4 cli/main.lua run demos/demo02_merchant.sb   # types, guards, match
lua5.4 cli/main.lua run demos/demo03_quest.sb      # Bool flags, fn, pre:
lua5.4 cli/main.lua run demos/demo04_expedition.sb # entity families
lua5.4 cli/main.lua run demos/demo05_siege.sb      # actors, schedules, verify
lua5.4 cli/main.lua run demos/demo06_buried_keep.sb  # records, grids, migrations
lua5.4 cli/main.lua run demos/demo07_oracle.sb     # import, bounded, counterfactual
```

---

## Key Concepts

| Concept | What it is |
|---------|-----------|
| **Scenes** | Interactive screens with narration text and player choices. Choices can be guarded with conditions. |
| **State** | Typed, bounded variables. Only *discrete* types (Bool, Int, enum, Set, …) may drive game logic. |
| **Transaction log** | Every mutation is recorded. Current state is always a projection of the log. |
| **Actors** | NPC/environment agents with behavior functions, perception filtering, and typed message inboxes. |
| **Schedules** | Time-triggered events that fire at declared intervals. |
| **Verify** | Exhaustive assertions over all reachable future states. |
| **Search builtins** | `can-reach?`, `find-path`, `probability`, `optimal-path` — query the game's reachable futures. |

---

## CLI Reference

```
lua5.4 cli/main.lua <command> [options] <file>

Commands:
  check   <file>               Fast syntax + type check (no codegen)
  compile <file>               Compile; report errors and warnings
  run     <file>               Compile and run interactively
  format  <file>               Format source (--check / --write flags)
  repl    <file>               Interactive expression REPL
  verify  <file>               Run all verify blocks
  bundle  <file>               Bundle into a self-contained Lua file
  lsp                          Start LSP server (for editor integration)
  migrate <save.log>           Apply schema migrations to a save file
  extract-symbols <file>       Suggest type declarations from symbol usage
  compact <game.sb> <save.log> Compact a save log into a snapshot
  help [<command>]             Show help

Options (run):
  --production                 Strip debug-only content (verify, watch, pre:/post:)
  --seed N                     Fix random seed
  --save <path>                Save game log on exit
  --load <path>                Load game log before start
  --auto                       Non-interactive: always pick choice 1
  --steps N                    Limit to N turns  (requires --auto)
  --debug                      TCP debug server (port 7373) + browser UI (port 7374)
  --serve                      Browser-driven mode: open http://localhost:7374
```

---

## Documentation

Full documentation lives in `docs/`:

| Path | Contents |
|------|----------|
| `docs/tutorial/` | Step-by-step tutorials — start here |
| `docs/howto/` | Short recipes for common tasks |
| `docs/reference/` | Exhaustive language, CLI, and API specifications |
| `docs/explanation/` | Architecture and design background |

### Tutorials

1. [`docs/tutorial/01_hello_world.md`](docs/tutorial/01_hello_world.md) — Minimal interactive fiction
2. [`docs/tutorial/02_state_and_choices.md`](docs/tutorial/02_state_and_choices.md) — Guarded choices and branching narrative
3. [`docs/tutorial/03_functions_and_actors.md`](docs/tutorial/03_functions_and_actors.md) — Functions and NPC actors
4. [`docs/tutorial/04_search_and_verify.md`](docs/tutorial/04_search_and_verify.md) — Testing your game mechanically
5. [`docs/tutorial/05_tile_grids.md`](docs/tutorial/05_tile_grids.md) — Tactical tile-grid games

### Reference

- [`docs/reference/language.md`](docs/reference/language.md) — Complete syntax reference
- [`docs/reference/builtins.md`](docs/reference/builtins.md) — Every built-in function
- [`docs/reference/cli.md`](docs/reference/cli.md) — CLI subcommands and flags
- [`docs/reference/lua_api.md`](docs/reference/lua_api.md) — Lua embedding API
- [`docs/reference/tile_grid.md`](docs/reference/tile_grid.md) — Tile grid extension

---

## Running Tests

```bash
busted tests/                          # all unit/integration tests (~1634)
busted tests/cli/cli_integration_spec.lua   # CLI integration tests (~77)
```

---

## Project Layout

```
cli/            Command-line interface
compiler/       Lexer, parser, type checker, code generator
runtime/        Engine, state, evaluator, actors, scheduler, search, debug
lib/            Public Lua embedding API (lib/storybase.lua)
demos/          Example games
tests/          Test suite
docs/           Documentation
```

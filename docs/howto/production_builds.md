# How to Build for Production

A production build strips debug-only content from the compiled game, reducing binary size and eliminating development overhead in shipped games.

---

## What Is Stripped

| Content | Stripped in production |
|---------|----------------------|
| `verify` blocks | Yes |
| `watch` / `watch-when` declarations | Yes |
| `pre:` / `post:` contract blocks | Yes (unless `strict-contracts: true`) |
| `macro` declarations | Retained (inlined at compile time) |
| Migration blocks | Retained (needed for save compatibility) |
| Debug server | Does not start (no TCP socket) |
| `fn-call` events | Not emitted |

---

## Compiling for Production

### CLI

```bash
lua5.4 cli/main.lua compile --production mygame.sb
```

Reports errors and warnings, but does not run the game. Use this in CI to verify the production build compiles cleanly.

### Running in production mode

```bash
lua5.4 cli/main.lua run --production mygame.sb
```

The game runs without verify, watches, or contracts.

### Lua API

```lua
local compiler = require("compiler.compiler")
local gt, diags = compiler.compile_file("mygame.sb", { production = true })
```

---

## Keeping Contracts in Production

If you want `pre:` / `post:` checks to run in production (for critical safety invariants), set `strict-contracts: true` in `engine-config`:

```
engine-config:
  entry-scene:      start
  strict-contracts: true
```

With this setting, `pre:` and `post:` blocks are retained even in production builds. `verify` and `watch` blocks are still stripped.

---

## What Changes at Runtime

**Without `--production`:**
- `verify-always` runs exhaustive BFS searches.
- `watch-when` conditions are checked after every mutation.
- `pre:` / `post:` contracts are evaluated.
- Debug server listens on the configured port.
- `fn-call` events are broadcast to debug clients.
- `clamp-event`, `spawn-event`, `despawn-event` events fire.

**With `--production`:**
- None of the above.
- Mutations are logged and state changes correctly, but no verification, watching, or debugging.
- `Int` saturation still clamps silently.

---

## Production Build Checklist

1. Run `storybase verify mygame.sb` — all verify blocks pass.
2. Run `storybase compile --production mygame.sb` — no errors.
3. Run `storybase run --production --auto --steps 100 mygame.sb` — game starts and runs without crashing.
4. Test save/load compatibility if you updated `schema-version`.

# How to Connect the Debug Server

The StoryBase debug server exposes a TCP JSON (NDJSON) interface for live state inspection, time-travel, watch events, and hot reload. It is designed for tooling — editor plugins, GUI debuggers, or custom scripts.

---

## Starting the Server

The debug server starts when the engine is run in development mode (not `--production`). The default port is **7777**. Override in `engine-config`:

```
engine-config:
  entry-scene: start
  debug-port:  7373
```

Run the game normally:

```bash
lua5.4 cli/main.lua run mygame.sb
```

The server listens on `localhost:<port>`. Connect any TCP client to interact.

---

## Protocol

All messages are **NDJSON** — one JSON object per line, terminated by `\n`.

**Client → server:** send a command object:

```json
{"cmd": "get-state"}
{"cmd": "eval", "expr": "player/health"}
{"cmd": "time-travel", "seq": 42}
{"cmd": "undo"}
{"cmd": "reload", "source": "...full .sb source..."}
{"cmd": "set-breakpoint", "path": "player/health", "condition": "< 10"}
{"cmd": "clear-breakpoint", "path": "player/health"}
{"cmd": "get-log"}
```

**Server → client:** events are sent automatically as they fire:

```json
{"event": "mutation", "seq": 15, "path": "player/health", "old": 100, "new": 85, "fn": "take-damage"}
{"event": "scene-change", "scene": "combat", "from": "village"}
{"event": "watch-fired", "label": "player died", "path": "player/health", "value": 0}
{"event": "clamp-event", "path": "player/health", "attempted": -5, "clamped": 0, "fn": "take-damage"}
{"event": "spawn-event", "family": "npcs", "key": "goblin"}
{"event": "despawn-event", "family": "npcs", "key": "goblin"}
{"event": "schedule-fired", "name": "morning-reset"}
{"event": "fn-call", "fn": "take-damage", "args": [10]}
{"event": "reload", "ok": true}
```

---

## Commands Reference

### `get-state`

Returns a snapshot of all current state paths and their values.

```json
{"cmd": "get-state"}
```

Response:

```json
{"event": "state", "state": {"player/health": 85, "player/gold": 30, ...}}
```

---

### `eval`

Evaluate a pure StoryBase expression and return the result.

```json
{"cmd": "eval", "expr": "player/health + 10"}
```

Response:

```json
{"event": "eval-result", "result": 95}
```

---

### `get-log`

Return all transaction log entries.

```json
{"cmd": "get-log"}
```

Response:

```json
{"event": "log", "entries": [...]}
```

---

### `time-travel`

Restore state to the point just after log entry `seq`. This reconstructs state by replaying the log up to that sequence number.

```json
{"cmd": "time-travel", "seq": 20}
```

Response:

```json
{"event": "time-travel-ok", "seq": 20}
```

---

### `undo`

Revert to the most recent checkpoint (function tagged `checkpoint`).

```json
{"cmd": "undo"}
```

---

### `set-breakpoint` / `clear-breakpoint`

Set a watch that pauses execution (in future tooling; currently fires a `watch-fired` event) when the condition at a path is met.

```json
{"cmd": "set-breakpoint", "path": "player/health", "condition": "< 10"}
{"cmd": "clear-breakpoint", "path": "player/health"}
```

---

### `reload`

Hot-reload the game source. The server validates the new schema against the current state, applies field additions/removals atomically, and emits a `reload` event.

```json
{"cmd": "reload", "source": "module game\n  version: 2.0\n..."}
```

**Hot reload rules:**

- New scalar/record fields: initialised with the declared default.
- New family fields: all existing instances get the default.
- Removed fields: silently dropped from current state.
- Int range narrowed: error if the current value is out of the new range.
- Enum value removed: error if the current value is no longer valid.
- All validation runs before any change is applied (atomic).

Response on success:

```json
{"event": "reload", "ok": true}
```

Response on failure:

```json
{"event": "reload", "ok": false, "error": "player/health value 150 out of new range [0, 100]"}
```

---

## Events Reference

| Event | When fired | Key fields |
|-------|-----------|-----------|
| `mutation` | After every state mutation | `seq`, `path`, `old`, `new`, `fn`, `op` |
| `scene-change` | After every scene transition | `scene`, `from` |
| `watch-fired` | When a `watch-when` condition becomes true | `label`, `path`, `value` |
| `clamp-event` | When `inc!`/`dec!` clamps to Int range | `path`, `attempted`, `clamped`, `fn` |
| `spawn-event` | After `spawn!` | `family`, `key` |
| `despawn-event` | After `despawn!` | `family`, `key` |
| `message-sent` | After `send!` | `actor`, `msg` |
| `schedule-fired` | When a schedule fires | `name`, `time` |
| `fn-call` | On every function call (dev mode) | `fn`, `args` |
| `reload` | After a `reload` command | `ok`, `error?` |

---

## Watch Declarations

`watch` and `watch-when` are declared in the `.sb` source file:

```
watch player/health "health changed"
watch-when player/health <= 0 "player died"
watch-when player/location = 'shrine "reached the shrine"
```

These are registered at startup. When the condition becomes true (positive edge for `watch-when`, any non-nil value for `watch`), a `watch-fired` event is broadcast to all connected clients.

---

## Quick Test with `nc`

You can test the debug server with `netcat`:

```bash
# Terminal 1: start the game
lua5.4 cli/main.lua run mygame.sb

# Terminal 2: connect and query state
nc localhost 7777
{"cmd":"get-state"}
```

Each JSON command must be on one line followed by `\n`.

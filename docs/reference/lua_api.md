# Lua API Reference

`lib/storybase.lua` provides a public API for embedding StoryBase in a Lua host program.

```lua
local sb = require("lib.storybase")
```

---

## Loading a Game

### `sb.load(filepath)`

Compile a `.sb` file from disk and return a game object.

```lua
local game, err = sb.load("games/adventure.sb")
if not game then error(err) end
```

**Returns:** `game, nil` on success; `nil, err_string` on failure.

---

### `sb.from_source(source, filename?)`

Compile StoryBase source text and return a game object.

```lua
local source = [[
  module demo
    version: 1.0
  engine-config:
    entry-scene: start
  scene start:
    Hello world.
    * Continue -> start
]]
local game, err = sb.from_source(source, "demo.sb")
```

**Parameters:**
- `source` — StoryBase source text (string).
- `filename` — optional name used in error messages (default `"inline"`).

**Returns:** `game, nil` on success; `nil, err_string` on failure.

---

## Game Object

All methods below are called on the object returned by `sb.load` or `sb.from_source`.

---

### Lifecycle

#### `game:init()`

Initialise the game from declared defaults and set the entry scene. Must be called once before any other method. Safe to call again to reset to initial state.

```lua
game:init()
```

---

#### `game:reset()`

Alias for `game:init()`. Resets to initial state.

---

### Presentation

#### `game:render()`

Render the current scene, returning narration and choices.

```lua
local narration, choices = game:render()

for _, line in ipairs(narration) do
  if type(line) == "table" then
    -- Attributed dialogue from a `say` statement
    local label = line.display or line.speaker or "?"
    print(label .. ": " .. line.text)
  else
    -- Plain narration string
    print(line)
  end
end
for _, choice in ipairs(choices) do
  print(choice.index .. ") " .. choice.label)
end
```

**Returns:** `narration_list, choices_list`

- `narration_list` — ordered list of items. Each item is either:
  - A **string** — a plain rendered narration line (with `{expr}` interpolation applied).
  - A **table** — a dialogue object emitted by a `say` statement, with fields:
    - `speaker` (string or nil) — raw speaker key
    - `display` (string or nil) — human-readable name from the `speaker` declaration
    - `color` (string or nil) — CSS hex color from the `speaker` declaration
    - `text` (string) — rendered dialogue text
- `choices_list` — list of tables, each with `index` (1-based integer) and `label` (string). Only choices whose guard condition is true are included.

---

#### `game:current_scene()`

Return the name of the top-of-stack scene as a string.

```lua
local scene = game:current_scene()   -- e.g. "village"
```

---

### Player Input

#### `game:choose(index)`

Dispatch player choice `index` (1-based, matching the indices returned by `game:render()`). Runs the choice body, applies navigation, then runs all post-action phases (actor behaviors, scheduler).

```lua
local ok = game:choose(1)
-- ok = true on success, false if index is out of range
```

**Returns:** `true` on success, `false` if index is out of range.

---

### State Access

#### `game:get(path)`

Read a state path value.

```lua
local hp     = game:get("player/health")   -- → integer
local status = game:get("player/status")   -- → string, e.g. "alive"
local flag   = game:get("world/gate-open") -- → boolean
```

**Returns:** the value at `path`, or `nil` if the path has no value (unspawned entity, etc.).

---

#### `game:set(path, value)`

Write a state path value directly, bypassing the transaction log. Use `game:call()` for logged mutations.

```lua
game:set("player/health", 50)
game:set("world/gate-open", true)
```

---

### Calling Functions

#### `game:call(fn_name, ...)`

Call a named transaction or pure function with Lua arguments. Arguments are converted to StoryBase AST literals.

```lua
game:call("heal", 30)
game:call("move-to", "'forest")   -- symbol: prefix with '
game:call("spawn-npc", "'goblin", 10)
local dmg = game:call("base-damage")
```

**Argument conversion:**

| Lua type | StoryBase type |
|----------|----------------|
| `integer` | `Int` literal |
| `float` | `Float` literal |
| `boolean` | `Bool` literal |
| `string` starting with `'` | Symbol literal (strips the `'`) |
| other `string` | `String` literal |

**Returns:** the function's return value, or `nil`.

**Raises:** an error if the function throws a runtime error.

---

### Entity Family Queries

#### `game:find(family, opts?)`

Query an entity family, returning matching keys.

```lua
local keys = game:find("npcs")
local hostile = game:find("npcs", {
  where = function(key)
    return game:get("npcs/" .. key .. "/disposition") == "hostile"
  end,
  order_by  = "npcs/{key}/health",
  order_dir = "asc",
  limit     = 5,
})
local count = game:find("crew", { count = true })
```

**Options table:**

| Key | Type | Description |
|-----|------|-------------|
| `where` | `function(key) → bool` | Lua predicate; only keys where it returns true are included |
| `order_by` | `string` | Path template with `{key}` placeholder; sort by value at this path |
| `order_dir` | `"asc"` \| `"desc"` | Sort direction (default `"asc"`) |
| `limit` | `integer` | Maximum number of results |
| `count` | `boolean` | Return an integer count instead of a list |

**Returns:** list of key strings (or integer when `count = true`).

---

### Expression Evaluation

#### `game:eval(expr_string)`

Evaluate a StoryBase expression string in the current state. Only pure expressions are supported.

```lua
local val, err = game:eval("player/health + 10")
local reachable, err = game:eval("can-reach? player/status = 'dead")
```

**Returns:** `value, nil` on success; `nil, err_string` on failure.

---

### Counterfactual Branches

#### `game:counterfactual(fn)`

Create a forked copy of the current game state, apply mutations via the callback, and return a frozen read-only snapshot. The live game state is not modified.

```lua
local snapshot = game:counterfactual(function(branch)
  branch:call("heal", 50)
  branch:call("move-to", "'castle")
end)

local hypothetical_hp = snapshot:get("player/health")
local hypothetical_scene = snapshot:current_scene()
```

**Parameter:** `fn(branch)` — a function receiving a branch game object. Mutations applied to `branch` do not affect the main game.

**Returns:** a frozen snapshot table with:
- `snapshot:get(path)` — read a state path from the branched state.
- `snapshot:current_scene()` — the scene name after the branch's mutations.

---

### Bounded Computations

#### `game:register_bounded(name, fn)`

Register a Lua handler for a `bounded` computation declared in the game source.

```lua
game:register_bounded("classify-intent", function(text, state_snapshot)
  -- text: the argument passed to the bounded call
  -- state_snapshot: read-only table of declared "reads:" paths
  if text:find("attack") then return "hostile" end
  return "neutral"
end)
```

The handler receives the argument(s) passed to the bounded call plus a read-only state snapshot containing the paths declared in the `bounded`'s `reads:` block. It must return a value of the `returns:` type.

---

### Documentation

#### `game:docs(name?)`

Return doc strings from the compiled game table.

```lua
-- All entities with doc strings
local all_docs = game:docs()
-- { ["heal"] = "Restore player health.", ["player"] = "Player state.", ... }

-- Single entity lookup
local doc = game:docs("heal")   -- → "Restore player health." or nil
```

Doc strings are string literals placed immediately before a declaration in the `.sb` source:

```
"Restore player health."
fn heal amount:
  inc! player/health amount
```

`game:docs()` collects doc strings from: `fn`, `scene`, `actor`, `schedule`, `bounded`, and `state`/`type` declarations.

---

### Event Subscriptions

#### `game:on(event_name, handler)`

Subscribe to a named event.

```lua
game:on("choice", function(payload)
  print("Player chose " .. payload.index .. " in scene " .. payload.scene)
end)

game:on("mutation", function(payload)
  print("Changed " .. payload.path .. " → " .. tostring(payload.new))
end)

game:on("scene-change", function(payload)
  print("Moved to scene: " .. payload.scene)
end)
```

**Built-in event names:**

| Event | Payload fields | When fired |
|-------|---------------|------------|
| `"choice"` | `index`, `scene` | After each `game:choose()` call |
| `"mutation"` | `path`, `old`, `new`, `fn` | After each state mutation |
| `"scene-change"` | `scene`, `from` | After each scene transition |

**Custom events** fired by `engine/emit` in the StoryBase source are also delivered here:

```lua
-- In mygame.sb:
--   engine/emit "level-up" player/level
game:on("level-up", function(payload)
  print("Level up! Now level " .. tostring(payload))
end)
```

---

### Autonomous Turns

#### `game:tick()`

Advance one autonomous turn: runs actor behaviors, applies deferred mutations, and fires scheduled events. No player input is consumed.

```lua
game:tick()    -- NPC step only
```

---

### Save and Load

#### `game:save(filepath)`

Save the current transaction log to a file.

```lua
local ok, err = game:save("saves/slot1.log")
if not ok then print("Save failed: " .. err) end
```

**Returns:** `true, nil` on success; `false, err_string` on failure.

The save file is a Lua script with the serialised log and scene stack. It is compatible with `storybase run --load`.

---

#### `game:load(filepath)`

Load a previously saved transaction log. Replays the log from scratch and applies any outstanding schema migrations.

```lua
local ok, err = game:load("saves/slot1.log")
```

**Returns:** `true, nil` on success; `false, err_string` on failure.

---

## Complete Example

```lua
local sb = require("lib.storybase")

-- Load and initialise
local game, err = sb.load("demos/demo03_quest.sb")
if not game then error(err) end
game:init()

-- Event listener
game:on("mutation", function(e)
  io.write(string.format("[%s] %s -> %s\n", e.path, tostring(e.old), tostring(e.new)))
end)

-- Play loop
while true do
  local narr, choices = game:render()
  for _, line in ipairs(narr)    do print(line) end
  for _, c    in ipairs(choices) do print(c.index .. ") " .. c.label) end

  if #choices == 0 then break end

  io.write("> ")
  local n = tonumber(io.read())
  if n then game:choose(n) end
end
```

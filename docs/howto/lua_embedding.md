# How to Embed StoryBase in a Lua Host

Use `lib/storybase.lua` to embed StoryBase in a Lua application — a web server, a game engine, a test harness, or any Lua program.

---

## Basic Usage

```lua
local sb = require("lib.storybase")

-- Load and initialise
local game, err = sb.load("games/adventure.sb")
if not game then error(err) end
game:init()

-- Render the first scene
local narration, choices = game:render()
for _, item in ipairs(narration) do
  if item.kind == "say" then
    print((item.display or item.speaker or "?") .. ": " .. item.text)
  else
    print(item.text)
  end
end
for _, choice in ipairs(choices) do print(choice.index .. ") " .. choice.label) end

-- Dispatch a choice
game:choose(1)
```

---

## The Game Loop

```lua
local sb   = require("lib.storybase")
local game = sb.load("games/adventure.sb")
game:init()

while true do
  local narration, choices = game:render()

  -- Display narration (each item is a table: {kind="narration"|"say", text=..., ...})
  for _, item in ipairs(narration) do
    if item.kind == "say" then
      print((item.display or item.speaker or "?") .. ": " .. item.text)
    else
      print(item.text)
    end
  end

  -- Check for end of game (no choices available)
  if #choices == 0 then
    print("-- Game over --")
    break
  end

  -- Display choices
  for _, c in ipairs(choices) do
    print(c.index .. ") " .. c.label)
  end

  -- Get player input
  io.write("> ")
  local n = tonumber(io.read("*l"))
  if n and n >= 1 and n <= #choices then
    game:choose(n)
  end
end
```

---

## Reading and Writing State

```lua
-- Read any state path
local hp   = game:get("player/health")    -- integer
local stat = game:get("player/status")    -- string, e.g. "alive"
local flag = game:get("world/gate-open")  -- boolean

-- Write directly (bypasses transaction log — use game:call() for logged changes)
game:set("player/health", 100)
```

---

## Calling Named Functions

```lua
-- Call a transaction function
game:call("heal", 30)
game:call("move-to", "'forest")   -- symbols: prefix with '
game:call("buy-item", "'sword", 40)

-- Call a pure function and use the return value
local dmg = game:call("base-damage")
print("Base damage:", dmg)
```

String arguments starting with `'` are treated as symbol literals.

---

## Subscribing to Events

```lua
-- Called every time a state mutation occurs
game:on("mutation", function(e)
  print(string.format("[mut] %s: %s → %s (fn: %s)",
    e.path, tostring(e.old), tostring(e.new), e.fn))
end)

-- Called after each game:choose()
game:on("choice", function(e)
  print("Chose " .. e.index .. " in " .. e.scene)
end)

-- Called after each scene transition
game:on("scene-change", function(e)
  print("Scene: " .. (e.from or "?") .. " → " .. e.scene)
end)
```

---

## Querying Entity Families

```lua
-- All live crew members
local crew = game:find("crew")

-- Crew members with HP > 0
local alive = game:find("crew", {
  where = function(key)
    return (game:get("crew/" .. key .. "/hp") or 0) > 0
  end,
})

-- Sort by health, take top 3
local weakest = game:find("npcs", {
  where     = function(k) return game:get("npcs/" .. k .. "/active") end,
  order_by  = "npcs/{key}/health",
  order_dir = "asc",
  limit     = 3,
})

-- Count
local n = game:find("crew", { count = true })
print("Crew alive: " .. n)
```

---

## Counterfactual Branches

Test "what if" scenarios without affecting the live game:

```lua
-- What would health be if we healed 50?
local snap = game:counterfactual(function(branch)
  branch:call("heal", 50)
end)
print("After heal: " .. snap:get("player/health"))
print("Live health unchanged: " .. game:get("player/health"))

-- Multi-step hypothesis
local snap2 = game:counterfactual(function(branch)
  branch:call("move-to", "'dungeon")
  branch:call("fight-enemy")
  branch:tick()   -- run one autonomous turn
end)
print("Hypothetical scene: " .. snap2:current_scene())
```

---

## Save and Load

```lua
-- Save to file
local ok, err = game:save("saves/slot1.log")
if not ok then error("Save failed: " .. err) end

-- Load from file (applies migrations automatically)
local ok, err = game:load("saves/slot1.log")
if not ok then error("Load failed: " .. err) end
```

---

## Evaluating Expressions

```lua
-- Evaluate any pure StoryBase expression
local val, err = game:eval("player/health + 10")
local alive    = game:eval("player/status = 'alive")
local reachable = game:eval("can-reach? quest-complete?  depth: 20")
```

---

## Registering Bounded Computations

```lua
-- Register a Lua handler for a bounded computation declared in the game:
-- bounded classify-intent text: returns: Intent distribution: uniform reads: [] lua: "..."
game:register_bounded("classify-intent", function(text, state_snapshot)
  if text:find("attack") then return "hostile" end
  if text:find("trade")  then return "friendly" end
  return "neutral"
end)
```

---

## Autonomous Turns

Run one turn of NPC/schedule activity without player input:

```lua
game:tick()    -- actors behave, schedules fire
```

---

## Complete Integration Example

```lua
local sb = require("lib.storybase")

local function run_game(path)
  local game, err = sb.load(path)
  if not game then error(err) end

  -- Wire events for logging
  game:on("scene-change", function(e)
    io.write(string.format("\n[→ %s]\n", e.scene))
  end)

  game:init()

  while true do
    local narr, choices = game:render()
    for _, line in ipairs(narr) do print(line) end

    if #choices == 0 then break end
    for _, c in ipairs(choices) do print(c.index .. ") " .. c.label) end

    io.write("> ")
    local n = tonumber(io.read("*l"))
    if n then game:choose(n) end
  end
end

run_game("demos/demo02_merchant.sb")
```

---

## API Quick Reference

| Method | Description |
|--------|-------------|
| `sb.load(path)` | Load from file |
| `sb.from_source(src, name?)` | Load from string |
| `game:init()` | Initialise / reset |
| `game:render()` | → narration list, choices list |
| `game:current_scene()` | → scene name |
| `game:choose(n)` | Dispatch choice n |
| `game:get(path)` | Read state path |
| `game:set(path, val)` | Write state path (unlogged) |
| `game:call(fn, ...)` | Call named function |
| `game:find(family, opts?)` | Query entity family |
| `game:eval(expr)` | Evaluate expression string |
| `game:counterfactual(fn)` | Forked state branch |
| `game:register_bounded(name, fn)` | Register bounded handler |
| `game:on(event, handler)` | Subscribe to event (built-in + custom `engine/emit` events) |
| `game:docs(name?)` | Doc strings for all entities (or one by name) |
| `game:tick()` | Autonomous turn |
| `game:save(path)` | Save to file |
| `game:load(path)` | Load from file |

Full documentation: [`docs/reference/lua_api.md`](../reference/lua_api.md).

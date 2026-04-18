# How to Use Bounded Computations

Bounded computations let you call arbitrary Lua code from StoryBase and treat the result as a discrete value. The search engine branches over all possible return values, so the game remains fully analysable.

Use bounded computations for:
- Natural language intent classification
- AI-driven tactical decisions
- ML model outputs
- Any external logic that produces a discrete result

---

## Declaring a Bounded Computation

In your `.sb` file:

```
bounded classify-intent text:
  returns:      Intent
  distribution: uniform
  reads:        []
  lua:          "classify"
```

| Field | Required | Description |
|-------|----------|-------------|
| `returns:` | Yes | The discrete return type (`Intent` must be a declared enum or alias). |
| `distribution:` | Yes | How the search engine branches: `uniform` (all return values equally likely) or `conditioned-on <path>` (use the current value of `path` as a prior). |
| `reads:` | Yes | Path patterns the Lua handler may read. Included in perception snapshots. |
| `lua:` | Yes | Lua identifier passed to `game:register_bounded`. |

---

## Declaring the Return Type

```
type Intent = attack | trade | flee | idle
```

The return type must be a discrete enum or alias.

---

## Registering the Handler in Lua

```lua
local sb   = require("lib.storybase")
local game = sb.load("mygame.sb")

game:register_bounded("classify", function(text, state_snapshot)
  -- text:           the argument passed to the bounded call in StoryBase
  -- state_snapshot: read-only table with the paths declared in reads:
  if text:find("attack") then return "attack" end
  if text:find("buy")    then return "trade"  end
  if text:find("run")    then return "flee"   end
  return "idle"
end)

game:init()
```

The handler receives:
1. The argument(s) passed to the bounded call.
2. A read-only Lua table containing the path values declared in `reads:`.

It must return a string matching one of the `returns:` type's valid values.

---

## Calling from StoryBase

Call a bounded computation like any other function:

```
fn process-input text:
  let intent = (classify-intent text):
    match intent:
      'attack: enter-combat-mode
      'trade:  open-shop
      'flee:   set! player/location 'exit
      'idle:   pass
```

Or in a guard:

```
* [classify-intent player/last-input = 'attack] Pursue the player
  initiate-pursuit
  -> encounter
```

---

## How Search Treats Bounded Computations

During exhaustive search (`can-reach?`, `verify-always`, etc.), the engine **branches over all possible return values** of `classify-intent`. With `distribution: uniform`, all return values (`attack`, `trade`, `flee`, `idle`) are explored with equal weight.

This means your `verify-always` checks hold even if the bounded computation returns any possible value — the game is analysable regardless of external Lua logic.

With `conditioned-on player/disposition`, the distribution is weighted by the current value of `player/disposition`. The search still branches over all values, but probabilities reflect the conditioning.

---

## Example: AI Tactical Assessment

```
type TacticalDecision = advance | hold | retreat | flank

bounded tactical-move npc:
  returns:      TacticalDecision
  distribution: conditioned-on npcs/{npc}/disposition
  reads:        [npcs/{npc}/hp, player/hp, player/location]
  lua:          "ai_decide"

fn npc-turn npc:
  let decision = (tactical-move npc):
    match decision:
      'advance: move-toward-player npc
      'hold:    defend-position npc
      'retreat: flee-from-player npc
      'flank:   flank-player npc
```

In Lua:

```lua
game:register_bounded("ai_decide", function(npc_key, snap)
  local my_hp     = snap["npcs/" .. npc_key .. "/hp"] or 0
  local player_hp = snap["player/hp"] or 100

  if my_hp < 20 then return "retreat" end
  if my_hp > player_hp then return "advance" end
  return "hold"
end)
```

---

## Tips

- Keep `reads:` accurate — only list paths the handler actually reads. Overly broad `reads:` degrades perception-snapshot filtering for actors.
- Bounded computations that always return the same value are fine but unnecessary — just use a pure function instead.
- The `lua:` name is matched against the name passed to `game:register_bounded`. It is not a Lua module path; it is just a string key.
- If no handler is registered at runtime, the bounded call returns `nil`. Use `??` to provide a default:

  ```
  let weather = (oracle-weather ?? 'clear):
    ...
  ```

  This makes bounded computations safe to use even when no Lua handler is wired up (e.g. in CLI / non-embedded runs).

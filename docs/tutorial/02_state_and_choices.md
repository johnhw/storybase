# Tutorial 2: State and Choices

Expand your game with typed enums, guarded choices that appear or disappear based on state, and conditional narration.

By the end of this tutorial you will understand:
- Enum types and symbol literals
- Multiple state paths
- Guarded choices `[condition]`
- Conditional narration with `when` and `if/else`
- `inc!`, `dec!`, and `set!` mutations

---

## Prerequisites

Complete [Tutorial 1](01_hello_world.md) first.

---

## Step 1 — Enums and Symbol Literals

An enum type declares a fixed set of named values:

```
type Status = alive | dead | resting

state player:
  status: Status = 'alive
```

Values are **symbol literals**: they are written with a leading `'`. Enums are *discrete* — the compiler knows there are exactly 3 possible values, which enables bounded future-state search.

Let's build a simple resource-management game:

```
module resources
  version: 1.0

engine-config:
  entry-scene: camp

type Weather = clear | rain | storm

state player:
  energy: Int(0, 100) = 50
  food:   Int(0, 50)  = 20

state world:
  weather: Weather = 'clear
  day:     Int(0, 30) = 1

scene camp:
  Day {world/day}. Energy {player/energy}. Food {player/food}.
  Weather: {world/weather}.

  * Rest (gain 20 energy, costs 3 food)
    inc! player/energy 20
    dec! player/food 3
    -> camp

  * Forage (gain 8 food, uses 10 energy)
    inc! player/food 8
    dec! player/energy 10
    -> camp

  * Advance to next day
    inc! world/day 1
    -> camp
```

Try running this. Notice how `Int` state saturates: you can rest even with full energy (it just wastes food), and energy can't go below 0.

---

## Step 2 — Guarded Choices

A choice guard `[condition]` hides the choice when the condition is false:

```
scene camp:
  Day {world/day}. Energy {player/energy}. Food {player/food}.
  Weather: {world/weather}.

  * [player/energy >= 10] Forage (gain 8 food, uses 10 energy)
    inc! player/food 8
    dec! player/energy 10
    -> camp

  * [player/food >= 3] Rest (gain 20 energy, costs 3 food)
    inc! player/energy 20
    dec! player/food 3
    -> camp

  * Advance to next day
    inc! world/day 1
    -> camp
```

Now "Forage" disappears when energy drops below 10, and "Rest" disappears when food drops below 3. Guards can reference any discrete state path or pure function.

---

## Step 3 — Conditional Narration

Use `when` for conditional narrative lines in a scene body:

```
scene camp:
  Day {world/day}. Energy {player/energy}. Food {player/food}.

  when world/weather = 'storm:
    A fierce storm batters the camp. Foraging is impossible.

  when player/energy < 20:
    You are exhausted and can barely stand.

  when player/food <= 5:
    Your food supply is dangerously low.

  * [player/energy >= 10 and world/weather != 'storm] Forage
    inc! player/food 8
    dec! player/energy 10
    -> camp

  * [player/food >= 3] Rest
    inc! player/energy 20
    dec! player/food 3
    -> camp

  * Advance to next day
    inc! world/day 1
    -> camp
```

`when` blocks are narration-only — they don't create choices. Use them to show contextual text.

You can also use `if/else`:

```
  if player/energy >= 50:
    You feel strong and capable.
  else:
    Fatigue weighs on your limbs.
```

---

## Step 4 — Match Expressions

`match` lets you branch on an enum value:

```
scene camp:
  Day {world/day}.
  The sky is
  match world/weather:
    'clear: clear and blue.
    'rain:  grey and drizzling.
    'storm: dark and threatening.
```

Match works in narration (as above), in function bodies, and in expressions:

```
fn weather-penalty:
  match world/weather:
    'storm: 20
    'rain:  10
    _:       0       # _ is the wildcard / default branch
```

---

## Step 5 — Putting It Together

Here's a more complete example with guarded weather-sensitive choices:

```
module resources
  version: 1.0

engine-config:
  entry-scene: camp

type Weather = clear | rain | storm

state player:
  energy: Int(0, 100) = 50
  food:   Int(0, 50)  = 20

state world:
  weather: Weather = 'clear
  day:     Int(0, 30) = 1

fn forage-yield:
  match world/weather:
    'clear: 10
    'rain:  5
    'storm: 0

scene camp:
  Day {world/day}. Energy {player/energy}. Food {player/food}.

  when world/weather = 'clear:
    Blue skies overhead.
  when world/weather = 'rain:
    Cold rain patters on the tent.
  when world/weather = 'storm:
    A fierce storm makes leaving camp dangerous.

  when player/energy < 20:
    You are exhausted.
  when player/food <= 5:
    Food is running dangerously low.

  * [player/energy >= 10 and world/weather != 'storm] Forage
    inc! player/food (forage-yield)
    dec! player/energy 10
    -> camp

  * [player/food >= 3] Rest
    inc! player/energy 20
    dec! player/food 3
    -> camp

  * Change weather (for testing)
    set! world/weather
      match world/weather:
        'clear: 'rain
        'rain:  'storm
        'storm: 'clear
    -> camp

  * Advance to next day
    inc! world/day 1
    dec! player/food 2
    -> camp
```

---

## Key Points

| Concept | Syntax |
|---------|--------|
| Enum type | `type Status = alive \| dead` |
| Symbol literal | `'alive` |
| Guarded choice | `* [condition] Choice text` |
| Conditional narration | `when condition:` / `if ... else:` |
| Match | `match value: 'a: ... 'b: ... _: ...` |
| Saturation arithmetic | `inc!` / `dec!` clamp to declared `Int(min, max)` range |

---

## Next Steps

**[Tutorial 3: Functions and Actors](03_functions_and_actors.md)** — extract reusable logic into named functions and add an NPC with autonomous behavior.

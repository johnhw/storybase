# Tutorial 5: Tile Grids

Build a tactical mini-game on a 2D tile map. You will use line-of-sight, range checks, A* pathfinding, and entity position tracking.

By the end of this tutorial you will understand:
- `defgrid` declaration
- `grid-get` / `grid-set!`
- `within-range?` for range checks
- `visible-from?` for line-of-sight
- `path-to` for movement pathfinding
- `occupied-by` for entity collision

---

## Prerequisites

Complete [Tutorial 4](04_search_and_verify.md) first.

---

## Step 1 — Declare a Grid

Add a `defgrid` declaration alongside your types and state:

```
type TileKind = floor | wall | door | exit

defgrid dungeon:
  dimensions: Int(0, 10) x Int(0, 10)
  cell-type:  TileKind
```

This declares a 10×10 grid named `dungeon` where each cell holds a `TileKind` value.

- Coordinates are **0-based**: x ∈ [0, 9], y ∈ [0, 9].
- Origin `(0, 0)` is the top-left corner.
- All cells start at the first enum variant (`'floor` here).

---

## Step 2 — Player and Enemy State

The player and enemy positions are just ordinary `Int` state paths:

```
state player:
  x: Int(0, 9) = 1
  y: Int(0, 9) = 1
  hp: Int(0, 100) = 100

state enemy:
  x: Int(0, 9) = 8
  y: Int(0, 9) = 8
  hp: Int(0, 100) = 80
  active: Bool = true
```

---

## Step 3 — Grid Initialisation

Initialise the grid in a setup function. Call it from the entry scene:

```
fn init-dungeon:
  # The grid starts all-floor, so just add walls
  # North wall
  for x in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]:
    grid-set! dungeon x 0 'wall
  # South wall
  for x in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]:
    grid-set! dungeon x 9 'wall
  # West wall
  for y in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]:
    grid-set! dungeon 0 y 'wall
  # East wall
  for y in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]:
    grid-set! dungeon 9 y 'wall
  # Interior obstacle
  grid-set! dungeon 4 4 'wall
  grid-set! dungeon 4 5 'wall
  grid-set! dungeon 5 4 'wall
  # Exit
  grid-set! dungeon 9 5 'exit
```

---

## Step 4 — Movement

Use `path-to` to compute a valid path to a destination and take the first step:

```
fn step-toward tx ty:
  pre: player/hp > 0
  let route = (path-to dungeon player/x player/y tx ty  blocked: {'wall}):
    when route != nil:
      let step = route[0]:
        set! player/x step/x
        set! player/y step/y
```

`path-to` returns nil if no path exists (blocked by walls). Taking the first element of the returned list moves one cell toward the target.

---

## Step 5 — Line of Sight

Check whether the player can see the enemy:

```
fn can-see-enemy?:
  visible-from? dungeon player/x player/y enemy/x enemy/y  solid: {'wall}
```

Use it in conditional narration:

```
scene dungeon-room:
  You are at ({player/x}, {player/y}). HP: {player/hp}.

  [can-see-enemy?]
    You can see the enemy at ({enemy/x}, {enemy/y})!
  [not can-see-enemy? and enemy/active]
    The enemy is lurking somewhere in the dungeon.
```

---

## Step 6 — Range Check

Check whether the enemy is close enough to attack:

```
fn in-attack-range?:
  within-range? dungeon player/x player/y enemy/x enemy/y  range: 1

fn attack-enemy:
  pre: in-attack-range?
  pre: enemy/active
  dec! enemy/hp (random-int 10 20)
  when enemy/hp <= 0:
    set! enemy/active false
```

`within-range?` with the default Chebyshev metric covers the 8 adjacent cells (radius 1).

---

## Step 7 — Entity Collision

Use `occupied-by` to check if a cell is occupied before moving there:

```
fn move-to-cell tx ty:
  pre: grid-get dungeon tx ty != 'wall
  pre: occupied-by dungeon units tx ty = nil
  set! player/x tx
  set! player/y ty
```

`occupied-by dungeon units tx ty` scans the `units` family for any member whose `units/KEY/x == tx` and `units/KEY/y == ty`.

---

## Step 8 — Complete Example

```
module dungeon-crawl
  version: 1.0

engine-config:
  entry-scene: intro

type TileKind = floor | wall | exit

defgrid dungeon:
  dimensions: Int(0, 10) x Int(0, 10)
  cell-type:  TileKind

state player:
  x:  Int(0, 9) = 1
  y:  Int(0, 9) = 1
  hp: Int(0, 100) = 100

state enemy:
  x:      Int(0, 9) = 7
  y:      Int(0, 9) = 7
  hp:     Int(0, 100) = 60
  active: Bool = true

fn init-dungeon:
  # Outer walls
  grid-set! dungeon 0 0 'wall  grid-set! dungeon 1 0 'wall
  grid-set! dungeon 2 0 'wall  grid-set! dungeon 3 0 'wall
  grid-set! dungeon 4 0 'wall  grid-set! dungeon 5 0 'wall
  grid-set! dungeon 6 0 'wall  grid-set! dungeon 7 0 'wall
  grid-set! dungeon 8 0 'wall  grid-set! dungeon 9 0 'wall
  grid-set! dungeon 0 9 'wall  grid-set! dungeon 9 9 'wall
  grid-set! dungeon 0 1 'wall  grid-set! dungeon 9 1 'wall
  grid-set! dungeon 0 2 'wall  grid-set! dungeon 9 2 'wall
  grid-set! dungeon 0 3 'wall  grid-set! dungeon 9 3 'wall
  grid-set! dungeon 0 4 'wall  grid-set! dungeon 9 4 'wall
  grid-set! dungeon 0 5 'wall  grid-set! dungeon 9 5 'wall
  grid-set! dungeon 0 6 'wall  grid-set! dungeon 9 6 'wall
  grid-set! dungeon 0 7 'wall  grid-set! dungeon 9 7 'wall
  grid-set! dungeon 0 8 'wall  grid-set! dungeon 9 8 'wall
  # Interior pillar
  grid-set! dungeon 4 4 'wall
  grid-set! dungeon 5 4 'wall
  grid-set! dungeon 4 5 'wall
  # Exit
  grid-set! dungeon 9 8 'exit

fn step-toward tx ty:
  let route = (path-to dungeon player/x player/y tx ty  blocked: {'wall}):
    when route != nil:
      let step = route[0]:
        set! player/x step/x
        set! player/y step/y

fn in-attack-range?:
  within-range? dungeon player/x player/y enemy/x enemy/y  range: 1

fn can-see-enemy?:
  visible-from? dungeon player/x player/y enemy/x enemy/y  solid: {'wall}

fn attack-enemy:
  pre: in-attack-range?
  pre: enemy/active
  dec! enemy/hp (random-int 10 20)
  when enemy/hp <= 0:
    set! enemy/active false

fn at-exit?:
  grid-get dungeon player/x player/y = 'exit

scene intro:
  You enter the dungeon.
  * Begin
    init-dungeon
    -> room

scene room:
  Position ({player/x}, {player/y}). HP: {player/hp}.

  when can-see-enemy? and enemy/active:
    The enemy glares at you from ({enemy/x}, {enemy/y})!
  when not can-see-enemy? and enemy/active:
    Something lurks in the shadows.
  when not enemy/active:
    The enemy is defeated.
  when at-exit?:
    You stand at the exit!

  * [in-attack-range? and enemy/active] Attack enemy
    attack-enemy
    -> room

  * Move toward enemy
    step-toward enemy/x enemy/y
    -> room

  * Move toward exit
    step-toward 9 8
    -> room

  * [at-exit? and not enemy/active] Escape!
    -> victory

scene victory:
  You escaped the dungeon!
  HP remaining: {player/hp}.
  Enemy HP: {enemy/hp}.
```

Run it:

```bash
lua5.4 cli/main.lua run dungeon-crawl.sb
```

---

## Key Points

| Concept | Syntax |
|---------|--------|
| Declare grid | `defgrid name: dimensions: W x H  cell-type: T` |
| Read cell | `grid-get name x y` |
| Write cell | `grid-set! name x y value` |
| Grid size | `grid-width name` / `grid-height name` |
| Range check | `within-range? name x1 y1 x2 y2  range: N  metric: "manhattan"` |
| Line of sight | `visible-from? name x1 y1 x2 y2  solid: {values}` |
| Pathfinding | `path-to name x1 y1 x2 y2  blocked: {values}  diag: bool` |
| Collision | `occupied-by name family x y` |

---

## Congratulations

You have completed all five StoryBase tutorials. You now know how to:

1. Build multi-scene interactive fiction with typed state.
2. Use enums, guards, and conditional narration.
3. Extract logic into functions, guard with preconditions, and create autonomous NPCs with actors.
4. Test your game exhaustively with `verify-always` and search builtins.
5. Build tactical games on 2D tile grids.

**Where to go next:**

- [How-to guides](../howto/) — focused recipes for specific tasks.
- [Language reference](../reference/language.md) — complete syntax specification.
- [Built-ins reference](../reference/builtins.md) — every built-in function in detail.
- [Demo games](../../demos/) — five progressively complex example games.

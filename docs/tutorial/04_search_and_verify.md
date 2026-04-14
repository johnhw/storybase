# Tutorial 4: Search and Verify

Use StoryBase's built-in exhaustive search to ask questions about your game's future states — and write `verify` blocks to assert invariants that must hold in every reachable state.

By the end of this tutorial you will understand:
- Why discrete types enable exhaustive search
- `can-reach?` — is a condition achievable?
- `find-path` — what sequence of choices leads there?
- `probability` — how likely is an outcome?
- `verify` blocks with `verify-always`
- `watch` declarations
- Running verification from the CLI

---

## Prerequisites

Complete [Tutorial 3](03_functions_and_actors.md) first.

---

## Step 1 — Why Search Works

StoryBase's type system divides types into *discrete* (finite, bounded) and *superficial* (unbounded, display-only). Because all game logic depends only on discrete types, the set of reachable game states is **finite** — even if large.

The engine can enumerate all reachable states via BFS and answer questions like:
- "Can the player die?"
- "Is it possible to get stuck?"
- "What's the probability of winning in under 10 turns?"

The state-space size is the product of the sizes of all discrete state paths. Smaller enums and tighter `Int` bounds mean faster searches.

---

## Step 2 — `can-reach?`

`can-reach?` is a pure built-in that returns `true` if there exists *any* sequence of player choices (up to a given depth) that leads to a state where the condition holds:

```
can-reach? player/status = 'dead
can-reach? player/location = 'castle  depth: 20
can-reach? quest-complete?
```

Use it in choice guards to hint at reachability, or in `verify` blocks to assert something is impossible.

Example — show a warning if the player can lose from here:

```
scene combat:
  HP: {player/hp}.
  [can-reach? player/hp <= 0  depth: 5]
    Warning: you could die in the next few turns.
  * Attack
    attack-enemy
    -> combat
```

---

## Step 3 — `find-path`

`find-path` returns the shortest sequence of choices that reaches a state where the condition holds, or nil if unreachable:

```
let path = (find-path player/location = 'shrine  depth: 30):
  when path != nil:
    set! player/hint (tostring path)
```

Each element of the returned list is a record with:
- `scene` — scene name
- `label` — choice text
- `index` — 1-based choice index

This is most useful in hints, AI navigation, or debug tools.

---

## Step 4 — `probability`

`probability` estimates the fraction of BFS paths that satisfy a condition, assuming the player picks choices uniformly at random:

```
probability player/status = 'dead  depth: 10
```

Returns a Float between 0 and 1.

This is useful for balancing: if `probability player/won?  depth: 20` returns `0.03`, the game is too hard.

---

## Step 5 — `verify` Blocks

`verify` blocks are the primary tool for automated game testing. They run when you call `storybase verify <file>`.

```
verify "player health never goes negative":
  verify-always player/health >= 0
```

`verify-always <condition>` does an exhaustive BFS and checks that `condition` holds in every reachable state. If it finds a violating state, it reports the counterexample.

```bash
lua5.4 cli/main.lua verify mygame.sb
```

Output:

```
PASS  "player health never goes negative"  (checked 312 states)
```

Or on failure:

```
FAIL  "player health never goes negative"
      counterexample found after 8 choices:
        player/health = -5
```

### Multiple clauses

```
verify "game is winnable":
  verify-always can-reach? quest-complete?  depth: 30

verify "inventory never exceeds 10 items":
  verify-always count-where player/inventory fn(_): true <= 10
```

### `from-any-state:` clause

Check a property from every reachable state, not just the initial one:

```
verify "player always has an escape":
  from-any-state:
    when player/location = 'dungeon:
      can-reach? player/location = 'village  depth: 10
```

This is stronger than `verify-always`: it checks that *from every reachable dungeon state*, the village is reachable.

### `after:` and `requires:` clauses

Test the result of a specific function call:

```
verify "heal never exceeds max health":
  after (heal 50):
    player/health <= 100

verify "buy-item works when affordable":
  requires: player/gold >= 30
  after (buy-item 'sword 30):
    player/gold = player/gold@before - 30
```

`requires:` skips the `after` check when the precondition isn't met. `@before` refers to the value before the call.

---

## Step 6 — `watch` Declarations

Watches fire events in the debug server when conditions become true. They are declared at the top level:

```
watch player/health "health changed"
watch-when player/health <= 0 "player died"
watch-when player/location = 'shrine "reached the shrine"
```

`watch path "label"` fires whenever `path` changes to a non-nil value.
`watch-when cond "label"` fires on the positive edge (when `cond` becomes true after being false).

In the debug server, both fire a `watch-fired` event with the label and current state. Watches are stripped from production builds.

---

## Step 7 — Complete Example

A small game with full verification:

```
module treasure-hunt
  version: 1.0

engine-config:
  entry-scene: forest

type Location = forest | ruins | cave | shrine

state player:
  location: Location = 'forest
  hp:       Int(0, 100) = 100
  has-key:  Bool = false
  has-map:  Bool = false
  won:      Bool = false

fn move-to loc:
  set! player/location loc

fn pick-up-key:
  pre: player/location = 'ruins
  pre: not player/has-key
  set! player/has-key true

fn pick-up-map:
  pre: player/location = 'cave
  pre: not player/has-map
  set! player/has-map true

fn open-shrine:
  pre: player/has-key
  pre: player/has-map
  pre: player/location = 'shrine
  set! player/won true

fn take-damage:
  dec! player/hp (random-int 5 20)

# ── Watches ─────────────────────────────────────────────────────

watch-when player/won "player won"
watch-when player/hp <= 0 "player died"

# ── Verify ──────────────────────────────────────────────────────

verify "hp never goes negative":
  verify-always player/hp >= 0

verify "winning requires key and map":
  verify-always
    not player/won or (player/has-key and player/has-map)

verify "game is winnable from start":
  verify-always can-reach? player/won  depth: 20

# ── Scenes ──────────────────────────────────────────────────────

scene forest:
  A dense forest. Paths lead east to ruins and north to a cave.
  HP: {player/hp}. Key: {player/has-key}. Map: {player/has-map}.

  * Head to the ruins
    move-to 'ruins
    -> ruins
  * Head to the cave
    move-to 'cave
    -> cave
  * [player/has-key and player/has-map] Go to the shrine
    move-to 'shrine
    -> shrine

scene ruins:
  Crumbling stone walls. A rusted key lies in the rubble.
  * [not player/has-key] Pick up the key
    pick-up-key
    -> ruins
  * Encounter a trap
    take-damage
    -> ruins
  * Return to forest
    move-to 'forest
    -> forest

scene cave:
  A dark cave. A tattered map is pinned to the wall.
  * [not player/has-map] Take the map
    pick-up-map
    -> cave
  * Return to forest
    move-to 'forest
    -> forest

scene shrine:
  The ancient shrine. Vines hang from the stone arch.
  * [player/has-key and player/has-map] Open the shrine
    open-shrine
    -> ending

scene ending:
  You have opened the shrine! The treasure is yours.
  HP remaining: {player/hp}.
```

Run verification:

```bash
lua5.4 cli/main.lua verify treasure-hunt.sb
```

Expected output:

```
PASS  "hp never goes negative"  (checked N states)
PASS  "winning requires key and map"  (checked N states)
PASS  "game is winnable from start"  (checked N states)
```

---

## Key Points

| Concept | Syntax |
|---------|--------|
| Reachability check | `can-reach? condition  depth: N` |
| Find sequence of choices | `find-path condition  depth: N` |
| Probability estimate | `probability condition  depth: N` |
| Exhaustive assert | `verify-always condition` |
| State-at-call reference | `path@before` |
| Check from any state | `from-any-state: when cond: check` |
| Watch path | `watch path "label"` |
| Watch condition | `watch-when cond "label"` |
| Run verification | `storybase verify file.sb` |

---

## Next Steps

**[Tutorial 5: Tile Grids](05_tile_grids.md)** — build a tactical mini-game on a 2D tile map with line-of-sight and pathfinding.

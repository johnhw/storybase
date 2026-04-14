# Tutorial 3: Functions and Actors

Extract reusable logic into named functions, add preconditions to guard against invalid calls, and give the world a life of its own with an NPC actor.

By the end of this tutorial you will understand:
- Declaring and calling `fn`
- Pure functions vs. transaction functions
- Preconditions (`pre:`) and postconditions (`post:`)
- Entity families (`state family/{key}: Type`)
- `spawn!` and `despawn!`
- Actor declarations with `behavior`, `perceives`, and `inbox`
- `send!` messaging

---

## Prerequisites

Complete [Tutorial 2](02_state_and_choices.md) first.

---

## Step 1 — Named Functions

Instead of writing mutations directly in scene choices, extract them into named functions:

```
fn heal amount:
  inc! player/health amount

fn take-damage amount:
  dec! player/health amount
```

Call them from choices or other functions:

```
* Rest by the fire
  heal 20
  -> camp
```

The compiler automatically classifies functions:
- **Transaction** — calls at least one mutation (`set!`, `inc!`, etc.). Calls are recorded in the transaction log.
- **Pure** — no mutations. May be called from any context, including choice guards and `when` conditions.

```
fn alive?:
  player/health > 0     # pure: no mutations, returns a Bool
```

---

## Step 2 — Preconditions

A `pre:` block guards a function. If any precondition fails at runtime, the call is rejected and an error is logged in debug mode:

```
fn heal amount:
  pre: alive?                    # can't heal a dead player
  pre: player/health < 100       # no effect if already full
  inc! player/health amount

fn enter-combat enemy:
  pre: alive?
  pre: not combat/active
  set! combat/active true
  set! combat/enemy enemy
```

Multiple `pre:` lines are ANDed. In production builds, `pre:` checks are stripped unless `strict-contracts: true` is set in `engine-config`.

A `post:` block checks after the body runs. Use `path@before` to reference the value before the call:

```
fn buy-item price:
  pre:  player/gold >= price
  post: player/gold = player/gold@before - price
  dec!  player/gold price
```

---

## Step 3 — Entity Families

Entity families let you create a dynamic collection of instances with typed state:

```
type NpcStatus = idle | working | hostile | fled

type Npc:
  hp:     Int(0, 100) = 80
  status: NpcStatus   = 'idle
  name:   String      = "Stranger"

state npcs/{npc}: Npc  max: 10
```

`state npcs/{npc}: Npc  max: 10` declares a family where each member is an `Npc` record. `{npc}` is auto-typed as `SymbolOf(npcs)`. Up to 10 instances can exist simultaneously.

Spawn and despawn instances:

```
fn spawn-guard:
  spawn! npcs 'guard Npc(name: "Gate Guard", hp: 90, status: 'idle)

fn remove-guard:
  pre: path-exists? npcs/guard/hp
  despawn! npcs 'guard
```

Read and write family member state using interpolated paths:

```
set! npcs/guard/status 'hostile
let hp = npcs/guard/hp:
  when hp < 20:
    set! npcs/guard/status 'fled
```

Iterate over all live members:

```
fn pacify-all:
  for npc in (path-list npcs):
    set! npcs/{npc}/status 'idle
```

Check if a member exists:

```
[path-exists? npcs/guard/hp] Talk to the guard
```

---

## Step 4 — Actors

Actors are autonomous agents. Each actor runs a behavior function every turn, after the player's action.

```
type GuardMsg:
  | alert:     threat: Symbol
  | stand-down:

actor guard-actor:
  state:     npcs/guard
  perceives: [npcs/guard/hp, npcs/guard/status, player/location]
  inbox:     List(GuardMsg, 4)
  behavior:  guard-behavior
  priority:  10
```

| Field | Description |
|-------|-------------|
| `state:` | The state path prefix for this actor's own state |
| `perceives:` | Paths the behavior function may read (enforced by the compiler) |
| `inbox:` | Typed message queue |
| `behavior:` | Name of the transaction function to call each turn |
| `priority:` | Higher priority wins conflict resolution when two actors write the same path |

**Perception filtering:** before the behavior function runs, the engine builds a read-only snapshot containing only the `perceives:` paths. The behavior function cannot read state it doesn't perceive — this is enforced at compile time.

---

## Step 5 — Behavior Function

A behavior function is a transaction function called by the engine each turn:

```
fn guard-behavior:
  # React to messages
  for msg in npcs/guard/inbox:
    match msg:
      alert {threat}:
        set! npcs/guard/status 'hostile
      stand-down:
        set! npcs/guard/status 'idle

  # Autonomous behavior: chase player if hostile
  when npcs/guard/status = 'hostile and player/location = 'courtyard:
    dec! npcs/guard/hp 5       # guard gets hurt in the fight
```

Note: actor mutations are **deferred**. The engine collects all actor mutations and applies them after all behaviors have run. This prevents actor execution order from affecting outcomes.

---

## Step 6 — Sending Messages

Send a typed message to an actor from a scene choice or transaction function:

```
fn raise-alarm:
  send! guard-actor (GuardMsg/alert threat: 'player)

fn sound-all-clear:
  send! guard-actor (GuardMsg/stand-down)
```

Messages are delivered at the start of the *next* turn's message-delivery step and appear in the actor's `inbox`. The `for msg in inbox:` loop in the behavior function processes them.

---

## Step 7 — Complete Example

Here is a mini-game with a guard NPC:

```
module guard-game
  version: 1.0

engine-config:
  entry-scene: village

type NpcStatus = idle | hostile | fled

type GuardMsg:
  | alert:
  | stand-down:

state player:
  location: Symbol = 'village
  suspicious: Bool = false

state npcs/guard:
  hp:     Int(0, 100) = 90
  status: NpcStatus   = 'idle

actor guard-actor:
  state:     npcs/guard
  perceives: [npcs/guard/hp, npcs/guard/status, player/location, player/suspicious]
  inbox:     List(GuardMsg, 4)
  behavior:  guard-behavior
  priority:  10

fn guard-behavior:
  for msg in npcs/guard/inbox:
    match msg:
      alert:
        set! npcs/guard/status 'hostile
      stand-down:
        set! npcs/guard/status 'idle

  when npcs/guard/status = 'hostile and player/location = npcs/guard/status:
    dec! npcs/guard/hp 10

fn do-suspicious-thing:
  set! player/suspicious true
  send! guard-actor (GuardMsg/alert)

fn act-normal:
  set! player/suspicious false
  send! guard-actor (GuardMsg/stand-down)

scene village:
  You are in the village. Guard status: {npcs/guard/status}.
  Your suspicion level: {player/suspicious}.

  when npcs/guard/status = 'idle:
    The guard nods at you.
  when npcs/guard/status = 'hostile:
    The guard stares at you with narrowed eyes.

  * Act suspicious
    do-suspicious-thing
    -> village
  * Act normal
    act-normal
    -> village
```

---

## Key Points

| Concept | Syntax |
|---------|--------|
| Transaction function | `fn f: inc! x 1` |
| Pure function | `fn f: x > 0` |
| Precondition | `pre: condition` |
| Entity family | `state family/{key}: Type  max: N` |
| Spawn / despawn | `spawn! family 'key Type(...)` / `despawn! family 'key` |
| Check existence | `path-exists? family/key/field` |
| Iterate family | `for k in (path-list family):` |
| Actor declaration | `actor name: state: ... perceives: ... inbox: ... behavior: ... priority: N` |
| Send message | `send! actor-name (MsgType/variant arg: val)` |

---

## Next Steps

**[Tutorial 4: Search and Verify](04_search_and_verify.md)** — use the engine's exhaustive search to test whether your game is winnable and verify invariants hold in all reachable states.

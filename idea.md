
# StoryBase Language Specification — V1.0

## 1. Overview and Philosophy

StoryBase is a DSL for authoring adventure and RPG games. It is implemented in Lua using an LPEG-based parser, with a runtime library that manages state, the transaction log, and the debug interface. Its central idea is the **logic machine**: a deterministic, finite-state core that controls all gameplay decisions, surrounded by an unbounded presentation layer that can display anything but never affect logic.

Five principles govern the design:

**Separation of logic and presentation.** All branching, conditionals, and gameplay decisions depend only on *discrete* (bounded, enumerable) types. Text, visuals, and other presentation data are *superficial* types: they can be displayed and updated, but no computation may branch on their values. This separation makes the game state machine finite and fully analysable.

**The transaction log is the ground truth.** Every change to state is recorded as a timestamped transaction. The current state is always a projection of the log. This gives automatic save/load, full replay, debugging by time-travel, and the basis for future-state search.

**Bounded exhaustive search over futures.** Because all logic depends only on discrete bounded types, and all random sources produce a finite set of outcomes, the reachable future states form a finite (if large) graph. The engine searches this graph to answer questions like *can the player reach the castle?* or *is it possible to die in the next five turns?*

**Structured actors and messaging.** Complex game worlds involve many interacting entities. Actors encapsulate NPC and environment behaviour; they communicate through typed, discrete messages that appear in the transaction log. This keeps multi-entity interactions analysable and replayable.

**First-class debugging and hot reload.** The debug interface is part of the language specification, not an afterthought. Live state inspection, time-travel, watch expressions, hot reload, and counterfactual traces are core design goals baked into the runtime contract.

---

## 2. Syntax

### 2.1 Tokens and Lexical Rules

```
# This is a comment. Comments run to end of line.

# Booleans
true   false

# Integers
42   -7   0

# Floats  (superficial only — cannot appear in logic)
3.14   -0.5

# Strings  (superficial only)
"hello, world"   "line one\nline two"

# Multi-line string — indentation stripped to opening column
"""
  The forest is dark and cold.
  A distant horn echoes through the trees.
"""

# Symbol literals  (quoted with ')
'sword   'alive   'blacksmith

# Paths  — any token containing / is a path
player/health
npcs/blacksmith/disposition
world/chapter

# Path with variable interpolation (var must be a typed entity-family key)
npcs/{npc}/health

# Named argument
depth: 20

# Block opener — colon at end of a form
fn move-to loc:
  body ...
```

**Naming conventions:**
- Functions returning `Bool` or testing a condition end with `?`: `alive?`, `can-afford?`
- Mutation primitives end with `!`: `set!`, `spawn!`, `dec!`
- Type names are `CamelCase`: `CharClass`, `Health`
- Everything else uses `kebab-case`: `player/hit-points`, `move-to`

### 2.2 Indentation Layout

Parentheses are **grouping only** and never open a block. All block structure is determined by indentation.

- A form that does not close on its opening line uses the indented block beneath it as its remaining arguments or body statements.
- Lines at the same indentation within a block are siblings.
- Dedenting closes the current block.
- Parentheses within a line are legal for inline sub-expressions and always take precedence inside their own scope.

```
# Block style
fn take-damage amount:
  dec!  player/health amount
  when  player/health <= 0:
    set! player/status 'dead

# Parentheses for inline grouping
fn effective-damage base roll:
  min base (base + roll)
```

### 2.3 Expression Syntax

Comparisons and boolean operators use **infix** notation. Function calls use **prefix** notation.

```
# Infix comparisons
player/health > 0
player/status = 'alive
world/turn != 0
npcs/{npc}/health >= 50

# Infix boolean operators
player/status = 'alive  and  player/health > 0
not player/has-key
x > 0  or  y < 10

# Prefix function calls
can-afford? 40
min amount (100 - player/health)
contains? player/inventory 'sword

# Nil-coalescing (right side evaluated only if left is nil)
npcs/{npc}/health ?? 0
player/companion ?? 'none

# Arithmetic (infix)
player/gold - 40
base + (random-int 0 10)
```

Operator precedence (high to low): `*` `/`, `+` `-`, comparisons (`=` `!=` `<` `>` `<=` `>=`), `not`, `and`, `or`, `??`.

**Lambda expressions** produce anonymous functions. They are valid wherever a function type is expected (e.g. `any?`, `all?`, `count-where`) and in `fn` arguments that accept a callback.

```
# Single-expression lambda
fn(x): x > 0
fn(item): contains? player/inventory item
fn(x y): x + y

# Multi-line lambda — body is an indented block
fn(npc):
  npcs/{npc}/status = 'alive
  and  npcs/{npc}/disposition = 'hostile
```

The compiler infers the parameter types from context. Lambdas are always pure (they may not call mutation primitives).

### 2.4 Control Flow

```
# Conditional (no else)
when player/health <= 0:
  set! player/status 'dead

# Conditional with else
if player/has-key:
  set! combat/active true
else:
  set! player/description "You need a key."

# Pattern match (expression or statement)
match player/class:
  'warrior: 15
  'rogue:   12
  'mage:     8
  _:         0     # wildcard branch

# Multi-way conditional — each branch tests an arbitrary boolean expression
cond:
  player/health <= 0:   set! player/status 'dead
  player/health < 20:   set! player/description "Badly wounded."
  _:                    set! player/description "Feeling fine."

# For loop
for npc in (path-list npcs):
  set! npcs/{npc}/location 'village

# While loop — condition re-evaluated each iteration; body may mutate state
while combat/active  and  player/status = 'alive:
  attack-enemy
  enemy-attacks

# Let bindings (sequential; each binding may reference previous ones)
let base  = base-damage
    roll  = (random-int 0 10)
    total = base + roll:
  dec! player/health total
```

### 2.5 Collection Literals

```
# Set — bare values, commas optional
{'sword, 'potion, 'key}
(set)                       # empty set

# List — ordered, indexed
['north, 'east, 'south]
[]                          # empty list

# Map — key: value pairs, commas optional
{name: "Aldric", class: 'warrior, level: 5}
{}                          # empty map
```

**Parser rule:** if the first element inside `{...}` is followed by `:`, the whole form is a map; otherwise it is a set. `{}` is always an empty map; `(set)` is always an empty set.

### 2.6 Type Expressions

```
Bool                          # boolean
Int(0, 100)                   # bounded integer
Enum(alive, dead, unknown)    # inline anonymous enum
Option(T)                     # T or nil
Set(T, max)                   # bounded set
List(T, max)                  # bounded list
SymbolOf(Family)              # typed symbol
String    Float               # superficial types
UList(T)  UMap(K, V)          # unbounded superficial collections
RecordName   VariantName      # declared named types
(T -> R)                      # function / lambda type (one argument)
(T U -> R)                    # function / lambda type (two arguments)
```

### 2.7 Scene Syntax

In a scene body, plain text lines are narration; special sigils introduce choices and navigation.

```
scene village:
  You stand in the **village square**. The forge glows to the east.

  [hostile-nearby?] A hostile figure lurks nearby!

  * Enter the forest
    move-to 'forest
    random-encounter
    -> forest

  * [can-afford? 40] Buy a health potion (40 gold)
    buy-item 'health-potion 40
    -> village

  * Talk to the blacksmith
    => talk-blacksmith

  * Rest here (recover 20 health)
    heal 20
    -> village
```

Scene sigils:
- Plain text lines = narration emitted to the presentation layer
- `[condition] Text` = conditional narration (shown only when condition holds; not a choice)
- `* [cond] Text` = choice; optional `[cond]` guard hides choice when false
- `-> name` = goto (scene stack unchanged)
- `-> (expr)` = computed goto; `expr` must evaluate to a `SceneId`
- `=> name` = enter (push current scene onto stack, transition to `name`)
- `<-` = exit (pop stack, return to previous scene)

Narration may contain inline expressions in `{...}`:

```
scene combat:
  Fighting {npcs/{combat/enemy}/name}!
  Your health: {player/health}.  Enemy health: {npcs/{combat/enemy}/health}.
```

Inline expressions are read-only and may reference any discrete path (values are converted to display strings by the presentation layer).

---

## 3. Type System

Types are divided into two worlds. The compiler enforces the boundary between them.

### 3.1 Discrete Types

Discrete types have a **finite, bounded** set of possible values. Only discrete types may appear in conditional expressions or drive game logic. All discrete types have a computable *state-space size* used to bound future-state search.

| Type             | Example syntax             | State-space size               |
|------------------|----------------------------|-------------------------------|
| Boolean          | `Bool`                     | 2                              |
| Bounded integer  | `Int(0, 100)`              | max − min + 1                  |
| Named enum       | `type S = alive \| dead`   | N values                       |
| Inline enum      | `Enum(alive, dead)`        | N values                       |
| Symbol (untyped) | `Symbol`                   | ∞ — emits `warn-untyped-symbol`|
| Typed symbol     | `SymbolOf(Family)`         | \|Family\|                     |
| Option           | `Option(T)`                | \|T\| + 1                      |
| Bounded set      | `Set(T, max)`              | Σ C(\|T\|, i) for i = 0..max  |
| Bounded list     | `List(T, max)`             | (\|T\| + 1)^max                |
| Record           | `RecordName`               | product of field sizes         |
| Variant          | `VariantName`              | sum of branch sizes            |

### 3.2 Superficial Types

Superficial types are **unbounded** and used exclusively for presentation. The compiler enforces:

- No superficial value may appear in a conditional expression (`if`, `when`, `cond`, `match`).
- No superficial value may be passed where a discrete type is expected.
- No random source may produce a superficial value.
- Superficial values *may* be constructed from discrete values (building a description string from an enum is fine).

| Type        | Notes                          |
|-------------|-------------------------------|
| `String`    | Narrative text, display names  |
| `Float`     | Visual/audio parameters        |
| `UList(T)`  | Unbounded list                 |
| `UMap(K,V)` | Unbounded map                  |

### 3.3 The Compiler Boundary

```
# OK: discrete value drives a conditional
if player/health < 20:
  set! player/description "You look badly hurt."

# OK: superficial value updated from discrete
set! player/description
  match player/status:
    'alive: "Hale and hearty."
    'dead:  "Dead."

# ERROR: superficial value in a conditional
if player/name = "Alice":      # compile error: String in condition
  grant-bonus

# ERROR: random source producing superficial
set! player/name (random-choice ["Alice", "Bob"])   # compile error
```

### 3.4 Typed Symbols

`Symbol` is the catch-all for symbolic values whose domain has not yet been enumerated. Legal everywhere a discrete type is expected, but emits `warn-untyped-symbol`. The state-space size is treated as a large constant, degrading search precision.

Entity-family keys (e.g. `{npc}` in `state npcs/{npc}: Npc`) are automatically typed as `SymbolOf(npcs)`.

```
# Warns: imprecise search bounds
state flags: Set(Symbol, 20)

# Better: precise bounds, no warning
type QuestFlag = ore-delivered | goblin-defeated | found-crown
state flags: Set(QuestFlag, 20)
```

`storybase extract-symbols` scans a codebase, collects all symbol literals used in a given context, and outputs a candidate `type` declaration.

### 3.5 Nil and Nil-Coalescing

Reads from an uninstantiated family member (e.g. `npcs/stranger/health` before that NPC has been spawned) return `nil`. Nil propagates through pure expressions. Mutations targeting a nil path are runtime errors, caught by debug hooks and logged in dev mode.

```
npcs/{npc}/health ?? 0       # 0 if npc not yet spawned
player/companion ?? 'none    # 'none if companion path is nil
```

`??` is a binary infix operator. The right-hand side is evaluated only if the left-hand side is nil. `??` may not appear in write positions.

### 3.6 Saturation Arithmetic

Mutation primitives on `Int(min, max)` values **clamp** to the declared range by default. There is no wrap-around and no implicit error.

```
# Health = Int(0, 100). Current value: 10.
dec! player/health 50     # → clamps to 0, not -40
inc! player/health 200    # → clamps to 100
```

In debug mode, the `clamp-event` hook fires on every clamp (§18.1). Production builds clamp silently.

---

## 4. Path Syntax

Paths are the fundamental addressing mechanism. Any token containing `/` is a path. Paths are absolute; a leading `/` is optional and stripped.

### 4.1 Variable Interpolation

`{varname}` splices a variable into a path segment. The variable must be typed as an entity-family key (`SymbolOf(Family)`).

```
npcs/{npc}/health         # npc : SymbolOf(npcs)
zones/{zone}/discovered   # zone : SymbolOf(zones)
```

### 4.2 Write-Path Restrictions

In any **write position** (any mutation primitive — see §8) the following rules apply:

- **Static paths** are always legal: `set! player/health 50`
- **`{var}` interpolation** is legal only if `var` has a declared entity-family type. The compiler infers the write-set as `family/*/field`.
- **Dynamic path construction** is a compile error in all write positions.

```
# Legal: npc is typed as SymbolOf(npcs)
set! npcs/{npc}/health 50

# COMPILE ERROR: untyped variable
let p = some-fn:
  set! {p}/health 50

# COMPILE ERROR: dynamic construction
set! (path-join "npcs/" name "/health") 50
```

This restriction ensures the compiler can always determine the static write-set of any function, which is required for future-state search, hook analysis, and bidirectional search.

### 4.3 Path Patterns (Query Context Only)

Path patterns are legal only inside `find`, `query-history`, `can-reach?`, `verify`, and `watch` forms.

| Pattern                     | Matches                                              |
|-----------------------------|------------------------------------------------------|
| `player/health`             | Exactly `/player/health`                             |
| `player/*`                  | Any single segment under `/player`                   |
| `player/**/strength`        | `strength` at any depth under `/player`              |
| `npcs/*/location`           | `location` under any direct NPC                      |
| `player/(health\|mana)`     | Either `health` or `mana` under `/player`            |
| `player/!inventory`         | Any field under `/player` except `inventory`         |

### 4.4 Indexed Access

For `List` values, index and slice notation is legal in both read and write positions.

```
player/waypoints[0]       # first element
player/waypoints[-1]      # last element
player/waypoints[1:4]     # elements 1–3
```

---

## 5. Module System

### 5.1 Module Header

Every file may open with a `module` declaration. It is optional but recommended.

```
module combat
  version: 1.2
  exports: [enter-combat, exit-combat, CombatState, CombatResult]
```

`version` is used by the migration system (§11). `exports` lists names visible when this module is imported with a namespace alias; without `exports`, all top-level names are exported.

### 5.2 Importing

```
import "combat.sb"              # flat import — all names available unqualified
import "enemies.sb" as E        # namespaced — E.Npc, E.spawn-enemy, E.NpcId
import "shared/items.sb"        # relative path from the importing file
```

Import cycles are a compile error.

### 5.3 State Paths Are Global

**State paths are always global.** A `state npcs/{npc}: Npc` declaration in `enemies.sb` contributes to the global path namespace as `npcs/{npc}/…` regardless of how it is imported. The path namespace is the shared world state; module namespacing applies only to type names, function names, and scene names.

This is intentional: paths represent game state, not programmer organisation. Two modules may both read and write `player/health` without any special coordination. The transaction log records all mutations regardless of which module triggered them.

---

## 6. Schema Declarations

All types and state shapes must be declared before any game logic. The compiler uses the schema to check types, compute state-space bounds, and enforce the discrete/superficial boundary.

### 6.1 Type Declarations

The `type` keyword covers all type definition forms. The body shape determines which form is used.

**Enum** — `=` followed by `|`-separated names:

```
type Status       = alive | dead | unconscious
type Location     = village | forest | dungeon | castle
type CharClass    = warrior | rogue | mage
type CombatResult = ongoing | victory | defeat
```

**Range alias** — `=` followed by a type expression:

```
type Health = Int(0, 100)
type Gold   = Int(0, 9999)
type Damage = Int(0, 999)
```

**Record** — indented block of `field: Type = default` lines:

```
type Entity:
  health:   Health   = 50
  status:   Status   = 'alive
  location: Location = 'village
  name:     String   = "Unknown"

type Npc:
  with Entity                        # mixin — splices all Entity fields here
  disposition: Disposition = 'neutral

type Player:
  with Entity
  health:      Health           = 100   # override default only, not type
  mana:        Int(0, 50)       = 50
  gold:        Gold             = 30
  class:       CharClass        = 'warrior
  has-key:     Bool             = false
  inventory:   Set(ItemKind, 10) = (set)
  quest-flags: Set(QuestFlag, 20) = (set)
  description: String           = ""
```

`with OtherRecord` splices all fields from `OtherRecord` at that point. Fields declared after `with` may **override defaults but not types**. Multiple `with` clauses are allowed; conflicting field names from two different `with` sources are a compile error.

**Variant** — indented block of `| branch:` lines:

```
type ActorMsg:
  | alert:          threat: NpcId, location: Location
  | trade-offer:    item: ItemKind, price: Gold
  | attack-request: target: NpcId, damage: Damage
  | quest-update:   quest: QuestFlag, status: Bool
```

Each branch is an anonymous record. State-space size is the sum of all branch sizes.

### 6.2 State Declarations

```
"The player's persistent state."
state player: Player = Player(name: "Hero")

"One entry per spawned NPC. Up to 20 concurrent."
state npcs/{npc}: Npc  max: 20       # npc auto-typed as SymbolOf(npcs)

state world:
  turn:    Int(0, 9999) = 0
  chapter: Chapter      = 'intro

state combat:
  active:  Bool         = false
  enemy:   NpcId        = 'wanderer
  outcome: CombatResult = 'ongoing
```

For entity families (`state family/{var}: Type`), `max: N` declares the maximum number of simultaneously instantiated members, bounding the state-space size for search. Instances are created and destroyed with `spawn!` and `despawn!` (§8.5).

A string literal immediately before any declaration is a **doc string**, attached to the declaration and surfaced in the live inspector (§18.4).

### 6.3 Relation Declarations

```
"Movement graph between locations."
relation exits: Location -> Set(Location, 6):
  'village: {'forest}
  'forest:  {'village, 'dungeon}
  'dungeon: {'forest, 'castle}
  'castle:  {'village}
```

The static data block is optional. Relations may also be populated or modified at runtime with `relate!` and `unrelate!` (§8.3). A relation without a static block starts empty.

### 6.4 Time Model

```
time-model:
  axes: [day, hour, minute, tick]
  wrap: [none, 24, 60, none]    # cyclic axes wrap; none means no wrap-around
```

Time literals use named axes. Omitted axes are zero (absolute) or unchanged (relative):

```
[tick: +1]                       # advance one tick
[day: +1]                        # advance one day
[day: +1, tick: +5]              # advance one day and five ticks
[day: 3, hour: 14, tick: 0]      # set absolute time
```

### 6.5 Schema Version

```
schema-version: 3
```

Declared at the top of the main schema file. When loading a save, the engine applies any outstanding migration blocks (§11) in order to bring the save up to the current version.

### 6.6 Engine Configuration

```
engine-config:
  entry-scene:         main
  scene-stack-max:     16
  max-counterfactual-depth: 3
  strict-contracts:    false     # enable pre/post checking in production
  debug-port:          7373
```

---

## 7. Functions

### 7.1 Declaration

```
fn function-name arg1 arg2 ...:
  body
```

Arguments are positional by default. Named arguments use `name: value` syntax; they may not precede positional arguments, but their order among each other does not matter.

```
fn move-to loc:
  set!  player/location loc
  time-inc! tick:

fn heal amount:
  pre:  player/status = 'alive
  inc!  player/health (min amount (100 - player/health))

fn can-afford? price:
  player/gold >= price

fn alive? entity:
  npcs/{entity}/status = 'alive
```

### 7.2 Pure vs. Transaction Inference

The compiler automatically classifies every function:

- **Transaction function** — calls any mutation primitive directly or transitively. Calls are recorded in the log. May not be called from pure contexts (inside `find where` clauses, `verify` conditions, etc.).
- **Pure function** — calls no mutation primitives. Returns a value; may read any path. Free to call from any context.

There is no annotation required. The compiler infers the classification and verifies it.

### 7.3 Preconditions and Postconditions

```
fn take-damage amount:
  pre:
    amount > 0
    player/status = 'alive
  post:
    player/health >= 0
  dec!  player/health amount
  when  player/health <= 0:
    set! player/status 'dead
    set! player/description "You have fallen."
```

`pre:` conditions are checked before the body runs. `post:` conditions are checked after. Violations are runtime errors caught by debug hooks (§18) and logged in dev mode. Both blocks are stripped in production builds unless `strict-contracts: true` is set in engine config.

`path@before` in a `post:` block refers to the value of `path` as it was at the start of the function:

```
fn buy-item item price:
  pre:  can-afford? price
  post: player/gold = player/gold@before - price
  dec!  player/gold price
  pickup-item item
```

### 7.4 Function Tags

```
fn enter-combat enemy:
  tags: [checkpoint, reversible]
  set!  combat/active true
  ...
```

Built-in tag meanings:

| Tag          | Effect                                                              |
|--------------|---------------------------------------------------------------------|
| `checkpoint` | Engine inserts a save-point in the log before this call            |
| `reversible` | Compiler verifies all mutations in this function are invertible     |
| `debug-only` | Declaration is stripped from production builds                      |

Custom tags may be declared with `tag name` and used in hooks (§9).

---

## 8. Mutation Primitives

All mutation primitives are valid only inside transaction functions. Every call produces a log entry.

### 8.1 Scalar Mutations

```
set!  path value             # assign value to path
inc!  path amount            # add amount (Int, clamps to declared range)
dec!  path amount            # subtract amount (Int, clamps to declared range)
```

### 8.2 Collection Mutations

```
add!    path value           # add value to Set
remove! path value           # remove value from Set
push!   path value           # append to List (bounded; runtime error if full)
pop!    path                 # remove and return last element of List
clear!  path                 # empty a Set or List
```

### 8.3 Relation Mutations

```
relate!   relation a b       # add (a → b) to relation
unrelate! relation a b       # remove (a → b) from relation
```

### 8.4 Actor Messaging

```
send! actor-name message     # enqueue a typed message to actor's inbox
```

Messages sent during a turn are delivered at the start of the next turn's message-delivery step (§14.4).

### 8.5 Spawning

```
spawn!   npcs 'blacksmith Npc(name: "Aldric", health: 80)
despawn! npcs 'blacksmith
```

`spawn! family key Record(...)` instantiates a new family member. The key must not already exist (runtime error otherwise). `despawn!` removes the instance; subsequent reads of its paths return nil. Both operations are logged and are reversible by undo and counterfactual (§21).

### 8.6 Scene Navigation (from transaction functions)

```
goto-scene!  'combat          # goto from inside a transaction function
enter-scene! 'talk-npc        # enter (push) from inside a transaction function
exit-scene!                   # exit (pop) from inside a transaction function
```

These are the imperative equivalents of the `->`, `=>`, and `<-` scene sigils.

### 8.7 Time

```
time-inc! tick:              # advance time by one tick
time-inc! day: 1, tick: 3   # advance by 1 day and 3 ticks
```

### 8.8 Undo

```
undo!                        # revert state to the last checkpoint
undo! steps: 3               # revert to 3 checkpoints ago
```

`undo!` replays the log from the most recent checkpoint, reconstructing state. It does not erase log entries; it appends a special `undo` event so the full play history remains auditable. The undo target must have been produced by a function tagged `checkpoint` or by the engine's auto-checkpoint mechanism.

---

## 9. Hooks and Aspects

Hooks execute before or after tagged functions. They observe state but may not call mutation primitives except through `engine/emit` (the debug/presentation event channel).

```
tag checkpoint
tag reversible
tag broadcast

hook checkpoint:
  pre:  engine/checkpoint! fn-name

hook broadcast:
  post: engine/emit 'state-changed changes

# Hook on a specific function
hook after: move-to:
  engine/emit 'player-moved {from: old-location, to: player/location}
```

`changes` in a `post:` hook is a read-only list of `{path, old, new}` records for all mutations made during the tagged function.

---

## 10. Random Sources

All random sources produce discrete values, are logged, and are replayable.

```
random-bool p                # true with probability p (Float, 0–1)
random-int  min max          # uniform integer in [min, max]
random-enum EnumType         # uniform draw from an enum
random-choice list           # uniform draw from a List
random-weighted weights list # weighted draw; weights is List(Float, N)
```

In exhaustive search mode, each random call is replaced by a branch over all possible outcomes weighted by their probabilities. Branches below a configurable probability threshold are pruned.

Random draws are logged as `random(source, result, seed)`. Replaying with the same seed produces the same outcome.

---

## 11. Bounded Computations

`bounded` declares a Lua function that produces a discrete output from potentially complex (non-discrete) computation. The result is treated identically to a random draw by the search engine: it branches over the declared distribution. At runtime the Lua function is called and its result is logged.

```
bounded classify-intent text:
  returns:      PlayerIntent
  distribution: uniform
  reads:        []
  lua:          "game.nlp.classify_intent"

bounded tactical-assessment npc:
  returns:      Disposition
  distribution: conditioned-on npcs/{npc}/disposition
  reads:        [player/location, player/status, npcs/{npc}/*]
  lua:          "game.ai.assess_threat"
```

- `returns` — the discrete output type (required).
- `distribution` — how the search engine branches: `uniform` (all return values equally likely), `conditioned-on path` (use current path value as prior).
- `reads` — path patterns the Lua function may read (for hook analysis and perception snapshots).
- `lua` — dotted Lua module path. Called as `module.fn(arg, state_snapshot)` where `state_snapshot` is a read-only Lua table of the declared `reads:` paths.

The result is a normal discrete value, usable in conditionals and logic. Any function that calls a `bounded` computation is automatically tagged `uses-bounded`.

---

## 12. Transaction Log and Time

Every mutation — `set!`, `inc!`, `dec!`, collection operations, `relate!`, `unrelate!`, `send!`, `spawn!`, `despawn!`, `undo!`, scene transitions, random draws, bounded computations, and scheduled events — produces a log entry:

```
{seq: 514, time: {day:1, hour:5, tick:10}, fn: "move-to", path: "player/location", old: "village", new: "forest"}
```

The log is the single source of truth. Current state is always a projection of all log entries in order. Saving and loading a game is saving and replaying a log. The engine maintains an in-memory cache of the current projected state for O(1) reads.

**Historical queries:**

```
query-at player/location  time: {day: 1, hour: 3, tick: 0}
  → 'forest

query-history player/health
  from: {tick: 0}
  to:   now
  → [{time: ..., old: 100, new: 80}, ...]

query-changes player/location  last-n: 5
```

---

## 13. Scheduling

The scheduler is part of the engine. Scheduled events appear in the log at their declared time, exactly as if triggered by normal code. Future-state search includes all pending scheduled events in successor-state computation.

```
"Return all NPCs to their home locations each morning."
schedule morning-reset:
  every:  [day: +1]
  offset: [hour: 6]
  fn:
    for npc in (path-list npcs):
      set! npcs/{npc}/location 'village
    set! npcs/blacksmith/disposition 'friendly

schedule gate-close:
  at: [tick: +50]
  fn:
    set! world/gate-open false
```

**Imperative scheduling** from inside a transaction function:

```
schedule! 'patrol  every: [tick: +10]  fn: patrol-route
cancel-schedule! 'patrol
```

The pending schedule queue is itself discrete logged state — it appears in the log when created or cancelled, and is included in future-state search.

---

## 14. Actors and Messages

### 14.1 Actor Declaration

```
"The village blacksmith NPC."
actor blacksmith:
  state:     npcs/blacksmith
  perceives: [world/turn, player/location, player/quest-flags,
               npcs/blacksmith/*]
  inbox:     List(ActorMsg, 8)
  behavior:  blacksmith-behavior
  priority:  10

actor guard:
  state:     npcs/guard
  perceives: [player/location, npcs/*/location, npcs/guard/*]
  inbox:     List(ActorMsg, 8)
  behavior:  guard-behavior
  priority:  20
```

### 14.2 Perception Snapshots

Before calling a behavior function, the engine builds a **perception snapshot** — a frozen filtered copy of state containing only the paths matching the `perceives:` patterns. Behavior function reads resolve against the snapshot. The compiler rejects reads of paths not covered by `perceives:`. This means behavior functions are pure with respect to unperceived state.

### 14.3 Behavior Functions

A behavior function is a transaction function called by the engine during the actor step. It reads from the perception snapshot and emits mutations and messages.

```
fn blacksmith-behavior:
  when player/location = 'village:
    set! npcs/blacksmith/disposition 'friendly
  for msg in npcs/blacksmith/inbox:
    match msg:
      alert {threat, location}:
        set! npcs/blacksmith/disposition 'hostile
        send! guard (ActorMsg/attack-request target: threat, damage: 10)
      trade-offer {item, price}:
        when player/gold >= price:
          dec!  player/gold price
          add!  player/inventory item
      _: pass

fn guard-behavior:
  for msg in npcs/guard/inbox:
    match msg:
      attack-request {target, damage}:
        set! npcs/guard/disposition 'hostile
      _: pass
```

Actor mutations are **deferred** — they are queued and applied only after all actors complete their behavior step. This prevents actor execution order from affecting outcomes. Conflicts (two actors writing the same path) are resolved by the higher-priority actor winning; all conflicts are logged.

### 14.4 Turn Lifecycle

Each game turn proceeds in six steps:

1. **Player action (optional)** — if player input is available, the corresponding transaction function is applied immediately. If no input is provided the step is skipped, allowing fully autonomous turns driven by actors and scheduled events alone.
2. **Message delivery** — messages sent in the previous turn are moved to each actor's `inbox`.
3. **Actor behaviors** — all actors run their behavior functions in `priority` order; mutations are deferred.
4. **Mutation application** — deferred actor mutations are applied in priority order.
5. **Scheduled events** — any schedule whose trigger time has arrived fires.
6. **Queue rotation** — actor inboxes are cleared; `time-inc! tick:` fires if time was not already advanced during this turn (regardless of whether a player action occurred).

Autonomous turns (step 1 skipped) are the normal mechanism for NPC speed and pacing: a fast NPC's schedule can fire every tick while a slow NPC fires every five, all without any player involvement. Steps 2–6 are included as transitions in future-state search.

---

## 15. Query Language

### 15.1 Simple Queries

```
# Single-value read
player/health

# Boolean expression
player/status = 'alive  and  player/health > 20

# Historical query
query-history player/health  from: 5 ticks ago  to: now
```

### 15.2 The `find` Form

`find` queries an entity family with composable filters, returning a bounded list of matching keys or an integer count.

```
find npc
  where    npcs/{npc}/disposition = 'hostile
  within   3 hops of exits from player/location
  order-by npcs/{npc}/health asc
  limit    5
```

Clauses (all optional; multiple `where` clauses are ANDed):

| Clause | Description |
|--------|-------------|
| `where <condition>` | State filter |
| `or-where <condition>` | Disjunction with previous `where` |
| `within N hops of <rel> from <src>` | Reachability filter via a relation |
| `connected-to <path> via <relation>` | Any-hop adjacency |
| `order-by <path> asc\|desc` | Sort result list |
| `limit N` | Cap the result list |
| `count` | Return an integer instead of a list |

`find` is a pure expression. The result type is `List(SymbolOf(Family), limit)` or `Int` for `count`.

### 15.3 Relation Queries

Built-in queries on `relation` declarations. All return discrete values.

```
adjacent?         exits 'village              # Set of locations 1 hop from village
adjacent?         exits player/location       # Set 1 hop from player
reachable?        exits player/location 'castle              # Bool
reachable?        exits player/location 'castle  max-hops: 5 # Bool
shortest-path     exits player/location 'castle              # List(Location, ...)
reachable-set     exits player/location  max-hops: 2         # Set of locations
inverse-adjacent? exits 'forest              # Set of locations that lead into forest
```

### 15.4 Future-State Search

```
can-reach?          player/status = 'dead            # Bool
can-reach?          player/status = 'dead  depth: 20
find-path           player/location = 'castle        # action sequence or nil
verify-always       player/health >= 0               # Bool: holds in all futures?
find-counterexample player/health >= 0               # failing state, or nil
probability         player/status = 'dead  depth: 10 # Float
optimal-path        quest-complete?  by: min-turns   # optimal action sequence
```

All search operations accept `depth: N` and `strategy: breadth-first|depth-first|best-first`.

---

## 16. Spatial Queries

### 16.1 Room Graphs

Room-based games use `relation exits: Location -> Set(Location, max)`. The query operations in §15.3 — adjacency, reachability, shortest path, inverse adjacency — provide all standard room-graph needs.

### 16.2 Tile Grid Extension

For tactical games requiring tile-based spatial reasoning, the optional `defgrid` extension adds:

```
defgrid world-map:
  dimensions: Int(0, 30) x Int(0, 30)
  cell-type:  TileKind
```

With `defgrid`, the following queries become available:

```
visible-from?  world-map player/tile-pos target/tile-pos        # raycasting
within-range?  world-map player/tile-pos target/tile-pos  range: 5
path-to        world-map player/tile-pos target/tile-pos        # A* List
occupied-by    world-map tile-pos                               # entity or nil
```

`defgrid` is an optional engine extension, not required for non-tactical games.

---

## 17. Scenes

### 17.1 Declaration

```
scene village:
  You are in the **village square**. Smoke drifts from the forge.

  [hostile-nearby?] A hostile figure lurks nearby!

  * Enter the forest
    move-to 'forest
    random-encounter
    -> forest

  * [can-afford? 40] Buy a health potion (40 gold)
    buy-item 'health-potion 40
    -> village

  * [player/has-key] Ride to the castle
    move-to 'castle
    -> castle

  * Talk to the blacksmith
    => talk-blacksmith

  * Rest here (recover 20 health)
    heal 20
    -> village
```

### 17.2 Scene State Machine

Scenes form a flat state machine, not a call stack. `engine/current-scene` and `engine/scene-stack` are discrete, engine-managed state included in the transaction log and future-state search.

- `-> name` — unconditional goto; stack unchanged
- `-> (expr)` — computed goto; `expr` must evaluate to a `SceneId`
- `=> name` — push caller onto stack; transition to `name`; return on `<-`
- `<-` — pop stack; return to the previous scene
- From transaction functions: `goto-scene!`, `enter-scene!`, `exit-scene!`

The scene stack is bounded (see `scene-stack-max` in engine config). Exceeding the bound is a runtime error. Recursive scenes (a scene that can `=>` to itself) generate a compile warning.

All scene names form an auto-generated `SceneId` enum. Scene names must be globally unique across all imported modules.

### 17.3 Computed Gotos

```
scene main:
  -> (match player/location:
        'village: 'village
        'forest:  'forest
        'castle:  'castle
        'dungeon: 'dungeon)

scene combat:
  Fighting {npcs/{combat/enemy}/name}!

  * Attack
    attack-enemy
    enemy-attacks
    -> (match combat/outcome:
          'ongoing: 'combat
          _:        'main)
```

---

## 18. Hot Reload and Live Debug

This section is part of the language specification. Conforming implementations must support it in dev mode.

### 18.1 Debug Protocol

A conforming runtime exposes a local WebSocket interface (default port 7373 in dev mode; disabled in production builds). The runtime emits events and accepts commands.

**Emitted events:**

```
mutation        {path, old, new, fn, tick}
scene-change    {from, to, stack, tick}
message-sent    {actor, msg, tick}
schedule-fired  {name, tick}
fn-call         {name, args, tick}        # dev mode only
spawn-event     {family, key, init, tick}
despawn-event   {family, key, tick}
clamp-event     {path, attempted, clamped, tick}
reload          {file, outcome, changes, tick}
```

**Accepted commands:**

```
get-state       {pattern}           → {path: value, ...}
eval            {expr}              → value
reload          {file}              → outcome
set-breakpoint  {condition}         → id
clear-breakpoint {id}
time-travel     {tick}              → frozen GameState
get-log         {from, to}          → log entries
```

### 18.2 Hot Reload Semantics

| Change type                    | Reload behaviour                                    |
|--------------------------------|-----------------------------------------------------|
| Function body changed          | Apply immediately; current state preserved           |
| New field added to type        | Initialise with declared default; log `field-added` |
| Field removed from type        | Drop value silently; log `field-removed`            |
| Enum value added               | Legal immediately                                   |
| Enum value removed             | Error if any current state holds that value         |
| Type range narrowed            | Error if current state is out of new range          |
| New state path added           | Initialised to default                              |
| Scene text changed             | Presentation layer re-renders current scene         |
| Scene choices changed          | Re-enter current scene (exit then enter)            |
| Schema version bumped          | Run migration chain (§11)                           |

### 18.3 Watch Declarations

```
watch player/health  "HP"
watch player/gold    "Gold"
watch world/turn     "Turn"
watch-when player/status = 'dead  "Player died — turn {world/turn}"
watch-when (hostile-nearby?)      "Hostile NPC nearby"
```

Watch declarations are tagged `debug-only` and stripped from production builds. The live inspector polls `get-state` on `mutation` events to refresh all watched paths.

### 18.4 Doc Strings

A string literal immediately before any `type`, `state`, `relation`, `fn`, `actor`, `schedule`, `scene`, or `bounded` declaration is attached as a doc string and surfaced in the live inspector's schema browser.

```
"The player's current hit points. Clamped to 0–100."
state player:
  "Discrete location token — determines available exits."
  location: Location = 'village
```

---

## 19. Schema Migration

### 19.1 Implicit Migration

Changes that do not require explicit migration blocks:

- New field added → initialised to declared default in all existing saves
- Field removed → value silently dropped; log entry emitted
- Enum value added → legal immediately
- New state path added → initialised to default
- New family member (uninstantiated) → starts as nil

### 19.2 Explicit Migration Blocks

```
schema-version: 3

migration 1 -> 2:
  rename player/hit-points -> player/health
  add    player/mana = 50
  drop   player/notes

migration 2 -> 3:
  transform player/level:
    fn old: old * 10          # rescale — fn body runs per-entity
  transform npcs/*/health:
    fn old: min old 100       # clamp to new range
  rename-enum player/class  'fighter -> 'warrior
```

Migration operations:

| Operation | Syntax | Description |
|-----------|--------|-------------|
| `rename`  | `rename old-path -> new-path` | Rename a state path |
| `add`     | `add path = value` | Add a new path with a value |
| `drop`    | `drop path` | Remove a path |
| `transform` | `transform path: fn old: expr` | Transform existing values |
| `rename-enum` | `rename-enum path old -> new` | Rename an enum literal in a specific path |

`storybase migrate save.log` applies outstanding migrations to a log file and writes an upgraded copy.

---

## 20. Testing

### 20.1 Verify Blocks

`verify` declarations are checked by `storybase verify`. They use the future-state search engine.

```
verify "player can always reach the castle eventually":
  from-any-state:
    can-reach? player/location = 'castle  depth: 100

verify "health is always non-negative":
  verify-always player/health >= 0

verify "buying a potion costs exactly 40 gold":
  requires player/gold >= 40
  after (buy-item 'health-potion 40):
    player/gold = player/gold@before - 40
    contains? player/inventory 'health-potion

verify "combat is always resolvable":
  when combat/active = true:
    can-reach? combat/active = false  depth: 20

verify "death is recoverable via undo":
  when player/status = 'dead:
    after undo!:
      player/status != 'dead
```

**Clauses:**

| Clause | Description |
|--------|-------------|
| `from-any-state:` | Check holds from every reachable state |
| `when <cond>:` | Restrict to states satisfying `cond` |
| `requires <cond>` | Skip verify if precondition is not met |
| `after <transition>:` | Apply transition and check result |
| `path@before` | Value of `path` before the `after` transition |

Failures report the specific state, counterexample path, and log excerpt that violated the property.

---

## 21. Counterfactual Traces

### 21.1 Basic Usage

`counterfactual` creates an **immutable branched game state** by replaying the log to a past tick and applying a sequence of transitions to a private copy.

```
let alt = counterfactual from: world/turn - 3 do:
  move-to 'forest
  random-encounter
```

`alt` is a `GameState` value. Read paths from it by prefixing with `(in-state alt)`:

```
(in-state alt) player/health
(in-state alt) player/status

if (in-state alt) player/health < player/health:
  "That path would have cost you more."
```

### 21.2 Querying Counterfactual States

All pure query operations accept `(in-state gs)` to redirect reads:

```
can-reach? (in-state alt) player/status = 'dead  depth: 20

find npc
  in-state: alt
  where     npcs/{npc}/disposition = 'hostile
```

### 21.3 Semantics

- `GameState` values are **immutable and ephemeral** — no side effects; garbage-collected when they leave scope.
- Actors and scheduled events do **not** run in a counterfactual by default. Use `simulate: true` to include them:
  ```
  let alt = counterfactual from: world/turn  simulate: true  do:
    move-to 'forest
  ```
- Counterfactuals may be nested; nesting depth is bounded (see `max-counterfactual-depth` in engine config).
- Counterfactuals are logged as `counterfactual(from: T, transitions: [...])` entries, visible in the debug timeline.

### 21.4 NPC Planning

Actors may use counterfactuals inside `bounded` computations to evaluate options before committing. Since `bounded` is treated as random by the search engine, this does not cause unbounded search branching:

```
bounded evaluate-options npc:
  returns:      BestAction
  distribution: uniform
  reads:        [player/location, npcs/{npc}/*]
  lua:          "game.ai.evaluate_options"
  # Lua receives a state snapshot and may call storybase.counterfactual()
```

---

## 22. Lua Interop

### 22.1 Overview

StoryBase compiles to a Lua table representation consumed by the StoryBase runtime library. The compiler is also written in Lua (with LPEG for parsing). Lua code can call StoryBase functions, read state, and subscribe to events.

```lua
local sb = require("storybase")
local game = sb.load("game.sb")

-- Call a transaction function
game:call("move-to", "'forest")

-- Read state
local health = game:get("player/health")
local loc    = game:get("player/location")

-- Run a query
local hostiles = game:find("npc", {
  where  = "npcs/{npc}/disposition = 'hostile",
  within = {hops=3, relation="exits", from="player/location"},
  limit  = 5
})

-- Subscribe to events
game:on("mutation", function(ev)
  print(ev.path, ev.old, "->", ev.new)
end)

game:on("scene-change", function(ev)
  render_scene(ev.to)
end)

-- Send player input
game:choose(2)               -- player selected choice index 2
game:eval("pickup-item 'key")
```

### 22.2 Bounded Computations

Bounded computation handlers are registered as plain Lua functions:

```lua
game:register_bounded("game.ai.assess_threat", function(npc, state)
  -- state is a read-only table of the paths declared in reads:
  local hp   = state["player/health"]
  local disp = state["npcs/" .. npc .. "/disposition"]
  -- return a value of the declared returns: type
  if hp < 20 then return "hostile" else return "neutral" end
end)
```

The runtime calls this function synchronously during the turn and logs the result exactly like a random draw.

### 22.3 Counterfactual API from Lua

```lua
game:register_bounded("game.ai.evaluate_options", function(npc, state)
  -- Use the storybase counterfactual API to evaluate options
  local alt = game:counterfactual({from = state["world/turn"]}, function(g)
    g:call("move-to", "'forest")
  end)
  local future_health = alt:get("player/health")
  return future_health > 50 and "cooperate" or "defect"
end)
```

---

## 23. Macro System

StoryBase supports a hygienic macro system for compile-time code generation. Macros expand before type-checking.

```
macro with-combat-check body:
  when combat/active = false:
    error "with-combat-check called outside combat"
  body

macro repeat-n n body:
  let i = 0:
    while i < n:
      body
      set! i (i + 1)
```

Macros expand before type-checking. A macro body may not expand other macros defined in the same compilation unit (use separate files). The expanded form is what the type checker and log see.

---

## 24. Standard Library Reference

### Core

| Name          | Signature              | Notes                        |
|---------------|------------------------|------------------------------|
| `min`         | `Int Int → Int`        |                              |
| `max`         | `Int Int → Int`        |                              |
| `abs`         | `Int → Int`            |                              |
| `clamp`       | `Int Int Int → Int`    | `clamp val lo hi`            |
| `not`         | `Bool → Bool`          |                              |
| `and`         | `Bool Bool → Bool`     | short-circuit                |
| `or`          | `Bool Bool → Bool`     | short-circuit                |
| `str`         | `... → String`         | concatenate any values       |
| `int-to-str`  | `Int → String`         |                              |
| `str-to-int`  | `String → Option(Int)` |                              |

### Collections

| Name           | Signature                    | Notes |
|----------------|------------------------------|-------|
| `contains?`    | `Set(T) T → Bool`            |       |
| `size`         | `Set(T) → Int`               |       |
| `empty?`       | `Set(T) → Bool`              |       |
| `union`        | `Set(T) Set(T) → Set(T)`     |       |
| `intersect`    | `Set(T) Set(T) → Set(T)`     |       |
| `list-get`     | `List(T) Int → Option(T)`    |       |
| `list-size`    | `List(T) → Int`              |       |
| `any?`         | `List(T) (T→Bool) → Bool`    |       |
| `all?`         | `List(T) (T→Bool) → Bool`    |       |
| `count-where`  | `List(T) (T→Bool) → Int`     |       |

### Paths

| Name              | Notes                                                    |
|-------------------|----------------------------------------------------------|
| `path-exists? path` | `Bool` — true if the path is instantiated (not nil)   |
| `path-list family`  | `List(SymbolOf(family))` — all instantiated keys      |

### Engine

| Name                   | Notes                                          |
|------------------------|------------------------------------------------|
| `engine/current-scene` | `SceneId`                                      |
| `engine/scene-stack`   | `List(SceneId, 16)`                            |
| `engine/tick`          | `Int` — current tick                           |
| `engine/time`          | Full time tuple                                |
| `engine/checkpoint!`   | Insert a checkpoint at the current tick        |
| `engine/emit`          | Emit an event to the debug/presentation layer  |

---

## 25. Complete Example

A small RPG demonstrating the major language features.

```
# ============================================================
# game.sb  —  StoryBase V1.0 complete example
# ============================================================

module main-game
  version: 1.0

schema-version: 1

time-model:
  axes: [day, hour, tick]
  wrap: [none, 24, none]

engine-config:
  entry-scene: main
  scene-stack-max: 16
  debug-port: 7373

# ============================================================
# TYPES
# ============================================================

type Status       = alive | dead | unconscious
type Disposition  = friendly | neutral | hostile
type Location     = village | forest | dungeon | castle
type CharClass    = warrior | rogue | mage
type ItemKind     = health-potion | iron-ore | iron-blade | key
type QuestFlag    = ore-delivered | goblin-defeated | found-crown
type CombatResult = ongoing | victory | defeat
type EnemyKind    = goblin | skeleton | wanderer
type Chapter      = intro | middle | finale

type Health = Int(0, 100)
type Gold   = Int(0, 9999)
type Damage = Int(0, 999)

type Entity:
  health:   Health   = 50
  status:   Status   = 'alive
  location: Location = 'village
  name:     String   = "Unknown"

type Npc:
  with Entity
  disposition: Disposition = 'neutral

type Player:
  with Entity
  health:      Health              = 100
  mana:        Int(0, 50)          = 50
  gold:        Gold                = 30
  class:       CharClass           = 'warrior
  has-key:     Bool                = false
  inventory:   Set(ItemKind, 10)   = (set)
  quest-flags: Set(QuestFlag, 20)  = (set)
  description: String              = ""

type ActorMsg:
  | alert:          threat: NpcId, location: Location
  | trade-offer:    item: ItemKind, price: Gold
  | attack-request: target: NpcId, damage: Damage

# ============================================================
# STATE
# ============================================================

"The player character."
state player: Player = Player(name: "Hero")

"Spawned NPCs. Maximum 20 concurrent."
state npcs/{npc}: Npc  max: 20

state world:
  turn:    Int(0, 9999) = 0
  chapter: Chapter      = 'intro

state combat:
  active:  Bool         = false
  enemy:   NpcId        = 'wanderer
  outcome: CombatResult = 'ongoing

# ============================================================
# RELATIONS
# ============================================================

"Navigation graph between locations."
relation exits: Location -> Set(Location, 6):
  'village: {'forest}
  'forest:  {'village, 'dungeon}
  'dungeon: {'forest, 'castle}
  'castle:  {'village}

# ============================================================
# SCHEDULING
# ============================================================

schedule morning-reset:
  every:  [day: +1]
  offset: [hour: 6]
  fn:
    for npc in (path-list npcs):
      set! npcs/{npc}/location 'village
    set! npcs/blacksmith/disposition 'friendly

# ============================================================
# ACTORS
# ============================================================

"The village blacksmith."
actor blacksmith:
  state:     npcs/blacksmith
  perceives: [world/turn, player/location, player/quest-flags,
               npcs/blacksmith/*]
  inbox:     List(ActorMsg, 8)
  behavior:  blacksmith-behavior
  priority:  10

"The village gate guard."
actor guard:
  state:     npcs/guard
  perceives: [player/location, npcs/*/location, npcs/guard/*]
  inbox:     List(ActorMsg, 8)
  behavior:  guard-behavior
  priority:  20

# ============================================================
# PURE FUNCTIONS
# ============================================================

fn alive? entity:
  npcs/{entity}/status = 'alive

fn can-afford? price:
  player/gold >= price

fn hostile-nearby?:
  (find npc
    where  npcs/{npc}/location = player/location
    and    npcs/{npc}/disposition = 'hostile
    count) > 0

fn base-damage:
  match player/class:
    'warrior: 15
    'rogue:   12
    'mage:     8

fn quest-complete?:
  (contains? player/quest-flags 'goblin-defeated)
  and (contains? player/quest-flags 'found-crown)
  and player/location = 'castle

# ============================================================
# TRANSACTION FUNCTIONS
# ============================================================

fn move-to loc:
  pre:  player/status = 'alive
  set!  player/location loc
  time-inc! tick:

fn take-damage amount:
  pre:
    amount > 0
    player/status = 'alive
  post:
    player/health >= 0
  dec!  player/health amount
  when  player/health <= 0:
    set! player/status 'dead
    set! player/description "You have fallen."

fn heal amount:
  pre:  player/status = 'alive
  inc!  player/health (min amount (100 - player/health))

fn pickup-item item:
  pre:  not (contains? player/inventory item)
  post: contains? player/inventory item
  add!  player/inventory item
  add!  player/quest-flags item

fn buy-item item price:
  pre:  can-afford? price
  post: player/gold = player/gold@before - price
  dec!  player/gold price
  pickup-item item

fn enter-combat enemy:
  tags: [checkpoint]
  set!  combat/active  true
  set!  combat/enemy   enemy
  set!  combat/outcome 'ongoing
  goto-scene! 'combat

fn attack-enemy:
  pre:  combat/active = true
  let base  = base-damage
      roll  = (random-int 0 10)
      total = base + roll:
    dec!  npcs/{combat/enemy}/health total
    set!  player/description (str "You deal " total " damage.")
    when  npcs/{combat/enemy}/health <= 0:
      set!  npcs/{combat/enemy}/status 'dead
      set!  combat/outcome 'victory
      inc!  player/gold (random-int 10 30)

fn enemy-attacks:
  let dmg = (random-int 5 15):
    take-damage dmg
    when player/status = 'dead:
      set! combat/outcome 'defeat

fn random-encounter:
  when (random-bool 0.25):
    let kind = (random-enum EnemyKind):
      spawn! npcs 'wanderer Npc(status: 'alive, health: 30,
                                location: player/location,
                                disposition: 'hostile)
      enter-combat 'wanderer

fn deliver-ore:
  pre:  contains? player/quest-flags 'iron-ore
  remove! player/inventory 'iron-ore
  add!    player/quest-flags 'ore-delivered
  set!    npcs/blacksmith/disposition 'friendly

fn end-chapter:
  when quest-complete?:
    set! world/chapter 'finale
    inc! player/gold 500

# ============================================================
# ACTOR BEHAVIORS
# ============================================================

fn blacksmith-behavior:
  when player/location = 'village:
    set! npcs/blacksmith/disposition 'friendly
  for msg in npcs/blacksmith/inbox:
    match msg:
      alert {threat, location}:
        set! npcs/blacksmith/disposition 'hostile
        send! guard (ActorMsg/attack-request target: threat, damage: 10)
      trade-offer {item, price}:
        when player/gold >= price:
          dec! player/gold price
          add! player/inventory item
      _: pass

fn guard-behavior:
  for msg in npcs/guard/inbox:
    match msg:
      attack-request {target, damage}:
        set! npcs/guard/disposition 'hostile
      _: pass

# ============================================================
# SCENES
# ============================================================

scene main:
  -> (match player/location:
        'village: 'village
        'forest:  'forest
        'castle:  'castle
        'dungeon: 'dungeon)

scene village:
  You are in the **village square**. The smell of bread and coal smoke drifts on the air.

  [hostile-nearby?] A hostile figure lurks nearby!

  * Enter the forest
    move-to 'forest
    random-encounter
    -> forest

  * [can-afford? 40] Buy a health potion (40 gold)
    buy-item 'health-potion 40
    -> village

  * [can-afford? 200  and  contains? player/quest-flags 'ore-delivered]
    Collect your iron blade from the blacksmith (200 gold)
    buy-item 'iron-blade 200
    -> village

  * [player/has-key] Ride to the castle
    move-to 'castle
    -> castle

  * Talk to the blacksmith
    => talk-blacksmith

  * Rest here (recover 20 health)
    heal 20
    -> village

scene forest:
  You stand in the **dark forest**. The trees press in on all sides.

  * [not (contains? player/quest-flags 'goblin-defeated)]
    Press deeper — into the dungeon
    move-to 'dungeon
    -> dungeon

  * Return to the village
    move-to 'village
    -> village

scene dungeon:
  The dungeon is dark and cold. Water drips somewhere in the distance.

  * Explore further
    random-encounter
    -> dungeon

  * Return to the forest
    move-to 'forest
    -> forest

scene castle:
  You stand before the castle gates.

  * [quest-complete?] Present the crown to the king
    end-chapter
    -> castle

  * Return to the village
    move-to 'village
    -> village

scene combat:
  Fighting {npcs/{combat/enemy}/name}!
  Your health: {player/health}.  Enemy health: {npcs/{combat/enemy}/health}.

  * Attack
    attack-enemy
    enemy-attacks
    -> (match combat/outcome:
          'ongoing: 'combat
          _:        'main)

  * [contains? player/inventory 'health-potion] Use health potion
    remove! player/inventory 'health-potion
    heal 40
    enemy-attacks
    -> (match combat/outcome:
          'ongoing: 'combat
          _:        'main)

  * [can-afford? 10] Flee (lose 10 gold)
    dec!  player/gold 10
    set!  combat/active false
    -> main

scene talk-blacksmith:
  The blacksmith looks you over with a practiced eye.

  * [not (contains? player/quest-flags 'ore-delivered)]
    "Bring me iron ore and I'll forge you a blade."
    -> talk-blacksmith

  * [contains? player/inventory 'iron-ore] Deliver the iron ore
    deliver-ore
    <-

  * Farewell
    <-

# ============================================================
# WATCHES  (dev mode only — stripped from production builds)
# ============================================================

watch player/health  "HP"
watch player/gold    "Gold"
watch world/turn     "Turn"
watch world/chapter  "Chapter"
watch-when player/status = 'dead  "Player died — turn {world/turn}"

# ============================================================
# TESTS
# ============================================================

verify "player can always reach the castle eventually":
  from-any-state:
    can-reach? player/location = 'castle  depth: 100

verify "health is always non-negative":
  verify-always player/health >= 0

verify "buying a potion costs exactly 40 gold":
  requires player/gold >= 40
  after (buy-item 'health-potion 40):
    player/gold = player/gold@before - 40
    contains? player/inventory 'health-potion

verify "combat is always resolvable":
  when combat/active = true:
    can-reach? combat/active = false  depth: 20

verify "death is recoverable via undo":
  when player/status = 'dead:
    after undo!:
      player/status != 'dead
```

# Language Reference

Complete StoryBase syntax specification. For an introduction see the [tutorials](../tutorial/01_hello_world.md).

---

## Table of Contents

1. [Lexical Rules](#lexical-rules)
2. [Declarations](#declarations)
3. [Type Expressions](#type-expressions)
4. [Expressions](#expressions)
5. [Statements](#statements)
6. [Scene Syntax](#scene-syntax)
7. [Dialogue and Speaker System](#dialogue-and-speaker-system)
8. [Type System](#type-system)
9. [Path Syntax](#path-syntax)
10. [Module System](#module-system)
11. [Error Codes](#error-codes)

---

## Lexical Rules

### Comments

```
# This is a comment. Everything to end-of-line is ignored.
```

### Booleans

```
true   false
```

### Integer literals

```
42   -7   0
```

### Float literals (superficial only)

```
3.14   -0.5   1.0e3
```

Floats are *superficial* — they cannot appear in conditional expressions or drive game logic.

### String literals (superficial only)

```
"hello, world"
"line one\nline two"
```

**Multi-line strings** strip indentation to the column of the opening `"""`:

```
"""
  The forest is dark and cold.
  A distant horn echoes through the trees.
"""
```

### Symbol literals

```
'sword   'alive   'blacksmith   'warrior
```

Symbols are quoted with `'`. They are discrete values with no intrinsic meaning; their type is inferred from context.

### Paths

Any token containing `/` is a path:

```
player/health
npcs/blacksmith/disposition
world/chapter
```

### Path interpolation

`{varname}` splices a variable into a path segment:

```
npcs/{npc}/health
zones/{zone}/discovered
```

The variable must be typed as a family key (`SymbolOf(Family)`).

### Named arguments

Named arguments use `name: value` syntax:

```
depth: 20
range: 5
by: min-turns
```

### Naming conventions

| Convention | Applies to |
|-----------|-----------|
| `CamelCase` | Type names: `CharClass`, `Health`, `ActorMsg` |
| `kebab-case` | Functions, state paths, scenes, variables |
| Ends with `?` | Functions returning Bool or testing a condition |
| Ends with `!` | Mutation primitives |

### Indentation layout

All block structure is determined by indentation. Parentheses `(...)` are for inline grouping only and never open a block. A form that does not close on its opening line uses the indented block beneath it as its body.

```
fn take-damage amount:
  dec!  player/health amount
  when  player/health <= 0:
    set! player/status 'dead
```

---

## Declarations

Declarations appear at the top level of a `.sb` file, in any order (the compiler resolves names in multiple passes).

A **doc string** — a string literal immediately before any declaration — is attached to that declaration:

```
"The player's persistent game state."
state player: Player = Player(name: "Hero")
```

### `module`

```
module combat
  version: 1.2
  exports: [enter-combat, exit-combat, CombatState]
```

Optional. One per file. Declares the module name, schema version, and exported names. If `exports:` is omitted, all top-level names are exported.

### `import`

```
import "combat.sb"              # flat — all names available unqualified
import "enemies.sb" as E        # namespaced — E.Npc, E.spawn-enemy
import "shared/items.sb"        # relative path from importing file
```

Import cycles are a compile error (`IMPORT_CYCLE`). State paths declared in imported modules are always global.

### `schema-version`

```
schema-version: 3
```

Declares the current schema version. The migration system uses this to apply outstanding `migration` blocks when loading saves.

### `engine-config`

```
engine-config:
  entry-scene:              village      # required: first scene shown
  scene-stack-max:          16           # maximum => / <- depth
  max-counterfactual-depth: 3
  strict-contracts:         false        # keep pre:/post: in production builds
  debug-port:               7373         # TCP port for debug server
  npc-speed:                1            # extra autonomous turns per player turn
```

All keys are optional except `entry-scene`.

### `time-model`

```
time-model:
  axes: [day, hour, minute, tick]
  wrap: [none, 24, 60, none]    # cyclic axes wrap at N; none = no wrap
```

Omit `wrap:` for non-cyclic time. Axis names are arbitrary identifiers.

### `type`

**Enum:**

```
type Status   = alive | dead | unconscious
type Location = village | forest | dungeon | castle
```

**Range alias:**

```
type Health = Int(0, 100)
type Gold   = Int(0, 9999)
```

**Record:**

```
type Entity:
  health:   Health   = 50
  status:   Status   = 'alive
  name:     String   = "Unknown"

type Npc:
  with Entity                     # mixin: splice all Entity fields here
  disposition: Disposition = 'neutral
```

`with OtherRecord` splices all fields from `OtherRecord`. Fields after `with` may override defaults but not types. Multiple `with` clauses are allowed; conflicting names from two different `with` sources are a compile error.

**Variant:**

```
type ActorMsg:
  | alert:       threat: NpcId, location: Location
  | trade-offer: item: ItemKind, price: Gold
  | stand-down:
```

Each branch is an anonymous record. State-space size is the sum of all branch sizes.

### `state`

**Scalar:**

```
state world/turn: Int(0, 9999) = 0
```

**Record block:**

```
state player:
  health: Health = 100
  gold:   Gold   = 30
  class:  Class  = 'warrior
```

**Named record type:**

```
state player: Player = Player(health: 100, gold: 30)
```

**Entity family:**

```
state npcs/{npc}: Npc  max: 20
```

`max: N` bounds the number of simultaneously live instances. `{npc}` is auto-typed as `SymbolOf(npcs)`.

### `relation`

```
"Movement graph between locations."
relation exits: Location -> Set(Location, 6):
  'village: {'forest}
  'forest:  {'village, 'dungeon}
  'dungeon: {'forest, 'castle}
```

The static data block is optional. Relations can be populated at runtime with `relate!` / `unrelate!`.

### `fn`

```
fn function-name arg1 arg2:
  body
```

```
fn heal amount:
  pre:  player/status = 'alive
  post: player/health <= player/health@before + amount
  inc!  player/health (min amount (100 - player/health))
```

- `pre:` — preconditions checked before the body runs.
- `post:` — postconditions checked after. `path@before` refers to the value of `path` before the call.
- `tags: [checkpoint, reversible]` — attach function tags.

Functions are automatically classified as **transaction** (calls mutations) or **pure** (no mutations). The compiler infers this and enforces it.

### `actor`

```
actor captain:
  state:     garrison
  perceives: [garrison/alert, garrison/morale, castle/hp]
  inbox:     List(CaptainMsg, 8)
  behavior:  captain-behavior
  priority:  10
```

| Field | Required | Description |
|-------|----------|-------------|
| `state:` | Yes | State path prefix for this actor's own state |
| `perceives:` | Yes | List of path patterns the behavior function may read |
| `inbox:` | Yes | Typed message inbox: `List(MsgType, max)` |
| `behavior:` | Yes | Name of the transaction function called each turn |
| `priority:` | No | Integer; higher wins conflict resolution (default 0) |

### `schedule`

```
schedule attacker-wave:
  every:  [turn: +2]
  offset: [turn: 0]
  fn:
    dec! castle/hp 30
```

| Field | Description |
|-------|-------------|
| `every:` | Fire every N time units: `[axis: +N]` |
| `at:` | Fire once at an absolute or relative time |
| `offset:` | Initial delay before the first `every:` fire |
| `fn:` | Transaction function body (inline or function name) |

### `verify`

```
verify "castle hp stays non-negative":
  verify-always castle/hp >= 0

verify "player always has an exit":
  from-any-state:
    when player/location = 'dungeon:
      can-reach? player/location = 'forest
```

Verify blocks are stripped from production builds.

Clause kinds:

| Clause | Description |
|--------|-------------|
| `verify-always <cond>` | BFS: condition holds in all reachable states |
| `after (<fn> <args>): <assertions>` | Apply a function call; check assertions on the result |
| `requires: <cond>` | Precondition for skipping an `after` check |
| `from-any-state: when <cond>: <check>` | Check `<check>` from every state where `<cond>` holds |

### `watch`

```
watch player/health "health changed"
watch-when player/health <= 0 "player died"
```

Register a watch expression. In debug mode the `watch-fired` event is emitted to connected clients whenever the condition becomes true (positive edge). Stripped from production builds.

### `bounded`

```
bounded classify-intent text:
  returns:      PlayerIntent
  distribution: uniform
  reads:        []
  lua:          "game.nlp.classify_intent"
```

Declares a Lua-backed bounded computation whose output is treated as a discrete value. The search engine branches over all possible return values.

### `defgrid`

```
defgrid world-map:
  dimensions: Int(0, 30) x Int(0, 30)
  cell-type:  TileKind
```

Declares a tile grid. See [`docs/reference/tile_grid.md`](tile_grid.md).

### `migration`

```
migration 2 -> 3:
  rename player/xp player/experience
  add    player/prestige: Int(0, 10) = 0
  drop   player/old-flag
```

Applied in order when loading a save with an older schema version. See the [schema migration how-to](../howto/schema_migration.md).

### `speaker`

```
speaker aldric:
  display: "Aldric the Bold"
  color:   "#c8a96e"
```

Declares optional UI metadata for a named speaker. Both fields are optional.

| Field | Description |
|-------|-------------|
| `display:` | Human-readable name shown in the UI (string) |
| `color:` | CSS hex color for the speaker's name or bubble (string) |

Speakers do not need to be declared to be used in `say` statements — an undeclared speaker emits an `INFO` hint at compile time but is not an error. Declared speakers make the metadata available to the Lua embedding API.

### `hook`

Hooks execute additional code before or after specific functions, or before/after all functions carrying a given tag.

**Function-level hooks** (by function name):

```
hook before: attack:
  inc! world/pre-attack-count 1

hook after: attack:
  when player/health <= 0:
    set! player/status 'dead
```

`hook before: fn-name:` — body runs before `fn-name` executes.
`hook after: fn-name:` — body runs after `fn-name` executes.

**Tag-level hooks** (by function tag):

```
hook combat: pre:
  log-combat-start

hook combat: post:
  check-victory-condition
```

`hook tag-name: pre:` — body runs before every function tagged `[combat]`.
`hook tag-name: post:` — body runs after every function tagged `[combat]`.

In an `after:` or `post:` hook body, the `changes` variable is bound to a list of `{path, old, new}` tables describing every state mutation made during the hooked function's execution.

### `macro`

```
macro hurt-player amount:
  dec! player/health amount
  when player/health <= 0:
    set! player/status 'dead
```

Macros are inlined at each call site. They may not be recursive.

---

## Type Expressions

### Discrete types

| Syntax | Description | State-space size |
|--------|-------------|-----------------|
| `Bool` | Boolean | 2 |
| `Int(min, max)` | Bounded integer | `max - min + 1` |
| `Enum(a, b, c)` | Inline anonymous enum | N values |
| `Option(T)` | T or nil | `|T| + 1` |
| `Set(T, max)` | Bounded set | Σ C(|T|, i) for i = 0..max |
| `List(T, max)` | Bounded ordered list | `(|T| + 1)^max` |
| `Symbol` | Untyped symbol (avoid; emits warning) | ∞ |
| `SymbolOf(Family)` | Typed entity-family key | `|Family|` |
| `TypeName` | Named enum, record, or variant | product / sum of fields |

### Superficial types

| Syntax | Description |
|--------|-------------|
| `String` | Text (display only) |
| `Float` | Floating-point number (display/audio only) |
| `UList(T)` | Unbounded ordered list |
| `UMap(K, V)` | Unbounded map |

Superficial values may never appear in conditional expressions or drive game logic.

`UList` supports `push!`, `pop!`, `size`, `count`, and `for` iteration. The `UMap` type must be declared as a named type alias before use in state declarations. `UMap` supports:

| Operation | Description |
|-----------|-------------|
| `map-set! path key value` | Set a key in a UMap |
| `map-delete! path key` | Remove a key from a UMap |
| `(map-get path key)` | Read a value (nil if absent) |
| `(map-size path)` | Number of entries |
| `(map-keys path)` | List of all keys |

### Function types

```
(T -> R)          # one argument T, returns R
(T U -> R)        # two arguments
```

Used in `fn` parameter declarations and lambda expressions.

---

## Expressions

### Operator precedence (high → low)

| Operator | Description |
|----------|-------------|
| `*` `/` | Multiplication, division |
| `+` `-` | Addition, subtraction |
| `=` `!=` `<` `>` `<=` `>=` | Comparisons (infix) |
| `not` | Logical negation (prefix) |
| `and` | Logical AND |
| `or` | Logical OR |
| `??` | Nil-coalescing (right side only if left is nil) |

### Literals

```
42          # Int literal
3.14        # Float literal
true        # Bool literal
"hello"     # String literal
'sword      # Symbol literal
```

### Path expressions

```
player/health
npcs/{npc}/status
world/gold
```

Evaluating a path reads its current value from the state store.

### `path@before`

In `post:` blocks only: the value of `path` at the start of the function call.

```
post: player/gold = player/gold@before - price
```

**Propagation into called functions:** The `path@before` snapshot is also available inside functions called from within `post:` blocks or postcondition expressions. This means a helper function called during postcondition evaluation can read `path@before` values from the outer function's snapshot. This behaviour is intentional and allows postcondition logic to be factored into shared helpers.

### Arithmetic and comparisons

```
player/health + 10
base * 2 + modifier
count > 0  and  player/alive?
```

### Nil-coalescing

```
npcs/{npc}/health ?? 0    # 0 if npc is not spawned
player/companion ?? 'none
```

### Function calls (prefix)

```
can-afford? 40
min a b
count-where (path-list npcs) fn(m): npcs/{m}/alive = true
```

### `if` expression

```
if player/health > 50: "healthy" else: "hurt"
```

### `match` expression

```
match player/class:
  'warrior: 15
  'rogue:   12
  'mage:     8
  _:         0
```

`_` is the wildcard / default branch.

### `cond` expression

```
cond:
  player/health <= 0: 'dead
  player/health < 20: 'hurt
  _:                  'healthy
```

### `find` expression

```
find npc
  where    npcs/{npc}/disposition = 'hostile
  order-by npcs/{npc}/health asc
  limit    3
```

Returns a `List(SymbolOf(npcs), 3)` of matching keys.

| Clause | Description |
|--------|-------------|
| `where <cond>` | Filter by condition (multiple `where` are ANDed) |
| `or-where <cond>` | Disjunction with previous `where` |
| `within N hops of <rel> from <src>` | Reachability filter |
| `order-by <path> asc\|desc` | Sort result |
| `limit N` | Cap result size |
| `count` | Return an integer instead of a list |

### `counterfactual` expression

```
let alt = counterfactual do:
  heal 50
  move-to 'castle
(in-state alt) player/health
```

Forks a copy of the current state, applies the `do:` block (a list of function calls), and returns a frozen snapshot. Read values from the snapshot with `(in-state <var>) <path>`. The live state is unchanged.

Optional `from:` clause replays the transaction log to a past tick before applying mutations:

```
let alt = counterfactual from: (world/turn - 3) do:
  heal 50
(in-state alt) player/health
```

Optional `simulate: true` runs one round of actor and scheduler activity after the mutations:

```
let alt = counterfactual simulate: true do:
  spawn-enemy
(in-state alt) combat/active
```

`counterfactual` is pure — it may only be used in pure functions (no mutations in the outer scope).

### Lambda expressions

```
fn(x): x > 0
fn(item): contains? player/inventory item
fn(npc):
  npcs/{npc}/status = 'alive
  and npcs/{npc}/disposition = 'hostile
```

Single-expression or multi-line. Lambdas are always pure.

### Collection literals

```
{'sword, 'potion}       # Set literal
['north, 'east]         # List literal
{name: "Aldric", hp: 80} # Map literal
(set)                   # empty Set
[]                      # empty List
{}                      # empty Map
```

**Parser rule:** `{...}` with the first element followed by `:` is a map; otherwise it is a set. `{}` is always an empty map; `(set)` is always an empty set.

### Index and slice

```
player/waypoints[0]     # first element
player/waypoints[-1]    # last element
player/waypoints[1:4]   # elements 1–3 (0-based, end exclusive)
```

### Collection builtins

| Builtin | Arguments | Returns | Description |
|---------|-----------|---------|-------------|
| `contains? coll item` | collection, any | Bool | True if item is in the collection |
| `not-in? item coll` | any, collection | Bool | True if item is **not** in the collection |
| `empty? coll` | collection | Bool | True if the collection has no elements |
| `count coll` | collection | Int | Number of elements |
| `size coll` | collection | Int | Alias for `count` |
| `union a b` | Set, Set | Set | Elements in either set (no duplicates) |
| `intersect a b` | Set, Set | Set | Elements in both sets |
| `difference a b` | Set, Set | Set | Elements in `a` but not `b` |

`not-in? item coll` is sugar for `not (contains? coll item)` and reduces double-negative noise in guards.

---

## Statements

All mutation primitives are valid only inside transaction functions. Each call produces a log entry.

### `set!`

```
set! path value
```

Assign `value` to `path`.

### `inc!` / `dec!`

```
inc! player/health 10
dec! player/gold cost
```

Add or subtract a value. For `Int(min, max)` paths, clamps to the declared range (saturation arithmetic).

### `add!` / `remove!`

```
add!    player/inventory 'sword
remove! player/inventory 'key
```

Add or remove a value from a `Set`.

### `push!` / `pop!`

```
push! player/history 'dungeon
pop!  player/history
```

Append to or remove the last element from a `List`. `push!` is a runtime error if the list is full.

### `clear!`

```
clear! player/inventory
```

Empty a `Set` or `List`.

### `relate!` / `unrelate!`

```
relate!   exits 'forest 'dungeon
unrelate! exits 'forest 'dungeon
```

Add or remove an edge from a `relation`.

### `spawn!` / `despawn!`

```
spawn!   npcs 'blacksmith Npc(name: "Aldric", health: 80)
despawn! npcs 'blacksmith
```

Create or destroy an entity family member.

### `send!`

```
send! captain (CaptainMsg/raise-alert level: 'battle)
```

Enqueue a typed message to an actor's inbox. Delivered at the start of the next turn's message-delivery step.

### `time-inc!`

```
time-inc! tick:
time-inc! day: 1, tick: 3
```

Advance time. Uses the time axes declared in `time-model`.

### `schedule!` / `cancel-schedule!`

```
schedule!        'patrol  every: [tick: +10]  fn: patrol-route
cancel-schedule! 'patrol
```

Create or cancel a dynamic (runtime) schedule.

### `goto-scene!` / `enter-scene!` / `exit-scene!`

```
goto-scene!  'combat
enter-scene! 'talk-npc
exit-scene!
```

Imperative scene navigation from inside a transaction function. Equivalent to `->`, `=>`, `<-` in scene bodies.

### `undo!`

```
undo!
undo! steps: 3
```

Revert state to the most recent checkpoint (or `steps:` checkpoints ago). Does not erase log entries; appends an `undo` event.

### `engine/checkpoint!`

```
engine/checkpoint!
engine/checkpoint! my-fn-name
```

Push an explicit checkpoint into the transaction log. The optional argument overrides the checkpoint label (defaults to the enclosing function name). Used together with `undo!`.

### `engine/emit`

```
engine/emit event-name
engine/emit event-name arg1 arg2
```

Fire a named event. In debug mode the event is broadcast to connected debug clients (TCP and SSE). When using the Lua embedding API, the event is delivered to any `game:on("event-name", handler)` listeners registered with `game:on()`.

### `let`

```
let base  = base-damage
    roll  = (random-int 0 10)
    total = base + roll:
  dec! player/health total
```

Sequential local bindings. Each binding may reference previous ones.

**Free (no-body) form:** omit the `:` and body to bind a variable into the enclosing function scope for the remainder of that function:

```
let x = (random-int 1 20)
let bonus = x + modifier
set! player/total bonus
```

Multiple free `let` statements accumulate in the same scope; each can reference those above it.

### `for`

```
for npc in (path-list npcs):
  when npcs/{npc}/alive:
    set! npcs/{npc}/location 'village
```

Iterate over a list or `path-list`.

**`else` clause:** an optional `else:` block executes when the collection is empty (the loop body never ran):

```
for item in world/items:
  process item
else:
  set! world/result 'none
```

### `while`

```
while combat/active and player/status = 'alive:
  attack-enemy
  enemy-attacks
```

Loop while condition holds. Body may call mutation primitives.

**Iteration safety limit:** `while` loops are capped at 10,000 iterations. Exceeding this limit raises a runtime error (`while loop exceeded 10000 iteration safety limit`). Infinite-loop bugs are caught rather than silently truncating state.

### `break` and `continue`

```
for item in player/inventory:
  if item = 'key:
    break
  process-item item

while world/ticks < 100:
  inc! world/ticks 1
  if world/ticks = 50:
    continue
  do-work
```

`break` exits the innermost `for` or `while` loop immediately. `continue` skips the remaining body of the current iteration and proceeds to the next one.

### `return`

```
fn classify n:
  if n > 50:
    return 'high
  return 'low
```

`return expr` exits a function early and returns the given value. Execution of subsequent statements in the function body is skipped. Without an early `return`, a function's return value is the result of the last expression-type statement.

### `when`

```
when player/health <= 0:
  set! player/status 'dead
```

Conditional execution without an else branch.

### `if` / `else`

```
if player/has-key:
  set! combat/active true
else:
  set! player/description "You need a key."
```

### `match` (statement)

```
match player/class:
  'warrior:
    inc! player/health 20
  'mage:
    inc! player/mana 10
  _:
    pass
```

### `say` (function body)

Emit attributed dialogue from inside a function or macro body.

```
say 'aldric "Ready when you are, Commander."
say 'mira   "The wind is right for travel today."
say (player/companion) "I'll scout ahead."
```

**Syntax:** `say <speaker> <text-expr>`

The speaker may be a symbol literal (`'name`), an identifier, or a parenthesised expression that resolves to a symbol at runtime. The text is a string literal or interpolated string. Dialogue objects emitted inside function bodies are prepended to the narration of the scene that called the function.

### `pass`

```
pass
```

No-op. Useful as an empty branch body.

---

## Scene Syntax

```
scene village:
  Narration text here.

  [hostile-nearby?] A hostile figure lurks nearby!

  * Enter the forest
    move-to 'forest
    -> forest

  * [can-afford? 40] Buy a potion (40 gold)
    buy-item 'health-potion 40
    -> village

  * Talk to the blacksmith
    => talk-blacksmith
```

### Narration lines

Plain text lines are narration. They are sent to the presentation layer as-is.

Inline expressions use `{expr}`:

```
Your health: {player/health}.
Fighting {npcs/{combat/enemy}/name}!
```

### Conditional narration

```
[condition] Text shown only when condition is true.
```

This is not a choice — the text is shown or hidden but cannot be selected.

### `when` in scene bodies

```
when player/health < 20:
  The walls are crumbling.
```

Multi-line conditional narration block.

### `if` / `else` in scene bodies

```
if player/gold >= 200:
  A wealthy merchant indeed.
else:
  You could have done better.
```

### `say` in scene bodies

Emit attributed dialogue inline within a scene. Two forms are supported.

**Inline form** — single line:

```
say aldric: Ready when you are, Commander.
say mira:   The wind is right for travel today.
say (player/companion): I'll scout ahead. Stay close.
```

**Block form** — multiple lines attributed to the same speaker:

```
say aldric:
  Ah, you're finally here.
  I was beginning to wonder if you'd changed your mind.
```

The speaker may be a bare identifier, a symbol literal (e.g. `'aldric`), a `NAMED_ARG` token (identifier followed immediately by `:`), or a parenthesised expression. The dynamic form `say (expr):` resolves the speaker symbol at runtime — useful when the speaker depends on game state.

### Choices

```
* Choice text
  fn-call
  -> next-scene
```

Optional guard:

```
* [condition] Choice text (hidden when condition is false)
  fn-call
  -> next-scene
```

### Scene navigation

| Sigil | Effect |
|-------|--------|
| `-> name` | Goto: transition to `name`, scene stack unchanged |
| `-> (expr)` | Computed goto: `expr` must evaluate to a scene name |
| `=> name` | Enter: push current scene onto stack, go to `name` |
| `<-` | Exit: pop stack, return to previous scene |

---

## Dialogue and Speaker System

StoryBase has a first-class dialogue attribution system for writing interactive fiction with multiple named characters.

### Speaker declarations

```
speaker aldric:
  display: "Aldric the Bold"
  color:   "#c8a96e"

speaker mira:
  display: "Mira Ashveil"
  color:   "#7ab8c2"
```

Declare named speakers at the top level. Both `display:` and `color:` are optional. Speakers do not need to be declared; an undeclared speaker name is valid but emits an `INFO` hint at compile time.

### The `say` statement

`say` emits attributed dialogue. It is legal in scene bodies, choice bodies, function bodies, and macros.

**Scene-body inline form:**

```
say aldric: Ah, you're finally here.
```

**Scene-body block form:**

```
say aldric:
  Ah, you're finally here.
  I was beginning to wonder if you'd changed your mind.
```

**Function-body form:**

```
fn aldric-greets:
  say 'aldric "Ready when you are, Commander."
  say 'aldric "I've been sharpening my blade all morning."
```

The scene-body form uses a colon separator; the function-body form places the text directly after the speaker.

### Dynamic speakers

The speaker expression may be any expression wrapped in parentheses:

```
say (player/companion): I'll scout ahead.
```

At runtime the expression is evaluated and its symbol value is used as the speaker key. If the result is `nil` (e.g. an `Option` that is not set), the line is still emitted but has no speaker attribution.

### Narration output format

`say` statements produce *dialogue objects* in the narration list rather than plain strings. Each dialogue object is a Lua table with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `speaker` | string or nil | Raw speaker key (symbol name) |
| `display` | string or nil | Human-readable name from the `speaker` declaration, or the raw key if undeclared |
| `color` | string or nil | CSS hex color from the `speaker` declaration, or nil if undeclared |
| `text` | string | Rendered dialogue text (with `{expr}` interpolation applied) |

Plain narration lines remain plain strings. Hosts must check `type(line) == "table"` to distinguish dialogue objects from narration strings.

```lua
local narration, choices = game:render()
for _, line in ipairs(narration) do
  if type(line) == "table" then
    -- Attributed dialogue
    local label = line.display or line.speaker or "?"
    print(label .. ": " .. line.text)
  else
    -- Plain narration
    print(line)
  end
end
```

### Ordering: fn-body say before scene narration

Dialogue emitted by `say` inside a function that is called from a choice body accumulates in a pending buffer. When the next scene renders, that buffered dialogue is prepended to the scene's narration so it appears in the correct narrative order.

This guarantee applies transitively: if a choice body calls function A, which calls function B, all `say` statements from both A and B are buffered and prepended to the next scene's narration in call order (A's lines before B's, which are before the scene's own narration lines).

**Summary of ordering guarantees:**
- `say` in a choice body: appears immediately before the next scene renders.
- `say` in a function called from a choice body: buffered and prepended to the next scene.
- `say` in nested function calls: buffered in call order, all prepended before scene narration.
- `say` in scene bodies: appears at the position it is written in the scene narration list.

---

## Type System

### Discrete vs. superficial

Only **discrete** types may appear in conditional expressions or drive game logic. **Superficial** types are unbounded and for presentation only.

The compiler enforces:
- No superficial value in a conditional (`if`, `when`, `cond`, `match`).
- No superficial value passed where a discrete type is expected.
- No random source may produce a superficial value.

### Saturation arithmetic

`inc!` and `dec!` on `Int(min, max)` clamp to the declared range. No wrap-around; no runtime error for out-of-range attempts. In debug mode, the `clamp-event` fires on every clamp.

### Nil

Reads from an uninstantiated family member return `nil`. Nil propagates through expressions. Use `??` to provide a default.

### State-space size

The total state-space size — the product of all discrete state path sizes — determines the precision and cost of exhaustive search. Keep it bounded by preferring named enums over `Symbol`.

---

## Path Syntax

### Static paths

```
player/health
world/chapter
```

### Interpolated paths

```
npcs/{npc}/health
```

`{npc}` must be typed as `SymbolOf(npcs)`.

### Write-path restrictions

In write positions (any mutation primitive):
- Static paths are always legal.
- `{var}` interpolation is legal only if `var` is a declared family-key type.
- Dynamic path construction (e.g. `path-join`) is a compile error.

### Path patterns (query context only)

Legal inside `find`, `verify`, `watch`, `perceives:` only:

| Pattern | Matches |
|---------|---------|
| `player/health` | Exactly `player/health` |
| `player/*` | Any single segment under `player` |
| `player/**/strength` | `strength` at any depth under `player` |
| `npcs/*/location` | `location` under any NPC |
| `player/(health\|mana)` | Either field |
| `player/!inventory` | Any field except `inventory` |

### Indexed access

```
player/waypoints[0]    # 0-based index
player/waypoints[-1]   # last element
player/waypoints[1:4]  # slice
```

---

## Module System

State paths are always global. `import` makes type names, function names, and scene names available:

```
import "combat.sb"           # all names unqualified
import "enemies.sb" as E     # E.Npc, E.spawn-enemy
```

Import cycles are a compile error.

---

## Error Codes

| Code | Level | Description |
|------|-------|-------------|
| `UNDEFINED_TYPE` | error | Reference to an undeclared type |
| `UNDEFINED_NAME` | error | Reference to an undeclared function, scene, or variable |
| `DUPLICATE_DECL` | error | Two declarations with the same name |
| `IMPORT_CYCLE` | error | Circular import |
| `FILE_NOT_FOUND` | error | `import` target not found |
| `TYPE_MISMATCH` | error | Value used where a different type is expected |
| `IMPURE_IN_PURE` | error | Mutation called from a pure context |
| `WRITE_PATH_DYNAMIC` | error | Dynamic path construction in write position |
| `SUPERFICIAL_IN_COND` | error | Superficial type in a conditional expression |
| `PERCEIVES_VIOLATION` | warning | Actor reads a path outside its `perceives:` list |
| `UNTYPED_SYMBOL` | warning | `Symbol` used where `SymbolOf(F)` would give better bounds |
| `UNSUPPORTED_FEATURE` | error | Feature not yet implemented (e.g., `import "f" as Alias` — use flat import) |

# Basic idea
- Engine for RPG/adventure style games, with a focus on structured, queryable state and time. Inspired by the idea of "event sourcing" in software design, where all changes to application state are stored as a sequence of events.
- Uses a custom DSL for defining transactions and queries, with a focus on readability and ease of use for game designers.
- Compiled to Python, with inline Python and READ-ONLY access to underlying structure in fenced blocks (a la rpython)
- Uses hierarchical keys to represent state, e.g. `player/body/arm/strength` or `player/inventory`. Values can be numbers, strings, lists, etc.
- Strictly typed and type checked at compile
- Can query and prove properties of the game state, including past and future states, using a PROLOG-like query system. Queries can be about the current state, or about what could happen in the future.
- Full "version control" of game state, with the ability to branch and merge timelines based on player actions and time travel.
- Controlled use of random events, with the ability to replay and test specific scenarios by controlling the random seed and/or using exhaustive search. MC or MCMC for sampling from complex probability distributions over future states (e.g. to satisfy constraints or via potential functions)
- Hierarchical time system, with multiple levels of time (e.g. epsiodes, turns, etc.) and the ability to query and manipulate time in a flexible way.
- Basic model is a database holding facts, a set of rules (PROLOG style), and a set of dynamic logic to manipulate the database and query it. Facts are added via transactions, which are timestamped and indexed. Rules can be used to derive new facts from existing ones, and to answer queries about the state of the world.
- Focus on debugging and testing, with tools for dumping the state of the world, tracing the execution of transactions, and testing the reachability of different states.
- Auto-serialisable via the log of transactions, with the ability to replay and branch timelines as needed. (essentially a VCS, with persistent on-disk storage with an in-memory cache for performance)
- Actor based model with message passing, but with a shared state that can be queried and manipulated by all actors. (e.g. player, NPCs, environment) Actors can have their own internal state and logic, but they interact with the world through transactions that manipulate the shared state.
- Actors can have "mental models" that represent the world state, and indexed in the same way, but are updated via beliefs and perceptions, which are also transactions that can be logged and queried. This allows for modeling of NPCs with their own beliefs and knowledge about the world, which can be different from the actual state of the world.
- All functions have known possible changes to the world state, which can be used for reachability testing and to ensure that certain properties hold (e.g. "player cannot die" or "door cannot be opened without key"). This also allows for more efficient querying and reasoning about the world state, as we can use the known effects of transactions to limit the search space when answering queries.
- Sophisticated menu system, with support for dynamic menus that can change based on the game state, and for branching dialogue trees that can be queried and manipulated using the same transaction and query system as the rest of the game logic.
- Use of logits as standard representation of probabilities, to allow for more efficient and stable handling of probabilities in the game logic, especially when dealing with very small or very large probabilities.
- Message based UI system, where the UI is essentially an actor that receives messages about the game state and sends messages back to the game logic based on player input. This allows for a clean separation of concerns between the game logic and the presentation layer, and makes it easier to implement different types of UIs (e.g. text-based, graphical, etc.) without changing the underlying game logic.
- Support for continuous development, e.g. to upgrade from one data model to another, set new defaults,
- cascading defaults in in the data model

# Open questions

- Syntax of the DSL for transactions and queries
- How to represent and manipulate time, including branching timelines and time travel
- How to implement the PROLOG-like query system, including support for constraints and probabilities in future queries
- How to implement the actor model and the shared state, including the mental models of NPCs
- How to implement the logging and version control of game state, including branching and merging timelines
- How to implement the testing and debugging tools, including reachability testing and state dumping
- How to implement the randomisation and control of random events, including support for exhaustive search and replaying specific scenarios
- How to ensure type safety and consistency of the game state, including type checking of transactions and queries at compile time

# Types
- Booleans
- Integers (including bounded ints)
- Enums
- Floats (including bounded floats)
- Strings
- Sets
- Lists
- Maps
- Functions
- Paths (e.g. player/body/arm/strength)
- Distribution versions of Booleans, Integers, Enums, Floats, Strings, Sets, Lists, Maps (e.g. for representing uncertain or probabilistic state)

# Syntax ideas
- Clean, simple, Python-like syntax
- Indentation-based blocks for defining functions
- Basic control flow: if/else, switch, counted loops, foreach loops, while, recursion
- sophisticated path syntax
    - /player/body/arm/strength
    - /player/body/arm/*  wildcard
    - /*/body/arm/strength
    - /(player|npc1|npc2)/body/arm/strength choice
    - /{var}/body/arm/strength variable substitution (can include e.g. wildcards in the variable)
    - /**/strength glob
    - /player/body/!arm/strength negation
    - /player/body/!(arm|leg)/strength negation
    - /player/body?/arm/strength optional
    - /player/body/arm/strength[0] indexed access
    - /player/body/arm/strength[0:3] slice access
    - start/end anchors for queries, e.g. */arm/strength$ to match exactly that prefix
- Maybe something like LET, LAMBDA in Excel
- (s-expr) syntax?
- literals
  - strings/int/bool/enum: "string", 123, true, false, enum(value1, value2, ...)
  - sets: {item1, item2, ...}
  - lists: [item1, item2, ...]
  - maps: {key1: value1, key2: value2, ...} (maps can be used to represent entities)

possible syntax (not necessarily final, just to get a sense of how it might look):
```

object_map = map(string, object)

/liveness
  /state enum(alive, dead, unconscious)

/location
  /x int
  /y int
  /height int

/entity
  /name string "Unknown"
  /liveness liveness(state=alive)
  /location location(x=0 y=0 height=0)
  /hit_points int 0
  /inventory set(string) {}
  /seen set(string) {}

/player
  | entity     # merge/inherit
  "Player" -> /name
  100 -> /hit_points


def add_inventory(entity, item):
  item -> {entity}/inventory
  item -> {entity}/seen

def player_picks_up_goo():
  add_inventory(player, "goo bits")
  "You pick up the goo. It feels slimy and gross." => ui/message
  +1 -> player/fear/goo

menu:
    ?can_see(player, goo) => "You see some goo on the ground. Do you want to pick it up?"
        - "Yes"
             player_picks_up_goo()
        - "No"
             pass
```


# Fragments of design and implementation ideas
Running log of event transactions
Every transaction has an index and a (multi-part) time

513 1.5.3.9 player/body/arm/strength +1
514 1.5.3.10 player/fear/goo +1
515 1.5.3.10 player/history + "seen goo"
516 1.5.3.10 player/inventory + "goo bits"

e.g. inventory is "sum" of items
stats are sum of updates

some form of ECS like system
attribute sets => attribute sets or entities

player/body/arm/strength

Queries over time, including past and future, with PROLOG style place-holders
Future queries answered via constraints and/or probabilities

Postulated futures? (e.g. "player escapes in next turn)
Future-hinting structure? Inc. dynamic hints.

Some form of simple query language

Type checking on compile all transactions
Reachability/coverage testing
(inc. dynamically in game while testing)

Standardised randomisation, including manual control, exhaustive searching

"Fresh state" schema + defaults


* `set_time('+1.0.0.0')` set the time. Relative adjustments are given with `+n`. Travelling to the past (or the exact present) will revert state and branch the world. Returns the old branch.

* `can(query)` return True if query can happen, False otherwise
* `when(query)` return the soonest time that query can happen, if it can happen, or None, if it can't
* `likely(query)` how likely query is to happen

`(can be-in? player house)`

---

# StoryBase Language Specification

## 1. Overview and Philosophy

StoryBase is a DSL for authoring adventure and RPG games. Its central idea is the **logic machine**: a deterministic, finite-state core that controls all gameplay decisions, surrounded by an unbounded presentation layer that can display anything but never affect logic.

Four principles govern the design:

**Separation of logic and presentation.** All branching, conditionals, and gameplay decisions depend only on *discrete* (bounded, enumerable) types. Text, visuals, and other presentation data are *superficial* types: they can be displayed and updated, but no computation may branch on their values. This separation makes the game state machine finite and fully analysable.

**The transaction log is the ground truth.** Every change to state is recorded as a timestamped transaction. The current state is always a projection of the log. This gives automatic save/load, full replay, debugging by time-travel into history, and the basis for future-state search.

**Bounded exhaustive search over futures.** Because all logic depends only on discrete bounded types, and all random sources produce a finite set of outcomes, the reachable future states form a finite (if large) graph. The engine can search this graph to answer questions like *can the player reach the castle?* or *is it possible to die in the next five turns?*

**Structured actors and messaging.** Complex game worlds involve many interacting entities. Actors encapsulate NPC and environment behaviour; they communicate through typed, discrete messages that appear in the transaction log. This keeps multi-entity interactions analysable and replayable.

---

## 2. Lexical Rules and Basic Syntax

StoryBase uses an s-expression syntax. Parentheses are always legal; indentation may replace them under a simple layout rule.

### 2.1 Tokens

```
# This is a comment. Comments run to end of line.

# Booleans
True   False

# Integers
42   -7   0

# Floats  (superficial only — cannot appear in logic)
3.14   -0.5

# Strings  (superficial only)
"hello, world"   "line one\nline two"

# Symbols  (quoted with ')
'sword   'alive   'blacksmith

# Paths  — any token containing / is a path
player/health          # resolves to /player/health
world/chapter          # resolves to /world/chapter
npcs/blacksmith/hp     # resolves to /npcs/blacksmith/hp

# Path with variable interpolation
npcs/{npc}/location    # npc is a typed entity-family variable in scope

# Named argument / block opener — colon as suffix
depth: 20              # named argument
defn foo [x]:          # block opener (introduces indented body)
```

**Naming conventions:**
- Functions that return `Bool` or test a condition end with `?`: `alive?`, `can-afford?`
- Transaction functions (those that modify state) are plain: `take-damage`, `move-to`
- Type names are `CamelCase`: `CharClass`, `Health`
- State paths and function names use `kebab-case`: `player/hit-points`, `pickup-item`

### 2.2 Parenthesised S-Expressions

The base syntax. Every form is `(head arg1 arg2 ...)`:

```
(defn take-damage [amount]
  (dec! player/health amount)
  (when (<= player/health 0)
    (set! player/status 'dead)))
```

### 2.3 Indentation Layout Rule

Parentheses may be replaced with indentation. The rule is deliberately simple:

- If a form does not close on the same line it opens, the next indented block provides its remaining arguments.
- Lines at the same indentation within that block are sibling arguments.
- Dedenting closes the open form.
- Explicit parentheses always take precedence inside their own scope. You can freely mix the two styles.

```
# Indented — equivalent to the parenthesised form above
defn take-damage [amount]:
  dec! player/health amount
  when (<= player/health 0)
    set! player/status 'dead
```

### 2.4 Named Arguments

Any argument of the form `name: value` is a named (keyword) argument. Order among named arguments does not matter; they may not precede positional arguments.

```
can-reach? (= player/location 'castle)
  depth: 20
  strategy: breadth-first
```

### 2.5 Collection Literals

Collections are distinguished by content, not by prefix sigil.

```
# Set — bare values, no colons
{'sword 'potion 'key}

# Set — empty (explicit constructor to avoid ambiguity with empty map)
(set)

# List (ordered, indexed)
['north 'east 'south 'west]

# Map — key: value pairs
{name: "Aldric"  class: 'warrior  level: 5}

# Map — empty
{}
```

**Parser rule:** if the first element inside `{...}` is followed by `:`, the whole form is a map; otherwise it is a set. The empty form `{}` is always an empty map; `(set)` is always an empty set.

---

## 3. Type System

Types are divided into two worlds. The compiler enforces the boundary between them.

### 3.1 Discrete Types

Discrete types have a **finite, bounded** set of possible values. Only discrete types may appear in conditional expressions or as the domain of game logic. All discrete types have a computable *state-space size* used to bound future-state search.

| Type | Syntax | State-space size |
|------|--------|-----------------|
| Boolean | `Bool` | 2 |
| Enumeration | `(Enum v1 v2 ... vN)` | N |
| Bounded integer | `(Int min max)` | max − min + 1 |
| Symbol | `Symbol` | unbounded (warns) |
| Typed symbol | `(SymbolOf Family)` | \|Family\| |
| Option | `(Option T)` | \|T\| + 1 |
| Bounded set | `(Set T max)` | Σ C(\|T\|,i) for i=0..max |
| Bounded list | `(List T max)` | (\|T\|+1)^max |
| Record | `RecordName` | product of field sizes |
| Variant | `VariantName` | sum of branch sizes |

### 3.2 Superficial Types

Superficial types are **unbounded** and used exclusively for presentation: narrative text, display names, visual parameters. The compiler enforces:

- No superficial value may appear in a conditional expression (`if`, `when`, `cond`, `match`).
- No superficial value may be passed as an argument to a function declared or inferred to return a discrete type.
- No random source may produce a superficial value.
- Superficial values *may* be constructed from discrete values (e.g. building a description string from an enum).

| Type | Notes |
|------|-------|
| `String` | Narrative text, display names |
| `Float` | Visual/audio parameters |
| `(UList T)` | Unbounded list |
| `(UMap K V)` | Unbounded map |

### 3.3 The Compiler Boundary

```
# OK: discrete value drives a conditional
if (< player/health 20)
  set! player/description "You look badly hurt."

# OK: superficial value updated from discrete
set! player/description
  match player/status
    'alive "Hale and hearty."
    'dead  "Dead."

# ERROR: superficial value in a conditional
if (= player/name "Alice")    # compile error: String in condition
  grant-bonus

# ERROR: random source producing superficial
set! player/name (random-choice ["Alice" "Bob"])  # compile error
```

### 3.4 Typed Symbols

`Symbol` is the catch-all type for symbolic values whose domain has not yet been enumerated. It is legal everywhere a discrete type is expected, but the compiler emits a **`warn-untyped-symbol`** warning for every use. The state-space size of `Symbol` is treated as a large constant for search-bound estimation, which degrades the precision of future-state analysis.

```
# Warns: Symbol is untyped — search bounds are imprecise
defboundset QuestFlags  Symbol  20

# Better: fully enumerated — precise bounds, no warning
defenum QuestFlag  forge-quest-active  defeated-goblin-king  found-crown
defboundset QuestFlags  QuestFlag  20
```

Entity-family keys (the variable in `defstate npcs/{npc}:`) are automatically typed as `(SymbolOf npcs)` by the compiler. You can declare explicit domains with `defenum` or leave them as `Symbol` during prototyping.

The `storybase extract-symbols` tool scans a codebase, collects all literal symbols used in a given context, and outputs a candidate `defenum` declaration.

---

## 4. Path Syntax

Paths are the fundamental addressing mechanism. Any token containing `/` is a path. Paths are absolute; a leading `/` is optional syntactic noise and is stripped.

### 4.1 Variable Interpolation

`{varname}` splices a variable into a path segment. The variable must be typed as an entity-family key — the variable declared in a `defstate family/{var}:` form — or as `(SymbolOf Family)`.

```
npcs/{npc}/health        # npc : (SymbolOf npcs)
world/{zone}/discovered  # zone : (SymbolOf zones)
```

### 4.2 Write-Path Restrictions

In any **write position** (`set!`, `inc!`, `dec!`, `add!`, `remove!`, `push!`, `pop!`, `clear!`, `send!`, `relate!`, `unrelate!`) the following rules apply:

- **Static paths** are always legal: `set! player/health 50`
- **`{var}` interpolation** is legal only if `var` has a declared entity-family type. The compiler infers the write-set as `family/*/field`.
- **Dynamic path construction** is a compile error in all write positions.

```
# Legal: npc is typed as (SymbolOf npcs)
set! npcs/{npc}/health 50

# COMPILE ERROR: untyped variable
let p = (some-fn):
  set! {p}/health 50

# COMPILE ERROR: dynamic construction
set! (path-join "npcs/" name "/health") 50
```

This restriction ensures the compiler can always determine the static write-set of any transaction function, which is required for future-state search, hook analysis, and bidirectional search.

### 4.3 Path Patterns (Query Context Only)

Path patterns are legal only inside `query`, `query-history`, `can-reach?`, and similar search forms. They are **not** legal in write positions.

| Pattern | Matches |
|---------|---------|
| `player/health` | Exactly `/player/health` |
| `player/*` | Any single segment under `/player` |
| `player/**/strength` | `strength` at any depth under `/player` |
| `npcs/*/location` | `location` under any direct child of `/npcs` |
| `player/(health\|mana)` | Either `health` or `mana` under `/player` |
| `player/!inventory` | Any field under `/player` except `inventory` |
| `player/inventory/*$` | Exactly one segment past `inventory` (end anchor) |

### 4.4 Indexed Access

For `List` values, index and slice notation is legal in both read and write positions.

```
player/waypoints[0]       # first element
player/waypoints[-1]      # last element
player/waypoints[1:4]     # elements 1, 2, 3
player/waypoints[::2]     # every other element (read only)
```

### 4.5 Path Semantics in defstate

When a `defstate` uses `{var}` in its path, it declares a *family* of state nodes — one per registered instance. The variable is automatically typed as `(SymbolOf family)` throughout the codebase.

```
defstate npcs/{npc}: Npc = Npc()
# 'npc' is now typed as (SymbolOf npcs) everywhere
```

---

## 5. Schema Definition

All types and state shapes are declared in a schema block before any game logic. The compiler uses the schema to check types, compute state-space bounds, and enforce the discrete/superficial boundary.

### 5.1 Base Type Declaration

```
deftype Name TypeExpr
```

`TypeExpr` is one of the type forms from §3.

### 5.2 Record Types

A record is a named, ordered set of typed fields with defaults. Records are discrete types; their state-space size is the product of their field sizes.

```
defrecord Name:
  fieldname: TypeName = default
  mixin OtherRecord
  ...
```

`mixin` splices all fields from another record at that point. Fields declared after `mixin` may **override defaults** (but not types) of mixed-in fields. Multiple mixins are allowed; conflicting field names from two different mixins are a compile error.

```
defrecord Entity:
  health:   Health      = 50
  status:   Status      = 'alive
  location: Location    = 'village
  name:     DisplayName = "Unknown"

defrecord Npc:
  mixin Entity
  disposition: Disposition = 'neutral

defrecord Player:
  mixin Entity
  health:      Health           = 100    # override default only
  mana:        Mana             = 50
  gold:        Gold             = 0
  class:       CharClass        = 'warrior
  has-key:     Bool             = False
  inventory:   (Set ItemKind 10) = (set)
  quest-flags: (Set Symbol  20)  = (set)
  description: Description      = ""
```

Fields may have record types, giving nested structure:

```
defrecord Coord:
  x: (Int 0 39) = 0
  y: (Int 0 39) = 0

defrecord GridEntity:
  mixin Entity
  coord: Coord = Coord()
```

Record constructors use named arguments; omitted fields take their defaults:

```
Player(name: "Hero"  class: 'rogue)
Entity(health: 30  location: 'dungeon)
Coord()                               # all defaults
```

### 5.3 Variant Types

A variant (tagged union) is a discrete type whose value is exactly one of a set of named branches, each with its own record payload. Variants are used primarily for actor messages. Their state-space size is the sum of branch payload sizes.

```
defvariant Name:
  branch-name: { field: Type  field: Type ... }
  ...
```

```
defvariant ActorMsg:
  alert:          { threat: NpcId  location: Location }
  trade-offer:    { item: ItemKind  price: Gold }
  attack-request: { target: NpcId  damage: Damage }
  quest-update:   { quest: Symbol  status: Symbol }
```

Constructing a variant value:

```
ActorMsg/alert       threat: 'goblin    location: 'forest
ActorMsg/trade-offer item:   'sword     price: 50
```

Pattern-matching a variant value:

```
match msg:
  alert { threat location }:
    set! npcs/{npc}/disposition 'hostile
  trade-offer { item price }:
    when (can-afford? price)
      buy-item item price
  _: pass
```

### 5.4 Relations

A relation declares a typed directed association between discrete values. Relations are first-class state; `relate!` and `unrelate!` produce log entries. Their state-space size is computable from the domain and range types.

```
defrelation name: DomainType -> RangeType
```

`RangeType` is typically `(Set T max)` for one-to-many, a plain discrete type for one-to-one, or `(Map T (Int lo hi))` for weighted edges.

```
defrelation exits:    Location -> (Set Location max: 6)
defrelation knows:    NpcId    -> (Set NpcId    max: 20)
defrelation carries:  NpcId    -> (Set ItemKind max: 10)
defrelation distance: Location -> (Map Location (Int 0 100))
```

Static initial data may be declared inline when the relation is fixed at game start:

```
defrelation exits: Location -> (Set Location max: 6):
  village -> {'forest}
  forest  -> {'village 'dungeon}
  castle  -> {'village}
  dungeon -> {'forest 'castle}
```

### 5.5 Schema Macros

`deftype` is the base form; the following macros expand to it.

```
defenum        Name  val1 val2 ...
# expands to: deftype Name (Enum val1 val2 ...)

defboundint    Name  min max
# expands to: deftype Name (Int min max)

defboundset    Name  ElementType  max
# expands to: deftype Name (Set ElementType max)

defboundlist   Name  ElementType  max
# expands to: deftype Name (List ElementType max)

defsuperficial Name  BaseType
# expands to: deftype Name BaseType  (marked superficial)
```

### 5.6 State Declaration

```
defstate path: RecordType = RecordType(field: value ...)
```

For simple state without a named record type, inline field declaration is equivalent:

```
defstate path:
  field: Type = default
  ...
```

The inline form implicitly defines an anonymous record. Both forms produce identical schemas; the explicit `defrecord` form is preferred when the record type is referenced more than once.

```
defstate player: Player = Player(name: "Hero")
defstate npcs/{npc}: Npc = Npc()

defstate world:
  turn:    TurnCount = 0
  chapter: Chapter   = 'intro

defstate combat:
  active:  Bool         = False
  enemy:   NpcId        = 'blacksmith  # placeholder; only valid when active=True
  outcome: CombatResult = 'ongoing
```

---

## 6. Functions

### 6.1 Pure Functions

A function is *pure* if it performs no state mutations and calls no random sources or bounded computations. The compiler detects this automatically.

```
defn can-afford? [price]:
  >= player/gold price

defn alive? [entity]:
  = npcs/{entity}/status 'alive

defn base-damage []:
  match player/class
    'warrior  15
    'rogue    12
    'mage      8

defn hostile-nearby? []:
  any? query npc
    where: (and (= npcs/{npc}/location player/location)
                (= npcs/{npc}/disposition 'hostile))
```

### 6.2 Transaction Functions

A function is a *transaction* if it calls any mutation primitive. The compiler detects this automatically and records the inferred read/write sets.

```
defn move-to [loc]:
  set! player/location loc
  time-inc! turn:

defn take-damage [amount]:
  dec! player/health amount
  when (<= player/health 0)
    set! player/status 'dead
    set! player/description "You have fallen."
```

### 6.3 Pre/Post Conditions

Pre and post conditions are declared inside the function body, before imperative statements.

```
defn take-damage [amount]:
  pre:
    amount > 0
    = player/status 'alive
  post:
    >= player/health 0
  dec! player/health amount
  when (<= player/health 0)
    set! player/status 'dead

defn pickup-item [item]:
  pre:  not (contains? player/inventory item)
  post: contains? player/inventory item
  add! player/inventory  item
  add! player/quest-flags item
```

Pre-conditions are checked on entry; a violation is a caller bug. Post-conditions are checked on exit; a violation is an implementation bug. Both use only discrete values.

### 6.4 Local Bindings

```
defn resolve-attack [enemy]:
  let base  = (base-damage)
      bonus = (if (contains? player/quest-flags 'berserk) 5 0)
      total = (+ base bonus):
    dec! npcs/{enemy}/health total
    set! player/description (str "You deal " total " damage.")
```

### 6.5 Control Flow

```
# Conditional
if condition then-expr else-expr

# One-armed conditional
when condition body...

# Multi-branch
cond:
  (< player/health 20)  (set! player/status 'critical)
  (< player/health 50)  (set! player/status 'wounded)
  True                  (set! player/status 'healthy)

# Match on discrete value or variant
match player/class
  'warrior  (inc! damage 5)
  'mage     (inc! mana-cost 2)
  'rogue    (inc! crit-chance 3)

# Counted loop
dotimes i 3
  push! player/waypoints player/location

# Iteration
for item player/inventory
  log (str "Carrying: " item)
```

---

## 7. Mutation Primitives

All mutation primitives produce a transaction in the log. They are only legal inside transaction functions. Write-path restrictions (§4.2) apply to all of them.

```
set!      path value       # set path to value
inc!      path amount      # path = path + amount  (discrete numeric)
dec!      path amount      # path = path − amount  (discrete numeric)
add!      path value       # add value to a set
remove!   path value       # remove value from a set
push!     path value       # append value to a list
pop!      path             # remove last element from a list
clear!    path             # set collection to empty
send!     actor value      # enqueue a typed message to an actor's inbox
relate!   relation a b     # add (a → b) to a relation
unrelate! relation a b     # remove (a → b) from a relation
```

---

## 8. Decorators and Tags

Tags classify functions. They are declared with `deftag` and applied as decorators on the lines immediately before `defn`.

### 8.1 Declaring Tags

```
deftag transaction
  doc: "Modifies discrete game state; produces log entries."

deftag reversible
  doc: "Can be run backwards; suitable for bidirectional search."

deftag logged
  doc: "Calls appear verbatim in the debug log."

deftag validated
  doc: "Pre/post conditions checked even in release mode."

deftag checkpoint
  doc: "Engine snapshots state before this function runs."
```

### 8.2 Applying Decorators

```
@transaction
@reversible
@logged
defn move-to [loc]:
  set! player/location loc
```

### 8.3 Auto-Detected Properties

The compiler infers these without annotation.

| Property | Inferred when |
|----------|--------------|
| `transaction` | body contains any mutation primitive |
| `pure` | no mutations, no random sources, no bounded computations |
| `uses-random` | body calls any `random-*` form |
| `uses-bounded` | body calls any `defbounded` function |
| `reads: [paths]` | static read-set analysis |
| `modifies: [paths]` | static write-set analysis |

---

## 9. Hooks and Aspects

Hooks are cross-cutting pre/post callbacks registered on a tag.

### 9.1 Hook Definition

```
hook tagname:
  pre:  form...
  post: form...
```

Available bindings: `fn-name`, `fn-args`, `pre-state` (post only), `post-state` (post only), `changes` (post only), `result` (post only).

```
hook transaction:
  pre:  snapshot-if-checkpoint-due
  post: (broadcast 'state-changed changes)

hook reversible:
  post: (register-inverse! fn-name fn-args pre-state post-state)

hook logged:
  pre:  (log "> {fn-name} {fn-args}")
  post: (log "< {fn-name} → {result}")

hook validated:
  post:
    when (not (all-post-conditions-hold? fn-name post-state))
      raise (PostConditionError fn-name)
```

### 9.2 Aspects

An aspect is a named pre/post pair applied as a decorator to individual functions.

```
defaspect checkpoint-around:
  pre:  (checkpoint! fn-name)
  post: (when (failed? result) (rollback-to-last-checkpoint))
```

### 9.3 Execution Order

```
Hook pre      (outermost, declaration order)
  Aspect pre  (decorator order)
    pre: conditions
    Body
    post: conditions
  Aspect post (reverse decorator order)
Hook post     (outermost, reverse declaration order)
```

---

## 10. Random Sources

All randomness is isolated to a small set of primitives. Every call is logged with its seed and outcome. In search mode the engine enumerates all possible outcomes.

```
random-bool   p                  # True with probability p;  2 outcomes
random-int    min max            # uniform integer in [min, max]
random-choice collection         # uniform draw from a discrete collection
random-enum   EnumType           # uniform draw from an enumeration
```

Random primitives may only produce discrete values. A function that calls any random primitive is auto-tagged `uses-random`. In search/probability mode, `random-int min max` branches into `(max−min+1)` successor states.

---

## 11. Bounded Computations

`defbounded` declares a computation that uses Python (and may use floats, ML models, or other external resources) but produces a **discrete output**. From the search engine's perspective, a bounded computation is treated identically to a random choice over its declared return type — the engine branches over all possible output values, weighted by the declared distribution.

This gives a clean seam for floating-point game logic, procedural generation, and AI components: compute freely in Python, but commit to a discrete output at the boundary. In run mode the Python function is called and its return value is logged as a normal transaction entry, enabling full replay.

```
defbounded name [params...]:
  returns:      DiscreteType
  distribution: DistributionSpec
  reads:        [path ...]
  python:       "module.function_name"
```

`distribution:` tells the engine the probability model used during search:

| Spec | Search-engine treatment |
|------|------------------------|
| `uniform` | equal weight across all values of the return type |
| `(conditioned-on path)` | distribution depends on the discrete value at `path` |
| `(point-mass value)` | always returns `value` (useful for testing/mocking) |

```
defbounded classify-intent [text]:
  returns:      PlayerIntent     # a declared enum
  distribution: uniform
  reads:        []
  python:       "game.nlp.classify_intent"

defbounded tactical-assessment [npc]:
  returns:      Disposition
  distribution: (conditioned-on npcs/{npc}/disposition)
  reads:        [player/location  player/status  npcs/{npc}/*]
  python:       "game.ai.assess_threat"
```

**Key rules:**
- The return type of `defbounded` must be discrete (not superficial).
- A function calling a `defbounded` function is auto-tagged `uses-bounded`.
- The result is a normal discrete value and may be used in conditionals and logic.
- In search mode, calls to `defbounded` branch over all return-type values weighted by `distribution`, exactly as `random-int` branches over its range.

---

## 12. Transaction Log and Time

### 12.1 Transaction Format

Every mutation produces a log entry:

```
Trans 514  time:[1 5 3 10]  (Add player/inventory 'goo-bits)
Trans 515  time:[1 5 3 10]  (Inc player/fear/goo 1)
Trans 516  time:[1 5 3 11]  (Set player/location 'forest)
```

Each entry records: a global sequence index, a hierarchical time tuple, the operation, and (for reversible functions) enough information to reconstruct the pre-state.

### 12.2 Hierarchical Time

Time is a tuple of integers `[episode  chapter  turn  tick]`. The number of levels is configurable per game. Time is strictly increasing within a play session.

```
time-now                       # returns current time tuple e.g. [1 3 7 2]
time-inc! turn:                # advance turn counter, reset lower levels
time-inc! tick:                # advance tick, keep upper levels
```

### 12.3 Snapshotting

```
configure-snapshots!
  interval:   100
  keep-last:  10

checkpoint! 'before-boss-fight
restore!    'before-boss-fight
list-snapshots
```

### 12.4 Replay

```
replay-all
replay-from 200
replay-to   time: [1 3 7 0]
replay-from 200
  breakpoint: (< player/health 10)
```

### 12.5 Historical Queries

```
query-at player/location
  time: [1 3 5 0]
→ 'forest

query-history (= player/location 'village)
  from: [0 0 0 0]
  to:   [2 0 0 0]
→ [[0 0 0 0]  [0 0 5 2]  [1 2 3 0]]

query-changes player/health
  last-n: 5
→ [[[1 2 0 0]  100  90]
   [[1 2 1 3]   90  80]
   [[1 2 2 0]   80  95]]
```

---

## 13. Scheduling

The scheduler is part of the engine. Scheduled transactions appear in the log at their declared time, exactly as if triggered normally. Replay and future-state search automatically account for all scheduled events.

### 13.1 Scheduling Primitives

```
schedule!        name: Symbol  at: TimeTuple    do: form
schedule!        name: Symbol  every: TimeDelta  do: form
cancel-schedule! name: Symbol
```

`at:` accepts an absolute or relative time tuple; `+n` in any position means "n more than current." `every:` declares a recurring event that fires on each multiple of the delta.

```
# Gate closes in 3 turns
schedule! name: 'gate-close  at: [+0 +0 +3 0]  do: (close-gate)

# Fires at the start of every episode
schedule! name: 'morning-cycle  every: [+1 0 0 0]  do: (morning-events)

# Cancel before it fires
cancel-schedule! 'gate-close
```

### 13.2 `defschedule` — Named Recurring Events

For complex recurring logic:

```
defschedule name:
  every:  TimeDelta
  offset: TimeTuple    # when within the period to fire (default [0 0 0 0])
  do:
    body...
```

```
defschedule morning-cycle:
  every:  [+1 0 0 0]
  offset: [0 0 0 0]
  do:
    for npc (known-npcs):
      set! npcs/{npc}/location (npc-home npc)
    set! world/time-of-day 'morning
```

### 13.3 Scheduled Events in Search

The scheduler's pending queue is part of discrete state. Every successor state in future-search includes due scheduled events on the same footing as player actions. The engine does not distinguish between scheduled and immediately triggered transactions.

---

## 14. Actors and Messages

Actors model NPCs, the environment, and other autonomous agents. Each actor has a typed inbox; its behaviour is a transaction function that runs once per turn against a filtered view of the world state.

### 14.1 Declaring Actors

```
defactor name:
  state:    path
  perceives: [path-pattern ...]
  inbox:    (List MsgType max: N)
  behavior: function-name
  priority: Int              # lower = earlier in turn order; default 0
```

The `perceives:` list is a set of path patterns. Before calling the behaviour function, the engine constructs a **perception snapshot** — a frozen, filtered copy of state covering only the declared paths. The behaviour function reads from this snapshot, not from live state.

```
defactor blacksmith:
  state:     npcs/blacksmith
  perceives: [world/time-of-day  player/location  player/quest-flags
               npcs/blacksmith/*]
  inbox:     (List ActorMsg max: 8)
  behavior:  blacksmith-behavior
  priority:  10

defactor guard:
  state:     npcs/guard
  perceives: [player/location  npcs/*/location  npcs/guard/*]
  inbox:     (List ActorMsg max: 8)
  behavior:  guard-behavior
  priority:  20
```

The `inbox:` declaration automatically extends the actor's state subtree with an `inbox` sub-path of the declared type (e.g. `npcs/blacksmith/inbox`). This path is managed by the engine and is part of discrete, logged state.

### 14.2 Behaviour Functions

A behaviour function is a **transaction function** that the engine calls each turn. Inside a behaviour, path reads resolve against the actor's perception snapshot; the compiler rejects reads of paths not covered by the actor's `perceives:` declaration. The actor also always perceives its own state and inbox without needing to declare them.

Mutations in a behaviour are queued and applied to global state after all actors have completed their turn step, so no actor sees mid-turn changes made by another.

```
@transaction
defn blacksmith-behavior []:
  # Reads resolve against the perception snapshot
  when (= world/time-of-day 'morning):
    set! npcs/blacksmith/disposition 'friendly

  for msg npcs/blacksmith/inbox:
    match msg:
      alert { threat location }:
        set! npcs/blacksmith/disposition 'hostile
        send! guard (ActorMsg/attack-request target: threat  damage: 10)
      trade-offer { item price }:
        when (>= player/gold price):
          dec! player/gold price
          add! player/inventory item
      _: pass
```

### 14.3 Turn Lifecycle

```
1. Player action → transactions applied; outgoing messages queued
2. Pending message queue delivered to actor inboxes (as transactions)
3. Actors run in priority order:
     each behaviour reads its perception snapshot
     mutations and sends are queued
4. Queued mutations applied to global state
5. Scheduled events due this turn fire
6. New outgoing message queue becomes next turn's delivery batch
```

Messages sent during step 3 are delivered at step 2 of the *following* turn, preventing within-turn message loops. The full turn — player action, actor responses, scheduled events — is one atomic unit in the log for replay purposes.

### 14.4 Sending Messages

`send!` is a transaction primitive that enqueues a typed value into the target actor's inbox path. It is legal anywhere a mutation is legal.

```
send! blacksmith (ActorMsg/trade-offer item: 'sword  price: 50)
send! guard      (ActorMsg/alert threat: 'goblin  location: 'forest)
```

### 14.5 Actors in Future-State Search

Actor behaviours are declared pure functions of the perception snapshot. The search engine expands actor responses as part of each successor state: after applying the player's action, it runs each actor's behaviour (given the updated perception snapshot) and includes the resulting transactions. `can-reach?`, `verify-always`, and all future queries therefore account for full NPC reactions.

---

## 15. Query Language

### 15.1 Current-State Queries

`query` binds variables to values satisfying a `where:` condition and returns all solutions.

```
query npc
  where: (= npcs/{npc}/location player/location)
→ ['blacksmith 'merchant]

query [npc hp]
  where: (and (= npcs/{npc}/health hp)
              (< hp 20))
→ [['wounded-guard 15]  ['dying-merchant 8]]
```

### 15.2 Aggregation

```
count query npc
  where: (= npcs/{npc}/disposition 'hostile)
→ 3

any? query npc
  where: (= npcs/{npc}/disposition 'hostile)
→ True

all? query npc
  where: (> npcs/{npc}/health 0)
→ False

sum query hp
  where: (= npcs/{npc}/health hp)
→ 143
```

### 15.3 Relation Queries

The following operations are built into any declared `defrelation` and may be used freely in `where:` clauses and outside them.

```
# Is b directly reachable from a in one step?
adjacent? exits player/location 'forest
→ True

# Is b reachable from a within max-hops steps?
reachable? exits player/location 'castle  max-hops: 3
→ True

# Shortest path as a list of nodes (nil if unreachable)
shortest-path exits player/location 'castle
→ ['village 'forest 'dungeon 'castle]

# All nodes reachable from a within max-hops steps
reachable-set exits player/location  max-hops: 2
→ {'forest 'dungeon}

# Does any node have an edge to b? (inverse adjacency)
inverse-adjacent? exits 'forest player/location
→ True
```

Inside `query where:` clauses:

```
query loc
  where: (reachable? exits player/location loc  max-hops: 2)
→ ['forest 'dungeon]
```

### 15.4 Future-State Queries

```
can-reach? (= player/location 'castle)
  depth: 20
→ True

find-path (= player/location 'castle)
  max-depth: 15
→ ['enter-forest 'find-bridge 'cross-bridge 'approach-gate 'open-gate]

all-paths (= player/location 'castle)
  max-depth: 10
  max-results: 5
→ [['enter-forest ...] ['talk-wizard ...] ...]

probability (= combat/outcome 'victory)
  depth: 10
→ 0.73

expected-value player/gold
  depth: 20
→ 187.4

verify-always (>= player/health 0)
  depth: 50
→ True

find-counterexample (> player/gold 0)
  depth: 10
→ ['buy-sword 'buy-armour 'donate-to-temple]

optimal-path (= quest/status 'complete)
  depth: 30
  metric: player/gold
→ ['accept-quest 'kill-goblins 'loot-chest 'return-to-merchant]
```

### 15.5 Bidirectional Search

When a goal condition is highly specific, the engine automatically switches to bidirectional BFS. Functions tagged `@reversible` provide an inverse for the backward frontier; for functions built from primitive operations the compiler derives the inverse automatically.

---

## 16. Spatial Queries

### 16.1 Room Graph (Core)

The room-graph model is the default spatial representation for exploration-based games. A location enum combined with a `defrelation exits` gives a fully analysable world graph. The built-in relation query operations from §15.3 (`adjacent?`, `reachable?`, `shortest-path`) provide all spatial navigation queries.

```
defenum Location  village forest castle dungeon tower

defrelation exits: Location -> (Set Location max: 6):
  village -> {'forest}
  forest  -> {'village 'dungeon}
  castle  -> {'village 'tower}
  dungeon -> {'forest 'castle}
  tower   -> {'castle}

# Is the castle reachable from the player's location in ≤4 steps?
reachable? exits player/location 'castle  max-hops: 4
→ True

# What is the shortest route?
shortest-path exits player/location 'castle
→ ['village 'forest 'dungeon 'castle]
```

Visibility in the room-graph model is adjacency plus perception: an actor sees what is in its current room, and optionally one hop away, as declared in its `perceives:` list.

### 16.2 Tile Grid (Extension)

Games requiring geometric visibility (tactical RPGs, roguelikes) may declare a `defgrid`. This is an optional extension; it adds a small set of built-in spatial operations over a 2D discrete coordinate space.

```
defgrid name:
  width:  (Int 1 W)
  height: (Int 1 H)
  walls:  (Set Coord max: N)

deftype Coord = { x: (Int 0 (- W 1))  y: (Int 0 (- H 1)) }
```

Built-in grid queries:

```
visible-from?  dungeon-floor  player/coord  monster/coord
within-range?  dungeon-floor  player/coord  target/coord  range: 5
path-to        dungeon-floor  player/coord  exit/coord    → (List Coord)
occupied-by    dungeon-floor  coord                       → (Option NpcId)
```

`visible-from?` uses built-in raycasting; `path-to` uses built-in A\*. Both are opaque to the language (they cannot be expressed in StoryBase itself) but their read-sets are declared to the compiler so the search engine knows when to recompute cached results. `Coord` is discrete and bounded; a 40×40 grid has 1600 positions, well within the analysable range.

---

## 17. Scenes

Scenes replace recursive menu functions. The scene system is a **state machine**: named scenes are nodes, navigation forms are edges. No call stack grows during navigation.

The engine maintains two pieces of engine-managed discrete state:

- `engine/current-scene: SceneId` — the active scene
- `engine/scene-stack: (List SceneId max: 8)` — the return stack for `enter`/`exit`

Both are visible to the search engine, so `can-reach? (= engine/current-scene 'castle-gate)` works correctly.

### 17.1 Declaring Scenes

```
defscene name:
  prompt: StringExpr          # optional; shown before options
  option-item...
```

Each option item is either a direct option or a guarded option:

```
# Direct option
"Label string"
  transaction-call...
  nav-form

# Guarded option (omitted from display when guard is False)
when discrete-condition
  "Label string"
    transaction-call...
    nav-form
```

`nav-form` is exactly one of `goto`, `enter`, `exit`, or `exit-to`. Every execution path through an option body must end with a nav-form.

```
defscene village:
  prompt: "You are in the village square."
  "Enter the forest"
    move-to 'forest
    random-encounter
    goto forest
  when (can-afford? 40)
    "Buy a health potion (40 gold)"
      buy-item 'health-potion 40
      goto village
  when player/has-key
    "Ride to the castle"
      move-to 'castle
      goto castle-gate
  "Talk to the blacksmith"
    enter talk-blacksmith
  "Rest (recover 20 health)"
    heal 20
    time-inc! turn:
    goto village
```

### 17.2 Navigation Forms

| Form | Effect |
|------|--------|
| `goto scene` | Jump to `scene`; scene stack unchanged |
| `enter scene` | Push current scene onto stack; jump to `scene` |
| `exit` | Pop stack; return to calling scene |
| `exit-to scene` | Clear stack; jump to `scene` unconditionally |

`goto` accepts any expression that evaluates to a `SceneId`:

```
goto (if (= combat/outcome 'ongoing) combat main)
```

`SceneId` is an auto-generated enum of all declared scene names; the compiler checks all `goto` targets at compile time.

### 17.3 Sub-Scenes (Dialogue)

`enter`/`exit` give a bounded call-and-return structure without recursion. The scene stack depth is declared in game configuration; exceeding it is a compile-time error.

```
defscene talk-blacksmith:
  prompt: "The blacksmith looks up from his work."
  "Do you have any quests?"
    add! player/quest-flags 'forge-quest-active
    enter forge-quest-dialogue
  when (contains? player/quest-flags 'has-ore)
    "I have the ore you asked for."
      deliver-ore
      exit
  "Goodbye."
    exit

defscene forge-quest-dialogue:
  prompt: "\"Bring me iron ore from the dungeon, and I'll forge you a blade.\""
  "I'll do it."
    set! npcs/blacksmith/disposition 'friendly
    exit
  "Maybe later."
    exit
```

### 17.4 Dynamic Prompts and Labels

Prompts and option labels may be any `String` expression (superficial). Guard conditions must be purely discrete.

```
defscene combat:
  prompt: (str "Fighting " npcs/{combat/enemy}/name "!")
  "Attack"
    attack-enemy
    enemy-attacks
    goto (if (= combat/outcome 'ongoing) combat main)
  when (contains? player/inventory 'health-potion)
    "Use health potion"
      remove! player/inventory 'health-potion
      heal 40
      enemy-attacks
      goto (if (= combat/outcome 'ongoing) combat main)
  when (can-afford? 10)
    "Flee (lose 10 gold)"
      dec! player/gold 10
      move-to 'village
      set! combat/active False
      goto village
```

### 17.5 Scene Entry from Transaction Functions

A transaction function may request a scene transition with `goto-scene!`, which records the target in `engine/current-scene` as a log entry:

```
@transaction
@checkpoint
defn enter-combat [enemy]:
  set! combat/active  True
  set! combat/enemy   enemy
  set! combat/outcome 'ongoing
  goto-scene! combat
```

---

## 18. Python Interop

Python code may read the logic machine freely but may only modify it by returning a list of validated transactions. The compiler checks that transactions returned by Python touch only the paths declared in the function's `modifies:` contract.

### 18.1 Read-Only Python

```
defpy name [params...]
  returns:  Type
  module:   "module.path"
  function: "function_name"
  reads:    [path ...]
  modifies: []
  pure:     False
```

```python
# game/narrative.py
from storybase import State

def generate_scene_description(state: State) -> str:
    location = state.get("player/location")
    npcs_here = state.query("[npc]", where="npcs/{npc}/location == player/location")
    return build_description(location, npcs_here)
```

### 18.2 Python with Transaction Contract

```
defpy resolve-puzzle [puzzle-id]
  returns:  Bool
  module:   "game.puzzles"
  function: "check_and_resolve"
  reads:    [player/inventory  player/quest-flags]
  modifies: [player/quest-flags  player/gold]
  pure:     True
```

```python
# game/puzzles.py
from storybase import State, Transaction

def check_and_resolve(state: State, puzzle_id: str):
    if required_item(puzzle_id) in state.get("player/inventory"):
        return [
            Transaction.add("player/quest-flags", puzzle_id + "-solved"),
            Transaction.inc("player/gold", 100),
        ]
    return []
```

---

## 19. Macro System

Macros operate on syntax (the AST) at compile time. All schema-sugar forms (`defenum`, `defboundint`, etc.) are macros.

### 19.1 Defining Macros

```
defmacro name [param ...]:
  body returning a syntax tree
```

`'(...)` constructs a literal syntax tree; `,expr` splices a value; `,@expr` splices a list.

```
defmacro defenum [name vals...]:
  '(deftype ,name (Enum ,@vals))

defmacro defboundint [name lo hi]:
  '(deftype ,name (Int ,lo ,hi))
```

### 19.2 Hygiene

Generated variable names use `#` suffix to avoid capturing names from the call site:

```
defmacro swap! [a b]:
  '(let tmp# = ,a:
     set! ,a ,b
     set! ,b tmp#)
```

### 19.3 Common Utility Macros

```
unless  condition  body...
# expands to: if (not condition) body... nil

->  x  (f a)  (g b)
# thread-first: (g (f x a) b)

->>  x  (f a)  (g b)
# thread-last: (g b (f a x))

guard  [condition message]  body...
# runtime assertion with message
```

---

## 20. Standard Library Reference

### Arithmetic
```
+  -  *  div  mod
min  max  abs
clamp  value lo hi
```

### Comparison and Logic
```
=  !=  <  <=  >  >=
and  or  not
```

### Collections
```
count      coll
empty?     coll
contains?  coll  item
first  last  rest  nth  coll
conj   coll  item         # pure add (returns new collection)
disj   coll  item         # pure remove
union  coll1  coll2
intersection  coll1  coll2
```

### Strings (superficial)
```
str         a  b  ...
format      template  args...
str-length  s
substring   s  start  end
```

### Paths
```
path-join      segment ...
path-parent    path
path-leaf      path
path-segments  path
path-match?    path  pattern
path-extract   path  pattern
```

### State
```
get      path
set!     path  value
inc!     path  amount
dec!     path  amount
add!     path  value
remove!  path  value
push!    path  value
pop!     path
clear!   path
```

### Messages and Relations
```
send!      actor  message
relate!    relation  a  b
unrelate!  relation  a  b
```

### Random
```
random-bool    p
random-int     min  max
random-choice  collection
random-enum    EnumType
```

### Time
```
time-now
time-inc!  level:
time<      t1  t2
time<=     t1  t2
```

### Scheduling
```
schedule!        name: n  at: t      do: form
schedule!        name: n  every: d   do: form
cancel-schedule! name: n
```

### Queries
```
query          vars  where: condition
query-at       path  time: t
query-history  condition  from: t1  to: t2
query-changes  path  last-n: n
count  sum  any?  all?     aggregates over (query ...)
```

### Relation Queries
```
adjacent?         relation  a  b
reachable?        relation  a  b  max-hops: n
shortest-path     relation  a  b
reachable-set     relation  a     max-hops: n
inverse-adjacent? relation  b  a
```

### Future Search
```
can-reach?           condition  depth: n
find-path            condition  max-depth: n
all-paths            condition  max-depth: n  max-results: n
probability          condition  depth: n
expected-value       path       depth: n
verify-always        condition  depth: n
find-counterexample  condition  depth: n
optimal-path         condition  depth: n  metric: path-or-fn
```

### Snapshots and Replay
```
checkpoint!    name
restore!       name
list-snapshots
replay-from    index
replay-to      time: t
```

### Scenes
```
goto       scene-expr
enter      scene-name
exit
exit-to    scene-name
goto-scene! scene-name    # from inside a transaction function
```

---

## 21. Complete Example

A self-contained game fragment demonstrating all major language features.

```
# ============================================================
# SCHEMA
# ============================================================

defenum   CharClass    warrior mage rogue
defenum   Location     village forest castle dungeon
defenum   Status       alive dead unconscious
defenum   Disposition  friendly neutral hostile
defenum   CombatResult ongoing victory defeat
defenum   Chapter      intro quest finale
defenum   EnemyKind    goblin wolf bandit
defenum   ItemKind     sword health-potion key iron-ore iron-blade
defenum   NpcId        blacksmith merchant guard wanderer

defboundint  Health    0 100
defboundint  Mana      0 50
defboundint  Gold      0 999
defboundint  TurnCount 0 99999
defboundint  Damage    0 30

defsuperficial  DisplayName  String
defsuperficial  Description  String


# ============================================================
# RECORDS
# ============================================================

defrecord Entity:
  health:   Health      = 50
  status:   Status      = 'alive
  location: Location    = 'village
  name:     DisplayName = "Unknown"

defrecord Npc:
  mixin Entity
  disposition: Disposition = 'neutral

defrecord Player:
  mixin Entity
  health:      Health            = 100    # override default
  mana:        Mana              = 50
  gold:        Gold              = 30
  class:       CharClass         = 'warrior
  has-key:     Bool              = False
  inventory:   (Set ItemKind 10) = (set)
  quest-flags: (Set Symbol  20)  = (set)
  description: Description       = ""


# ============================================================
# VARIANT TYPES
# ============================================================

defvariant ActorMsg:
  alert:          { threat: NpcId  location: Location }
  trade-offer:    { item: ItemKind  price: Gold }
  attack-request: { target: NpcId  damage: Damage }


# ============================================================
# RELATIONS
# ============================================================

defrelation exits: Location -> (Set Location max: 4):
  village -> {'forest}
  forest  -> {'village 'dungeon}
  castle  -> {'village}
  dungeon -> {'forest 'castle}


# ============================================================
# STATE
# ============================================================

defstate player: Player = Player(name: "Hero")
defstate npcs/{npc}: Npc = Npc()    # npc : (SymbolOf npcs); instances: NpcId

defstate world:
  turn:    TurnCount = 0
  chapter: Chapter   = 'intro

defstate combat:
  active:  Bool         = False
  enemy:   NpcId        = 'wanderer
  outcome: CombatResult = 'ongoing


# ============================================================
# SCHEDULING
# ============================================================

defschedule morning-cycle:
  every:  [+1 0 0 0]
  offset: [0 0 0 0]
  do:
    for npc ['blacksmith 'merchant 'guard]:
      set! npcs/{npc}/location 'village
    set! npcs/blacksmith/disposition 'friendly


# ============================================================
# ACTORS
# ============================================================

defactor blacksmith:
  state:     npcs/blacksmith
  perceives: [world/turn  player/location  player/quest-flags
               npcs/blacksmith/*]
  inbox:     (List ActorMsg max: 8)
  behavior:  blacksmith-behavior
  priority:  10

defactor guard:
  state:     npcs/guard
  perceives: [player/location  npcs/*/location  npcs/guard/*]
  inbox:     (List ActorMsg max: 8)
  behavior:  guard-behavior
  priority:  20

@transaction
defn blacksmith-behavior []:
  when (= player/location 'village):
    set! npcs/blacksmith/disposition 'friendly
  for msg npcs/blacksmith/inbox:
    match msg:
      alert { threat location }:
        set! npcs/blacksmith/disposition 'hostile
        send! guard (ActorMsg/attack-request target: threat  damage: 10)
      trade-offer { item price }:
        when (>= player/gold price):
          dec! player/gold price
          add! player/inventory item
      _: pass

@transaction
defn guard-behavior []:
  for msg npcs/guard/inbox:
    match msg:
      attack-request { target damage }:
        set! npcs/guard/disposition 'hostile
      _: pass


# ============================================================
# TAGS AND HOOKS
# ============================================================

deftag transaction
deftag reversible
deftag checkpoint

hook transaction:
  post: (broadcast 'state-changed changes)

hook checkpoint:
  pre: (checkpoint! fn-name)


# ============================================================
# PURE FUNCTIONS
# ============================================================

defn alive? [entity]:
  = npcs/{entity}/status 'alive

defn can-afford? [price]:
  >= player/gold price

defn hostile-nearby? []:
  any? query npc
    where: (and (= npcs/{npc}/location player/location)
                (= npcs/{npc}/disposition 'hostile))

defn base-damage []:
  match player/class
    'warrior  15
    'rogue    12
    'mage      8

defn quest-complete? []:
  and (contains? player/quest-flags 'defeated-goblin-king)
      (contains? player/quest-flags 'found-crown)
      (= player/location 'castle)


# ============================================================
# TRANSACTION FUNCTIONS
# ============================================================

@transaction
@reversible
defn move-to [loc]:
  pre:  = player/status 'alive
  set! player/location loc
  time-inc! turn:

@transaction
@reversible
defn take-damage [amount]:
  pre:
    amount > 0
    = player/status 'alive
  post:
    >= player/health 0
  dec! player/health amount
  when (<= player/health 0)
    set! player/status 'dead
    set! player/description "You have fallen."

@transaction
defn heal [amount]:
  pre:  = player/status 'alive
  inc! player/health (min amount (- 100 player/health))

@transaction
defn pickup-item [item]:
  pre:  not (contains? player/inventory item)
  post: contains? player/inventory item
  add! player/inventory  item
  add! player/quest-flags item

@transaction
defn buy-item [item price]:
  pre:  can-afford? price
  dec! player/gold price
  pickup-item item

@transaction
@checkpoint
defn enter-combat [enemy]:
  set! combat/active  True
  set! combat/enemy   enemy
  set! combat/outcome 'ongoing
  goto-scene! combat

@transaction
defn attack-enemy []:
  pre:  = combat/active True
  let base  = (base-damage)
      roll  = (random-int 0 10)
      total = (+ base roll):
    dec! npcs/{combat/enemy}/health total
    set! player/description (str "You deal " total " damage.")
    when (<= npcs/{combat/enemy}/health 0)
      set! npcs/{combat/enemy}/status 'dead
      set! combat/outcome 'victory
      let reward = (random-int 10 30):
        inc! player/gold reward

@transaction
defn enemy-attacks []:
  let dmg = (random-int 5 15):
    take-damage dmg
    when (= player/status 'dead)
      set! combat/outcome 'defeat

@transaction
defn random-encounter []:
  when (random-bool 0.25)
    let kind = (random-enum EnemyKind):
      set! npcs/wanderer/status      'alive
      set! npcs/wanderer/health      30
      set! npcs/wanderer/location    player/location
      set! npcs/wanderer/disposition 'hostile
      enter-combat 'wanderer

@transaction
defn deliver-ore []:
  pre:  contains? player/quest-flags 'iron-ore
  remove! player/inventory 'iron-ore
  add!    player/quest-flags 'delivered-ore
  set!    npcs/blacksmith/disposition 'friendly

@transaction
defn end-chapter []:
  when (quest-complete?)
    set! world/chapter 'finale
    inc! player/gold 500


# ============================================================
# SCENES
# ============================================================

defscene main:
  prompt: "What will you do?"
  goto
    match player/location
      'village  village
      'forest   forest
      'castle   castle
      'dungeon  dungeon

defscene village:
  prompt: "You are in the village square."
  "Enter the forest"
    move-to 'forest
    random-encounter
    goto forest
  when (can-afford? 40)
    "Buy a health potion (40 gold)"
      buy-item 'health-potion 40
      goto village
  when (and (can-afford? 200)
            (contains? player/quest-flags 'delivered-ore))
    "Collect your iron blade from the blacksmith (200 gold)"
      buy-item 'iron-blade 200
      goto village
  when player/has-key
    "Ride to the castle"
      move-to 'castle
      goto castle
  "Talk to the blacksmith"
    enter talk-blacksmith
  "Rest (recover 20 health)"
    heal 20
    time-inc! turn:
    goto village

defscene forest:
  prompt: "You stand in the dark forest."
  when (not (contains? player/quest-flags 'goblin-king-defeated))
    "Press deeper — into the dungeon"
      move-to 'dungeon
      goto dungeon
  "Return to the village"
    move-to 'village
    goto village

defscene dungeon:
  prompt: "The dungeon is dark and cold."
  "Explore further"
    random-encounter
    goto dungeon
  "Return to the forest"
    move-to 'forest
    goto forest

defscene castle:
  prompt: "You stand before the castle gates."
  when (quest-complete?)
    "Present the crown to the king"
      end-chapter
      goto castle
  "Return to the village"
    move-to 'village
    goto village

defscene combat:
  prompt: (str "Fighting " npcs/{combat/enemy}/name "!")
  "Attack"
    attack-enemy
    enemy-attacks
    goto (if (= combat/outcome 'ongoing) combat main)
  when (contains? player/inventory 'health-potion)
    "Use health potion"
      remove! player/inventory 'health-potion
      heal 40
      enemy-attacks
      goto (if (= combat/outcome 'ongoing) combat main)
  when (can-afford? 10)
    "Flee (lose 10 gold)"
      dec! player/gold 10
      move-to 'village
      set! combat/active False
      goto village

defscene talk-blacksmith:
  prompt: "The blacksmith looks up from his work."
  when (not (contains? player/quest-flags 'forge-quest-active))
    "Do you have any quests?"
      add! player/quest-flags 'forge-quest-active
      enter forge-quest-dialogue
  when (contains? player/quest-flags 'iron-ore)
    "I have the iron ore you asked for."
      deliver-ore
      exit
  "Goodbye."
    exit

defscene forge-quest-dialogue:
  prompt: "\"Bring me iron ore from the dungeon, and I'll forge you a blade.\""
  "I'll do it."
    exit
  "Maybe later."
    exit


# ============================================================
# QUERIES AND VERIFICATION
# ============================================================

# Who is near the player right now?
query npc
  where: (and (= npcs/{npc}/location player/location)
              (= npcs/{npc}/status 'alive))

# Is the castle reachable in the world graph?
reachable? exits 'village 'castle  max-hops: 5
→ True

# What is the shortest overland route to the castle?
shortest-path exits player/location 'castle
→ ['village 'forest 'dungeon 'castle]

# Can the player complete the quest within 50 turns?
can-reach? (quest-complete?)
  depth: 50

# Is there a sequence of actions that kills the player in 5 turns?
find-counterexample (= player/status 'alive)
  depth: 5

# What is the probability of winning the first combat?
probability (= combat/outcome 'victory)
  depth: 10

# Verify health never goes negative on any path
verify-always (>= player/health 0)
  depth: 100

# What was the player's location at the start of the quest chapter?
query-at player/location
  time: [0 1 0 0]
```

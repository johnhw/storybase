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

Three principles govern the design:

**Separation of logic and presentation.** All branching, conditionals, and gameplay decisions depend only on *discrete* (bounded, enumerable) types. Text, visuals, and other presentation data are *superficial* types: they can be displayed and updated, but no computation may branch on their values. This separation makes the game state machine finite and fully analysable.

**The transaction log is the ground truth.** Every change to state is recorded as a timestamped transaction. The current state is always a projection of the log. This gives automatic save/load, full replay, debugging by time-travel into history, and the basis for future-state search.

**Bounded exhaustive search over futures.** Because all logic depends only on discrete bounded types, and all random sources produce a finite set of outcomes, the reachable future states form a finite (if large) graph. The engine can search this graph to answer questions like *can the player reach the castle?* or *is it possible to die in the next five turns?*

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
npcs/{npc}/location    # npc is a variable in scope

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

One form per line is the norm; infix sub-expressions are usually written with explicit parens to avoid ambiguity:

```
defn clamp-heal [amount]:
  inc! player/health (min amount (- 100 player/health))
```

### 2.4 Named Arguments

Any argument of the form `name: value` is a named (keyword) argument. Order among named arguments does not matter; they may not precede positional arguments.

```
can-reach? (= player/location 'castle)
  depth: 20
  strategy: breadth-first

query-history (= player/location 'village)
  from: [0 0 0]
  to:   [20 0 0]
```

### 2.5 Collection Literals

```
# Set
#{'sword 'potion 'key}

# List (ordered, indexed)
['north 'east 'south 'west]

# Map (symbol keys)
{name: "Aldric"  class: 'warrior  level: 5}

# Empty collections
#{}   []   {}
```

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
| Option | `(Option T)` | \|T\| + 1 |
| Bounded set | `(Set T max)` | Σ C(\|T\|, i) for i = 0..max |
| Bounded list | `(List T max)` | (\|T\|+1)^max (ordered, allows duplicates) |
| Struct | `(Struct f1: T1 f2: T2 ...)` | \|T1\| × \|T2\| × ... |

### 3.2 Superficial Types

Superficial types are **unbounded** and used exclusively for presentation: narrative text, display names, visual parameters. The compiler enforces:

- No superficial value may appear in a conditional expression (`if`, `when`, `cond`, `match`).
- No superficial value may be passed as an argument to a function that is declared or inferred to return a discrete type.
- No random source may produce a superficial value.
- Superficial values *may* be constructed from discrete values (e.g. building a description string from an enum).

| Type | Notes |
|------|-------|
| `String` | Narrative text, display names |
| `Float` | Visual/audio parameters, timers |
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

---

## 4. Path Syntax

Paths are the fundamental addressing mechanism. Any token containing `/` is a path. Paths are absolute; a leading `/` is optional syntactic noise and is stripped.

```
player/health          # same as /player/health
world/chapter
npcs/blacksmith/hp
```

### 4.1 Variable Interpolation

`{varname}` splices a variable into a path segment. The variable must be a `Symbol` or a type that unambiguously identifies a state node.

```
npcs/{npc}/health        # npc is a Symbol variable in scope
world/{zone}/discovered  # zone is a Symbol variable
```

### 4.2 Path Patterns (Query Context Only)

Path patterns are legal only inside `query`, `query-history`, `can-reach?`, and similar search forms. They are **not** legal as the target of `set!`, `inc!`, etc.

| Pattern | Matches |
|---------|---------|
| `player/health` | Exactly `/player/health` |
| `player/*` | Any single segment under `/player` |
| `player/**/strength` | `strength` at any depth under `/player` |
| `npcs/*/location` | `location` under any direct child of `/npcs` |
| `player/(health\|mana)` | Either `health` or `mana` under `/player` |
| `player/!inventory` | Any field under `/player` except `inventory` |
| `player/!(health\|mana)` | Any field except `health` or `mana` |
| `player/inventory/*$` | Exactly one segment past `inventory` (end anchor) |

Variables in patterns bind to matched segments:

```
# In a query, segments prefixed with a plain name and used inside {} bind as variables
query [npc attr]
  where: (discrete? npcs/{npc}/{attr})
```

### 4.3 Indexed Access

For `List` and `BoundedList` values, index and slice notation is legal in both read and write positions.

```
player/waypoints[0]       # first element
player/waypoints[-1]      # last element
player/waypoints[1:4]     # elements 1, 2, 3
player/waypoints[::2]     # every other element (read only)
```

### 4.4 Path Semantics in defstate

When a `defstate` uses `{var}` in its path, it declares a *family* of state nodes, one per value of the variable's type. The variable ranges over all known instances.

```
defstate npcs/{npc}:
  health: Health = 50
  ...
```

This declares that for every symbol registered as an NPC, a subtree `npcs/{npc}/...` is allocated with the given schema.

---

## 5. Schema Definition

All types and state shapes are declared in a schema block before any game logic. The compiler uses the schema to:
- Check that every path written or read has a declared type
- Compute discrete state-space bounds for future-state search
- Enforce the discrete/superficial boundary

### 5.1 Base Type Declaration

```
deftype Name TypeExpr
```

`TypeExpr` is one of the type forms from §3.

```
deftype Health     (Int 0 100)
deftype Gold       (Int 0 999)
deftype TurnCount  (Int 0 999999)
deftype Inventory  (Set Symbol 10)
deftype QuestFlags (Set Symbol 20)
deftype CharClass  (Enum warrior mage rogue)
deftype Location   (Enum village forest castle dungeon tower)
deftype Status     (Enum alive dead unconscious)
deftype Liveness   (Enum alive dead undead)
deftype Disposition (Enum friendly neutral hostile)
deftype Chapter    (Enum intro act1 act2 finale)
deftype TimeOfDay  (Enum morning noon evening night)
```

### 5.2 Schema Macros

`deftype` is the base form; the following are macros that expand to it. They exist purely for readability and do not add expressive power.

```
defenum    Name  val1 val2 ...
# expands to: deftype Name (Enum val1 val2 ...)

defboundint  Name  min max
# expands to: deftype Name (Int min max)

defboundset  Name  ElementType  max
# expands to: deftype Name (Set ElementType max)

defboundlist Name  ElementType  max
# expands to: deftype Name (List ElementType max)

defsuperficial Name  BaseType
# expands to: deftype Name BaseType
# and marks Name as superficial for compiler enforcement
```

In practice a schema section uses macros throughout:

```
defenum    CharClass    warrior mage rogue
defenum    Location     village forest castle dungeon tower
defenum    Status       alive dead unconscious
defenum    Disposition  friendly neutral hostile
defenum    Chapter      intro act1 act2 finale
defenum    TimeOfDay    morning noon evening night

defboundint  Health    0 100
defboundint  Mana      0 100
defboundint  Gold      0 999
defboundint  TurnCount 0 999999

defboundset  Inventory   Symbol 10
defboundset  QuestFlags  Symbol 20

defsuperficial  DisplayName  String
defsuperficial  Description  String
```

### 5.3 State Declaration

```
defstate path:
  fieldname: TypeName = default
  ...
```

Fields whose types are discrete are logic fields. Fields whose types are superficial are presentation fields. The compiler infers this from the type declared in the schema.

```
defstate player:
  # Discrete — affect game logic
  health:       Health      = 100
  mana:         Mana        = 100
  status:       Status      = 'alive
  location:     Location    = 'village
  class:        CharClass   = 'warrior
  gold:         Gold        = 0
  has-key:      Bool        = False
  inventory:    Inventory   = #{}
  quest-flags:  QuestFlags  = #{}
  # Superficial — presentation only
  name:         DisplayName = "Hero"
  description:  Description = ""

defstate world:
  turn:        TurnCount  = 0
  chapter:     Chapter    = 'intro
  time-of-day: TimeOfDay  = 'morning

defstate npcs/{npc}:
  health:      Health      = 50
  status:      Status      = 'alive
  location:    Location    = 'village
  disposition: Disposition = 'neutral
  name:        DisplayName = "Unknown"
```

### 5.4 Components (Reusable Field Groups)

```
defcomponent living:
  health:  Health  = 100
  status:  Status  = 'alive

defcomponent positioned:
  location:  Location  = 'village

defstate player:
  include living
  include positioned
  mana:  Mana  = 100
  gold:  Gold  = 0
  ...
```

`include` splices all fields from the component at that point. Field names must not collide.

---

## 6. Functions

### 6.1 Pure Functions

A function is *pure* if it performs no state mutations and calls no random sources. The compiler detects this automatically; no annotation is required. Pure functions may read any state path including superficial fields (to build return values), but their return type determines whether the result is discrete or superficial.

```
defn can-afford? [price]:
  >= player/gold price

defn alive? [entity]:
  = npcs/{entity}/status 'alive

defn hostile-nearby? []:
  any? (query npc where: (and (= npcs/{npc}/location player/location)
                              (= npcs/{npc}/disposition 'hostile)))

defn max-damage []:
  match player/class
    'warrior  20
    'mage     12
    'rogue    18
```

The `?` suffix is a convention for functions returning `Bool`. It is not enforced by the compiler but is expected by tooling (e.g. the REPL highlights predicate results differently).

### 6.2 Transaction Functions

A function is a *transaction* if it calls any mutation primitive: `set!`, `inc!`, `dec!`, `add!`, `remove!`, `push!`, `pop!`. The compiler detects this automatically and records it in the function's inferred contract (which paths it reads and which it modifies).

```
defn move-to [loc]:
  set! player/location loc

defn take-damage [amount]:
  dec! player/health amount
  when (<= player/health 0)
    set! player/status 'dead

defn pickup-item [item]:
  add! player/inventory  item
  add! player/quest-flags item
  set! player/description (str "You picked up " item)

defn buy-item [item price]:
  dec! player/gold price
  pickup-item item
```

### 6.3 Pre/Post Conditions

Pre and post conditions are declared inside the function body, before the imperative statements. They are checked at runtime in debug mode and can be statically verified by the future-query engine in test mode.

Pre-conditions: assertions that must hold when the function is entered. A violated pre-condition is a caller bug.
Post-conditions: assertions that must hold when the function returns. A violated post-condition is an implementation bug.

Both must use only discrete values (same rule as all logic).

```
defn take-damage [amount]:
  pre:
    amount > 0
    amount <= 100
    = player/status 'alive
  post:
    >= player/health 0
  dec! player/health amount
  when (<= player/health 0)
    set! player/status 'dead

defn pickup-item [item]:
  pre:
    not (contains? player/inventory item)
  post:
    contains? player/inventory item
  add! player/inventory  item
  add! player/quest-flags item
  set! player/description (str "You picked up " item)
```

### 6.4 Local Bindings

```
defn resolve-attack [enemy]:
  let base   = (max-damage)
      bonus  = (if (contains? player/quest-flags 'berserk) 5 0)
      total  = (+ base bonus):
    dec! npcs/{enemy}/health total
    set! player/description (str "You deal " total " damage.")
```

### 6.5 Control Flow

```
# Conditional
if condition then-expr else-expr

if (< player/health 20)
  set! player/status 'critical
  set! player/status 'healthy

# One-armed conditional
when condition body...

when (contains? player/quest-flags 'found-key)
  set! player/has-key True

# Multi-branch
cond:
  (< player/health 20)  (set! player/status 'critical)
  (< player/health 50)  (set! player/status 'wounded)
  True                  (set! player/status 'healthy)

# Match on discrete value
match player/class
  'warrior  (inc! damage 5)
  'mage     (inc! mana-cost 2)
  'rogue    (inc! crit-chance 3)

# Counted loop
dotimes i 3
  push! player/echoes player/location

# Iteration
for item player/inventory
  log (str "Carrying: " item)
```

---

## 7. Mutation Primitives

All mutation primitives produce a transaction in the log. They are only legal inside transaction functions.

```
set!    path value       # set path to value
inc!    path amount      # path = path + amount  (discrete numeric)
dec!    path amount      # path = path - amount  (discrete numeric)
add!    path value       # add value to set
remove! path value       # remove value from set
push!   path value       # append value to list
pop!    path             # remove last element from list
clear!  path             # set collection to empty
```

All paths must be declared in the schema. The compiler checks that the value type matches the declared field type.

---

## 8. Decorators and Tags

Tags classify functions. They are declared globally with `deftag` and applied as decorators on the lines immediately before a `defn`.

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

User-defined tags are declared the same way. Tag names are plain symbols.

### 8.2 Applying Decorators

One decorator per line, immediately before `defn`. No blank lines between decorators and the function.

```
@transaction
@reversible
@logged
defn move-to [loc]:
  set! player/location loc

@transaction
@validated
defn take-damage [amount]:
  pre:
    amount > 0
    = player/status 'alive
  post:
    >= player/health 0
  dec! player/health amount
  when (<= player/health 0)
    set! player/status 'dead
```

### 8.3 Auto-Detected Properties

The compiler infers these without annotation. Manual annotations override detection.

| Property | Inferred when |
|----------|--------------|
| `transaction` | body contains any mutation primitive |
| `pure` | no mutations, no random sources, no I/O |
| `uses-random` | body calls any `random-*` form |
| `reads: [paths]` | static read-set analysis |
| `modifies: [paths]` | static write-set analysis |

A function may use `@no-transaction` to suppress the auto-detected `transaction` tag (e.g. for a function that writes only to a debug log outside the logic machine).

---

## 9. Hooks and Aspects

Hooks are cross-cutting pre/post callbacks registered on a tag. They execute around every function carrying that tag.

### 9.1 Hook Definition

```
hook tagname:
  pre:  form...
  post: form...
```

Inside a hook body the following bindings are available:

| Name | In | Value |
|------|----|-------|
| `fn-name` | pre, post | Symbol name of the called function |
| `fn-args` | pre, post | List of argument values |
| `pre-state` | post | Snapshot of discrete state before the call |
| `post-state` | post | Discrete state after the call |
| `changes` | post | List of `[path old-value new-value]` triples |
| `result` | post | Return value of the function |

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

### 9.2 Aspects (Reusable Hook Bundles)

An aspect is a named pre/post pair that can be applied as a decorator to individual functions.

```
defaspect checkpoint-around:
  pre:  (checkpoint! fn-name)
  post: (when (failed? result) (rollback-to-last-checkpoint))

defaspect timed:
  pre:  (start-timer fn-name)
  post: (record-timing fn-name elapsed)
```

Applied as decorators:

```
@transaction
@checkpoint-around
@timed
defn risky-combat-resolution [enemy]:
  ...
```

### 9.3 Execution Order

```
Hook pre      (outermost, registered hooks fire in declaration order)
  Aspect pre  (in decorator order)
    pre: conditions
    Body
    post: conditions
  Aspect post (in reverse decorator order)
Hook post     (outermost, reverse declaration order)
```

---

## 10. Random Sources

All randomness is isolated to a small set of primitives. Every call is logged with its seed and outcome, making replays fully deterministic. In search mode the engine enumerates all possible outcomes rather than sampling.

```
random-bool   p                  # True with probability p;  2 outcomes
random-int    min max            # Uniform integer in [min, max];  (max−min+1) outcomes
random-choice collection         # Uniform draw from a discrete collection
random-enum   EnumType           # Uniform draw from an enumeration
```

**Rules:**
- Random primitives may only produce discrete values. They may not produce `String`, `Float`, or any superficial type.
- A function that calls any random primitive is auto-tagged `uses-random`.
- In test/search mode `random-int min max` branches into `(max−min+1)` successor states, one per possible outcome.

```
defn random-encounter []:
  @transaction
  when (random-bool 0.3):
    let enemy = (random-enum EnemyKind):
      spawn-enemy enemy

defn roll-damage [base]:
  + base (random-int 0 10)
```

---

## 11. Transaction Log and Time

### 11.1 Transaction Format

Every mutation produces a log entry:

```
Trans 514  time:[1 5 3 10]  (Add player/inventory 'goo-bits)
Trans 515  time:[1 5 3 10]  (Inc player/fear/goo 1)
Trans 516  time:[1 5 3 11]  (Set player/location 'forest)
```

Each transaction records: a global sequence index, a hierarchical time tuple, the operation, and (for reversible functions) enough information to reconstruct the pre-state.

Operations: `Set`, `Inc`, `Dec`, `Add`, `Remove`, `Push`, `Pop`, `Clear`.

### 11.2 Hierarchical Time

Time is a tuple of integers `[episode  chapter  turn  tick]`. The number of levels is configurable per game. Time is strictly increasing within a play session.

```
time-now                       # returns current time tuple e.g. [1 3 7 2]
time-inc! turn:                # advance turn counter, reset lower levels
time-inc! tick:                # advance tick, keep upper levels
time-level-of turn             # returns the index of the 'turn' level
```

### 11.3 Snapshotting

```
# Automatic: engine snapshots every N transactions
configure-snapshots!
  interval:   100
  keep-last:  10

# Manual: named checkpoint
checkpoint! 'before-boss-fight  # returns snapshot id

# Restore
restore! 'before-boss-fight

# List available snapshots
list-snapshots
```

Restoring a snapshot replays all transactions since that snapshot point on top of the snapshot's frozen state. Delta snapshots (snapshots that store only the diff from a parent snapshot) are used internally to keep memory usage manageable.

### 11.4 Replay

```
replay-all                          # rebuild state from transaction 0
replay-from 200                     # replay from transaction 200 onwards
replay-to time: [1 3 7 0]          # replay until that time point
replay-from 200
  breakpoint: (< player/health 10)  # pause when condition first holds
```

### 11.5 Historical Queries

```
# State of a path at a specific time
query-at player/location
  time: [1 3 5 0]
→ 'forest

# All times at which a condition held
query-history (= player/location 'village)
  from: [0 0 0 0]
  to:   [2 0 0 0]
→ [[0 0 0 0]  [0 0 5 2]  [1 2 3 0]]

# History of changes to a path
query-changes player/health
  last-n: 5
→ [[[1 2 0 0]  100  90]
   [[1 2 1 3]   90  80]
   [[1 2 2 0]   80  95]]   # healed
```

---

## 12. Query Language

### 12.1 Current-State Queries

`query` binds one or more variables to values that satisfy a `where:` condition. It returns all solutions.

```
query npc
  where: (= npcs/{npc}/location player/location)
→ ['blacksmith 'merchant]

query [npc hp]
  where: (and (= npcs/{npc}/health hp)
              (< hp 20))
→ [['wounded-guard 15]  ['dying-merchant 8]]
```

The `where:` clause uses only discrete values and pure functions. Path patterns are legal inside `query` where clauses.

### 12.2 Aggregation

```
count query npc
  where: (= npcs/{npc}/disposition 'hostile)
→ 3

sum query hp
  where: (= npcs/{npc}/health hp)
→ 143

any? query npc
  where: (= npcs/{npc}/disposition 'hostile)
→ True

all? query npc
  where: (> npcs/{npc}/health 0)
→ False
```

### 12.3 Future-State Queries

Future queries search the game graph up to a given depth. The game graph is built lazily: from any state, the successors are the states reachable by applying each possible transaction with each possible random outcome and each possible user choice.

```
# Can a condition ever be reached?
can-reach? (= player/location 'castle)
  depth: 20
→ True

# Find one path of actions that reaches the goal
find-path (= player/location 'castle)
  max-depth: 15
→ ['enter-forest 'find-bridge 'cross-bridge 'approach-gate 'open-gate]

# All paths up to max-depth (up to max-results results)
all-paths (= player/location 'castle)
  max-depth: 10
  max-results: 5
→ [['enter-forest 'find-bridge ...]
   ['talk-wizard 'get-scroll 'use-scroll]
   ...]

# Probability of a condition holding (uniform over random outcomes)
probability (= combat/outcome 'victory)
  depth: 10
→ 0.73

# Expected value of a discrete field after N steps
expected-value player/gold
  depth: 20
→ 187.4

# Verify a property holds on ALL reachable paths
verify-always (>= player/health 0)
  depth: 50
→ True

# Find a counterexample (path that violates the property)
find-counterexample (> player/gold 0)
  depth: 10
→ ['buy-sword 'buy-armour 'donate-to-temple]

# Optimal sequence maximising an objective
optimal-path (= quest/status 'complete)
  depth: 30
  metric: player/gold          # maximise gold at goal
→ ['accept-quest 'kill-goblins 'loot-chest 'return-to-merchant]
```

### 12.4 Bidirectional Search

When a goal condition is highly specific (a small fraction of the total state space), the engine automatically switches to bidirectional BFS: expanding a forward frontier from the current state and a backward frontier from the goal, meeting in the middle. This halves the effective search depth, reducing worst-case complexity from O(B^D) to O(B^(D/2)).

Functions tagged `@reversible` provide an inverse that the backward frontier uses to expand. For functions built from primitive operations (`set!`, `inc!`, `dec!`, `add!`, `remove!`) the compiler derives the inverse automatically. Complex functions may declare an explicit inverse:

```
@transaction
@reversible
defn apply-curse []:
  dec! player/health 10
  set! player/status 'cursed
  # inverse auto-derived: inc! player/health 10, restore player/status
```

---

## 13. Menus and Dialogue

Menus are first-class constructs. Guard conditions must use only discrete values.

### 13.1 Basic Menu

```
defn village-options []:
  menu "You stand in the village square.":
    "Enter the forest"
      move-to 'forest
    "Rest at the inn"
      rest-at-inn
    when (can-afford? 50)
      "Visit the shop"
        shop-menu
    when player/has-key
      "Ride to the castle"
        move-to 'castle
```

Each option is `label body`. The label is a `String` (superficial, display only). The body is any sequence of forms, including nested menus.

### 13.2 Conditional Options

`when` guards are evaluated against current discrete state. An option whose guard is `False` is not presented to the player.

```
when (and (contains? player/quest-flags 'has-ore)
          (= npcs/blacksmith/disposition 'friendly))
  "Ask the blacksmith to forge a sword"
    blacksmith-forge-menu
```

### 13.3 Nested Dialogue

```
defn talk-to-blacksmith []:
  menu "The blacksmith looks up.":
    "Do you have any quests?"
      fn []:
        add! player/quest-flags 'forge-quest-active
        menu "The blacksmith nods slowly.":
          "I'll do it."
            accept-forge-quest
          "Maybe later."
            end-conversation
    when (contains? player/quest-flags 'has-ore)
      "I have the ore you asked for."
        deliver-ore
    "Goodbye."
      end-conversation
```

---

## 14. Python Interop

Python code may read the logic machine freely but may only modify it by returning a list of validated transactions. The compiler checks that transactions returned by Python touch only the paths declared in the function's `:modifies` contract.

### 14.1 Read-Only Python

```
defpy describe-scene []
  returns:  String
  module:   "game.narrative"
  function: "generate_scene_description"
  reads:    [player/* world/* npcs/*/location npcs/*/disposition]
  modifies: []
  pure:     False
```

```python
# game/narrative.py
from storybase import State

def generate_scene_description(state: State) -> str:
    location = state.get("player/location")
    npcs_here = state.query("[npc]", where="npcs/{npc}/location == player/location")
    # ... build description string
    return description
```

### 14.2 Python with Transaction Contract

```
defpy resolve-puzzle [puzzle-id]
  returns:  Bool
  module:   "game.puzzles"
  function: "check_and_resolve"
  reads:    [player/inventory player/quest-flags]
  modifies: [player/quest-flags player/gold]
  pure:     True
```

```python
# game/puzzles.py
from storybase import State, Transaction

def check_and_resolve(state: State, puzzle_id: str):
    inventory = state.get("player/inventory")
    if required_item(puzzle_id) in inventory:
        return [
            Transaction.add("player/quest-flags", puzzle_id + "-solved"),
            Transaction.inc("player/gold", 100),
        ]
    return []
    # StoryBase validates transactions against :modifies before applying them.
```

---

## 15. Macro System

Macros operate on syntax (the AST) at compile time. They make it possible to build convenient syntax without adding primitives to the language. All schema-sugar forms (`defenum`, `defboundint`, etc.) are macros.

### 15.1 Defining Macros

```
defmacro name [param ...]:
  body returning a syntax tree
```

Inside a macro body, `'(...)` constructs a literal syntax tree and `,expr` splices a value into it (quasiquote / unquote). `,@expr` splices a list of forms.

```
defmacro defenum [name vals...]:
  '(deftype ,name (Enum ,@vals))

defenum Status alive dead unconscious
# expands to:
# deftype Status (Enum alive dead unconscious)
```

```
defmacro defboundint [name lo hi]:
  '(deftype ,name (Int ,lo ,hi))

defmacro defboundset [name elem-type max-size]:
  '(deftype ,name (Set ,elem-type ,max-size))
```

### 15.2 Hygiene

Generated variable names use `#` suffix to ensure they don't capture names from the call site:

```
defmacro swap! [a b]:
  '(let tmp# = ,a:
     set! ,a ,b
     set! ,b tmp#)
```

### 15.3 Common Utility Macros

These are in the standard library, defined using `defmacro`:

```
unless  condition  body...
# expands to: if (not condition) body... nil

->  x  (f a)  (g b)
# thread-first: expands to: (g (f x a) b)

->>  x  (f a)  (g b)
# thread-last: expands to: (g b (f a x))

guard  [condition message]  body...
# runtime assertion with message
```

---

## 16. Standard Library Reference

### Arithmetic
```
+  -  *  div  mod      # integer arithmetic
min  max  abs           # integer min/max/absolute-value
clamp  value lo hi      # clamp value to range
```

### Comparison and Logic
```
=  !=  <  <=  >  >=
and  or  not
```

### Collections
```
count   coll
empty?  coll
contains?  coll  item
first  coll
rest   coll
last   coll
nth    coll  index
conj   coll  item         # return new coll with item added (pure)
disj   coll  item         # return new coll with item removed (pure)
union  coll1  coll2
intersection  coll1  coll2
```

### Strings (superficial)
```
str   a  b  ...           # concatenate as string
format  template  args... # interpolated format
str-length  s
substring   s  start  end
```

### Paths
```
path-join    segment ...
path-parent  path
path-leaf    path
path-segments  path
path-match?  path  pattern
path-extract  path  pattern   # returns binding map
```

### State
```
get   path
set!  path  value
inc!  path  amount
dec!  path  amount
add!  path  value
remove!  path  value
push!  path  value
pop!   path
clear! path
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
time<   t1  t2
time<=  t1  t2
```

### Queries
```
query          vars  where: condition
query-at       vars  time: t  where: condition
query-history  condition  from: t1  to: t2
query-changes  path  last-n: n
count          (query ...)
sum            (query ...)
any?           (query ...)
all?           (query ...)
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

### Snapshots
```
checkpoint!   name
restore!      name
list-snapshots
replay-from   index
replay-to     time: t
```

---

## 17. Complete Example

The following is a self-contained game fragment demonstrating all major language features.

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

defboundint  Health    0 100
defboundint  Mana      0 50
defboundint  Gold      0 999
defboundint  TurnCount 0 99999
defboundint  Damage    0 30

defboundset  Inventory   Symbol 10
defboundset  QuestFlags  Symbol 20

defsuperficial  DisplayName  String
defsuperficial  Description  String


# ============================================================
# STATE
# ============================================================

defstate player:
  health:      Health      = 100
  mana:        Mana        = 50
  status:      Status      = 'alive
  location:    Location    = 'village
  class:       CharClass   = 'warrior
  gold:        Gold        = 30
  has-key:     Bool        = False
  inventory:   Inventory   = #{}
  quest-flags: QuestFlags  = #{}
  name:        DisplayName = "Hero"
  description: Description = ""

defstate world:
  turn:    TurnCount  = 0
  chapter: Chapter    = 'intro

defstate npcs/{npc}:
  health:      Health      = 50
  status:      Status      = 'alive
  location:    Location    = 'village
  disposition: Disposition = 'neutral
  name:        DisplayName = "Unknown"

defstate combat:
  active:   Bool          = False
  enemy:    Symbol        = 'none
  outcome:  CombatResult  = 'ongoing


# ============================================================
# TAGS AND HOOKS
# ============================================================

deftag transaction
deftag reversible
deftag checkpoint

hook transaction:
  post: (broadcast 'state-changed changes)

hook checkpoint:
  pre:  (checkpoint! fn-name)


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
  set! player/description (str "You picked up " item)

@transaction
defn buy-item [item price]:
  pre:  can-afford? price
  dec! player/gold price
  pickup-item item

@transaction
@checkpoint
defn enter-combat [enemy]:
  set! combat/active True
  set! combat/enemy  enemy
  set! combat/outcome 'ongoing

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
defn end-chapter []:
  when (quest-complete?)
    set! world/chapter 'finale
    inc! player/gold 500

@transaction
defn random-encounter []:
  when (random-bool 0.25)
    let kind = (random-enum EnemyKind):
      set! npcs/wanderer/status 'alive
      set! npcs/wanderer/health 30
      set! npcs/wanderer/location player/location
      set! npcs/wanderer/disposition 'hostile
      enter-combat 'wanderer


# ============================================================
# MENUS
# ============================================================

defn main-menu []:
  match player/location
    'village  (village-menu)
    'forest   (forest-menu)
    'castle   (castle-menu)
    'dungeon  (dungeon-menu)

defn village-menu []:
  menu "You are in the village.":
    "Enter the forest"
      do (move-to 'forest) (random-encounter) (main-menu)
    when (can-afford? 40)
      "Buy a health potion (40 gold)"
        do (buy-item 'health-potion 40) (village-menu)
    when (and (can-afford? 200) (contains? player/quest-flags 'has-ore))
      "Commission a blade from the blacksmith (200 gold)"
        do (buy-item 'iron-blade 200) (village-menu)
    when player/has-key
      "Ride to the castle"
        do (move-to 'castle) (main-menu)
    "Rest (recover 20 health)"
      do (heal 20) (time-inc! turn:) (village-menu)

defn forest-menu []:
  menu "You stand in the dark forest.":
    when (not (contains? player/quest-flags 'goblin-king))
      "Press deeper into the forest"
        do (move-to 'dungeon) (main-menu)
    "Search the undergrowth"
      do (search-undergrowth) (forest-menu)
    "Return to the village"
      do (move-to 'village) (main-menu)

defn combat-menu []:
  menu (str "Fighting " npcs/{combat/enemy}/name):
    "Attack"
      do (attack-enemy) (enemy-attacks)
         (if (= combat/outcome 'ongoing) (combat-menu) (main-menu))
    "Use health potion"
      when (contains? player/inventory 'health-potion)
        do (remove! player/inventory 'health-potion)
           (heal 40)
           (enemy-attacks)
           (if (= combat/outcome 'ongoing) (combat-menu) (main-menu))
    "Flee (lose 10 gold)"
      when (can-afford? 10)
        do (dec! player/gold 10)
           (move-to 'village)
           (set! combat/active False)
           (main-menu)


# ============================================================
# QUERIES AND VERIFICATION  (typically in a test/debug module)
# ============================================================

# Who is near the player right now?
query npc
  where: (and (= npcs/{npc}/location player/location)
              (= npcs/{npc}/status 'alive))

# Can the player complete the quest within 50 turns?
can-reach? (quest-complete?)
  depth: 50

# Is there any sequence of actions that kills the player in 5 turns?
find-counterexample (= player/status 'alive)
  depth: 5

# What is the probability of winning the first combat?
probability (= combat/outcome 'victory)
  depth: 10

# Verify health never goes negative on any path
verify-always (>= player/health 0)
  depth: 100

# What was the player's location at the start of act 1?
query-at player/location
  time: [0 1 0 0]
```

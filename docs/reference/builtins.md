# Built-in Functions Reference

All built-in functions are called with prefix notation: `function-name arg1 arg2 ...`

Named arguments use `name: value` syntax and may appear in any order among each other.

---

## State Queries

### `path-exists?`

```
path-exists? <path>  →  Bool
```

Returns `true` if the given path has a non-nil value (i.e., the entity family member has been spawned).

```
path-exists? crew/renn/hp        # Is Renn currently spawned?
path-exists? npcs/blacksmith/name
```

Note: in expression position, `path-exists?` takes a `PATH_EXPR` argument directly, not a string.

---

### `path-list`

```
path-list <family>  →  List of keys
```

Returns a list of all currently live keys in an entity family.

```
path-list npcs         # → ['blacksmith, 'guard, ...]
path-list crew         # → ['renn, 'lyra, 'bram]
```

---

### `count-where`

```
count-where <list>  fn(<var>): <condition>  →  Int
```

Counts elements of `list` for which the lambda returns true.

```
count-where (path-list crew) fn(m): crew/{m}/hp > 0
count-where player/inventory fn(item): item != 'potion
```

---

### `any?`

```
any? <list>  fn(<var>): <condition>  →  Bool
```

Returns `true` if at least one element of `list` satisfies the predicate.

```
any? (path-list npcs) fn(n): npcs/{n}/disposition = 'hostile
```

---

### `all?`

```
all? <list>  fn(<var>): <condition>  →  Bool
```

Returns `true` if every element of `list` satisfies the predicate.

```
all? crew/roster fn(m): crew/{m}/hp > 0
```

---

## Collections

### `size` / `count`

```
size  <collection>  →  Int
count <collection>  →  Int
```

Returns the number of elements in a `Set`, `List`, or `UList`. `count` is an alias for `size`.

```
size player/inventory       # number of items carried
count player/waypoints      # same as size
```

---

### `empty?`

```
empty? <collection>  →  Bool
```

Returns `true` if the collection has no elements.

```
empty? player/inventory
```

---

### `contains?`

```
contains? <collection> <item>  →  Bool
```

Returns `true` if `item` is in the collection.

```
contains? player/inventory 'sword
```

---

### `not-in?`

```
not-in? <item> <collection>  →  Bool
```

Returns `true` if `item` is **not** in the collection. Sugar for `not (contains? coll item)`.

```
not-in? 'key player/inventory
```

---

### `union` / `intersect` / `difference`

```
union      <a> <b>  →  Set
intersect  <a> <b>  →  Set
difference <a> <b>  →  Set
```

Set operations. `union` returns elements in either set, `intersect` elements in both, `difference` elements in `a` but not `b`.

---

### `min`

```
min <a> <b>  →  value
```

Returns the smaller of two values.

```
min amount (100 - player/health)
min player/gold 50
```

---

### `max`

```
max <a> <b>  →  value
```

Returns the larger of two values.

```
max 0 (player/health - cost)
```

---

### `tostring`

```
tostring <value>  →  String
```

Converts any value to its string representation. Result is superficial.

```
tostring player/health       # "42"
tostring player/class        # "warrior"
```

---

### `random-int`

```
random-int <min> <max>  →  Int
```

Returns a uniformly random integer in `[min, max]` (inclusive). The call is logged and replayable. In exhaustive search, branches over all outcomes.

```
random-int 1 6          # d6 roll
random-int 0 10         # damage modifier
```

---

### `random-bool`

```
random-bool          →  Bool
random-bool <p>      →  Bool
```

Returns `true` with probability `p` (default `0.5`). In exhaustive search, branches over `{false, true}` regardless of `p`.

```
random-bool             # fair coin
random-bool 0.25        # 25% chance of true
```

---

### `random-enum`

```
random-enum <EnumType>  →  variant
```

Returns a uniformly random variant of the named enum type. The argument is the enum's bare type name (no quotes). Branches over all variants under search.

```
random-enum Weather     # any variant of `enum Weather`
```

---

### `random-choice`

```
random-choice <list>  →  T | nil
```

Returns a uniformly random element of a `List`, `UList`, or `Set`. Returns nil for an empty collection. Branches over all elements under search.

```
random-choice ['fire 'ice 'wind]
random-choice player/known-spells
```

---

### `random-weighted`

```
random-weighted <weights> <values>  →  T | nil
```

Returns one element of `values`, chosen with probability proportional to the corresponding entry in `weights`. Both lists must be the same length. Under exhaustive search, weights are ignored (uniform branching).

```
random-weighted [1 2 5] ['common 'uncommon 'rare]
```

---

### `range`

```
range <hi>                 →  List(Int)
range <lo> <hi>            →  List(Int)
range <lo> <hi> <step>     →  List(Int)
```

Returns a list of integers from `lo` (inclusive, default 0) to `hi` (exclusive), advancing by `step` (default 1). Direction follows the sign of `step`; `step` must not be zero. Capped at 10,000 elements to match the engine's loop safety limit.

```
range 5                    # [0 1 2 3 4]
range 1 4                  # [1 2 3]
range 0 10 2               # [0 2 4 6 8]
range 5 0 (0 - 1)          # [5 4 3 2 1]
```

---

### `list-get` / `list-size`

```
list-get  <list> <index>  →  T | nil
list-size <list>          →  Int
```

`list-get` returns the element at 1-based `index` (negative indices count from the end: `-1` = last); returns nil for out-of-bounds. `list-size` is an alias for `size` / `count` on a `List`.

```
list-get  player/waypoints 1
list-get  player/waypoints (0 - 1)   # last element
list-size player/waypoints
```

---

## Math

Math helpers operate on `Int` and `Float` values. All are pure.

### `abs`

```
abs <n>  →  Int | Float
```

Absolute value.

```
abs (player/hp - enemy/hp)
```

---

### `clamp`

```
clamp <v> <lo> <hi>  →  Int | Float
```

Returns `v` clamped to `[lo, hi]`.

```
clamp player/hp 0 100
```

---

### `floor` / `ceil`

```
floor <n>  →  Int
ceil  <n>  →  Int
```

Round toward `-∞` / `+∞`. Useful for converting `Float` to `Int`.

```
floor (player/xp / 100)
ceil  (damage * 1.5)
```

---

### `int-div` / `mod`

```
int-div <a> <b>  →  Int
mod     <a> <b>  →  Int
```

Floor-division quotient and remainder. Sign convention matches the divisor (i.e. `mod (-7) 3 = 2`, not `-1`).

```
int-div total-seconds 60      # whole minutes
mod     total-seconds 60      # leftover seconds
```

---

## String / Numeric Conversion

### `str`

```
str <a> <b> ...  →  String
```

Concatenate any number of values into a `String`. `nil` arguments render as the empty string; booleans render as `"false"` / `"true"`.

```
str "HP: " player/hp " / " player/max-hp
```

---

### `int-to-str` / `str-to-int`

```
int-to-str <n>  →  String
str-to-int <s>  →  Int | nil
```

Convert between integers and their decimal string form. `str-to-int` returns `nil` if the string is not a valid integer (treat as `Option(Int)`).

```
int-to-str player/gold        # "42"
str-to-int "100"              # 100
str-to-int "abc"              # nil
```

---

## Debug Output

Both builtins are suppressed automatically in production builds (`opts.production`), so they're safe to leave in shipped source.

### `print`

```
print <a> <b> ...  →  nil
```

Write space-separated arguments to stderr, followed by a newline. Intended for ad-hoc development logging.

```
print "guard hp:" npcs/guard/hp
```

---

### `log`

```
log <level> <a> <b> ...  →  nil
```

Like `print`, but prepends `[LEVEL] file:line (fn-name):` so log lines are attributable. `level` is any string (conventionally `'debug` / `'info` / `'warn` / `'error`).

```
log 'info "spawned npc" npc/key
log 'warn "low health" player/hp
```

---

## UList Builtins

`UList(T)` is an unbounded ordered list. It is stored as a Lua sequence table and is **superficial** (not included in state-space analysis). All pure builtins below return a *new* list without mutating state.

**Mutation primitives** (in transaction functions only): `push!`, `pop!`, `clear!`, `set! path[n] val`.

---

### `ulist-size`

```
ulist-size <path>  →  Int
```

Returns the number of elements in the list.

```
ulist-size merchant/ledger
```

---

### `ulist-get`

```
ulist-get <path> <index>  →  T | nil
```

Returns the element at 1-based `index` (negative indices count from the end: `-1` = last). Returns nil for out-of-bounds.

```
ulist-get world/notes 1
ulist-get world/notes (0 - 1)   # last element (use expr form for negative literals)
```

---

### `ulist-first` / `ulist-last`

```
ulist-first <path>  →  T | nil
ulist-last  <path>  →  T | nil
```

Return the first or last element, or nil if the list is empty.

```
ulist-first merchant/ledger
ulist-last  merchant/ledger
```

---

### `ulist-index-of`

```
ulist-index-of <path> <value>  →  Int | nil
```

Returns the 1-based index of the first occurrence of `value`, or nil if not found.

```
ulist-index-of world/notes "urgent"
```

---

### `ulist-contains?`

```
ulist-contains? <path> <value>  →  Bool
```

Returns `true` if `value` appears anywhere in the list.

```
ulist-contains? world/notes "urgent"
```

---

### `ulist-append` / `ulist-prepend`

```
ulist-append  <path> <value>  →  UList(T)
ulist-prepend <path> <value>  →  UList(T)
```

Return a new list with `value` added at the end (append) or beginning (prepend). The stored list is unchanged.

```
ulist-append  merchant/ledger "new entry"
ulist-prepend merchant/ledger "header"
```

---

### `ulist-remove-at`

```
ulist-remove-at <path> <index>  →  UList(T)
```

Returns a new list with the element at 1-based `index` removed.

```
ulist-remove-at world/notes 2
```

---

### `ulist-remove`

```
ulist-remove <path> <value>  →  UList(T)
```

Returns a new list with the **first** occurrence of `value` removed.

```
ulist-remove world/notes "stale"
```

---

### `ulist-concat`

```
ulist-concat <path-a> <path-b>  →  UList(T)
```

Returns a new list that is the concatenation of both lists.

```
ulist-concat merchant/ledger world/archive
```

---

### `ulist-slice`

```
ulist-slice <path> <from> <to>  →  UList(T)
```

Returns a new list containing elements from 1-based `from` (inclusive) to `to` (inclusive). Out-of-range indices are clamped silently.

```
ulist-slice merchant/ledger 1 5
ulist-slice merchant/ledger (ulist-size merchant/ledger - 1) (ulist-size merchant/ledger)
```

---

### `ulist-reverse`

```
ulist-reverse <path>  →  UList(T)
```

Returns a new list with element order reversed.

```
ulist-reverse merchant/ledger
```

---

### `ulist-map`

```
ulist-map <path>  fn(<var>): <expr>  →  UList(U)
```

Returns a new list where each element has been transformed by the lambda.

```
ulist-map world/notes fn(s): str "[" s "]"
```

---

### `ulist-filter`

```
ulist-filter <path>  fn(<var>): <condition>  →  UList(T)
```

Returns a new list containing only elements for which the lambda returns true.

```
ulist-filter world/notes fn(s): ulist-contains? (ulist-slice (str s) 1 4) "gold"
```

---

## UMap Builtins

`UMap(K, V)` is an unbounded key-value map. It is **superficial** (not included in state-space analysis). All pure builtins return a *new* map without mutating state.

**Mutation primitives** (in transaction functions only): `map-set!`, `map-delete!`.

---

### `map-size`

```
map-size <path>  →  Int
```

Returns the number of key-value pairs in the map.

```
map-size store/kv
```

---

### `map-keys`

```
map-keys <path>  →  List of K
```

Returns all keys as a list (order unspecified).

```
map-keys store/kv
```

---

### `map-values`

```
map-values <path>  →  List of V
```

Returns all values as a list (order corresponds to `map-keys`).

```
map-values store/kv
```

---

### `map-get`

```
map-get <path> <key>  →  V | nil
```

Returns the value for `key`, or nil if not present.

```
map-get store/kv "alpha"
```

---

### `map-contains-key?`

```
map-contains-key? <path> <key>  →  Bool
```

Returns `true` if `key` is present in the map.

```
map-contains-key? store/kv "beta"
```

---

### `map-set` (pure)

```
map-set <path> <key> <value>  →  UMap(K, V)
```

Returns a new map with `key` set to `value`. The stored map is unchanged.

```
map-set store/kv "delta" 40
```

---

### `map-delete` (pure)

```
map-delete <path> <key>  →  UMap(K, V)
```

Returns a new map with `key` removed. The stored map is unchanged.

```
map-delete store/kv "alpha"
```

---

### `map-merge`

```
map-merge <path-a> <path-b>  →  UMap(K, V)
```

Returns a new map combining both maps; keys in `b` override keys in `a`.

```
map-merge store/kv (map-set store/kv "delta" 40)
```

---

## Relations

These functions operate on `relation` declarations.

### `adjacent?`

```
adjacent? <relation> <source>  →  Set
```

Returns the set of nodes one hop from `source`.

```
adjacent? exits player/location   # locations reachable in one step
```

---

### `reachable?`

```
reachable? <relation> <source> <target>             →  Bool
reachable? <relation> <source> <target>  max-hops: N →  Bool
```

Returns `true` if `target` is reachable from `source` via `relation`.

```
reachable? exits player/location 'castle
reachable? exits player/location 'castle  max-hops: 5
```

---

### `shortest-path`

```
shortest-path <relation> <source> <target>  →  List | nil
```

Returns the shortest sequence of nodes from `source` to `target`, or nil if unreachable.

```
shortest-path exits player/location 'castle
```

---

### `reachable-set`

```
reachable-set <relation> <source>             →  Set
reachable-set <relation> <source>  max-hops: N →  Set
```

Returns all nodes reachable from `source`.

```
reachable-set exits player/location  max-hops: 3
```

---

### `inverse-adjacent?`

```
inverse-adjacent? <relation> <target>  →  Set
```

Returns the set of nodes that have an edge *into* `target` (reverse adjacency).

```
inverse-adjacent? exits 'forest     # locations from which forest is reachable in one step
```

---

## Future-State Search

Search builtins perform BFS over the reachable future states of the game. They are pure (no mutations) and are valid in any pure context.

All search builtins accept:

| Named arg | Default | Description |
|-----------|---------|-------------|
| `depth: N` | engine default (5) | Maximum BFS depth |
| `budget: S` | none | Wall-clock time limit in seconds |
| `strategy: name` | `breadth-first` | `breadth-first`, `depth-first`, or `best-first` |

---

### `can-reach?`

```
can-reach? <condition>              →  Bool
can-reach? <condition>  depth: N    →  Bool
```

Returns `true` if there exists any sequence of choices (up to `depth`) that leads to a state where `condition` holds.

```
can-reach? player/status = 'dead
can-reach? player/location = 'castle  depth: 20
```

---

### `find-path`

```
find-path <condition>             →  List of {scene, label, index} | nil
find-path <condition>  depth: N   →  ...
```

Returns the shortest sequence of choices leading to a state where `condition` holds, or nil if unreachable within `depth`. Each element describes one choice: the scene name, choice text, and index.

```
find-path player/location = 'castle
find-path player/shrine-found = true  depth: 30
```

---

### `verify-always`

```
verify-always <condition>  →  Bool
```

Returns `true` if `condition` holds in *every* reachable future state (BFS exhaustion). Equivalent to checking that the negation is unreachable. Intended for use inside `verify` blocks.

```
verify-always castle/hp >= 0
verify-always player/health >= 0
```

---

### `find-counterexample`

```
find-counterexample <condition>  →  frozen state snapshot | nil
```

Finds a reachable future state where `condition` is false, or returns nil if none exists.

```
find-counterexample player/health >= 0
```

---

### `probability`

```
probability <condition>             →  Float
probability <condition>  depth: N   →  Float
```

Returns the estimated probability (0–1) that `condition` holds at some point within `depth` turns, assuming uniform random choice selection. Returns `(prob, approximate)` — `approximate` is true if any branch was pruned.

```
probability player/status = 'dead  depth: 10
```

---

### `optimal-path`

```
optimal-path <condition>  by: <cost-expr>             →  List | nil
optimal-path <condition>  by: <cost-expr>  depth: N   →  ...
```

Returns the choice sequence minimizing `by:` (a pure numeric expression evaluated at each node) that reaches a state where `condition` holds. Uses Dijkstra's algorithm.

```
optimal-path quest-complete?  by: min-turns
optimal-path player/gold > 1000  by: min player/hp-lost 0
```

---

## Temporal Queries

These builtins are available when a `time-model` is declared. They consult the transaction
log to reconstruct history, so they reflect only mutations that occurred after engine
initialisation (defaults are logged at `init` time, so initial values are always visible).

### `query-history`

```
query-history <path>            →  List of log-entry records
query-history <path-pattern>    →  List of log-entry records
```

Returns every recorded mutation of `path` (or paths matching a wildcard pattern), oldest
first. Each element is a log-entry record with the fields below.

```
for entry in (query-history player/gold):
  Day {entry/time/day}: {entry/old} → {entry/new} gold

for entry in (query-history player/*):
  {entry/path} changed on day {entry/time/day}
```

### `query-changes`

```
query-changes <path>                      →  List of log-entry records
query-changes <path>  last-n: N           →  List (most recent N, oldest first)
```

Returns recorded mutations of `path`. With `last-n: N`, returns only the N most recent
entries (still returned oldest-first within that window).

```
for entry in (query-changes player/location last-n: 3):
  Visited: {entry/new}
```

### `query-at`

```
query-at <path>  time: {axis: value, ...}  →  value | nil
```

Returns the value of `path` as it was at the given time-axis coordinates — i.e. the `new`
field of the last mutation whose time snapshot is ≤ the requested time. Returns nil if no
entry exists at or before that time.

```
fn gold-on-day d:
  query-at player/gold time: {day: d}

When {gold-on-day 1} gold in hand, the journey began.
```

**Log-entry record fields** (returned by all three query builtins):

| Field | Type | Description |
|-------|------|-------------|
| `path` | String | State path that was mutated |
| `old` | any | Value before the mutation |
| `new` | any | Value after the mutation |
| `time` | table | Time-axis snapshot at point of mutation, e.g. `{day=3}` |

Access nested time fields with `entry/time/<axis-name>` — the loop variable followed by
`/time/` and the axis name (e.g. `entry/time/day`). This uses the multi-segment loop
variable path syntax described in the `for` statement section of the language reference.

---

## Tile Grid Builtins

These are only available when a `defgrid` declaration is present and the engine has been initialized with grids.

See [`docs/reference/tile_grid.md`](tile_grid.md) for the full tile grid reference including `defgrid` syntax, coordinate conventions, and algorithm details.

---

### `grid-get`

```
grid-get <grid-name> <x> <y>  →  cell value
```

Returns the cell value at `(x, y)`. Returns nil for out-of-bounds coordinates.

```
grid-get world-map player/x player/y
```

---

### `grid-set!`

```
grid-set! <grid-name> <x> <y> <value>  →  nil
```

Sets the cell value at `(x, y)`. Mutation — only valid in transaction functions.

```
grid-set! world-map 3 5 'wall
```

---

### `grid-width` / `grid-height`

```
grid-width  <grid-name>  →  Int
grid-height <grid-name>  →  Int
```

Returns the grid dimensions as declared in `defgrid`.

---

### `within-range?`

```
within-range? <grid-name> <x1> <y1> <x2> <y2>            →  Bool
within-range? <grid-name> <x1> <y1> <x2> <y2>  range: N  →  Bool
within-range? <grid-name> <x1> <y1> <x2> <y2>  metric: "manhattan"  →  Bool
```

Returns `true` if `(x2, y2)` is within `range` of `(x1, y1)` (default range: 1).

`metric:` options: `"chebyshev"` (default), `"manhattan"`, `"euclidean"`.

```
within-range? battle-map player/x player/y enemy/x enemy/y  range: 3
within-range? battle-map px py ex ey  range: 5  metric: "manhattan"
```

---

### `visible-from?`

```
visible-from? <grid-name> <x1> <y1> <x2> <y2>              →  Bool
visible-from? <grid-name> <x1> <y1> <x2> <y2>  solid: {values}  →  Bool
```

Returns `true` if `(x2, y2)` is visible from `(x1, y1)` using a ray-cast line-of-sight test. Cells with values in the `solid:` set block vision. Default: all cells are transparent.

```
visible-from? dungeon-map player/x player/y torch/x torch/y  solid: {'wall}
```

---

### `path-to`

```
path-to <grid-name> <x1> <y1> <x2> <y2>                      →  List of {x, y} | nil
path-to <grid-name> <x1> <y1> <x2> <y2>  blocked: {values}   →  ...
path-to <grid-name> <x1> <y1> <x2> <y2>  diag: true          →  ...
```

Returns the A* shortest path from `(x1, y1)` to `(x2, y2)` as a list of `{x, y}` coordinate maps (not including the start), or nil if no path exists.

`blocked:` specifies impassable cell values (default: empty set — all cells passable).
`diag: true` allows diagonal movement (default: false — 4-directional only).

```
path-to dungeon-map player/x player/y exit/x exit/y  blocked: {'wall, 'door}
path-to tactical-map ax ay bx by  diag: true
```

---

### `occupied-by`

```
occupied-by <grid-name> <family-name> <x> <y>  →  key | nil
```

Returns the key of the entity at position `(x, y)` in the given family, or nil if no entity is at that position. Scans `family/KEY/x` and `family/KEY/y` state paths.

```
occupied-by battle-map units player/x player/y
```

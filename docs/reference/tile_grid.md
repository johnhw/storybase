# Tile Grid Reference

The tile grid extension adds 2D spatial reasoning to StoryBase games. It is an optional feature — games that don't need it don't pay any cost.

---

## `defgrid` Declaration

```
defgrid world-map:
  dimensions: Int(0, 30) x Int(0, 30)
  cell-type:  TileKind
```

| Field | Required | Description |
|-------|----------|-------------|
| `dimensions:` | Yes | `Int(0, W) x Int(0, H)` — grid width and height. Coordinates are 0-based: `x ∈ [0, W-1]`, `y ∈ [0, H-1]`. |
| `cell-type:` | Yes | The discrete type of each cell. Must be a declared enum or alias. |

The grid name (`world-map`) is used as the first argument to all grid built-in functions.

### Example

```
type TileKind = floor | wall | door | water

defgrid dungeon:
  dimensions: Int(0, 20) x Int(0, 15)
  cell-type:  TileKind
```

---

## Coordinate System

- Origin `(0, 0)` is the **top-left** corner.
- `x` increases to the right; `y` increases downward.
- All coordinates are **0-based integers**.
- Out-of-bounds coordinates return nil from `grid-get` and false from `within-range?` / `visible-from?`.

**Cell storage (internal):** flat 1-indexed Lua array, `cells[y * width + x + 1]`. This detail is only relevant if you access grids directly from Lua via the debug API.

---

## Accessing and Modifying Grids

### `grid-get`

```
grid-get <grid-name> <x> <y>  →  cell value | nil
```

Read the cell value at `(x, y)`. Returns nil for out-of-bounds positions.

```
grid-get dungeon player/x player/y    # → 'floor, 'wall, etc.
grid-get dungeon 0 0                  # → top-left cell
```

---

### `grid-set!`

```
grid-set! <grid-name> <x> <y> <value>
```

Set the cell at `(x, y)` to `value`. Mutation — valid only in transaction functions.

```
grid-set! dungeon 5 3 'door
grid-set! dungeon player/x player/y 'floor
```

---

### `grid-width` / `grid-height`

```
grid-width  <grid-name>  →  Int
grid-height <grid-name>  →  Int
```

Return the grid dimensions as declared in `defgrid`.

---

## Spatial Queries

### `within-range?`

```
within-range? <grid-name> <x1> <y1> <x2> <y2>             →  Bool
within-range? <grid-name> <x1> <y1> <x2> <y2>  range: N   →  Bool
within-range? <grid-name> <x1> <y1> <x2> <y2>  metric: M  →  Bool
```

Returns `true` if `(x2, y2)` is within distance `range` of `(x1, y1)`.

**Parameters:**
- `range:` — maximum distance (default: 1).
- `metric:` — distance metric (string):
  - `"chebyshev"` (default) — max of |Δx| and |Δy|; natural for 8-directional movement.
  - `"manhattan"` — |Δx| + |Δy|; natural for 4-directional movement.
  - `"euclidean"` — √(Δx² + Δy²); circles.

**Examples:**

```
within-range? battle-map 3 3 5 5  range: 3                   # Chebyshev ≤ 3 → true
within-range? battle-map 0 0 5 0  range: 5  metric: "manhattan"  # |5|+|0|=5 → true
within-range? battle-map px py tx ty  range: 2  metric: "euclidean"
```

---

### `visible-from?`

```
visible-from? <grid-name> <x1> <y1> <x2> <y2>               →  Bool
visible-from? <grid-name> <x1> <y1> <x2> <y2>  solid: {vals} →  Bool
```

Returns `true` if `(x2, y2)` is visible from `(x1, y1)` with a ray-cast line-of-sight test. Cells with values in the `solid:` set block the ray. The start and end cells themselves are not checked; only intermediate cells are tested.

**Algorithm:** float-step ray marching. The ray steps in increments of 0.01 normalized units from `(x1, y1)` to `(x2, y2)`, sampling intermediate cells. A cell is opaque if its value is in `solid:`.

**Parameters:**
- `solid:` — a set literal of opaque cell values (default: empty — all cells transparent).

**Examples:**

```
visible-from? dungeon 2 2 8 5  solid: {'wall, 'door}
visible-from? world-map px py target-x target-y  solid: {'mountain, 'dense-forest}
```

---

### `path-to`

```
path-to <grid-name> <x1> <y1> <x2> <y2>                     →  List of {x, y} | nil
path-to <grid-name> <x1> <y1> <x2> <y2>  blocked: {vals}    →  ...
path-to <grid-name> <x1> <y1> <x2> <y2>  diag: true         →  ...
```

Returns the shortest path from `(x1, y1)` to `(x2, y2)` as a list of `{x=N, y=N}` maps (not including the start cell), or nil if no path exists.

**Algorithm:** A* with a binary min-heap priority queue. Heuristic: Chebyshev distance.

**Parameters:**
- `blocked:` — set of impassable cell values (default: empty — all cells passable).
- `diag: true` — allow diagonal movement; false (default) = 4-directional only.

**Cost:** each step costs 1. Diagonal steps also cost 1 (not √2).

**Examples:**

```
path-to dungeon px py ex ey  blocked: {'wall}
path-to battle-map 0 0 9 9   blocked: {'wall, 'lava}  diag: true
```

**Reading the result:**

```
let route = (path-to dungeon player/x player/y exit/x exit/y blocked: {'wall}):
  when route != nil  and  count-where route fn(_): true > 0:
    let next = route[0]:
      set! player/x next/x
      set! player/y next/y
```

---

### `occupied-by`

```
occupied-by <grid-name> <family-name> <x> <y>  →  key | nil
```

Returns the key of the entity from `family-name` that is at position `(x, y)`, or nil if none.

Scans `family/KEY/x` and `family/KEY/y` state paths for all live members of `family-name`. The `grid-name` argument is used for bounds checking only; the cell type is not inspected.

**Example:**

```
let who = (occupied-by battle-map units target-x target-y):
  when who != nil:
    dec! units/{who}/hp 10
```

---

## Complete Example

```
type TileKind = floor | wall | door | exit

defgrid dungeon:
  dimensions: Int(0, 10) x Int(0, 10)
  cell-type:  TileKind

state player:
  x: Int(0, 9) = 1
  y: Int(0, 9) = 1

fn step-toward target-x target-y:
  let route = (path-to dungeon player/x player/y target-x target-y blocked: {'wall, 'door}):
    when route != nil:
      let step = route[0]:
        set! player/x step/x
        set! player/y step/y

scene explore:
  You are at ({player/x}, {player/y}).
  [visible-from? dungeon player/x player/y 9 9  solid: {'wall}]
    You can see the exit!
  * Move toward exit
    step-toward 9 9
    -> explore
```

---

## Initialisation

Grids are initialised by the engine at startup with all cells set to the default value of the `cell-type` enum's first variant. You can populate cells in the entry scene or a startup transaction function using `grid-set!`.

For large grids, a common pattern is to initialise in a setup function:

```
fn init-map:
  # Fill with floor
  for y in ...:
    for x in ...:
      grid-set! dungeon x y 'floor
  # Place walls
  grid-set! dungeon 0 0 'wall
  ...
```

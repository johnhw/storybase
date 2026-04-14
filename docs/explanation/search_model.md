# The Search Model

StoryBase's search engine lets you ask exact questions about what futures are reachable from the current game state. This document explains how it works, what its limits are, and how to choose between the different search functions.

---

## Why Discrete Types Make Search Possible

The search engine works by enumerating all reachable `(state, scene_stack)` pairs. This is only possible if the state space is finite.

StoryBase enforces this by restricting all game logic to *discrete* types:
- `Bool` — 2 values
- `Int(0, 100)` — 101 values
- Enum with N variants — N values
- `Option(T)` — |T| + 1 values
- `Set(T, max)` — bounded
- Entity family with `max: N` — bounded number of members

The total state-space size is the product of all these. For a game with 10 Bool flags (2^10 = 1024 combinations), 3 `Int(0, 99)` values (100^3 = 1,000,000 combinations), and 2 enums with 5 values each (25 combinations), the state space is 1024 × 1,000,000 × 25 = 25.6 billion states — large but finite.

In practice, depth bounds (e.g. `depth: 10`) limit the search to states reachable in at most 10 turns, which is vastly smaller.

---

## BFS Node Structure

Each node in the search graph is a `(cache, stack)` pair:
- `cache` — a snapshot of all state path values (a flat Lua table).
- `stack` — the current scene stack (list of scene names).

The BFS starts from the current engine state, then enumerates all reachable `(cache, stack)` pairs by simulating choices:

1. **Render** the current scene from `(cache, stack)` to get available choices.
2. **For each choice**: clone `(cache, stack)`, simulate the choice body (mutations + navigation), then simulate `post_action` (actor behaviors + scheduled events). This produces a child `(cache', stack')`.
3. **Deduplicate**: hash `(cache, stack)` and skip already-visited nodes.
4. **Recurse** until depth is exhausted or the target condition is met.

### Why include `post_action`?

Actor behaviors and scheduled events are part of the game's state transitions. If you omit them, you get an incomplete picture of what states are reachable. The search engine includes a full turn (choice → actor step → scheduler step) as each BFS edge.

---

## Random Source Branching

When the evaluator encounters `random-int min max` during search, it does not pick one value — it **branches** over all possible values in `[min, max]`.

The engine uses a `_random_inject` hook: during search, `call_fn` for `random-int` calls `random_outcome_combos`, which enumerates all outcomes. Each outcome produces a separate child node.

For `probability`, each branch is weighted by `1 / (max - min + 1)` (uniform distribution). Branches with weight below a configurable threshold are pruned, and the result is marked `approximate`.

This means:
- `can-reach? player/dead  depth: 5` is exact: it finds *any* path, regardless of random outcomes.
- `probability player/dead  depth: 5` is exact if no pruning occurs, approximate otherwise.

---

## Cycle Detection

BFS tracks visited nodes by their content hash. Two nodes with the same `(cache, stack)` content are identical, regardless of how they were reached. This prevents infinite loops in cyclic game graphs (e.g., a scene that returns to itself).

The hash is computed over the full `cache` (all path values) plus the `stack` (list of scene names). Hash collisions are theoretically possible but practically negligible with Lua's default string hashing.

`probability` does **not** use cycle deduplication — every path through the graph must be counted separately to compute accurate probabilities.

---

## Time Budgets

Long-running searches can be bounded by a wall-clock time limit:

```
can-reach? condition  depth: 50  budget: 2.0
```

`budget:` is in seconds. The clock is checked every 50 BFS iterations. When the budget expires, the search returns the best answer found so far:
- `can-reach?` returns `false` (not found — but might exist; result is approximate).
- `probability` returns `(prob, true)` where the second value signals that the result is approximate.
- `find-path` returns nil (not found in time).

---

## Strategies

The default BFS strategy is breadth-first (`strategy: "breadth-first"`). Two alternatives:

### Depth-first (`strategy: "depth-first"`)

Explores one path to full depth before backtracking. Uses less memory than BFS. Good when you expect the target to be deep in the graph and want a quick answer.

### Best-first (`strategy: "best-first"`)

Uses a priority queue ordered by a heuristic function. Explores states that look closest to the goal first. Faster than BFS when the heuristic is good.

```
can-reach? quest-complete?
  depth: 30
  strategy: "best-first"
```

For `optimal-path`, the default strategy is Dijkstra's algorithm (best-first with cumulative cost), not BFS.

---

## The Coroutine Iterator

For custom search logic, `search.lua` exposes a coroutine iterator:

```lua
local search = require("runtime.search")
local it = search.make_iterator(game_table, cache, stack, condition_fn, depth)
for cache_snap, path in it do
  -- process each matching state
end
```

The iterator yields `(cache_snapshot, action_path)` for each state where `condition_fn` returns true. This is used internally by `find-counterexample` and is available for custom tooling.

---

## Choosing the Right Search Function

| Question | Use |
|----------|-----|
| Can this condition ever be reached? | `can-reach?` |
| What sequence of choices gets there? | `find-path` |
| What fraction of random outcomes lead there? | `probability` |
| Does this hold in every reachable state? | `verify-always` |
| Find a state where this is violated | `find-counterexample` |
| What is the fastest/cheapest route? | `optimal-path by: <cost>` |

### `can-reach?` vs `verify-always`

- `can-reach? cond` — exists a path where `cond` holds? (BFS stops at first match)
- `verify-always cond` — does `cond` hold in **every** reachable state? (BFS to exhaustion)

`verify-always cond` is equivalent to `not can-reach? not cond`.

### `find-path` vs `optimal-path`

- `find-path cond` — the **shortest** (fewest turns) path where `cond` holds.
- `optimal-path cond by: <expr>` — the path minimizing the cumulative value of `<expr>` (Dijkstra).

Use `optimal-path` when "best" means something other than fewest turns — e.g., minimum gold spent, minimum HP lost.

---

## Performance Guidance

**State-space size is the primary cost.** To keep searches fast:

1. Prefer named enums over `Int` for small-domain values.
2. Use tight `Int(min, max)` bounds — `Int(0, 5)` has 6 states; `Int(0, 9999)` has 10,000.
3. Use small `max: N` on entity families and bounded collections.
4. Prefer `Set(QuestFlag, 5)` over `Set(Symbol, 20)` — the former has bounded state, the latter uses a large constant.

**Depth bounds:** BFS at depth *d* with branching factor *B* explores at most B^d nodes. At depth 5 with 3 choices per scene, that's 3^5 = 243 nodes — fast. At depth 20, it's 3^20 = 3.5 billion — too slow. Use `depth:` to limit searches to what's practically feasible.

**Budget:** use `budget:` for interactive queries where an approximate answer is acceptable. Set a budget of 1–2 seconds for in-game hints.

**Verify at design time:** `verify` blocks are stripped from production builds. Run them during development and CI, not during gameplay.

# Design Philosophy

StoryBase was designed around five principles. Each one flows from the previous, and together they produce a system that is qualitatively different from a scripted game engine or a general-purpose programming language used for games.

---

## 1. Separation of Logic and Presentation

Game logic and narrative presentation must be strictly separate.

**The rule:** all branching, conditionals, and gameplay decisions depend only on *discrete* types (Bool, Int, enum, bounded Set/List). Text, visuals, and other presentation data are *superficial* types: they can be displayed and changed, but no computation may branch on their values.

**Why this matters:** if you allow a conditional on a String value — `if player/name = "Alice": grant-bonus` — then the game's branching structure depends on unbounded data. You can no longer enumerate all reachable states, and exhaustive search becomes impossible. The compiler rejects superficial values in conditionals before the code even runs.

This boundary may feel restrictive at first. In practice, it rarely is: you almost never need to branch on a display string. When you think you do, it is usually a sign that the underlying concept should be represented as an enum or a bounded integer.

**What it enables:** a finite, analysable state machine. Every feature downstream — bounded search, verify blocks, deterministic replay, counterfactuals — depends on this foundation.

---

## 2. The Transaction Log Is the Ground Truth

Every mutation to state is an entry in the transaction log. Current state is always a *projection* of all log entries in order.

**The rule:** the engine maintains a fast in-memory cache of the current projected state, but the log is canonical. The cache can be reconstructed from the log at any time.

**Why this matters:** this gives you automatic save/load (saving a log = saving state), full replay (replay the log = reconstruct any past state), time-travel debugging (replay up to sequence N), and the basis for future-state search (clone the current cache, replay a hypothetical action, observe the result).

Other game engines typically store current state in a mutable dictionary and implement save/load as a separate serialisation concern. The transaction-log approach makes these capabilities *structural* rather than bolt-on.

**What it costs:** a slight write overhead (each mutation appends to the log) and more memory (the log grows over time). `storybase compact` can compress old logs into snapshots.

**What it enables:** save/load for free, replay for free, time-travel debugger, counterfactual branches, auditable change history, and the ability to ask "what was player/health at turn 37?" without any additional instrumentation.

---

## 3. Bounded Exhaustive Search Over Futures

Because all logic depends on discrete bounded types and all random sources produce finite outcomes, the set of reachable future states forms a finite graph. The engine can search it.

**What it means:** `can-reach? player/status = 'dead` is not a heuristic or an approximation — it is an exact BFS over the reachable state graph. `verify-always castle/hp >= 0` checks *every* state the player could possibly reach. `probability player/won?` enumerates *all* branches with their exact weights.

**Why discrete types matter for search:** a `Bool` has 2 states. An `Int(0, 100)` has 101 states. An enum with 5 values has 5 states. A `String` has infinitely many. The total state-space size is the product of all discrete field sizes. For a game with 20 Bool flags and 5 bounded integers with 100 values each, the state space is 2²⁰ × 100⁵ — large but finite.

**Random sources:** each `random-int` call branches the search. The engine enumerates all possible outcomes, weighted by probability. `probability` returns exact results.

**Depth bounds:** BFS at depth *d* explores at most B^d states where B is the average branching factor. For large games, depth must be bounded. The default is 5; increase with `depth: N` on specific queries.

**What this enables:** `verify` blocks run as a test suite. Automated game balancing. Hints like "you can complete this quest in 7 turns." Designer-facing tools that ask "is the game winnable?" before any player tests it.

---

## 4. Structured Actors and Messaging

Complex game worlds have many interacting agents. Actors give each NPC and environment system its own perception snapshot, behavior function, and message inbox.

**The rule:** each actor declares a `perceives:` list — the paths it is allowed to read. The behavior function sees only a filtered snapshot of those paths. The compiler rejects reads of unperceived paths. Actor mutations are *deferred*: collected during the behavior step, applied after all actors have run.

**Why perception filtering matters:** without it, actor execution order would affect outcomes (actor A reads a path that actor B just mutated). With deferred writes and perception snapshots, behavior functions are deterministic and order-independent. All actors see a consistent "beginning of turn" snapshot.

**Why typed messages matter:** unstructured communication (shared global state) is hard to reason about and replay. Typed messages appear in the transaction log, can be replayed, and are visible in the debugger. Conflict logging (when two actors try to write the same path) is automatic and auditable.

**What this enables:** NPC behavior that is testable, replayable, and included in future-state search. The search engine includes actor-behavior transitions as first-class successors.

---

## 5. First-Class Debugging and Hot Reload

Debugging is not an afterthought. The debug server, watch expressions, time-travel, hot reload, and counterfactual traces are part of the language specification.

**The rule:** debug capabilities must be expressible in the language itself — not just available through external tools. `verify` blocks are part of the source file. `watch-when` declarations are part of the schema. The debug server protocol is documented and stable.

**Hot reload:** during development, you can change the source file while the game is running and send a `reload` command to the debug server. The engine validates the schema change against the current state, applies field additions atomically, and resumes without restarting. This makes iterative design dramatically faster.

**Why hot reload is hard (and how this design makes it tractable):** most game engines have to restart to reload because their state is entangled with their code. In StoryBase, state is just a flat key-value store (the transaction log cache), and code is just function bodies. Schema migrations tell the engine exactly how state must transform. Reload is just a restricted migration.

**What this enables:** a tight edit-run-observe loop. Watch expressions that fire in the debug client the moment an invariant is violated. Counterfactual traces ("what would health be if I had taken the left path?") without any extra plumbing.

---

## The Five Principles Together

| Principle | What it costs | What it buys |
|-----------|--------------|-------------|
| Logic/presentation split | No branching on Strings/Floats | Finite state machine, searchable futures |
| Transaction log as truth | Write overhead, memory | Save/load/replay for free, time-travel |
| Bounded exhaustive search | State-space must be finite | Exact reachability, verify blocks |
| Structured actors | Explicit perceives: lists | Deterministic NPC behavior, search inclusion |
| First-class debugging | Debug server adds complexity | Hot reload, watch expressions, counterfactuals |

None of these constraints is arbitrary. Each one enables the next. The transaction log enables time-travel, which enables counterfactuals. The discrete type constraint enables bounded search, which enables verify. Structured actors enable per-actor perception filtering, which enables deterministic search including NPC behavior.

A game engine that discards any one of these constraints still works — it just loses the guarantees that the others buy. StoryBase is a coherent system, not a menu of features.

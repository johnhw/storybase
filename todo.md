
# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-04-18)

All eight implementation phases are complete, plus all "Bugs/Spec Gaps", "Small Wins",
the **Standalone Bundler**, **Language Server (LSP)**, and all four Medium Features below.
**1659 tests passing** (excluding flaky http tests; 1642 in isolation).

Demo 08 (The Probability Engine) is complete: demonstrates `probability`, `can-reach?`,
`find-path`, `optimal-path`, `find-counterexample`, `engine/emit`, `engine/checkpoint!`,
`undo!`, explicit lambda `fn(x): ...`, and `verify after requires`. Run:
  `lua5.4 cli/main.lua run --auto --steps 15 demos/demo08_probability_engine.sb`

Bug fixes in this session:
- `_in_bfs` guard: BFS engines in `search.lua` and `verify.lua` now set `eng._in_bfs = true`.
  `make_ctx` in `engine.lua` propagates it; `child_ctx` in `eval.lua` propagates it. All five
  BFS builtins (`can-reach?`, `find-path`, `probability`, `optimal-path`, `find-counterexample`)
  have guards returning safe defaults when called from narration during outer BFS.
- `nil` as language literal: `call_fn` now treats the name "nil" as the nil literal,
  allowing `if doom = nil:` comparisons.
- Nil variable tracking: `nil_vars` set added to contexts; LET_STMT and param binding
  track nil-valued variables so they can be distinguished from undefined names.
- `if/else` retval propagation: `IF_EXPR` as a statement now propagates `sub.retval` so
  `if/else` works as a value-returning construct in function bodies.
- `parse_if_expr`: parser now handles the case where `:` after the condition was consumed
  as part of a NAMED_ARG token (same fix already present in `parse_when_stmt`).

---

**`--cli` single-step scripting mode** is complete: `storybase run game.sb --cli save.sbd` reads
stdin for a choice index, advances the game by exactly one step, writes full state (including
checkpoint stack) to the save file, and emits a single JSON object to stdout. 35 tests in
`tests/cli/cli_cmd_spec.lua`. Supports `--reset` flag and `q`/`quit`/`exit` to quit.

---

## Active Tasks

### Bugs / Spec Gaps (fix first)

- [x] **`import "path" as Alias` is silently ignored.** Fixed: `resolve_imports` now emits
  `UNSUPPORTED_FEATURE` compile error so authors are not silently misled. Tests in
  `tests/compiler/import_spec.lua`.

- [x] **`module ... exports:` is not enforced.** Fixed: parser now parses and stores the
  `exports:` list in `ast.module_decl`; importing a module with `exports:` emits
  `WARN_EXPORTS_NOT_ENFORCED`. Tests in `tests/compiler/import_spec.lua`.

### Small Wins (low effort, high value)

- [x] **Source-context lines in error messages.** `print_diags` in `cli/main.lua` and
  `cli/check_cmd.lua` now accept a `source_map` and print the offending line + caret.

- [x] **`storybase check` subcommand.** `cli/check_cmd.lua` — lexer+parser+checker only,
  with source-context output. Wired in `cli/main.lua`.

- [x] **`storybase format` pretty-printer.** `cli/format_cmd.lua` — walks the parsed AST and
  emits canonical 2-space-indented output. `--check` and `--write` modes supported.

- [x] **`--debug` flag on `run`.** `engine.run` now accepts `opts.debug_port`; when set,
  creates a TCP debug server, calls `eng:set_debug_server`, `srv:start()`, polls each turn,
  and prints `[debug] listening on :PORT`.

- [x] **`storybase repl` subcommand.** `cli/repl_cmd.lua` — interactive REPL with expression
  eval, function calls, `:state`, `:scene`, `:choices`, `:choose N`, `:tick`, `:save/:load`.

- [x] **`at:` one-shot schedule trigger.** The scheduler already had `at:` logic; added
  deregister-after-fire for pure `at:`-only schedules. New `tests/runtime/scheduler_spec.lua`
  (12 tests) including end-to-end pipeline coverage.

### Medium Features

- [x] **Namespaced imports (`import "path" as E`).** Names from the imported file are
  accessible as `E.TypeName`, `E.fn-name`, `E.scene-name`, etc. State and relation
  declarations remain global. Implementation: `apply_import_namespace` in
  `compiler/compiler.lua` renames all non-state declarations and rewrites internal
  cross-references; `compiler/parser.lua` extended to parse `Alias.Name` in type
  expressions, function calls, and scene transitions. 7 new tests in
  `tests/compiler/import_spec.lua`; CLI integration test updated. **1611 tests passing.**

- [x] **Path patterns in `watch` and `verify` forms.** `idea.md §4.3` specifies `player/*`,
  `npcs/*/location`, `player/**` wildcards and `player/(health|mana)` alternations.
  `runtime/debug.lua` `path_matches` extended with `**` multi-segment wildcards and `(a|b)`
  alternation expansion; `check_watches` now iterates all cache keys for pattern watches;
  `engine.lua` `set_debug_server` now registers `watch`/`watch-when` declarations from
  `game_table.watches`; `runtime/verify.lua` exports `match_path_pattern`. Tests in
  `tests/runtime/debug_spec.lua` (+14) and `tests/runtime/verify_spec.lua` (+9).

- [x] **Browser-based debug UI + interactive play.**  All subtasks complete. 23 tests in
  `tests/runtime/debug_http_spec.lua`. **1634 tests passing.**

#### Browser UI Subtasks (all complete)

- [x] **Subtask 1** — HTTP + SSE transport in `runtime/debug.lua`: `srv:start_http(port)`,
  `srv:poll_http()`, `srv:_http_response()`, `srv:_sse_push()`, routes for GET /, GET /events,
  POST /command, OPTIONS; `srv:emit()` broadcasts to SSE clients.
- [x] **Subtask 2** — New game-play commands: `get-scene`, `do-choice`, `get-tick`, `get-mode`
  in `handle_command`. `do-choice` gated by `_serve_mode`.
- [x] **Subtask 3** — Embedded HTML/JS/CSS (`M.HTML_UI`) in `runtime/debug.lua`: two-column
  layout (GAME left, STATE/MUTATIONS/TIMELINE/WATCHES right), SSE auto-reconnect, choice
  buttons disabled in debug mode.
- [x] **Subtask 4** — `--serve` flag in `cli/main.lua`: `serve` added to `BOOL_FLAGS`; HTTP
  server started on `debug_port + 1`; polling loop replaces stdin loop in serve mode.
- [x] **Subtask 5** — `tests/runtime/debug_http_spec.lua`: 23 tests covering lifecycle, GET /,
  POST /command, get-scene/do-choice, SSE events.
- [x] **Subtask 6** — `code_map.md` updated; task marked complete.

- [x] **`counterfactual` as a language expression.** `idea.md §21` specifies
  `let alt = counterfactual from: world/turn - 3 do: ...` as first-class syntax.
  Parser and eval were already wired; added `from_tick` log replay: when `from:` is set,
  `eval.lua` builds historical state by replaying log mutations up to the target tick (falls
  back to current state if `from_tick` evaluates to non-number or log is empty). 4 new tests in
  `tests/runtime/counterfactual_spec.lua`.

- [x] **Demo 07.** `demos/demo07_oracle.sb` + `demos/oracle_lib.sb` — The Wanderer's Oracle.
  Two-file game: main file imports oracle_lib.sb (flat import), uses `bounded oracle-weather`
  (with `?? 'clear` fallback when no handler), and `counterfactual` in pure preview fns
  (`preview-meditate`, `preview-trade`, `preview-gather-trade`) called from scene narration.
  7 CLI integration tests added; verify blocks pass (155 BFS states). 1596 tests passing.

### Major Features

- [x] **Language Server (LSP).** `cli/lsp.lua` — stdio JSON-RPC 2.0 server. Wraps
  `M.parse_and_check`; on every `textDocument/didOpen` or `textDocument/didChange` it
  re-parses and pushes diagnostics. Supports `textDocument/hover` (doc strings + kind +
  params), `textDocument/definition` (jump to declaration), and `textDocument/completion`
  (names, state paths, types, scenes filtered by prefix; trigger chars `/` and `-`).
  Wired as `storybase lsp` in `cli/main.lua`. 43 unit tests in `tests/cli/lsp_spec.lua`.

- [x] **Standalone bundler (`storybase bundle`).** `storybase bundle game.sb --output game.lua`
  produces a single self-contained Lua file: compiler stripped, 14 runtime modules embedded
  via `package.preload`, game table baked in as a Lua literal. Runs with a stock `lua5.4`
  binary. `--production` strips verify/watch blocks. The bundle emits a `BUNDLED_ASSETS`
  table and `asset_load()` helper as documented extension points for future asset embedding
  (images, audio, etc.). Bundled games accept `--seed N`, `--save`, and `--load` flags.
  Implemented in `cli/bundle_cmd.lua`; 20 tests in `tests/cli/bundle_spec.lua`.

---

## Deferred / Low Priority

Items noted as low-priority during earlier phases; not yet implemented.

- [x] `engine/checkpoint!` callable form — parser handles PATH token `engine/checkpoint!` as
  `CHECKPOINT_MUT` node (ast.lua); eval pushes a log checkpoint. Optional `fn-name` arg
  overrides the checkpoint label. Tests in `tests/lib/storybase_spec.lua`.

- [x] `engine/emit event args` callable form — parser handles PATH token `engine/emit` as
  `EMIT_MUT` node; eval fires `ctx.debug:emit(...)` (debug server) AND `ctx.game._emit_hook`
  (wired by `lib/storybase.lua` to deliver events to `game:on()` listeners). Tests in
  `tests/lib/storybase_spec.lua`.

- [x] Doc string surfacing via public API — `game:docs(name?)` added to `lib/storybase.lua`:
  collects `doc` fields from fns, scenes, actors, schedules, bounded, schema.states/types;
  returns full map or single-name lookup. Tests in `tests/lib/storybase_spec.lua`.

- [x] Doc string surfacing via debug server schema browser — `get-schema` command added
  to `runtime/debug.lua` `handle_command`. Returns types (with doc), states, relations,
  fns (with is_transaction flag + doc), scenes, actors, schedules, bounded (with lua_name
  + doc), schema_version, and engine_config. `codegen.lua` `emit_bounded` now emits `doc`.
  9 new tests in `tests/runtime/debug_spec.lua`.

- [ ] Every public function in every module has at least one passing and one failing test.

---

## New Demos

### Feature gap analysis

The existing seven demos leave several implemented features undemonstrated:

| Feature | Status |
|---------|--------|
| Search builtins in gameplay (`can-reach?`, `find-path`, `probability`, `optimal-path`, `find-counterexample`) | **Not demoed** — only used in offline `verify` blocks |
| Advanced tile grid (`visible-from?`, `path-to`, `grid-get/set!`, `occupied-by`) | **Not demoed** — demo06 only shows `within-range?` |
| `engine/checkpoint!` + undo | **Not demoed** |
| `engine/emit` custom events | **Not demoed** |
| `while` loop | **Not demoed** |
| `cond` expression | **Not demoed** |
| Lambda expressions explicitly | Implicit in `count-where` but never written as `fn(x): ...` |
| `verify` clauses beyond `verify-always` (`after`, `requires`, `from_any_state`) | **Not demoed** |
| `Option(T)` type | **Not demoed** |
| Inline `Enum(a, b)` type | **Not demoed** |
| Type aliases (`type Alias = OtherType`) | **Not demoed** |
| Multi-axis time model (more than one axis) | Demo05 uses time-model but single axis |

The two biggest gaps are (1) search builtins as interactive gameplay mechanics—StoryBase's flagship feature—and (2) the advanced tile grid algorithms.

---

### Demo 08 — "The Probability Engine" (search builtins as gameplay) ✓ COMPLETE

**Concept.** A gambling den / strategic betting game in which the player is an odds-maker
advising desperate clients. The engine's BFS search builtins become the in-game "calculation
machine" that lets the player quote probabilities, find winning paths, and expose impossible
dreams before taking someone's last coin.

**Narrative premise.** You run a back-alley probability shop in a city under siege. Clients
arrive with schemes and wagers; you use your mechanical oracle to assess their odds. A city
governor wants to know if relief supplies *can* reach the city before the walls fall; a
gambler wants the *optimal* sequence of bets to clear his debt; a spy wants to know if she
*can possibly* escape without being caught.

**Features to demonstrate:**

- `probability` — quoted as an in-game percentage ("Your plan succeeds 34% of the time")
- `can-reach?` — gating a "take the contract" choice ("The task is impossible — I cannot in
  good conscience take your coin")
- `find-path` / `optimal-path` — displayed as a printed route or bet sequence to the client
- `find-counterexample` — "I have found the one sequence of events that destroys your plan"
- `engine/emit 'contract-accepted {...}` — emit a custom event each time a contract is signed
- `engine/checkpoint!` — mark the state before each consultation so the player can undo a
  bad contract with a `<- undo` choice
- `undo` mechanic via scene that calls `engine/checkpoint!` before each session and lets the
  player back out
- `verify after requires` — post-game invariant: "after any contract is accepted, the client's
  gold is reduced"; `requires` used as a precondition guard
- Lambda expressions explicitly: `fn(path): probability ... > 0.5`

**Sketch of state:**

```
type ContractKind = 'supply-run | 'escape | 'bet-sequence | 'assassination
state world/day          : Int(1, 30)
state world/reputation   : Int(0, 100)
state world/gold         : Int(0, 500)
state world/contract     : Option(ContractKind)
state clients/supply/gold : Int(0, 200)
state clients/gambler/gold: Int(0, 200)
state clients/spy/gold    : Int(0, 200)
```

**Scene structure:**
- `intro` → `shop` (main hub)
- `shop`: list active clients + current reputation; `engine/checkpoint!` here each turn
- `=> consult-supply`, `=> consult-gambler`, `=> consult-spy` (enter/exit sub-scenes)
- Each consult scene uses a search builtin to compute the answer, shows the result in
  narration (`{probability ...}`, `{can-reach? ...}`), then offers "Accept / Decline"
- `=> undo-last` scene that calls a pure fn to describe what will be rolled back, then
  player confirms — demonstrates checkpoint + undo
- `finale` when `world/day >= 20` or `world/reputation` reaches ceiling/floor

**Implementation notes:**
- The BFS search targets will be small sub-games embedded in the `.sb` file (separate
  scenes that model each client's situation); `can-reach?` / `probability` evaluate
  reachability over those scenes
- This keeps the state space small enough for fast BFS (< 1 second)
- `find-counterexample` returns a snapshot; narrate it as "The oracle has found your doom:
  {counterexample/...}"

---

### Demo 09 — "The Warden's Map" (advanced tile grid)

**Concept.** A dungeon-warden puzzle game. The player manages a small dungeon grid: placing
guards, toggling torches (opaque cells), and watching intruders try to reach the vault.
The game uses every advanced tile grid builtin not shown in demo06.

**Features to demonstrate:**

- `grid-get` / `grid-set!` — toggling torch cells (lit/dark) and trap cells
- `visible-from?` — guard sight-lines: a guard can only act on an intruder they can see
- `path-to` — display the shortest intruder route to the vault each turn
- `occupied-by` — check which guard (if any) occupies a cell before placing
- `while` loop — simulation of intruder advance each round until stopped or vault reached
- `cond` expression — multi-branch status message based on vault danger level
- Inline `Enum(lit, dark, trapped)` type for cell state
- Lambda in `count-where`: count visible intruders with explicit `fn(k): visible-from? ...`
- `engine/emit 'intruder-spotted {...}` on each sight-line trigger
- `verify from_any_state when ... : assert ...` — model-check that the vault is never
  reachable when all entry corridors are guarded

**Sketch of grid:**

```
defgrid dungeon 10 8:
  ##########
  #...V....#    V = vault, . = floor, # = wall
  #.######.#
  #......>.#    > = east entry, v = south entry
  #.######.#
  #........#
  #v.......#
  ##########
```

**State:**
```
type CellKind = Enum(floor, wall, torch, trap)
state guards/{g}/x    : Int(0, 9)
state guards/{g}/y    : Int(0, 7)
state world/round     : Int(1, 20)
state world/alert     : Int(0, 5)
state vault/breached  : Bool
```

**Scene structure:**
- `intro` → `warden-view` (main hub each round)
- `warden-view`: narrate current grid state, intruder path (`{path-to dungeon ...}`),
  visible intruder count, alert level
- Choices: place/move a guard, toggle a torch, set a trap, advance the round
- Advancing the round runs the `while` simulation (intruder movement loop)
- `engine/emit 'round-complete {round: world/round}` each round
- `=> place-guard`, `=> toggle-torch`, `=> set-trap` sub-scenes
- `finale` when vault is breached or all intruders are caught

---

---

### Demo 10 — "The Market Bell" (multi-axis time model)

**Concept.** A small trading-post game set over five days. The player buys and sells goods
at a village market that opens and closes on a real hour/day cycle. Schedules fire at
meaningful times of day, hours wrap cyclically, and a one-shot festival closes the market
permanently on day 5. This is the only demo to use more than one time axis.

**Time-model features to demonstrate:**

- **Multi-axis model** — `axes: [day, hour]` (two axes)
- **Cyclic wrap** — `wrap: [none, 24]` (hours wrap at 24; days do not)
- **Multi-axis `time-inc!`** — advancing both axes in one call: `time-inc! hour: 4`; a
  rest action advances `hour: 8`; waking at midnight wraps cleanly into the next day
- **`every:` with non-trivial `offset:`** — morning bell fires `every: [day: +1]` with
  `offset: [hour: 6]` (6am each day); evening close fires at `offset: [hour: 18]`
- **`at:` one-shot schedule** — `at: [day: +5]` triggers the grand festival, cancels the
  market permanently, fires `engine/emit 'festival-begins`
- **`time-inc!` producing a wrap event** — when hour exceeds 24 and wraps, a schedule
  fires `every: [day: +1]` automatically; narrate this as "A new day dawns."

**State:**

```
time-model:
  axes: [day, hour]
  wrap: [none, 24]

engine-config:
  entry-scene: market-town

state world/day         : Int(1, 6)    = 1
state world/hour        : Int(0, 23)   = 8
state market/open       : Bool         = true
state market/festival   : Bool         = false
state player/gold       : Int(0, 500)  = 100
state player/goods      : Int(0, 20)   = 5
state prices/grain      : Int(1, 20)   = 8
state prices/cloth      : Int(1, 30)   = 15
```

**Schedules:**

```
schedule morning-bell:
  every:  [day: +1]
  offset: [hour: 6]
  fn:
    set!  market/open true
    set!  prices/grain  (random-int 5 12)
    set!  prices/cloth  (random-int 10 25)
    engine/emit 'market-opened {day: world/day, hour: world/hour}

schedule evening-close:
  every:  [day: +1]
  offset: [hour: 18]
  fn:
    set!  market/open false
    engine/emit 'market-closed {day: world/day}

schedule grand-festival:
  at: [day: +5]
  fn:
    set!  market/festival true
    set!  market/open     false
    cancel-schedule! morning-bell
    cancel-schedule! evening-close
    engine/emit 'festival-begins {day: world/day}
```

**Transaction functions:**

```
fn buy-grain:
  pre:  market/open
  pre:  player/gold >= prices/grain
  dec!  player/gold  prices/grain
  inc!  player/goods 1

fn sell-grain:
  pre:  market/open
  pre:  player/goods > 0
  inc!  player/gold  prices/grain
  dec!  player/goods 1

fn rest:               # sleep until morning; advances 8 hours (may wrap day)
  pre:  not market/open
  time-inc! hour: 8

fn browse-stalls:      # pass 2 hours at the market
  pre:  market/open
  time-inc! hour: 2
```

**Scene structure:**

- `market-town` (main hub): narrate day, hour, market status, prices, gold, goods;
  conditional lines for "Market is open / closed", "Festival has begun"; choices gate on
  `market/open`
- Choices: buy grain, sell grain, browse stalls (+2 hr), rest until morning (+8 hr)
- `when market/festival`: `-> festival-end`
- `festival-end`: finale scene summarising gold earned over the five days

**Verify blocks (demonstrating `after` and `requires`):**

```
verify "gold never goes negative":
  verify-always player/gold >= 0

verify "selling requires goods":
  after (sell-grain):
    player/goods >= 0

verify "market closed at night":
  from_any_state
  when world/hour >= 18 or world/hour < 6:
    assert not market/open or market/festival
```

**Watch declarations:**

```
watch world/day          "Day"
watch world/hour         "Hour"
watch market/open        "Market open"
watch player/gold        "Gold"
watch prices/grain       "Grain price"
watch-when market/festival  "The Grand Festival has begun!"
```

---

---

### Demo 11 — "The Expedition Guild" (`find`, `Option(T)`, type aliases, computed goto, multiline strings, `@before`)

**Concept.** A guild management game. The player hires adventurers from a roster, assigns a
companion, equips a weapon, and dispatches expeditions over thirty days. The `find`
expression drives every roster query; `Option(T)` models nullable companion and weapon
slots; type aliases keep state declarations readable; a computed goto routes to each
companion's unique scene.

**Features to demonstrate:**

- **Type aliases** — `type Gold = Int(0, 500)` / `type Prestige = Int(0, 100)` — named
  abbreviations for bounded types; used throughout state declarations
- **`Option(T)`** — `state player/companion : Option(SymbolOf(members))` (nil = solo) and
  `state player/weapon : Option(WeaponKind)` (nil = unarmed); nil-coalescing `??` used in
  narration: `player/weapon ?? 'none`
- **`find` expression** — full `where`/`order-by`/`limit` form:
  - `find member where members/{member}/status = 'available order-by members/{member}/skill desc limit 4` — show best recruits
  - `find member where members/{member}/location = guild/location` — who is present today
  - `count-where` with explicit `fn(m): members/{m}/status = 'injured` lambda alongside `find` to contrast the two forms
- **Computed goto** — `-> (companion-scene player/companion)` routes to the scene named
  after the active companion; a pure fn `companion-scene key` returns the scene id as a
  symbol; also `-> (next-chapter world/chapter)` for chapter progression
- **Multiline strings** — quest briefings and expedition reports rendered as `"""..."""`
  blocks in narration and choice text
- **`@before` in verify** — `verify "hiring spends gold": after (hire-member m): player/gold < @before player/gold`; `requires guild/gold > 0`

**State:**

```
type Gold     = Int(0, 500)
type Prestige = Int(0, 100)
type MemberStatus = available | on-mission | injured | retired
type WeaponKind   = sword | bow | staff
type Chapter      = Enum(prologue, rising, climax, epilogue)

state guild/gold     : Gold      = 200
state guild/prestige : Prestige  = 10
state guild/day      : Int(1,30) = 1
state guild/chapter  : Chapter   = 'prologue

state members/{m}:
  status   : MemberStatus = 'available
  skill    : Int(1, 10)
  hire-cost: Int(5, 50)

state player/companion : Option(SymbolOf(members))
state player/weapon    : Option(WeaponKind)
```

**Key functions:**

```
fn companion-scene key:          # returns scene name for computed goto
  match key:
    'aldric: 'talk-aldric
    'mira:   'talk-mira
    'zhen:   'talk-zhen
    _:       'no-companion

fn hire-member m:
  pre:  members/{m}/status = 'available
  pre:  guild/gold >= members/{m}/hire-cost
  dec!  guild/gold members/{m}/hire-cost
  set!  members/{m}/status 'on-mission

fn equip-weapon w:
  set! player/weapon w

fn unequip:
  set! player/weapon nil

fn dismiss-companion:
  set! player/companion nil
```

**Scene structure:**

- `guild-hall` (hub): shows roster summary (`find` for available members), day, gold,
  prestige; `-> (companion-scene player/companion)` as a choice when companion is set
- `=> hire-roster`: full `find` query drives the list; hire action sets companion
- `=> armory`: `Option(WeaponKind)` equip/unequip; shows `player/weapon ?? 'unarmed`
- `talk-aldric`, `talk-mira`, `talk-zhen` (computed-goto targets): companion-specific scenes
- `no-companion`: reached when companion is nil
- `=> mission-briefing`: multiline string quest text, dispatches expedition
- `-> (next-chapter guild/chapter)` advances chapter on milestone
- `guild-epilogue`: finale when `guild/day >= 30`

---

### Demo 12 — "The Herbalist's Codex" (namespaced import + lib file)

**Concept.** A two-file herbalism game. A library file defines all shared types, state, and
pure helpers; the main file imports it with an alias and uses every name through the
namespace prefix. This mirrors real multi-module game authoring and demonstrates that
scene navigation, type references, and function calls all work across a namespaced import.

**Features to demonstrate:**

- **`import "codex_lib.sb" as Herb`** — namespaced import; all non-state names from the
  lib become `Herb.TypeName`, `Herb.fn-name`, `Herb.scene-name`
- Show that **state and relation declarations remain global** (no prefix needed to read
  `garden/moisture` even though it is declared in the lib)
- Cross-file **scene navigation**: `=> Herb.scene-harvest` enters a scene defined in the lib
- Cross-file **type references**: `type Remedy = Herb.PlantKind | 'none` in the main file
- Cross-file **function calls**: `Herb.assess-stock`, `Herb.brew-remedy remedy-kind`
- Reinforce **multiline strings** for lore entries in the lib file
- Reinforce **`Option(T)`**: `state workbench/remedy : Option(Herb.RemedyKind)` — what is
  currently being brewed (nil = empty bench)
- **`verify after`** across files: `after (Herb.brew-remedy r): workbench/remedy != nil`

**File layout:**

`demos/codex_lib.sb`:
```
module codex-lib
  version: 1.0

type PlantKind  = feverwort | silkmoss | ironroot | moonpetal
type RemedyKind = tonic | salve | elixir | poultice

state garden/{p}:
  quantity : Int(0, 20) = 0
  moisture : Int(0, 5)  = 3

"Assess whether the garden has enough of a plant to brew."
fn assess-stock plant min-qty:
  garden/{plant}/quantity >= min-qty

"Reduce moisture on all garden beds (called each day)."
fn dry-garden:
  for p in (path-list garden):
    when garden/{p}/moisture > 0:
      dec! garden/{p}/moisture 1

scene harvest:
  The garden beds stretch before you.
  ...
```

`demos/demo12_codex.sb`:
```
module codex-main
  version: 1.0

import "codex_lib.sb" as Herb

schema-version: 1

engine-config:
  entry-scene: workshop

type RemedyKind = Herb.RemedyKind      # re-export alias

state workbench/remedy  : Option(Herb.RemedyKind)
state workbench/day     : Int(1, 20)   = 1
state player/gold       : Int(0, 200)  = 50

fn brew-remedy r:
  pre:  Herb.assess-stock 'feverwort 3
  dec!  garden/feverwort/quantity 3
  set!  workbench/remedy r

fn sell-remedy:
  pre:  workbench/remedy != nil
  inc!  player/gold 15
  set!  workbench/remedy nil

scene workshop:
  The workshop. Day {workbench/day}. Gold: {player/gold}.
  Bench: {workbench/remedy ?? 'empty}.

  * Tend the garden
    => Herb.harvest
  * [Herb.assess-stock 'feverwort 3] Brew a tonic
    brew-remedy 'tonic
    -> workshop
  * [workbench/remedy != nil] Sell the remedy (+15 gold)
    sell-remedy
    -> workshop
  * Rest (advance day)
    Herb.dry-garden
    inc! workbench/day 1
    -> workshop
```

**Verify:**
```
verify "remedy requires ingredients":
  after (brew-remedy r):
    workbench/remedy != nil

verify "gold never negative":
  verify-always player/gold >= 0
```

---

### Prioritisation

Implement Demo 08 first — it demonstrates the most distinctive StoryBase capability (BFS
search as gameplay) and requires no new language features. Demo 09 (advanced tile grid),
Demo 10 (multi-axis time), Demo 11 (find/Option/computed goto), and Demo 12 (namespaced
import) can follow in any order; each is self-contained.

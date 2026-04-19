
# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-04-19)

All eight implementation phases complete. Demos 01–10 tested end-to-end via `--cli` mode.
**1706 tests passing.**

Next: implement demos 11 and 12.

---

## Active Tasks

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

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.

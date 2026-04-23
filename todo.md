
# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-04-23)

All eight implementation phases complete. Demos 01–11 tested end-to-end via `--cli` mode.
**1720 tests passing.**

Next: implement demo 12 (namespaced import + lib file).

Three compiler/runtime fixes landed for demo 11:
- **Lexer**: allow path expressions like `{player/companion}` inside `{}` in interp paths
- **Parser**: `make_interp_path` now handles `{...}` as a unit (not split on `/`)
- **Eval**: `render_text` uses `val_to_display` to show lists as comma-separated strings

---

## Active Tasks

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
- Cross-file **scene navigation**: `=> Herb.harvest` enters a scene defined in the lib
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

state garden/{p}: GardenBed  max: 4

type GardenBed:
  quantity: Int(0, 20)
  moisture: Int(0, 5)

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

engine-config:
  entry-scene: workshop

state workbench/remedy  : Option(Herb.RemedyKind)
state workbench/day     : Int(1, 20) = 1
state player/gold       : Int(0, 200) = 50

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

---

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.

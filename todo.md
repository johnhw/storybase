
# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-04-24)

All eight implementation phases complete. Demos 01–11 and demo_say tested end-to-end via `--cli` mode.
**1738 tests passing.**

Dialogue attribution system (`say` / `speaker`) is complete. Next: Demo 12.

---

## Active Tasks

### Demo 12 — "The Herbalist's Codex" (namespaced import + lib file)

**Concept.** A two-file herbalism game. A library file defines all shared types, state, and
pure helpers; the main file imports it with an alias and uses every name through the
namespace prefix. This mirrors real multi-module game authoring.

**Features to demonstrate:**

- **`import "codex_lib.sb" as Herb`** — namespaced import
- State declarations remain global (no prefix needed)
- Cross-file scene navigation: `=> Herb.harvest`
- Cross-file type references: `Option(Herb.RemedyKind)`
- Cross-file function calls: `Herb.assess-stock`, `Herb.dry-garden`
- Multiline strings for lore entries
- `verify after` across files

**File layout:**

`demos/codex_lib.sb`:
```
module codex-lib
  version: 1.0

type PlantKind  = feverwort | silkmoss | ironroot | moonpetal
type RemedyKind = tonic | salve | elixir | poultice

type GardenBed:
  quantity: Int(0, 20)
  moisture: Int(0, 5)

state garden/{p}: GardenBed  max: 4

fn assess-stock plant min-qty:
  garden/{plant}/quantity >= min-qty

fn dry-garden:
  for p in (path-list garden):
    when garden/{p}/moisture > 0:
      dec! garden/{p}/moisture 1

scene harvest:
  ...
```

`demos/demo12_codex.sb`:
```
module codex-main
  version: 1.0

import "codex_lib.sb" as Herb

engine-config:
  entry-scene: workshop

state workbench/remedy : Option(Herb.RemedyKind)
state workbench/day    : Int(1, 20) = 1
state player/gold      : Int(0, 200) = 50

fn brew-remedy r:
  pre:  Herb.assess-stock 'feverwort 3
  dec!  garden/feverwort/quantity 3
  set!  workbench/remedy r

fn sell-remedy:
  pre:  workbench/remedy != nil
  inc!  player/gold 15
  set!  workbench/remedy nil

scene workshop:
  ...
```

---

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] ANSI colour output in CLI for attributed dialogue.

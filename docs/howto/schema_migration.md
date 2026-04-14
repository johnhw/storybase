# How to Evolve the Schema Without Breaking Saves

When you change the game's data model — renaming a field, adding a new state path, removing an unused one — existing save files become incompatible. StoryBase's migration system lets you describe the transformation so old saves can be brought up to date automatically.

---

## 1. Bump the Schema Version

In your `.sb` file, increment `schema-version` whenever you change the schema:

```
schema-version: 3   # was 2
```

---

## 2. Write a Migration Block

```
migration 2 -> 3:
  rename player/xp player/experience
  add    player/prestige: Int(0, 10) = 0
  drop   player/old-flag
  transform player/class:
    'fighter: 'warrior
    'wizard:  'mage
    _:        'rogue
  rename-enum ClassType warrior mage rogue
```

Migration blocks are ordered by version number and applied in sequence when loading a save with an older `schema-version`. Each block takes a save from version N to N+1.

---

## Migration Operations

### `rename`

```
rename <old-path> <new-path>
```

Move the value from `old-path` to `new-path`. The old key is removed.

```
rename player/xp player/experience
rename npcs/blacksmith/dialogue npcs/blacksmith/greeting
```

---

### `add`

```
add <path>: <type> = <default>
```

Add a new state path with a default value. Existing saves get the default; there is no effect if the path already exists.

```
add player/prestige: Int(0, 10) = 0
add world/difficulty: Difficulty = 'normal
```

---

### `drop`

```
drop <path>
```

Remove a state path. The value is discarded.

```
drop player/legacy-flag
drop combat/old-outcome
```

---

### `transform`

```
transform <path>:
  <old-value>: <new-value>
  ...
  _: <default>
```

Remap enum values. The `_` branch handles any value not listed.

```
transform player/class:
  'fighter: 'warrior
  'wizard:  'mage
  'thief:   'rogue
  _:        'rogue
```

---

### `rename-enum`

```
rename-enum <TypeName> <old-value> <new-value>
```

Rename an enum value everywhere it appears in state. Useful when you rename an enum variant in the type declaration.

```
rename-enum Status alive living
rename-enum CharClass warrior fighter
```

---

## Running Migrations

### From the CLI

```bash
lua5.4 cli/main.lua migrate mygame.sb saves/slot1.log --out saves/slot1_migrated.log
```

If `--out` is omitted, the migrated log is written to stdout.

The command reads the `schema-version` embedded in the save log, determines which migration blocks need to run, and applies them in order.

### Automatically on load

`storybase run --load` applies migrations automatically before presenting the game. No manual step required.

### From Lua

```lua
game:load("saves/slot1.log")   -- migrations applied automatically
```

---

## Example: Adding a Field

Before (version 1):

```
schema-version: 1

state player:
  health: Int(0, 100) = 100
  gold:   Int(0, 999) = 30
```

After (version 2): add a `class` field.

```
schema-version: 2

type Class = warrior | mage | rogue

state player:
  health: Int(0, 100) = 100
  gold:   Int(0, 999) = 30
  class:  Class = 'warrior    # new field

migration 1 -> 2:
  add player/class: Class = 'warrior
```

Saves from version 1 will have `player/class = 'warrior` after migration.

---

## Example: Renaming a Field

```
schema-version: 3   # was 2

state player:
  experience: Int(0, 9999) = 0   # was player/xp

migration 2 -> 3:
  rename player/xp player/experience
```

---

## Tips

- Always test migrations by running `storybase migrate` against a real save before shipping.
- Keep migrations small — one conceptual change per block.
- Migration blocks are stripped from production builds (they are development-time tooling).
- If you need to change the type of an existing field (not just rename it), use `transform` or `drop` + `add`.

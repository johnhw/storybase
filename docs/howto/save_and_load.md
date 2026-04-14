# How to Save and Load Game State

---

## CLI: `--save` and `--load`

Save on exit:

```bash
lua5.4 cli/main.lua run mygame.sb --save saves/slot1.log
```

Load and resume:

```bash
lua5.4 cli/main.lua run mygame.sb --load saves/slot1.log
```

Save and load together (autosave pattern):

```bash
lua5.4 cli/main.lua run mygame.sb --load saves/slot1.log --save saves/slot1.log
```

If `--load` is given, the engine replays the log from scratch and applies any outstanding schema migrations (see [schema_migration.md](schema_migration.md)) before presenting the game.

---

## Save File Format

Save files are line-delimited NDJSON (one entry per line). Each line is a JSON log entry:

```json
{"seq":1,"time":{"tick":0},"fn":"_init","path":"player/health","value":100,"op":"set"}
{"seq":2,"time":{"tick":0},"fn":"_init","path":"player/gold","value":30,"op":"set"}
...
```

They are human-readable and diff-friendly. You can inspect or edit them in any text editor.

The save file also includes the scene stack (current scene and any pushed scenes).

---

## Lua API: `game:save` and `game:load`

```lua
local sb   = require("lib.storybase")
local game = sb.load("mygame.sb")
game:init()

-- Play some turns ...

-- Save
local ok, err = game:save("saves/slot1.log")
if not ok then print("Save failed: " .. err) end

-- Later: load
local ok, err = game:load("saves/slot1.log")
if not ok then print("Load failed: " .. err) end
```

`game:load` replays the log from scratch; any outstanding migrations are applied automatically.

---

## Compacting Large Save Files

After many turns, save files can become large. `compact` replays the log and emits a snapshot with one entry per path:

```bash
lua5.4 cli/main.lua compact mygame.sb saves/slot1.log --out saves/slot1_compact.log
```

The compacted file loads faster because it has fewer entries to replay. The original is not modified.

---

## Common Pitfalls

**Save file from an older schema version:** if you changed the game's schema after saving, load will fail or produce wrong state. Run `storybase migrate` first (see [schema_migration.md](schema_migration.md)).

**Loading a save from a different game:** the engine does not validate that the save belongs to the same game. Loading a mismatched save will produce undefined state.

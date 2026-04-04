# StoryBase Demo Games

A suite of five progressively complex example games using a consistent fantasy adventure theme.
Each game builds on the previous one, introducing new language features in a natural context.

---

## Game 1 — The Wanderer (`demo01_wanderer.sb`)

**Concept:** A traveller explores three locations in a simple linear adventure.

**Features demonstrated:**
- `module` / `engine-config` / `entry-scene`
- `state` (Int scalar)
- `scene` with narration text
- `->` (goto) scene transitions
- `inc!` mutation
- Inline expressions `{expr}` in narration

**Story:** You play a lone wanderer moving through a village, a forest, and a mountain pass.
The game tracks how many locations you have visited.

**State:**
```
state world:
  visited: Int(0, 99) = 0
```

**Scenes:** village → forest → mountain → summit (end)

**Notes:** No branches, no guards; purely linear to show the basic structure.

---

## Game 2 — The Merchant (`demo02_merchant.sb`)

**Concept:** A travelling merchant buys and sells goods, managing limited inventory.

**Features demonstrated:**
- Multiple state paths with different types (Int, Bool, Symbol)
- Choice guards `[condition]`
- Named transaction functions (`fn`)
- `save`/`load` (via CLI flags, not in-game; documented in comments)
- `match` expression
- Type declarations (`type`)

**Story:** You are a merchant in a fantasy market. Buy goods cheap, sell them at profit.
Mind your gold and inventory space.

**State:**
```
type Goods = herbs | iron | silk | empty

state merchant:
  gold:    Int(0, 9999) = 100
  item:    Goods = 'empty
  mood:    Symbol = 'neutral

state market:
  herb_price:  Int(1, 50) = 8
  iron_price:  Int(1, 50) = 15
  silk_price:  Int(1, 50) = 30
```

**Scenes:** market (hub), buy-herbs, buy-iron, buy-silk, sell, travel

**Guards:** Buy choices visible only when `merchant/gold >= price` and `merchant/item == 'empty`

---

## Game 3 — The Quest (`demo03_quest.sb`)

**Concept:** A short quest chain where completing tasks unlocks new options.

**Features demonstrated:**
- `Bool` state flags for quest progression
- `fn` with `pre:` precondition
- `if/else` control flow
- `when` conditional execution
- `cond` expression
- Enum types used for player class
- Multiple scene loops with distinct choice sets

**Story:** A young adventurer arrives in a village with three tasks to complete before the town
elder will reveal the secret of the lost shrine.

**State:**
```
type Class = warrior | mage | rogue

state player:
  class:        Class  = 'warrior
  found_herb:   Bool   = false
  slew_wolf:    Bool   = false
  spoke_elder:  Bool   = false
  shrine_found: Bool   = false
  xp:           Int(0, 999) = 0
```

**Scenes:** intro (class select), village (hub), forest, cave, elder, shrine (ending)

**Quest chain:** collect herb (forest) AND slay wolf (cave) → talk to elder → find shrine

---

## Game 4 — The Expedition (`demo04_expedition.sb`)

**Concept:** An expedition with a crew of NPCs; manage their morale and health.

**Features demonstrated:**
- Entity family (`state crew/{member}`)
- `spawn!` and `despawn!`
- `for` loops over `path-list`
- `find` query with `where` and `order-by`
- `path-exists?` predicate
- `SymbolOf(family)` type
- `set!` with interpolated paths

**Story:** You lead a three-person expedition into a dangerous canyon. Each crew member has
health and morale. You must manage resources and make decisions that affect the whole crew.

**State:**
```
type MemberId = SymbolOf(crew)

type Member:
  hp:     Int(0, 100) = 100
  morale: Int(0, 100) = 80
  role:   Symbol      = 'explorer

state crew/{member}: Member  max: 5

state expedition:
  food:     Int(0, 200) = 100
  day:      Int(0, 30)  = 0
  complete: Bool        = false
```

**Scenes:** camp (hub), explore, rest, forage, crisis (if morale < 30), summit

---

## Game 5 — The Siege (`demo05_siege.sb`)

**Concept:** A castle under siege with autonomous defenders and attackers; full engine showcase.

**Features demonstrated:**
- Actors with behaviors and message passing (`actor`, `behavior`, `send!`)
- Scheduled events (`schedule`, `every:`)
- `verify-always` blocks
- `find-path` search
- `cancel-schedule!`
- `counterfactual` query
- `time-model` with a turn axis

**Story:** You are a castle commander defending against waves of attackers. Autonomous defenders
patrol and react to threats. The siege advances by turn; manage resources to survive 10 turns.

**State:**
```
type WallSection = north | south | east | west

state castle:
  hp:        Int(0, 500) = 500
  supplies:  Int(0, 200) = 100
  turn:      Int(0, 30)  = 0
  breached:  Bool        = false

state defenders/{post}: Section  max: 4

actor north-guard: ...
schedule resupply: every: [turn: +3]
verify morale-check: ...
```

**Ending:** Survive 10 turns (win) or `castle/hp == 0` (lose).

---

## Implementation Order

1. `demo01_wanderer.sb` — implement first; validates basic pipeline end-to-end
2. `demo02_merchant.sb` — adds types, guards, fn calls
3. `demo03_quest.sb` — adds complex control flow and quest state
4. `demo04_expedition.sb` — adds entity families and queries
5. `demo05_siege.sb` — full feature showcase (actors, schedule, verify)

Each game should be runnable with `storybase run demo0N_name.sb` and include comments
explaining each feature. The siege game (demo05) also requires `storybase verify` to pass.

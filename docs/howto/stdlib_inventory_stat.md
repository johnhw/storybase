# `@stdlib/inventory` and `@stdlib/stat`

Two patterns appear in nearly every non-trivial StoryBase game:

- a **capped, set-backed inventory** at some path, with the conventional
  `give` / `take` / `has?` / `count` / `empty?` / `full?` / `clear!`
  surface; and
- a **bounded integer stat** (HP, mana, stamina, …) with `heal` / `hurt` /
  `restore` / `deplete` / `full?` / `empty?` / `current` accessors.

Both ship as `.sb` modules under `stdlib/`, importable through the
`@stdlib/<name>` prefix that the compiler resolves into its bundled
standard-library directory. Internally each module is a single
[`decl-macro`](../reference/language.md#decl-macro) that expands at
compile time into the boilerplate the author would have written by
hand — there is no compiler-internal magic.

## `inventory $name $T $max`

```
import "@stdlib/inventory"
type ItemKind = Enum(sword, shield, potion)
inventory player-bag ItemKind 8
```

expands to:

```
state player-bag: Set(ItemKind, 8) = (set)

fn player-bag-give item:   add!      player-bag item
fn player-bag-take item:   remove!   player-bag item
fn player-bag-has? item:   contains? player-bag item
fn player-bag-count:       size      player-bag
fn player-bag-empty?:      empty?    player-bag
fn player-bag-full?:       (size player-bag) = 8
fn player-bag-clear!:      clear!    player-bag
```

`$name` is the state path *and* the prefix used for the emitted fn
names — pass a single-segment kebab-case identifier (no `/`). Same
constraint as the `counter` example in the language reference: a
multi-segment path can't be reused inside a composite identifier.
Authors who want a nested family path such as `player/inventory`
should write the state declaration by hand and skip the macro.

`$T` is any previously declared discrete type; `$max` is the integer
capacity used in both the `Set` type bound and the `full?` predicate.

## `stat $name $min $max`

```
import "@stdlib/stat"
stat player-health 0 100
```

expands to:

```
state player-health: Int(0, 100) = 100

fn player-health-heal n:    inc! player-health n
fn player-health-hurt n:    dec! player-health n
fn player-health-set v:     set! player-health v
fn player-health-restore:   set! player-health 100
fn player-health-deplete:   set! player-health 0
fn player-health-full?:     player-health = 100
fn player-health-empty?:    player-health = 0
fn player-health-current:   player-health
```

The default value is `$max`, so a fresh stat starts "full". `Int(min,
max)` clamps automatically, so `player-health-hurt 9999` lands at the
`min` bound rather than going negative. To start the stat at a
different value, follow the macro call with a `set! $name <val>` in a
`generate` block or scene-on-enter body.

## End-to-end example

[`demos/demo25_dungeon_loot.sb`](../../demos/demo25_dungeon_loot.sb)
wires both modules into a small dungeon loop:

```
import "@stdlib/inventory"
import "@stdlib/stat"

type LootKind = Enum(potion, scroll, ring)

inventory player-bag    LootKind  3
stat      player-health 0         10

scene hall:
  A long hallway. HP {player-health-current}/10. Bag: {player-bag-count}/3.

  * [not (player-bag-has? `potion)] Grab a potion
    player-bag-give `potion
    -> hall

  * [player-bag-has? `potion] Quaff a potion (+4 HP)
    player-bag-take `potion
    player-health-heal 4
    -> hall

  * [player-bag-full?] Open the treasure room
    -> treasure
```

The demo includes a `verify "loot loop is winnable":
verify-eventually (player-bag-full?)` clause that proves at compile
time that the loop is reachable to its winning condition; `storybase
verify` confirms it under bounded BFS.

## When to drop the macro

The macros aren't load-bearing — both expansions are mechanical, and
copying the equivalent state + fn block by hand keeps the same
behaviour. Drop the macro when you need:

- a nested family path (`player/inventory`),
- a different fn surface (e.g. `regen`, `overheal`, `slot[N]`),
- different defaults / clamp boundaries that the macro doesn't expose.

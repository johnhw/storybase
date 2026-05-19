# `@stdlib/dialog`

Nearly every talk-to-an-NPC scene in a StoryBase game tracks the same
boilerplate: a `Bool` flag per topic so the choice list can hide
questions already asked, mutate the flag on entry, and let a
follow-up question gate itself on an earlier one being asked.
`stdlib/dialog.sb` ships a single decl-macro that emits the flag and
the conventional helpers for one topic per call.

## `dialog-topic $owner $topic`

```
import "@stdlib/dialog"
dialog-topic smith family-history
```

expands to:

```
state smith-asked-family-history: Bool = false

fn smith-asked-family-history?:
  smith-asked-family-history

fn smith-not-asked-family-history?:
  not smith-asked-family-history

fn mark-smith-family-history-asked!:
  set! smith-asked-family-history true

fn smith-reset-family-history!:
  set! smith-asked-family-history false
```

The flag defaults to `false`; the four helper fns track and
manipulate it through the conventional shapes a talk-scene needs.

Both `$owner` and `$topic` must be single-segment kebab-case
identifiers (no `/`) because the substrate fuses them into a single
COMPOSITE_IDENT. To partition flags under a hierarchical path (e.g.
`asked/{owner}/{topic}`), write the boilerplate by hand or layer
your own wrapper macro on top.

## Typical use

```
import "@stdlib/dialog"

dialog-topic smith family-history
dialog-topic smith deliver-ore
dialog-topic smith forge-secret

scene forge:
  The blacksmith looks up from his anvil.

  * [smith-not-asked-family-history?] Ask where he learned the trade.
    mark-smith-family-history-asked!
    say smith: My grandfather built this forge in 1882.
    -> forge

  * [smith-asked-family-history? and smith-not-asked-forge-secret?] Press him about the forge's reputation.
    mark-smith-forge-secret-asked!
    say smith: I do not sharpen blades that go north of the river.
    -> forge

  * Leave the forge.
    -> done
```

Each topic's asked-flag is independent: marking one does not
affect any other. The macro only handles the flag — the
say-line, knowledge-flag mutation, rapport adjustment, or whatever
else the topic *does* stays in the choice body where it belongs,
since that part is unique per topic.

## Verifying reachability

Because each topic flips a real Bool state path, the standard
`verify-eventually` form proves a topic is reachable from the
initial state under bounded BFS:

```
verify "every topic is reachable to the asked state":
  verify-eventually smith-asked-family-history?
  verify-eventually smith-asked-deliver-ore?
  verify-eventually smith-asked-forge-secret?
```

A passing verify run is the same evidence the engine gives for
hand-rolled asked-flags; the macro doesn't add or remove any
analysis guarantees.

See `demos/demo_dialog_smith.sb` for a complete end-to-end example.

## Scope and trade-offs

This module deliberately handles **only** the asked-flag pattern.
An earlier sketch (see `todo.md` §E2) proposed a block-level
`dialog blacksmith-talk:` form with nested `topic … once / always /
when:` sub-clauses that would expand into a whole scene and per-topic
choices. The substrate today doesn't model nested-keyword
sub-declarations, so that form would have required another compiler
extension. The narrower per-topic macro shipped here removes the
same boilerplate without changing the compiler at all.

## Errors

| Condition | Diagnostic |
|---|---|
| `dialog-topic npcs/meredith family-history` (multi-segment `$owner`) | `MACRO_DECL_EMIT — decl-macro: cannot resolve composite identifier` |
| `dialog-topic meredith locked/study` (multi-segment `$topic`) | `MACRO_DECL_EMIT — decl-macro: cannot resolve composite identifier` |
| `dialog-topic meredith` (wrong arity) | `MACRO_DECL_EMIT — decl-macro 'dialog-topic' expects 2 argument(s), got 1` |

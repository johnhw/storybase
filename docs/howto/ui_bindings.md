# UI bindings — how-to

This guide shows how to add a live HUD to a StoryBase game without
writing any driver code. You annotate state declarations with a `ui:`
block, optionally compose them in a `ui-panel`, and every driver that
knows about UI bindings — curses, plain, ansi, the buffer-backed test
driver, future GUIs — renders the right widget.

The mental model is the same one the engine already uses: **the author
declares; the runtime interprets.** You describe *what* the player
should see — a bar for HP, a toggle for "auto-rest", an inventory list,
a radio group for a triage choice. The driver decides *how* to draw it.

See `demos/demo35_healers_ward_ui.sb` for a fully worked example.

---

## The shortest possible HUD

```
state player/hp: Int(0, 100) = 100
  ui:
    kind:  stat-bar
    label: "Health"
```

That's it. Compile and run with `--ui curses`; a stat bar reading
`Health: 100/100 [###...]` appears at the top of the screen. Run the
same source with `--ui plain` and a line reading `Health: 100/100`
prefixes every scene render. No additional declarations, no glue code,
no driver-specific markup.

The widget is *reactive*. The next `inc!`, `dec!`, or `set!` on
`player/hp` fires a `mutation` event through the kernel; the curses
driver re-renders just the bar's row (the rest of the screen diffs
clean). The plain driver re-emits the header line on the next scene
pull. You don't have to wire any of this — it falls out of the binding.

---

## Two surfaces: `ui:` block vs `ui-panel`

There are two places you can declare a binding.

### 1. `ui:` on a state decl

Use this when the widget *is* the state.

```
state player/hp: Int(0, 100) = 100
  ui:
    kind:       stat-bar
    label:      "Health"
    color-good: "#4ade80"
    color-bad:  "#ef4444"

state world/auto-rest: Bool = false
  ui:
    kind:  toggle
    label: "Auto-rest"
    fn:    set-auto-rest
```

The `ui:` block is a trailing indented block on the state decl —
indent it once below the `state ... = ...` line. The keys inside are
free-form: drivers consume what they recognise and ignore the rest, so
e.g. `color-good`/`color-bad` are hints the curses driver can honour
and the plain driver can drop.

Every binding key is parsed as a literal (string, int, float, bool,
ident, symbol, path). Quote anything that contains spaces or
punctuation; otherwise the bare identifier form is fine.

### 2. `ui-panel` top-level decl

Use this when you want to compose multiple widgets, mix in interpolated
text, or reuse a state path under a different widget kind.

```
ui-panel ward-hud:
  layout:   vstack
  position: top
  children:
    - stat-bar  world/herbs
    - stat-bar  world/bandages
    - stat      world/day
    - text      "Tending: {world/selected-patient} (day {world/day})"
    - choice    world/triage-focus
    - toggle    world/auto-rest
    - inventory world/journal
```

Each child line is `<widget-kind> <argument>`, optionally prefixed by
`-`. Path widgets (`stat-bar`, `stat`, `toggle`, `choice`, `inventory`)
take a state path; the `text` widget takes a template string.

Panels are pure presentation. The compiler emits them into
`game_table.ui_panels` and drivers consume them via the kernel's
`get_bindings()` query. `verify` ignores them. Saves do not contain
them.

You can declare multiple panels (`ui-panel header:`, `ui-panel footer:`,
…); drivers may render them into different screen regions according to
the `position:` hint (`top` / `bottom` are the two values drivers
currently honour).

### When to use which

- **`ui:` on a state decl** is the right answer 90 % of the time. The
  binding lives next to the state it renders, you don't have to repeat
  the path, and it stays in sync if you rename the path.
- **`ui-panel`** wins when you need to (a) interleave a `text` widget
  whose template references several paths, (b) order widgets
  differently from declaration order, or (c) bind the same state to
  more than one widget kind.

The two surfaces compose: when both are present the driver discovers
state-decl bindings first, then walks the panel and skips any path
that's already been claimed by an explicit `ui:` block. Your `ui:`
block always wins over a panel reference to the same path.

---

## Widget vocabulary

Every binding has a `kind:`. The driver-agnostic vocabulary today:

| kind        | binds to                | renders as                                  |
|-------------|-------------------------|---------------------------------------------|
| `stat-bar`  | bounded `Int(min, max)` | `Label: cur/max [#####....]`                |
| `stat`      | any scalar              | `Label: value` (formatted per type)         |
| `toggle`    | `Bool`                  | `[x] Label` / `[ ] Label`                   |
| `choice`    | inline enum             | radio group, one `(*)`/`( )` row per value  |
| `inventory` | `Set` / `List` / `UList`| scrollable bulleted list                    |
| `text`      | template string         | static or live-updating interpolated line   |

The plain driver renders `stat-bar`, `stat`, `toggle`, `inventory`,
and `text` as one-line headers; `choice` is curses-only (it has no
sensible flattening to a single text line). The ansi driver adds
colour. The curses driver adds the full set plus a scrolling
`narration` pane and the numbered `choices` list (those last two are
always present — you don't need to bind them).

### Per-widget keys

All keys are optional unless noted. Drivers ignore keys they don't
understand, so adding driver-specific hints is safe.

- **`stat-bar`** (`Int(min, max)`)
  - `label` — string. Defaults to the trailing path segment.
  - `color-good`, `color-bad` — hex colours (`"#4ade80"`). Honoured by
    ansi / curses; ignored by plain.

- **`stat`** (any scalar)
  - `label` — string.
  - Values format through `ui/format.value`: bounded `Int` → `cur/max`,
    `Bool` → `yes/no`, enum → label, `Set`/`List` → `(a, b, c)`.

- **`toggle`** (`Bool`)
  - `label` — string.
  - `fn` — name of a fn to call on the flip. The widget passes the
    *new* boolean as a single arg, so `fn set-auto-rest v: …` is the
    canonical shape.
  - `on-glyph`, `off-glyph` — single-character overrides for `x` / ` `.

- **`choice`** (inline enum or `SymbolOf(family)`)
  - `label` — string. Doubles as the radio-group header.
  - `fn` — fn name to call on Enter; receives the newly-selected symbol.

- **`inventory`** (`Set` / `List` / `UList`)
  - `label` — string. Doubles as the list header.
  - `max-rows` — integer, default `5`. Hard cap on visible items.
  - `bullet` — single-character glyph, default `-`.
  - `empty-text` — string shown when the collection is empty.
  - `fn` — fn name to call on Enter against the highlighted item.

- **`text`** (template)
  - On a state decl: `template:` defaults to `"{<that-path>}"`.
  - On a panel child: the argument string is the template.
  - `{path}` substitutes the live value through the same formatter
    `stat`/`stat-bar` use.
  - `{{` / `}}` escape to literal braces.
  - The widget subscribes to every referenced path so any of them
    mutating triggers a repaint.

---

## A worked example: the healer's ward

`demos/demo35_healers_ward_ui.sb` extends `demos/demo13_healers_ward.sb`
with a full HUD. The interesting declarations:

```
state world/herbs: Int(0, 20) = 12
  ui:
    kind:       stat-bar
    label:      "Herbs"
    color-good: "#4ade80"
    color-bad:  "#ef4444"

state world/triage-focus: TriageFocus = `any
  ui:
    kind:  choice
    label: "Triage focus"

state world/auto-rest: Bool = false
  ui:
    kind:  toggle
    label: "Auto-rest"
    fn:    set-auto-rest

state world/journal: UList(String) = ["Ward opens."]
  ui:
    kind:     inventory
    label:    "Journal"
    max-rows: 5

ui-panel ward-hud:
  layout:   vstack
  position: top
  children:
    - stat-bar  world/herbs
    - stat-bar  world/bandages
    - stat      world/day
    - text      "Tending: {world/selected-patient} (day {world/day})"
    - choice    world/triage-focus
    - toggle    world/auto-rest
    - inventory world/journal
```

Run it:

```
lua5.4 cli/main.lua run demos/demo35_healers_ward_ui.sb --ui curses
lua5.4 cli/main.lua run demos/demo35_healers_ward_ui.sb --ui plain --auto --steps 6
```

Or capture a deterministic curses snapshot via the buffer backend:

```
lua5.4 cli/main.lua run demos/demo35_healers_ward_ui.sb \
  --ui curses --ui-backend buffer \
  --ui-rows 30 --ui-cols 80 \
  --ui-keys "1131q" --ui-snapshot /tmp/hud.txt
```

A `dec! world/herbs 1` inside `apply-herbs` immediately repaints the
herbs bar (and only that bar's row — the rest of the screen diffs
clean). A `push! world/journal "Bandage applied."` likewise prepends a
new bullet to the inventory widget. The toggle calls `set-auto-rest`
when the player presses space on it, which writes to `world/auto-rest`
and pushes a journal entry — the toggle widget then re-reads its bound
path and flips `[ ]` to `[x]` in the next frame.

---

## Production builds

By default `--production` (i.e. `storybase bundle --production`) strips
both `state.ui` and `ui_panels` from the bundled game-table. The
rationale is that production hosts usually wire their own UI directly
on top of the engine API and don't need the runtime-author bindings.

To keep the bindings under `--production`, opt in via `engine-config`:

```
engine-config:
  entry-scene: start
  ui-runtime:  true
```

With `ui-runtime: true`, bundled games retain their bindings and any
driver that walks `game.schema.states[*].ui` / `game.ui_panels` will
light up the HUD exactly as in development.

---

## Common pitfalls

- **Naming a fn `log`**. The runtime has a builtin `log` (mathematical
  logarithm). A user fn called `log` will be shadowed silently. Pick a
  different name (`record-event`, `journal-add`, …).
- **Nested interpolation in `text` templates**. The `text` widget's
  template parser is one-level: `{patients/{world/selected-patient}/name}`
  will *not* resolve correctly. Use a flat path or surface the value
  through a derived state. (Demo35 uses
  `"Tending: {world/selected-patient}"` for this reason.)
- **`inventory` on a family**. The widget binds to a *scalar* path
  holding a Set / List / UList. To render a family as a list, expose
  the family keys via a derived UList or write your own loop.
- **Panel child ordering vs state-decl bindings**. The driver discovers
  `ui:` blocks first (in state declaration order), then walks the
  panel and skips already-claimed paths. If you want the panel order
  to win, omit the `ui:` block on the state and let the panel be the
  sole binding.
- **Curses-only widgets in plain output**. `choice` has no flattening,
  so it simply doesn't appear in the plain driver's header. The
  underlying state path is still readable from narration via `{path}`
  interpolation if you need it on the plain driver too.

---

## Where to read next

- The driver-side contract — events, queries, commands, screen model —
  lives in [`docs/reference/driver_protocol.md`](../reference/driver_protocol.md).
- The architecture rationale, milestone history, and open questions
  live in [`ui_idea.md`](../../ui_idea.md).
- Compiler tests for the binding parsers:
  `tests/compiler/ui_bindings_spec.lua`.
- Curses widget specs, one per widget kind, under `tests/ui/`.

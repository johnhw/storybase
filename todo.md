# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-05-01)

All eight implementation phases complete. Language review passes 1 and 2 complete.
Demos 01–20 tested end-to-end. UList(T) and UMap(K,V) fully implemented.
Code review rounds 1 and 2 fully resolved (bugs, inelegances, false impls, design flaws).
Demo 20 (Harrow House) complete: 3 bugs fixed, 9 regression tests added.
API extended with `game:scene()`, `game:choices()`, `game:pick()` convenience methods.
**1986 unit tests passing (busted tests/).**

---

## Deferred / Low Priority

- [ ] Every public function in every module has at least one passing and one failing test.
- [ ] ANSI colour output in CLI for attributed dialogue.
- [ ] Inelegance #7 — BFS expansion logic duplicated ~5×. Deferred: each BFS function has a different data payload (priority/path/prob/cost) and queue mechanism (FIFO/heap/yield). Extracting a shared helper would require a messy callback strategy and add more complexity than it removes.

---

## Demo 20: The Harrow House (Complete)

Bugs fixed and tests added (2026-05-01):
- Fixed `ending-offered-hand` rapport condition: `= 10` → `>= 9` (max achievable is 9)
- Fixed lock-out bug: asking about locked study in prosaic phase consumed the flag, blocking
  key acquisition in uneasy; added re-ask choice guarded by `phase != prosaic and not (study-key in inventory) and rapport >= 6`
- Fixed study notebook-1 "Read" option persisting after reading; added `not (knows? 'knows-family-strain)` guard matching notebooks 2 and 3

Original plan (all implemented):

A complete showcase game: a Lovecraftian mystery set in a Victorian house in the present-day Midwest.
The player must uncover what a solitary, guarded woman is doing in a sealed ancestral home.
The primary mechanic is conversation — asking questions at the right moment, in the right room,
with enough earned rapport. Navigation and object discovery play a supporting role.

### Target features to showcase

- `time-model` with named `period` axis (drives Meredith's schedule)
- `actor` + `schedule` for NPC daily movement
- `relation` for the room-exit graph (some edges initially absent, unlocked by events)
- `bounded` for NPC dialog-intent classification
- `rapport`/`wariness` Int state and guard conditions on choices
- `Set(KnowledgeFlag)` for player knowledge accumulation
- `spawn!`/`despawn!` for conditional appearances of Meredith in rooms
- `hook after: move-to:` for ambient narration that changes by phase
- `verify` blocks for key invariants
- Three-phase Lovecraftian tonal arc encoded in `Phase` enum state

---

### Setting

**House:** Harrow House, a three-storey Victorian in southern Ohio, built 1884.
Owned by the late Professor Elias Harrow; his granddaughter **Meredith Harrow** now lives
there alone. The house has not been significantly altered since the 1920s.
The player arrives as a prospective buyer (or journalist, or distant relative — left vague).

**Tone arc:**
- **Phase 1 (prosaic):** Rooms are dusty but normal. Meredith is politely evasive. The mystery
  is mundane — a private woman in an old house with family history she'd rather not discuss.
- **Phase 2 (uneasy):** The locked study is opened. Its books are wrong. Sounds come from below.
  Meredith's behaviour changes after dusk. Certain angles in the sub-rooms feel subtly off.
- **Phase 3 (revelation):** The basement and sub-basement are reached. The Professor's notebooks
  explain what the house actually is. Meredith is the custodian of something that must not leave.
  The ending is ambiguous: was she protecting the world, or feeding it?

---

### Rooms

Twelve rooms total. Access gates marked; locked rooms require specific knowledge or items.

| Symbol       | Room                  | Access gate                          | Phase first enters |
|--------------|-----------------------|--------------------------------------|--------------------|
| `foyer`      | Entrance Foyer        | always open                          | 1                  |
| `parlour`    | Parlour               | always open                          | 1                  |
| `dining`     | Dining Room           | always open                          | 1                  |
| `kitchen`    | Kitchen               | always open                          | 1                  |
| `library`    | Ground-floor Library  | always open                          | 1                  |
| `garden`     | Rear Garden           | always open (via kitchen)            | 1                  |
| `landing`    | Upper Landing         | always open (via foyer staircase)    | 1                  |
| `study`      | Professor's Study     | needs `study-key` item               | 2                  |
| `bedroom`    | Meredith's Bedroom    | Meredith refuses entry               | 2 (partial)        |
| `attic`      | Attic                 | needs `attic-key` found in study     | 2                  |
| `basement`   | Basement              | needs `basement-key` found in study  | 2–3                |
| `chamber`    | The Sub-basement      | needs `knows-mechanism` + lamp lit   | 3                  |

Room exits (static relation, some edges added at runtime):

```
foyer     <-> parlour, dining, landing
kitchen   <-> dining, garden
library   <-> foyer
study     <-> landing          (edge added when study-key acquired)
attic     <-> landing          (edge added when attic-key acquired)
basement  <-> kitchen          (edge added when basement-key acquired)
chamber   <-> basement         (edge added when mechanism activated)
bedroom   <-> landing          (never traversable by player)
```

---

### Character: Meredith Harrow

Mid-to-late 50s. Former academic (art history). Returned to the house five years ago
after her last surviving parent died. She has not left the property in three years.

**Personality:** measured, self-possessed, watchful. Not hostile — she invited you in —
but deeply reluctant to discuss the house, the Professor, or her work. She will deflect
intrusive questions with politeness, then with brevity, then by excusing herself.

**Dialog style:** complete sentences, slightly formal register. Never contractions in
stressed moments. She often answers a question by asking one back.

**Schedule (the `period` axis, 8 periods per day, advancing each scene visit):**

| Period | Value       | Location        | Receptivity            |
|--------|-------------|-----------------|------------------------|
| 0      | `dawn`      | kitchen         | low (preoccupied)      |
| 1      | `morning`   | library         | high (most open)       |
| 2      | `mid-morning` | parlour       | medium                 |
| 3      | `noon`      | dining          | low (eating, brief)    |
| 4      | `afternoon` | garden          | medium (occupied)      |
| 5      | `late-afternoon` | landing    | very low (writing)     |
| 6      | `evening`   | kitchen→dining  | low (preparing dinner) |
| 7      | `night`     | bedroom         | unavailable            |

After period 7 the day resets (`wrap: [8]`). On reset, `wariness` decrements by 1 (she
forgets small slights overnight) and `day-count` increments.

Meredith is `spawned` at her scheduled location each period. The `actor meredith`
behavior function moves her between periods and despawns/respawns as needed.

**Refusal behaviour:**
- If `wariness >= 3` she gives one-word or deflecting answers.
- If `wariness >= 5` she excuses herself and leaves the room (`despawn!`); she does not
  return until the next period.
- Certain topics always trigger a wariness increment regardless of rapport:
  `ask-about-sounds`, `ask-about-basement`, `ask-about-rituals` (in phase 1).

---

### State Schema (outline)

```
type Phase    = prosaic | uneasy | revelation
type Period   = dawn | morning | mid-morning | noon | afternoon | late-afternoon | evening | night
type Room     = foyer | parlour | dining | kitchen | library | garden | landing | study | bedroom | attic | basement | chamber
type Disposition = welcoming | cautious | withdrawn | absent

type KnowledgeFlag =
  knows-harrow-history | knows-family-strain | knows-basement-exists |
  knows-strange-sounds | knows-locked-study | knows-harrow-research |
  knows-occult-geometry | knows-ritual-purpose | knows-the-vigil |
  knows-the-mechanism | knows-the-truth

type ItemKind = study-key | attic-key | basement-key | oil-lamp | harrow-notebook-1 | harrow-notebook-2 | harrow-notebook-3 | mechanism-token

state world:
  phase:         Phase             = 'prosaic
  period:        Period            = 'morning
  day:           Int(0, 30)        = 0
  ambient-light: Bool              = true    # false after lamp required

state player:
  location:      Room              = 'foyer
  inventory:     Set(ItemKind, 8)  = (set)
  knowledge:     Set(KnowledgeFlag, 15) = (set)
  rapport:       Int(0, 10)        = 3
  wariness:      Int(0, 5)         = 0

state meredith:
  location:      Room              = 'kitchen
  disposition:   Disposition       = 'welcoming
  period-index:  Int(0, 7)         = 1

# Asked-about flags prevent repetition and track escalation
state asked:
  family-history:    Bool = false
  harrow-research:   Bool = false
  locked-study:      Bool = false
  sounds:            Bool = false
  basement:          Bool = false
  her-work:          Bool = false
  leaving:           Bool = false

time-model:
  axes: [period]
  wrap: [8]

relation house-exits: Room -> Set(Room, 4):
  # ... static edges listed above; dynamic edges added at runtime

relation room-items: Room -> Set(ItemKind, 4):
  'study:    {'attic-key, 'basement-key, 'harrow-notebook-1}
  'attic:    {'harrow-notebook-2, 'oil-lamp}
  'basement: {'mechanism-token}
  'chamber:  {'harrow-notebook-3}
```

---

### Knowledge Acquisition Logic

Knowledge is accumulated three ways:

1. **Room discovery:** entering a room for the first time grants a knowledge flag
   (e.g. entering the study grants `knows-locked-study` → `knows-harrow-research` after reading).
2. **Item reading:** picking up a Harrow notebook and "reading" it grants its knowledge flag.
3. **Dialog:** asking Meredith about a topic at sufficient rapport grants knowledge.
   Some knowledge can *only* come from Meredith (e.g. `knows-the-vigil`).
   Some knowledge Meredith will *never* give — it must be found in the notebooks.

Knowledge flags gate both new dialog options and phase transitions:

- Phase transitions:
  - `prosaic → uneasy`: `knows-harrow-research` obtained
  - `uneasy → revelation`: `knows-the-vigil` obtained (only Meredith can give this,
    requires rapport >= 7 and the player to have already found both notebooks)

---

### Dialog Design

Each dialog choice is a `scene talk-meredith` sub-scene. Choices are guarded by:
- Player location = Meredith's current location
- Meredith's disposition != `absent`
- Rapport/wariness thresholds
- `asked/topic = false` (to show a topic for the first time) or `true` (follow-ups)
- Phase (some topics only available in phase 2 or 3)

Sample choice structure in `scene talk-meredith`:

```
* [meredith/disposition != 'absent  and  rapport >= 4  and  not asked/harrow-research]
  "What was your grandfather actually working on, toward the end?"
  ask-about-research
  -> talk-meredith

* [meredith/disposition != 'absent  and  world/phase != 'prosaic  and  rapport >= 6]
  "The sounds from beneath the house — when did they start?"
  ask-about-sounds
  -> talk-meredith
```

Dialog function `ask-about-X` sets the `asked/X` flag, adjusts rapport/wariness,
grants knowledge, and may change Meredith's disposition or trigger her departure.

**Response texture (key beats):**

| Topic                | Phase 1 response                        | Phase 2 response                            | Phase 3 response                         |
|---------------------|-----------------------------------------|---------------------------------------------|------------------------------------------|
| Family history       | "The Professor was a remarkable man."   | "He was obsessive. We did not speak much."  | "He gave everything to the work."        |
| His research         | "Mathematics. Theoretical geometry."    | "Not geometry that appears in any text."    | "He called it threshold cartography."   |
| The locked study     | "Private. It belonged to him."          | "I have the key now."                       | (gives key at rapport 8)                 |
| Sounds from below    | "Old pipes. The house settles."         | Pauses. "You hear it too."                  | "It quiets if I am present at midnight." |
| Her work             | "I tend the house. There is always work."| "I maintain certain... conditions."        | "I am the last one who knows how."       |
| The vigil            | unavailable                             | Deflects entirely.                          | Reveals (rapport >= 7 only)              |

---

### Phase Narration

Phase transitions are reflected in ambient room descriptions. The `hook after: move-to:`
generates a secondary description line that changes by phase.

Phase 1 examples:
- Foyer: *The hallway smells of cedar and old paper. Afternoon light through the transom.*
- Kitchen: *A kettle on the range. Everything ordered and clean.*

Phase 2 examples:
- Foyer: *The portraits seem to watch you differently today. You cannot say exactly how.*
- Basement (first entry): *The air is wrong down here. Not cold — simply wrong, in a way
  your body registers before your mind does.*

Phase 3 examples:
- Chamber: *The angles of this room do not add up. You have measured them. They do not add up.*
- Anywhere at night: *Something below is patient. You understand now why she does not sleep.*

---

### Endings

Three possible endings, all reached from `scene chamber`:

1. **The Vigil Continues** (rapport >= 8, `knows-the-truth`): The player understands and
   chooses to leave without disturbing anything. Meredith thanks them quietly at the door.
   Tone: melancholy, respectful.

2. **The Mechanism Fails** (player activates mechanism-token without `knows-the-truth`):
   Something stirs. The player flees. What happens to Meredith is not shown.
   Tone: abrupt horror, aftermath only.

3. **The Offered Hand** (only if player has all three notebooks AND rapport = 10):
   Meredith asks the player to stay. To learn. To help maintain the vigil.
   The player must choose. Tone: quietly cosmic.

---

### Implementation Plan

1. [ ] Write `demos/demo20_harrow_house.sb` — full game source in StoryBase
2. [ ] Schema: types, state, time-model, relations
3. [ ] Actor `meredith`: schedule-driven movement via period-indexed relation
4. [ ] `scene` blocks: 12 rooms + `talk-meredith` + 3 ending scenes
5. [ ] Dialog functions: `ask-about-X` for ~10 topics, with rapport/wariness effects
6. [ ] Phase transition functions: `enter-uneasy`, `enter-revelation`
7. [ ] Item/knowledge integration: reading notebooks, room-discovery flags
8. [ ] Hook: `after: move-to:` for phase-sensitive ambient narration
9. [ ] Verify blocks: key invariants (rapport bounds, phase monotonicity, ending conditions)
10. [ ] CLI test: walk the full mystery path with `--cli` scripted sequence

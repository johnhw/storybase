# Tutorial 1: Hello World

Build your first interactive fiction story in StoryBase — a single scene with one choice and a state counter.

By the end of this tutorial you will understand:
- The minimal structure every `.sb` file needs
- How to declare state
- How to write a scene with narration and choices
- How to read state in narration text
- How to mutate state from a choice

---

## Prerequisites

- Lua 5.4 installed (`lua5.4 --version`)
- StoryBase repository cloned

---

## Step 1 — The Minimal File

Create a file called `hello.sb`:

```
module hello
  version: 1.0

engine-config:
  entry-scene: start

scene start:
  Hello, adventurer!
  * Continue
    -> start
```

Run it:

```bash
lua5.4 cli/main.lua run hello.sb
```

You should see:

```
Hello, adventurer!
1) Continue
>
```

Pressing `1` takes you back to the same scene — it loops forever.

**What each part does:**

- `module hello` — names the module. `version: 1.0` is used by the migration system.
- `engine-config: entry-scene: start` — tells the engine which scene to show first.
- `scene start:` — declares a scene named `start`.
- `Hello, adventurer!` — a narration line; displayed to the player.
- `* Continue` — a choice the player can make. The `*` marks it as a choice.
- `-> start` — goto: navigate to the scene named `start`. The scene stack is unchanged.

---

## Step 2 — Add State

State is the memory of your game. Add a visit counter:

```
module hello
  version: 1.0

engine-config:
  entry-scene: start

state world:
  visited: Int(0, 99) = 0

scene start:
  Hello, adventurer! You have visited {world/visited} times.
  * Continue
    inc! world/visited 1
    -> start
```

Run it again. Each time you pick "Continue", the count goes up.

**New parts:**

- `state world:` — declares a group of state variables under the path prefix `world`.
- `visited: Int(0, 99) = 0` — a bounded integer from 0 to 99, starting at 0.
- `{world/visited}` — inline expression in narration; displays the current value of `world/visited`.
- `inc! world/visited 1` — increments `world/visited` by 1. Int state is saturating: once it hits 99, further increments do nothing.

---

## Step 3 — Add Multiple Scenes

Let's add a second scene and a way to navigate between them:

```
module hello
  version: 1.0

engine-config:
  entry-scene: start

state world:
  visited: Int(0, 99) = 0

scene start:
  You stand at the crossroads.
  You have visited {world/visited} place(s).
  * Head north into the forest.
    inc! world/visited 1
    -> forest
  * Stay here.
    -> start

scene forest:
  The forest is cool and dark.
  You have visited {world/visited} place(s).
  * Return to the crossroads.
    -> start
```

Now you can travel between scenes and watch the counter change.

**Navigation:**

- `-> forest` — goto the `forest` scene. Any uncompleted scene is replaced.
- `-> start` — goto back to `start`.

---

## Step 4 — Check for Errors

Before running, it's good practice to compile first:

```bash
lua5.4 cli/main.lua compile hello.sb
```

If there are no errors, it prints nothing. If there are errors, you see something like:

```
hello.sb:12:3: error [UNDEFINED_TYPE]: unknown type 'Count'
```

Fix the error, then run.

---

## What You Built

A three-scene interactive fiction with:
- A bounded integer state variable
- Narration that displays the current state
- Multiple scenes with goto navigation
- A state mutation from a choice

---

## Next Steps

**[Tutorial 2: State and Choices](02_state_and_choices.md)** — add guarded choices, enums, and conditional narration.

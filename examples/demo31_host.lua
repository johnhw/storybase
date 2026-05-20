-- examples/demo31_host.lua
--
-- Companion piece: demos/demo31_embedded_host.sb
--
-- This is the §I6 acceptance demo: a Lua host that drives a StoryBase
-- game *without* using the storybase CLI. Every interesting hook on the
-- public lib/storybase.lua surface is exercised:
--
--   1.  sb.load + game:init + game:current_scene
--   2.  game:on("<engine/emit event>", handler) for every event the .sb file
--       declares — door-opened, signal-sent, ship-spotted, ship-saved,
--       storm-began, night-ended.
--   3.  game:on("mutation"|"choice"|"scene-change", ...) — the built-in
--       lifecycle channels.
--   4.  Driver loop:  game:render() → distinguish dialogue objects
--       (type(line) == "table") from plain narration strings, render
--       each, then dispatch via game:choose(n). The choice index is
--       resolved by substring with game:pick() to keep the driver
--       script deterministic.
--   5.  game:call(...) to invoke transaction fns directly (so the host
--       can mix scripted side-effects with the scene flow).
--   6.  game:tick() to fan out the scheduler — fires the `storm-began
--       event from the schedule body.
--   7.  game:save(path) + sb.load + game:load(path) round-trip, with
--       state checked on both sides of the trip.
--
-- Run from the repo root:
--    lua5.4 examples/demo31_host.lua
--
-- Acceptance: the script runs to completion (exit 0), every emitted
-- event lands in a registered handler, and the printed transcript shows
-- speaker attribution (display name + color) on every say line.

package.path = "./?.lua;" .. package.path

local sb = require("lib.storybase")

-- ── 0. Tally helpers ────────────────────────────────────────────────────────
--
-- Every event handler increments a counter so we can assert at the end
-- that the host saw what the .sb file actually emitted.

local seen = {}
local function record(event_name)
  seen[event_name] = (seen[event_name] or 0) + 1
end

local function indent(s)         return "    " .. s end
local function rule(title)       print("\n── " .. title .. " " .. string.rep("─", math.max(0, 60 - #title))) end

-- Pretty-print a value (numbers, strings, booleans, simple tables).
local function pp(v)
  local t = type(v)
  if t == "table" then
    local parts = {}
    for k, vv in pairs(v) do parts[#parts+1] = tostring(k) .. "=" .. pp(vv) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(v)
end

-- ── 1. Load and initialise ──────────────────────────────────────────────────

rule("1. Load and initialise")

local game, err = sb.load("demos/demo31_embedded_host.sb")
if not game then
  io.stderr:write("ERROR loading game: " .. tostring(err) .. "\n")
  os.exit(1)
end
game:init()

print(indent("Loaded:        demos/demo31_embedded_host.sb"))
print(indent("Entry scene:   " .. tostring(game:current_scene())))
print(indent("Day at start:  " .. tostring(game:get("world/day"))))
print(indent("Fuel at start: " .. tostring(game:get("relay/fuel"))))

-- ── 2. Subscribe to every engine/emit event ─────────────────────────────────

rule("2. Subscribe to engine/emit events")

-- Every event handler is intentionally separate so the printed
-- transcript shows speaker attribution + payload destructuring per kind.

game:on("door-opened", function(e)
  record("door-opened")
  print(indent(string.format("[event] door-opened — hour=%s day=%s",
    pp(e.payload.hour), pp(e.payload.day))))
end)

game:on("signal-sent", function(e)
  record("signal-sent")
  print(indent(string.format("[event] signal-sent — ship=%s strength=%s fuel-after=%s",
    pp(e.payload.ship), pp(e.payload.strength), pp(e.payload["fuel-after"]))))
end)

game:on("ship-spotted", function(e)
  record("ship-spotted")
  print(indent(string.format("[event] ship-spotted — name=%s distance-nm=%s weather=%s",
    pp(e.payload.name), pp(e.payload["distance-nm"]), pp(e.payload.weather))))
end)

game:on("ship-saved", function(e)
  record("ship-saved")
  print(indent(string.format("[event] ship-saved — name=%s ships-saved-after=%s",
    pp(e.payload.name), pp(e.payload["ships-saved-after"]))))
end)

game:on("storm-began", function(e)
  record("storm-began")
  print(indent(string.format("[event] storm-began — day=%s severity=%s",
    pp(e.payload.day), pp(e.payload.severity))))
end)

game:on("night-ended", function(e)
  record("night-ended")
  print(indent(string.format("[event] night-ended — next-day=%s",
    pp(e.payload["next-day"]))))
end)

-- ── 3. Lifecycle channels — built-in events ─────────────────────────────────

local mutation_count = 0
game:on("mutation", function(_) mutation_count = mutation_count + 1 end)
game:on("choice", function(e)
  print(indent(string.format("[choice] %d in scene '%s'", e.index, e.scene)))
end)

print(indent("Subscribed: door-opened signal-sent ship-spotted ship-saved storm-began night-ended"))
print(indent("Also:       mutation choice"))

-- ── 4. Render helper that distinguishes dialogue from narration ─────────────
--
-- Every narration item is a Lua table tagged with `kind`:
--   { kind = "narration", text = "..." }                                   -- plain scene text
--   { kind = "say",       speaker, display, color, text = "..." }          -- attributed dialogue
-- Hosts dispatch on item.kind. See docs/reference/language.md §Dialogue.

local function render_narration(narr)
  for _, item in ipairs(narr) do
    if item.kind == "say" then
      local label = item.display or item.speaker or "?"
      local color = item.color  and (" (" .. item.color .. ")") or ""
      print(indent("  " .. label .. color .. ": " .. tostring(item.text or "")))
    else
      -- item.kind == "narration"
      print(indent("  " .. tostring(item.text or "")))
    end
  end
end

-- ── 5. Drive a few choices ──────────────────────────────────────────────────
--
-- We use game:pick(substr) (label substring match) so the script does
-- not depend on choice ordering or guard visibility.

rule("3. Driver loop")

local function show_scene()
  local narr, choices = game:render()
  print(indent("(scene: " .. tostring(game:current_scene()) .. ")"))
  render_narration(narr)
  for _, c in ipairs(choices) do print(indent("  [" .. c.index .. "] " .. c.label)) end
  return choices
end

local function pick(substr)
  print(indent("> pick: " .. substr))
  local ok = game:pick(substr)
  assert(ok, "no choice matched '" .. substr .. "'")
end

show_scene()         -- dawn (door closed)
pick("Open")         -- triggers door-opened emit
show_scene()         -- dawn (door open)
pick("Nightingale")  -- triggers signal-sent + ship-spotted; advances to sighting
show_scene()         -- sighting
pick("Guide")        -- triggers ship-saved; returns to dawn
show_scene()         -- dawn

pick("Albatross")    -- signal #2
pick("Guide")        -- save #2
pick("Nightingale")  -- signal #3 — should unlock Rest
pick("Guide")
show_scene()         -- dawn — Rest is now visible

-- ── 6. Direct fn calls + tick the scheduler ────────────────────────────────
--
-- Show that the host can mix game:call() side-effects between scene
-- rendering and player choices.

rule("4. game:call + game:tick")

print(indent("Bright-tuning the lamp via game:call('brighten')"))
game:call("brighten")
print(indent("relay/strength = " .. tostring(game:get("relay/strength"))))

print(indent("Resting (advances time-axis 'day' by 1)"))
game:call("rest")
print(indent("world/day = " .. tostring(game:get("world/day"))))

-- The storm-watch schedule's `at: [day: +1]` is now due. game:tick()
-- runs the scheduler and fires the storm-began event.
print(indent("Ticking the scheduler"))
game:tick()
print(indent("world/weather = " .. tostring(game:get("world/weather"))))

-- ── 7. Save / load round-trip ──────────────────────────────────────────────

rule("5. Save / load round-trip")

local save_path = os.tmpname() .. ".sbd"
local ok, save_err = game:save(save_path)
assert(ok, "save failed: " .. tostring(save_err))
print(indent("Saved to: " .. save_path))

local snapshot = {
  day          = game:get("world/day"),
  weather      = game:get("world/weather"),
  fuel         = game:get("relay/fuel"),
  ships_saved  = game:get("relay/ships-saved"),
  signals_sent = game:get("relay/signals-sent"),
  scene        = game:current_scene(),
}
print(indent("Snapshot: " .. pp(snapshot)))

-- Fresh game; load the save into it; verify state matches.
local game2, err2 = sb.load("demos/demo31_embedded_host.sb")
assert(game2, err2)
game2:init()

-- Wire the same handlers (just enough to prove they re-attach cleanly).
local restored_emits = 0
for _, name in ipairs({"door-opened", "signal-sent", "ship-spotted",
                       "ship-saved", "storm-began", "night-ended"}) do
  game2:on(name, function() restored_emits = restored_emits + 1 end)
end

local ok2, load_err = game2:load(save_path)
assert(ok2, "load failed: " .. tostring(load_err))

for k, v in pairs(snapshot) do
  local got
  if k == "day"          then got = game2:get("world/day")
  elseif k == "weather"  then got = game2:get("world/weather")
  elseif k == "fuel"     then got = game2:get("relay/fuel")
  elseif k == "ships_saved"  then got = game2:get("relay/ships-saved")
  elseif k == "signals_sent" then got = game2:get("relay/signals-sent")
  elseif k == "scene"    then got = game2:current_scene()
  end
  assert(got == v, string.format("round-trip mismatch on %s: %s != %s",
    k, tostring(got), tostring(v)))
end
print(indent("Round-trip OK: every snapshot field matches after reload"))

os.remove(save_path)

-- ── 8. Acceptance check + summary ──────────────────────────────────────────

rule("6. Acceptance check")

-- The §I6 contract requires every engine/emit call to land in a
-- registered handler. The .sb file emits six event kinds; we expect
-- each to have fired at least once during the driver loop above.
local expected = {
  "door-opened", "signal-sent", "ship-spotted",
  "ship-saved",  "night-ended", "storm-began",
}
local missing = {}
for _, name in ipairs(expected) do
  if (seen[name] or 0) == 0 then missing[#missing+1] = name end
end

print(indent("Mutations observed: " .. mutation_count))
for _, name in ipairs(expected) do
  print(indent(string.format("  %-14s fired %d time(s)", name, seen[name] or 0)))
end

assert(#missing == 0, "Missing emit handlers: " .. table.concat(missing, ", "))

print("\n== demo31 embedded-host walkthrough complete ==")

-- examples/bounded_lua_interop.lua
--
-- Comprehensive demonstration of the StoryBase Lua embedding API.
-- Run from the repo root:
--   lua5.4 examples/bounded_lua_interop.lua
--
-- Covers:
--   - sb.load / game:init
--   - game:register_bounded (assess-reputation handler)
--   - game:on("mutation", ...) event subscription
--   - game:call, game:get, game:set
--   - game:find with a Lua predicate
--   - UList(String) ledger — push!, ulist-size, ulist-get builtins
--   - game:eval pure expression strings
--   - game:counterfactual branching
--   - game:save / game:load round-trip
--   - game:docs

package.path = "./?.lua;" .. package.path

local sb = require("lib.storybase")

-- ── 1. Load and initialise ────────────────────────────────────────────────────

print("=== 1. Load and initialise ===")

local game, err = sb.load("examples/bounded_interop_game.sb")
if not game then
  io.stderr:write("ERROR loading game: " .. tostring(err) .. "\n")
  os.exit(1)
end
game:init()

print("Loaded game.  Entry scene: " .. game:current_scene())
print("Initial gold:      " .. tostring(game:get("merchant/gold")))
print("Initial contracts: " .. tostring(game:get("merchant/contracts")))

-- ── 2. Spawn some couriers ────────────────────────────────────────────────────

print("\n=== 2. Spawn couriers ===")

-- game:call calls a mutation/pure fn by name with Lua-value args
game._eng._state:spawn("couriers", "swift-anna", {
  name = "Swift Anna", kind = "foot-runner",  fee = 50,  reputation = "unknown", hired = false
})
game._eng._state:spawn("couriers", "iron-bart", {
  name = "Iron Bart",  kind = "horse-rider", fee = 120, reputation = "unknown", hired = false
})
game._eng._state:spawn("couriers", "captain-mo", {
  name = "Captain Mo", kind = "ship-captain", fee = 250, reputation = "unknown", hired = false
})

print("Couriers spawned: " .. table.concat(game:find("couriers"), ", "))

-- ── 3. Register a bounded computation handler ─────────────────────────────────

print("\n=== 3. Register bounded handler 'game.reputation.assess' ===")

-- The handler receives (arg, state_snapshot).
--   arg            = the courier key (as a string, e.g. "swift-anna")
--   state_snapshot = read-only table of the "reads:" paths declared in the .sb file
--
-- Returns one of: "unknown" | "poor" | "fair" | "good" | "excellent"
game:register_bounded("game.reputation.assess", function(courier_key, state)
  -- state["world/weather"] is resolved; interpolated paths ({courier}) must be
  -- built from courier_key because the reads: snapshot uses raw pattern strings.
  local eng_state = game._eng._state
  local kind    = eng_state:get("couriers/" .. courier_key .. "/kind")  or "foot-runner"
  local weather = state["world/weather"]                                 or 5
  local hired   = eng_state:get("couriers/" .. courier_key .. "/hired") or false

  -- Simple scoring: kind bonus + weather modifier
  local score = 0
  if kind == "ship-captain"  then score = score + 3 end
  if kind == "horse-rider"   then score = score + 2 end
  if kind == "foot-runner"   then score = score + 1 end
  if weather >= 8            then score = score + 2 end   -- good weather
  if weather <= 2            then score = score - 2 end   -- storm
  if hired                   then score = score + 1 end   -- proven track record

  if     score >= 5 then return "excellent"
  elseif score >= 4 then return "good"
  elseif score >= 3 then return "fair"
  elseif score >= 1 then return "poor"
  else                   return "unknown"
  end
end)

print("Handler registered.")

-- ── 4. Subscribe to mutation events ──────────────────────────────────────────

print("\n=== 4. Subscribe to mutation events ===")

local mutation_log = {}
game:on("mutation", function(ev)
  mutation_log[#mutation_log + 1] = string.format("  [mut] %s: %s → %s",
    ev.path, tostring(ev.old), tostring(ev.new))
end)

-- ── 5. Rate all couriers (triggers bounded computation) ───────────────────────

print("\n=== 5. Rate couriers via bounded computation ===")

game:call("rate-courier", "'swift-anna")
game:call("rate-courier", "'iron-bart")
game:call("rate-courier", "'captain-mo")

print("Reputations after rating:")
for _, key in ipairs(game:find("couriers")) do
  print(string.format("  %-15s → %s", key, tostring(game:get("couriers/" .. key .. "/reputation"))))
end

print("Mutations during rating:")
for _, m in ipairs(mutation_log) do print(m) end

-- ── 6. Hire a courier and complete a contract ─────────────────────────────────

print("\n=== 6. Hire Swift Anna + complete contract ===")

mutation_log = {}

game:call("hire-courier", "'swift-anna")
print("Hired Anna.  Gold now: " .. tostring(game:get("merchant/gold")))

game:call("complete-contract", "'swift-anna")
print("Completed contract.  Gold now: " .. tostring(game:get("merchant/gold")))
print("Contracts completed: " .. tostring(game:get("merchant/contracts")))

-- ── 7. UList ledger operations ────────────────────────────────────────────────

print("\n=== 7. UList ledger ===")

local ledger_size, ledger_err = game:eval("ulist-size merchant/ledger")
print("Ledger size: " .. tostring(ledger_size) .. " (err=" .. tostring(ledger_err) .. ")")

-- Read first and last entry
local first, _ = game:eval("ulist-first merchant/ledger")
local last,  _ = game:eval("ulist-last  merchant/ledger")
print("First entry: " .. tostring(first))
print("Last entry:  " .. tostring(last))

-- Pure functional ops: filter entries containing "gold"
local filtered, _ = game:eval([[ulist-filter merchant/ledger fn(s): ulist-contains? (ulist-slice (str s) 1 4) "gold"]])
-- (In a real game you'd use str-contains, but ulist ops work on any UList(T))

-- Simpler: check via Lua directly
local ledger_raw = game:get("merchant/ledger")
local gold_entries = {}
for _, e in ipairs(ledger_raw or {}) do
  if tostring(e):find("gold") then gold_entries[#gold_entries + 1] = e end
end
print("Entries mentioning 'gold': " .. #gold_entries)
for _, e in ipairs(gold_entries) do print("  " .. e) end

-- ulist-append pure (does not mutate state)
local appended, _ = game:eval([[ulist-append merchant/ledger "synthetic-entry"]])
print("After ulist-append (pure), original size unchanged: " ..
  tostring(game:eval("ulist-size merchant/ledger")) ..
  ", new list size: " .. tostring(#appended))

-- ── 8. game:eval for complex pure expressions ─────────────────────────────────

print("\n=== 8. game:eval expressions ===")

local can_hire_mo, _ = game:eval("can-hire? 'captain-mo")
print("can-hire? captain-mo: " .. tostring(can_hire_mo))

local hired_count, _ = game:eval("hired-count")
print("hired-count: " .. tostring(hired_count))

local summary, _ = game:eval("ledger-summary")
print("ledger-summary: " .. tostring(summary))

-- ── 9. game:find with Lua predicate ──────────────────────────────────────────

print("\n=== 9. game:find with predicate ===")

local state = game._eng._state
local affordable = game:find("couriers", {
  where = function(key)
    local fee  = state:get("couriers/" .. key .. "/fee")  or 9999
    local gold = state:get("merchant/gold")               or 0
    return gold >= fee
  end,
  order_by  = "couriers/{key}/fee",
  order_dir = "asc",
})
print("Affordable couriers (ascending by fee):")
for _, key in ipairs(affordable) do
  print(string.format("  %-15s fee=%s  rep=%s",
    key,
    tostring(state:get("couriers/" .. key .. "/fee")),
    tostring(state:get("couriers/" .. key .. "/reputation"))))
end

-- ── 10. UMap operations ───────────────────────────────────────────────────────

print("\n=== 10. UMap operations ===")

-- Create a transient UMap via eval (pure ops, no state mutation)
-- Here we build a summary map: courier name → reputation
local function build_rep_map(g)
  local result = {}
  for _, key in ipairs(g:find("couriers")) do
    local rep = g:get("couriers/" .. key .. "/reputation")
    result[key] = rep
  end
  return result
end

local rep_map = build_rep_map(game)
print("Reputation map (built in Lua):")
for k, v in pairs(rep_map) do
  print(string.format("  %-15s → %s", k, v))
end

-- game:eval using map builtins on a state UMap path
-- (merchant/ledger is a UList, not UMap, but we can test UMap ops via eval
--  on a meta UMap if present; here we just show the builtins work)
local meta_src = [[
module meta-demo
  version: 1.0
engine-config:
  entry-scene: main
state store:
  kv: UMap(String, Int(0, 999)) = {}
scene main:
  * noop -> main
fn set-kv k v:
  map-set! store/kv k v
fn del-kv k:
  map-delete! store/kv k
]]
local meta_game, merr = sb.from_source(meta_src, "meta-demo")
assert(not merr, merr)
meta_game:init()
meta_game:call("set-kv", "alpha", 10)
meta_game:call("set-kv", "beta", 20)
meta_game:call("set-kv", "gamma", 30)

local sz, _      = meta_game:eval("map-size store/kv")
local keys, _    = meta_game:eval("map-keys store/kv")
local vals, _    = meta_game:eval("map-values store/kv")
local has, _     = meta_game:eval([[map-contains-key? store/kv "beta"]])
local merged, _  = meta_game:eval([[map-merge store/kv (map-set store/kv "delta" 40)]])
local deleted, _ = meta_game:eval([[map-delete store/kv "alpha"]])

print("map-size:          " .. tostring(sz))
print("map-keys:          " .. table.concat(keys, ", "))
print("map-values count:  " .. tostring(#vals))
print("map-contains-key? beta: " .. tostring(has))
print("map-merge added delta:   " .. tostring(merged["delta"]))
print("map-delete removed alpha: " .. tostring(deleted["alpha"] == nil))

meta_game:call("del-kv", "beta")
local sz2, _ = meta_game:eval("map-size store/kv")
print("After map-delete! beta: map-size = " .. tostring(sz2))

-- ── 11. Counterfactual branching ──────────────────────────────────────────────

print("\n=== 11. Counterfactual branching ===")

local gold_before = game:get("merchant/gold")
print("Gold before counterfactual: " .. tostring(gold_before))

-- Branch: what would happen if we hired Captain Mo and completed a contract?
local snapshot = game:counterfactual(function(branch)
  -- Captain Mo fee is 250; we need enough gold
  branch:call("hire-courier", "'captain-mo")
  branch:call("complete-contract", "'captain-mo")
end)

local gold_in_branch    = snapshot:get("merchant/gold")
local contracts_in_branch = snapshot:get("merchant/contracts")
print("Gold in counterfactual:      " .. tostring(gold_in_branch))
print("Contracts in counterfactual: " .. tostring(contracts_in_branch))
print("Live gold unchanged:         " .. tostring(game:get("merchant/gold")))

-- ── 12. Advance season and observe UList growth ───────────────────────────────

print("\n=== 12. Advance season + UList growth ===")

local size_before, _ = game:eval("ulist-size merchant/ledger")
game:call("advance-season")
game:call("advance-season")
local size_after, _ = game:eval("ulist-size merchant/ledger")
print(string.format("Ledger grew from %d to %d entries after 2 season advances.",
  size_before, size_after))

-- The last two entries should be the ledger-summary strings
local last2, _ = game:eval("ulist-slice merchant/ledger (ulist-size merchant/ledger - 1) (ulist-size merchant/ledger)")
print("Last 2 ledger entries:")
if type(last2) == "table" then
  for _, e in ipairs(last2) do print("  " .. tostring(e)) end
end

-- ── 13. Save / load round-trip ────────────────────────────────────────────────

print("\n=== 13. Save / load round-trip ===")

local save_path = os.tmpname() .. ".sbd"
local ok, save_err = game:save(save_path)
print("Save: " .. tostring(ok) .. " (err=" .. tostring(save_err) .. ")")

local game2, err2 = sb.load("examples/bounded_interop_game.sb")
assert(not err2, err2)
game2:init()
-- Re-spawn couriers in the fresh instance (save/load restores state)
local ok2, load_err = game2:load(save_path)
print("Load: " .. tostring(ok2) .. " (err=" .. tostring(load_err) .. ")")

local gold_restored = game2:get("merchant/gold")
local ledger_size2, _ = game2:eval("ulist-size merchant/ledger")
print("Restored gold:        " .. tostring(gold_restored))
print("Restored ledger size: " .. tostring(ledger_size2))
assert(gold_restored == game:get("merchant/gold"),
  "Gold mismatch after load!")
print("Round-trip OK: gold matches.")

os.remove(save_path)

-- ── 14. Doc strings ───────────────────────────────────────────────────────────

print("\n=== 14. Doc strings ===")

local all_docs = game:docs()
if type(all_docs) == "table" then
  local count = 0
  for _ in pairs(all_docs) do count = count + 1 end
  print("Doc strings present: " .. count)
  -- Print the one for assess-reputation
  local rep_doc = game:docs("assess-reputation")
  if rep_doc then
    print("assess-reputation doc: " .. rep_doc)
  end
end

print("\n=== Done ===")

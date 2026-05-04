-- tests/runtime/ulist_spec.lua
-- Comprehensive tests for UList(T) runtime support and UMap completeness.
-- Run with: busted tests/

local sb = require("lib.storybase")

-- ── Shared source fixture ─────────────────────────────────────────────────────

local SRC = [[
module ulist-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  notes: UList(String)  = []
  tags:  UList(Int(0, 9999)) = []
  log:   UList(String)  = []

state meta:
  labels: UMap(String, String) = {}
  counts: UMap(String, Int(0, 9999)) = {}

scene main:
  * Push note
    push! world/notes "hello"
    -> main
  * Push two notes
    push! world/notes "alpha"
    push! world/notes "beta"
    -> main
  * Clear notes
    clear! world/notes
    -> main
  * Pop note
    pop! world/notes
    -> main
  * Set index
    set! world/notes[1] "updated"
    -> main
  * Map label
    map-set! meta/labels "key" "value"
    -> main
  * Delete label
    map-delete! meta/labels "key"
    -> main

fn add-note text:
  push! world/notes text

fn add-tag n:
  push! world/tags n

fn clear-notes:
  clear! world/notes

fn pop-note:
  pop! world/notes

fn set-count key val:
  map-set! meta/counts key val

fn del-count key:
  map-delete! meta/counts key
]]

local function make()
  local g, err = sb.from_source(SRC, "ulist-test")
  assert.is_nil(err, tostring(err))
  g:init()
  return g
end

-- ── UList state initialisation ───────────────────────────────────────────────

describe("UList state", function()
  it("initialises to empty list", function()
    local g = make()
    local notes = g:get("world/notes")
    assert.is_table(notes)
    assert.equal(0, #notes)
  end)

  it("push! appends elements without capacity limit", function()
    local g = make()
    for i = 1, 20 do g:call("add-note", tostring(i)) end
    local notes = g:get("world/notes")
    assert.equal(20, #notes)
    assert.equal("1",  notes[1])
    assert.equal("20", notes[20])
  end)

  it("pop! removes the last element", function()
    local g = make()
    g:call("add-note", "a")
    g:call("add-note", "b")
    g:call("add-note", "c")
    g:call("pop-note")
    local notes = g:get("world/notes")
    assert.equal(2, #notes)
    assert.equal("b", notes[2])
  end)

  it("clear! empties the list", function()
    local g = make()
    g:call("add-note", "x")
    g:call("add-note", "y")
    g:call("clear-notes")
    local notes = g:get("world/notes")
    assert.equal(0, #notes)
  end)

  it("set![idx] updates an element", function()
    local g = make()
    g:call("add-note", "original")
    g:choose(5)  -- Set index → sets notes[1] = "updated"
    local notes = g:get("world/notes")
    assert.equal("updated", notes[1])
  end)
end)

-- ── ulist-size ───────────────────────────────────────────────────────────────

describe("ulist-size", function()
  it("returns 0 for empty list", function()
    local g = make()
    local n, err = g:eval("ulist-size world/notes")
    assert.is_nil(err)
    assert.equal(0, n)
  end)

  it("returns correct count after pushes", function()
    local g = make()
    g:call("add-note", "a")
    g:call("add-note", "b")
    local n, err = g:eval("ulist-size world/notes")
    assert.is_nil(err)
    assert.equal(2, n)
  end)
end)

-- ── ulist-get ────────────────────────────────────────────────────────────────

describe("ulist-get", function()
  it("retrieves element by 1-based index", function()
    local g = make()
    g:call("add-note", "first")
    g:call("add-note", "second")
    local v, err = g:eval("ulist-get world/notes 1")
    assert.is_nil(err)
    assert.equal("first", v)
    local v2, err2 = g:eval("ulist-get world/notes 2")
    assert.is_nil(err2)
    assert.equal("second", v2)
  end)

  it("returns nil for out-of-bounds index", function()
    local g = make()
    g:call("add-note", "only")
    local v, err = g:eval("ulist-get world/notes 5")
    assert.is_nil(err)
    assert.is_nil(v)
  end)

  it("supports negative indexing (-1 = last)", function()
    local g = make()
    g:call("add-note", "x")
    g:call("add-note", "y")
    g:call("add-note", "z")
    -- Use (0 - 1) since SB atoms don't allow bare negative integer literals
    local v, err = g:eval("ulist-get world/notes (0 - 1)")
    assert.is_nil(err)
    assert.equal("z", v)
  end)
end)

-- ── ulist-first / ulist-last ──────────────────────────────────────────────

describe("ulist-first and ulist-last", function()
  it("ulist-first returns first element", function()
    local g = make()
    g:call("add-note", "alpha")
    g:call("add-note", "beta")
    local v, err = g:eval("ulist-first world/notes")
    assert.is_nil(err)
    assert.equal("alpha", v)
  end)

  it("ulist-last returns last element", function()
    local g = make()
    g:call("add-note", "alpha")
    g:call("add-note", "beta")
    local v, err = g:eval("ulist-last world/notes")
    assert.is_nil(err)
    assert.equal("beta", v)
  end)

  it("ulist-first returns nil for empty list", function()
    local g = make()
    local v, err = g:eval("ulist-first world/notes")
    assert.is_nil(err)
    assert.is_nil(v)
  end)

  it("ulist-last returns nil for empty list", function()
    local g = make()
    local v, err = g:eval("ulist-last world/notes")
    assert.is_nil(err)
    assert.is_nil(v)
  end)
end)

-- ── ulist-index-of ───────────────────────────────────────────────────────────

describe("ulist-index-of", function()
  it("returns 1-based index of first occurrence", function()
    local g = make()
    g:call("add-tag", 10)
    g:call("add-tag", 20)
    g:call("add-tag", 30)
    local v, err = g:eval("ulist-index-of world/tags 20")
    assert.is_nil(err)
    assert.equal(2, v)
  end)

  it("returns nil when value not found", function()
    local g = make()
    g:call("add-tag", 5)
    local v, err = g:eval("ulist-index-of world/tags 99")
    assert.is_nil(err)
    assert.is_nil(v)
  end)

  it("returns index of first occurrence when value appears multiple times", function()
    local g = make()
    g:call("add-tag", 7)
    g:call("add-tag", 7)
    g:call("add-tag", 7)
    local v, err = g:eval("ulist-index-of world/tags 7")
    assert.is_nil(err)
    assert.equal(1, v)
  end)
end)

-- ── ulist-contains? ──────────────────────────────────────────────────────────

describe("ulist-contains?", function()
  it("returns true when value present", function()
    local g = make()
    g:call("add-tag", 42)
    local v, err = g:eval("ulist-contains? world/tags 42")
    assert.is_nil(err)
    assert.is_true(v)
  end)

  it("returns false when value absent", function()
    local g = make()
    g:call("add-tag", 1)
    local v, err = g:eval("ulist-contains? world/tags 99")
    assert.is_nil(err)
    assert.is_false(v)
  end)

  it("returns false for empty list", function()
    local g = make()
    local v, err = g:eval("ulist-contains? world/tags 0")
    assert.is_nil(err)
    assert.is_false(v)
  end)
end)

-- ── ulist-append / ulist-prepend ─────────────────────────────────────────────

describe("ulist-append and ulist-prepend", function()
  it("ulist-append returns new list with value at end", function()
    local g = make()
    g:call("add-note", "a")
    g:call("add-note", "b")
    -- eval the append pure expression; does not mutate world/notes
    local result, err = g:eval([[ulist-append world/notes "c"]])
    assert.is_nil(err)
    assert.equal(3, #result)
    assert.equal("c", result[3])
    -- original state unchanged
    assert.equal(2, #g:get("world/notes"))
  end)

  it("ulist-prepend returns new list with value at front", function()
    local g = make()
    g:call("add-note", "b")
    g:call("add-note", "c")
    local result, err = g:eval([[ulist-prepend world/notes "a"]])
    assert.is_nil(err)
    assert.equal(3, #result)
    assert.equal("a", result[1])
    assert.equal("b", result[2])
    assert.equal("c", result[3])
    -- original state unchanged
    assert.equal(2, #g:get("world/notes"))
  end)

  it("ulist-append on empty list returns singleton", function()
    local g = make()
    local result, err = g:eval([[ulist-append world/notes "only"]])
    assert.is_nil(err)
    assert.equal(1, #result)
    assert.equal("only", result[1])
  end)
end)

-- ── ulist-remove-at / ulist-remove ───────────────────────────────────────────

describe("ulist-remove-at and ulist-remove", function()
  it("ulist-remove-at removes element at given 1-based index", function()
    local g = make()
    g:call("add-tag", 10)
    g:call("add-tag", 20)
    g:call("add-tag", 30)
    local result, err = g:eval("ulist-remove-at world/tags 2")
    assert.is_nil(err)
    assert.equal(2, #result)
    assert.equal(10, result[1])
    assert.equal(30, result[2])
  end)

  it("ulist-remove-at with negative index removes from end", function()
    local g = make()
    g:call("add-tag", 1)
    g:call("add-tag", 2)
    g:call("add-tag", 3)
    local result, err = g:eval("ulist-remove-at world/tags (0 - 1)")
    assert.is_nil(err)
    assert.equal(2, #result)
    assert.equal(2, result[2])
  end)

  it("ulist-remove removes first occurrence of value", function()
    local g = make()
    g:call("add-tag", 5)
    g:call("add-tag", 10)
    g:call("add-tag", 5)
    local result, err = g:eval("ulist-remove world/tags 5")
    assert.is_nil(err)
    assert.equal(2, #result)
    assert.equal(10, result[1])
    assert.equal(5,  result[2])
  end)

  it("ulist-remove is no-op when value not present", function()
    local g = make()
    g:call("add-tag", 7)
    g:call("add-tag", 8)
    local result, err = g:eval("ulist-remove world/tags 99")
    assert.is_nil(err)
    assert.equal(2, #result)
  end)

  it("ulist-remove does not mutate original state", function()
    local g = make()
    g:call("add-tag", 1)
    g:call("add-tag", 2)
    g:eval("ulist-remove world/tags 1")  -- pure; no side effect
    assert.equal(2, #g:get("world/tags"))
  end)
end)

-- ── ulist-concat ─────────────────────────────────────────────────────────────

describe("ulist-concat", function()
  it("concatenates two lists", function()
    local g = make()
    g:call("add-tag", 1)
    g:call("add-tag", 2)
    -- world/log is a second empty UList
    local result, err = g:eval("ulist-concat world/tags world/log")
    assert.is_nil(err)
    -- world/log is empty so result equals world/tags
    assert.equal(2, #result)
    assert.equal(1, result[1])
    assert.equal(2, result[2])
  end)

  it("result length equals sum of lengths", function()
    local g = make()
    for i = 1, 3 do g:call("add-tag", i) end
    for i = 1, 3 do g:call("add-note", "n" .. i) end
    -- concat tags (Int list) with itself
    local r1, _ = g:eval("ulist-concat world/tags world/tags")
    assert.equal(6, #r1)
  end)
end)

-- ── ulist-slice ──────────────────────────────────────────────────────────────

describe("ulist-slice", function()
  it("returns sub-list between from and to (1-based inclusive)", function()
    local g = make()
    for i = 1, 5 do g:call("add-tag", i * 10) end
    local result, err = g:eval("ulist-slice world/tags 2 4")
    assert.is_nil(err)
    assert.equal(3, #result)
    assert.equal(20, result[1])
    assert.equal(30, result[2])
    assert.equal(40, result[3])
  end)

  it("clamps gracefully when to > length", function()
    local g = make()
    g:call("add-tag", 1)
    g:call("add-tag", 2)
    local result, err = g:eval("ulist-slice world/tags 1 100")
    assert.is_nil(err)
    assert.equal(2, #result)
  end)
end)

-- ── ulist-reverse ────────────────────────────────────────────────────────────

describe("ulist-reverse", function()
  it("returns a reversed copy", function()
    local g = make()
    g:call("add-tag", 1)
    g:call("add-tag", 2)
    g:call("add-tag", 3)
    local result, err = g:eval("ulist-reverse world/tags")
    assert.is_nil(err)
    assert.equal(3, result[1])
    assert.equal(2, result[2])
    assert.equal(1, result[3])
  end)

  it("does not mutate original", function()
    local g = make()
    g:call("add-tag", 9)
    g:call("add-tag", 8)
    g:eval("ulist-reverse world/tags")
    local tags = g:get("world/tags")
    assert.equal(9, tags[1])  -- original order preserved
  end)

  it("returns empty list for empty input", function()
    local g = make()
    local result, err = g:eval("ulist-reverse world/tags")
    assert.is_nil(err)
    assert.equal(0, #result)
  end)
end)

-- ── ulist-map / ulist-filter ─────────────────────────────────────────────────

describe("ulist-map and ulist-filter", function()
  local MAP_SRC = [[
module ulist-lambda-test
  version: 1.0
engine-config:
  entry-scene: main

state world:
  nums: UList(Int(0, 9999)) = []

scene main:
  * noop -> main

fn add-num n:
  push! world/nums n
]]

  local function make2()
    local g, err = sb.from_source(MAP_SRC, "ulist-lambda-test")
    assert.is_nil(err, tostring(err))
    g:init()
    return g
  end

  it("ulist-map applies lambda to each element", function()
    local g = make2()
    g:call("add-num", 1)
    g:call("add-num", 2)
    g:call("add-num", 3)
    -- double each element
    local result, err = g:eval("ulist-map world/nums fn(x): x * 2")
    assert.is_nil(err, tostring(err))
    assert.equal(3, #result)
    assert.equal(2,  result[1])
    assert.equal(4,  result[2])
    assert.equal(6,  result[3])
  end)

  it("ulist-filter keeps only matching elements", function()
    local g = make2()
    for i = 1, 5 do g:call("add-num", i) end
    local result, err = g:eval("ulist-filter world/nums fn(x): x > 2")
    assert.is_nil(err, tostring(err))
    assert.equal(3, #result)
    assert.equal(3, result[1])
    assert.equal(4, result[2])
    assert.equal(5, result[3])
  end)

  it("ulist-filter on empty list returns empty", function()
    local g = make2()
    local result, err = g:eval("ulist-filter world/nums fn(x): x > 0")
    assert.is_nil(err, tostring(err))
    assert.equal(0, #result)
  end)

  it("ulist-map on empty list returns empty", function()
    local g = make2()
    local result, err = g:eval("ulist-map world/nums fn(x): x + 1")
    assert.is_nil(err, tostring(err))
    assert.equal(0, #result)
  end)
end)

-- ── UMap completeness ─────────────────────────────────────────────────────────

describe("UMap builtins", function()
  local MAP_SRC2 = [[
module umap-test
  version: 1.0
engine-config:
  entry-scene: main

state store:
  inventory: UMap(String, Int(0, 999)) = {}
  labels:    UMap(String, String)      = {}

scene main:
  * noop -> main

fn set-item key val:
  map-set! store/inventory key val

fn del-item key:
  map-delete! store/inventory key

fn set-label k v:
  map-set! store/labels k v
]]

  local function make3()
    local g, err = sb.from_source(MAP_SRC2, "umap-test")
    assert.is_nil(err, tostring(err))
    g:init()
    return g
  end

  -- existing builtins
  it("map-get retrieves a value by key", function()
    local g = make3()
    g:call("set-item", "sword", 3)
    local v, err = g:eval([[map-get store/inventory "sword"]])
    assert.is_nil(err)
    assert.equal(3, v)
  end)

  it("map-get returns nil for absent key", function()
    local g = make3()
    local v, err = g:eval([[map-get store/inventory "ghost"]])
    assert.is_nil(err)
    assert.is_nil(v)
  end)

  it("map-size returns 0 for empty map", function()
    local g = make3()
    local n, err = g:eval("map-size store/inventory")
    assert.is_nil(err)
    assert.equal(0, n)
  end)

  it("map-size reflects number of entries", function()
    local g = make3()
    g:call("set-item", "a", 1)
    g:call("set-item", "b", 2)
    g:call("set-item", "c", 3)
    local n, err = g:eval("map-size store/inventory")
    assert.is_nil(err)
    assert.equal(3, n)
  end)

  it("map-keys returns all keys as a list", function()
    local g = make3()
    g:call("set-item", "x", 10)
    g:call("set-item", "y", 20)
    local keys, err = g:eval("map-keys store/inventory")
    assert.is_nil(err)
    assert.equal(2, #keys)
    local kset = {}
    for _, k in ipairs(keys) do kset[k] = true end
    assert.is_true(kset["x"])
    assert.is_true(kset["y"])
  end)

  -- new builtins
  it("map-values returns all values as a list", function()
    local g = make3()
    g:call("set-item", "p", 100)
    g:call("set-item", "q", 200)
    local vals, err = g:eval("map-values store/inventory")
    assert.is_nil(err)
    assert.equal(2, #vals)
    local vset = {}
    for _, v in ipairs(vals) do vset[v] = true end
    assert.is_true(vset[100])
    assert.is_true(vset[200])
  end)

  it("map-contains-key? returns true for present key", function()
    local g = make3()
    g:call("set-item", "helmet", 1)
    local v, err = g:eval([[map-contains-key? store/inventory "helmet"]])
    assert.is_nil(err)
    assert.is_true(v)
  end)

  it("map-contains-key? returns false for absent key", function()
    local g = make3()
    local v, err = g:eval([[map-contains-key? store/inventory "nothing"]])
    assert.is_nil(err)
    assert.is_false(v)
  end)

  it("map-merge combines two maps (right wins on conflict)", function()
    local g = make3()
    g:call("set-item", "a", 1)
    g:call("set-item", "b", 2)
    -- merge inventory with itself modified via map-set (pure)
    local merged, err = g:eval([[map-merge store/inventory (map-set store/inventory "b" 99)]])
    assert.is_nil(err)
    local n = 0
    for _ in pairs(merged) do n = n + 1 end
    assert.equal(2, n)
    assert.equal(99, merged["b"])  -- right (second arg) wins on "b"
    assert.equal(1,  merged["a"])
  end)

  it("map-set pure returns new map without mutating state", function()
    local g = make3()
    g:call("set-item", "existing", 5)
    local new_map, err = g:eval([[map-set store/inventory "new-key" 42]])
    assert.is_nil(err)
    assert.equal(42, new_map["new-key"])
    assert.equal(5,  new_map["existing"])
    -- original state still has only "existing"
    local orig = g:get("store/inventory")
    assert.is_nil(orig["new-key"])
  end)

  it("map-delete pure returns new map without mutating state", function()
    local g = make3()
    g:call("set-item", "keep", 10)
    g:call("set-item", "drop", 20)
    local new_map, err = g:eval([[map-delete store/inventory "drop"]])
    assert.is_nil(err)
    assert.is_nil(new_map["drop"])
    assert.equal(10, new_map["keep"])
    -- original state still has "drop"
    local orig = g:get("store/inventory")
    assert.equal(20, orig["drop"])
  end)

  -- mutation primitives
  it("map-set! mutates the map in state", function()
    local g = make3()
    g:call("set-item", "coins", 50)
    g:call("set-item", "coins", 75)  -- overwrite
    assert.equal(75, g:get("store/inventory")["coins"])
  end)

  it("map-delete! removes a key from state", function()
    local g = make3()
    g:call("set-item", "ring", 1)
    g:call("del-item", "ring")
    local inv = g:get("store/inventory")
    assert.is_nil(inv["ring"])
  end)

  -- Regression: UMap save/load round-trip (snapshot serialiser must handle hash tables)
  it("save/load preserves multiple UMap entries across two separate calls", function()
    local g = make3()
    g:call("set-item", "sword", 3)
    local path = os.tmpname() .. ".sbd"
    local ok, e = g:save(path)
    assert.is_true(ok, tostring(e))

    -- Load into fresh instance and add a second item
    local g2, err = require("lib.storybase").from_source(MAP_SRC2, "umap-test")
    assert.is_nil(err)
    g2:init()
    local ok2, e2 = g2:load(path)
    assert.is_true(ok2, tostring(e2))

    -- "sword" must survive the round-trip
    assert.equal(3, g2:get("store/inventory")["sword"])

    -- Adding a second key must not erase the first
    g2:call("set-item", "shield", 2)
    local inv = g2:get("store/inventory")
    assert.equal(3, inv["sword"])
    assert.equal(2, inv["shield"])

    os.remove(path)
  end)

  it("UMap with hyphenated string keys serialises and deserialises correctly", function()
    local g = make3()
    g:call("set-label", "fire-arrow", "fire-arrow")
    g:call("set-label", "ice-bolt", "ice-bolt")
    local path = os.tmpname() .. ".sbd"
    g:save(path)

    local g2, err = require("lib.storybase").from_source(MAP_SRC2, "umap-test")
    assert.is_nil(err); g2:init()
    g2:load(path)
    local labels = g2:get("store/labels")
    assert.equal("fire-arrow", labels["fire-arrow"])
    assert.equal("ice-bolt",   labels["ice-bolt"])
    os.remove(path)
  end)
end)

-- ── UList composition: use in fn body + event observation ────────────────────

describe("UList in game logic", function()
  local GAME_SRC = [[
module ulist-game
  version: 1.0
engine-config:
  entry-scene: hub

state journal:
  entries: UList(String) = []
  tags:    UList(Int(0, 9999)) = []

fn log-entry text:
  push! journal/entries text

fn tag-entry n:
  push! journal/tags n

fn clear-journal:
  clear! journal/entries
  clear! journal/tags

scene hub:
  * Log alpha
    log-entry "alpha"
    tag-entry 1
    -> hub
  * Log beta
    log-entry "beta"
    tag-entry 2
    -> hub
  * Clear
    clear-journal
    -> hub
]]

  local function make_game()
    local g, err = sb.from_source(GAME_SRC, "ulist-game")
    assert.is_nil(err, tostring(err))
    g:init()
    return g
  end

  it("tracks mutations via on(`mutation') event", function()
    local g = make_game()
    local paths_changed = {}
    g:on("mutation", function(ev)
      paths_changed[ev.path] = true
    end)
    g:choose(1)  -- Log alpha
    assert.is_true(paths_changed["journal/entries"])
    assert.is_true(paths_changed["journal/tags"])
  end)

  it("multiple choices append in order", function()
    local g = make_game()
    g:choose(1)  -- Log alpha
    g:choose(2)  -- Log beta
    local entries = g:get("journal/entries")
    assert.equal(2, #entries)
    assert.equal("alpha", entries[1])
    assert.equal("beta",  entries[2])
  end)

  it("clear choice empties both ulists", function()
    local g = make_game()
    g:choose(1)
    g:choose(2)
    g:choose(3)  -- Clear
    assert.equal(0, #g:get("journal/entries"))
    assert.equal(0, #g:get("journal/tags"))
  end)

  it("ulist-map over game state returns transformed values", function()
    local g = make_game()
    g:choose(1)
    g:choose(2)
    local result, err = g:eval("ulist-map journal/tags fn(x): x * 10")
    assert.is_nil(err)
    assert.equal(10, result[1])
    assert.equal(20, result[2])
  end)

  it("ulist-filter over game state keeps matching", function()
    local g = make_game()
    g:choose(1)
    g:choose(2)
    local result, err = g:eval("ulist-filter journal/tags fn(x): x > 1")
    assert.is_nil(err)
    assert.equal(1, #result)
    assert.equal(2, result[1])
  end)

  it("ulist-reverse, ulist-first, ulist-last are consistent", function()
    local g = make_game()
    g:choose(1)
    g:choose(2)
    local first, _  = g:eval("ulist-first journal/entries")
    local last,  _  = g:eval("ulist-last  journal/entries")
    local rev,   _  = g:eval("ulist-reverse journal/entries")
    assert.equal("alpha", first)
    assert.equal("beta",  last)
    assert.equal("beta",  rev[1])
    assert.equal("alpha", rev[2])
  end)

  it("ulist-concat of list with itself doubles it", function()
    local g = make_game()
    g:choose(1)
    g:choose(2)
    local result, err = g:eval("ulist-concat journal/entries journal/entries")
    assert.is_nil(err)
    assert.equal(4, #result)
  end)

  it("save/load round-trip preserves UList state", function()
    local g = make_game()
    g:choose(1)  -- alpha
    g:choose(2)  -- beta
    local path = os.tmpname() .. ".sbd"
    local ok, err2 = g:save(path)
    assert.is_true(ok, tostring(err2))

    local g2, err3 = sb.from_source(GAME_SRC, "ulist-game")
    assert.is_nil(err3)
    g2:init()
    local ok2, err4 = g2:load(path)
    assert.is_true(ok2, tostring(err4))

    local entries = g2:get("journal/entries")
    assert.equal(2,       #entries)
    assert.equal("alpha", entries[1])
    assert.equal("beta",  entries[2])
    os.remove(path)
  end)
end)

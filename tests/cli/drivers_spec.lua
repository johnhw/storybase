-- tests/cli/drivers_spec.lua
-- Unit tests for cli/drivers/plain.lua and cli/drivers/ansi.lua.

local plain_mod = require("cli.drivers.plain")
local ansi_mod  = require("cli.drivers.ansi")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_io(input_lines)
  local out_parts = {}
  local line_idx  = 0
  local out = {
    write = function(_, s) out_parts[#out_parts + 1] = s end,
    flush = function() end,
  }
  local inp = {
    read = function(_, _fmt)
      line_idx = line_idx + 1
      return input_lines[line_idx]
    end,
  }
  local function captured() return table.concat(out_parts) end
  return out, inp, captured
end

local narr_items = {
  { kind = "narration", text = "The cave is dark." },
  { kind = "say",       speaker = "ghost", display = "Ghost", color = "#aabbcc", text = "Boo!" },
  { kind = "narration", text = "" },  -- empty line should be skipped
}

local choices = {
  { index = 1, label = "Run away" },
  { index = 2, label = "Stay put" },
}

-- ── plain driver ──────────────────────────────────────────────────────────────

describe("plain driver: render", function()
  it("prints narration text", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    local text = captured()
    assert.is_truthy(text:find("The cave is dark%."), text)
  end)

  it("formats say items as 'Speaker: text'", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    local text = captured()
    assert.is_truthy(text:find("Ghost: Boo!"), text)
  end)

  it("skips empty narration text", function()
    local out, inp, captured = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    -- rendered output should not have a bare blank line from the empty item
    -- (blank lines from the wrapping \n\n are fine; just no double-blank mid-list)
    local text = captured()
    assert.is_falsy(text:find("\n\n\n"), text)
  end)
end)

describe("plain driver: prompt", function()
  it("prints numbered choices", function()
    local out, inp, captured = make_io({ "1" })
    local d = plain_mod.new({ io_out = out, io_in = inp })
    d:prompt(choices)
    local text = captured()
    assert.is_truthy(text:find("1%. Run away"), text)
    assert.is_truthy(text:find("2%. Stay put"), text)
  end)

  it("returns the chosen index", function()
    local out, inp, _ = make_io({ "2" })
    local d = plain_mod.new({ io_out = out, io_in = inp })
    local idx = d:prompt(choices)
    assert.equal(2, idx)
  end)

  it("returns nil on 'q'", function()
    local out, inp, _ = make_io({ "q" })
    local d = plain_mod.new({ io_out = out, io_in = inp })
    local idx = d:prompt(choices)
    assert.is_nil(idx)
  end)

  it("returns nil on EOF", function()
    local out, inp, _ = make_io({})  -- no lines → nil on read
    local d = plain_mod.new({ io_out = out, io_in = inp })
    local idx = d:prompt(choices)
    assert.is_nil(idx)
  end)

  it("retries on invalid input then accepts valid", function()
    local out, inp, captured = make_io({ "99", "1" })
    local d = plain_mod.new({ io_out = out, io_in = inp })
    local idx = d:prompt(choices)
    assert.equal(1, idx)
    assert.is_truthy(captured():find("Invalid"), captured())
  end)
end)

describe("plain driver: notify", function()
  it("is a no-op (does not error)", function()
    local out, inp, _ = make_io({})
    local d = plain_mod.new({ io_out = out, io_in = inp })
    assert.has_no_error(function() d:notify("mutation", { path = "x", value = 1 }) end)
  end)
end)

-- ── ansi driver ───────────────────────────────────────────────────────────────

describe("ansi driver: render", function()
  it("includes the speaker text", function()
    local out, inp, captured = make_io({})
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    assert.is_truthy(captured():find("Boo!"), captured())
  end)

  it("emits ANSI color escape for speaker with color field", function()
    local out, inp, captured = make_io({})
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    -- "#aabbcc" → \27[38;2;170;187;204m
    assert.is_truthy(captured():find("\27%[38;2;170;187;204m"), captured())
  end)

  it("emits ANSI reset after speaker label", function()
    local out, inp, captured = make_io({})
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = narr_items, choices = choices })
    assert.is_truthy(captured():find("\27%[0m"), captured())
  end)

  it("prints plain narration without escape codes", function()
    local out, inp, captured = make_io({})
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    d:render({ narration = { { kind = "narration", text = "Plain text." } }, choices = {} })
    -- The output for narration should be just the text with no color escape before it
    local text = captured()
    assert.is_truthy(text:find("Plain text%."), text)
    -- No color escape immediately before "Plain text."
    assert.is_falsy(text:find("\27%[38;2;.-mPlain text"), text)
  end)
end)

describe("ansi driver: prompt", function()
  it("returns the chosen index", function()
    local out, inp, _ = make_io({ "1" })
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    local idx = d:prompt(choices)
    assert.equal(1, idx)
  end)

  it("emits bold escape around choice index", function()
    local out, inp, captured = make_io({ "1" })
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    d:prompt(choices)
    assert.is_truthy(captured():find("\27%[1m1\27%[0m"), captured())
  end)

  it("returns nil on quit", function()
    local out, inp, _ = make_io({ "quit" })
    local d = ansi_mod.new({ io_out = out, io_in = inp })
    assert.is_nil(d:prompt(choices))
  end)
end)

-- ── --ui flag integration ─────────────────────────────────────────────────────

describe("--ui flag: driver loading via cli/main", function()
  local compiler = require("compiler.compiler")
  local engine   = require("runtime.engine")

  local src = [[
module ui-test
  version: 1.0
engine-config:
  entry-scene: start
speaker aldric:
  display: "Aldric"
  color:   "#ff0000"
scene start:
  say aldric: Hello.
  Welcome to the test.
  * Done -> start
]]

  local game_table
  before_each(function()
    local gt, diags = compiler.compile(src, "ui_test.sb")
    local errs = {}
    for _, d in ipairs(diags or {}) do
      if d.level == "error" then errs[#errs + 1] = d end
    end
    assert.equal(0, #errs, "compile errors")
    game_table = gt
  end)

  it("plain driver receives structured narration via step()", function()
    local rendered = {}
    local fake_driver = {
      render = function(_, scene_output)
        rendered[#rendered + 1] = scene_output
      end,
      prompt = function(_, _) return nil end,  -- quit immediately
      notify = function() end,
    }
    local io_null = { write = function() end }
    local eng = engine.new(game_table, { io_out = io_null, driver = fake_driver })
    eng:init()
    eng:step()
    assert.is_true(#rendered >= 1, "driver:render should have been called")
    local narr = rendered[1].narration
    local has_say = false
    local has_narration = false
    for _, item in ipairs(narr) do
      if item.kind == "say"       then has_say       = true end
      if item.kind == "narration" then has_narration = true end
    end
    assert.is_true(has_say,       "expected a say item")
    assert.is_true(has_narration, "expected a narration item")
  end)

  it("all narration items have a kind field", function()
    local rendered = {}
    local fake_driver = {
      render = function(_, scene_output) rendered[#rendered + 1] = scene_output end,
      prompt = function(_, _) return nil end,
      notify = function() end,
    }
    local io_null = { write = function() end }
    local eng = engine.new(game_table, { io_out = io_null, driver = fake_driver })
    eng:init()
    eng:step()
    for _, item in ipairs(rendered[1] and rendered[1].narration or {}) do
      assert.is_string(item.kind, "every narration item must have a kind field")
    end
  end)
end)

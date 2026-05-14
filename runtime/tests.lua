-- runtime/tests.lua
-- Test block runner: evaluates test declarations from the compiled game table.
--
-- Each test runs in a fresh state initialised to game defaults.
-- Sections:
--   setup:   mutation statements applied before the test body
--   run:     function calls / statements under test
--   expect:  boolean expressions that must all be truthy

local eval = require("runtime.eval")
local M    = {}

-- ============================================================
-- State helpers
-- ============================================================

local function make_fresh_store(game_table)
  local log_mod   = require("runtime.log")
  local state_mod = require("runtime.state")
  local l = log_mod.new()
  local s = state_mod.new(game_table.schema, l)
  s:init_defaults()
  return s
end

-- ============================================================
-- Single test runner
-- ============================================================

local function run_one_test(test_entry, game_table)
  local store = make_fresh_store(game_table)
  local ctx   = eval.new_ctx(store, game_table.fns, "test-setup", game_table)

  -- 1. Run setup statements
  for i, stmt in ipairs(test_entry.setup or {}) do
    local ok, err = pcall(eval.eval_stmt, stmt, ctx)
    if not ok then
      return { pass = false,
               fail_msg = string.format("setup[%d] raised error: %s", i, tostring(err)) }
    end
  end

  -- 2. Run the body under test
  ctx.fn_name = "test-run"
  for i, stmt in ipairs(test_entry.run or {}) do
    local ok, err = pcall(eval.eval_stmt, stmt, ctx)
    if not ok then
      return { pass = false,
               fail_msg = string.format("run[%d] raised error: %s", i, tostring(err)) }
    end
  end

  -- 3. Evaluate expect assertions
  ctx.fn_name = "test-expect"
  for i, expr in ipairs(test_entry.expect or {}) do
    local ok, result = pcall(eval.eval_expr, expr, ctx)
    if not ok then
      return { pass = false,
               fail_msg = string.format("expect[%d] raised error: %s", i, tostring(result)) }
    end
    if not result then
      return { pass = false,
               fail_msg = string.format("expect[%d] failed", i) }
    end
  end

  return { pass = true }
end

-- ============================================================
-- Public API
-- ============================================================

--- Run all test blocks in a game table.
---@param game_table table  Compiled game table (from codegen)
---@return table  List of {label, pass, fail_msg?} result tables
function M.run_all(game_table)
  local results = {}
  for _, test_entry in ipairs(game_table.tests or {}) do
    local r = run_one_test(test_entry, game_table)
    results[#results+1] = {
      label    = test_entry.label,
      pass     = r.pass,
      fail_msg = r.fail_msg,
    }
  end
  return results
end

return M

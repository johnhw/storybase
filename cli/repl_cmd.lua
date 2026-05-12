-- cli/repl_cmd.lua
-- storybase repl <file>
--
-- Load a .sb file and start an interactive expression REPL.
--
-- Commands at the prompt:
--   <expression>       Evaluate a pure expression and print the result
--   <fn-name>          Call a no-arg transaction function
--   :state <path>      Inspect a state path value
--   :scene             Show current scene name
--   :choices           List available choices
--   :choose <N>        Execute choice N
--   :tick              Run one autonomous turn
--   :load <path>       Load a save file
--   :save <path>       Save the current state
--   :help              Show this command list
--   :quit / :q / Ctrl-D  Exit the REPL

local M = {}

local PROMPT     = "storybase> "
local HELP_TEXT  = [[
REPL commands:
  <expression>           Evaluate a pure expression and print the result
  <fn-name> [arg ...]    Call a named function (transaction or pure)
  :state <path>          Show value at a state path
  :scene                 Show the current scene name
  :choices               List available choices in the current scene
  :choose <N>            Execute choice N
  :tick                  Run one autonomous turn (actors + scheduler)
  :save <path>           Save current game state to a file
  :load <path>           Load game state from a file
  :help                  Show this text
  :quit / :q             Exit the REPL
]]

local function parse_args(args)
  local flags, positional = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      local key = a:sub(3)
      if args[i + 1] and args[i + 1]:sub(1, 2) ~= "--" then
        flags[key] = args[i + 1]; i = i + 2
      else
        flags[key] = true; i = i + 1
      end
    else
      positional[#positional + 1] = a; i = i + 1
    end
  end
  return flags, positional
end

--- Pretty-print a Lua value returned by game:get / game:eval.
---@param v any
---@return string
local function pretty(v)
  if v == nil then return "nil" end
  if type(v) == "boolean"  then return tostring(v) end
  if type(v) == "number"   then return tostring(v) end
  if type(v) == "string"   then return string.format("%q", v) end
  if type(v) == "table" then
    -- Detect list (consecutive integer keys starting at 1)
    local n = #v
    local is_list = n > 0
    if is_list then
      for i = 1, n do
        if v[i] == nil then is_list = false; break end
      end
    end
    if is_list then
      local items = {}
      for _, item in ipairs(v) do items[#items + 1] = pretty(item) end
      return "[" .. table.concat(items, ", ") .. "]"
    end
    -- Generic table
    local items = {}
    for k, val in pairs(v) do
      items[#items + 1] = tostring(k) .. " = " .. pretty(val)
    end
    table.sort(items)
    return "{" .. table.concat(items, ", ") .. "}"
  end
  return tostring(v)
end

--- Run the repl subcommand.
---@param args table  argument list (without the leading "repl")
---@return integer    exit code
function M.run(args)
  local flags, pos_args = parse_args(args)
  local filepath = pos_args[1]
  if not filepath then
    io.stderr:write("error: storybase repl: no input file\n")
    return 1
  end

  -- Load the game via the public Lua API
  local ok_sb, sb = pcall(require, "lib.storybase")
  if not ok_sb then
    io.stderr:write("error: could not load storybase lib: " .. tostring(sb) .. "\n")
    return 1
  end

  local game, err = sb.load(filepath)
  if not game then
    io.stderr:write("error: " .. tostring(err) .. "\n")
    return 1
  end

  game:init()
  game:advance_to_choices()  -- follow any computed-goto entry scenes
  io.stdout:write("StoryBase REPL — " .. filepath .. "\n")
  io.stdout:write("Type :help for commands, :quit to exit.\n")
  io.stdout:write("\n")

  -- If --seed was given, we already seeded in load; note it.
  if flags["seed"] then
    math.randomseed(tonumber(flags["seed"]) or 0)
  end

  -- ── REPL loop ────────────────────────────────────────────────
  while true do
    io.stdout:write(PROMPT)
    io.stdout:flush()

    local line = io.stdin:read("*l")
    if not line then
      -- EOF (Ctrl-D)
      io.stdout:write("\n")
      break
    end

    line = line:match("^%s*(.-)%s*$")  -- trim
    if line == "" then goto continue end

    -- ── Meta-commands (:xxx) ──────────────────────────────────

    if line == ":quit" or line == ":q" then
      break

    elseif line == ":help" then
      io.stdout:write(HELP_TEXT)

    elseif line == ":scene" then
      io.stdout:write(tostring(game:current_scene()) .. "\n")

    elseif line == ":choices" then
      local _, choices = game:render()
      if #choices == 0 then
        io.stdout:write("(no choices)\n")
      else
        for i, c in ipairs(choices) do
          io.stdout:write(string.format("  %d. %s\n", i, c.label or ""))
        end
      end

    elseif line:match("^:choose%s+") then
      local n = tonumber(line:match("^:choose%s+(%d+)"))
      if not n then
        io.stderr:write("usage: :choose <N>\n")
      else
        local ok_ch, cerr = pcall(function() game:choose(n) end)
        if not ok_ch then
          io.stderr:write("error: " .. tostring(cerr) .. "\n")
        else
          -- Advance past any computed-goto scenes, collecting narration
          local narr = game:advance_to_choices()
          for _, item in ipairs(narr or {}) do
            if item.kind == "say" then
              local label = item.display or item.speaker or "?"
              io.stdout:write(label .. ": " .. tostring(item.text or "") .. "\n")
            elseif item.text and item.text ~= "" then
              io.stdout:write(item.text .. "\n")
            end
          end
        end
      end

    elseif line == ":tick" then
      local ok_tk, terr = pcall(function() game:tick() end)
      if not ok_tk then
        io.stderr:write("error: " .. tostring(terr) .. "\n")
      else
        io.stdout:write("(tick)\n")
      end

    elseif line:match("^:state%s+") then
      local path = line:match("^:state%s+(.+)$")
      if not path then
        io.stderr:write("usage: :state <path>\n")
      else
        local val = game:get(path)
        io.stdout:write(pretty(val) .. "\n")
      end

    elseif line:match("^:save%s+") then
      local path = line:match("^:save%s+(.+)$")
      if not path then
        io.stderr:write("usage: :save <path>\n")
      else
        local ok_sv, serr = game:save(path)
        if not ok_sv then
          io.stderr:write("error saving: " .. tostring(serr) .. "\n")
        else
          io.stdout:write("[Saved to " .. path .. "]\n")
        end
      end

    elseif line:match("^:load%s+") then
      local path = line:match("^:load%s+(.+)$")
      if not path then
        io.stderr:write("usage: :load <path>\n")
      else
        local ok_ld, lerr = game:load(path)
        if not ok_ld then
          io.stderr:write("error loading: " .. tostring(lerr) .. "\n")
        else
          io.stdout:write("[Loaded from " .. path .. "]\n")
        end
      end

    elseif line:sub(1, 1) == ":" then
      io.stderr:write("unknown command: " .. line .. "  (try :help)\n")

    else
      -- ── Expression / function call ───────────────────────────
      -- First try to evaluate as a pure expression
      local val, eval_err = game:eval(line)
      if eval_err == nil then
        io.stdout:write(pretty(val) .. "\n")
      else
        -- If eval failed, try treating the first token as a function name
        local fn_name = line:match("^([%w%-]+)")
        if fn_name and game._eng and game._eng._fns and game._eng._fns[fn_name] then
          local ok_fn, fn_err = pcall(function()
            game:call(fn_name)
          end)
          if not ok_fn then
            io.stderr:write("error: " .. tostring(fn_err) .. "\n")
          else
            io.stdout:write("(ok)\n")
          end
        else
          io.stderr:write("error: " .. tostring(eval_err) .. "\n")
        end
      end
    end

    ::continue::
  end

  return 0
end

return M

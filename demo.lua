#!/usr/bin/env lua5.4
-- demo.lua — run a numbered StoryBase demo
-- Usage: lua5.4 demo.lua <number>   e.g.  lua5.4 demo.lua 20

local num = arg[1]
if not num then
  io.stderr:write("usage: lua5.4 demo.lua <number>\n")
  os.exit(1)
end

-- Normalise to two-digit prefix (1 → "01", 20 → "20")
local prefix = string.format("%02d", tonumber(num) or -1)

-- Find the matching file in demos/
local handle = io.popen('ls demos/demo' .. prefix .. '_*.sb 2>/dev/null')
local path   = handle:read("*l")
handle:close()

if not path or path == "" then
  io.stderr:write("no demo found matching demos/demo" .. prefix .. "_*.sb\n")
  os.exit(1)
end

-- Hand off to the CLI — replace this process via os.execute
os.execute('lua5.4 cli/main.lua run ' .. path)

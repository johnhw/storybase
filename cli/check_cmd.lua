-- cli/check_cmd.lua
-- storybase check <file>
--
-- Runs lexer → parser → checker (stops before codegen) and reports
-- errors/warnings.  Faster feedback loop than `compile` for authoring.
--
-- Exit codes:
--   0  no errors (warnings may be present)
--   1  one or more errors

local M = {}

--- Split source text into a 1-based array of line strings.
local function split_lines(source)
  local lines = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

--- Print diagnostics to stderr, with source-context lines where available.
---@param diags      table  diagnostic accumulator
---@param source_map table? {[filepath] = source_string}
local function print_diags(diags, source_map)
  local line_cache = {}
  local function get_lines(file)
    if not source_map or not file then return nil end
    if not line_cache[file] then
      local src = source_map[file]
      if src then line_cache[file] = split_lines(src) end
    end
    return line_cache[file]
  end

  for _, d in ipairs(diags.all or {}) do
    local loc   = string.format("%s:%d:%d", d.file or "?", d.line or 0, d.col or 0)
    local label = (d.level == "error") and "error" or "warning"
    io.stderr:write(string.format("%s: %s [%s]: %s\n", loc, label, d.code, d.message))

    if d.line and d.line > 0 then
      local lines = get_lines(d.file)
      if lines then
        local srcline = lines[d.line]
        if srcline then
          io.stderr:write(string.format("  %s\n", srcline))
          local col = math.max(1, d.col or 1)
          io.stderr:write(string.format("  %s^\n", string.rep(" ", col - 1)))
        end
      end
    end

    if d.note and d.note ~= "" then
      io.stderr:write(string.format("  note: %s\n", d.note))
    end
  end
end

--- Parse flat argument list into {flags, positional}.
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

--- Run the check subcommand.
---@param args table  argument list (without the leading "check")
---@return integer    exit code
function M.run(args)
  local _, pos_args = parse_args(args)
  local filepath = pos_args[1]
  if not filepath then
    io.stderr:write("error: storybase check: no input file\n")
    return 1
  end

  local ok, compiler = pcall(require, "compiler.compiler")
  if not ok then
    io.stderr:write("error: could not load compiler: " .. tostring(compiler) .. "\n")
    return 1
  end

  -- Read source for context lines
  local source_map = {}
  local sf = io.open(filepath, "r")
  if sf then source_map[filepath] = sf:read("*a"); sf:close() end

  local typed_ast, diags = compiler.parse_and_check_file(filepath)
  print_diags(diags, source_map)

  local ne = #(diags.errors or {})
  local nw = #(diags.warnings or {})

  if ne > 0 then
    io.stderr:write(string.format("check failed: %d error%s",
      ne, ne == 1 and "" or "s"))
    if nw > 0 then
      io.stderr:write(string.format(", %d warning%s", nw, nw == 1 and "" or "s"))
    end
    io.stderr:write("\n")
    return 1
  end

  local ok_msg = "check passed"
  if nw > 0 then
    ok_msg = ok_msg .. string.format(" (%d warning%s)", nw, nw == 1 and "" or "s")
  end
  io.stdout:write(ok_msg .. "\n")

  -- Print type/state summary if check succeeded
  if typed_ast and typed_ast.symtab then
    local st = typed_ast.symtab
    local ntypes  = 0; for _ in pairs(st.types  or {}) do ntypes  = ntypes  + 1 end
    local nstates = 0; for _ in pairs(st.states or {}) do nstates = nstates + 1 end
    io.stdout:write(string.format("  Types: %d  State paths: %d\n",
      ntypes, nstates))
  end

  return 0
end

return M

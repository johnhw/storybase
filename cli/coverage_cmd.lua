-- cli/coverage_cmd.lua
-- storybase coverage [--depth N] [--budget N] [--format json] <file>
--
-- Walk the BFS frontier and report which scenes and fns are exercised
-- at the configured search depth. Unreachable scenes and uncovered fns
-- are explicitly listed.  Exit 0 on success, 1 on compile / argument error.

local M = {}

local function parse_args(args)
  local flags      = {}
  local positional = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      local key = a:sub(3)
      if args[i + 1] and args[i + 1]:sub(1, 2) ~= "--" then
        flags[key] = args[i + 1]
        i = i + 2
      else
        flags[key] = true
        i = i + 1
      end
    else
      positional[#positional + 1] = a
      i = i + 1
    end
  end
  return flags, positional
end

function M.run(args)
  local flags, pos_args = parse_args(args or {})
  local filepath = pos_args[1]
  if not filepath then
    io.stderr:write("error: storybase coverage: no input file\n")
    return 1
  end

  -- 1. Read and compile
  local f, ferr = io.open(filepath, "r")
  if not f then
    io.stderr:write("error: cannot open " .. filepath .. ": " .. tostring(ferr) .. "\n")
    return 1
  end
  local src = f:read("*a"); f:close()

  local compiler    = require("compiler.compiler")
  local game_table, diags = compiler.compile(src, filepath)
  for _, d in ipairs(diags and diags.all or {}) do
    local loc = string.format("%s:%d:%d", d.file or "?", d.line or 0, d.col or 0)
    io.stderr:write(string.format("%s: %s: %s\n", loc, d.level, d.message))
  end
  if diags:has_errors() then
    io.stderr:write("Compilation failed; cannot run coverage.\n")
    return 1
  end

  -- 2. Collect declared entities
  local scene_order = {}
  for name in pairs(game_table.scenes or {}) do
    scene_order[#scene_order + 1] = name
  end
  table.sort(scene_order)

  local fn_order = {}
  for name in pairs(game_table.fns or {}) do
    fn_order[#fn_order + 1] = name
  end
  table.sort(fn_order)

  -- Coverage counters
  local scene_counts = {}  -- name → visit count (distinct BFS nodes at that scene)
  local fn_counts    = {}  -- name → call count across all BFS paths
  for _, name in ipairs(scene_order) do scene_counts[name] = 0 end
  for _, name in ipairs(fn_order)    do fn_counts[name]    = 0 end

  -- 3. Install fn-call hook on the game table before BFS runs
  game_table._fn_call_hook = function(name)
    if fn_counts[name] ~= nil then
      fn_counts[name] = fn_counts[name] + 1
    end
  end

  -- 4. Build the initial BFS state from a fresh engine initialisation
  local engine_mod = require("runtime.engine")
  local io_sink    = { write = function() end }

  local entry = game_table.schema
    and game_table.schema.engine_config
    and game_table.schema.engine_config["entry-scene"]
  if not entry then
    io.stderr:write("error: no entry-scene defined in engine-config\n")
    game_table._fn_call_hook = nil
    return 1
  end

  local init_eng = engine_mod.new(game_table, { io_out = io_sink })
  init_eng:init()
  -- Pass the live _cache reference; expand_graph clones it immediately via clone_flat
  local initial_cache = init_eng._state._cache
  local initial_stack = { entry }

  -- 5. Run BFS via expand_graph
  local search = require("runtime.search")
  local depth  = tonumber(flags.depth)  or 8
  local budget = tonumber(flags.budget) or 30

  local result = search.expand_graph(game_table, initial_cache, initial_stack, {
    depth     = depth,
    max_nodes = 5000,
    budget    = budget,
  })

  -- 6. Tally scene visits from BFS nodes
  for _, node in ipairs(result.nodes or {}) do
    if node.scene and scene_counts[node.scene] ~= nil then
      scene_counts[node.scene] = scene_counts[node.scene] + 1
    end
  end

  -- 7. Remove hook
  game_table._fn_call_hook = nil

  -- 8. Compute percentages
  local total_scenes   = #scene_order
  local reached_scenes = 0
  for _, name in ipairs(scene_order) do
    if scene_counts[name] > 0 then reached_scenes = reached_scenes + 1 end
  end

  local total_fns   = #fn_order
  local reached_fns = 0
  for _, name in ipairs(fn_order) do
    if fn_counts[name] > 0 then reached_fns = reached_fns + 1 end
  end

  local scene_pct = total_scenes > 0
    and math.floor(reached_scenes / total_scenes * 100 + 0.5) or 100
  local fn_pct = total_fns > 0
    and math.floor(reached_fns / total_fns * 100 + 0.5) or 100

  -- Sorted lists of unreachable / uncovered entities
  local unreachable_scenes = {}
  for _, name in ipairs(scene_order) do
    if scene_counts[name] == 0 then
      unreachable_scenes[#unreachable_scenes + 1] = name
    end
  end
  local uncovered_fns = {}
  for _, name in ipairs(fn_order) do
    if fn_counts[name] == 0 then
      uncovered_fns[#uncovered_fns + 1] = name
    end
  end

  -- 9. Emit report
  local format = flags.format
  if format == "json" then
    -- Build JSON via runtime.debug encode_json (already a dep for the project)
    local debug_mod = require("runtime.debug")

    local scenes_detail = {}
    for _, name in ipairs(scene_order) do
      scenes_detail[#scenes_detail + 1] = {
        name    = name,
        visits  = scene_counts[name],
        reached = scene_counts[name] > 0,
      }
    end
    local fns_detail = {}
    for _, name in ipairs(fn_order) do
      fns_detail[#fns_detail + 1] = {
        name    = name,
        calls   = fn_counts[name],
        reached = fn_counts[name] > 0,
      }
    end

    local payload = {
      file      = filepath,
      depth     = depth,
      truncated = result.truncated or false,
      bfs_nodes = result.node_count or 0,
      bfs_edges = result.edge_count or 0,
      scenes    = {
        total    = total_scenes,
        reached  = reached_scenes,
        percent  = scene_pct,
        detail   = scenes_detail,
      },
      fns = {
        total    = total_fns,
        reached  = reached_fns,
        percent  = fn_pct,
        detail   = fns_detail,
      },
    }
    io.stdout:write(debug_mod.encode_json(payload) .. "\n")

  else
    -- Human-readable text output
    io.stdout:write(string.format("Coverage report: %s\n", filepath))
    io.stdout:write(string.format(
      "  BFS depth: %d  nodes: %d  edges: %d%s\n\n",
      depth,
      result.node_count or 0,
      result.edge_count or 0,
      (result.truncated and "  [truncated — increase --depth or --budget]") or ""))

    -- Scenes
    io.stdout:write(string.format("Scenes  %d / %d  (%d%%)\n",
      reached_scenes, total_scenes, scene_pct))
    for _, name in ipairs(scene_order) do
      local n    = scene_counts[name]
      local mark = n > 0 and "[x]" or "[ ]"
      io.stdout:write(string.format("  %s  %-30s  %d node(s)\n", mark, name, n))
    end
    if #unreachable_scenes > 0 then
      io.stdout:write(string.format("\n  Unreachable scenes (%d):\n",
        #unreachable_scenes))
      for _, name in ipairs(unreachable_scenes) do
        io.stdout:write(string.format("    - %s\n", name))
      end
    end

    -- Functions
    if total_fns > 0 then
      io.stdout:write(string.format("\nFunctions  %d / %d  (%d%%)\n",
        reached_fns, total_fns, fn_pct))
      for _, name in ipairs(fn_order) do
        local n    = fn_counts[name]
        local mark = n > 0 and "[x]" or "[ ]"
        io.stdout:write(string.format("  %s  %-30s  %d call(s)\n", mark, name, n))
      end
      if #uncovered_fns > 0 then
        io.stdout:write(string.format("\n  Uncovered functions (%d):\n",
          #uncovered_fns))
        for _, name in ipairs(uncovered_fns) do
          io.stdout:write(string.format("    - %s\n", name))
        end
      end
    end

    io.stdout:write(string.format("\nSummary: scenes %d%%", scene_pct))
    if total_fns > 0 then
      io.stdout:write(string.format(", fns %d%%", fn_pct))
    end
    io.stdout:write("\n")
  end

  return 0
end

return M

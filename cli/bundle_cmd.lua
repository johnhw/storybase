-- cli/bundle_cmd.lua
-- storybase bundle <game.sb> [--output <path>] [--production]
--
-- Produces a single self-contained Lua file: all runtime modules embedded,
-- compiler stripped, game table baked in as a Lua literal.
--
-- The output file runs with a stock lua5.4 binary — no StoryBase installation
-- required.  Only standard Lua 5.4 libraries are needed.  LuaSocket is
-- optional; it is only used if the debug server is started (development mode).
--
-- ── Future asset support ─────────────────────────────────────────────────────
-- When StoryBase gains an asset system (images, audio, tile-set data, …),
-- the bundler will embed those assets in the BUNDLED_ASSETS table that is
-- already emitted in every bundle.  The asset_load() helper is provided today
-- for forward compatibility; game code will be able to call it without knowing
-- whether it is running from source or from a bundle.
--
-- Planned embed formats:
--   • Text / JSON / CSV  → stored verbatim as Lua strings
--   • Binary data        → base64-encoded; asset_load() returns raw bytes
--   • Large assets       → optionally kept as sidecar files; path recorded in table
--
-- The bundler will scan for an asset manifest next to the .sb file
-- (e.g. game.assets.json) and embed each listed file into BUNDLED_ASSETS.
-- ─────────────────────────────────────────────────────────────────────────────

local M = {}

-- Runtime modules to embed in every bundle, in loose dependency order.
-- compiler.ast is included because runtime.migrate requires it.
-- runtime.debug is excluded: it lazily requires compiler.compiler for hot-reload
-- which is not bundled.  To debug a game, run it from source with `storybase run`.
local BUNDLE_MODULES = {
  "compiler.ast",
  "runtime.log",
  "runtime.random",
  "runtime.state",
  "runtime.tilegrid",
  "runtime.query",
  "runtime.search",
  "runtime.actors",
  "runtime.scheduler",
  "runtime.eval",
  "runtime.counterfactual",
  "runtime.verify",
  "runtime.migrate",
  "runtime.engine",
}

-- ============================================================
-- Lua value serialiser
-- ============================================================

--- Serialise a Lua value as valid Lua source text that reconstructs it.
---
--- Supported types: nil, boolean, number (incl. NaN/±Inf), string, table.
--- Tables may be arbitrarily nested.  Cycle detection raises an error.
--- Shared sub-tables (same reference, no cycle) are serialised as separate
--- identical copies — the game table is read-only at runtime so identity is
--- irrelevant.
---
---@param val     any     Value to serialise
---@param depth   integer Nesting depth (internal; start at 0)
---@param visited table   Cycle-detection set (internal; start at {})
---@return string         Valid Lua literal
local serialize  -- forward declaration (needed for mutual recursion with table branch)

serialize = function(val, depth, visited)
  depth   = depth   or 0
  visited = visited or {}

  local vtype = type(val)

  if vtype == "nil" then
    return "nil"

  elseif vtype == "boolean" then
    return tostring(val)

  elseif vtype == "number" then
    if val ~= val then               -- IEEE 754 NaN
      return "(0/0)"
    elseif val == math.huge then
      return "math.huge"
    elseif val == -math.huge then
      return "-math.huge"
    elseif val == math.floor(val) and math.abs(val) < 2^53 then
      return string.format("%d", val)  -- integer: no decimal point
    else
      return string.format("%.17g", val)
    end

  elseif vtype == "string" then
    return string.format("%q", val)

  elseif vtype == "table" then
    if depth > 250 then
      error("bundle: table nesting depth exceeds 250 levels — aborting", 2)
    end
    if visited[val] then
      error("bundle: reference cycle detected in game table — cannot serialise", 2)
    end
    visited[val] = true

    local pad    = string.rep("  ", depth + 1)
    local endpad = string.rep("  ", depth)

    -- Determine whether this is a pure sequence (keys are exactly 1..#val, nothing else).
    local n = #val
    local total_keys = 0
    for _ in pairs(val) do total_keys = total_keys + 1 end
    local pure_seq = (n == total_keys) and (n > 0)

    local parts = {}

    if pure_seq then
      -- Compact sequence form: { v1, v2, … }
      for idx = 1, n do
        parts[#parts + 1] = pad .. serialize(val[idx], depth + 1, visited)
      end
    else
      -- General map / mixed form: output every key explicitly.
      -- Sort for determinism: string keys first (lexicographic), then integer keys.
      local entries = {}
      for k, v in pairs(val) do
        entries[#entries + 1] = { k = k, v = v }
      end
      table.sort(entries, function(a, b)
        local ta, tb = type(a.k), type(b.k)
        if ta ~= tb then return ta == "string" end  -- strings before numbers
        if ta == "number" then return a.k < b.k end
        return tostring(a.k) < tostring(b.k)
      end)

      for _, e in ipairs(entries) do
        local k, v = e.k, e.v
        local kstr
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
          kstr = k                                 -- bare identifier key
        elseif type(k) == "number" then
          kstr = "[" .. k .. "]"
        else
          kstr = "[" .. string.format("%q", tostring(k)) .. "]"
        end
        parts[#parts + 1] = pad .. kstr .. " = " .. serialize(v, depth + 1, visited)
      end
    end

    visited[val] = nil  -- clear so the same table can be serialised if reached from elsewhere

    if #parts == 0 then
      return "{}"
    else
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. endpad .. "}"
    end

  else
    error("bundle: cannot serialise value of type '" .. vtype
          .. "' — functions and userdata are not supported in game tables", 2)
  end
end

-- ============================================================
-- Module file resolver
-- ============================================================

--- Locate and read the source of a Lua module.
--- Uses package.searchpath so the same resolution logic as require() applies.
---@param mod_name string  e.g. "runtime.engine"
---@return string|nil source, string|nil error_msg
local function read_module_source(mod_name)
  local path, serr = package.searchpath(mod_name, package.path)
  if not path then
    return nil, "cannot locate module '" .. mod_name .. "': " .. tostring(serr)
  end
  local f, ferr = io.open(path, "r")
  if not f then
    return nil, "cannot open '" .. path .. "': " .. tostring(ferr)
  end
  local src = f:read("*a")
  f:close()
  return src
end

-- ============================================================
-- Bundle writer
-- ============================================================

--- Write the complete bundle to an already-open file handle.
---@param out_f      file*   Output file (open for writing)
---@param game_src   string  Original .sb file path (for header comment)
---@param game_table table   Compiled game table
---@param modules    table   List of { name=string, source=string }
---@param opts       table   { production=bool }
local function write_bundle(out_f, game_src, game_table, modules, opts)
  opts = opts or {}

  -- ── Header ────────────────────────────────────────────────────────────────
  out_f:write("#!/usr/bin/env lua5.4\n")
  out_f:write("-- StoryBase Bundle\n")
  out_f:write(string.format("-- Source:  %s\n", game_src))
  out_f:write(string.format("-- Built:   %s\n", os.date("%Y-%m-%d %H:%M:%S")))
  out_f:write(string.format("-- Mode:    %s\n",
    opts.production and "production (verify/watch blocks stripped)" or "development"))
  out_f:write("--\n")
  out_f:write("-- Run with:  lua5.4 <this-file> [--seed N] [--save <path>] [--load <path>]\n")
  out_f:write("-- This file is self-contained; no StoryBase installation is required.\n")
  out_f:write("\n")

  -- ── Bundled modules ───────────────────────────────────────────────────────
  out_f:write(string.rep("-", 78) .. "\n")
  out_f:write("-- Bundled modules\n")
  out_f:write(string.rep("-", 78) .. "\n")
  out_f:write("-- Each runtime module is registered as a package.preload entry so that\n")
  out_f:write("-- the normal require() mechanism finds it without any file I/O.\n")
  out_f:write("\n")

  for _, mod in ipairs(modules) do
    out_f:write(string.format("package.preload[%q] = function(...)\n", mod.name))
    out_f:write(mod.source)
    if mod.source:sub(-1) ~= "\n" then out_f:write("\n") end
    out_f:write("end\n\n")
  end

  -- ── Bundled assets ────────────────────────────────────────────────────────
  out_f:write(string.rep("-", 78) .. "\n")
  out_f:write("-- Bundled assets\n")
  out_f:write(string.rep("-", 78) .. "\n")
  out_f:write("-- Future: images, audio, and other game assets will be embedded here.\n")
  out_f:write("-- Populate BUNDLED_ASSETS[\"logical/path\"] = content_string to add assets.\n")
  out_f:write("-- Call asset_load(path) at runtime to retrieve an asset by its logical path.\n")
  out_f:write("\n")
  out_f:write("local BUNDLED_ASSETS = {}\n")
  out_f:write("\n")
  out_f:write("---Retrieve a bundled asset by its logical path.\n")
  out_f:write("---@param path string\n")
  out_f:write("---@return string|nil\n")
  -- suppress luacheck unused-variable warning; asset_load is part of the public API surface
  out_f:write("local asset_load = function(path) return BUNDLED_ASSETS[path] end --luacheck: ignore\n")
  out_f:write("\n")

  -- ── Game table ────────────────────────────────────────────────────────────
  out_f:write(string.rep("-", 78) .. "\n")
  out_f:write("-- Game table\n")
  out_f:write(string.rep("-", 78) .. "\n")
  out_f:write("-- Compiled schema, functions, scenes, actors, and schedules.\n")
  out_f:write("\n")
  out_f:write("local GAME_TABLE = ")
  local ok_ser, serialized = pcall(serialize, game_table, 0, {})
  if not ok_ser then
    error("failed to serialise game table: " .. tostring(serialized), 2)
  end
  out_f:write(serialized)
  out_f:write("\n\n")

  -- ── Runner ────────────────────────────────────────────────────────────────
  out_f:write(string.rep("-", 78) .. "\n")
  out_f:write("-- Runner\n")
  out_f:write(string.rep("-", 78) .. "\n")
  out_f:write("-- Parse command-line options and start the game engine.\n")
  out_f:write("\n")
  out_f:write([[
local _args = arg or {}
local _opts = {}
local _i = 1
while _i <= #_args do
  local _a = _args[_i]
  if _a == "--seed" and _args[_i + 1] then
    _opts.seed = tonumber(_args[_i + 1]); _i = _i + 2
  elseif _a == "--save" and _args[_i + 1] then
    _opts.save_path = _args[_i + 1]; _i = _i + 2
  elseif _a == "--load" and _args[_i + 1] then
    _opts.load_path = _args[_i + 1]; _i = _i + 2
  else
    _i = _i + 1
  end
end

local _engine = require("runtime.engine")
_engine.run(GAME_TABLE, _opts)
]])
end

-- ============================================================
-- CLI entry point
-- ============================================================

function M.run(args)
  local flags = {}
  local positional = {}
  local i = 1
  while i <= #(args or {}) do
    local a = args[i]
    if a:sub(1, 2) == "--" then
      local key = a:sub(3)
      if key == "production" then
        flags["production"] = true; i = i + 1
      elseif args[i + 1] and args[i + 1]:sub(1, 2) ~= "--" then
        flags[key] = args[i + 1]; i = i + 2
      else
        flags[key] = true; i = i + 1
      end
    else
      positional[#positional + 1] = a; i = i + 1
    end
  end

  local sb_path = positional[1]
  if not sb_path then
    io.stderr:write("usage: storybase bundle <game.sb> [--output <path>] [--production]\n")
    return 1
  end

  -- Default output: same directory as .sb, .lua extension
  local out_path = flags["output"]
  if not out_path then
    out_path = sb_path:gsub("%.sb$", "") .. ".lua"
    if out_path == sb_path then out_path = sb_path .. ".bundle.lua" end
  end

  -- ── Compile source ───────────────────────────────────────────────────────
  local ok_c, compiler = pcall(require, "compiler.compiler")
  if not ok_c then
    io.stderr:write("error: could not load compiler: " .. tostring(compiler) .. "\n")
    return 1
  end

  local compile_opts = { production = (flags["production"] == true) }
  local game_table, diags = compiler.compile_file(sb_path, compile_opts)

  for _, d in ipairs(diags and diags.all or {}) do
    local label = (d.level == "error") and "error" or "warning"
    io.stderr:write(string.format("%s:%d: %s [%s]: %s\n",
      d.file or sb_path, d.line or 0, label, d.code, d.message))
  end

  if not game_table or diags:has_errors() then
    io.stderr:write("error: compilation failed; cannot bundle '" .. sb_path .. "'\n")
    return 1
  end

  -- ── Load runtime module sources ──────────────────────────────────────────
  local modules = {}
  local missing = {}
  for _, mod_name in ipairs(BUNDLE_MODULES) do
    local src, err = read_module_source(mod_name)
    if not src then
      missing[#missing + 1] = { name = mod_name, err = err }
    else
      modules[#modules + 1] = { name = mod_name, source = src }
    end
  end

  if #missing > 0 then
    io.stderr:write("error: could not locate the following modules to embed:\n")
    for _, m in ipairs(missing) do
      io.stderr:write(string.format("  %s: %s\n", m.name, m.err))
    end
    return 1
  end

  -- ── Write bundle ─────────────────────────────────────────────────────────
  local out_f, ferr = io.open(out_path, "w")
  if not out_f then
    io.stderr:write("error: cannot open output file '" .. out_path
                    .. "': " .. tostring(ferr) .. "\n")
    return 1
  end

  local bundle_opts = { production = flags["production"] == true }
  local ok_w, werr = pcall(write_bundle, out_f, sb_path, game_table, modules, bundle_opts)
  out_f:close()

  if not ok_w then
    io.stderr:write("error: bundle generation failed: " .. tostring(werr) .. "\n")
    os.remove(out_path)
    return 1
  end

  -- ── Report ───────────────────────────────────────────────────────────────
  local size_f = io.open(out_path, "rb")
  local out_size = 0
  if size_f then
    out_size = size_f:seek("end") or 0
    size_f:close()
  end

  io.stdout:write(string.format("Bundle written: %s\n", out_path))
  io.stdout:write(string.format("  %d modules embedded, %d bytes\n", #modules, out_size))
  io.stdout:write(string.format("  Run with: lua5.4 %s\n", out_path))

  return 0
end

return M

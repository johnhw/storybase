-- runtime/config.lua
-- Registry-backed configuration with a precedence chain.
--
-- Every tunable knob is declared once via `declare(key, spec)`. Reads of
-- undeclared keys error so magic-string lookups cannot leak back in. Values
-- are resolved on read by walking layers in priority order:
--
--   runtime > cli > env > file > game > default
--
--   runtime  — programmatic override via M.set()
--   cli      — parsed command-line args, set via M.bind_cli({...})
--   env      — STORYBASE_* env vars, populated by M.load_env()
--   file     — simple `key = value` lines, populated by M.load_file(path)
--   game     — the compiled `engine-config:` block of the loaded .sb file
--   default  — the spec's `default` field
--
-- Key naming is canonical: dotted, lowercase, hyphens kept. Examples:
--   engine.scene-stack-max, engine.npc-speed, debug.port, run.steps.

local M = {}

-- ── Internal state ───────────────────────────────────────────────

local REGISTRY = {}        -- key → spec table
local LAYERS = {
  runtime = {},
  cli     = {},
  env     = {},
  file    = {},
  game    = {},
  default = {},
}
local LAYER_ORDER = { "runtime", "cli", "env", "file", "game", "default" }

-- ── Type coercion ────────────────────────────────────────────────

local function coerce_bool(v)
  if type(v) == "boolean" then return v end
  if type(v) == "number" then
    if v == 1 then return true end
    if v == 0 then return false end
    return nil, "invalid boolean: " .. tostring(v)
  end
  if type(v) ~= "string" then
    return nil, "invalid boolean: " .. tostring(v)
  end
  local s = v:lower()
  if s == "true" or s == "yes" or s == "on" or s == "1" then return true end
  if s == "false" or s == "no" or s == "off" or s == "0" then return false end
  return nil, "invalid boolean: " .. tostring(v)
end

local function coerce_int(v)
  local n
  if type(v) == "number" then
    n = v
  else
    n = tonumber(v)
    if not n then return nil, "invalid integer: " .. tostring(v) end
  end
  if n % 1 ~= 0 then
    return nil, "expected integer, got fractional: " .. tostring(v)
  end
  return math.floor(n)
end

local function coerce_float(v)
  if type(v) == "number" then return v end
  local n = tonumber(v)
  if not n then return nil, "invalid number: " .. tostring(v) end
  return n
end

local function coerce_string(v)
  if type(v) == "string" then return v end
  if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
  return nil, "expected string, got " .. type(v)
end

local COERCERS = {
  bool    = coerce_bool,
  boolean = coerce_bool,
  int     = coerce_int,
  integer = coerce_int,
  float   = coerce_float,
  number  = coerce_float,
  string  = coerce_string,
}

local function coerce(key, value)
  local spec = REGISTRY[key]
  if not spec then error("unknown config key: " .. key, 3) end
  if value == nil then return nil end

  if spec.coerce then
    local v, err = spec.coerce(value)
    if err then error(("config %s: %s"):format(key, err), 3) end
    return v
  end

  if spec.type == "enum" then
    local s = tostring(value)
    for _, opt in ipairs(spec.enum or {}) do
      if opt == s then return s end
    end
    error(("config %s: invalid enum value %q (allowed: %s)"):format(
      key, s, table.concat(spec.enum or {}, ", ")), 3)
  end

  local fn = COERCERS[spec.type]
  if not fn then
    error(("config %s: unsupported type %q"):format(key, tostring(spec.type)), 3)
  end
  local v, err = fn(value)
  if err then error(("config %s: %s"):format(key, err), 3) end
  return v
end

-- ── Public API ───────────────────────────────────────────────────

--- Declare a configuration key. Must be called exactly once per key.
---@param key string  Canonical dotted key, e.g. "engine.scene-stack-max".
---@param spec table  Fields:
---   type    — "int" | "float" | "bool" | "string" | "enum"
---   default — value used when no layer overrides (may be nil)
---   doc     — short human-readable description (for --help / dump)
---   enum    — list of allowed strings (when type == "enum")
---   env     — explicit env var name (default: STORYBASE_<KEY>)
---   cli     — flag name like "--http-port" (informational; for --help)
---   coerce  — optional function(raw) -> value, err. Bypasses built-in.
function M.declare(key, spec)
  assert(type(key) == "string" and key ~= "", "config key must be non-empty string")
  assert(type(spec) == "table", "config spec must be a table")
  if REGISTRY[key] then
    error("duplicate config key: " .. key, 2)
  end
  REGISTRY[key] = spec
  if spec.default ~= nil then
    LAYERS.default[key] = coerce(key, spec.default)
  end
end

--- Read a resolved value. Returns (value, layer) where `layer` names the
--- winning source ("runtime", "cli", ..., "default", or "unset" if all
--- layers are empty and the default is nil).
function M.get(key)
  if not REGISTRY[key] then error("unknown config key: " .. key, 2) end
  for _, layer in ipairs(LAYER_ORDER) do
    local v = LAYERS[layer][key]
    if v ~= nil then return v, layer end
  end
  return nil, "unset"
end

--- Programmatic override (highest precedence). Pass nil to clear.
function M.set(key, value)
  if not REGISTRY[key] then error("unknown config key: " .. key, 2) end
  if value == nil then
    LAYERS.runtime[key] = nil
  else
    LAYERS.runtime[key] = coerce(key, value)
  end
end

--- Additive single-key write to the cli layer. Unlike `bind_cli` (which
--- clears the layer first), `set_cli` only touches one key — so typed flag
--- handlers can pile on without stomping the bulk override table that
--- `bind_cli` already installed. Pass nil to clear just this key.
function M.set_cli(key, value)
  if not REGISTRY[key] then error("unknown config key: " .. key, 2) end
  if value == nil then
    LAYERS.cli[key] = nil
  else
    LAYERS.cli[key] = coerce(key, value)
  end
end

local function env_var_name(key, spec)
  if spec.env then return spec.env end
  return "STORYBASE_" .. key:upper():gsub("[%.%-]", "_")
end

--- Populate the env layer by scanning os.getenv for each declared key.
--- `getenv` (test seam) defaults to os.getenv.
function M.load_env(getenv)
  getenv = getenv or os.getenv
  for key, spec in pairs(REGISTRY) do
    local name = env_var_name(key, spec)
    local raw = getenv(name)
    if raw ~= nil and raw ~= "" then
      LAYERS.env[key] = coerce(key, raw)
    end
  end
end

--- Load a simple-format config file into the file layer. Returns
--- (ok, errors) — ok is true iff no errors were collected. Unknown keys
--- and malformed lines accumulate in `errors`; valid lines are still
--- applied. Quoted values (`"..."` or `'...'`) have their quotes stripped.
function M.load_file(path)
  local f, oerr = io.open(path, "r")
  if not f then return false, { oerr or ("could not open: " .. path) } end

  local errors = {}
  local lineno = 0
  for line in f:lines() do
    lineno = lineno + 1
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local k, v = trimmed:match("^([%w%._%-]+)%s*=%s*(.*)$")
      if not k then
        errors[#errors + 1] = ("%s:%d: malformed line: %s"):format(path, lineno, line)
      elseif not REGISTRY[k] then
        errors[#errors + 1] = ("%s:%d: unknown config key: %s"):format(path, lineno, k)
      else
        v = v:match("^%s*(.-)%s*$")
        local stripped = v:match('^"(.*)"$') or v:match("^'(.*)'$")
        if stripped then v = stripped end
        local ok, err = pcall(function()
          LAYERS.file[k] = coerce(k, v)
        end)
        if not ok then
          errors[#errors + 1] = ("%s:%d: %s"):format(path, lineno, err)
        end
      end
    end
  end
  f:close()
  return #errors == 0, errors
end

--- Populate the game layer from a compiled game_table's engine_config block.
--- Each entry maps to `engine.<key>`. Entries not declared in the registry
--- are silently ignored — the checker is responsible for validating them.
function M.bind_game(game_table)
  for k in pairs(LAYERS.game) do LAYERS.game[k] = nil end
  local ec = game_table
    and game_table.schema
    and game_table.schema.engine_config
  if not ec then return end
  for k, v in pairs(ec) do
    local key = "engine." .. k
    if REGISTRY[key] then
      LAYERS.game[key] = coerce(key, v)
    end
  end
end

--- Populate the cli layer from a `{key = value}` table. The caller (CLI
--- arg parser) is responsible for mapping flag names like "--http-port"
--- to canonical keys like "debug.http-port". Unknown keys error.
function M.bind_cli(args)
  for k in pairs(LAYERS.cli) do LAYERS.cli[k] = nil end
  if not args then return end
  for k, v in pairs(args) do
    if not REGISTRY[k] then
      error("unknown config key from CLI: " .. k, 2)
    end
    LAYERS.cli[k] = coerce(k, v)
  end
end

--- Bootstrap the env and file layers from the conventional sources:
---   1. `<home>/.storybaserc`  (if present)
---   2. `<cwd>/.storybaserc`   (if present, overrides home)
---   3. STORYBASE_* env vars
--- Files that don't exist are silently skipped (not an error). Returns
--- (errors, sources) where `errors` is a list of strings collected from any
--- file's parse, and `sources` lists the file paths that were actually read.
---
--- Opts (all optional, mostly for tests):
---   home   — home directory (default: $HOME or $USERPROFILE)
---   cwd    — current directory (default: ".")
---   getenv — env lookup function (default: os.getenv)
function M.load_startup(opts)
  opts = opts or {}
  local home   = opts.home   or os.getenv("HOME") or os.getenv("USERPROFILE")
  local cwd    = opts.cwd    or "."
  local getenv = opts.getenv or os.getenv

  local errors  = {}
  local sources = {}

  local function maybe_load(path)
    if not path or path == "" then return end
    local f = io.open(path, "r")
    if not f then return end
    f:close()
    local ok, errs = M.load_file(path)
    sources[#sources + 1] = path
    if not ok then
      for _, e in ipairs(errs) do errors[#errors + 1] = e end
    end
  end

  if home and home ~= "" then
    maybe_load(home .. "/.storybaserc")
  end
  maybe_load(cwd .. "/.storybaserc")

  M.load_env(getenv)
  return errors, sources
end

--- Diagnostic dump: { [key] = { value = v, layer = "cli", doc = "..." } }.
function M.dump()
  local out = {}
  for key, spec in pairs(REGISTRY) do
    local v, layer = M.get(key)
    out[key] = { value = v, layer = layer, doc = spec.doc }
  end
  return out
end

--- Format declared keys as a help block. Returns a string with one line
--- per key:  `  <key>  (<type>, default=<v>) — <doc>`. Used to generate the
--- "Config keys" section of `storybase --help`.
function M.format_help()
  local lines = {}
  for _, key in ipairs(M.keys()) do
    local spec = REGISTRY[key]
    local typ = spec.type or "?"
    local def = LAYERS.default[key]
    local parts = { typ }
    if def ~= nil then parts[#parts + 1] = "default=" .. tostring(def) end
    if spec.enum then
      parts[#parts + 1] = "one of: " .. table.concat(spec.enum, "|")
    end
    local header = ("  %-36s (%s)"):format(key, table.concat(parts, ", "))
    if spec.doc and spec.doc ~= "" then
      lines[#lines + 1] = header .. " — " .. spec.doc
    else
      lines[#lines + 1] = header
    end
  end
  return table.concat(lines, "\n")
end

--- Return the spec for `key`, or nil if undeclared.
function M.spec(key)
  return REGISTRY[key]
end

--- Sorted list of all declared keys.
function M.keys()
  local out = {}
  for k in pairs(REGISTRY) do out[#out + 1] = k end
  table.sort(out)
  return out
end

--- Test-only: clear all state. Call between specs.
function M._reset()
  for k in pairs(REGISTRY) do REGISTRY[k] = nil end
  for _, layer in ipairs(LAYER_ORDER) do
    for k in pairs(LAYERS[layer]) do LAYERS[layer][k] = nil end
  end
end

return M

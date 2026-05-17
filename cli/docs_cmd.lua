-- cli/docs_cmd.lua
-- storybase docs <file.sb>: emit a static reference site for a game.
--
-- Walks the typed AST, groups declarations by kind, and renders one page
-- per kind plus a home page.  Reuses the doc strings attached to every
-- declaration (§18.4) so authors don't have to maintain a second copy.
--
-- Usage:
--   storybase docs <file.sb>                  # writes ./docs_out/
--   storybase docs <file.sb> -o my_docs       # writes ./my_docs/
--   storybase docs <file.sb> --format md      # single Markdown file
--   storybase docs <file.sb> --format md -o reference.md

local M = {}

local ast      = require("compiler.ast")
local compiler = require("compiler.compiler")
local lexer    = require("compiler.lexer")
local parser   = require("compiler.parser")

local K = ast.K

-- ============================================================
-- Type-expression formatter (lifted from cli/format_cmd.lua)
-- ============================================================

local fmt_type, fmt_expr

fmt_type = function(node)
  if not node then return "?" end
  local k = node.kind
  if k == K.TYPE_BOOL   then return "Bool" end
  if k == K.TYPE_INT    then
    local lo, hi = node.min, node.max
    if lo ~= nil or hi ~= nil then
      return string.format("Int(%s, %s)",
        lo ~= nil and tostring(lo) or "",
        hi ~= nil and tostring(hi) or "")
    end
    return "Int"
  end
  if k == K.TYPE_FLOAT      then return "Float" end
  if k == K.TYPE_STRING     then return "String" end
  if k == K.TYPE_SYMBOL     then return "Symbol" end
  if k == K.TYPE_SYMBOL_OF  then
    return string.format("SymbolOf(%s)", node.family or "?")
  end
  if k == K.TYPE_NAMED      then return node.name or "?" end
  if k == K.TYPE_OPTION     then return "Option(" .. fmt_type(node.inner) .. ")" end
  if k == K.TYPE_SET then
    local mx = node.max ~= nil and (", " .. tostring(node.max)) or ""
    return "Set(" .. fmt_type(node.inner) .. mx .. ")"
  end
  if k == K.TYPE_LIST then
    local mx = node.max ~= nil and (", " .. tostring(node.max)) or ""
    return "List(" .. fmt_type(node.inner) .. mx .. ")"
  end
  if k == K.TYPE_ULIST then return "UList(" .. fmt_type(node.inner) .. ")" end
  if k == K.TYPE_UMAP then
    return string.format("UMap(%s, %s)",
      fmt_type(node.key or node.key_type),
      fmt_type(node.val or node.val_type))
  end
  if k == K.TYPE_ENUM_INLINE then
    return "Enum(" .. table.concat(node.values or {}, ", ") .. ")"
  end
  if k == K.TYPE_FN then
    local params = {}
    for _, p in ipairs(node.params or node.param_types or {}) do
      params[#params + 1] = fmt_type(p)
    end
    return "fn(" .. table.concat(params, ", ") .. ") -> "
                 .. fmt_type(node.ret or node.return_type)
  end
  return "?"
end

-- Compact, single-line rendering of an expression node.  Used for default
-- values, pre/post conditions, etc. — not for whole function bodies.
fmt_expr = function(node)
  if node == nil then return "" end
  if type(node) == "string" then return node end
  if type(node) ~= "table"  then return tostring(node) end
  local k = node.kind
  if k == K.INT_LIT     then return tostring(node.value) end
  if k == K.FLOAT_LIT   then
    local s = tostring(node.value)
    if not s:find("%.") and not s:find("e") then s = s .. ".0" end
    return s
  end
  if k == K.BOOL_LIT    then return node.value and "true" or "false" end
  if k == K.STRING_LIT  then return string.format("%q", node.value or "") end
  if k == K.MULTILINE_STRING then return '"""' .. (node.value or "") .. '"""' end
  if k == K.SYMBOL_LIT  then return "`" .. (node.name or "?") end
  if k == K.PATH_EXPR then
    local segs = {}
    for _, s in ipairs(node.segments or {}) do
      if type(s) == "string" then segs[#segs + 1] = s
      else segs[#segs + 1] = "{" .. fmt_expr(s) .. "}" end
    end
    return table.concat(segs, "/")
  end
  if k == K.INTERP_PATH then
    local segs = {}
    for _, s in ipairs(node.segments or {}) do
      if type(s) == "string" then
        segs[#segs + 1] = s
      elseif type(s) == "table" and s.interp then
        segs[#segs + 1] = "{" .. s.interp .. "}"
      else
        segs[#segs + 1] = "{" .. fmt_expr(s) .. "}"
      end
    end
    return table.concat(segs, "/")
  end
  if k == K.BINARY_OP then
    return string.format("(%s %s %s)",
      fmt_expr(node.left), node.op, fmt_expr(node.right))
  end
  if k == K.UNARY_OP then
    return string.format("(%s %s)", node.op, fmt_expr(node.operand or node.expr))
  end
  if k == K.NIL_COALESCE then
    return string.format("(%s ?? %s)", fmt_expr(node.left), fmt_expr(node.right))
  end
  if k == K.FN_CALL then
    if not node.args or #node.args == 0 then return node.name or "?" end
    local args = {}
    for _, a in ipairs(node.args) do args[#args + 1] = fmt_expr(a) end
    return (node.name or "?") .. " " .. table.concat(args, " ")
  end
  if k == K.NAMED_ARG then
    return (node.name or "?") .. ": " .. fmt_expr(node.value)
  end
  if k == K.EXPR_STMT  then return fmt_expr(node.expr) end
  if k == K.SET_LIT then
    local items = {}
    for _, v in ipairs(node.elements or {}) do items[#items + 1] = fmt_expr(v) end
    return "{" .. table.concat(items, ", ") .. "}"
  end
  if k == K.LIST_LIT then
    local items = {}
    for _, v in ipairs(node.elements or {}) do items[#items + 1] = fmt_expr(v) end
    return "[" .. table.concat(items, ", ") .. "]"
  end
  if k == K.EMPTY_SET  then return "(set)" end
  if k == K.EMPTY_LIST then return "[]"    end
  if k == K.EMPTY_MAP  then return "{}"    end
  if k == K.LAMBDA_EXPR then
    local ps = "(" .. table.concat(node.params or {}, ", ") .. ")"
    return "fn" .. ps .. ": ..."
  end
  return "<" .. tostring(k or "?") .. ">"
end

-- ============================================================
-- AST walking helpers
-- ============================================================

local function path_to_str(path_node)
  if not path_node then return "?" end
  if type(path_node) == "string" then return path_node end
  return fmt_expr(path_node)
end

--- Group top-level declarations by AST kind.
local function group_decls(typed_ast)
  local groups = {
    module     = nil,
    schema     = nil,
    engine     = nil,
    time_model = nil,
    imports    = {},
    types      = {},
    states     = {},
    relations  = {},
    fns        = {},
    scenes     = {},
    actors     = {},
    schedules  = {},
    bounded    = {},
    macros     = {},
    speakers   = {},
    grids      = {},
    hooks      = {},
    verifies   = {},
    tests      = {},
    migrations = {},
  }
  for _, d in ipairs(typed_ast.decls or {}) do
    local k = d.kind
    if     k == K.MODULE_DECL    then groups.module = d
    elseif k == K.SCHEMA_VERSION then groups.schema = d
    elseif k == K.ENGINE_CONFIG  then groups.engine = d
    elseif k == K.TIME_MODEL     then groups.time_model = d
    elseif k == K.IMPORT_DECL    then table.insert(groups.imports,  d)
    elseif k == K.TYPE_ENUM
        or k == K.TYPE_ALIAS
        or k == K.TYPE_RECORD
        or k == K.TYPE_VARIANT   then table.insert(groups.types,    d)
    elseif k == K.STATE_SCALAR
        or k == K.STATE_RECORD
        or k == K.STATE_FAMILY   then table.insert(groups.states,   d)
    elseif k == K.RELATION_DECL  then table.insert(groups.relations, d)
    elseif k == K.FN_DECL        then table.insert(groups.fns,       d)
    elseif k == K.SCENE_DECL     then table.insert(groups.scenes,    d)
    elseif k == K.ACTOR_DECL     then table.insert(groups.actors,    d)
    elseif k == K.SCHEDULE_DECL  then table.insert(groups.schedules, d)
    elseif k == K.BOUNDED_DECL   then table.insert(groups.bounded,   d)
    elseif k == K.MACRO_DECL     then table.insert(groups.macros,    d)
    elseif k == K.SPEAKER_DECL   then table.insert(groups.speakers,  d)
    elseif k == K.DEFGRID_DECL   then table.insert(groups.grids,     d)
    elseif k == K.HOOK_DECL      then table.insert(groups.hooks,     d)
    elseif k == K.VERIFY_DECL    then table.insert(groups.verifies,  d)
    elseif k == K.TEST_DECL      then table.insert(groups.tests,     d)
    elseif k == K.MIGRATION_DECL then table.insert(groups.migrations, d)
    end
  end
  -- Stable alphabetical order within each kind, by declaration name.
  local function name_of(d)
    if d.kind == K.STATE_FAMILY then return d.family or "?" end
    if d.path then return path_to_str(d.path) end
    return d.name or "?"
  end
  for _, key in ipairs({"types", "states", "relations", "fns", "scenes",
                        "actors", "schedules", "bounded", "macros",
                        "speakers", "grids", "hooks", "verifies"}) do
    table.sort(groups[key], function(a, b) return name_of(a) < name_of(b) end)
  end
  return groups
end

--- Walk a scene body collecting outgoing scene names (goto / enter targets).
--- Used to build a static scene graph.  Computed gotos (target = expression)
--- are recorded as "<dynamic>".
local function scene_outgoing(scene_decl)
  local out = {}
  local seen = {}
  local function add(name)
    if name and not seen[name] then
      seen[name] = true; out[#out + 1] = name
    end
  end
  local function walk(node)
    if type(node) ~= "table" then return end
    if node.kind == K.GOTO_SCENE_MUT
       or node.kind == K.ENTER_SCENE_MUT
       or node.kind == "scene_goto"
       or node.kind == "scene_enter" then
      local t = node.target
      if type(t) == "string" then add(t)
      elseif type(t) == "table" then add("<dynamic>") end
      return
    end
    for _, v in pairs(node) do
      if type(v) == "table" then walk(v) end
    end
  end
  walk(scene_decl.body or {})
  return out
end

-- ============================================================
-- HTML rendering
-- ============================================================

local function escape_html(s)
  if s == nil then return "" end
  s = tostring(s)
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
       :gsub('"', "&quot;")
  return s
end

local STYLE_CSS = [[
* { box-sizing: border-box; }
body { font-family: -apple-system, "Segoe UI", system-ui, sans-serif;
       margin: 0; padding: 0; color: #1f2933; background: #f5f7fa; }
.layout { display: flex; min-height: 100vh; }
nav.sidebar { width: 240px; background: #1f2933; color: #d9e2ec;
              padding: 1.5rem 1rem; position: sticky; top: 0; height: 100vh;
              overflow-y: auto; }
nav.sidebar h1 { font-size: 1rem; margin: 0 0 1rem 0;
                 color: #f5f7fa; letter-spacing: 0.04em; text-transform: uppercase; }
nav.sidebar h2 { font-size: 0.75rem; margin: 1.25rem 0 0.25rem 0;
                 color: #9aa5b1; letter-spacing: 0.06em; text-transform: uppercase; }
nav.sidebar a { display: block; padding: 0.25rem 0.5rem; margin: 0 -0.5rem;
                color: #d9e2ec; text-decoration: none; border-radius: 4px;
                font-size: 0.9rem; }
nav.sidebar a:hover    { background: #323f4b; }
nav.sidebar a.current  { background: #486581; color: #fff; }
nav.sidebar .count { float: right; color: #829ab1; font-size: 0.8rem; }
main { flex: 1; padding: 2rem 3rem; max-width: 60rem; }
h1.page  { font-size: 1.75rem; margin-top: 0; color: #102a43; }
h2.entry { font-size: 1.15rem; margin: 1.75rem 0 0.25rem 0;
           color: #243b53; border-bottom: 1px solid #d9e2ec; padding-bottom: 0.25rem; }
.meta    { color: #627d98; font-size: 0.9rem; margin: 0.25rem 0 0.5rem 0; }
.doc     { margin: 0.5rem 0 0.75rem 0; }
.sig     { font-family: "JetBrains Mono", "SF Mono", Consolas, monospace;
           background: #f0f4f8; padding: 0.5rem 0.75rem;
           border-radius: 4px; border-left: 3px solid #486581;
           font-size: 0.9rem; overflow-x: auto; white-space: pre; }
pre.body { font-family: "JetBrains Mono", "SF Mono", Consolas, monospace;
           background: #1f2933; color: #d9e2ec; padding: 0.75rem 1rem;
           border-radius: 4px; font-size: 0.85rem; overflow-x: auto; }
table.fields { border-collapse: collapse; margin: 0.5rem 0; font-size: 0.9rem; }
table.fields td { padding: 0.2rem 0.75rem 0.2rem 0; vertical-align: top; }
table.fields .fname { font-family: monospace; color: #102a43; }
table.fields .ftype { font-family: monospace; color: #335f88; }
table.fields .fdoc  { color: #627d98; font-style: italic; }
.tag      { display: inline-block; padding: 0.05rem 0.4rem; margin-right: 0.25rem;
            background: #bcccdc; color: #243b53; font-size: 0.75rem;
            border-radius: 3px; font-family: monospace; }
.tag-pure { background: #b3e5d1; color: #1b4332; }
.summary  { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
            gap: 0.75rem; margin: 1rem 0 2rem 0; }
.summary .card { background: #fff; padding: 0.75rem; border-radius: 6px;
                 border: 1px solid #d9e2ec; }
.summary .card .label { color: #627d98; font-size: 0.8rem;
                        text-transform: uppercase; letter-spacing: 0.04em; }
.summary .card .value { color: #102a43; font-size: 1.5rem; font-weight: 600; }
.empty   { color: #829ab1; font-style: italic; }
a.scene-link { color: #486581; text-decoration: none; }
a.scene-link:hover { text-decoration: underline; }
ul.scene-graph { padding-left: 1.25rem; }
ul.scene-graph li { margin: 0.25rem 0; }
.footer { color: #829ab1; font-size: 0.85rem; margin-top: 3rem;
          padding-top: 1rem; border-top: 1px solid #d9e2ec; }
]]

-- ============================================================
-- Page-builder helpers
-- ============================================================

local function html_doc_para(doc)
  if not doc or doc == "" then return "" end
  return '<p class="doc">' .. escape_html(doc) .. "</p>\n"
end

local function html_sig(s)
  return '<div class="sig">' .. escape_html(s) .. "</div>\n"
end

local function html_anchor(name)
  return (name or ""):gsub("[^%w%-]", "-")
end

-- Sidebar definition shared across HTML pages.
local SIDEBAR_PAGES = {
  { file = "index.html",     label = "Overview" },
  { file = "types.html",     label = "Types",      key = "types" },
  { file = "state.html",     label = "State",      key = "states" },
  { file = "relations.html", label = "Relations",  key = "relations" },
  { file = "fns.html",       label = "Functions",  key = "fns" },
  { file = "scenes.html",    label = "Scenes",     key = "scenes" },
  { file = "actors.html",    label = "Actors",     key = "actors" },
  { file = "schedules.html", label = "Schedules",  key = "schedules" },
  { file = "bounded.html",   label = "Bounded",    key = "bounded" },
  { file = "macros.html",    label = "Macros",     key = "macros" },
  { file = "speakers.html",  label = "Speakers",   key = "speakers" },
  { file = "grids.html",     label = "Grids",      key = "grids" },
  { file = "hooks.html",     label = "Hooks",      key = "hooks" },
  { file = "verifies.html",  label = "Verify",     key = "verifies" },
}

local function sidebar_html(groups, current_file, title)
  local parts = { '<nav class="sidebar">\n' }
  parts[#parts + 1] = '<h1>' .. escape_html(title or "StoryBase") .. '</h1>\n'
  for _, p in ipairs(SIDEBAR_PAGES) do
    local count_str = ""
    if p.key then
      local entries = groups[p.key]
      if type(entries) == "table" then
        count_str = string.format(' <span class="count">%d</span>', #entries)
      end
    end
    local cls = (p.file == current_file) and ' class="current"' or ""
    parts[#parts + 1] = string.format('<a href="%s"%s>%s%s</a>\n',
      p.file, cls, escape_html(p.label), count_str)
  end
  parts[#parts + 1] = '</nav>\n'
  return table.concat(parts)
end

local function html_page(title, sidebar, body)
  return table.concat({
    "<!DOCTYPE html>\n",
    '<html lang="en"><head><meta charset="utf-8">',
    "<title>", escape_html(title), "</title>\n",
    '<link rel="stylesheet" href="style.css"></head>\n',
    "<body><div class=\"layout\">\n",
    sidebar,
    "<main>\n", body, "\n",
    '<div class="footer">Generated by <code>storybase docs</code>.</div>\n',
    "</main></div></body></html>\n",
  })
end

-- ============================================================
-- Per-kind HTML body renderers
-- ============================================================

local function render_index(groups, filename)
  local parts = { '<h1 class="page">' }
  local mod = groups.module
  if mod and mod.name then
    parts[#parts + 1] = escape_html(mod.name)
    if mod.version then
      parts[#parts + 1] = ' <span class="meta">v' ..
                          escape_html(tostring(mod.version)) .. "</span>"
    end
  else
    parts[#parts + 1] = escape_html(filename or "Game")
  end
  parts[#parts + 1] = "</h1>\n"
  parts[#parts + 1] = '<p class="meta">Source: <code>' ..
                      escape_html(filename or "?") .. "</code></p>\n"

  -- Summary cards
  parts[#parts + 1] = '<div class="summary">\n'
  local counts = {
    { "Types",     #groups.types },
    { "State",     #groups.states },
    { "Relations", #groups.relations },
    { "Functions", #groups.fns },
    { "Scenes",    #groups.scenes },
    { "Actors",    #groups.actors },
    { "Schedules", #groups.schedules },
    { "Bounded",   #groups.bounded },
    { "Macros",    #groups.macros },
    { "Verify",    #groups.verifies },
  }
  for _, c in ipairs(counts) do
    parts[#parts + 1] = string.format(
      '<div class="card"><div class="label">%s</div>'
      .. '<div class="value">%d</div></div>\n',
      escape_html(c[1]), c[2])
  end
  parts[#parts + 1] = "</div>\n"

  if groups.engine and groups.engine.keys then
    parts[#parts + 1] = "<h2>Engine configuration</h2>\n"
    parts[#parts + 1] = '<table class="fields">\n'
    for _, kv in ipairs(groups.engine.keys) do
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">%s</td><td class="ftype">%s</td></tr>\n',
        escape_html(kv.key or "?"), escape_html(fmt_expr(kv.value)))
    end
    parts[#parts + 1] = "</table>\n"
  end

  if groups.schema and groups.schema.version then
    parts[#parts + 1] = "<h2>Schema</h2>\n"
    parts[#parts + 1] = "<p>Schema version: <code>" ..
                        escape_html(tostring(groups.schema.version)) ..
                        "</code></p>\n"
  end

  if groups.time_model then
    parts[#parts + 1] = "<h2>Time model</h2>\n"
    local axes = table.concat(groups.time_model.axes or {}, ", ")
    parts[#parts + 1] = "<p>Axes: <code>" .. escape_html(axes) .. "</code></p>\n"
  end

  if #groups.imports > 0 then
    parts[#parts + 1] = "<h2>Imports</h2>\n<ul>\n"
    for _, imp in ipairs(groups.imports) do
      local alias = imp.alias and (" <em>as " .. escape_html(imp.alias) .. "</em>") or ""
      parts[#parts + 1] = "<li><code>" .. escape_html(imp.path or "?") ..
                          "</code>" .. alias .. "</li>\n"
    end
    parts[#parts + 1] = "</ul>\n"
  end

  return table.concat(parts)
end

local function render_types(groups)
  local parts = { '<h1 class="page">Types</h1>\n' }
  if #groups.types == 0 then
    parts[#parts + 1] = '<p class="empty">No types declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.types) do
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"))
    if d.kind == K.TYPE_ENUM then
      parts[#parts + 1] = html_sig(
        "type " .. (d.name or "?") .. " = " ..
        table.concat(d.values or {}, " | "))
    elseif d.kind == K.TYPE_ALIAS then
      parts[#parts + 1] = html_sig(
        "type " .. (d.name or "?") .. " = " .. fmt_type(d.type_expr))
    elseif d.kind == K.TYPE_RECORD then
      parts[#parts + 1] = html_sig("type " .. (d.name or "?") .. ":")
      if d.fields and #d.fields > 0 then
        parts[#parts + 1] = '<table class="fields">\n'
        for _, f in ipairs(d.fields) do
          if f.kind == K.WITH_MIXIN then
            parts[#parts + 1] = string.format(
              '<tr><td class="fname">with %s</td><td></td><td></td></tr>\n',
              escape_html(f.type_name or "?"))
          else
            local def = (f.default ~= nil) and (" = " .. fmt_expr(f.default)) or ""
            parts[#parts + 1] = string.format(
              '<tr><td class="fname">%s</td>'
              .. '<td class="ftype">%s%s</td>'
              .. '<td class="fdoc">%s</td></tr>\n',
              escape_html(f.name or "?"),
              escape_html(fmt_type(f.type_expr)), escape_html(def),
              escape_html(f.doc or ""))
          end
        end
        parts[#parts + 1] = "</table>\n"
      end
    elseif d.kind == K.TYPE_VARIANT then
      parts[#parts + 1] = html_sig("type " .. (d.name or "?") .. ":")
      for _, br in ipairs(d.branches or {}) do
        local field_strs = {}
        for _, f in ipairs(br.fields or {}) do
          field_strs[#field_strs + 1] = (f.name or "?") ..
            ": " .. fmt_type(f.type_expr)
        end
        local suffix = (#field_strs > 0) and (" " .. table.concat(field_strs, " ")) or ""
        parts[#parts + 1] = string.format(
          '<div class="sig">| %s:%s</div>\n',
          escape_html(br.name or "?"), escape_html(suffix))
      end
    end
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function state_decl_str(d)
  if d.kind == K.STATE_SCALAR then
    local path = path_to_str(d.path)
    local s = "state " .. path .. ": " .. fmt_type(d.type_expr)
    if d.default ~= nil then s = s .. " = " .. fmt_expr(d.default) end
    return s
  elseif d.kind == K.STATE_RECORD then
    return "state " .. path_to_str(d.path) .. ":"
  elseif d.kind == K.STATE_FAMILY then
    local p = (d.family or "?") .. "/{" .. (d.var or "k") .. "}"
    local s = "state " .. p .. ": " .. fmt_type(d.type_expr)
    if d.max ~= nil then s = s .. "  max: " .. tostring(d.max) end
    return s
  end
  return "state ?"
end

local function render_states(groups)
  local parts = { '<h1 class="page">State</h1>\n' }
  if #groups.states == 0 then
    parts[#parts + 1] = '<p class="empty">No state declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.states) do
    local name
    if d.kind == K.STATE_FAMILY then
      name = (d.family or "?") .. "/{" .. (d.var or "k") .. "}"
    else
      name = path_to_str(d.path)
    end
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(name), escape_html(name))
    parts[#parts + 1] = html_sig(state_decl_str(d))
    if d.kind == K.STATE_RECORD and d.fields and #d.fields > 0 then
      parts[#parts + 1] = '<table class="fields">\n'
      for _, f in ipairs(d.fields) do
        local def = (f.default ~= nil) and (" = " .. fmt_expr(f.default)) or ""
        parts[#parts + 1] = string.format(
          '<tr><td class="fname">%s</td>'
          .. '<td class="ftype">%s%s</td>'
          .. '<td class="fdoc">%s</td></tr>\n',
          escape_html(f.name or "?"),
          escape_html(fmt_type(f.type_expr)), escape_html(def),
          escape_html(f.doc or ""))
      end
      parts[#parts + 1] = "</table>\n"
    end
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function render_relations(groups)
  local parts = { '<h1 class="page">Relations</h1>\n' }
  if #groups.relations == 0 then
    parts[#parts + 1] = '<p class="empty">No relations declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.relations) do
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"))
    parts[#parts + 1] = html_sig(string.format(
      "relation %s: %s -> %s",
      d.name or "?", d.from_type or "?", fmt_type(d.to_type_expr)))
    if d.initial_data and #d.initial_data > 0 then
      parts[#parts + 1] = '<p class="meta">Initial edges:</p>\n<ul>\n'
      for _, e in ipairs(d.initial_data) do
        local kname = (e.key and e.key.kind == K.SYMBOL_LIT)
                      and ("`" .. (e.key.name or "?"))
                      or (e.key and e.key.name or "?")
        local vs = {}
        for _, v in ipairs(e.values or {}) do
          vs[#vs + 1] = (v.kind == K.SYMBOL_LIT)
                        and ("`" .. (v.name or "?"))
                        or (v.name or "?")
        end
        parts[#parts + 1] = string.format(
          '<li><code>%s</code> &rarr; {%s}</li>\n',
          escape_html(kname), escape_html(table.concat(vs, ", ")))
      end
      parts[#parts + 1] = "</ul>\n"
    end
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function fn_signature(d)
  local params = {}
  for _, p in ipairs(d.params or {}) do
    params[#params + 1] = type(p) == "string" and p or (p.name or "?")
  end
  local sig = "fn " .. (d.name or "?")
  if #params > 0 then sig = sig .. " " .. table.concat(params, " ") end
  return sig
end

local function fmt_cond_list(list)
  if not list or #list == 0 then return nil end
  local strs = {}
  for _, c in ipairs(list) do strs[#strs + 1] = fmt_expr(c) end
  return strs
end

local function render_fns(groups)
  local parts = { '<h1 class="page">Functions</h1>\n' }
  if #groups.fns == 0 then
    parts[#parts + 1] = '<p class="empty">No functions declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.fns) do
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"))
    -- Tag row: pure + user tags
    local tags = {}
    if d.pure then
      tags[#tags + 1] = '<span class="tag tag-pure">pure</span>'
    end
    for _, t in ipairs(d.tags or {}) do
      tags[#tags + 1] = '<span class="tag">' .. escape_html(t) .. "</span>"
    end
    if #tags > 0 then
      parts[#parts + 1] = '<div class="meta">' .. table.concat(tags) .. "</div>\n"
    end
    parts[#parts + 1] = html_sig(fn_signature(d))
    local pre  = fmt_cond_list(d.pre)
    local post = fmt_cond_list(d.post)
    if pre then
      parts[#parts + 1] = "<p><strong>Pre:</strong></p>\n<ul>\n"
      for _, s in ipairs(pre) do
        parts[#parts + 1] = "<li><code>" .. escape_html(s) .. "</code></li>\n"
      end
      parts[#parts + 1] = "</ul>\n"
    end
    if post then
      parts[#parts + 1] = "<p><strong>Post:</strong></p>\n<ul>\n"
      for _, s in ipairs(post) do
        parts[#parts + 1] = "<li><code>" .. escape_html(s) .. "</code></li>\n"
      end
      parts[#parts + 1] = "</ul>\n"
    end
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function render_scenes(groups)
  local parts = { '<h1 class="page">Scenes</h1>\n' }
  if #groups.scenes == 0 then
    parts[#parts + 1] = '<p class="empty">No scenes declared.</p>\n'
    return table.concat(parts)
  end
  -- Scene graph (static)
  parts[#parts + 1] = "<h2>Scene graph</h2>\n"
  local entry = nil
  if groups.engine and groups.engine.keys then
    for _, kv in ipairs(groups.engine.keys) do
      if kv.key == "entry-scene" then entry = fmt_expr(kv.value) end
    end
  end
  if entry then
    parts[#parts + 1] = '<p class="meta">Entry: <code>' ..
                        escape_html(entry) .. "</code></p>\n"
  end
  parts[#parts + 1] = '<ul class="scene-graph">\n'
  for _, d in ipairs(groups.scenes) do
    local outs = scene_outgoing(d)
    local out_str
    if #outs == 0 then
      out_str = '<span class="meta">terminal</span>'
    else
      local pieces = {}
      for _, n in ipairs(outs) do
        if n == "<dynamic>" then
          pieces[#pieces + 1] = '<em>&lt;dynamic&gt;</em>'
        else
          pieces[#pieces + 1] = string.format('<a class="scene-link" href="#%s">%s</a>',
            html_anchor(n), escape_html(n))
        end
      end
      out_str = table.concat(pieces, ", ")
    end
    parts[#parts + 1] = string.format(
      '<li><a class="scene-link" href="#%s"><code>%s</code></a> &rarr; %s</li>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"), out_str)
  end
  parts[#parts + 1] = "</ul>\n"
  -- Per-scene blocks
  for _, d in ipairs(groups.scenes) do
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"))
    parts[#parts + 1] = html_doc_para(d.doc)
    local outs = scene_outgoing(d)
    if #outs > 0 then
      local pieces = {}
      for _, n in ipairs(outs) do pieces[#pieces + 1] = "<code>" .. escape_html(n) .. "</code>" end
      parts[#parts + 1] = '<p class="meta">Goes to: ' .. table.concat(pieces, ", ") .. "</p>\n"
    end
  end
  return table.concat(parts)
end

local function render_actors(groups)
  local parts = { '<h1 class="page">Actors</h1>\n' }
  if #groups.actors == 0 then
    parts[#parts + 1] = '<p class="empty">No actors declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.actors) do
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"))
    parts[#parts + 1] = html_sig("actor " .. (d.name or "?"))
    parts[#parts + 1] = '<table class="fields">\n'
    if d.state_path then
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">state</td><td class="ftype">%s</td></tr>\n',
        escape_html(path_to_str(d.state_path)))
    end
    parts[#parts + 1] = string.format(
      '<tr><td class="fname">priority</td><td class="ftype">%s</td></tr>\n',
      escape_html(tostring(d.priority or 0)))
    if d.perceives then
      local pcs = {}
      for _, p in ipairs(d.perceives) do
        pcs[#pcs + 1] = fmt_expr(p)
      end
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">perceives</td><td class="ftype">[%s]</td></tr>\n',
        escape_html(table.concat(pcs, ", ")))
    end
    if d.inbox_type then
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">inbox</td><td class="ftype">%s</td></tr>\n',
        escape_html(fmt_type(d.inbox_type)))
    end
    if d.behavior then
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">behavior</td><td class="ftype">%s</td></tr>\n',
        escape_html(tostring(d.behavior)))
    end
    parts[#parts + 1] = "</table>\n"
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function fmt_axes_table(axes)
  if not axes or #axes == 0 then return "" end
  local s = {}
  for _, a in ipairs(axes) do
    s[#s + 1] = (a.axis or a.name or "?") .. ": " ..
                tostring(a.value ~= nil and a.value or "?")
  end
  return "[" .. table.concat(s, ", ") .. "]"
end

local function render_schedules(groups)
  local parts = { '<h1 class="page">Schedules</h1>\n' }
  if #groups.schedules == 0 then
    parts[#parts + 1] = '<p class="empty">No schedules declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.schedules) do
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"))
    parts[#parts + 1] = html_sig("schedule " .. (d.name or "?"))
    parts[#parts + 1] = '<table class="fields">\n'
    local trig = d.trigger or {}
    if trig.every then
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">every</td><td class="ftype">%s</td></tr>\n',
        escape_html(fmt_axes_table(trig.every)))
    end
    if trig.at then
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">at</td><td class="ftype">%s</td></tr>\n',
        escape_html(fmt_axes_table(trig.at)))
    end
    if trig.offset then
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">offset</td><td class="ftype">%s</td></tr>\n',
        escape_html(fmt_axes_table(trig.offset)))
    end
    parts[#parts + 1] = "</table>\n"
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function render_bounded(groups)
  local parts = { '<h1 class="page">Bounded</h1>\n' }
  if #groups.bounded == 0 then
    parts[#parts + 1] = '<p class="empty">No bounded computations declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.bounded) do
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"))
    local params = {}
    for _, p in ipairs(d.params or {}) do
      params[#params + 1] = type(p) == "string" and p or (p.name or "?")
    end
    local sig = "bounded " .. (d.name or "?")
    if #params > 0 then sig = sig .. " " .. table.concat(params, " ") end
    parts[#parts + 1] = html_sig(sig)
    parts[#parts + 1] = '<table class="fields">\n'
    parts[#parts + 1] = string.format(
      '<tr><td class="fname">returns</td><td class="ftype">%s</td></tr>\n',
      escape_html(fmt_type(d.returns_type)))
    if d.distribution then
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">distribution</td><td class="ftype">%s</td></tr>\n',
        escape_html(fmt_expr(d.distribution)))
    end
    if d.lua_name then
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">lua</td><td class="ftype">%s</td></tr>\n',
        escape_html(tostring(d.lua_name)))
    end
    if d.reads and #d.reads > 0 then
      local rs = {}
      for _, r in ipairs(d.reads) do rs[#rs + 1] = fmt_expr(r) end
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">reads</td><td class="ftype">[%s]</td></tr>\n',
        escape_html(table.concat(rs, ", ")))
    end
    parts[#parts + 1] = "</table>\n"
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function render_macros(groups)
  local parts = { '<h1 class="page">Macros</h1>\n' }
  if #groups.macros == 0 then
    parts[#parts + 1] = '<p class="empty">No macros declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.macros) do
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"))
    local params = {}
    for _, p in ipairs(d.params or {}) do
      params[#params + 1] = type(p) == "string" and p or (p.name or "?")
    end
    local sig = "macro " .. (d.name or "?")
    if #params > 0 then sig = sig .. " " .. table.concat(params, " ") end
    parts[#parts + 1] = html_sig(sig)
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function render_speakers(groups)
  local parts = { '<h1 class="page">Speakers</h1>\n' }
  if #groups.speakers == 0 then
    parts[#parts + 1] = '<p class="empty">No speakers declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.speakers) do
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"))
    parts[#parts + 1] = '<table class="fields">\n'
    if d.display then
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">display</td><td class="ftype">%s</td></tr>\n',
        escape_html(tostring(d.display)))
    end
    if d.color then
      parts[#parts + 1] = string.format(
        '<tr><td class="fname">color</td><td class="ftype">'
        .. '<span style="display:inline-block;width:0.8rem;height:0.8rem;'
        .. 'background:%s;border:1px solid #d9e2ec;vertical-align:middle;'
        .. 'margin-right:0.25rem;"></span>%s</td></tr>\n',
        escape_html(d.color), escape_html(d.color))
    end
    parts[#parts + 1] = "</table>\n"
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function render_grids(groups)
  local parts = { '<h1 class="page">Tile Grids</h1>\n' }
  if #groups.grids == 0 then
    parts[#parts + 1] = '<p class="empty">No tile grids declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.grids) do
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(d.name or "?"), escape_html(d.name or "?"))
    parts[#parts + 1] = html_sig(string.format(
      "defgrid %s  %sx%s  cell: %s%s",
      d.name or "?",
      tostring(d.width or "?"), tostring(d.height or "?"),
      tostring(d.cell_type or "?"),
      d.default_val and ("  default: `" .. tostring(d.default_val)) or ""))
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function render_hooks(groups)
  local parts = { '<h1 class="page">Hooks</h1>\n' }
  if #groups.hooks == 0 then
    parts[#parts + 1] = '<p class="empty">No hooks declared.</p>\n'
    return table.concat(parts)
  end
  for _, d in ipairs(groups.hooks) do
    local label = (d.hook_kind or "?") .. " " .. tostring(d.target or "?")
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(label), escape_html(label))
    parts[#parts + 1] = html_sig("hook " .. label)
    parts[#parts + 1] = html_doc_para(d.doc)
  end
  return table.concat(parts)
end

local function render_verifies(groups)
  local parts = { '<h1 class="page">Verify</h1>\n' }
  if #groups.verifies == 0 then
    parts[#parts + 1] = '<p class="empty">No verify blocks declared.</p>\n'
    return table.concat(parts)
  end
  parts[#parts + 1] = '<p class="meta">Static listing — run <code>storybase verify</code> '
                      .. 'for pass/fail status.</p>\n'
  for i, d in ipairs(groups.verifies) do
    local label = d.label or ("verify #" .. tostring(i))
    parts[#parts + 1] = string.format(
      '<h2 class="entry" id="%s">%s</h2>\n',
      html_anchor(label), escape_html(label))
    if d.clauses and #d.clauses > 0 then
      parts[#parts + 1] = "<ul>\n"
      for _, c in ipairs(d.clauses) do
        local kind = c.clause_kind or "?"
        local cond = c.condition and fmt_expr(c.condition) or ""
        parts[#parts + 1] = string.format(
          '<li><code>%s</code> %s</li>\n',
          escape_html(kind), escape_html(cond))
      end
      parts[#parts + 1] = "</ul>\n"
    end
  end
  return table.concat(parts)
end

-- ============================================================
-- Markdown rendering (single-file)
-- ============================================================

local function md_section(title, lines, depth)
  local prefix = string.rep("#", depth or 2)
  return prefix .. " " .. title .. "\n\n" .. table.concat(lines or {}, "\n")
end

local function md_doc(doc)
  if not doc or doc == "" then return "" end
  return "\n> " .. tostring(doc):gsub("\n", "\n> ") .. "\n"
end

local function render_markdown(groups, filename)
  local out = {}
  local mod = groups.module
  local title = (mod and mod.name) or filename or "Game"
  out[#out + 1] = "# " .. tostring(title)
  if mod and mod.version then
    out[#out + 1] = "\n_Version " .. tostring(mod.version) .. "_"
  end
  out[#out + 1] = "\n_Source: `" .. tostring(filename or "?") .. "`_\n"

  -- Counts table
  out[#out + 1] = "\n## Summary\n"
  out[#out + 1] = "| Kind | Count |"
  out[#out + 1] = "|------|-------|"
  local counts = {
    { "Types",     #groups.types },
    { "State",     #groups.states },
    { "Relations", #groups.relations },
    { "Functions", #groups.fns },
    { "Scenes",    #groups.scenes },
    { "Actors",    #groups.actors },
    { "Schedules", #groups.schedules },
    { "Bounded",   #groups.bounded },
    { "Macros",    #groups.macros },
    { "Speakers",  #groups.speakers },
    { "Grids",     #groups.grids },
    { "Hooks",     #groups.hooks },
    { "Verify",    #groups.verifies },
  }
  for _, c in ipairs(counts) do
    out[#out + 1] = string.format("| %s | %d |", c[1], c[2])
  end
  out[#out + 1] = ""

  if groups.engine and groups.engine.keys then
    out[#out + 1] = "## Engine configuration\n"
    for _, kv in ipairs(groups.engine.keys) do
      out[#out + 1] = string.format("- `%s` = `%s`", kv.key or "?", fmt_expr(kv.value))
    end
    out[#out + 1] = ""
  end

  local function section(label, list, render_one)
    if not list or #list == 0 then return end
    out[#out + 1] = "## " .. label .. "\n"
    for _, d in ipairs(list) do
      render_one(d)
    end
  end

  section("Types", groups.types, function(d)
    out[#out + 1] = "### `" .. (d.name or "?") .. "`"
    if d.kind == K.TYPE_ENUM then
      out[#out + 1] = "```"
      out[#out + 1] = "type " .. (d.name or "?") .. " = " .. table.concat(d.values or {}, " | ")
      out[#out + 1] = "```"
    elseif d.kind == K.TYPE_ALIAS then
      out[#out + 1] = "```"
      out[#out + 1] = "type " .. (d.name or "?") .. " = " .. fmt_type(d.type_expr)
      out[#out + 1] = "```"
    elseif d.kind == K.TYPE_RECORD then
      out[#out + 1] = "```"
      out[#out + 1] = "type " .. (d.name or "?") .. ":"
      for _, f in ipairs(d.fields or {}) do
        if f.kind == K.WITH_MIXIN then
          out[#out + 1] = "  with " .. (f.type_name or "?")
        else
          local def = (f.default ~= nil) and (" = " .. fmt_expr(f.default)) or ""
          out[#out + 1] = "  " .. (f.name or "?") .. ": "
            .. fmt_type(f.type_expr) .. def
        end
      end
      out[#out + 1] = "```"
    elseif d.kind == K.TYPE_VARIANT then
      out[#out + 1] = "```"
      out[#out + 1] = "type " .. (d.name or "?") .. ":"
      for _, br in ipairs(d.branches or {}) do
        local fs = {}
        for _, f in ipairs(br.fields or {}) do
          fs[#fs + 1] = (f.name or "?") .. ": " .. fmt_type(f.type_expr)
        end
        local suffix = (#fs > 0) and (" " .. table.concat(fs, " ")) or ""
        out[#out + 1] = "  | " .. (br.name or "?") .. ":" .. suffix
      end
      out[#out + 1] = "```"
    end
    out[#out + 1] = md_doc(d.doc)
  end)

  section("State", groups.states, function(d)
    local name
    if d.kind == K.STATE_FAMILY then
      name = (d.family or "?") .. "/{" .. (d.var or "k") .. "}"
    else
      name = path_to_str(d.path)
    end
    out[#out + 1] = "### `" .. name .. "`"
    out[#out + 1] = "```"
    out[#out + 1] = state_decl_str(d)
    if d.kind == K.STATE_RECORD and d.fields and #d.fields > 0 then
      for _, f in ipairs(d.fields) do
        local def = (f.default ~= nil) and (" = " .. fmt_expr(f.default)) or ""
        out[#out + 1] = "  " .. (f.name or "?") .. ": "
                        .. fmt_type(f.type_expr) .. def
      end
    end
    out[#out + 1] = "```"
    out[#out + 1] = md_doc(d.doc)
  end)

  section("Relations", groups.relations, function(d)
    out[#out + 1] = "### `" .. (d.name or "?") .. "`"
    out[#out + 1] = "```"
    out[#out + 1] = string.format("relation %s: %s -> %s",
      d.name or "?", d.from_type or "?", fmt_type(d.to_type_expr))
    out[#out + 1] = "```"
    out[#out + 1] = md_doc(d.doc)
  end)

  section("Functions", groups.fns, function(d)
    out[#out + 1] = "### `" .. (d.name or "?") .. "`"
    local tagbits = {}
    if d.pure then tagbits[#tagbits + 1] = "pure" end
    for _, t in ipairs(d.tags or {}) do tagbits[#tagbits + 1] = t end
    if #tagbits > 0 then
      out[#out + 1] = "_tags: " .. table.concat(tagbits, ", ") .. "_"
    end
    out[#out + 1] = "```"
    out[#out + 1] = fn_signature(d)
    out[#out + 1] = "```"
    local pre  = fmt_cond_list(d.pre)
    local post = fmt_cond_list(d.post)
    if pre then
      out[#out + 1] = "Pre:"
      for _, s in ipairs(pre) do out[#out + 1] = "- `" .. s .. "`" end
    end
    if post then
      out[#out + 1] = "Post:"
      for _, s in ipairs(post) do out[#out + 1] = "- `" .. s .. "`" end
    end
    out[#out + 1] = md_doc(d.doc)
  end)

  section("Scenes", groups.scenes, function(d)
    out[#out + 1] = "### `" .. (d.name or "?") .. "`"
    local outs = scene_outgoing(d)
    if #outs > 0 then
      out[#out + 1] = "_Goes to: " .. table.concat(outs, ", ") .. "_"
    end
    out[#out + 1] = md_doc(d.doc)
  end)

  section("Actors", groups.actors, function(d)
    out[#out + 1] = "### `" .. (d.name or "?") .. "`"
    out[#out + 1] = "- state: `" .. path_to_str(d.state_path) .. "`"
    out[#out + 1] = "- priority: " .. tostring(d.priority or 0)
    if d.perceives then
      local pcs = {}
      for _, p in ipairs(d.perceives) do pcs[#pcs + 1] = fmt_expr(p) end
      out[#out + 1] = "- perceives: [" .. table.concat(pcs, ", ") .. "]"
    end
    out[#out + 1] = md_doc(d.doc)
  end)

  section("Schedules", groups.schedules, function(d)
    out[#out + 1] = "### `" .. (d.name or "?") .. "`"
    local trig = d.trigger or {}
    if trig.every  then out[#out + 1] = "- every: " .. fmt_axes_table(trig.every) end
    if trig.at     then out[#out + 1] = "- at: "    .. fmt_axes_table(trig.at) end
    if trig.offset then out[#out + 1] = "- offset: " .. fmt_axes_table(trig.offset) end
    out[#out + 1] = md_doc(d.doc)
  end)

  section("Bounded", groups.bounded, function(d)
    out[#out + 1] = "### `" .. (d.name or "?") .. "`"
    out[#out + 1] = "- returns: `" .. fmt_type(d.returns_type) .. "`"
    if d.distribution then out[#out + 1] = "- distribution: `" .. fmt_expr(d.distribution) .. "`" end
    if d.lua_name then out[#out + 1] = "- lua: `" .. tostring(d.lua_name) .. "`" end
    out[#out + 1] = md_doc(d.doc)
  end)

  section("Macros",   groups.macros,   function(d)
    out[#out + 1] = "### `" .. (d.name or "?") .. "`"
    out[#out + 1] = md_doc(d.doc)
  end)

  section("Speakers", groups.speakers, function(d)
    out[#out + 1] = "### `" .. (d.name or "?") .. "`"
    if d.display then out[#out + 1] = "- display: " .. tostring(d.display) end
    if d.color   then out[#out + 1] = "- color: `" .. tostring(d.color) .. "`" end
    out[#out + 1] = md_doc(d.doc)
  end)

  section("Tile Grids", groups.grids, function(d)
    out[#out + 1] = "### `" .. (d.name or "?") .. "`"
    out[#out + 1] = string.format("- %sx%s, cell: `%s`",
      tostring(d.width or "?"), tostring(d.height or "?"),
      tostring(d.cell_type or "?"))
    out[#out + 1] = md_doc(d.doc)
  end)

  section("Verify", groups.verifies, function(d)
    local label = d.label or "(unnamed)"
    out[#out + 1] = "### `" .. label .. "`"
    for _, c in ipairs(d.clauses or {}) do
      local cond = c.condition and fmt_expr(c.condition) or ""
      out[#out + 1] = "- `" .. (c.clause_kind or "?") .. "` " .. cond
    end
  end)

  return table.concat(out, "\n") .. "\n"
end

-- ============================================================
-- Filesystem helpers
-- ============================================================

local function write_file(path, contents)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(contents)
  f:close()
  return true
end

local function ensure_dir(dir)
  -- Try mkdir -p; fall back to nothing.  If it fails, we'll fail at the
  -- first file write with a clearer error.
  os.execute("mkdir -p " .. string.format("%q", dir) .. " 2>/dev/null")
end

local function join_path(dir, name)
  if not dir or dir == "" then return name end
  if dir:sub(-1) == "/" then return dir .. name end
  return dir .. "/" .. name
end

-- ============================================================
-- Argument parsing
-- ============================================================

local function parse_args(args)
  local opts = { format = "html", output = nil, file = nil }
  local positional = {}
  local i = 1
  while i <= #(args or {}) do
    local a = args[i]
    if a == "-o" or a == "--output" then
      i = i + 1
      opts.output = args[i]
    elseif a == "--format" then
      i = i + 1
      opts.format = args[i]
    elseif a:sub(1, 2) == "--" then
      io.stderr:write("warning: unknown flag '" .. a .. "'\n")
    else
      positional[#positional + 1] = a
    end
    i = i + 1
  end
  opts.file = positional[1]
  return opts
end

-- ============================================================
-- Public entry point
-- ============================================================

--- Public renderer for tests / external use.
--- Returns a table {pages = {[filename] = contents}} for HTML mode,
--- or {pages = {[outname] = markdown_text}} for md mode.
---@param typed_ast table
---@param filename  string
---@param format    string   "html" or "md"
---@param out_name  string?  base output filename (md only; default "docs.md")
function M.build_pages(typed_ast, filename, format, out_name)
  local groups = group_decls(typed_ast)
  local pages  = {}

  if format == "md" then
    pages[out_name or "docs.md"] = render_markdown(groups, filename)
    return { pages = pages, groups = groups }
  end

  local title = (groups.module and groups.module.name) or filename or "Game"
  local function add(file, body)
    pages[file] = html_page(title .. " — " .. file,
                            sidebar_html(groups, file, title), body)
  end
  add("index.html",     render_index(groups, filename))
  add("types.html",     render_types(groups))
  add("state.html",     render_states(groups))
  add("relations.html", render_relations(groups))
  add("fns.html",       render_fns(groups))
  add("scenes.html",    render_scenes(groups))
  add("actors.html",    render_actors(groups))
  add("schedules.html", render_schedules(groups))
  add("bounded.html",   render_bounded(groups))
  add("macros.html",    render_macros(groups))
  add("speakers.html",  render_speakers(groups))
  add("grids.html",     render_grids(groups))
  add("hooks.html",     render_hooks(groups))
  add("verifies.html",  render_verifies(groups))
  pages["style.css"]  = STYLE_CSS
  return { pages = pages, groups = groups }
end

--- CLI entry point.
---@param args table
---@return integer  exit code
function M.run(args)
  local opts = parse_args(args)
  if not opts.file then
    io.stderr:write("usage: storybase docs <file.sb> [-o <dir>] [--format html|md]\n")
    return 1
  end
  if opts.format ~= "html" and opts.format ~= "md" then
    io.stderr:write("error: --format must be 'html' or 'md', got '"
                    .. tostring(opts.format) .. "'\n")
    return 1
  end

  local typed_ast, diags = compiler.parse_and_check_file(opts.file)
  if not typed_ast or (diags and diags:has_errors()) then
    io.stderr:write("error: could not compile '" .. opts.file .. "'\n")
    if diags then
      for _, d in ipairs(diags.errors or {}) do
        io.stderr:write(string.format("  %s:%d [%s] %s\n",
          d.file or opts.file, d.line or 0, d.code, d.message))
      end
    end
    return 1
  end

  -- Macros are stripped by `expand_macros` before parse_and_check returns,
  -- so re-parse (lexer + parser only) to recover any MACRO_DECL nodes for
  -- the docs site.  Tolerate parse failures silently — we already know
  -- compile succeeded above.
  local f = io.open(opts.file, "r")
  if f then
    local src = f:read("*a"); f:close()
    local tokens = lexer.tokenize(src, opts.file)
    if tokens then
      local raw_ast = parser.parse(tokens, opts.file)
      if raw_ast and raw_ast.decls then
        local extra = {}
        for _, d in ipairs(raw_ast.decls) do
          if d.kind == ast.K.MACRO_DECL then extra[#extra + 1] = d end
        end
        if #extra > 0 then
          for _, d in ipairs(extra) do
            typed_ast.decls[#typed_ast.decls + 1] = d
          end
        end
      end
    end
  end

  local result = M.build_pages(typed_ast, opts.file, opts.format)

  if opts.format == "md" then
    local out = opts.output or "docs.md"
    -- If user passed a directory-like target ending in '/', write into it
    if out:sub(-1) == "/" then
      ensure_dir(out)
      out = out .. "docs.md"
    end
    local body = result.pages["docs.md"]
    local ok, err = write_file(out, body)
    if not ok then
      io.stderr:write("error: failed to write " .. out .. ": "
                      .. tostring(err) .. "\n")
      return 1
    end
    io.stdout:write("Wrote " .. out .. "\n")
    return 0
  end

  -- HTML: write each page into output directory
  local out_dir = opts.output or "docs_out"
  ensure_dir(out_dir)
  local written = 0
  for file, body in pairs(result.pages) do
    local path = join_path(out_dir, file)
    local ok, err = write_file(path, body)
    if not ok then
      io.stderr:write("error: failed to write " .. path .. ": "
                      .. tostring(err) .. "\n")
      return 1
    end
    written = written + 1
  end
  io.stdout:write(string.format("Wrote %d files to %s/\n", written, out_dir))
  return 0
end

return M

-- cli/lsp.lua
-- Language Server Protocol (LSP) server for StoryBase.
--
-- Implements the stdio JSON-RPC transport; no extra dependencies beyond
-- the compiler and the JSON codec already in runtime/debug.lua.
--
-- Supported LSP features:
--   - textDocument/publishDiagnostics  (pushed on every open/change)
--   - textDocument/hover               (doc strings + type info)
--   - textDocument/definition          (jump to declaration)
--   - textDocument/completion          (names, state paths, types, scenes)
--
-- Usage:
--   storybase lsp
-- Then configure your editor to launch the server via stdio.

local M = {}

local compiler = require("compiler.compiler")
local ast_mod  = require("compiler.ast")
local dbg      = require("runtime.debug")  -- JSON codec only

local K = ast_mod.K

-- ── JSON-RPC transport ────────────────────────────────────────

--- Encode a Lua value to JSON, with explicit-null support via JSON_NULL.
local JSON_NULL = {}  -- sentinel: encodes as JSON null

local function json_encode(v)
  if v == JSON_NULL then return "null" end
  return dbg.encode_json(v)
end

--- Write a JSON-RPC message to stdout.
---@param body table
local function send_raw(body)
  local s = json_encode(body)
  io.stdout:write("Content-Length: " .. #s .. "\r\n\r\n" .. s)
  io.stdout:flush()
end

--- Send a successful JSON-RPC response.  result=nil sends JSON null.
---@param id      integer|string|nil
---@param result  any
local function send_response(id, result)
  if result == nil then
    -- Must send explicit null — build manually to avoid pairs() skipping nil
    local id_lit
    if type(id) == "string" then
      id_lit = '"' .. id:gsub('"', '\\"') .. '"'
    elseif id == nil then
      id_lit = "null"
    else
      id_lit = tostring(id)
    end
    local s = '{"jsonrpc":"2.0","id":' .. id_lit .. ',"result":null}'
    io.stdout:write("Content-Length: " .. #s .. "\r\n\r\n" .. s)
    io.stdout:flush()
  else
    send_raw({ jsonrpc = "2.0", id = id, result = result })
  end
end

--- Send a JSON-RPC error response.
---@param id      integer|string|nil
---@param code    integer  standard JSON-RPC error code
---@param message string
local function send_error(id, code, message)
  send_raw({ jsonrpc = "2.0", id = id,
             error = { code = code, message = message } })
end

--- Send a JSON-RPC notification (no id).
---@param method string
---@param params table
local function send_notification(method, params)
  send_raw({ jsonrpc = "2.0", method = method, params = params })
end

--- Read one JSON-RPC message from stdin.
--- Returns nil on EOF or fatal read error.
---@return table|nil
local function read_message()
  local content_length = nil
  -- Read headers
  while true do
    local line = io.stdin:read("*l")
    if line == nil then return nil end
    line = line:gsub("\r", "")
    if line == "" then break end  -- blank line ends headers
    local k, v = line:match("^([^:]+):%s*(.+)$")
    if k and k:lower() == "content-length" then
      content_length = tonumber(v)
    end
  end
  if not content_length then return nil end
  local body = io.stdin:read(content_length)
  if not body then return nil end
  local ok, msg = pcall(dbg.decode_json, body)
  if not ok then return nil end
  return msg
end

-- ── Document store ────────────────────────────────────────────

--- Per-document state.
--- documents[uri] = {text, lines, typed_ast, diags, syms}
local documents = {}

--- Convert a file:// URI to a filesystem path.
---@param uri string
---@return string
local function uri_to_path(uri)
  local path = uri:match("^file://(.+)$")
  if not path then return uri end
  -- URL-decode %XX sequences
  path = path:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  return path
end

--- Split source text into a 1-based array of line strings.
---@param text string
---@return string[]
local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

-- ── Symbol map ────────────────────────────────────────────────

--- Build a flat symbol map from a typed AST.
--- Returns: {[name_or_path] = {kind, pos, doc, detail}}
---@param typed_ast table|nil
---@return table
local function build_syms(typed_ast)
  local syms = {}
  if not typed_ast then return syms end

  local function add(name, kind, node, detail)
    if name and node then
      syms[name] = {
        kind   = kind,
        pos    = node.pos,
        doc    = node.doc,
        detail = detail,
      }
    end
  end

  -- From symtab (populated by checker)
  local st = typed_ast.symtab
  if st then
    for name, node in pairs(st.types     or {}) do add(name, "type",     node) end
    for path, node in pairs(st.states    or {}) do add(path, "state",    node) end
    for name, node in pairs(st.relations or {}) do add(name, "relation", node) end
    for name, node in pairs(st.scenes    or {}) do add(name, "scene",    node) end
    for name, node in pairs(st.grids     or {}) do add(name, "grid",     node) end
  end

  -- From top-level decls (fn, actor, schedule, bounded, macro not in symtab)
  for _, decl in ipairs(typed_ast.decls or {}) do
    if decl.kind == K.FN_DECL then
      local params = {}
      for _, p in ipairs(decl.params or {}) do
        -- params are plain strings (parameter names), not sub-tables
        params[#params + 1] = type(p) == "string" and p or (p.name or "?")
      end
      add(decl.name, "fn", decl, "(" .. table.concat(params, ", ") .. ")")

    elseif decl.kind == K.ACTOR_DECL then
      add(decl.name, "actor", decl)

    elseif decl.kind == K.SCHEDULE_DECL then
      add(decl.name, "schedule", decl)

    elseif decl.kind == K.BOUNDED_DECL then
      add(decl.name, "bounded", decl)

    elseif decl.kind == K.MACRO_DECL then
      add(decl.name, "macro", decl)
    end
  end

  return syms
end
M.build_syms = build_syms

-- ── Diagnostics conversion ────────────────────────────────────

--- Convert StoryBase diagnostics to LSP diagnostic format.
---@param diags table  StoryBase diagnostic accumulator
---@return table[]     LSP diagnostics array
local function make_lsp_diags(diags)
  local result = {}
  for _, d in ipairs(diags.all or {}) do
    local line = math.max(0, (d.line or 1) - 1)
    local col  = math.max(0, (d.col  or 1) - 1)
    result[#result + 1] = {
      range = {
        start  = { line = line, character = col },
        ["end"]= { line = line, character = col + 1 },
      },
      severity = (d.level == "error") and 1 or 2,
      code     = d.code,
      source   = "storybase",
      message  = d.message,
    }
  end
  return result
end
M.make_lsp_diags = make_lsp_diags

-- ── Document update ───────────────────────────────────────────

--- Parse a document, update the in-memory store, and push diagnostics.
---@param uri  string
---@param text string
local function update_document(uri, text)
  local path = uri_to_path(uri)
  local typed_ast, diags
  local ok, err = pcall(function()
    typed_ast, diags = compiler.parse_and_check(text, path)
  end)
  if not ok then
    -- Compiler itself crashed: manufacture a single error diagnostic
    local dummy_diag = ast_mod.error("INTERNAL", "LSP: compiler crash: " .. tostring(err),
                                     ast_mod.pos(path, 1, 1))
    local acc = { all = { dummy_diag }, errors = { dummy_diag }, warnings = {} }
    acc.has_errors = function() return true end
    diags = acc
    typed_ast = nil
  end

  documents[uri] = {
    text      = text,
    lines     = split_lines(text),
    typed_ast = typed_ast,
    diags     = diags,
    syms      = build_syms(typed_ast),
  }

  send_notification("textDocument/publishDiagnostics", {
    uri         = uri,
    diagnostics = make_lsp_diags(diags),
  })
end

-- ── Word extraction ───────────────────────────────────────────

--- Find the word (identifier or state path) at a given 0-based line/character.
--- Identifier characters: letters, digits, hyphens, underscores, slashes (for paths).
---@param lines    string[]
---@param line0    integer   0-based line index
---@param char0    integer   0-based character index
---@return string|nil
local function word_at(lines, line0, char0)
  local text = lines[line0 + 1]
  if not text or text == "" then return nil end

  -- Work in 1-based positions
  local pos = char0 + 1

  local function is_word(ch)
    return ch:match("[%a%d%-%_/]") ~= nil
  end

  -- If the character directly under the cursor is not a word character, no word here.
  -- LSP character positions point to the character at that index (0-based),
  -- so pos (1-based) must land on a word char.
  local cur_ch = text:sub(pos, pos)
  if cur_ch == "" or not is_word(cur_ch) then return nil end

  -- Walk left to find start
  local left = pos
  while left > 1 and is_word(text:sub(left - 1, left - 1)) do
    left = left - 1
  end
  -- Walk right to find end
  local right = pos
  while right < #text and is_word(text:sub(right + 1, right + 1)) do
    right = right + 1
  end

  local word = text:sub(left, right)
  if word == "" or word == "/" or word == "-" then return nil end
  return word
end
M.word_at = word_at

-- ── Hover formatting ──────────────────────────────────────────

--- Format a hover response for a symbol.
---@param sym  table   entry from build_syms
---@param name string
---@return string   Markdown text
local function format_hover(sym, name)
  local parts = {}
  parts[#parts + 1] = "**" .. sym.kind .. "** `" .. name .. "`"
  if sym.detail and sym.detail ~= "" then
    parts[#parts + 1] = sym.detail
  end
  if sym.doc and sym.doc ~= "" then
    parts[#parts + 1] = ""
    parts[#parts + 1] = sym.doc
  end
  return table.concat(parts, "\n")
end

-- ── Completion ───────────────────────────────────────────────

-- LSP CompletionItemKind numbers
local CK = {
  Text     = 1,
  Method   = 2,
  Function = 3,
  Field    = 5,
  Variable = 6,
  Class    = 7,
  Property = 10,
  Keyword  = 14,
}

local KIND_TO_CK = {
  fn       = CK.Function,
  scene    = CK.Function,
  bounded  = CK.Function,
  macro    = CK.Function,
  state    = CK.Property,
  relation = CK.Property,
  grid     = CK.Property,
  type     = CK.Class,
  actor    = CK.Variable,
  schedule = CK.Variable,
}

--- Build a completion list from syms whose name starts with prefix.
---@param syms   table   symbol map from build_syms
---@param prefix string  current word prefix (may be empty)
---@return table[]       array of LSP CompletionItem
local function make_completions(syms, prefix)
  local items = {}
  for name, sym in pairs(syms) do
    if prefix == "" or name:sub(1, #prefix) == prefix then
      items[#items + 1] = {
        label         = name,
        kind          = KIND_TO_CK[sym.kind] or CK.Variable,
        detail        = sym.kind,
        documentation = sym.doc or nil,
      }
    end
  end
  table.sort(items, function(a, b) return a.label < b.label end)
  return items
end

-- ── Request handlers ──────────────────────────────────────────

local handlers = {}

handlers["initialize"] = function(id, _params)
  send_response(id, {
    capabilities = {
      textDocumentSync = {
        openClose = true,
        change    = 1,   -- 1 = Full (resend entire document on change)
      },
      hoverProvider      = true,
      definitionProvider = true,
      completionProvider = {
        triggerCharacters = { "/", "-" },
      },
    },
    serverInfo = { name = "storybase-lsp", version = "0.1.0" },
  })
end

handlers["initialized"] = function(_id, _params)
  -- Notification: no response required
end

handlers["shutdown"] = function(id, _params)
  send_response(id, nil)  -- null result per spec
end

handlers["exit"] = function(_id, _params)
  os.exit(0)
end

handlers["$/cancelRequest"] = function(_id, _params)
  -- Ignore cancel notifications
end

handlers["textDocument/didOpen"] = function(_id, params)
  local doc = params.textDocument
  update_document(doc.uri, doc.text)
end

handlers["textDocument/didChange"] = function(_id, params)
  local doc     = params.textDocument
  local changes = params.contentChanges
  if changes and #changes > 0 then
    -- Full sync mode: last change has the full new content
    update_document(doc.uri, changes[#changes].text)
  end
end

handlers["textDocument/didClose"] = function(_id, params)
  local uri = params.textDocument.uri
  documents[uri] = nil
  -- Clear diagnostics for closed file
  send_notification("textDocument/publishDiagnostics",
                    { uri = uri, diagnostics = {} })
end

handlers["textDocument/hover"] = function(id, params)
  local uri  = params.textDocument.uri
  local pos  = params.position
  local doc  = documents[uri]
  if not doc then return send_response(id, nil) end

  local word = word_at(doc.lines, pos.line, pos.character)
  if not word then return send_response(id, nil) end

  local sym = doc.syms[word]
  if not sym then return send_response(id, nil) end

  send_response(id, {
    contents = { kind = "markdown", value = format_hover(sym, word) },
  })
end

handlers["textDocument/definition"] = function(id, params)
  local uri = params.textDocument.uri
  local pos = params.position
  local doc = documents[uri]
  if not doc then return send_response(id, nil) end

  local word = word_at(doc.lines, pos.line, pos.character)
  if not word then return send_response(id, nil) end

  local sym = doc.syms[word]
  if not sym or not sym.pos then return send_response(id, nil) end

  local def_line = math.max(0, (sym.pos.line or 1) - 1)
  local def_col  = math.max(0, (sym.pos.col  or 1) - 1)
  local def_uri  = sym.pos.file and ("file://" .. sym.pos.file) or uri

  send_response(id, {
    uri   = def_uri,
    range = {
      start  = { line = def_line, character = def_col },
      ["end"]= { line = def_line, character = def_col },
    },
  })
end

handlers["textDocument/completion"] = function(id, params)
  local uri = params.textDocument.uri
  local pos = params.position
  local doc = documents[uri]
  if not doc then
    return send_response(id, { isIncomplete = false, items = {} })
  end

  -- Extract the word prefix ending at the cursor
  local line_text = doc.lines[pos.line + 1] or ""
  local before    = line_text:sub(1, pos.character)
  local prefix    = before:match("[%a%d%-%_/]*$") or ""

  local items = make_completions(doc.syms, prefix)
  send_response(id, { isIncomplete = false, items = items })
end

-- ── Main loop ─────────────────────────────────────────────────

--- Run the LSP server, reading JSON-RPC messages from stdin until EOF.
function M.run()
  while true do
    local msg = read_message()
    if msg == nil then break end  -- EOF

    local method = msg.method
    local id     = msg.id

    if method then
      local handler = handlers[method]
      if handler then
        local ok, err = pcall(handler, id, msg.params or {})
        if not ok then
          if id ~= nil then
            send_error(id, -32603, "Internal error: " .. tostring(err))
          end
        end
      elseif id ~= nil then
        -- Request for unknown method: return error
        send_error(id, -32601, "Method not found: " .. tostring(method))
      end
      -- Unknown notifications (no id) are silently ignored per spec
    end
  end
end

return M

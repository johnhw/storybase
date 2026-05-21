-- compiler/lexer.lua
-- Tokenise StoryBase source text into a token stream with source positions.
--
-- Token table structure:
--   { kind = "...", value = ..., pos = {file="...", line=N, col=N} }
--
-- Token kinds:
--   INTEGER, FLOAT, BOOL, STRING, MULTILINE_STRING
--   SYMBOL, PATH, INTERP_PATH, NAMED_ARG
--   IDENT, KEYWORD
--   MACRO_PARAM      — bare `$ident` (decl-macro substitution slot)
--   COMPOSITE_IDENT  — no-whitespace run of IDENT and `$IDENT` segments joined
--                      by `-`; value is a list whose entries are either literal
--                      strings or `{kind="macro_param", name="..."}` placeholders.
--                      Consecutive string parts are merged at emit time.
--   OP  (operator / punctuation)
--   RAW_TEXT
--   INDENT, DEDENT, NEWLINE
--   EOF

local M = {}

-- ── Keyword set ────────────────────────────────────────────────────────────
local KEYWORDS = {}
for _, kw in ipairs({
  "fn", "state", "type", "scene", "when", "if", "elif", "else", "match",
  "cond", "for", "while", "break", "continue", "return", "let", "in", "with", "import", "module",
  "relation", "actor", "schedule", "bounded", "macro", "decl-macro", "verify",
  "watch", "watch-when", "pre", "post", "tags", "pass",
  "tag", "hook", "say", "speaker",
  "generate", "ending", "quest",
  "and", "or", "not",
}) do
  KEYWORDS[kw] = true
end

-- ── Boolean literals ───────────────────────────────────────────────────────
-- (checked after KEYWORDS to avoid treating them as KEYWORD)
local BOOLEANS = { ["true"] = true, ["false"] = false }

-- ── Escape sequences ───────────────────────────────────────────────────────
local ESCAPES = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"' }

-- ── Character helpers ──────────────────────────────────────────────────────
local function is_alpha(c)
  return c ~= nil and ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_')
end

local function is_digit(c)
  return c ~= nil and c >= '0' and c <= '9'
end

local function is_alnum(c)
  return is_alpha(c) or is_digit(c)
end

-- ── Constructors ───────────────────────────────────────────────────────────
local function mktok(kind, value, file, line, col)
  return { kind = kind, value = value, pos = { file = file, line = line, col = col } }
end

local function mkdiag(level, code, msg, file, line, col, note)
  return { level = level, code = code, message = msg,
           file = file, line = line, col = col, note = note }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- M.tokenize
-- ─────────────────────────────────────────────────────────────────────────────

--- Tokenise source text.
---
--- Returns (tokens, diags):
---   tokens — list of token tables
---   diags  — list of diagnostic tables (errors and warnings)
---
---@param source   string  Source text
---@param filename string  File name for diagnostics
---@return table, table
function M.tokenize(source, filename)
  filename = filename or "?"
  local tokens = {}
  local diags  = {}
  local s      = source:gsub("\r\n", "\n"):gsub("\r", "\n")  -- normalise CRLF
  local slen   = #s

  -- ── Position tracking ────────────────────────────────────────────────
  local pos        = 1   -- current byte index (1-based)
  local cur_line   = 1
  local line_start = 1   -- byte offset where the current line started

  local function col()
    return pos - line_start + 1
  end

  -- Peek at character at pos+offset (default offset=0).
  local function peek(offset)
    local p = pos + (offset or 0)
    if p < 1 or p > slen then return nil end
    return s:sub(p, p)
  end

  -- Advance pos by n (default 1), updating line/line_start.
  local function adv(n)
    n = n or 1
    for _ = 1, n do
      if pos <= slen and s:sub(pos, pos) == '\n' then
        cur_line   = cur_line + 1
        line_start = pos + 1
      end
      pos = pos + 1
    end
  end

  local function emit(kind, value, ln, c)
    table.insert(tokens, mktok(kind, value, filename, ln, c))
  end

  local function err(code, msg, ln, c, note)
    table.insert(diags, mkdiag("error", code, msg, filename, ln or cur_line, c or col(), note))
  end

  -- ── Indentation state ────────────────────────────────────────────────
  local indent_stack   = { 0 }   -- stack of indentation column-widths
  local at_line_start  = true    -- are we at the start of a new line?
  local line_has_tok   = false   -- has the current logical line emitted any tokens?
  local paren_depth    = 0       -- nesting depth inside (), [], {} — suppresses INDENT/DEDENT

  -- ── Helpers ──────────────────────────────────────────────────────────

  -- Scan a kebab-case identifier segment: [a-zA-Z][a-zA-Z0-9-]* [!?]?
  -- Returns the scanned string (or nil if peek() is not alpha).
  local function scan_ident_seg()
    if not is_alpha(peek()) then return nil end
    local start = pos
    adv()
    while true do
      local c = peek()
      if is_alnum(c) then
        adv()
      elseif c == '-' and is_alnum(peek(1)) then
        adv()  -- consume '-'
        adv()  -- consume following alnum
      else
        break
      end
    end
    -- Optional trailing '!' or '?'
    local trail = peek()
    if trail == '!' or trail == '?' then
      adv()
    end
    return s:sub(start, pos - 1)
  end

  -- Scan a single-line string (pos is right after the opening '"').
  -- Returns the decoded string value.
  local function scan_string_body(tok_line, tok_col)
    local parts = {}
    while pos <= slen do
      local c = peek()
      if c == '"' then
        adv()
        return table.concat(parts)
      elseif c == '\\' then
        adv()
        local esc = peek()
        if esc == nil then
          err("UNTERMINATED_STRING", "Unterminated string literal", tok_line, tok_col)
          return table.concat(parts)
        end
        local rep = ESCAPES[esc]
        if rep then
          table.insert(parts, rep)
        else
          -- Unknown escape: keep verbatim
          table.insert(parts, '\\')
          table.insert(parts, esc)
        end
        adv()
      elseif c == '\n' then
        err("UNTERMINATED_STRING", "Unterminated string literal (newline before closing quote)",
            tok_line, tok_col)
        return table.concat(parts)
      else
        table.insert(parts, c)
        adv()
      end
    end
    err("UNTERMINATED_STRING", "Unterminated string literal (end of file)", tok_line, tok_col)
    return table.concat(parts)
  end

  -- Scan a multi-line string (pos is right after the opening '"""').
  -- start_col is the 1-based column of the opening '"""'.
  local function scan_multiline_body(start_col, tok_line, tok_col)
    -- Consume rest of opening line (must be only whitespace).
    while pos <= slen and peek() ~= '\n' do
      local c = peek()
      if c ~= ' ' and c ~= '\t' then
        err("UNTERMINATED_STRING",
            "Unexpected content after opening \"\"\"", cur_line, col())
      end
      adv()
    end
    if pos <= slen then adv() end  -- consume '\n'

    local strip = start_col - 1   -- leading spaces to strip per line
    local parts = {}

    while pos <= slen do
      -- Strip up to `strip` leading spaces/tabs
      local stripped = 0
      while stripped < strip and pos <= slen and (peek() == ' ' or peek() == '\t') do
        adv()
        stripped = stripped + 1
      end

      -- Check for closing '"""' (after stripping indentation)
      if s:sub(pos, pos + 2) == '"""' then
        adv(3)
        break
      end

      -- Collect to end of line
      local seg_start = pos
      while pos <= slen and peek() ~= '\n' do
        adv()
      end
      table.insert(parts, s:sub(seg_start, pos - 1))

      if pos <= slen then
        table.insert(parts, '\n')
        adv()  -- consume '\n'
      end
    end

    local value = table.concat(parts)
    -- Strip trailing newline added by last line
    value = value:gsub('\n$', '')
    return value
  end

  -- ── Main scan loop ────────────────────────────────────────────────────
  while pos <= slen do
    local c = peek()

    -- ── Newline ───────────────────────────────────────────────────────
    if c == '\n' then
      if line_has_tok then
        emit("NEWLINE", nil, cur_line, col())
        line_has_tok = false
      end
      adv()
      at_line_start = true

    -- ── Indentation handling (at start of each physical line) ─────────
    elseif at_line_start then
      at_line_start = false

      -- Measure and validate indentation
      local ind_start = pos
      local has_sp    = false
      local has_tab   = false
      while peek() == ' ' or peek() == '\t' do
        if peek() == ' '  then has_sp  = true end
        if peek() == '\t' then has_tab = true end
        adv()
      end
      local ind_len = pos - ind_start

      if has_sp and has_tab then
        err("MIXED_INDENT", "Mixed tabs and spaces in indentation", cur_line, 1)
      end

      -- Skip blank lines and comment-only lines
      local nc = peek()
      if nc == '\n' or nc == '#' or nc == nil then
        if nc == '#' then
          while pos <= slen and peek() ~= '\n' do adv() end
        end
        -- Don't emit INDENT/DEDENT for blank/comment lines
        at_line_start = true   -- re-set so next char triggers indentation again
        -- (the \n will be consumed in the next iteration)

      else
        -- Real content: resolve INDENT/DEDENT (suppressed inside parens/brackets)
        local cur_ind = indent_stack[#indent_stack]
        if paren_depth == 0 then
          if ind_len > cur_ind then
            table.insert(indent_stack, ind_len)
            emit("INDENT", nil, cur_line, 1)
          elseif ind_len < cur_ind then
            while #indent_stack > 1 and indent_stack[#indent_stack] > ind_len do
              table.remove(indent_stack)
              emit("DEDENT", nil, cur_line, 1)
            end
            if indent_stack[#indent_stack] ~= ind_len then
              err("MIXED_INDENT",
                  "Indentation does not match any enclosing block level",
                  cur_line, 1)
            end
          end
          -- ind_len == cur_ind: no change
        end
      end

    -- ── Spaces / tabs within a line ──────────────────────────────────
    elseif c == ' ' or c == '\t' then
      adv()

    -- ── Comments ─────────────────────────────────────────────────────
    elseif c == '#' then
      while pos <= slen and peek() ~= '\n' do adv() end

    -- ── Multi-line string '"""' ───────────────────────────────────────
    elseif c == '"' and s:sub(pos, pos + 2) == '"""' then
      local tok_line, tok_col = cur_line, col()
      adv(3)
      local value = scan_multiline_body(tok_col, tok_line, tok_col)
      emit("MULTILINE_STRING", value, tok_line, tok_col)
      line_has_tok = true

    -- ── Single-line string ────────────────────────────────────────────
    elseif c == '"' then
      local tok_line, tok_col = cur_line, col()
      adv()
      local value = scan_string_body(tok_line, tok_col)
      emit("STRING", value, tok_line, tok_col)
      line_has_tok = true

    -- ── Symbol literal '‹ident› ──────────────────────────────────────
    elseif c == "`" then
      local tok_line, tok_col = cur_line, col()
      adv()
      if is_alpha(peek()) then
        local start = pos
        while is_alnum(peek()) or (peek() == '-' and is_alnum(peek(1))) do
          if peek() == '-' then adv() end  -- consume '-'
          adv()
        end
        emit("SYMBOL", s:sub(start, pos - 1), tok_line, tok_col)
      else
        err("ILLEGAL_CHAR", "Expected identifier after backtick", tok_line, tok_col)
      end
      line_has_tok = true

    -- ── Number literal ────────────────────────────────────────────────
    elseif is_digit(c) then
      local tok_line, tok_col = cur_line, col()
      local start = pos
      while is_digit(peek()) do adv() end
      if peek() == '.' and is_digit(peek(1)) then
        adv()  -- consume '.'
        while is_digit(peek()) do adv() end
        emit("FLOAT", tonumber(s:sub(start, pos - 1)), tok_line, tok_col)
      else
        emit("INTEGER", tonumber(s:sub(start, pos - 1)), tok_line, tok_col)
      end
      line_has_tok = true

    -- ── Macro parameter '$ident' / composite ident with $-slots ──────
    -- `$ident` alone becomes MACRO_PARAM. If the param participates in a
    -- no-whitespace run with IDENTs / other params joined by `-` (e.g.
    -- `give-$path`, `$path-init`, `$a-$b`, `has-$path?`), the whole run is
    -- emitted as one COMPOSITE_IDENT token whose `value` is the parts list.
    elseif c == '$' then
      local tok_line, tok_col = cur_line, col()
      if not is_alpha(peek(1)) then
        err("ILLEGAL_CHAR", "Expected identifier after '$'", tok_line, tok_col)
        adv()
      else
        adv()  -- consume '$'
        local mp_start = pos
        while is_alnum(peek()) do adv() end
        local mp_name = s:sub(mp_start, pos - 1)

        local has_continuation =
            (peek() == '-' and (is_alpha(peek(1))
                              or (peek(1) == '$' and is_alpha(peek(2)))))
            or peek() == '!' or peek() == '?'

        if has_continuation then
          local parts = { { kind = "macro_param", name = mp_name } }
          local function append_str(str)
            if type(parts[#parts]) == "string" then
              parts[#parts] = parts[#parts] .. str
            else
              table.insert(parts, str)
            end
          end

          while peek() == '-' and (is_alpha(peek(1))
                              or (peek(1) == '$' and is_alpha(peek(2)))) do
            adv()  -- consume '-'
            append_str('-')
            if peek() == '$' then
              adv()  -- consume '$'
              local ms = pos
              while is_alnum(peek()) do adv() end
              table.insert(parts, { kind = "macro_param", name = s:sub(ms, pos - 1) })
            else
              local ss = pos
              while is_alnum(peek()) do adv() end
              append_str(s:sub(ss, pos - 1))
            end
          end

          if peek() == '!' or peek() == '?' then
            append_str(peek())
            adv()
          end

          emit("COMPOSITE_IDENT", parts, tok_line, tok_col)
        else
          emit("MACRO_PARAM", mp_name, tok_line, tok_col)
        end
        line_has_tok = true
      end

    -- ── Identifier / keyword / path / composite-ident with $-slots ────
    elseif is_alpha(c) then
      local tok_line, tok_col = cur_line, col()
      local first_seg = scan_ident_seg()  -- always succeeds (is_alpha guard above)

      -- Composite continuation: '-$ident' with no whitespace? scan_ident_seg
      -- already absorbed any '-ident' runs (since alnum follows the '-'), so
      -- the only way to land here is a '-$...' transition.
      if peek() == '-' and peek(1) == '$' and is_alpha(peek(2)) then
        local parts = { first_seg }
        local function append_str(str)
          if type(parts[#parts]) == "string" then
            parts[#parts] = parts[#parts] .. str
          else
            table.insert(parts, str)
          end
        end

        while peek() == '-' and (is_alpha(peek(1))
                            or (peek(1) == '$' and is_alpha(peek(2)))) do
          adv()  -- consume '-'
          append_str('-')
          if peek() == '$' then
            adv()  -- consume '$'
            local ms = pos
            while is_alnum(peek()) do adv() end
            table.insert(parts, { kind = "macro_param", name = s:sub(ms, pos - 1) })
          else
            local ss = pos
            while is_alnum(peek()) do adv() end
            append_str(s:sub(ss, pos - 1))
          end
        end

        if peek() == '!' or peek() == '?' then
          append_str(peek())
          adv()
        end

        emit("COMPOSITE_IDENT", parts, tok_line, tok_col)
        line_has_tok = true
        goto continue_scan
      end

      local segments  = { first_seg }
      local has_interp = false

      -- Try to extend into a path: ident(/segment)+
      while peek() == '/' do
        local next_ch = peek(1)
        if is_alpha(next_ch) then
          adv()  -- consume '/'
          local seg = scan_ident_seg()
          if seg then
            table.insert(segments, seg)
          else
            -- Cannot happen: we checked is_alpha above
            break
          end
        elseif next_ch == '*' then
          -- Wildcard segment: npcs/*/health  or  player/**/strength
          adv()  -- consume '/'
          adv()  -- consume first '*'
          if peek() == '*' then
            adv()  -- consume second '*'
            table.insert(segments, '**')
          else
            table.insert(segments, '*')
          end
        elseif next_ch == '(' then
          -- Alternation group: player/(health|mana)
          adv()  -- consume '/'
          adv()  -- consume '('
          local alt_start = pos
          while peek() ~= ')' and peek() ~= '' do adv() end
          local alt_inner = s:sub(alt_start, pos - 1)
          if peek() == ')' then adv() end  -- consume ')'
          table.insert(segments, '(' .. alt_inner .. ')')
        elseif next_ch == '!' then
          -- Negation segment: player/!inventory
          adv()  -- consume '/'
          adv()  -- consume '!'
          if is_alpha(peek()) then
            local neg_seg = scan_ident_seg()
            table.insert(segments, '!' .. neg_seg)
          else
            break
          end
        elseif next_ch == '{' then
          adv()  -- consume '/'
          -- Scan {ident} interpolation segment
          if peek() ~= '{' then break end
          local brace_col = col()
          adv()  -- consume '{'
          if is_alpha(peek()) then
            local istart = pos
            -- Allow path expressions like player/companion inside {}
            while is_alnum(peek()) or (peek() == '-' and is_alnum(peek(1)))
               or (peek() == '/' and is_alpha(peek(1))) do
              if peek() == '-' or peek() == '/' then adv() end
              adv()
            end
            local iname = s:sub(istart, pos - 1)
            if peek() == '}' then
              adv()  -- consume '}'
              table.insert(segments, '{' .. iname .. '}')
              has_interp = true
            else
              err("ILLEGAL_CHAR", "Expected '}' to close path interpolation",
                  cur_line, brace_col)
              table.insert(segments, '{' .. iname)
            end
          else
            err("ILLEGAL_CHAR",
                "Expected identifier inside path interpolation '{...}'",
                cur_line, brace_col)
          end
        else
          break  -- '/' is a division operator; stop path scanning
        end
      end

      if #segments > 1 then
        -- Path token
        local full = table.concat(segments, '/')
        if has_interp then
          emit("INTERP_PATH", full, tok_line, tok_col)
        else
          emit("PATH", full, tok_line, tok_col)
        end
      else
        -- Single identifier: keyword, bool, named-arg, or ident
        local word = first_seg
        if peek() == ':' then
          -- Named argument: 'word:' (no space between word and colon)
          adv()  -- consume ':'
          emit("NAMED_ARG", word, tok_line, tok_col)
        elseif BOOLEANS[word] ~= nil then
          emit("BOOL", BOOLEANS[word], tok_line, tok_col)
        elseif KEYWORDS[word] then
          emit("KEYWORD", word, tok_line, tok_col)
        else
          emit("IDENT", word, tok_line, tok_col)
        end
      end
      line_has_tok = true

    -- ── Operators and punctuation ─────────────────────────────────────
    else
      local tok_line, tok_col = cur_line, col()
      local two = s:sub(pos, pos + 1)

      if   two == '->' then emit("OP", "->", tok_line, tok_col); adv(2)
      elseif two == '=>' then emit("OP", "=>", tok_line, tok_col); adv(2)
      elseif two == '<-' then emit("OP", "<-", tok_line, tok_col); adv(2)
      elseif two == '<=' then emit("OP", "<=", tok_line, tok_col); adv(2)
      elseif two == '>=' then emit("OP", ">=", tok_line, tok_col); adv(2)
      elseif two == '!=' then emit("OP", "!=", tok_line, tok_col); adv(2)
      elseif two == '??' then emit("OP", "??", tok_line, tok_col); adv(2)
      elseif c == '='   then emit("OP", "=",  tok_line, tok_col); adv()
      elseif c == '<'   then emit("OP", "<",  tok_line, tok_col); adv()
      elseif c == '>'   then emit("OP", ">",  tok_line, tok_col); adv()
      elseif c == '+'   then emit("OP", "+",  tok_line, tok_col); adv()
      elseif c == '-'   then emit("OP", "-",  tok_line, tok_col); adv()
      elseif c == '*'   then emit("OP", "*",  tok_line, tok_col); adv()
      elseif c == '/'   then emit("OP", "/",  tok_line, tok_col); adv()
      elseif c == '{'   then
        if peek(1) == '{' then
          -- {{ escape: literal brace in narration text (no paren_depth change)
          emit("RAW_TEXT", "{", tok_line, tok_col); adv(2)
        else
          paren_depth = paren_depth + 1; emit("OP", "{", tok_line, tok_col); adv()
        end
      elseif c == '}'   then paren_depth = paren_depth - 1; emit("OP", "}",  tok_line, tok_col); adv()
      elseif c == '['   then paren_depth = paren_depth + 1; emit("OP", "[",  tok_line, tok_col); adv()
      elseif c == ']'   then paren_depth = paren_depth - 1; emit("OP", "]",  tok_line, tok_col); adv()
      elseif c == '('   then paren_depth = paren_depth + 1; emit("OP", "(",  tok_line, tok_col); adv()
      elseif c == ')'   then paren_depth = paren_depth - 1; emit("OP", ")",  tok_line, tok_col); adv()
      elseif c == '|'   then emit("OP", "|",  tok_line, tok_col); adv()
      elseif c == ','   then emit("OP", ",",  tok_line, tok_col); adv()
      elseif c == ':'   then emit("OP", ":",  tok_line, tok_col); adv()
      elseif c == '.'   then emit("OP", ".",  tok_line, tok_col); adv()
      elseif c == '@'   then emit("OP", "@",  tok_line, tok_col); adv()
      elseif c == "'"  then
        -- Apostrophe is valid in narration prose (contractions, possessives)
        emit("RAW_TEXT", "'", tok_line, tok_col); adv()
      elseif c:byte() > 127 then
        -- UTF-8 multi-byte sequence: decode length from leading byte and emit as RAW_TEXT
        local b = c:byte()
        local seq_len = (b >= 0xF0) and 4 or (b >= 0xE0) and 3 or (b >= 0xC0) and 2 or 1
        emit("RAW_TEXT", s:sub(pos, pos + seq_len - 1), tok_line, tok_col)
        adv(seq_len)
      else
        err("ILLEGAL_CHAR", "Illegal character: " .. c, tok_line, tok_col)
        adv()
      end
      line_has_tok = true
    end
    ::continue_scan::
  end

  -- ── End of source: close off last line and remaining indents ─────────
  if line_has_tok then
    emit("NEWLINE", nil, cur_line, col())
  end

  while #indent_stack > 1 do
    table.remove(indent_stack)
    emit("DEDENT", nil, cur_line, 1)
  end

  emit("EOF", nil, cur_line, col())

  return tokens, diags
end

return M

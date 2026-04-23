-- tests/compiler/lexer_spec.lua
-- Tests for compiler/lexer.lua.
--
-- Run with:  busted tests/

local lexer = require("compiler.lexer")

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Tokenise source and return just the (kind, value) pairs (no positions).
local function kinds(src)
  local toks, _ = lexer.tokenize(src, "test")
  local result = {}
  for _, t in ipairs(toks) do
    table.insert(result, { t.kind, t.value })
  end
  return result
end

-- Return the first diagnostic from tokenising source.
local function first_diag(src)
  local _, diags = lexer.tokenize(src, "test")
  return diags[1]
end

-- Return count of diagnostics.
local function diag_count(src)
  local _, diags = lexer.tokenize(src, "test")
  return #diags
end

-- Return just the kinds (no values).
local function kind_list(src)
  local toks, _ = lexer.tokenize(src, "test")
  local result = {}
  for _, t in ipairs(toks) do
    table.insert(result, t.kind)
  end
  return result
end

-- Return token at 1-based index.
local function tok(src, idx)
  local toks, _ = lexer.tokenize(src, "test")
  return toks[idx]
end

-- ── Integer literals ─────────────────────────────────────────────────────────

describe("lexer — integers", function()
  it("lexes a positive integer", function()
    local t = tok("42", 1)
    assert.equal("INTEGER", t.kind)
    assert.equal(42, t.value)
  end)

  it("lexes zero", function()
    local t = tok("0", 1)
    assert.equal("INTEGER", t.kind)
    assert.equal(0, t.value)
  end)

  it("lexes multiple integers separated by spaces", function()
    local ks = kinds("1 2 3")
    assert.equal("INTEGER", ks[1][1])
    assert.equal(1,         ks[1][2])
    assert.equal("INTEGER", ks[2][1])
    assert.equal(2,         ks[2][2])
    assert.equal("INTEGER", ks[3][1])
    assert.equal(3,         ks[3][2])
  end)

  it("emits NEWLINE and EOF after an integer", function()
    local ks = kind_list("5")
    assert.same({"INTEGER", "NEWLINE", "EOF"}, ks)
  end)
end)

-- ── Float literals ────────────────────────────────────────────────────────────

describe("lexer — floats", function()
  it("lexes a float", function()
    local t = tok("3.14", 1)
    assert.equal("FLOAT", t.kind)
    assert.is_true(math.abs(t.value - 3.14) < 1e-9)
  end)

  it("lexes a float with leading zero", function()
    local t = tok("0.5", 1)
    assert.equal("FLOAT", t.kind)
  end)

  it("does NOT lex '3.' as a float (no digit after dot)", function()
    -- '3.' should lex as INTEGER(3) then OP('.')
    -- (there is no dot operator in StoryBase but the lexer should not produce FLOAT)
    local ks = kind_list("3.")
    assert.equal("INTEGER", ks[1])
  end)
end)

-- ── Boolean literals ──────────────────────────────────────────────────────────

describe("lexer — booleans", function()
  it("lexes 'true'", function()
    local t = tok("true", 1)
    assert.equal("BOOL", t.kind)
    assert.equal(true, t.value)
  end)

  it("lexes 'false'", function()
    local t = tok("false", 1)
    assert.equal("BOOL", t.kind)
    assert.equal(false, t.value)
  end)
end)

-- ── String literals ───────────────────────────────────────────────────────────

describe("lexer — strings", function()
  it("lexes a simple string", function()
    local t = tok('"hello"', 1)
    assert.equal("STRING", t.kind)
    assert.equal("hello", t.value)
  end)

  it("handles escape sequences", function()
    local t = tok('"line1\\nline2"', 1)
    assert.equal("STRING", t.kind)
    assert.equal("line1\nline2", t.value)
  end)

  it("handles escaped backslash", function()
    local t = tok('"a\\\\b"', 1)
    assert.equal("STRING", t.kind)
    assert.equal("a\\b", t.value)
  end)

  it("handles escaped quote", function()
    local t = tok('"say \\"hi\\""', 1)
    assert.equal("STRING", t.kind)
    assert.equal('say "hi"', t.value)
  end)

  it("produces an error for an unterminated string", function()
    local d = first_diag('"no close')
    assert.is_not_nil(d)
    assert.equal("UNTERMINATED_STRING", d.code)
    assert.equal("error", d.level)
  end)

  it("produces an error for a string with a newline inside", function()
    local d = first_diag('"oops\n"')
    assert.is_not_nil(d)
    assert.equal("UNTERMINATED_STRING", d.code)
  end)
end)

-- ── Multi-line strings ────────────────────────────────────────────────────────

describe("lexer — multi-line strings", function()
  it("lexes a basic multi-line string at column 1 (no stripping)", function()
    -- Opening '"""' at col 1 → strip 0 leading spaces → content kept as-is
    local src = '"""\nhello\nworld\n"""'
    local t = tok(src, 1)
    assert.equal("MULTILINE_STRING", t.kind)
    assert.equal("hello\nworld", t.value)
  end)

  it("strips leading indentation equal to opening column minus 1", function()
    -- If '"""' is at col 3 (2 leading spaces), strip 2 spaces from each line
    local src = '  """\n  hello\n  world\n  """'
    -- Tokenise the multi-line string directly; it's the first content token
    -- (after the INDENT that "  " triggers at start-of-file)
    local toks, _ = lexer.tokenize(src, "test")
    local ms
    for _, t in ipairs(toks) do
      if t.kind == "MULTILINE_STRING" then ms = t; break end
    end
    assert.is_not_nil(ms)
    assert.equal("hello\nworld", ms.value)
  end)
end)

-- ── Symbol literals ───────────────────────────────────────────────────────────

describe("lexer — symbols", function()
  it("lexes a simple symbol", function()
    local t = tok("'sword", 1)
    assert.equal("SYMBOL", t.kind)
    assert.equal("sword", t.value)
  end)

  it("lexes a hyphenated symbol", function()
    local t = tok("'my-item", 1)
    assert.equal("SYMBOL", t.kind)
    assert.equal("my-item", t.value)
  end)

  it("emits an error for ' not followed by an identifier", function()
    local d = first_diag("'123")
    assert.is_not_nil(d)
    assert.equal("ILLEGAL_CHAR", d.code)
  end)
end)

-- ── Path tokens ───────────────────────────────────────────────────────────────

describe("lexer — paths", function()
  it("lexes a two-segment path", function()
    local t = tok("player/health", 1)
    assert.equal("PATH", t.kind)
    assert.equal("player/health", t.value)
  end)

  it("lexes a three-segment path", function()
    local t = tok("npcs/blacksmith/disposition", 1)
    assert.equal("PATH", t.kind)
    assert.equal("npcs/blacksmith/disposition", t.value)
  end)

  it("does NOT treat 'a / b' as a path (spaces around /)", function()
    local ks = kind_list("a / b")
    -- Should be: IDENT OP(/) IDENT NEWLINE EOF
    assert.equal("IDENT", ks[1])
    assert.equal("OP",    ks[2])
    assert.equal("IDENT", ks[3])
  end)
end)

-- ── Interpolated path tokens ──────────────────────────────────────────────────

describe("lexer — interpolated paths", function()
  it("lexes a path with an interpolation segment", function()
    local t = tok("npcs/{npc}/health", 1)
    assert.equal("INTERP_PATH", t.kind)
    assert.equal("npcs/{npc}/health", t.value)
  end)

  it("lexes a path with multiple interpolation segments", function()
    local t = tok("world/{region}/{zone}/name", 1)
    assert.equal("INTERP_PATH", t.kind)
    assert.equal("world/{region}/{zone}/name", t.value)
  end)

  it("lexes a path interpolation with a path expression (player/companion)", function()
    local t = tok("members/{player/companion}/status", 1)
    assert.equal("INTERP_PATH", t.kind)
    assert.equal("members/{player/companion}/status", t.value)
  end)

  it("lexes a path interpolation with a multi-segment path expression", function()
    local t = tok("data/{a/b/c}/value", 1)
    assert.equal("INTERP_PATH", t.kind)
    assert.equal("data/{a/b/c}/value", t.value)
  end)
end)

-- ── Named argument tokens ─────────────────────────────────────────────────────

describe("lexer — named arguments", function()
  it("lexes 'depth:' as NAMED_ARG", function()
    local t = tok("depth: 20", 1)
    assert.equal("NAMED_ARG", t.kind)
    assert.equal("depth", t.value)
  end)

  it("named arg is followed by the value token", function()
    local ks = kinds("depth: 20")
    assert.equal("NAMED_ARG", ks[1][1])
    assert.equal("depth",     ks[1][2])
    assert.equal("INTEGER",   ks[2][1])
    assert.equal(20,          ks[2][2])
  end)

  it("kebab-case named arg", function()
    local t = tok("max-depth: 5", 1)
    assert.equal("NAMED_ARG", t.kind)
    assert.equal("max-depth", t.value)
  end)
end)

-- ── Operators ─────────────────────────────────────────────────────────────────

describe("lexer — operators", function()
  local function op(src)
    return tok(src, 1)
  end

  it("lexes single-char operators", function()
    for _, sym in ipairs({"=", "<", ">", "+", "-", "*", "/"}) do
      local t = op(sym)
      assert.equal("OP", t.kind)
      assert.equal(sym, t.value)
    end
  end)

  it("lexes two-char operators", function()
    for _, sym in ipairs({"->", "=>", "<-", "<=", ">=", "!=", "??"}) do
      local t = op(sym)
      assert.equal("OP", t.kind, "expected OP for " .. sym)
      assert.equal(sym, t.value)
    end
  end)

  it("lexes punctuation operators", function()
    for _, sym in ipairs({"{", "}", "[", "]", "(", ")", "|", ",", ":", "@"}) do
      local t = op(sym)
      assert.equal("OP", t.kind, "expected OP for " .. sym)
      assert.equal(sym, t.value)
    end
  end)

  it("prefers two-char over single-char (e.g. '<=' not '<' then '=')", function()
    local ks = kind_list("<=")
    -- NEWLINE and EOF follow
    assert.equal("OP", ks[1])
    assert.equal(2, #kind_list("<=") - 1)  -- only one OP + NEWLINE + EOF = 3, minus EOF = 2
  end)

  it("'??' is a single OP token, not two '?'", function()
    local t = op("??")
    assert.equal("OP", t.kind)
    assert.equal("??", t.value)
  end)
end)

-- ── Keywords ──────────────────────────────────────────────────────────────────

describe("lexer — keywords", function()
  local kws = {
    "fn", "state", "type", "scene", "when", "if", "else", "match",
    "cond", "for", "while", "let", "in", "with", "import", "module",
    "relation", "actor", "schedule", "bounded", "macro", "verify",
    "watch", "pre", "post", "tags", "pass", "and", "or", "not",
  }

  for _, kw in ipairs(kws) do
    it("lexes '" .. kw .. "' as KEYWORD", function()
      local t = tok(kw, 1)
      assert.equal("KEYWORD", t.kind)
      assert.equal(kw, t.value)
    end)
  end

  it("lexes 'watch-when' as KEYWORD", function()
    local t = tok("watch-when", 1)
    assert.equal("KEYWORD", t.kind)
    assert.equal("watch-when", t.value)
  end)

  it("does not treat 'function' as a keyword (not reserved)", function()
    local t = tok("function", 1)
    assert.equal("IDENT", t.kind)
  end)
end)

-- ── Identifiers ───────────────────────────────────────────────────────────────

describe("lexer — identifiers", function()
  it("lexes a simple identifier", function()
    local t = tok("foo", 1)
    assert.equal("IDENT", t.kind)
    assert.equal("foo", t.value)
  end)

  it("lexes a kebab-case identifier", function()
    local t = tok("move-to", 1)
    assert.equal("IDENT", t.kind)
    assert.equal("move-to", t.value)
  end)

  it("lexes a predicate identifier ending in '?'", function()
    local t = tok("alive?", 1)
    assert.equal("IDENT", t.kind)
    assert.equal("alive?", t.value)
  end)

  it("lexes a mutation identifier ending in '!'", function()
    local t = tok("set!", 1)
    assert.equal("IDENT", t.kind)
    assert.equal("set!", t.value)
  end)

  it("lexes 'can-afford?' as a single identifier", function()
    local t = tok("can-afford?", 1)
    assert.equal("IDENT", t.kind)
    assert.equal("can-afford?", t.value)
  end)

  it("lexes 'time-inc!' as a single identifier", function()
    local t = tok("time-inc!", 1)
    assert.equal("IDENT", t.kind)
    assert.equal("time-inc!", t.value)
  end)
end)

-- ── Block sigils ──────────────────────────────────────────────────────────────

describe("lexer — block sigils", function()
  it("lexes '->' as OP", function()
    local t = tok("->", 1)
    assert.equal("OP", t.kind)
    assert.equal("->", t.value)
  end)

  it("lexes '=>' as OP", function()
    local t = tok("=>", 1)
    assert.equal("OP", t.kind)
    assert.equal("=>", t.value)
  end)

  it("lexes '<-' as OP", function()
    local t = tok("<-", 1)
    assert.equal("OP", t.kind)
    assert.equal("<-", t.value)
  end)

  it("lexes '*' as OP", function()
    local t = tok("*", 1)
    assert.equal("OP", t.kind)
    assert.equal("*", t.value)
  end)
end)

-- ── Whitespace and comments ───────────────────────────────────────────────────

describe("lexer — whitespace and comments", function()
  it("strips inline leading spaces (content token kind is correct)", function()
    -- "  42" triggers an INDENT then INTEGER; make sure no stray tokens
    local ks = kind_list("a:\n  42")
    -- Should have: IDENT NAMED_ARG NEWLINE INDENT INTEGER NEWLINE DEDENT EOF
    local found = false
    for _, k in ipairs(ks) do
      if k == "INTEGER" then found = true end
    end
    assert.is_true(found)
  end)

  it("strips comment to end of line", function()
    local ks = kind_list("42 # this is a comment")
    assert.equal("INTEGER", ks[1])
    assert.equal("NEWLINE", ks[2])
    assert.equal("EOF",     ks[3])
    assert.equal(3, #ks)
  end)

  it("treats blank lines as empty (no tokens)", function()
    local ks = kind_list("\n\n42")
    assert.equal("INTEGER", ks[1])
  end)

  it("treats comment-only lines as blank", function()
    local ks = kind_list("# comment\n42")
    assert.equal("INTEGER", ks[1])
  end)
end)

-- ── Indentation: INDENT / DEDENT ──────────────────────────────────────────────

describe("lexer — indentation", function()
  it("emits INDENT when indentation increases", function()
    local src = "fn foo:\n  bar"
    local ks = kind_list(src)
    -- KEYWORD NAMED_ARG NEWLINE INDENT IDENT NEWLINE DEDENT EOF
    assert.is_true(
      (function()
        for _, k in ipairs(ks) do
          if k == "INDENT" then return true end
        end
        return false
      end)())
  end)

  it("emits DEDENT when indentation decreases", function()
    local src = "fn foo:\n  bar\nbaz"
    local ks = kind_list(src)
    assert.is_true(
      (function()
        for _, k in ipairs(ks) do
          if k == "DEDENT" then return true end
        end
        return false
      end)())
  end)

  it("emits the correct number of DEDENTs for multiple levels", function()
    local src = "a:\n  b:\n    c\nend"
    local ks = kind_list(src)
    local dedents = 0
    for _, k in ipairs(ks) do
      if k == "DEDENT" then dedents = dedents + 1 end
    end
    assert.equal(2, dedents)
  end)

  it("does not emit INDENT/DEDENT for blank lines inside a block", function()
    local src = "a:\n  b\n\n  c\nd"
    local ks = kind_list(src)
    local indents = 0
    for _, k in ipairs(ks) do
      if k == "INDENT" then indents = indents + 1 end
    end
    assert.equal(1, indents)
  end)

  it("emits a NEWLINE at end of each non-blank line", function()
    local src = "a\nb\nc"
    local ks = kind_list(src)
    local newlines = 0
    for _, k in ipairs(ks) do
      if k == "NEWLINE" then newlines = newlines + 1 end
    end
    assert.equal(3, newlines)
  end)

  it("emits remaining DEDENTs at EOF", function()
    local src = "a:\n  b:\n    c"
    local ks = kind_list(src)
    -- Last three non-EOF tokens should include two DEDENTs
    local dedents = 0
    for _, k in ipairs(ks) do
      if k == "DEDENT" then dedents = dedents + 1 end
    end
    assert.equal(2, dedents)
  end)
end)

-- ── Source positions ──────────────────────────────────────────────────────────

describe("lexer — source positions", function()
  it("attaches the correct line number", function()
    local src = "foo\nbar"
    local toks, _ = lexer.tokenize(src, "f.sb")
    -- toks[1] = IDENT(foo), toks[3] = IDENT(bar) (after NEWLINE)
    assert.equal(1, toks[1].pos.line)
    assert.equal(2, toks[3].pos.line)
  end)

  it("attaches the correct column number for inline tokens", function()
    -- "foo bar": 'bar' starts at column 5
    local toks, _ = lexer.tokenize("foo bar", "test")
    -- toks[1]=IDENT(foo), toks[2]=IDENT(bar), toks[3]=NEWLINE, toks[4]=EOF
    assert.equal(5, toks[2].pos.col)
  end)

  it("attaches column 3 for identifier after two leading spaces in a block", function()
    local toks, _ = lexer.tokenize("fn foo:\n  hello", "test")
    local hello_tok
    for _, t in ipairs(toks) do
      if t.kind == "IDENT" and t.value == "hello" then
        hello_tok = t; break
      end
    end
    assert.is_not_nil(hello_tok)
    assert.equal(3, hello_tok.pos.col)
  end)

  it("attaches the given filename to every token", function()
    local toks, _ = lexer.tokenize("x", "game.sb")
    assert.equal("game.sb", toks[1].pos.file)
  end)

  it("EOF token has a position", function()
    local toks, _ = lexer.tokenize("x", "f.sb")
    local eof = toks[#toks]
    assert.equal("EOF", eof.kind)
    assert.is_not_nil(eof.pos)
  end)
end)

-- ── Error cases ───────────────────────────────────────────────────────────────

describe("lexer — error: unterminated string", function()
  it("reports UNTERMINATED_STRING error", function()
    local d = first_diag('"no close')
    assert.equal("error", d.level)
    assert.equal("UNTERMINATED_STRING", d.code)
  end)

  it("continues tokenising after an unterminated string", function()
    local toks, diags = lexer.tokenize('"oops\n42', "t")
    assert.is_true(#diags > 0)
    -- Should still have emitted an INTEGER for 42
    local found = false
    for _, t in ipairs(toks) do
      if t.kind == "INTEGER" and t.value == 42 then found = true end
    end
    assert.is_true(found)
  end)
end)

describe("lexer — error: illegal character", function()
  it("reports ILLEGAL_CHAR for an unknown character", function()
    local d = first_diag("$foo")
    assert.is_not_nil(d)
    assert.equal("ILLEGAL_CHAR", d.code)
    assert.equal("error", d.level)
  end)

  it("continues lexing after an illegal character", function()
    local ks = kind_list("$ 42")
    local found = false
    for _, k in ipairs(ks) do
      if k == "INTEGER" then found = true end
    end
    assert.is_true(found)
  end)
end)

describe("lexer — error: mixed indentation", function()
  it("reports MIXED_INDENT for a line with both spaces and tabs", function()
    local src = "fn foo:\n \t bar"  -- space then tab
    local d = first_diag(src)
    assert.is_not_nil(d)
    assert.equal("MIXED_INDENT", d.code)
  end)
end)

-- ── Integration: realistic snippets ───────────────────────────────────────────

describe("lexer — integration", function()
  it("tokenises a state declaration correctly", function()
    local src = "state player/health: Int(0, 100)"
    local ks = kinds(src)
    assert.equal("KEYWORD",  ks[1][1])  -- state
    assert.equal("PATH",     ks[2][1])  -- player/health
    assert.equal("OP",       ks[3][1])  -- :
    assert.equal("IDENT",    ks[4][1])  -- Int
    assert.equal("OP",       ks[5][1])  -- (
    assert.equal("INTEGER",  ks[6][1])  -- 0
    assert.equal("OP",       ks[7][1])  -- ,
    assert.equal("INTEGER",  ks[8][1])  -- 100
    assert.equal("OP",       ks[9][1])  -- )
  end)

  it("tokenises a function declaration with indented body", function()
    local src = "fn take-damage amount:\n  dec! player/health amount"
    local ks = kind_list(src)
    -- KEYWORD(fn) IDENT(take-damage) NAMED_ARG(amount) NEWLINE
    -- INDENT IDENT(dec!) PATH(player/health) IDENT(amount) NEWLINE
    -- DEDENT EOF
    assert.equal("KEYWORD",   ks[1])
    assert.equal("IDENT",     ks[2])
    assert.equal("NAMED_ARG", ks[3])
    assert.equal("NEWLINE",   ks[4])
    assert.equal("INDENT",    ks[5])
    assert.equal("IDENT",     ks[6])   -- dec!
    assert.equal("PATH",      ks[7])   -- player/health
    assert.equal("IDENT",     ks[8])   -- amount
    assert.equal("NEWLINE",   ks[9])
    assert.equal("DEDENT",    ks[10])
    assert.equal("EOF",       ks[11])
  end)

  it("tokenises a type enum declaration", function()
    local src = "type Status = alive | dead | unconscious"
    local ks = kinds(src)
    assert.equal("KEYWORD", ks[1][1])   -- type
    assert.equal("IDENT",   ks[2][1])   -- Status
    assert.equal("OP",      ks[3][1])   -- =
    assert.equal("IDENT",   ks[4][1])   -- alive
    assert.equal("OP",      ks[5][1])   -- |
    assert.equal("IDENT",   ks[6][1])   -- dead
    assert.equal("OP",      ks[7][1])   -- |
    assert.equal("IDENT",   ks[8][1])   -- unconscious
  end)

  it("handles empty source", function()
    local toks, diags = lexer.tokenize("", "empty.sb")
    assert.equal(0, #diags)
    assert.equal("EOF", toks[1].kind)
  end)

  it("handles source with only comments", function()
    local toks, diags = lexer.tokenize("# just a comment\n", "c.sb")
    assert.equal(0, #diags)
    assert.equal("EOF", toks[1].kind)
  end)
end)

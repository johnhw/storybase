
# StoryBase — Implementation TODO

Completed work has been moved to [completed.md](completed.md).

---

## Current Status (2026-04-16)

All eight implementation phases are complete, plus all "Bugs/Spec Gaps", "Small Wins",
and the **Standalone Bundler**, **Language Server (LSP)**, and two Medium Features below.
**1589 tests passing.**

Three low-priority deferred items completed: `engine/checkpoint!` callable, `engine/emit`
callable, and `game:docs()` public API for doc string surfacing.

---

## Active Tasks

### Bugs / Spec Gaps (fix first)

- [x] **`import "path" as Alias` is silently ignored.** Fixed: `resolve_imports` now emits
  `UNSUPPORTED_FEATURE` compile error so authors are not silently misled. Tests in
  `tests/compiler/import_spec.lua`.

- [x] **`module ... exports:` is not enforced.** Fixed: parser now parses and stores the
  `exports:` list in `ast.module_decl`; importing a module with `exports:` emits
  `WARN_EXPORTS_NOT_ENFORCED`. Tests in `tests/compiler/import_spec.lua`.

### Small Wins (low effort, high value)

- [x] **Source-context lines in error messages.** `print_diags` in `cli/main.lua` and
  `cli/check_cmd.lua` now accept a `source_map` and print the offending line + caret.

- [x] **`storybase check` subcommand.** `cli/check_cmd.lua` — lexer+parser+checker only,
  with source-context output. Wired in `cli/main.lua`.

- [x] **`storybase format` pretty-printer.** `cli/format_cmd.lua` — walks the parsed AST and
  emits canonical 2-space-indented output. `--check` and `--write` modes supported.

- [x] **`--debug` flag on `run`.** `engine.run` now accepts `opts.debug_port`; when set,
  creates a TCP debug server, calls `eng:set_debug_server`, `srv:start()`, polls each turn,
  and prints `[debug] listening on :PORT`.

- [x] **`storybase repl` subcommand.** `cli/repl_cmd.lua` — interactive REPL with expression
  eval, function calls, `:state`, `:scene`, `:choices`, `:choose N`, `:tick`, `:save/:load`.

- [x] **`at:` one-shot schedule trigger.** The scheduler already had `at:` logic; added
  deregister-after-fire for pure `at:`-only schedules. New `tests/runtime/scheduler_spec.lua`
  (12 tests) including end-to-end pipeline coverage.

### Medium Features

- [ ] **Namespaced imports (`import "path" as E`).** Once the alias is respected, names from
  the imported file are accessible as `E.TypeName`, `E.fn-name`, etc. The main work is in
  `compiler/checker.lua` name resolution and `compiler/compiler.lua` splice logic.
  Prerequisite: resolve the import-alias bug above.

- [x] **Path patterns in `watch` and `verify` forms.** `idea.md §4.3` specifies `player/*`,
  `npcs/*/location`, `player/**` wildcards and `player/(health|mana)` alternations.
  `runtime/debug.lua` `path_matches` extended with `**` multi-segment wildcards and `(a|b)`
  alternation expansion; `check_watches` now iterates all cache keys for pattern watches;
  `engine.lua` `set_debug_server` now registers `watch`/`watch-when` declarations from
  `game_table.watches`; `runtime/verify.lua` exports `match_path_pattern`. Tests in
  `tests/runtime/debug_spec.lua` (+14) and `tests/runtime/verify_spec.lua` (+9).

- [ ] **Browser-based debug UI.** The debug server already streams structured NDJSON events
  over TCP. A minimal single-page HTML file (state tree, mutation log, timeline scrubber, watch
  panel) served by the debug server itself would make the debug infrastructure usable without
  custom tooling. Add an HTTP GET handler for `/` to `runtime/debug.lua` that serves the
  embedded HTML.

- [x] **`counterfactual` as a language expression.** `idea.md §21` specifies
  `let alt = counterfactual from: world/turn - 3 do: ...` as first-class syntax.
  Parser and eval were already wired; added `from_tick` log replay: when `from:` is set,
  `eval.lua` builds historical state by replaying log mutations up to the target tick (falls
  back to current state if `from_tick` evaluates to non-number or log is empty). 4 new tests in
  `tests/runtime/counterfactual_spec.lua`.

- [ ] **Demo 07.** A demo specifically exercising `import`, `bounded`, and/or `counterfactual`
  to fill remaining spec coverage gaps. Good candidate: a two-file game where the main file
  imports a shared types/utility file, uses a `bounded` computation for NPC decision-making,
  and demonstrates `counterfactual` for player "what if" narration.

### Major Features

- [x] **Language Server (LSP).** `cli/lsp.lua` — stdio JSON-RPC 2.0 server. Wraps
  `M.parse_and_check`; on every `textDocument/didOpen` or `textDocument/didChange` it
  re-parses and pushes diagnostics. Supports `textDocument/hover` (doc strings + kind +
  params), `textDocument/definition` (jump to declaration), and `textDocument/completion`
  (names, state paths, types, scenes filtered by prefix; trigger chars `/` and `-`).
  Wired as `storybase lsp` in `cli/main.lua`. 43 unit tests in `tests/cli/lsp_spec.lua`.

- [x] **Standalone bundler (`storybase bundle`).** `storybase bundle game.sb --output game.lua`
  produces a single self-contained Lua file: compiler stripped, 14 runtime modules embedded
  via `package.preload`, game table baked in as a Lua literal. Runs with a stock `lua5.4`
  binary. `--production` strips verify/watch blocks. The bundle emits a `BUNDLED_ASSETS`
  table and `asset_load()` helper as documented extension points for future asset embedding
  (images, audio, etc.). Bundled games accept `--seed N`, `--save`, and `--load` flags.
  Implemented in `cli/bundle_cmd.lua`; 20 tests in `tests/cli/bundle_spec.lua`.

---

## Deferred / Low Priority

Items noted as low-priority during earlier phases; not yet implemented.

- [x] `engine/checkpoint!` callable form — parser handles PATH token `engine/checkpoint!` as
  `CHECKPOINT_MUT` node (ast.lua); eval pushes a log checkpoint. Optional `fn-name` arg
  overrides the checkpoint label. Tests in `tests/lib/storybase_spec.lua`.

- [x] `engine/emit event args` callable form — parser handles PATH token `engine/emit` as
  `EMIT_MUT` node; eval fires `ctx.debug:emit(...)` (debug server) AND `ctx.game._emit_hook`
  (wired by `lib/storybase.lua` to deliver events to `game:on()` listeners). Tests in
  `tests/lib/storybase_spec.lua`.

- [x] Doc string surfacing via public API — `game:docs(name?)` added to `lib/storybase.lua`:
  collects `doc` fields from fns, scenes, actors, schedules, bounded, schema.states/types;
  returns full map or single-name lookup. Tests in `tests/lib/storybase_spec.lua`.

- [ ] Doc string surfacing via debug server schema browser — `get-schema` command could
  include doc fields alongside type information. Not yet implemented.

- [ ] Every public function in every module has at least one passing and one failing test.

- the lua binary is called lua5.4. busted is installed as `busted` in the path. `lpeg` is installed.  `luasocket` is installed. 
- Note: you can change the `test*.sb` files if you find them to be defective or not in accordance to the spec, but only do so if you are sure.
- There is a map of the codebase in `code_map.md`, which describes the structure of the codebase and the purpose of each file. You should refer to this map as you work on the project to understand where different components are located and how they interact with each other.
- KEEP TODO.MD UP-TO-DATE. Mark all tasks as done when they are completed, and add new tasks as they arise. This is crucial for keeping track of progress and ensuring that the project stays organized. When a block of tasks is complete, move it to completed.md to keep todo.md focused on what still needs to be done.
- After writing or revising a significant semantic chunk (say the lexer) and the tests, review the todo.md, update it, then make a commit with a message that describes what was done. Write reasonably descriptive commit messages. Update code_map.md if you add new files or significantly change the structure of the codebase. This will help future agents understand the changes that were made and how they fit into the overall structure of the project.
- Follow the style guidelines in implementation.md
- The plan for the project is in idea.md, and specifies the entire project in detail. You should follow the plan as closely as possible, but if you find that it is not feasible or that there are better ways to implement certain features, you can deviate from the plan. However, you must document any deviations from the plan in todo.md, including the reasoning behind the deviation and any implications it might have for future work on the project.
- Every time you make a change to the code, add a test case that covers the change. If you are fixing a bug, add a test case that fails before the fix and passes after the fix.
- You must record progress in todo.md, including what has been completed, any new tasks, and any context that might be required for a future agent picking up the project. 
- At the top of todo.md, write and update a plan for what needs to be completed next, and update it as you go. This should provide sufficient context for a future agent to pick up the project and continue working on it without needing to read through all of the commit history.
- Write documentation as you go.

## Testing Regime

### Fast unit/integration tests (run frequently, before every commit)
`busted tests/`
Runs ~1292 tests in a few seconds. Covers compiler, runtime, library API, and CLI unit tests.

### CLI integration tests (run before commits that touch the CLI or demo files)
`busted tests/cli/cli_integration_spec.lua`
~77 tests covering every CLI subcommand against all test*.sb and demo*.sb files.
Uses `--auto --steps N` for non-interactive run tests.

### CLI non-interactive mode
`lua5.4 cli/main.lua run --auto demos/demo01_wanderer.sb`
`lua5.4 cli/main.lua run --auto --steps 10 demos/demo05_siege.sb`
The `--auto` flag always picks choice 1. `--steps N` limits turns to avoid precondition violations in demos with finite game states.

### CLI single-step scripting mode (preferred for game testing)
Use `--cli` mode as the default approach for testing game logic, state transitions, and multi-step sequences — unless specifically testing a UI component (e.g. the web debugger).

Basic usage:
```
SAVE=$(mktemp /tmp/test.XXXXXX.sbd)
echo "" | timeout 30 lua5.4 cli/main.lua run demos/demo01_wanderer.sb --cli "$SAVE" --reset
echo "1" | timeout 30 lua5.4 cli/main.lua run demos/demo01_wanderer.sb --cli "$SAVE"
rm -f "$SAVE" "$SAVE.snap"
```

**Always wrap CLI invocations with `timeout 30`** to prevent hangs in automated or test contexts.

Each call reads one choice from stdin, emits one JSON object to stdout, and persists state to `save.sbd` + `save.sbd.snap`. This allows long sequences to be tested step-by-step without an interactive terminal. For scripted sequences, loop with `echo "<choice>" | timeout 30 lua5.4 cli/main.lua run game.sb --cli save.sbd`.

The `--reset` flag starts from the initial state, discarding any prior save.

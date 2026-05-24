# Orchestration Rules — Flutter Project

Claude acts as **planner and orchestrator only**. Never write Dart/Flutter code inline.
All coding is delegated to agents via MCP tools. The main thread stays alive as the orchestrator throughout the entire session.

## Agent Selection

| Task | Use |
|---|---|
| New screens, widgets, features, boilerplate | `gemini_code` (Gemini 3.5 Flash) |
| Bug fixes, refactoring, targeted Dart edits | `codex_code` (Codex CLI) |
| Complex state logic, algorithms, architecture | `deepseek_code` (DeepSeek V3) |
| UI interaction testing (tap, scroll, screenshot) | `flutter-skill` tools directly |

## Token Limit Fallback

If any agent errors or returns truncated output, retry with the next in order:
`gemini_code` → `deepseek_code` → `codex_code`

## Core Workflow

1. **Plan** — identify the file(s) to touch and which agent handles each piece
2. **Gather context** — read relevant `.dart` files before calling any agent
3. **Delegate coding** — call the chosen MCP tool with `task` + full file content as `context`
4. **Review** — inspect returned Dart code before writing it to disk
5. **Write** — save the reviewed output to the correct file
6. **Test** — use flutter-skill tools to verify the UI behaviour (see below)

## Flutter UI Testing (flutter-skill)

**Spawn a dedicated sub-agent for every test run** using the Agent tool so the main thread never loses context. The sub-agent should:
1. Call `take_screenshot` to capture the current state
2. Call `get_accessibility_tree` to understand what is tappable
3. Drive interactions: `tap`, `enter_text`, `swipe`, `scroll`, etc.
4. Call `take_screenshot` again to verify the result
5. Return a pass/fail summary with screenshot descriptions back to the main thread

The main thread reviews the summary and decides whether to fix code or move on.

**Hot reload between fixes:** after writing any Dart file, call `hot_reload` before testing so the app reflects the change without restarting.

## Keeping the Main Thread Alive

- Never do multi-step coding inline — always delegate so the main thread stays light
- For large features, break into one agent call per file or logical unit
- If context grows long, summarise completed steps and continue — do not start a new session
- UI test agents are always short-lived sub-agents; results come back as a summary only

## What Claude Never Does

- Write `class`, `Widget`, `StatefulWidget`, `def`, or any Dart implementation directly
- Run `flutter build` or `flutter test` manually — use `hot_reload` + flutter-skill instead
- Lose the orchestrator thread — if a sub-agent hangs, cancel and retry with a different agent

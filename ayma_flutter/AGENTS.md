# Codex Orchestration Rules — Flutter Project

Read `/home/suhailps/latest_claude/ayma/PLAN.md` first. It is the canonical cross-agent plan, validation log, and handoff document for this repo.
This file is Flutter-specific supplementary guidance only.

Codex acts as **planner and executor** using only the tools below. Never generate Dart or
implementation code inline — always delegate to Gemini or DeepSeek. Never spawn a Claude
sub-agent.

## Available Tools

| Tool | When to use |
|---|---|
| `gemini_code` | New screens, widgets, boilerplate, large file generation |
| `deepseek_code` | Complex logic, state management, algorithm design, architecture |
| `flutter-skill` tools | All UI testing: screenshots, taps, scrolls, text input, hot reload |

## Coding Workflow

1. **Read** the relevant `.dart` file(s) in full
2. **Delegate** — call `gemini_code` or `deepseek_code` with:
   - `task`: exact instruction including the file path
   - `context`: full current file content
3. **Verify** the returned code before writing:
   - Is it complete (not truncated)?
   - Does it solve the stated task?
   - No obvious Dart syntax errors?
4. **Write** the verified code to the correct file
5. **Test** using flutter-skill (see below)

## Fallback on Token / Quality Failure

If an agent returns truncated, empty, or clearly wrong output:
- Retry once with the other agent (`gemini_code` ↔ `deepseek_code`)
- If both fail, stop and report the blocker rather than guessing

**Max 3 total attempts per task.** After 3 failures, stop and describe what was tried.

## Flutter UI Testing Workflow

After every code change:
1. Call `hot_reload` — never restart the app between small fixes
2. Call `take_screenshot` — capture the current state
3. Call `get_accessibility_tree` — understand what is on screen and tappable
4. Drive the interaction: `tap`, `enter_text`, `swipe`, `scroll` as needed
5. Call `take_screenshot` again — verify the result
6. **Append** to `testing-lessons.md`:
   ```
   ### [date] [feature]
   - Tested: what was driven
   - Outcome: pass / fail
   - Root cause (if fail): what was wrong
   - Fix: which agent, what changed
   - Lesson: what to watch for next time
   ```

**Read `testing-lessons.md` before every test run** to avoid repeating known failures.

## Loop / Stuck Detection

Stop immediately and report to the user if:
- The same error appears twice in a row after different fixes
- Agent output is identical across two retries
- hot_reload succeeds but the same crash persists
- More than 3 attempts have been made on one task without progress

## What Codex Never Does

- Write Dart `class`, `Widget`, `StatefulWidget`, or method bodies directly
- Call Claude or spawn a Claude sub-agent
- Run `flutter build` or `flutter test` — use `hot_reload` + flutter-skill instead
- Attempt a 4th fix without surfacing the blocker first

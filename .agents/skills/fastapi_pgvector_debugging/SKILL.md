---
name: fastapi_pgvector_debugging
description: Best practices for debugging the Python FastAPI backend, Postgres pgvector, and Gemini integration
---

# FastAPI, pgvector, and Gemini Debugging Best Practices

When maintaining or debugging the Python backend (`functions/bootstrap/main.py`), adhere to these workflows.

## 1. FastAPI Debugging
*   **Log Inspection**: The backend uses standard Python `logging`. When testing locally using `uvicorn`, keep the terminal open to monitor live logs and stack traces.
*   **Environment Constraints**: Always ensure your `.env` is loaded or environment variables (like `DATABASE_URL`, `GEMINI_API_KEY`) are correctly passed when debugging locally. Use a `.venv` (virtual environment) to avoid package conflicts.
*   **Exception Catching**: FastAPI catches generic exceptions. Watch out for `HTTPException(status_code=500)` returns. If you hit one, check the backend server logs for the raw stack trace.

## 2. PostgreSQL and pgvector
*   **Schema Verification**: Before executing raw queries in Python via `asyncpg`, ensure the `pgvector` extension is enabled in your database (`CREATE EXTENSION IF NOT EXISTS vector;`).
*   **SQL Logs**: If database writes fail silently, look for async tasks that might have swallowed `asyncpg` exceptions.
*   **Testing Match Logic**: When debugging profile matching or `vector` similarity, you can execute SQL `SELECT ... ORDER BY embedding <=> $1` queries directly in a Postgres CLI to verify semantic distance before tracing it in python.

## 3. Gemini API and WebSockets
*   **Quota Management**: The backend utilizes a key-rotation mechanism for Gemini. If you encounter `429 RESOURCE_EXHAUSTED` errors, verify that `_rotate_key()` correctly falls back to alternate keys.
*   **System Instructions**: Gemini's `system_instruction` parameter requires strict formatting (e.g., string types, not dicts). If the model "forgets" context, ensure `_build_system_prompt()` is successfully aggregating data from Postgres without raising silent errors.
*   **JSON Enforcement**: When expecting structured outputs (like `/post-turn`), always use `response_mime_type: "application/json"`. If `json.loads()` fails, check if the model is ignoring the generation config or if the prompt leaked prose.

## 4. Local Testing scripts
*   Instead of booting the full server, write small async python scripts (e.g., `test_script.py`) utilizing `asyncio.run()` to isolate and test specific backend functions (like prompt generation or pgvector queries) locally.

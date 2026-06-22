# Global Rules

## Prompts

Do NOT write any prompts inside code files (e.g., Python scripts).
All prompt templates must be saved as separate text or markdown files in a `prompts` directory and loaded dynamically by the code.

## The Karpathy AI Coding Rules
All agents operating in this workspace must adhere to the five fundamental principles of AI engineering:

1. **Think Before Coding**: Do not make assumptions. State assumptions explicitly before you start, and if a request is ambiguous or you are confused, pause to ask the user for clarification rather than guessing.
2. **Simplicity First**: Write the minimum amount of code necessary to solve the problem. Avoid speculative features, over-engineering, or creating abstractions for single-use code.
3. **Surgical Changes**: Touch only what is strictly required to fulfill the request. Do not "improve" adjacent code, refactor things that aren't broken, or change formatting unless it is explicitly part of the task.
4. **Goal-Driven Execution**: Define clear success criteria before beginning. Transform vague requests into concrete, verifiable steps.
5. **Production-Ready Code Only**: Do not write temporary hacks or workaround code. Do not leave commented-out or dead code blocks in source files. Ensure all async/future error paths are explicitly caught and handled. Every change must target clean, production-grade maintainability.

## Strict Database Rules (No Mocking)

- **NEVER use mock databases or SQLite fallbacks**: Under no circumstances should mock databases, mock SQLite fallbacks, or `USE_MOCK_DB` flags be introduced, configured, or supported in the active backend code files.
- **NEVER run with local database instances in production/Cloud Run**: The PostgreSQL database must always connect directly using the Google Cloud SQL Python Connector (`create_async_connector` + `connector.connect_async`) targeting `"ayma-ai:us-central1:ayma-db-instance"` with user `"ayma-user"`, password `"AymaSuperSecret2026!"`, and db `"ayma"`.
- **Always load environment variables safely**: Load environment variables from `.env.local` or `.env` using `python-dotenv` at the top of the entrypoint file (`main.py`) to properly retrieve secrets/API keys (such as LiveKit URLs and keys), but bypass loading them when running unit tests (e.g., `unittest`) to preserve test isolation.


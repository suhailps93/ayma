#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [[ -f "$HOME/.config/ayma/backend.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$HOME/.config/ayma/backend.env"
  set +a
fi

HOST="${AYMA_BACKEND_HOST:-127.0.0.1}"
PORT="${AYMA_BACKEND_PORT:-8000}"
MODE="${AYMA_BACKEND_MODE:-local}"

exec ./.venv/bin/python -m app.app_utils.expose_app \
  --mode "$MODE" \
  --host "$HOST" \
  --port "$PORT" \
  --local-agent app.agent.root_agent

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

if [[ -f "$HOME/.config/ayma/tunnel.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$HOME/.config/ayma/tunnel.env"
  set +a
fi

CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-$HOME/.local/bin/cloudflared}"
BACKEND_HOST="${AYMA_BACKEND_HOST:-127.0.0.1}"
BACKEND_PORT="${AYMA_BACKEND_PORT:-8000}"
TARGET_URL="${AYMA_TUNNEL_TARGET_URL:-http://${BACKEND_HOST}:${BACKEND_PORT}}"

if [[ ! -x "$CLOUDFLARED_BIN" ]]; then
  echo "cloudflared not found at $CLOUDFLARED_BIN" >&2
  echo "Install it first or set CLOUDFLARED_BIN." >&2
  exit 1
fi

if [[ -n "${CLOUDFLARED_TUNNEL_TOKEN:-}" ]]; then
  exec "$CLOUDFLARED_BIN" tunnel --no-autoupdate run --token "${CLOUDFLARED_TUNNEL_TOKEN}"
fi

echo "Starting Cloudflare quick tunnel for ${TARGET_URL}" >&2
echo "Set CLOUDFLARED_TUNNEL_TOKEN for a stable named tunnel." >&2
exec "$CLOUDFLARED_BIN" tunnel --no-autoupdate --url "${TARGET_URL}"

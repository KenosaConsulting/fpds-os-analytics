#!/usr/bin/env bash
# Run the FPDS Analytics API locally with an explicitly configured read-only DB.

set -euo pipefail

cd "$(dirname "$0")"

_kc() {
  local account="${FPDS_ANALYTICS_KEYCHAIN_ACCOUNT:-}"
  if [[ -n "$account" ]]; then
    security find-generic-password -s "$1" -a "$account" -w 2>/dev/null
  else
    security find-generic-password -s "$1" -w 2>/dev/null
  fi
}

KEYCHAIN_SERVICE="${FPDS_ANALYTICS_KEYCHAIN_SERVICE:-}"

export DB_PORT="${DB_PORT:-5432}"
export DB_NAME="${DB_NAME:-postgres}"
export DB_USER="${DB_USER:-fpds_analytics_api_readonly}"
export FPDS_ANALYTICS_REQUIRE_AUTH="${FPDS_ANALYTICS_REQUIRE_AUTH:-0}"
export FPDS_ANALYTICS_ALLOWED_ORIGINS="${FPDS_ANALYTICS_ALLOWED_ORIGINS:-http://localhost:8010,http://127.0.0.1:8010}"

if [[ -z "${ANALYTICS_DATABASE_URL:-${DATABASE_URL:-}}" ]]; then
  if [[ -z "${DB_PASS:-}" && -n "$KEYCHAIN_SERVICE" ]]; then
    export DB_PASS="$(_kc "$KEYCHAIN_SERVICE")"
  fi

  if [[ -z "${DB_HOST:-}" ]]; then
    echo "ERROR: Set ANALYTICS_DATABASE_URL, DATABASE_URL, or DB_HOST for the analytics database." >&2
    exit 1
  fi

  if [[ -z "${DB_PASS:-}" ]]; then
    echo "ERROR: Set DB_PASS or FPDS_ANALYTICS_KEYCHAIN_SERVICE for an approved local Keychain item." >&2
    exit 1
  fi
fi

if [[ -x ./.venv/bin/uvicorn ]]; then
  exec ./.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port "${PORT:-8010}" --log-level info
fi

if command -v uvicorn >/dev/null 2>&1; then
  exec uvicorn app.main:app --host 127.0.0.1 --port "${PORT:-8010}" --log-level info
fi

CHATBOT_UVICORN="../chatbot-api/.venv/bin/uvicorn"
if [[ -x "$CHATBOT_UVICORN" ]]; then
  exec "$CHATBOT_UVICORN" app.main:app --host 127.0.0.1 --port "${PORT:-8010}" --log-level info
fi

echo "ERROR: uvicorn not found. Create .venv and install requirements.txt first." >&2
exit 1

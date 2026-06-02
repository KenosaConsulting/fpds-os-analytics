#!/usr/bin/env bash
# Run the FPDS Analytics API locally with the isolated read-only DB role.

set -euo pipefail

cd "$(dirname "$0")"

_kc() {
  security find-generic-password -s "$1" -a "kenosa-consulting" -w 2>/dev/null
}

KEYCHAIN_SERVICE="${FPDS_ANALYTICS_KEYCHAIN_SERVICE:-fpds-analytics-api-db-password}"

export DB_HOST="${DB_HOST:-db.tfrhforjvaafmqmxmtrt.supabase.co}"
export DB_PORT="${DB_PORT:-5432}"
export DB_NAME="${DB_NAME:-postgres}"
export DB_USER="${DB_USER:-fpds_analytics_api_readonly}"
export DB_PASS="${DB_PASS:-$(_kc "$KEYCHAIN_SERVICE")}"
export FPDS_ANALYTICS_REQUIRE_AUTH="${FPDS_ANALYTICS_REQUIRE_AUTH:-0}"
export FPDS_ANALYTICS_ALLOWED_ORIGINS="${FPDS_ANALYTICS_ALLOWED_ORIGINS:-http://localhost:8010,http://127.0.0.1:8010}"

if [[ -z "${DB_PASS:-}" ]]; then
  echo "ERROR: Keychain entry '$KEYCHAIN_SERVICE' was not found." >&2
  exit 1
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

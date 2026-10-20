#!/usr/bin/env bash
# Register the generated bridge appservices with Continuwuity, then start them.
#
# Run this AFTER creating the first (admin) account in Element.
#
# Usage: ./scripts/register-bridges.sh [--user admin] [--token TOKEN] [--room-id ROOM]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [[ ! -f .env ]]; then
  echo "error: .env not found; run ./setup.sh first" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

USER=""
TOKEN=""
ROOM_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --room-id) ROOM_ID="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${BRIDGES:-}" ]]; then
  echo "No bridges configured in .env (BRIDGES is empty)."
  exit 0
fi

if [[ -z "$TOKEN" && -z "$USER" ]]; then
  read -r -p "Admin username (localpart, e.g. admin): " USER
fi

ARGS=(--domain "$SERVER_NAME" --bridges "$BRIDGES")
[[ -n "$USER" ]] && ARGS+=(--user "$USER")
[[ -n "$TOKEN" ]] && ARGS+=(--token "$TOKEN")
[[ -n "$ROOM_ID" ]] && ARGS+=(--room-id "$ROOM_ID")

python3 scripts/matrix_admin.py "${ARGS[@]}"

echo
echo "Starting bridge containers..."
docker compose up -d

echo
echo "Bridges registered. Now log in to each network:"
echo "  Telegram: chat with @telegrambot:${SERVER_NAME} and send: login"
echo "  Discord:  chat with @discordbot:${SERVER_NAME} and send: login"
echo "  WhatsApp: chat with @whatsappbot:${SERVER_NAME} and send: login"
echo "  Signal:   chat with @signalbot:${SERVER_NAME} and send: login"
echo
echo "If a registration failed, open the admin room and send the command manually"
echo "(see README.md → Bridges)."

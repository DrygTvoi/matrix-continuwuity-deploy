#!/usr/bin/env bash
# Restore a local backup produced by scripts/backup.sh.
#
# Usage: ./scripts/restore.sh <backup-dir|latest> [--force]
#
# This stops the whole stack and overwrites data/, config/, bridges/ and .env.
# It is intentionally strict: pass --force in scripts, or confirm interactively.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-latest}"
FORCE=0
[[ "${2:-}" == "--force" ]] && FORCE=1

if [[ "$TARGET" == "latest" ]]; then
  TARGET="$(find backups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1 || true)"
fi

if [[ -z "$TARGET" || ! -f "${TARGET}/stack.tar.gz" ]]; then
  echo "error: no backup found at '${TARGET}'" >&2
  echo "usage: $0 <backup-dir|latest> [--force]" >&2
  exit 1
fi

if [[ "$FORCE" -ne 1 ]]; then
  echo "This will stop the stack and overwrite data/, config/, bridges/ and .env"
  echo "from: ${TARGET}/stack.tar.gz"
  read -r -p "Type 'restore' to continue: " answer
  [[ "$answer" == "restore" ]] || { echo "Aborted."; exit 0; }
fi

COMPOSE_CMD="docker compose"
$COMPOSE_CMD stop || true

echo "Extracting ${TARGET}/stack.tar.gz ..."
tar -xzf "${TARGET}/stack.tar.gz" -C "$ROOT"

echo "Starting stack..."
$COMPOSE_CMD up -d --force-recreate --remove-orphans

echo "Restore complete. Check logs: ${COMPOSE_CMD} logs -f --tail=100"

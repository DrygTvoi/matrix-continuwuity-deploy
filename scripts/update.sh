#!/usr/bin/env bash
# Pull pinned image versions and recreate changed containers.
#
# Image tags are pinned in docker-compose.yml and updated by Renovate.
# To upgrade manually, change the tag there and run this script.
#
# Usage: ./scripts/update.sh [--no-backup]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NO_BACKUP=0
case "${1:-}" in
  --no-backup) NO_BACKUP=1 ;;
  -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 1 ;;
esac

if [[ ! -f .env ]]; then
  echo "error: .env not found; run ./setup.sh first" >&2
  exit 1
fi

if [[ "$NO_BACKUP" -eq 0 ]]; then
  ./scripts/backup.sh
fi

COMPOSE_CMD="docker compose"

echo "Pulling images..."
$COMPOSE_CMD pull

echo "Recreating changed containers..."
$COMPOSE_CMD up -d --remove-orphans

echo "Removing dangling images..."
docker image prune -f >/dev/null || true

echo
$COMPOSE_CMD ps

#!/usr/bin/env bash
# Consistent local backup of the homeserver, bridge databases and configs.
# Optional off-site copy via restic when RESTIC_REPOSITORY is set in .env.
#
# Usage: ./scripts/backup.sh

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "error: .env not found; run ./setup.sh first" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

COMPOSE_CMD="docker compose"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
DEST="backups/${STAMP}"
mkdir -p "$DEST"

SERVICES="continuwuity"
if [[ -n "${BRIDGES:-}" ]]; then
  IFS=',' read -ra _bridges <<< "$BRIDGES"
  for b in "${_bridges[@]}"; do
    SERVICES="${SERVICES} mautrix-${b}"
  done
fi

RUNNING="$($COMPOSE_CMD ps --services --status running 2>/dev/null || true)"
STOP_SERVICES=""
for s in $SERVICES; do
  if printf '%s\n' "$RUNNING" | grep -qx "$s"; then
    STOP_SERVICES="${STOP_SERVICES} ${s}"
  fi
done

start_services() {
  # shellcheck disable=SC2086
  [[ -n "${STOP_SERVICES// /}" ]] && $COMPOSE_CMD start $STOP_SERVICES >/dev/null 2>&1 || true
}
trap start_services EXIT

if [[ -n "${STOP_SERVICES// /}" ]]; then
  echo "Stopping database services:${STOP_SERVICES}"
  # shellcheck disable=SC2086
  $COMPOSE_CMD stop $STOP_SERVICES
else
  echo "Database services are already stopped; archiving as-is."
fi

echo "Archiving data, configs and bridge state..."
tar -C "$ROOT" -czf "${DEST}/stack.tar.gz" \
  data \
  config \
  .env \
  bridges

start_services
trap - EXIT
if [[ -n "${STOP_SERVICES// /}" ]]; then
  echo "Services restarted."
fi

# Optional off-site copy.
if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
  if command -v restic >/dev/null 2>&1; then
    echo "Uploading to restic: ${RESTIC_REPOSITORY}"
    restic backup "${DEST}" --tag matrix
    restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
  else
    echo "warning: RESTIC_REPOSITORY is set but restic is not installed" >&2
  fi
fi

# Local retention.
find backups -mindepth 1 -maxdepth 1 -type d -mtime +"${BACKUP_RETENTION_DAYS:-14}" \
  -exec rm -rf {} + 2>/dev/null || true

echo
echo "Backup written to ${ROOT}/${DEST}"
du -sh "${DEST}" 2>/dev/null || true

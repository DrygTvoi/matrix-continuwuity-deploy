#!/usr/bin/env bash
# Open the required ports and install a fail2ban jail for failed logins.
#
# Usage: sudo ./scripts/harden.sh [--no-firewall] [--no-fail2ban]
#
# Note: Docker publishes ports through iptables; ufw/firewalld rules alone do
# not restrict them. Use your provider's firewall/security group for strict
# inbound control, or add DOCKER-USER rules yourself.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DO_FIREWALL=1
DO_FAIL2BAN=1
for arg in "$@"; do
  case "$arg" in
    --no-firewall) DO_FIREWALL=0 ;;
    --no-fail2ban) DO_FAIL2BAN=0 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "error: run as root (sudo $0)" >&2
  exit 1
fi

TCP_PORTS=(80 443 3478 7881)
UDP_PORTS=(443 3478 7881)
UDP_RANGES=("49160-49200" "50000-50100")

open_firewall_firewalld() {
  echo "Configuring firewalld..."
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  local p
  for p in "${TCP_PORTS[@]}"; do firewall-cmd --permanent --add-port="${p}/tcp"; done
  for p in "${UDP_PORTS[@]}"; do firewall-cmd --permanent --add-port="${p}/udp"; done
  for p in "${UDP_RANGES[@]}"; do firewall-cmd --permanent --add-port="${p}/udp"; done
  firewall-cmd --reload
  firewall-cmd --list-all
}

open_firewall_ufw() {
  echo "Configuring ufw..."
  local p
  for p in "${TCP_PORTS[@]}"; do ufw allow "${p}/tcp"; done
  for p in "${UDP_PORTS[@]}"; do ufw allow "${p}/udp"; done
  for p in "${UDP_RANGES[@]}"; do ufw allow "${p}/udp"; done
  ufw status verbose
}

if [[ "$DO_FIREWALL" -eq 1 ]]; then
  if command -v firewall-cmd >/dev/null 2>&1; then
    open_firewall_firewalld
  elif command -v ufw >/dev/null 2>&1; then
    open_firewall_ufw
  else
    echo "warning: neither firewalld nor ufw found. Open these manually:" >&2
    echo "  TCP: 80, 443, 3478, 7881" >&2
    echo "  UDP: 443, 3478, 7881, 49160-49200, 50000-50100" >&2
  fi
  echo
  echo "NOTE: Docker bypasses ufw/firewalld for published container ports."
  echo "      fail2ban iptables rules may not see Docker-forwarded traffic either."
  echo "      Use your cloud provider's firewall for strict inbound rules."
fi

if [[ "$DO_FAIL2BAN" -eq 1 ]]; then
  if command -v fail2ban-client >/dev/null 2>&1; then
    echo "Installing fail2ban jail for Caddy..."
    install -D -m 0644 config/fail2ban/filter.d/caddy-auth.conf \
      /etc/fail2ban/filter.d/caddy-auth.conf
    LOG_DIR="${ROOT}/data/caddy/data/logs"
    LOG_UID="$(stat -c %u "$ROOT")"
    LOG_GID="$(stat -c %g "$ROOT")"
    if [[ ! -d "$LOG_DIR" ]]; then
      install -d -o "$LOG_UID" -g "$LOG_GID" -m 0755 "$LOG_DIR"
    else
      chown "$LOG_UID:$LOG_GID" "$LOG_DIR" 2>/dev/null || true
    fi
    if [[ ! -e "$LOG_DIR/access-hs.log" ]]; then
      install -o "$LOG_UID" -g "$LOG_GID" -m 0644 /dev/null "$LOG_DIR/access-hs.log"
    else
      chown "$LOG_UID:$LOG_GID" "$LOG_DIR/access-hs.log" 2>/dev/null || true
    fi
    cat > /etc/fail2ban/jail.d/caddy-auth.local <<EOF
[caddy-auth]
enabled = true
filter = caddy-auth
port = http,https
logpath = ${ROOT}/data/caddy/data/logs/access-*.log
backend = auto
maxretry = 10
findtime = 10m
bantime = 1h
EOF
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    fail2ban-client reload
    fail2ban-client status caddy-auth || true
  else
    echo "fail2ban is not installed; skipping. Install it with:"
    echo "  Fedora: sudo dnf install fail2ban"
    echo "  Debian: sudo apt-get install fail2ban"
  fi
fi

echo
echo "Done. Re-run ./scripts/harden.sh after changing the log path or ports."

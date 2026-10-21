#!/usr/bin/env bash
# setup.sh — one-command Continuwuity Matrix server
#
# Generates .env and config/, then (unless --no-start) pulls and starts the stack.
#
# Usage:
#   ./setup.sh                 interactive
#   ./setup.sh --no-start      generate configs only
#   ./setup.sh --force         overwrite an existing .env/config
#   ./setup.sh --rotate-secrets  generate new secrets instead of reusing .env
#   ./setup.sh --reset-bridges   regenerate bridge registrations
#   ./setup.sh --install-deps  install missing packages without asking
#   NON_INTERACTIVE=1 DOMAIN=... SERVER_IP=... ADMIN_EMAIL=... ./setup.sh --no-start
#
# Reverse proxy:
#   PROXY_MODE=auto (default) detects a reverse proxy already listening on
#   80/443. If one is found, the bundled Caddy runs behind it on an internal
#   port and integration snippets are written to config/proxy/.
#   Override with PROXY_MODE=bundled or PROXY_MODE=external.
#
# Custom hostnames (optional; default to <service>.<domain>):
#   ELEMENT_HOST=... CALL_HOST=... SFU_HOST=... TURN_HOST=...
#   NTFY_HOST=... STATUS_HOST=... BRIDGE_HOST=...
#
# Re-runs:
#   Existing .env values and secrets are reused, generated configs are
#   rewritten, and the core containers are recreated. Use --rotate-secrets to
#   replace the TURN/LiveKit/registration secrets.
#
# Missing packages are installed through apt, dnf, pacman or zypper after
# confirmation; set INSTALL_DEPS=1 to skip the confirmation.
#
# Recommended: run on a fresh server after the DNS records are in place.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_CMD="docker compose"
FORCE=0
NO_START=0
ROTATE_SECRETS=0
RESET_BRIDGES=0
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
INSTALL_DEPS="${INSTALL_DEPS:-0}"
OLD_DOMAIN=""

EXISTING_INSTALL=0
if [[ -f .env || -f config/continuwuity.toml ]]; then
  EXISTING_INSTALL=1
fi

PROXY_MODE_EXPLICIT=0
if [[ -n "${PROXY_MODE:-}" ]]; then
  PROXY_MODE_EXPLICIT=1
fi
PROXY_MODE="${PROXY_MODE:-auto}"          # auto | bundled | external
EXTERNAL_PROXY="${EXTERNAL_PROXY:-}"      # nginx, traefik, caddy, haproxy, apache, ...
PROXY_CONTAINER="${PROXY_CONTAINER:-}"    # container publishing 80/443, if any
CADDY_INTERNAL_PORT_EXPLICIT=0
if [[ -n "${CADDY_INTERNAL_PORT:-}" ]]; then
  CADDY_INTERNAL_PORT_EXPLICIT=1
fi
CADDY_INTERNAL_PORT="${CADDY_INTERNAL_PORT:-}"
CADDY_INTERNAL_BIND="${CADDY_INTERNAL_BIND:-}"
PROXY_UPSTREAM=""

BRIDGES_EXPLICIT=0
if [[ -n "${BRIDGES+x}" ]]; then
  BRIDGES_EXPLICIT=1
fi
BRIDGES="${BRIDGES:-}"
SERVER_IP="${SERVER_IP:-}"
REG_MODE="${REG_MODE:-}"

ELEMENT_HOST="${ELEMENT_HOST:-}"
CALL_HOST="${CALL_HOST:-}"
SFU_HOST="${SFU_HOST:-}"
TURN_HOST="${TURN_HOST:-}"
NTFY_HOST="${NTFY_HOST:-}"
STATUS_HOST="${STATUS_HOST:-}"
BRIDGE_HOST="${BRIDGE_HOST:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step() { echo -e "\n${BLUE}${BOLD}▶  $1${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "  ${RED}✗${NC}  $1"; }
info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '/^set -euo/d; s/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --no-start) NO_START=1 ;;
    --rotate-secrets) ROTATE_SECRETS=1 ;;
    --reset-bridges) RESET_BRIDGES=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    -h|--help) usage 0 ;;
    *) err "Unknown argument: $1"; usage 1 ;;
  esac
  shift
done

ask() {
  local prompt="$1" default="${2:-}" value
  # Prompts go to stderr: callers capture stdout with $(...), and the prompt
  # must not become part of the returned value.
  if [[ -n "$default" ]]; then
    echo -ne "  ${BOLD}${prompt}${NC} [${CYAN}${default}${NC}]: " >&2
  else
    echo -ne "  ${BOLD}${prompt}${NC}: " >&2
  fi
  read -r value
  echo "${value:-$default}"
}

ask_yes_no() {
  local prompt="$1" default="${2:-n}" value
  echo -ne "  ${BOLD}${prompt}${NC} [${default}]: " >&2
  read -r value
  value="${value:-$default}"
  [[ "${value,,}" == "y" || "${value,,}" == "yes" ]]
}

confirm() {
  local prompt="$1" default="${2:-n}" value
  echo -ne "  ${BOLD}${prompt}${NC} [${default}]: " >&2
  read -r value
  value="${value:-$default}"
  [[ "${value,,}" == "y" || "${value,,}" == "yes" ]]
}

saved_env_value() {
  local key="$1" line
  [[ -f .env ]] || return 0
  line="$(grep -m1 "^${key}=" .env 2>/dev/null || true)"
  printf '%s' "${line#*=}"
}

# The helpers below recover values from generated configs when .env is
# missing (for example after a partial restore). They never overwrite .env.
existing_server_name() {
  local value
  value="$(saved_env_value SERVER_NAME)"
  if [[ -z "$value" && -f config/continuwuity.toml ]]; then
    value="$(sed -n 's/^server_name = "\([^"]*\)"$/\1/p' config/continuwuity.toml)"
    value="${value%%$'\n'*}"
  fi
  printf '%s' "$value"
}

existing_admin_email() {
  local value
  value="$(saved_env_value ADMIN_EMAIL)"
  if [[ -z "$value" && -f config/Caddyfile ]]; then
    value="$(sed -n 's/^[[:space:]]*email[[:space:]]\{1,\}\([^[:space:]]*\)[[:space:]]*$/\1/p' config/Caddyfile)"
    value="${value%%$'\n'*}"
  fi
  printf '%s' "$value"
}

existing_server_ip() {
  local value
  value="$(saved_env_value SERVER_IP)"
  if [[ -z "$value" && -f config/turnserver.conf ]]; then
    value="$(sed -n 's/^external-ip=\(.*\)$/\1/p' config/turnserver.conf)"
    value="${value%%$'\n'*}"
  fi
  printf '%s' "$value"
}

existing_reg_mode() {
  local value
  value="$(saved_env_value REG_MODE)"
  [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
  if [[ -f config/continuwuity.toml ]]; then
    if grep -q '^yes_i_am_very_very_sure_i_want_an_open_registration_server_prone_to_abuse = true$' config/continuwuity.toml; then
      value="2"
    elif grep -q '^registration_token = ' config/continuwuity.toml; then
      value="1"
    fi
  fi
  printf '%s' "$value"
}

existing_turn_secret() {
  local value
  value="$(saved_env_value TURN_SHARED_SECRET)"
  if [[ -z "$value" && -f config/continuwuity.toml ]]; then
    value="$(sed -n 's/^turn_secret = "\([^"]*\)"$/\1/p' config/continuwuity.toml)"
    value="${value%%$'\n'*}"
  fi
  if [[ -z "$value" && -f config/turnserver.conf ]]; then
    value="$(sed -n 's/^static-auth-secret=\([^[:space:]]*\)$/\1/p' config/turnserver.conf)"
    value="${value%%$'\n'*}"
  fi
  printf '%s' "$value"
}

existing_registration_token() {
  local value
  value="$(saved_env_value REGISTRATION_TOKEN)"
  if [[ -z "$value" && -f config/continuwuity.toml ]]; then
    value="$(sed -n 's/^registration_token = "\([^"]*\)"$/\1/p' config/continuwuity.toml)"
    value="${value%%$'\n'*}"
  fi
  printf '%s' "$value"
}

existing_livekit_key() {
  local value line
  value="$(saved_env_value LIVEKIT_API_KEY)"
  if [[ -z "$value" && -f config/livekit.yaml ]]; then
    line="$(sed -n '/^keys:/{n;p;q;}' config/livekit.yaml)"
    line="${line#"${line%%[![:space:]]*}"}"
    value="${line%%:*}"
  fi
  printf '%s' "$value"
}

existing_livekit_secret() {
  local value line
  value="$(saved_env_value LIVEKIT_API_SECRET)"
  if [[ -z "$value" && -f config/livekit.yaml ]]; then
    line="$(sed -n '/^keys:/{n;p;q;}' config/livekit.yaml)"
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" == *": "* ]]; then
      value="${line#*: }"
    fi
  fi
  printf '%s' "$value"
}

load_saved_proxy_mode() {
  [[ "$PROXY_MODE_EXPLICIT" -eq 0 ]] || return 0
  local saved
  saved="$(saved_env_value PROXY_MODE)"
  if [[ "$saved" == "external" ]]; then
    PROXY_MODE="external"
  fi
}

load_saved_hosts() {
  local saved_domain var
  saved_domain="$(existing_server_name)"
  [[ -n "$saved_domain" ]] || return 0
  [[ "${saved_domain,,}" == "${DOMAIN,,}" ]] || return 0
  for var in ELEMENT_HOST CALL_HOST SFU_HOST TURN_HOST NTFY_HOST STATUS_HOST BRIDGE_HOST; do
    if [[ -z "${!var}" ]]; then
      printf -v "$var" '%s' "$(saved_env_value "$var")"
    fi
  done
}

gen_hex() { openssl rand -hex "$1"; }

detect_pkg_family() {
  local os_id="" os_like=""
  if [[ -r /etc/os-release ]]; then
    os_id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
    os_like="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")"
  fi
  local key=" ${os_id,,} ${os_like,,} "
  case "$key" in
    *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*) echo apt ;;
    *" arch "*|*" manjaro "*|*" endeavouros "*) echo pacman ;;
    *" fedora "*) echo dnf ;;
    *" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*|*" amzn "*) echo dnf-rhel ;;
    *" opensuse"*|*" suse "*) echo zypper ;;
    *) echo unknown ;;
  esac
}

pkg_family_label() {
  case "$1" in
    apt) echo "Debian/Ubuntu (apt)" ;;
    dnf) echo "Fedora (dnf)" ;;
    dnf-rhel) echo "RHEL-family (dnf)" ;;
    pacman) echo "Arch Linux (pacman)" ;;
    zypper) echo "openSUSE (zypper)" ;;
    *) echo "unknown distribution" ;;
  esac
}

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_docker_apt_repo() {
  local os_id codename arch
  os_id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
  codename="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")"
  arch="$(dpkg --print-architecture)"
  [[ "$os_id" == "debian" || "$os_id" == "ubuntu" ]] || return 1
  [[ -n "$codename" ]] || return 1

  info "Adding Docker's official apt repository..."
  run_as_root install -m 0755 -d /etc/apt/keyrings || return 1
  curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" \
    | run_as_root tee /etc/apt/keyrings/docker.asc >/dev/null || return 1
  run_as_root chmod a+r /etc/apt/keyrings/docker.asc || return 1
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${os_id} ${codename} stable" \
    | run_as_root tee /etc/apt/sources.list.d/docker.list >/dev/null || return 1
  run_as_root apt-get update || return 1
}

install_docker_dnf_repo() {
  info "Adding Docker's official dnf repository..."
  run_as_root dnf install -y dnf-plugins-core || return 1
  if ! run_as_root dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo; then
    run_as_root dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || return 1
  fi
}

install_system_deps() {
  local family="$1"
  case "$family" in
    apt)
      command -v apt-get >/dev/null 2>&1 || return 1
      run_as_root apt-get update || return 1
      run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        openssl curl python3 ca-certificates || return 1
      local have_docker=0
      command -v docker >/dev/null 2>&1 && have_docker=1
      if [[ "$have_docker" -eq 1 ]]; then
        if ! docker compose version >/dev/null 2>&1; then
          if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
            run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
              docker-compose-v2 || return 1
          else
            warn "Docker is installed without the Compose v2 plugin."
            warn "Refusing to replace the Docker engine automatically."
            return 2
          fi
        fi
      elif apt-cache show docker.io >/dev/null 2>&1 \
           && apt-cache show docker-compose-v2 >/dev/null 2>&1; then
        run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
          docker.io docker-compose-v2 || return 1
      else
        info "docker-compose-v2 is not in this distribution's repositories; using Docker's official repository."
        install_docker_apt_repo || return 1
        run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
          docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
      fi
      ;;
    dnf)
      command -v dnf >/dev/null 2>&1 || return 1
      run_as_root dnf install -y openssl curl python3 ca-certificates || return 1
      if ! run_as_root dnf install -y docker-ce docker-ce-cli containerd.io \
           docker-buildx-plugin docker-compose-plugin; then
        info "Docker CE is not configured yet; adding Docker's official repository."
        install_docker_dnf_repo || return 1
        run_as_root dnf install -y docker-ce docker-ce-cli containerd.io \
          docker-buildx-plugin docker-compose-plugin || return 1
      fi
      ;;
    dnf-rhel)
      err "Automatic installation is not supported on RHEL/CentOS/Rocky/AlmaLinux."
      info "Install Docker Engine + Compose plugin from https://docs.docker.com/engine/install/"
      return 2
      ;;
    pacman)
      command -v pacman >/dev/null 2>&1 || return 1
      run_as_root pacman -Sy --needed --noconfirm \
        docker docker-compose openssl curl python ca-certificates || return 1
      ;;
    zypper)
      command -v zypper >/dev/null 2>&1 || return 1
      run_as_root zypper --non-interactive install \
        docker docker-compose openssl curl python3 ca-certificates || return 1
      ;;
    *)
      return 2
      ;;
  esac

  if command -v systemctl >/dev/null 2>&1; then
    run_as_root systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  return 0
}

manual_deps_help() {
  local family="$1"
  echo
  echo -e "  ${BOLD}Install manually:${NC}"
  case "$family" in
    apt)
      echo -e "    ${CYAN}sudo apt-get update${NC}"
      echo -e "    ${CYAN}sudo apt-get install -y docker.io docker-compose-v2 openssl curl python3 ca-certificates${NC}"
      ;;
    dnf|dnf-rhel)
      echo -e "    ${CYAN}sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin${NC}"
      ;;
    pacman)
      echo -e "    ${CYAN}sudo pacman -S --needed docker docker-compose openssl curl python ca-certificates${NC}"
      ;;
    zypper)
      echo -e "    ${CYAN}sudo zypper install docker docker-compose openssl curl python3 ca-certificates${NC}"
      ;;
    *)
      echo -e "    Install Docker Engine, Docker Compose v2, openssl, curl and python3."
      ;;
  esac
  echo -e "    Docs: ${CYAN}https://docs.docker.com/engine/install/${NC}"
}

check_docker_daemon() {
  if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable"
    return 0
  fi

  local user_name="${USER:-$(id -un)}"
  if [[ "$NO_START" == "1" ]]; then
    warn "docker daemon is not reachable; continuing because --no-start was given."
    warn "Bridge containers need a running daemon to generate their configs."
    return 0
  fi
  err "docker daemon is not reachable"
  if [[ "${EUID}" -ne 0 ]] \
     && ! id -nG "$user_name" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    warn "User ${user_name} is not in the docker group."
    if [[ "$NON_INTERACTIVE" != "1" ]] && command -v sudo >/dev/null 2>&1 \
       && confirm "Add this user to the docker group? (requires re-login)" "n"; then
      sudo usermod -aG docker "$user_name" || true
      err "Log out and back in (or run 'newgrp docker'), then re-run ./setup.sh."
      exit 1
    fi
    info "Add it with: sudo usermod -aG docker ${user_name}  (then log out and back in)"
  else
    info "Start it with: sudo systemctl enable --now docker"
  fi
  exit 1
}

check_prerequisites() {
  step "Checking prerequisites"
  local missing=()
  for cmd in docker openssl curl python3; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd"
    else
      err "$cmd — not found"
      missing+=("$cmd")
    fi
  done
  if docker compose version &>/dev/null 2>&1; then
    ok "docker compose (v2)"
    COMPOSE_CMD="docker compose"
  else
    err "docker compose v2 — not found"
    missing+=("docker compose v2")
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    check_docker_daemon
    return 0
  fi

  echo
  err "Missing: ${missing[*]}"
  local family
  family="$(detect_pkg_family)"
  info "Detected: $(pkg_family_label "$family")"

  local do_install=0
  if [[ "$INSTALL_DEPS" == "1" ]]; then
    do_install=1
  elif [[ "$NON_INTERACTIVE" == "1" ]]; then
    warn "Non-interactive mode: not installing packages automatically."
    info "Use --install-deps (or INSTALL_DEPS=1) to allow it."
  elif [[ "$family" == "unknown" || "$family" == "dnf-rhel" ]]; then
    warn "Automatic installation is not supported for this distribution."
  elif confirm "Install missing dependencies now? (uses sudo)" "n"; then
    do_install=1
  fi

  if [[ "$do_install" -ne 1 ]]; then
    manual_deps_help "$family"
    exit 1
  fi

  if [[ "$EUID" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    err "sudo is required to install packages; run this script as root or install sudo."
    exit 1
  fi

  step "Installing system dependencies"
  if ! install_system_deps "$family"; then
    err "Automatic installation failed."
    manual_deps_help "$family"
    exit 1
  fi

  local still=()
  for cmd in docker openssl curl python3; do
    command -v "$cmd" &>/dev/null || still+=("$cmd")
  done
  if ! docker compose version &>/dev/null 2>&1; then
    still+=("docker compose v2")
  fi
  if [[ ${#still[@]} -gt 0 ]]; then
    err "Still missing after installation: ${still[*]}"
    manual_deps_help "$family"
    exit 1
  fi
  ok "dependencies installed"
  check_docker_daemon
}

detect_ip() {
  curl -4 -sf --max-time 6 https://api.ipify.org 2>/dev/null \
    || curl -4 -sf --max-time 6 https://ifconfig.me 2>/dev/null \
    || true
}

normalize_domain() {
  local d="$1"
  d="${d#*://}"
  d="${d%%/*}"
  d="${d%.}"
  printf '%s' "$d"
}

is_valid_hostname() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn "sport = :${port}" 2>/dev/null | grep -q . && return 0
    ss -Hlun "sport = :${port}" 2>/dev/null | grep -q . && return 0
    return 1
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
}

ss_owner_names() {
  local port="$1" out
  out="$(ss -Hltnp "sport = :${port}" 2>/dev/null || true)"
  if [[ -z "$out" ]] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    out="$(sudo -n ss -Hltnp "sport = :${port}" 2>/dev/null || true)"
  fi
  printf '%s\n' "$out" \
    | grep -o 'users:(([^)]*' 2>/dev/null \
    | grep -o '"[^"]*"' 2>/dev/null \
    | tr -d '"' \
    | sort -u || true
}

proxy_type_from_image() {
  case "$1" in
    *traefik*)           echo traefik ;;
    *openresty*|*nginx*) echo nginx ;;
    *haproxy*)           echo haproxy ;;
    *caddy*)             echo caddy ;;
    *apache*|*httpd*)    echo apache ;;
    *envoy*)             echo envoy ;;
    *cloudflared*)       echo cloudflared ;;
    *)                   echo "docker:${1##*/}" ;;
  esac
}

proxy_type_from_process() {
  case "$1" in
    nginx|openresty) echo nginx ;;
    traefik)         echo traefik ;;
    haproxy)         echo haproxy ;;
    caddy)           echo caddy ;;
    apache2|httpd)   echo apache ;;
    envoy)           echo envoy ;;
    cloudflared)     echo cloudflared ;;
    *)               echo "process:$1" ;;
  esac
}

docker_ps_ports() {
  docker ps --format '{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}|{{.Ports}}' 2>/dev/null || true
}

own_caddy_container() {
  local name="$1" project="$2" service="$3"
  [[ "$service" == "caddy" && ( "$project" == "matrix-conduit" || "$name" == matrix-conduit-caddy-* ) ]]
}

proxy_owner_on_port() {
  local port="$1" cname cimage cproject cservice cports name
  if command -v docker >/dev/null 2>&1; then
    while IFS='|' read -r cname cimage cproject cservice cports; do
      [[ -z "$cname" ]] && continue
      if own_caddy_container "$cname" "$cproject" "$cservice"; then
        echo own
      else
        proxy_type_from_image "$cimage"
      fi
      return 0
    done < <(docker_ps_ports | awk -F'|' -v p=":${port}->" 'index($5,p)')
  fi
  for name in $(ss_owner_names "$port"); do
    case "$name" in
      docker-proxy) echo docker; return 0 ;;
      *) proxy_type_from_process "$name"; return 0 ;;
    esac
  done
  if port_in_use "$port"; then
    echo unknown
  fi
}

container_name_for_port() {
  local port="$1" cname cimage cproject cservice cports
  command -v docker >/dev/null 2>&1 || return 0
  while IFS='|' read -r cname cimage cproject cservice cports; do
    [[ -z "$cname" ]] && continue
    own_caddy_container "$cname" "$cproject" "$cservice" && continue
    printf '%s' "$cname"
    return 0
  done < <(docker_ps_ports | awk -F'|' -v p=":${port}->" 'index($5,p)')
}

choose_caddy_bind() {
  local container="$1" mode network gateway
  if [[ -n "${CADDY_INTERNAL_BIND:-}" ]]; then
    printf '%s' "$CADDY_INTERNAL_BIND"
    return 0
  fi
  if [[ -n "$container" ]]; then
    mode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$container" 2>/dev/null || true)"
    if [[ "$mode" != "host" ]]; then
      while IFS='|' read -r network gateway; do
        if [[ -n "$gateway" ]]; then
          printf '%s' "$gateway"
          return 0
        fi
      done < <(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}|{{$v.Gateway}}{{"\n"}}{{end}}' "$container" 2>/dev/null || true)
    fi
  fi
  printf '127.0.0.1'
}

pick_caddy_port() {
  local port="${CADDY_INTERNAL_PORT:-8080}"
  if [[ "$CADDY_INTERNAL_PORT_EXPLICIT" -eq 1 ]]; then
    printf '%s' "$port"
    return 0
  fi
  # Keep the previous port when it is free or owned by our own Caddy;
  # move only when another service took it.
  while port_in_use "$port" && [[ "$(proxy_owner_on_port "$port")" != "own" ]]; do
    port=$((port + 1))
  done
  printf '%s' "$port"
}

detect_reverse_proxy() {
  step "Reverse proxy"
  local owner80 owner443 chosen saved_port

  load_saved_proxy_mode
  if [[ "$CADDY_INTERNAL_PORT_EXPLICIT" -eq 0 ]]; then
    saved_port="$(saved_env_value CADDY_INTERNAL_PORT)"
    if [[ -n "$saved_port" ]]; then
      CADDY_INTERNAL_PORT="$saved_port"
    fi
  fi

  case "$PROXY_MODE" in
    auto|bundled|external) ;;
    *) err "PROXY_MODE must be auto, bundled or external"; exit 1 ;;
  esac

  owner80="$(proxy_owner_on_port 80)"
  owner443="$(proxy_owner_on_port 443)"

  if [[ "$PROXY_MODE" == "auto" ]]; then
    if [[ -z "$owner80" && -z "$owner443" ]]; then
      PROXY_MODE="bundled"
    elif [[ ( -z "$owner80" || "$owner80" == "own" ) \
         && ( -z "$owner443" || "$owner443" == "own" ) ]]; then
      PROXY_MODE="bundled"
    else
      PROXY_MODE="external"
    fi
  fi

  CADDY_INTERNAL_PORT="$(pick_caddy_port)"

  if [[ "$PROXY_MODE" == "bundled" ]]; then
    EXTERNAL_PROXY=""
    PROXY_CONTAINER=""
    CADDY_INTERNAL_BIND="$(choose_caddy_bind "")"
    PROXY_UPSTREAM="${CADDY_INTERNAL_BIND}:${CADDY_INTERNAL_PORT}"
    if [[ -n "$owner80" && "$owner80" != "own" ]] \
       || [[ -n "$owner443" && "$owner443" != "own" ]]; then
      warn "Ports 80/443 are in use (${owner443:-$owner80}), so the bundled Caddy cannot bind them."
      warn "Use PROXY_MODE=external to run behind the existing service."
    else
      ok "ports 80/443 are free; the bundled Caddy terminates TLS"
    fi
    return 0
  fi

  chosen="${owner443:-$owner80}"
  if [[ -n "$chosen" && "$chosen" != "own" ]]; then
    EXTERNAL_PROXY="$chosen"
  else
    EXTERNAL_PROXY="${EXTERNAL_PROXY:-manual}"
  fi

  PROXY_CONTAINER=""
  if [[ -n "$owner443" && "$owner443" != "own" ]]; then
    PROXY_CONTAINER="$(container_name_for_port 443)"
  elif [[ -n "$owner80" && "$owner80" != "own" ]]; then
    PROXY_CONTAINER="$(container_name_for_port 80)"
  fi
  CADDY_INTERNAL_BIND="$(choose_caddy_bind "$PROXY_CONTAINER")"
  if [[ -z "$CADDY_INTERNAL_BIND" || "$CADDY_INTERNAL_BIND" == "0.0.0.0" ]]; then
    CADDY_INTERNAL_BIND="127.0.0.1"
  fi
  PROXY_UPSTREAM="${CADDY_INTERNAL_BIND}:${CADDY_INTERNAL_PORT}"
  if [[ -n "$saved_port" && "$saved_port" != "$CADDY_INTERNAL_PORT" ]]; then
    warn "Internal Caddy port changed from ${saved_port} to ${CADDY_INTERNAL_PORT}."
    warn "Update your external proxy to the new address (see config/proxy/)."
  fi

  if [[ "$EXTERNAL_PROXY" == "manual" ]]; then
    ok "external proxy mode (no local proxy detected)"
  else
    ok "existing reverse proxy detected: ${EXTERNAL_PROXY}"
  fi
  info "the bundled Caddy will listen on ${PROXY_UPSTREAM} (HTTP only, auto-HTTPS off)"

  case "$EXTERNAL_PROXY" in
    manual) ;;
    unknown|docker|docker:*|process:*)
      warn "The software listening on 80/443 could not be identified."
      if [[ "$NON_INTERACTIVE" != "1" ]] \
         && ! confirm "Continue assuming it is a reverse proxy?" "y"; then
        info "Free ports 80/443 and re-run, or set PROXY_MODE=bundled."
        exit 1
      fi
      ;;
  esac
}

check_compose_version() {
  [[ "$PROXY_MODE" == "external" ]] || return 0
  local version lowest
  version="$(docker compose version --short 2>/dev/null || true)"
  if [[ -z "$version" ]]; then
    version="$(docker compose version 2>/dev/null \
      | grep -oE 'v?[0-9]+(\.[0-9]+)+' | sed -n '1p' || true)"
  fi
  version="${version#v}"
  [[ -z "$version" ]] && return 0
  lowest="$(printf '%s\n%s\n' "2.24.4" "$version" | sort -V | sed -n '1p')"
  if [[ "$lowest" != "2.24.4" ]]; then
    err "Docker Compose ${version} is too old for external proxy mode (need 2.24.4+)."
    info "Upgrade the compose plugin, or free ports 80/443 and use PROXY_MODE=bundled."
    exit 1
  fi
}

check_dns() {
  local resolved
  [[ -n "${SERVER_IP:-}" ]] || return 0
  resolved="$(python3 -c '
import socket, sys
try:
    infos = socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)
except OSError:
    sys.exit(1)
print(" ".join(sorted({i[4][0] for i in infos})))
' "$DOMAIN" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    warn "DNS for ${DOMAIN} does not resolve yet; Caddy needs it before requesting certificates."
    return 0
  fi
  case " $resolved " in
    *" ${SERVER_IP} "*) ;;
    *)
      warn "DNS for ${DOMAIN} resolves to ${resolved}, not ${SERVER_IP}."
      warn "If a CDN, tunnel or another proxy fronts this server, use PROXY_MODE=external."
      ;;
  esac
}

port_owner_is_stack() {
  local port="$1" cname cimage cproject cservice cports
  command -v docker >/dev/null 2>&1 || return 1
  while IFS='|' read -r cname cimage cproject cservice cports; do
    [[ "$cproject" == "matrix-conduit" ]] && return 0
  done < <(docker_ps_ports | awk -F'|' -v p=":${port}->" 'index($5,p)')
  return 1
}

check_stack_ports() {
  local port
  if $COMPOSE_CMD ps --services --status running 2>/dev/null | grep -q .; then
    return 0
  fi
  for port in 3478 7881; do
    if port_in_use "$port" && ! port_owner_is_stack "$port"; then
      warn "Port ${port} is already in use by another service; LiveKit/TURN may fail to start."
    fi
  done
}

validate_hostnames() {
  local var value dup
  if ! is_valid_hostname "$DOMAIN"; then
    err "Invalid domain: ${DOMAIN}"
    exit 1
  fi
  for var in ELEMENT_HOST CALL_HOST SFU_HOST TURN_HOST NTFY_HOST STATUS_HOST BRIDGE_HOST; do
    value="${!var}"
    if ! is_valid_hostname "$value"; then
      err "Invalid hostname in ${var}: ${value}"
      exit 1
    fi
  done
  dup="$(printf '%s\n' "$DOMAIN" "$ELEMENT_HOST" "$CALL_HOST" "$SFU_HOST" \
    "$TURN_HOST" "$NTFY_HOST" "$STATUS_HOST" "$BRIDGE_HOST" | sort | uniq -d)"
  if [[ -n "$dup" ]]; then
    err "Duplicate hostnames: $(printf '%s' "$dup" | tr '\n' ' ')"
    exit 1
  fi
}

gather_settings() {
  step "Configuration"

  if [[ "$NON_INTERACTIVE" == "1" ]]; then
    local saved_domain saved_ip saved_email saved_reg
    saved_domain="$(existing_server_name)"
    DOMAIN="$(normalize_domain "${DOMAIN:-${saved_domain:-example.com}}")"
    load_saved_hosts
    saved_ip="$(existing_server_ip)"
    SERVER_IP="${SERVER_IP:-${saved_ip:-$(detect_ip)}}"
    if [[ -n "$saved_domain" && "${saved_domain,,}" == "${DOMAIN,,}" ]]; then
      saved_email="$(existing_admin_email)"
    else
      saved_email=""
    fi
    ADMIN_EMAIL="${ADMIN_EMAIL:-${saved_email:-admin@${DOMAIN}}}"
    saved_reg="$(existing_reg_mode)"
    REG_MODE="${REG_MODE:-${saved_reg:-1}}"
    if [[ "$BRIDGES_EXPLICIT" -eq 0 ]]; then
      BRIDGES="$(saved_env_value BRIDGES)"
    fi
  else
    local saved_domain saved_ip saved_email saved_reg default_bridges
    saved_domain="$(existing_server_name)"
    DOMAIN="$(ask "Your main domain (e.g. example.com)" "${DOMAIN:-$saved_domain}")"
    while [[ -z "$DOMAIN" ]]; do warn "Domain cannot be empty."; DOMAIN="$(ask "Your main domain")"; done
    DOMAIN="$(normalize_domain "$DOMAIN")"
    load_saved_hosts

    saved_ip="$(existing_server_ip)"
    local auto_ip
    auto_ip="${SERVER_IP:-${saved_ip:-$(detect_ip)}}"
    SERVER_IP="$(ask "Server public IP" "$auto_ip")"
    while [[ -z "$SERVER_IP" ]]; do warn "IP address cannot be empty."; SERVER_IP="$(ask "Server public IP")"; done

    if [[ -n "$saved_domain" && "${saved_domain,,}" == "${DOMAIN,,}" ]]; then
      saved_email="$(existing_admin_email)"
    else
      saved_email=""
    fi
    ADMIN_EMAIL="$(ask "Admin email (for Let's Encrypt)" "${ADMIN_EMAIL:-${saved_email:-admin@${DOMAIN}}}")"

    echo
    echo -e "  ${BOLD}Registration mode:${NC}"
    echo -e "    [1] Token-only ${YELLOW}(recommended)${NC} — only people with the token can register"
    echo -e "    [2] Open — anyone can register (requires an image built with the openreg feature)"
    saved_reg="$(existing_reg_mode)"
    saved_reg="${REG_MODE:-${saved_reg:-1}}"
    local choice
    choice="$(ask "Choose [1/2]" "$saved_reg")"
    REG_MODE="${choice:-1}"

    echo
    if [[ "$BRIDGES_EXPLICIT" -eq 1 ]]; then
      default_bridges="$BRIDGES"
    else
      default_bridges="$(saved_env_value BRIDGES)"
    fi
    if [[ -n "$default_bridges" ]]; then
      if ask_yes_no "Enable bridges (Telegram/Discord/WhatsApp/Signal)?" "y"; then
        BRIDGES="$(ask "Bridges (all or comma-separated: telegram,discord,whatsapp,signal)" "$default_bridges")"
      else
        BRIDGES=""
      fi
    else
      if ask_yes_no "Enable bridges (Telegram/Discord/WhatsApp/Signal)?" "n"; then
        BRIDGES="$(ask "Bridges (all or comma-separated: telegram,discord,whatsapp,signal)" "all")"
      else
        BRIDGES=""
      fi
    fi

    echo
    if ask_yes_no "Customize service hostnames (element/call/sfu/...)?" "n"; then
      ELEMENT_HOST="$(ask "Element Web host" "${ELEMENT_HOST:-element.${DOMAIN}}")"
      CALL_HOST="$(ask "Element Call host" "${CALL_HOST:-call.${DOMAIN}}")"
      SFU_HOST="$(ask "LiveKit SFU host" "${SFU_HOST:-sfu.${DOMAIN}}")"
      TURN_HOST="$(ask "TURN host" "${TURN_HOST:-turn.${DOMAIN}}")"
      NTFY_HOST="$(ask "ntfy host" "${NTFY_HOST:-ntfy.${DOMAIN}}")"
      STATUS_HOST="$(ask "Uptime Kuma host" "${STATUS_HOST:-status.${DOMAIN}}")"
      BRIDGE_HOST="$(ask "Bridge host" "${BRIDGE_HOST:-bridge.${DOMAIN}}")"
    fi
  fi

  DOMAIN="${DOMAIN,,}"
  ELEMENT_HOST="${ELEMENT_HOST:-element.${DOMAIN}}"
  CALL_HOST="${CALL_HOST:-call.${DOMAIN}}"
  SFU_HOST="${SFU_HOST:-sfu.${DOMAIN}}"
  TURN_HOST="${TURN_HOST:-turn.${DOMAIN}}"
  NTFY_HOST="${NTFY_HOST:-ntfy.${DOMAIN}}"
  STATUS_HOST="${STATUS_HOST:-status.${DOMAIN}}"
  BRIDGE_HOST="${BRIDGE_HOST:-bridge.${DOMAIN}}"

  local _host_var _host_value
  for _host_var in ELEMENT_HOST CALL_HOST SFU_HOST TURN_HOST NTFY_HOST STATUS_HOST BRIDGE_HOST; do
    _host_value="$(normalize_domain "${!_host_var}")"
    printf -v "$_host_var" '%s' "${_host_value,,}"
  done
  validate_hostnames

  if [[ "$REG_MODE" != "1" && "$REG_MODE" != "2" ]]; then
    err "REG_MODE must be 1 or 2"
    exit 1
  fi

  BRIDGES="${BRIDGES,,}"
  if [[ "$BRIDGES" == "all" ]]; then
    BRIDGES="telegram,discord,whatsapp,signal"
  fi
  BRIDGES="${BRIDGES// /}"
  if [[ -n "$BRIDGES" ]]; then
    local b
    IFS=',' read -ra _bridges <<< "$BRIDGES"
    for b in "${_bridges[@]}"; do
      case "$b" in
        telegram|discord|whatsapp|signal) ;;
        *) err "Unknown bridge: $b"; exit 1 ;;
      esac
    done
  fi

  PUID="$(id -u)"
  PGID="$(id -g)"

  if [[ " ,$BRIDGES," == *,telegram,* ]]; then
    local saved_tg_id saved_tg_hash
    saved_tg_id="$(saved_env_value TELEGRAM_API_ID)"
    saved_tg_hash="$(saved_env_value TELEGRAM_API_HASH)"
    if [[ "$NON_INTERACTIVE" == "1" ]]; then
      TELEGRAM_API_ID="${TELEGRAM_API_ID:-$saved_tg_id}"
      TELEGRAM_API_HASH="${TELEGRAM_API_HASH:-$saved_tg_hash}"
    else
      echo
      info "Telegram bridge needs API credentials from https://my.telegram.org/apps"
      TELEGRAM_API_ID="$(ask "Telegram API ID" "${TELEGRAM_API_ID:-$saved_tg_id}")"
      TELEGRAM_API_HASH="$(ask "Telegram API hash" "${TELEGRAM_API_HASH:-$saved_tg_hash}")"
    fi
    if [[ -z "$TELEGRAM_API_ID" || -z "$TELEGRAM_API_HASH" ]]; then
      err "Telegram API ID and hash are required when the telegram bridge is enabled."
      exit 1
    fi
  else
    TELEGRAM_API_ID=""
    TELEGRAM_API_HASH=""
  fi
}

check_overwrite() {
  OLD_DOMAIN="$(existing_server_name)"
  if [[ ! -f .env && -f config/continuwuity.toml ]]; then
    warn ".env is missing, but generated configs exist."
    warn "Secrets will be recovered from those configs where possible."
    warn "Custom hostnames from .env cannot be recovered; re-enter them if needed."
    warn "Back up .env: re-runs reuse it to keep running services consistent."
  fi

  if [[ -d data/conduit ]] \
     && find data/conduit -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    warn "Old Conduit data found in data/conduit; Continuwuity cannot use it."
    warn "See README → Migrating from the old Conduit stack."
  fi

  if [[ -d data/continuwuity ]] \
     && find data/continuwuity -maxdepth 1 \( -name CURRENT -o -name IDENTITY -o -name '*.sst' -o -name 'MANIFEST-*' \) -print -quit 2>/dev/null | grep -q .; then
    if [[ -n "$OLD_DOMAIN" && "$OLD_DOMAIN" != "$DOMAIN" ]]; then
      err "SERVER_NAME is already ${OLD_DOMAIN} and the database is not empty."
      err "Continuwuity cannot change server_name without a data wipe."
      err "Use the old domain, or move data/continuwuity away to start fresh."
      exit 1
    fi
  fi

  if [[ -f .env && "$FORCE" -ne 1 && "$NON_INTERACTIVE" -ne 1 ]]; then
    warn ".env already exists."
    if [[ "$ROTATE_SECRETS" -eq 1 ]]; then
      warn "--rotate-secrets was given: TURN, LiveKit and registration secrets will change."
    else
      info "Existing secrets will be reused; generated configs will be rewritten."
    fi
    if ! confirm "Overwrite .env and all generated configs? Data in data/ is kept." "n"; then
      info "Aborted."
      exit 0
    fi
    FORCE=1
  fi
}

generate_secrets() {
  local reused=1
  if [[ "$ROTATE_SECRETS" -eq 1 ]]; then
    step "Rotating secrets"
    TURN_SHARED_SECRET=""
    LIVEKIT_API_KEY=""
    LIVEKIT_API_SECRET=""
    REGISTRATION_TOKEN=""
    reused=0
  else
    step "Preparing secrets"
    TURN_SHARED_SECRET="$(existing_turn_secret)"
    LIVEKIT_API_KEY="$(existing_livekit_key)"
    LIVEKIT_API_SECRET="$(existing_livekit_secret)"
    REGISTRATION_TOKEN="$(existing_registration_token)"
    [[ -n "$TURN_SHARED_SECRET" ]] || reused=0
    [[ -n "$LIVEKIT_API_KEY" ]] || reused=0
    [[ -n "$LIVEKIT_API_SECRET" ]] || reused=0
    [[ -n "$REGISTRATION_TOKEN" ]] || reused=0
  fi

  [[ -n "$TURN_SHARED_SECRET" ]] || TURN_SHARED_SECRET="$(gen_hex 32)"
  [[ -n "$LIVEKIT_API_KEY" ]] || LIVEKIT_API_KEY="lk_$(gen_hex 8)"
  [[ -n "$LIVEKIT_API_SECRET" ]] || LIVEKIT_API_SECRET="$(gen_hex 32)"
  [[ -n "$REGISTRATION_TOKEN" ]] || REGISTRATION_TOKEN="$(gen_hex 32)"

  if [[ "$reused" -eq 1 ]]; then
    ok "reused existing TURN, LiveKit and registration secrets"
  else
    ok "TURN shared secret"
    ok "LiveKit API key/secret"
    ok "Registration token"
  fi
}

bridge_profiles() {
  local out="" b
  if [[ -n "$BRIDGES" ]]; then
    IFS=',' read -ra _bridges <<< "$BRIDGES"
    for b in "${_bridges[@]}"; do out="${out:+$out,}$b"; done
  fi
  printf '%s' "$out"
}

write_env() {
  step "Writing .env"
  local profiles
  profiles="$(bridge_profiles)"
  umask 077
  cat > .env <<EOF
# Generated by setup.sh on $(date -u '+%Y-%m-%d %H:%M UTC')
# Never commit this file.

SERVER_NAME=${DOMAIN}
SERVER_IP=${SERVER_IP}
ADMIN_EMAIL=${ADMIN_EMAIL}
REG_MODE=${REG_MODE}
PUID=${PUID}
PGID=${PGID}

# Service hostnames
ELEMENT_HOST=${ELEMENT_HOST}
CALL_HOST=${CALL_HOST}
SFU_HOST=${SFU_HOST}
TURN_HOST=${TURN_HOST}
NTFY_HOST=${NTFY_HOST}
STATUS_HOST=${STATUS_HOST}
BRIDGE_HOST=${BRIDGE_HOST}

# Reverse proxy: bundled Caddy on 80/443, or this stack's Caddy behind an
# existing proxy on an internal port (external).
PROXY_MODE=${PROXY_MODE}
EXTERNAL_PROXY=${EXTERNAL_PROXY}
CADDY_INTERNAL_BIND=${CADDY_INTERNAL_BIND}
CADDY_INTERNAL_PORT=${CADDY_INTERNAL_PORT}
EOF
  if [[ "$PROXY_MODE" == "external" ]]; then
    printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.external.yml\n' >> .env
  fi
  cat >> .env <<EOF

REGISTRATION_TOKEN=${REGISTRATION_TOKEN}
TURN_SHARED_SECRET=${TURN_SHARED_SECRET}
LIVEKIT_API_KEY=${LIVEKIT_API_KEY}
LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET}

COMPOSE_PROFILES=${profiles}
BRIDGES=${BRIDGES}
TELEGRAM_API_ID=${TELEGRAM_API_ID}
TELEGRAM_API_HASH=${TELEGRAM_API_HASH}

NTFY_ALERT_TOPIC=alerts
BACKUP_RETENTION_DAYS=14

# Optional off-site backups (restic):
# RESTIC_REPOSITORY=s3:https://s3.example.com/bucket/matrix
# RESTIC_PASSWORD=change-me
EOF
  chmod 600 .env
  ok ".env"
}

write_configs() {
  step "Writing configuration files"
  umask 022
  mkdir -p config config/proxy data/continuwuity/backups data/caddy/data \
           data/caddy/config data/caddy/data/logs data/ntfy data/uptime-kuma backups
  chmod 755 scripts/healthcheck.sh 2>/dev/null || true

  local allow_reg reg_token_line openreg_line=""
  allow_reg="true"
  if [[ "$REG_MODE" == "1" ]]; then
    reg_token_line="registration_token = \"${REGISTRATION_TOKEN}\""
  else
    reg_token_line=""
    openreg_line="yes_i_am_very_very_sure_i_want_an_open_registration_server_prone_to_abuse = true"
  fi

  # ── Continuwuity ────────────────────────────────────────────────────────────
  cat > config/continuwuity.toml <<EOF
[global]
server_name = "${DOMAIN}"
address = "0.0.0.0"
port = 8008
database_path = "/var/lib/continuwuity"
max_request_size = 20000000

allow_registration = ${allow_reg}
${reg_token_line}
${openreg_line}

allow_encryption = true
allow_federation = true
allow_room_creation = true
default_room_version = "12"

# Bootstrap/reset the first admin account if you lose access.

# Legacy calls (TURN). TURNS/5349 is intentionally disabled: Caddy owns the
# certificates, and coturn is not given access to them. See README for TURNS.
turn_uris = [
    "turn:${TURN_HOST}:3478?transport=udp",
    "turn:${TURN_HOST}:3478?transport=tcp",
]
turn_secret = "${TURN_SHARED_SECRET}"
turn_ttl = 86400

# Online RocksDB backups: !admin server backup-database
database_backup_path = "/var/lib/continuwuity/backups"
database_backups_to_keep = 7

log = "info"

[global.well_known]
client = "https://${DOMAIN}"
server = "${DOMAIN}:443"

[global.matrix_rtc]
foci = [
    { type = "livekit", livekit_service_url = "https://${SFU_HOST}" },
]
EOF
  chmod 600 config/continuwuity.toml
  ok "config/continuwuity.toml"

  # ── LiveKit ─────────────────────────────────────────────────────────────────
  # Long-lived TURN REST credentials for the SFU (HMAC-SHA1, per coturn's
  # use-auth-secret). The expiry is 10 years out; regenerate by re-running setup.
  local lk_turn_user lk_turn_pass
  lk_turn_user="$(( $(date +%s) + 315360000 )):livekit"
  lk_turn_pass="$(printf '%s' "$lk_turn_user" | openssl dgst -sha1 -hmac "$TURN_SHARED_SECRET" -binary | openssl base64 -A)"

  cat > config/livekit.yaml <<EOF
port: 7880
bind_addresses:
  - ""
rtc:
  tcp_port: 7881
  port_range_start: 49160
  port_range_end: 49200
  use_external_ip: true
  enable_loopback_candidate: false
  turn_servers:
    - host: ${TURN_HOST}
      port: 3478
      protocol: udp
      username: "${lk_turn_user}"
      credential: "${lk_turn_pass}"
    - host: ${TURN_HOST}
      port: 3478
      protocol: tcp
      username: "${lk_turn_user}"
      credential: "${lk_turn_pass}"
keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}
room:
  auto_create: false
EOF
  chmod 600 config/livekit.yaml
  ok "config/livekit.yaml"

  # ── coturn ──────────────────────────────────────────────────────────────────
  cat > config/turnserver.conf <<EOF
listening-port=3478
min-port=50000
max-port=50100
realm=${DOMAIN}
use-auth-secret
static-auth-secret=${TURN_SHARED_SECRET}
fingerprint
no-multicast-peers
no-tls
stale-nonce=600
EOF
  if [[ -n "${SERVER_IP:-}" ]]; then
    printf 'external-ip=%s\n' "$SERVER_IP" >> config/turnserver.conf
  else
    warn "SERVER_IP is empty; coturn will auto-detect the external address. Set external-ip manually behind NAT."
  fi
  chmod 600 config/turnserver.conf
  ok "config/turnserver.conf"

  # ── Element Web ─────────────────────────────────────────────────────────────
  cat > config/element-web.json <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${DOMAIN}",
      "server_name": "${DOMAIN}"
    }
  },
  "brand": "Element",
  "disable_custom_urls": true,
  "disable_guests": true,
  "permalink_prefix": "https://${ELEMENT_HOST}",
  "element_call": {
    "url": "https://${CALL_HOST}",
    "brand": "Element Call",
    "use_exclusively": true,
    "participant_limit": 8
  },
  "features": {}
}
EOF
  chmod 644 config/element-web.json
  ok "config/element-web.json"

  # ── Element Call ────────────────────────────────────────────────────────────
  cat > config/element-call.json <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${DOMAIN}",
      "server_name": "${DOMAIN}"
    }
  },
  "livekit": {
    "livekit_service_url": "https://${SFU_HOST}"
  }
}
EOF
  chmod 644 config/element-call.json
  ok "config/element-call.json"

  # ── ntfy ────────────────────────────────────────────────────────────────────
  cat > config/ntfy.yml <<EOF
base-url: "https://${NTFY_HOST}"
listen-http: ":8080"
cache-file: "/var/cache/ntfy/cache.db"
cache-duration: "24h"
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
behind-proxy: true
enable-signup: false
enable-login: true
EOF
  chmod 644 config/ntfy.yml
  ok "config/ntfy.yml"

  write_caddyfile
  if [[ "$PROXY_MODE" == "external" ]]; then
    write_proxy_config
  fi
  write_external_compose
  chown_tree
}

write_external_compose() {
  [[ "$PROXY_MODE" == "external" ]] || return 0
  cat > docker-compose.external.yml <<EOF
# Generated by setup.sh — existing reverse-proxy mode.
# Loaded automatically through COMPOSE_FILE in .env.
services:
  caddy:
    ports: !override
      - "${CADDY_INTERNAL_BIND}:${CADDY_INTERNAL_PORT}:80"
EOF
  ok "docker-compose.external.yml"
}

write_caddyfile() {
  local global_block bridge_block="" site_prefix=""
  if [[ "$PROXY_MODE" == "external" ]]; then
    # The bundled Caddy sits behind the existing proxy, so its sites must be
    # plain HTTP on port 80. Without the scheme Caddy defaults every hostname
    # to HTTPS, listens on 443 and the published 80 port stays dead.
    site_prefix="http://"
    global_block="{
    auto_https off
    servers {
        trusted_proxies static private_ranges
    }
}"
  else
    global_block="{
    email ${ADMIN_EMAIL}
    servers {
        trusted_proxies static 127.0.0.1/32
    }
}"
  fi
  if [[ -n "$BRIDGES" ]]; then
    bridge_block="
${site_prefix}${BRIDGE_HOST} {
    encode zstd gzip
    log {
        output file /data/logs/access-bridge.log {
            roll_size 50MiB
            roll_keep 5
        }
        format json
    }
    header {
        Strict-Transport-Security \"max-age=31536000; includeSubDomains\"
        X-Content-Type-Options \"nosniff\"
        Referrer-Policy \"strict-origin-when-cross-origin\"
        -Server
    }
"
    if [[ " ,$BRIDGES," == *,telegram,* ]]; then
      bridge_block+="
    handle_path /telegram/* {
        reverse_proxy mautrix-telegram:29317
    }
"
    fi
    if [[ " ,$BRIDGES," == *,discord,* ]]; then
      bridge_block+="
    handle_path /discord/* {
        reverse_proxy mautrix-discord:29334
    }
"
    fi
    if [[ " ,$BRIDGES," == *,whatsapp,* ]]; then
      bridge_block+="
    handle_path /whatsapp/* {
        reverse_proxy mautrix-whatsapp:29318
    }
"
    fi
    if [[ " ,$BRIDGES," == *,signal,* ]]; then
      bridge_block+="
    handle_path /signal/* {
        reverse_proxy mautrix-signal:29328
    }
"
    fi
    bridge_block+="
    handle {
        respond \"Matrix bridges\" 200
    }
}
"
  fi

  cat > config/Caddyfile <<EOF
${global_block}

${site_prefix}${DOMAIN} {
    encode zstd gzip
    log {
        output file /data/logs/access-hs.log {
            roll_size 50MiB
            roll_keep 5
        }
        format json
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }
    @matrix path /_matrix/* /.well-known/matrix/* /.well-known/openid-configuration /.well-known/oauth-authorization-server /_continuwuity/*
    handle @matrix {
        reverse_proxy continuwuity:8008
    }
    handle {
        respond "Matrix homeserver ${DOMAIN}" 200
    }
}

${site_prefix}${ELEMENT_HOST} {
    encode zstd gzip
    log {
        output file /data/logs/access-element.log {
            roll_size 50MiB
            roll_keep 5
        }
        format json
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "camera=(self), microphone=(self), display-capture=(self), fullscreen=(self)"
        -Server
    }
    reverse_proxy element-web:8080
}

${site_prefix}${CALL_HOST} {
    encode zstd gzip
    log {
        output file /data/logs/access-call.log {
            roll_size 50MiB
            roll_keep 5
        }
        format json
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "camera=(self), microphone=(self), display-capture=(self), fullscreen=(self)"
        -Server
    }
    reverse_proxy element-call:8080
}

${site_prefix}${SFU_HOST} {
    encode zstd gzip
    log {
        output file /data/logs/access-sfu.log {
            roll_size 50MiB
            roll_keep 5
        }
        format json
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }
    @jwt path /sfu/get* /healthz* /get_token*
    handle @jwt {
        reverse_proxy lk-jwt:8080
    }
    handle {
        reverse_proxy livekit:7880
    }
}

${site_prefix}${NTFY_HOST} {
    encode zstd gzip
    log {
        output file /data/logs/access-ntfy.log {
            roll_size 50MiB
            roll_keep 5
        }
        format json
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }
    reverse_proxy ntfy:8080
}

${site_prefix}${STATUS_HOST} {
    encode zstd gzip
    log {
        output file /data/logs/access-status.log {
            roll_size 50MiB
            roll_keep 5
        }
        format json
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }
    reverse_proxy uptime-kuma:3001
}
${bridge_block}
EOF
  chmod 644 config/Caddyfile
  ok "config/Caddyfile"
}

http_host_list() {
  printf '%s\n' "$DOMAIN" "$ELEMENT_HOST" "$CALL_HOST" "$SFU_HOST" "$NTFY_HOST" "$STATUS_HOST"
  [[ -n "$BRIDGES" ]] && printf '%s\n' "$BRIDGE_HOST"
}

proxy_upstream() {
  local host="${CADDY_INTERNAL_BIND:-127.0.0.1}"
  [[ -z "$host" || "$host" == "0.0.0.0" ]] && host="127.0.0.1"
  printf '%s:%s' "$host" "${CADDY_INTERNAL_PORT:-8080}"
}

write_proxy_config() {
  local upstream host hosts=() server_names first_host alias_list
  local caddy_addrs traefik_rule rule_item
  upstream="$(proxy_upstream)"
  while IFS= read -r host; do
    hosts+=("$host")
  done < <(http_host_list)

  server_names="${hosts[*]}"
  first_host="${hosts[0]}"
  alias_list="${hosts[*]:1}"
  caddy_addrs=""
  traefik_rule=""
  for host in "${hosts[@]}"; do
    caddy_addrs="${caddy_addrs:+$caddy_addrs, }${host}"
    rule_item="Host(\`${host}\`)"
    traefik_rule="${traefik_rule:+$traefik_rule || }${rule_item}"
  done

  cat > config/proxy/nginx.conf <<EOF
# Generated by setup.sh — detected proxy: ${EXTERNAL_PROXY}
# Include from /etc/nginx/conf.d/ (or sites-enabled/) and reload nginx.
#
# 1. Adjust the certificate paths; the certificate must cover every
#    server_name listed below.
# 2. nginx -t && systemctl reload nginx

map \$http_upgrade \$matrix_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${server_names};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${server_names};

    ssl_certificate     /etc/letsencrypt/live/${first_host}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${first_host}/privkey.pem;

    client_max_body_size 20m;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    proxy_buffering off;

    location / {
        proxy_pass http://${upstream};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$matrix_connection_upgrade;
    }
}
EOF

  cat > config/proxy/Caddyfile <<EOF
# Generated by setup.sh — add this block to your existing Caddyfile,
# or import the file from it.
${caddy_addrs} {
    reverse_proxy ${upstream}
}
EOF

  cat > config/proxy/traefik.yml <<EOF
# Generated by setup.sh — place this in your Traefik file-provider directory,
# or merge it into the dynamic configuration.
http:
  routers:
    matrix:
      rule: "${traefik_rule}"
      entryPoints:
        - websecure
      service: matrix
      tls:
        certResolver: letsencrypt   # adjust to your resolver, or remove
  services:
    matrix:
      loadBalancer:
        servers:
          - url: "http://${upstream}"
EOF

  cat > config/proxy/apache.conf <<EOF
# Generated by setup.sh — include from your Apache configuration.
# Requires Apache 2.4.47+ with mod_proxy, mod_proxy_http, mod_ssl, mod_headers.
# Adjust the certificate paths; the certificate must cover every name below.
<VirtualHost *:80>
    ServerName ${first_host}
    ServerAlias ${alias_list}
    Redirect permanent / https://${first_host}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${first_host}
    ServerAlias ${alias_list}

    SSLEngine on
    SSLCertificateFile    /etc/letsencrypt/live/${first_host}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${first_host}/privkey.pem

    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    ProxyPass        / http://${upstream}/ upgrade=websocket
    ProxyPassReverse / http://${upstream}/
    LimitRequestBody 20971520
    ProxyTimeout 300
</VirtualHost>
EOF

  cat > config/proxy/haproxy.cfg <<EOF
# Generated by setup.sh — merge into your haproxy.cfg.
frontend matrix_https
    bind *:443 ssl crt /etc/ssl/private/${first_host}.pem
    http-request set-header X-Forwarded-Proto https
    acl is_matrix hdr(host) -i ${server_names}
    use_backend matrix_caddy if is_matrix

backend matrix_caddy
    option forwardfor
    server caddy ${upstream}
EOF

  cat > config/proxy/README.md <<EOF
# Existing reverse proxy

setup.sh detected **${EXTERNAL_PROXY}** listening on ports 80/443. The bundled
Caddy stays behind it at **${PROXY_UPSTREAM}** (HTTP only, automatic HTTPS
disabled), so all Matrix routing still lives in config/Caddyfile.

## Apply the integration

Use the snippet for your proxy; the others are provided for reference:

| Proxy | File | Where to put it |
|---|---|---|
| nginx | nginx.conf | /etc/nginx/conf.d/matrix.conf |
| Caddy | Caddyfile | import it from your Caddyfile |
| Traefik | traefik.yml | your file-provider directory |
| Apache | apache.conf | inside the Apache configuration |
| HAProxy | haproxy.cfg | merge into haproxy.cfg |

If the proxy runs in a container, copy the snippet into that container's config
volume (and reload it there) instead of a host path.

Then:

1. Make sure DNS for these names points at this server:
$(for host in "${hosts[@]}"; do printf '   - %s\n' "$host"; done)
2. Make sure the TLS certificate covers all of them, or adjust the certificate
   paths in the snippet.
3. Reload your proxy, then run: docker compose up -d
   (running ./setup.sh again is also fine).
4. Check that the homeserver answers:
   curl https://${DOMAIN}/_matrix/client/versions

The bundled Caddy is reachable at ${PROXY_UPSTREAM} and is not exposed
publicly. If your proxy runs in Docker and cannot reach that address, attach
the proxy container to the host network or share a Docker network with this
stack. Docker publishes ports around ufw/firewalld, so do not change
CADDY_INTERNAL_BIND to 0.0.0.0.

TURN and LiveKit use their own ports (3478, 7881, 49160-49200 and
50000-50100) and do not go through this proxy.
EOF

  chmod 644 config/proxy/*
  ok "config/proxy/ (integration snippets for ${EXTERNAL_PROXY})"
}

chown_tree() {
  mkdir -p data bridges
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "$PUID:$PGID" data bridges config
  elif [[ "$PUID" -ne "$(id -u)" || "$PGID" -ne "$(id -g)" ]]; then
    warn "Not running as root; cannot chown data/, bridges/ and config/ to ${PUID}:${PGID}."
  fi
  chmod 700 data backups 2>/dev/null || true
  chmod 700 data/continuwuity data/continuwuity/backups 2>/dev/null || true
}

bridge_image() {
  case "$1" in
    telegram) echo "dock.mau.dev/mautrix/telegram:v0.2610.0" ;;
    discord)  echo "dock.mau.dev/mautrix/discord:v0.7.7" ;;
    whatsapp) echo "dock.mau.dev/mautrix/whatsapp:v0.2610.0" ;;
    signal)   echo "dock.mau.dev/mautrix/signal:v0.2610.0" ;;
  esac
}

# The bridge images write config.yaml/registration.yaml as root (they exit
# before their own su-exec step). Hand the files back to the host user so the
# patcher and register-bridges.sh can read them.
fix_bridge_perms() {
  local image="$1" dir="$2"
  docker run --rm \
    -v "$SCRIPT_DIR/$dir:/data" \
    --entrypoint sh "$image" \
    -c "chown -R ${PUID}:${PGID} /data && chmod -R u+rwX,g+rX /data" \
    >/dev/null 2>&1 || true
}

setup_bridges() {
  [[ -z "$BRIDGES" ]] && return 0
  step "Preparing bridges"
  if [[ "$RESET_BRIDGES" -eq 1 ]]; then
    warn "Bridge registrations will be regenerated."
    warn "Re-register them with ./scripts/register-bridges.sh (remove the old appservices first)."
  fi
  local b image dir
  IFS=',' read -ra _bridges <<< "$BRIDGES"
  for b in "${_bridges[@]}"; do
    image="$(bridge_image "$b")"
    dir="bridges/$b"
    mkdir -p "$dir"
    if [[ ! -f "$dir/config.yaml" ]]; then
      info "Generating default $b config (image pull may take a minute)..."
      docker run --rm \
        -v "$SCRIPT_DIR/$dir:/data" \
        -e UID="$PUID" -e GID="$PGID" \
        "$image" >/dev/null
    fi
    fix_bridge_perms "$image" "$dir"
    python3 scripts/patch_bridge_config.py \
      --bridge "$b" \
      --config "$dir/config.yaml" \
      --domain "$DOMAIN" \
      --bridge-host "$BRIDGE_HOST" \
      --telegram-api-id "$TELEGRAM_API_ID" \
      --telegram-api-hash "$TELEGRAM_API_HASH"
    if [[ ! -f "$dir/registration.yaml" || "$RESET_BRIDGES" -eq 1 \
          || ( -n "$OLD_DOMAIN" && "$OLD_DOMAIN" != "$DOMAIN" ) ]]; then
      rm -f "$dir/registration.yaml"
      info "Generating $b appservice registration..."
      docker run --rm \
        -v "$SCRIPT_DIR/$dir:/data" \
        -e UID="$PUID" -e GID="$PGID" \
        "$image" >/dev/null
      fix_bridge_perms "$image" "$dir"
    fi
    if [[ ! -f "$dir/registration.yaml" ]]; then
      err "$b registration was not generated; check $dir/config.yaml"
      exit 1
    fi
    ok "$b config + registration"
  done
}

print_dns() {
  step "DNS — required records"
  echo
  echo -e "  ${BOLD}Hostname${NC}                         ${BOLD}Type${NC}  ${BOLD}Value${NC}"
  printf "  %-32s A     %s\n" "${DOMAIN}" "$SERVER_IP"
  printf "  %-32s A     %s\n" "${ELEMENT_HOST}" "$SERVER_IP"
  printf "  %-32s A     %s\n" "${CALL_HOST}" "$SERVER_IP"
  printf "  %-32s A     %s\n" "${SFU_HOST}" "$SERVER_IP"
  printf "  %-32s A     %s\n" "${TURN_HOST}" "$SERVER_IP"
  printf "  %-32s A     %s\n" "${NTFY_HOST}" "$SERVER_IP"
  printf "  %-32s A     %s\n" "${STATUS_HOST}" "$SERVER_IP"
  if [[ -n "$BRIDGES" ]]; then
    printf "  %-32s A     %s\n" "${BRIDGE_HOST}" "$SERVER_IP"
  fi
  echo
  if [[ "$PROXY_MODE" == "external" ]]; then
    warn "Your existing proxy needs these records and TLS certificates."
  else
    warn "Caddy needs DNS to resolve before it can obtain TLS certificates."
  fi
}

validate_configs() {
  step "Validating configuration"
  if $COMPOSE_CMD config --quiet 2>/dev/null; then
    ok "docker compose config"
  else
    $COMPOSE_CMD config --quiet
    err "docker compose config failed"
    exit 1
  fi
  for f in config/element-web.json config/element-call.json; do
    python3 -m json.tool "$f" >/dev/null
    ok "$f"
  done
}

start_stack() {
  if [[ "$NO_START" == "1" ]]; then
    info "Skipping start (--no-start)."
    return 0
  fi
  step "Starting core services"
  info "Pulling images — this can take a few minutes..."
  $COMPOSE_CMD pull --quiet
  local core_services=(continuwuity caddy livekit lk-jwt element-call element-web coturn ntfy uptime-kuma healthcheck)
  local bridge_services=() bridge
  if [[ "$EXISTING_INSTALL" -eq 1 ]]; then
    info "Existing installation detected; recreating core services so regenerated configs take effect."
    if [[ -n "$BRIDGES" ]]; then
      IFS=',' read -ra _bridges <<< "$BRIDGES"
      for bridge in "${_bridges[@]}"; do
        if $COMPOSE_CMD ps --services --status running 2>/dev/null | grep -qx "mautrix-${bridge}"; then
          bridge_services+=("mautrix-${bridge}")
        fi
      done
    fi
    if [[ ${#bridge_services[@]} -gt 0 ]]; then
      $COMPOSE_CMD up -d --force-recreate "${core_services[@]}" "${bridge_services[@]}"
    else
      $COMPOSE_CMD up -d --force-recreate "${core_services[@]}"
    fi
  else
    $COMPOSE_CMD up -d "${core_services[@]}"
  fi
  ok "Core services started"

  if [[ "$PROXY_MODE" == "external" ]]; then
    info "Waiting for the homeserver through your existing proxy on https://${DOMAIN} ..."
  else
    info "Waiting for the homeserver to answer on https://${DOMAIN} ..."
  fi
  local i homeserver_up=0
  for i in $(seq 1 60); do
    if curl -4 -fsS --max-time 5 "https://${DOMAIN}/_matrix/client/versions" >/dev/null 2>&1; then
      homeserver_up=1
      break
    fi
    printf "."
    sleep 5
  done
  echo
  if [[ "$homeserver_up" -eq 1 ]]; then
    ok "homeserver is up"
  elif [[ "$PROXY_MODE" == "external" ]]; then
    warn "homeserver did not answer yet."
    warn "Apply the config/proxy/ snippet to your proxy, reload it, then check:"
    warn "  ${COMPOSE_CMD} logs -f continuwuity caddy"
  else
    warn "homeserver did not answer yet. Check: ${COMPOSE_CMD} logs -f continuwuity caddy"
  fi

  # ntfy ACLs: UnifiedPush topics (up*) and the healthcheck alert topic are
  # write-only for anonymous publishers; everything else is deny-all.
  $COMPOSE_CMD exec -T ntfy ntfy access '*' 'up*' write-only >/dev/null 2>&1 || true
  $COMPOSE_CMD exec -T ntfy ntfy access '*' "${NTFY_ALERT_TOPIC:-alerts}" write-only >/dev/null 2>&1 || true
  ok "ntfy ACLs configured"
}

print_banner() {
  echo
  echo -e "  ${CYAN}${BOLD}Matrix · Continuwuity${NC}"
  echo -e "  ${CYAN}self-hosted homeserver, calls, push and bridges${NC}"
  echo
}

print_summary() {
  echo
  echo -e "  ${GREEN}${BOLD}Setup complete${NC}"
  if [[ "$NO_START" == "1" ]]; then
    warn "Nothing was started (--no-start). Run: docker compose up -d"
  fi
  echo
  echo -e "  Homeserver   : ${CYAN}https://${DOMAIN}${NC}"
  echo -e "  Element Web  : ${CYAN}https://${ELEMENT_HOST}${NC}"
  echo -e "  Element Call : ${CYAN}https://${CALL_HOST}${NC}"
  echo -e "  SFU          : ${CYAN}https://${SFU_HOST}${NC}"
  echo -e "  Push (ntfy)  : ${CYAN}https://${NTFY_HOST}${NC}"
  echo -e "  Monitoring   : ${CYAN}https://${STATUS_HOST}${NC}"
  if [[ -n "$BRIDGES" ]]; then
    echo -e "  Bridges      : ${CYAN}https://${BRIDGE_HOST}${NC} (${BRIDGES})"
  fi
  if [[ "$PROXY_MODE" == "external" ]]; then
    echo -e "  Reverse proxy: existing (${EXTERNAL_PROXY}); Caddy on ${PROXY_UPSTREAM}"
    echo -e "  Proxy config : ${CYAN}config/proxy/${NC}"
  fi
  echo
  if [[ "$REG_MODE" == "1" ]]; then
    echo -e "  ${BOLD}Registration token:${NC} ${CYAN}${REGISTRATION_TOKEN}${NC}"
    echo -e "  ${YELLOW}Share it only with people you want on this server.${NC}"
  else
    warn "Open registration is enabled. Disable it after creating your account."
  fi
  echo
  echo -e "  ${BOLD}First steps:${NC}"
  echo -e "    1. Open https://${ELEMENT_HOST} and register the first account."
  echo -e "       It becomes the server admin automatically."
  echo -e "    2. Push notifications (Android): install the ntfy app, add"
  echo -e "       https://${NTFY_HOST} as a UnifiedPush distributor, and set"
  echo -e "       https://${NTFY_HOST} as the push gateway in Element."
  echo -e "    3. Monitoring: open https://${STATUS_HOST}, create the admin"
  echo -e "       account, and add the checks listed in README.md."
  if [[ -n "$BRIDGES" ]]; then
    echo -e "    4. Register the bridges after creating the admin account:"
    echo -e "       ${CYAN}./scripts/register-bridges.sh${NC}"
    echo -e "       Then start them: ${CYAN}docker compose up -d${NC}"
  fi
  echo
  echo -e "  ${BOLD}Useful commands:${NC}"
  echo -e "    Logs          : ${CYAN}${COMPOSE_CMD} logs -f${NC}"
  echo -e "    Update        : ${CYAN}./scripts/update.sh${NC}"
  echo -e "    Backup        : ${CYAN}./scripts/backup.sh${NC}"
  echo -e "    Health check  : ${CYAN}${COMPOSE_CMD} logs -f healthcheck${NC}"
  echo -e "    Harden host   : ${CYAN}sudo ./scripts/harden.sh${NC}"
  echo
}

main() {
  print_banner
  check_prerequisites
  detect_reverse_proxy
  check_compose_version
  gather_settings
  check_dns
  check_stack_ports
  check_overwrite
  generate_secrets
  print_dns
  write_env
  write_configs
  setup_bridges
  validate_configs
  start_stack
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

#!/usr/bin/env bash
# setup.sh — bootstrap a NaïveProxy (Caddy + forwardproxy@naive) server
# from an empty VPS in one step. Idempotent; safe to re-run.
#
# Required tools: bash 4+, coreutils, curl, sudo (or run as root).
# Tested on: Ubuntu 22.04/24.04, Debian 11/12. Works on RHEL/CentOS via dnf.

set -euo pipefail
IFS=$'\n\t'

REPO_URL="https://github.com/vmhlov/naive-proxy.git"
INSTALL_DIR="/opt/naive-proxy"
# Characters allowed in PROXY_USER / PROXY_PASS. Restricting to printable
# ASCII without `:`, `@`, `/`, `\`, whitespace and quotes guarantees both
# Caddyfile parsing and the `naive+quic://USER:PASS@HOST` URL stay valid.
CRED_RE='^[A-Za-z0-9._~+=!*()\-]+$'

# ---------- helpers ----------

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Run a command as root: directly if already root, else via sudo.
SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        die "Must run as root, or install sudo first."
    fi
fi
sudo_run() { $SUDO "$@"; }

ask() {
    # ask VAR_NAME "Prompt" [default] [--silent]
    local var=$1 prompt=$2 default=${3:-} silent=${4:-}
    local cur=${!var:-}
    if [[ -n "$cur" ]]; then return 0; fi
    local reply
    while :; do
        if [[ "$silent" == "--silent" ]]; then
            read -r -s -p "$prompt: " reply || reply=""
            echo
        else
            if [[ -n "$default" ]]; then
                read -r -p "$prompt [$default]: " reply || reply=""
            else
                read -r -p "$prompt: " reply || reply=""
            fi
        fi
        reply=${reply:-$default}
        if [[ -n "$reply" ]]; then
            printf -v "$var" '%s' "$reply"
            return 0
        fi
        warn "Value cannot be empty, try again."
    done
}

# RFC 3986 percent-encoding of a single string component.
urlencode() {
    local s=$1 i ch
    local out=""
    for (( i=0; i<${#s}; i++ )); do
        ch=${s:i:1}
        case "$ch" in
            [A-Za-z0-9._~-]) out+="$ch" ;;
            *) printf -v out '%s%%%02X' "$out" "'$ch" ;;
        esac
    done
    printf '%s' "$out"
}

# ---------- 1. Docker / Compose ----------

ensure_docker() {
    if command -v docker >/dev/null 2>&1; then
        log "Docker is already installed: $(docker --version)"
    else
        log "Installing Docker via get.docker.com…"
        local tmp
        tmp=$(mktemp)
        curl -fsSL https://get.docker.com -o "$tmp"
        sudo_run sh "$tmp"
        rm -f "$tmp"
        sudo_run systemctl enable --now docker || true
    fi

    if docker compose version >/dev/null 2>&1; then
        log "docker compose plugin OK: $(docker compose version --short)"
        return
    fi

    log "Installing docker compose plugin…"
    if   command -v apt-get >/dev/null 2>&1; then
        sudo_run apt-get update -qq
        sudo_run apt-get install -y docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
        sudo_run dnf install -y docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
        sudo_run yum install -y docker-compose-plugin
    elif command -v apk >/dev/null 2>&1; then
        sudo_run apk add --no-cache docker-cli-compose
    else
        die "No supported package manager found to install docker compose plugin."
    fi

    docker compose version >/dev/null 2>&1 \
        || die "docker compose plugin still missing after install."
}

# ---------- 2. repo location ----------

ensure_repo() {
    if [[ -f "docker-compose.yml" && -f "Caddyfile.example" ]]; then
        log "Running from repository checkout: $(pwd)"
        return
    fi
    log "Not in repo checkout — cloning to $INSTALL_DIR"
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        sudo_run git -C "$INSTALL_DIR" pull --ff-only
    else
        sudo_run mkdir -p "$(dirname "$INSTALL_DIR")"
        sudo_run git clone "$REPO_URL" "$INSTALL_DIR"
    fi
    cd "$INSTALL_DIR"
}

# ---------- 3. parameters ----------

collect_params() {
    if [[ -z "${DOMAIN:-}" ]]; then
        local public_ip=""
        public_ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)
        if [[ -n "$public_ip" ]]; then
            ask DOMAIN "Domain or public IP" "${public_ip}.nip.io"
        else
            ask DOMAIN "Domain or public IP (e.g. 1.2.3.4.nip.io)"
        fi
    fi
    ask EMAIL      "E-mail for Let's Encrypt"  "admin@${DOMAIN}"
    ask PROXY_USER "Proxy username"
    ask PROXY_PASS "Proxy password" "" --silent
    : "${TZ:=Etc/UTC}"

    [[ "$PROXY_USER" =~ $CRED_RE ]] \
        || die "PROXY_USER contains forbidden chars (only [A-Za-z0-9._~+=!*()-] allowed)."
    [[ "$PROXY_PASS" =~ $CRED_RE ]] \
        || die "PROXY_PASS contains forbidden chars (only [A-Za-z0-9._~+=!*()-] allowed)."
    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] \
        || die "DOMAIN '$DOMAIN' is not a valid hostname."
    [[ "$EMAIL"  =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
        || die "EMAIL '$EMAIL' is not a valid address."
}

# ---------- 4. render config ----------

render_config() {
    log "Writing .env"
    umask 077
    cat > .env <<EOF
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
PROXY_USER=${PROXY_USER}
PROXY_PASS=${PROXY_PASS}
TZ=${TZ}
EOF
    chmod 600 .env

    local probe random
    # `head -c N | tr | head -c N` triggers SIGPIPE on the upstream `tr`
    # under `set -o pipefail`, so guard the pipeline with `|| true`.
    random=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 16 || true)
    probe="${random}.example"
    log "Writing Caddyfile (probe_resistance=${probe})"

    # Use a tab-aware sed pipeline to substitute placeholders without risk
    # of `&`/`/` interpretation in user-supplied values.
    awk \
        -v domain="$DOMAIN" \
        -v email="$EMAIL" \
        -v user="$PROXY_USER" \
        -v pass="$PROXY_PASS" \
        -v probe="$probe" \
        '{
            gsub(/\{\{DOMAIN\}\}/, domain);
            gsub(/\{\{EMAIL\}\}/, email);
            gsub(/\{\{PROXY_USER\}\}/, user);
            gsub(/\{\{PROXY_PASS\}\}/, pass);
            gsub(/\{\{PROBE_RESISTANCE\}\}/, probe);
            print;
        }' Caddyfile.example > Caddyfile
    chmod 600 Caddyfile
}

# ---------- 5. deploy ----------

deploy() {
    log "Pulling image…"
    sudo_run docker compose pull
    log "Starting container…"
    sudo_run docker compose up -d
    log "Container status:"
    sudo_run docker compose ps
}

print_link() {
    local u p
    u=$(urlencode "$PROXY_USER")
    p=$(urlencode "$PROXY_PASS")
    cat <<EOF

==============================================================================
NaïveProxy is up. First Let's Encrypt issuance may take ~30s on cold start.
Watch logs with:    docker compose logs -f
Connection link (works in naive/sing-box/NekoBox clients):

  naive+quic://${u}:${p}@${DOMAIN}:443?padding=true#Naive

Configuration files (chmod 600):
  $(pwd)/.env
  $(pwd)/Caddyfile
==============================================================================
EOF
}

# ---------- entrypoint ----------

main() {
    ensure_docker
    ensure_repo
    collect_params
    render_config
    deploy
    print_link
}

main "$@"

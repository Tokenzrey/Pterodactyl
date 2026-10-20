#!/usr/bin/env bash
# shellcheck shell=bash
# Configuration loading and validation. Sourced by ./ptero.
#
# config/deploy.env and config/versions.env are parsed, NOT sourced: a typo or a pasted `$(...)` in
# the config can never execute code. Secrets are separate files under secrets/ (mode 600).

# shellcheck disable=SC2034  # used by diag.sh
SECRET_NAMES=(db_password redis_password tunnel_token)

# load_envfile FILE : export KEY=VALUE pairs. Returns 1 (after printing every problem) on a bad file.
load_envfile() {
    local file=$1 line key val n=0 bad=0
    [[ -r $file ]] || { err "cannot read $file"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
            if [[ $val == \"* || $val == \'* ]]; then
                val=${val#?}; val=${val%%[\"\']*}
            else
                val=${val%%[[:space:]]#*}
                val=${val%"${val##*[![:space:]]}"}
            fi
            if [[ ! $val =~ ^[A-Za-z0-9._:/@,+=%-]*$ ]]; then
                err "$file:$n: value of $key has characters outside [A-Za-z0-9._:/@,+=%-]"
                bad=1; continue
            fi
            printf -v "$key" '%s' "$val"
            export "${key?}"
        else
            err "$file:$n: expected KEY=value, got: ${line:0:40}"
            bad=1
        fi
    done <"$file"
    return $bad
}

load_config() {
    load_envfile "$PTERO_ROOT/config/versions.env" || return 1
    if [[ ! -f $PTERO_ROOT/config/deploy.env ]]; then
        err "config/deploy.env does not exist. Run ./ptero init, then edit it."
        return 1
    fi
    load_envfile "$PTERO_ROOT/config/deploy.env" || return 1
    : "${APP_TIMEZONE:=UTC}" "${PANEL_BIND_PORT:=8081}" "${WINGS_API_PORT:=443}" "${TUNNEL_METRICS_PORT:=20241}"
    : "${PANEL_EDGE_SUBNET:=172.29.250.0/24}" "${WINGS_REMOTE_MODE:=public}" "${WINGS_SFTP_BIND:=127.0.0.1}" "${MIN_FREE_DISK_GB:=10}"
    : "${DB_MEM_LIMIT:=1g}" "${PANEL_MEM_LIMIT:=1g}" "${DB_BUFFER_POOL:=256M}" "${BACKUP_AGE_RECIPIENT:=}" "${PTERO_ACCEPT_BETA:=no}"
    : "${GAMES_ENABLED:=no}" "${GAMES_DOMAIN:=}" "${GAMES_PORT:=25565}" "${GAMES_BACKEND_FIRST:=25600}" "${GAMES_BACKEND_LAST:=25699}"
    : "${GAMES_NODE_ID:=1}" "${GAMES_CONN_RATE:=10}" "${GAME_NET_SUBNET:=172.18.0.0/16}"
    : "${PANEL_EXTENSIONS:=}" "${PANEL_THEME:=classic}" "${PANEL_EXTENSIONS_ENABLED:=true}" "${ACTIVITY_PRUNE_DAYS:=365}" "${WINGS_TUNING:=yes}"
    : "${FIREWALL_SSH_PORTS:=}" "${FIREWALL_SSH_ALLOW_CIDRS:=}" "${FIREWALL_SSH_LIMIT:=no}" "${FIREWALL_GAME_ALLOW_CIDRS:=}" "${FIREWALL_ROLLBACK_SECONDS:=300}"
    PTERO_PROJECT=${PTERO_PROJECT:-pterodactyl}
    PANEL_URL="https://${PANEL_FQDN:-}"
    WINGS_URL="https://${WINGS_FQDN:-}"
    export PANEL_URL WINGS_URL APP_TIMEZONE PANEL_BIND_PORT WINGS_API_PORT TUNNEL_METRICS_PORT PANEL_EDGE_SUBNET DB_MEM_LIMIT PANEL_MEM_LIMIT DB_BUFFER_POOL
    export GAMES_PORT GAMES_CONN_RATE PANEL_EXTENSIONS_ENABLED ACTIVITY_PRUNE_DAYS
}

secret_path() { printf '%s/secrets/%s\n' "$PTERO_ROOT" "$1"; }
read_secret() { local p; p=$(secret_path "$1"); [[ -r $p ]] && tr -d '\r\n' <"$p"; }

# ---- validation: collect every problem, then report once -------------------------------------
VERRORS=()
verr() { VERRORS+=("$1"); }

valid_hostname() {
    [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
    [[ $1 =~ (^|\.)(example\.(com|org|net)|localhost|invalid|test)$ ]] && return 1
    return 0
}
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_cidr() { python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1],strict=True); sys.exit(0 if n.version==4 and n.is_private and 16<=n.prefixlen<=29 else 1)' "$1" 2>/dev/null; }
valid_tz() { [[ $1 =~ ^[A-Za-z0-9_+/-]+$ ]] && { [[ ! -d /usr/share/zoneinfo ]] || [[ -f /usr/share/zoneinfo/$1 ]]; }; }

validate_games_and_firewall() {
    [[ ${GAMES_ENABLED} == yes || ${GAMES_ENABLED} == no ]] || verr "GAMES_ENABLED must be yes or no"
    local v
    for v in FIREWALL_SSH_ALLOW_CIDRS FIREWALL_GAME_ALLOW_CIDRS GAME_NET_SUBNET; do
        [[ -z ${!v} ]] || valid_cidr_list "${!v}" || verr "$v must be a comma-separated list of IPs/networks (e.g. 203.0.113.7,198.51.100.0/24)"
    done
    [[ -z ${FIREWALL_SSH_PORTS} || ${FIREWALL_SSH_PORTS} =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || verr "FIREWALL_SSH_PORTS must be a comma-separated list of ports (e.g. 22 or 22,2222)"
    [[ ${FIREWALL_SSH_LIMIT} == yes || ${FIREWALL_SSH_LIMIT} == no ]] || verr "FIREWALL_SSH_LIMIT must be yes or no"
    [[ ${FIREWALL_ROLLBACK_SECONDS} =~ ^[0-9]+$ ]] && ((FIREWALL_ROLLBACK_SECONDS == 0 || (FIREWALL_ROLLBACK_SECONDS >= 60 && FIREWALL_ROLLBACK_SECONDS <= 3600))) \
        || verr "FIREWALL_ROLLBACK_SECONDS must be 0 (no dead-man switch) or between 60 and 3600"
    [[ ${GAMES_ENABLED} == yes ]] || return 0
    if ! valid_hostname "${GAMES_DOMAIN}"; then verr "GAMES_DOMAIN='${GAMES_DOMAIN}' is not a valid public hostname (servers become <name>.GAMES_DOMAIN; example.* placeholders are rejected)"
    else
        [[ ${GAMES_DOMAIN} == "${PANEL_FQDN}" || ${GAMES_DOMAIN} == "${WINGS_FQDN}" || ${PANEL_FQDN} == *".${GAMES_DOMAIN}" || ${WINGS_FQDN} == *".${GAMES_DOMAIN}" ]] \
            && verr "GAMES_DOMAIN must be a separate name that does not contain PANEL_FQDN or WINGS_FQDN (use e.g. mc.<your domain>)"
    fi
    valid_port "${GAMES_PORT}" || verr "GAMES_PORT='${GAMES_PORT}' is not a port number"
    [[ ${GAMES_BACKEND_FIRST} =~ ^[0-9]+$ && ${GAMES_BACKEND_LAST} =~ ^[0-9]+$ ]] \
        && ((GAMES_BACKEND_FIRST >= 1024 && GAMES_BACKEND_LAST <= 65535 && GAMES_BACKEND_FIRST <= GAMES_BACKEND_LAST && GAMES_BACKEND_LAST - GAMES_BACKEND_FIRST < 1000)) \
        || verr "GAMES_BACKEND_FIRST/LAST must be ports 1024-65535, first <= last, at most 1000 apart"
    if [[ ${GAMES_PORT} =~ ^[0-9]+$ && ${GAMES_BACKEND_FIRST} =~ ^[0-9]+$ && ${GAMES_BACKEND_LAST} =~ ^[0-9]+$ ]] && ((GAMES_PORT >= GAMES_BACKEND_FIRST && GAMES_PORT <= GAMES_BACKEND_LAST)); then
        verr "GAMES_PORT must be outside the backend range ${GAMES_BACKEND_FIRST}-${GAMES_BACKEND_LAST}"
    fi
    local p
    for p in PANEL_BIND_PORT WINGS_API_PORT TUNNEL_METRICS_PORT; do
        [[ ${!p} == "${GAMES_PORT}" ]] && verr "GAMES_PORT collides with $p"
    done
    [[ ${GAMES_NODE_ID} =~ ^[0-9]+$ ]] || verr "GAMES_NODE_ID must be a number"
    [[ ${GAMES_CONN_RATE} =~ ^[0-9]+$ ]] && ((GAMES_CONN_RATE >= 1 && GAMES_CONN_RATE <= 1000)) || verr "GAMES_CONN_RATE must be 1-1000 (new connections per second the router accepts)"
}

validate_extensions() {
    [[ ${PANEL_EXTENSIONS_ENABLED} == true || ${PANEL_EXTENSIONS_ENABLED} == false ]] || verr "PANEL_EXTENSIONS_ENABLED must be true or false"
    [[ ${ACTIVITY_PRUNE_DAYS} =~ ^[0-9]+$ ]] && ((ACTIVITY_PRUNE_DAYS >= 1 && ACTIVITY_PRUNE_DAYS <= 3650)) || verr "ACTIVITY_PRUNE_DAYS must be 1-3650"
    [[ ${WINGS_TUNING} == yes || ${WINGS_TUNING} == no ]] || verr "WINGS_TUNING must be yes or no"
    [[ -z ${PANEL_EXTENSIONS} || ${PANEL_EXTENSIONS} =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || { verr "PANEL_EXTENSIONS must be a comma-separated list of extension ids (e.g. announcements,custom-buttons,unix)"; return 0; }
    [[ ${PANEL_THEME} =~ ^[a-z0-9-]+$ ]] || verr "PANEL_THEME must be classic or the id of an installed theme extension"
    local id lock="$PTERO_ROOT/extensions/extensions.lock" a
    IFS=, read -ra a <<<"${PANEL_EXTENSIONS}"
    for id in "${a[@]}"; do
        [[ -n $id ]] || continue
        grep -v '^[[:space:]]*#' "$lock" 2>/dev/null | awk -v id="$id" '$1 == id {f = 1} END {exit !f}' \
            || verr "extension '$id' is not in extensions/extensions.lock. Only reviewed, hash-pinned packages are installed (./ptero ext vet <file>)"
    done
    if [[ ${PANEL_THEME} != classic && ",${PANEL_EXTENSIONS}," != *",${PANEL_THEME},"* ]]; then
        verr "PANEL_THEME='${PANEL_THEME}' must also be listed in PANEL_EXTENSIONS (a theme is an extension)"
    fi
}

validate_config() {
    VERRORS=()
    validate_extensions
    valid_hostname "${PANEL_FQDN:-}" || verr "PANEL_FQDN='${PANEL_FQDN:-}' is not a valid public hostname (no scheme/path; example.* placeholders are rejected)"
    valid_hostname "${WINGS_FQDN:-}" || verr "WINGS_FQDN='${WINGS_FQDN:-}' is not a valid public hostname (no scheme/path; example.* placeholders are rejected)"
    [[ -n ${PANEL_FQDN:-} && ${PANEL_FQDN:-} == "${WINGS_FQDN:-}" ]] && verr "PANEL_FQDN and WINGS_FQDN must be different hostnames"
    [[ ${ADMIN_EMAIL:-} =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ && ! ${ADMIN_EMAIL:-} =~ @(example\.(com|org|net))$ ]] \
        || verr "ADMIN_EMAIL='${ADMIN_EMAIL:-}' is not a real e-mail address"
    valid_tz "${APP_TIMEZONE:-}" || verr "APP_TIMEZONE='${APP_TIMEZONE:-}' is not a known timezone (e.g. UTC, Asia/Jakarta)"
    local p
    for p in PANEL_BIND_PORT WINGS_API_PORT TUNNEL_METRICS_PORT; do
        valid_port "${!p}" || verr "$p='${!p}' is not a port number (1-65535)"
    done
    if [[ ${PANEL_BIND_PORT} == "${WINGS_API_PORT}" || ${PANEL_BIND_PORT} == "${TUNNEL_METRICS_PORT}" || ${WINGS_API_PORT} == "${TUNNEL_METRICS_PORT}" ]]; then
        verr "PANEL_BIND_PORT, WINGS_API_PORT and TUNNEL_METRICS_PORT must all differ"
    fi
    valid_cidr "${PANEL_EDGE_SUBNET}" || verr "PANEL_EDGE_SUBNET='${PANEL_EDGE_SUBNET}' must be a private IPv4 network written as base/prefix with a /16 to /29 prefix (e.g. 172.29.250.0/24)"
    [[ ${WINGS_REMOTE_MODE} == public || ${WINGS_REMOTE_MODE} == internal ]] || verr "WINGS_REMOTE_MODE must be 'public' or 'internal'"
    validate_games_and_firewall
    [[ ${WINGS_SFTP_BIND} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || verr "WINGS_SFTP_BIND must be an IPv4 address (127.0.0.1, or 0.0.0.0 to expose SFTP deliberately)"
    [[ ${MIN_FREE_DISK_GB} =~ ^[0-9]+$ ]] || verr "MIN_FREE_DISK_GB must be a whole number"
    [[ -z ${BACKUP_AGE_RECIPIENT} || ${BACKUP_AGE_RECIPIENT} =~ ^age1[a-z0-9]{50,}$ ]] || verr "BACKUP_AGE_RECIPIENT must be an age public key (age1...) or empty"

    # pinned images: every image must carry a digest, and none may float on :latest
    local v
    for v in PANEL_IMAGE MARIADB_IMAGE REDIS_IMAGE CLOUDFLARED_IMAGE UTILITY_IMAGE MCROUTER_IMAGE INSTALLER_IMAGE; do
        if [[ -z ${!v:-} ]]; then verr "$v is not set in config/versions.env"
        elif [[ ${!v} == *:latest || ${!v} != *@sha256:* ]]; then verr "$v must be pinned by digest (@sha256:...), not a floating tag: ${!v}"; fi
    done
    [[ ${WINGS_VERSION:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || verr "WINGS_VERSION must look like v1.13.4"
    [[ ${WINGS_SHA256_AMD64:-} =~ ^[0-9a-f]{64}$ && ${WINGS_SHA256_ARM64:-} =~ ^[0-9a-f]{64}$ ]] || verr "WINGS_SHA256_AMD64/ARM64 must be 64 hex characters"
    if [[ ${PANEL_VERSION:-} =~ -(alpha|beta|rc) && ${PTERO_ACCEPT_BETA} != yes ]]; then
        verr "Panel ${PANEL_VERSION} is a pre-release. Read docs/architecture.md (Versions and beta risk) and set PTERO_ACCEPT_BETA=yes in config/deploy.env to proceed"
    fi
    ((${#VERRORS[@]} == 0))
}

# check_secrets [need_tunnel]: files exist, mode <= 600, strong enough
check_secrets() {
    local need_tunnel=${1:-0} n p m
    local weak='^(password|changeme|change_me|secret|123456|admin|pterodactyl|redis|mariadb)$'
    for n in db_password redis_password; do
        p=$(secret_path "$n")
        if [[ ! -f $p ]]; then verr "secrets/$n is missing (run ./ptero init)"; continue; fi
        m=$(file_mode "$p")
        [[ $m == 600 || $m == 400 ]] || verr "secrets/$n has mode $m; run: chmod 600 secrets/$n"
        local v; v=$(read_secret "$n")
        if ((${#v} < 24)) || [[ ${v,,} =~ $weak ]]; then verr "secrets/$n is too short or a known weak value (need >= 24 characters)"; fi
        [[ $v =~ ^[A-Za-z0-9]+$ ]] || verr "secrets/$n must be alphanumeric (it is embedded in connection settings)"
    done
    p=$(secret_path tunnel_token)
    if [[ -s $p ]]; then
        m=$(file_mode "$p")
        [[ $m == 600 || $m == 400 ]] || verr "secrets/tunnel_token has mode $m; run: chmod 600 secrets/tunnel_token"
        valid_tunnel_token "$(read_secret tunnel_token)" || verr "secrets/tunnel_token is not a Cloudflare tunnel token (expected base64 JSON with keys a, t, s). Re-copy it from the dashboard: ./ptero tunnel set-token"
    elif ((need_tunnel)); then
        verr "secrets/tunnel_token is empty. Create the tunnel in Cloudflare, then run: ./ptero tunnel set-token"
    fi
    ((${#VERRORS[@]} == 0))
}

# Cloudflare tunnel tokens are base64(JSON {"a": account, "t": tunnel id, "s": secret}). Checked without printing anything.
valid_tunnel_token() {
    printf '%s' "$1" | python3 -c '
import base64, json, sys
t = sys.stdin.read().strip()
try:
    d = json.loads(base64.b64decode(t + "=" * (-len(t) % 4)))
    sys.exit(0 if isinstance(d, dict) and all(k in d for k in ("a", "t", "s")) else 1)
except Exception:
    sys.exit(1)' 2>/dev/null
}

report_verrors() {
    local e
    err "configuration is not valid:"
    for e in "${VERRORS[@]}"; do printf '  - %s\n' "$e" >&2; done
}

# export_stack_env: variables that compose.yml interpolates. Secrets come from files, not argv.
export_stack_env() {
    DB_PASSWORD=$(read_secret db_password)
    REDIS_PASSWORD=$(read_secret redis_password)
    TUNNEL_TOKEN=$(read_secret tunnel_token || true)
    export DB_PASSWORD REDIS_PASSWORD TUNNEL_TOKEN PANEL_FQDN ADMIN_EMAIL
    export PANEL_IMAGE MARIADB_IMAGE REDIS_IMAGE CLOUDFLARED_IMAGE MCROUTER_IMAGE
}

tunnel_enabled() { [[ -s $(secret_path tunnel_token) ]]; }

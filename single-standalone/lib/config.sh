#!/usr/bin/env bash
# shellcheck shell=bash
# Configuration: load_config, require_config, the validators, and the init and doctor commands. Sourced by ./mcctl.
#
# config/mcctl.env is PARSED, never sourced: a typo or a pasted $(...) cannot run code, and only MCCTL_* keys are accepted.
# A value already in the environment wins over the file. Secrets are never in it: each is a file under secrets/ (mode 600).
# MCCTL_ROOT (where config/, secrets/ and servers/ live; default: the folder holding ./mcctl) comes from the environment only.

# ---- validators (pure bash; each returns 0 or 1 and prints nothing) ---------------------------------------------------------

# ipv4_int A.B.C.D -> stdout the address as an integer. No leading zeros ("010" reads as octal in other tools).
ipv4_int() {
    local re='^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$' i
    [[ $1 =~ $re ]] || return 1
    for i in 1 2 3 4; do ((BASH_REMATCH[i] <= 255)) || return 1; done
    echo $(( (BASH_REMATCH[1] << 24) | (BASH_REMATCH[2] << 16) | (BASH_REMATCH[3] << 8) | BASH_REMATCH[4] ))
}
valid_ipv4() { ipv4_int "$1" >/dev/null; }

# valid_domain NAME: lower-case DNS name with at least one dot and an alphabetic TLD; servers become <name>.NAME
valid_domain() {
    local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
    [[ $1 =~ $re ]]
}

# cidr_parts CIDR -> sets CIDR_BASE and CIDR_MASK (integers); 1 unless CIDR is IPv4 base/16..29 with no host bits set
cidr_parts() {
    local re='^([0-9.]+)/([0-9]{1,2})$' ip len
    [[ $1 =~ $re ]] || return 1
    ip=${BASH_REMATCH[1]} len=$((10#${BASH_REMATCH[2]}))
    ((len >= 16 && len <= 29)) || return 1
    CIDR_BASE=$(ipv4_int "$ip") || return 1
    CIDR_MASK=$(((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF))
    (( (CIDR_BASE & CIDR_MASK) == CIDR_BASE ))
}

# valid_game_subnet CIDR: a private network (10/8, 172.16/12 or 192.168/16) written as base/prefix, prefix 16 to 29
valid_game_subnet() {
    local CIDR_BASE CIDR_MASK
    cidr_parts "$1" || return 1
    (( (CIDR_BASE & 0xFF000000) == 0x0A000000 || (CIDR_BASE & 0xFFF00000) == 0xAC100000 || (CIDR_BASE & 0xFFFF0000) == 0xC0A80000 ))
}

# valid_router_ip IP CIDR: a host address inside CIDR that Docker does not use itself (network, gateway = first host, broadcast)
valid_router_ip() {
    local CIDR_BASE CIDR_MASK ip
    ip=$(ipv4_int "$1") && cidr_parts "$2" || return 1
    (( (ip & CIDR_MASK) == CIDR_BASE && ip != CIDR_BASE && ip != CIDR_BASE + 1 && ip != (CIDR_BASE | (~CIDR_MASK & 0xFFFFFFFF)) ))
}

# ---- loading -----------------------------------------------------------------------------------------------------------------

# load_envfile FILE: export the MCCTL_KEY=value pairs of FILE that the environment does not already set (a later line wins over
# an earlier one). Prints every problem (never a value) and returns 1 on a bad file.
load_envfile() {
    local file=$1 line key val n=0 bad=0 blank='^[[:space:]]*(#.*)?$' pair='^(MCCTL_[A-Z0-9_]+)=(.*)$'
    local -A found=()
    [[ -r $file ]] || { err "cannot read $file"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ $line =~ $blank ]] && continue
        if [[ ! $line =~ $pair ]]; then err "$file:$n: expected MCCTL_KEY=value"; bad=1; continue; fi
        key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
        if [[ $key == MCCTL_ROOT || $key == MCCTL_HOME ]]; then err "$file:$n: $key cannot be set here; set it in the environment"; bad=1; continue; fi
        if [[ $val == \"* || $val == \'* ]]; then
            val=${val#?}; val=${val%%[\"\']*}
        else
            val=${val%%[[:space:]]#*}
            val=${val%"${val##*[![:space:]]}"}
        fi
        if [[ ! $val =~ ^[A-Za-z0-9._:/@,+=%-]*$ ]]; then
            err "$file:$n: value of $key has characters outside [A-Za-z0-9._:/@,+=%-]"; bad=1; continue
        fi
        found[$key]=$val
    done <"$file"
    for key in "${!found[@]}"; do
        [[ -n ${!key:-} ]] && continue
        printf -v "$key" '%s' "${found[$key]}"
        export "${key?}"
    done
    return "$bad"
}

# load_config: MCCTL_ROOT, then config/mcctl.env (optional), then the defaults; every value that is set is validated and every
# problem is reported before returning 1. Exports MCCTL_ROOT, MCCTL_DNS, MCCTL_DOMAIN, MCCTL_PUBLIC_IPV4, MCCTL_CF_ZONE_ID,
# MCCTL_GAME_SUBNET and MCCTL_ROUTER_IP. A key that is empty is "not set"; require_config says which commands need which.
load_config() {
    local rc=0
    : "${MCCTL_ROOT:=${MCCTL_HOME:-}}"
    if [[ $MCCTL_ROOT != /* ]]; then
        err "MCCTL_ROOT='$MCCTL_ROOT' must be an absolute path (default: the folder that holds ./mcctl)"; rc=1
    elif [[ -f $MCCTL_ROOT/config/mcctl.env ]]; then
        load_envfile "$MCCTL_ROOT/config/mcctl.env" || rc=1
    fi
    : "${MCCTL_DNS:=on}" "${MCCTL_DOMAIN:=}" "${MCCTL_PUBLIC_IPV4:=}" "${MCCTL_CF_ZONE_ID:=}" "${MCCTL_GAME_SUBNET:=172.30.0.0/24}" "${MCCTL_ROUTER_IP:=172.30.0.2}"
    : "${MCCTL_CONN_LIMIT:=10}" "${MCCTL_RATE:=10/second}" "${MCCTL_SSH_PORTS:=}" "${MCCTL_FIREWALL_ROLLBACK_SECONDS:=300}"
    # local play (MCCTL_DNS=off) needs no zone: the names only have to resolve on this machine, through its hosts file
    if [[ $MCCTL_DNS == off && -z $MCCTL_DOMAIN ]]; then MCCTL_DOMAIN=mc.local; fi
    export MCCTL_ROOT MCCTL_DNS MCCTL_DOMAIN MCCTL_PUBLIC_IPV4 MCCTL_CF_ZONE_ID MCCTL_GAME_SUBNET MCCTL_ROUTER_IP
    export MCCTL_CONN_LIMIT MCCTL_RATE MCCTL_SSH_PORTS MCCTL_FIREWALL_ROLLBACK_SECONDS

    [[ $MCCTL_DNS == on || $MCCTL_DNS == off ]] \
        || { err "MCCTL_DNS='$MCCTL_DNS' must be on (a DNS record per server in Cloudflare) or off (local play: no Cloudflare, no token)"; rc=1; }
    [[ -z $MCCTL_DOMAIN ]] || valid_domain "$MCCTL_DOMAIN" \
        || { err "MCCTL_DOMAIN='$MCCTL_DOMAIN' is not a valid lower-case host name without scheme or path (e.g. mc.yourdomain.net)"; rc=1; }
    [[ -z $MCCTL_PUBLIC_IPV4 ]] || valid_ipv4 "$MCCTL_PUBLIC_IPV4" \
        || { err "MCCTL_PUBLIC_IPV4='$MCCTL_PUBLIC_IPV4' is not an IPv4 address (four numbers 0-255, e.g. 203.0.113.7)"; rc=1; }
    # ponytail: Cloudflare zone ids are 32 hex characters; only URL-path safety (it is put in /zones/<id>/...) is enforced here
    [[ -z $MCCTL_CF_ZONE_ID ]] || [[ $MCCTL_CF_ZONE_ID =~ ^[A-Za-z0-9]{1,64}$ ]] \
        || { err "MCCTL_CF_ZONE_ID must be letters and digits only (copy the Zone ID from the Cloudflare dashboard)"; rc=1; }
    if ! valid_game_subnet "$MCCTL_GAME_SUBNET"; then
        err "MCCTL_GAME_SUBNET='$MCCTL_GAME_SUBNET' must be a private IPv4 network written as base/prefix with a /16 to /29 prefix (e.g. 172.30.0.0/24)"; rc=1
    elif ! valid_router_ip "$MCCTL_ROUTER_IP" "$MCCTL_GAME_SUBNET"; then
        err "MCCTL_ROUTER_IP='$MCCTL_ROUTER_IP' must be a host address inside MCCTL_GAME_SUBNET=$MCCTL_GAME_SUBNET, not its network, first (gateway) or broadcast address"; rc=1
    fi
    if [[ ! $MCCTL_CONN_LIMIT =~ ^[0-9]+$ || $MCCTL_CONN_LIMIT -lt 1 || $MCCTL_CONN_LIMIT -gt 65535 ]]; then
        err "MCCTL_CONN_LIMIT='$MCCTL_CONN_LIMIT' must be an integer from 1 to 65535"; rc=1
    fi
    if [[ ! $MCCTL_RATE =~ ^[1-9][0-9]{0,5}/(second|minute|hour)$ ]]; then
        err "MCCTL_RATE='$MCCTL_RATE' must be N/second, N/minute or N/hour with N from 1 to 999999 (e.g. 10/second)"; rc=1
    fi
    if [[ -n $MCCTL_SSH_PORTS ]]; then
        local -a _sp; local _p
        IFS=, read -ra _sp <<<"$MCCTL_SSH_PORTS"
        for _p in "${_sp[@]}"; do
            [[ -n $_p ]] || continue
            if [[ ! $_p =~ ^[0-9]+$ || $_p -lt 1 || $_p -gt 65535 ]]; then
                err "MCCTL_SSH_PORTS='$MCCTL_SSH_PORTS' has a port '$_p' that is not an integer from 1 to 65535"; rc=1; break
            fi
        done
    fi
    if [[ ! $MCCTL_FIREWALL_ROLLBACK_SECONDS =~ ^[0-9]+$ || $MCCTL_FIREWALL_ROLLBACK_SECONDS -gt 3600 ]]; then
        err "MCCTL_FIREWALL_ROLLBACK_SECONDS='$MCCTL_FIREWALL_ROLLBACK_SECONDS' must be an integer from 0 to 3600"; rc=1
    fi
    return "$rc"
}

# require_config KEY...: die with EX_PREFLIGHT, naming every key that is empty or unset
require_config() {
    local k missing=()
    for k in "$@"; do [[ -n ${!k:-} ]] || missing+=("$k"); done
    ((${#missing[@]} == 0)) || die "missing configuration: ${missing[*]} (set it in $MCCTL_ROOT/config/mcctl.env or the environment; see config/mcctl.env.example)" "$EX_PREFLIGHT"
}

# dns_on: 0 unless MCCTL_DNS is off. Off is local play: no Cloudflare call, no DNS record, no token; the router publishes 127.0.0.1 only
dns_on() { [[ ${MCCTL_DNS:-on} != off ]]; }

# dns_hint FQDN: with DNS off, tell the player what to add to the hosts file of the machine the Minecraft client runs on
dns_hint() {
    dns_on || info "DNS is off: to join from this machine, add the line '127.0.0.1 ${1-}' to its hosts file (Windows: C:\\Windows\\System32\\drivers\\etc\\hosts)"
}

# ---- commands ----------------------------------------------------------------------------------------------------------------

cmd_init() {
    (($# == 0)) || die "usage: mcctl init" "$EX_USAGE"
    mkdir_private "$MCCTL_ROOT/secrets" "$MCCTL_ROOT/servers" || die "cannot create $MCCTL_ROOT/secrets and $MCCTL_ROOT/servers"
    info "ready: $MCCTL_ROOT/secrets and $MCCTL_ROOT/servers (mode 700)"
    [[ -f $MCCTL_ROOT/config/mcctl.env ]] \
        || info "next: cp config/mcctl.env.example config/mcctl.env, fill in the blanks, then run: ./mcctl doctor"
}

DOCTOR_FAILS=0
# doctor_line STATUS TEXT [HINT]: one [ok] / [FAIL] line; STATUS 0 is ok
doctor_line() {
    if [[ $1 == 0 ]]; then printf '[ok]   %s\n' "$2"
    else printf '[FAIL] %s%s\n' "$2" "${3:+: $3}"; DOCTOR_FAILS=$((DOCTOR_FAILS + 1)); fi
}
# doctor_need COMMAND HINT
doctor_need() {
    if command -v "$1" >/dev/null 2>&1; then doctor_line 0 "$1"; else doctor_line 1 "$1" "not found; $2"; fi
}

# cmd_doctor: check the host, one line per check; exit 3 when any check failed
cmd_doctor() {
    (($# == 0)) || die "usage: mcctl doctor" "$EX_USAGE"
    local f n m
    DOCTOR_FAILS=0
    load_config   # prints each problem; the config line below says whether there were any
    doctor_line $? "config" "see the ERROR lines above"
    if dns_on; then doctor_line 0 "DNS on: one record per server under $MCCTL_DOMAIN, in Cloudflare"
    else doctor_line 0 "DNS off: local play, no Cloudflare; names under $MCCTL_DOMAIN resolve through the hosts file"; fi
    ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))
    doctor_line $? "bash ${BASH_VERSION%%[( ]*}" "mcctl needs bash >= 4.4"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then doctor_line 0 "docker compose"
    else doctor_line 1 "docker compose" "'docker compose version' failed; install Docker Engine with the Compose v2 plugin"; fi
    doctor_need jq "install the 'jq' package"
    doctor_need curl "install the 'curl' package"
    if [[ -d $MCCTL_ROOT/secrets ]]; then
        for f in "$MCCTL_ROOT"/secrets/*; do
            [[ -f $f ]] || continue
            n=${f##*/} m=$(stat -c %a -- "$f" 2>/dev/null)
            if [[ $m == 600 || $m == 400 ]]; then doctor_line 0 "secrets/$n mode $m"
            else doctor_line 1 "secrets/$n has mode ${m:-unknown}; run: chmod 600 secrets/$n"; fi
        done
    else
        doctor_line 0 "secrets/ not created yet (./mcctl init creates it)"
    fi
    ((DOCTOR_FAILS == 0)) && return 0
    err "$DOCTOR_FAILS check(s) failed"
    return "$EX_PREFLIGHT"
}

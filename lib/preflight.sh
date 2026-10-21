#!/usr/bin/env bash
# shellcheck shell=bash
# Host preflight: read-only. Prints one line per check; exit status 3 if any check FAILs.
# Sourced by ./ptero.

PF_FAIL=0 PF_WARN=0
pf_ok()   { printf '  [ ok ] %s\n' "$*"; }
pf_warn() { printf '  [warn] %s\n' "$*"; PF_WARN=$((PF_WARN + 1)); }
pf_fail() { printf '  [FAIL] %s\n' "$*"; PF_FAIL=$((PF_FAIL + 1)); }

pf_os() {
    local id="" ver=""
    # shellcheck disable=SC1090  # os-release is a standard KEY=value file
    if [[ -r ${PTERO_OS_RELEASE:-/etc/os-release} ]]; then
        id=$(. "${PTERO_OS_RELEASE:-/etc/os-release}" && printf '%s' "${ID:-}")
        ver=$(. "${PTERO_OS_RELEASE:-/etc/os-release}" && printf '%s' "${VERSION_ID:-}")
    fi
    if [[ $(uname -s) != Linux ]]; then pf_fail "OS is $(uname -s); only Linux is supported (Windows/macOS are not)"; return; fi
    case "$id:$ver" in
        ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13) pf_ok "OS $id $ver (supported by upstream Wings docs)" ;;
        *) pf_warn "OS '$id $ver' is not on upstream's supported list (Ubuntu 22.04/24.04/26.04, Debian 12/13); it may work" ;;
    esac
    case "$(uname -m)" in
        x86_64|aarch64) pf_ok "architecture $(uname -m)" ;;
        *) pf_fail "architecture $(uname -m) has no Wings build (need x86_64 or aarch64)" ;;
    esac
    if have systemd-detect-virt; then
        case "$(systemd-detect-virt 2>/dev/null)" in
            openvz|lxc|virtuozzo|lxc-libvirt) pf_warn "virtualization $(systemd-detect-virt) is likely incompatible with Wings/Docker (upstream docs)" ;;
        esac
    fi
}

pf_tools() {
    local c missing=0
    for c in docker curl openssl python3 tar gzip sha256sum awk stat ss df; do
        have "$c" || { pf_fail "command not found: $c"; missing=1; }
    done
    ((missing)) || pf_ok "required commands present"
    if have python3 && ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'; then pf_fail "python3 >= 3.8 required"; fi
}

pf_docker() {
    have docker || return 0
    if ! docker info >/dev/null 2>&1; then
        pf_fail "cannot talk to the Docker daemon (is it running? are you in the 'docker' group, or root?)"
        return
    fi
    pf_ok "Docker daemon reachable ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"
    local cv
    cv=$(docker compose version --short 2>/dev/null | sed 's/^v//')
    if [[ -z $cv ]]; then pf_fail "Docker Compose v2 plugin not found (docker compose version)"
    elif [[ $(printf '%s\n2.20.0\n' "$cv" | sort -V | head -n1) != 2.20.0 ]]; then pf_fail "Docker Compose $cv is too old (need >= 2.20)"
    else pf_ok "Docker Compose $cv"; fi
}

pf_resources() {
    local root dir avail need=${MIN_FREE_DISK_GB:-10}
    root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
    for dir in "${root:-/var/lib/docker}" "$PTERO_ROOT"; do
        [[ -d $dir ]] || continue
        avail=$(df -Pk -- "$dir" | awk 'NR==2 {print int($4/1048576)}')
        if ((avail < need)); then pf_fail "only ${avail} GB free on $dir (need >= ${need} GB)"
        else pf_ok "${avail} GB free on $dir"; fi
    done
    avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    if [[ -n $avail ]] && ((avail < 1536)); then pf_warn "only ${avail} MB RAM available; Panel+DB+Redis need about 1.5 GB"
    else pf_ok "memory available: ${avail:-unknown} MB"; fi
    if have timedatectl && [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == no ]]; then
        pf_warn "system clock is not NTP-synchronised; Wings/Panel tokens and Cloudflare TLS need an accurate clock"
    fi
}

port_in_use() { [[ -n $(ss -H -ltn "( sport = :$1 )" 2>/dev/null) ]]; }

pf_ports() {
    local owner_panel=0 owner_tunnel=0 owner_wings=0
    if have docker && [[ -n $(compose ps -q --status running panel 2>/dev/null) ]]; then owner_panel=1; fi
    if have docker && [[ -n $(compose ps -q --status running cloudflared 2>/dev/null) ]]; then owner_tunnel=1; fi
    if wings_container_mode; then
        have docker && [[ -n $(compose_wings ps -q --status running wings 2>/dev/null) ]] && owner_wings=1
    elif have systemctl && systemctl is-active --quiet wings 2>/dev/null; then owner_wings=1; fi
    local chk owner_router=0 checks
    if have docker && [[ -n $(compose ps -q --status running mc-router 2>/dev/null) ]]; then owner_router=1; fi
    checks=("PANEL_BIND_PORT:$owner_panel:Panel" "TUNNEL_METRICS_PORT:$owner_tunnel:cloudflared metrics" "WINGS_API_PORT:$owner_wings:Wings API")
    [[ ${GAMES_ENABLED:-no} == yes ]] && checks+=("GAMES_PORT:$owner_router:game router")
    for chk in "${checks[@]}"; do
        local var=${chk%%:*} rest=${chk#*:} owned name
        owned=${rest%%:*}; name=${rest#*:}
        if port_in_use "${!var}"; then
            if ((owned)); then pf_ok "$var ${!var} is held by this deployment's $name"
            else pf_fail "$var ${!var} is already in use by something else (ss -ltnp 'sport = :${!var}'); change it in config/deploy.env"; fi
        else pf_ok "$var ${!var} is free"; fi
    done
}

# WINGS_MODE=container and a native Wings service must not both exist: they would be two Wings for one node, and both want the
# API port and SFTP port 2022 (found in the real run: Docker Desktop refuses to publish 2022 while the native service holds it).
pf_wings_mode() {
    wings_container_mode || return 0
    if wings_native_active; then
        pf_fail "WINGS_MODE=container, but the native Wings service (systemd) is active: two Wings for one node clash on the API port and on SFTP port 2022. Stop it: sudo systemctl disable --now wings"
    else
        pf_ok "WINGS_MODE=container: Wings runs as a Compose service; no native Wings service is active"
    fi
}

# prints the first existing subnet/route that overlaps $1, ignoring an entry identical to $2
first_overlap() { # reads candidate networks on stdin (so the program must come via -c, not a heredoc)
    python3 -c '
import ipaddress, sys
mine = ipaddress.ip_network(sys.argv[1])
ignore = sys.argv[2] if len(sys.argv) > 2 else ""
for other in (l.strip() for l in sys.stdin):
    if not other or other == ignore:
        continue
    try:
        o = ipaddress.ip_network(other, strict=False)
    except ValueError:
        continue
    if o.version == 4 and o.prefixlen > 0 and mine.overlaps(o):
        print(other)
        sys.exit(1)' "$@"
}

pf_network() {
    have docker || return 0
    local own hit nets
    own=$(docker network inspect "${PTERO_PROJECT}_edge" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
    nets=$( { docker network ls -q 2>/dev/null | xargs -r docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null
              have ip && ip -4 route show 2>/dev/null | awk '$1 != "default" {print $1}'; } )
    if hit=$(printf '%s\n' "$nets" | first_overlap "$PANEL_EDGE_SUBNET" "$own"); then
        pf_ok "PANEL_EDGE_SUBNET $PANEL_EDGE_SUBNET overlaps no Docker network or host route"
    else
        pf_fail "PANEL_EDGE_SUBNET $PANEL_EDGE_SUBNET overlaps existing network/route $hit; pick another in config/deploy.env"
    fi
    # The game network Wings will create must not overlap anything either (Docker: "Pool overlaps with other one on this
    # address space", which stops Wings at start). The Wings network itself is checked just below, so it is not compared here.
    local gnets ghit
    gnets=$( { docker network ls -q 2>/dev/null | xargs -r docker network inspect --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
               | awk '$1 != "pterodactyl_nw" { for (i = 2; i <= NF; i++) print $i }'
              have ip && ip -4 route show 2>/dev/null | awk '$1 != "default" {print $1}'; } )
    if [[ -n ${GAME_NET_SUBNET:-} ]]; then
        if ghit=$(printf '%s\n' "$gnets" | first_overlap "$GAME_NET_SUBNET" ""); then
            pf_ok "GAME_NET_SUBNET $GAME_NET_SUBNET overlaps no other Docker network or host route"
        else
            pf_fail "GAME_NET_SUBNET $GAME_NET_SUBNET overlaps existing network/route $ghit; Wings would fail to start with 'Pool overlaps'. Pick a free private range in config/deploy.env (e.g. 10.201.0.0/16)"
        fi
    fi
    # Wings also names the bridge device of its game network "pterodactyl0". A second network with that bridge name (for
    # example one left by an older stack) makes Wings fail with "conflicts with network ...".
    local bridges
    bridges=$(docker network ls -q 2>/dev/null | xargs -r docker network inspect --format '{{.Name}} {{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null \
              | awk '$1 != "pterodactyl_nw" && $2 == "pterodactyl0" {print $1}')
    if [[ -n $bridges ]]; then
        pf_fail "Docker network(s) $(echo $bridges) use the bridge name pterodactyl0, which Wings needs for its game network. Remove the unused network (docker network rm <name>, only if no container uses it) or run Wings on a host without it"
    else
        pf_ok "no other Docker network uses the bridge name pterodactyl0"
    fi
    # Wings creates its game network on first start and never changes it. If a network with that name already exists with
    # another subnet (e.g. left by an older stack), game containers get no usable IP. Detect that before Wings starts.
    local wnet wsub
    wnet=pterodactyl_nw
    if docker network inspect "$wnet" >/dev/null 2>&1; then
        # IPv4 only: the network also has an IPv6 subnet, which must not be compared with GAME_NET_SUBNET
        wsub=$(docker network inspect "$wnet" --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null | grep -F . | grep -v ':' | head -n1)
        if [[ -n ${GAME_NET_SUBNET:-} && -n $wsub && $wsub != "$GAME_NET_SUBNET" ]]; then
            pf_fail "Docker network '$wnet' already exists with subnet $wsub, but GAME_NET_SUBNET is ${GAME_NET_SUBNET}. Wings reuses the existing network and game servers would get no valid IP. Either set GAME_NET_SUBNET=$wsub, or remove the unused network: docker network rm $wnet (only when no game container uses it)"
        else
            pf_ok "Wings game network '$wnet' is absent or matches GAME_NET_SUBNET"
        fi
    else
        pf_ok "Wings game network '$wnet' does not exist yet (Wings creates it on first start)"
    fi
}

tcp_open() { timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

pf_internet() {
    if [[ ${PTERO_PREFLIGHT_SKIP:-} == net ]]; then pf_warn "network checks skipped (PTERO_PREFLIGHT_SKIP=net)"; return; fi
    tcp_open ghcr.io 443 && pf_ok "ghcr.io:443 reachable (Panel image)" || pf_warn "ghcr.io:443 unreachable; image pulls will fail"
    tcp_open region1.v2.argotunnel.com 7844 && pf_ok "Cloudflare tunnel edge :7844 reachable" \
        || pf_warn "region1.v2.argotunnel.com:7844 unreachable; the tunnel needs outbound TCP/UDP 7844 (check the firewall)"
}

preflight() {
    PF_FAIL=0 PF_WARN=0
    printf 'Preflight (read-only):\n'
    pf_os; pf_tools; pf_docker; pf_resources
    if [[ -n ${PANEL_EDGE_SUBNET:-} ]]; then pf_ports; pf_wings_mode; pf_network; fi
    pf_internet
    printf 'Result: %d failed, %d warnings\n' "$PF_FAIL" "$PF_WARN"
    ((PF_FAIL == 0))
}

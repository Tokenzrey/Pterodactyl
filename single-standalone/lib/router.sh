#!/usr/bin/env bash
# shellcheck shell=bash
# The router stack: mc-router (the one public port) and the egress guard. Sourced by ./mcctl, never executed.
#
# templates/stack.compose.yml is one compose project, mcctl-stack. The game containers are NOT in it: each server has its own
# project (mcctl-NAME) and joins the external network mcctl_game, which `up` creates with MCCTL_GAME_SUBNET before compose starts.
# The egress guard filters that subnet; it is the reason `up` refuses a network that already exists with another subnet.
# MCCTL_GAME_SUBNET and MCCTL_ROUTER_IP (exported by load_config) reach the stack file through compose's variable interpolation.

ROUTER_PORT=25565
STACK_PROJECT=mcctl-stack

# game_ip_range -> stdout the --ip-range of mcctl_game: the half of MCCTL_GAME_SUBNET that does not hold MCCTL_ROUTER_IP. Docker then
# never gives the router's address to a server, even while the router is down. (An --aux-address would reserve it for everyone, and
# the router's static address would then be refused: "Address already in use".)
game_ip_range() {
    local a b c d p=${MCCTL_GAME_SUBNET#*/} n r half start
    IFS=. read -r a b c d <<<"${MCCTL_GAME_SUBNET%/*}"; n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    IFS=. read -r a b c d <<<"$MCCTL_ROUTER_IP"; r=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    half=$(( 1 << (31 - p) ))
    start=$n
    if (( r - n < half )); then start=$(( n + half )); fi
    printf '%d.%d.%d.%d/%d\n' $(( (start >> 24) & 255 )) $(( (start >> 16) & 255 )) $(( (start >> 8) & 255 )) $(( start & 255 )) $(( p + 1 ))
}
GAME_NETWORK=mcctl_game
STACK_COMPOSE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates" 2>/dev/null && pwd -P)/stack.compose.yml

# stack_dc ARGS...: docker compose for the router stack. The router runs as a non-root user with no capabilities, so it reaches the
# Docker socket only through the socket's group: MCCTL_DOCKER_GID is that group, passed to the template's group_add.
stack_dc() {
    MCCTL_DOCKER_GID=$(stat -L -c %g -- "${MCCTL_DOCKER_SOCKET:-/var/run/docker.sock}" 2>/dev/null) \
        || { err "cannot read the group of the Docker socket (${MCCTL_DOCKER_SOCKET:-/var/run/docker.sock}): is Docker running?"; return "$EX_PREFLIGHT"; }
    export MCCTL_DOCKER_GID
    # local play (DNS off): the game port is for this machine only; with DNS on it is published on every address, as before
    MCCTL_ROUTER_BIND=127.0.0.1
    if dns_on; then MCCTL_ROUTER_BIND=0.0.0.0; fi
    export MCCTL_ROUTER_BIND
    # the voice chat ports of the servers (lib/voice.sh): the guard opens each one in MCCTL-INGRESS
    MCCTL_VOICE_PORTS=$(voice_ports 2>/dev/null | paste -sd' ' -)
    export MCCTL_VOICE_PORTS
    docker compose -p "$STACK_PROJECT" -f "$STACK_COMPOSE" "$@"
}

# router_port_free: 0 when nothing listens on the public port; 1 when something does, printing its `ss -ltnp` line(s) on stdout
# (the process is named there when this user may see it); 2 when that cannot be found out (no ss, or ss failed: the reason is on
# stderr). Control characters are removed from what is printed, because a process name is chosen by whoever started it.
router_port_free() {
    local out
    command -v ss >/dev/null 2>&1 || { err "ss not found: install iproute2 (needed to check whether port $ROUTER_PORT is free)"; return 2; }
    out=$(ss -H -ltnp "( sport = :$ROUTER_PORT )" 2>/dev/null) || { err "'ss' failed, so mcctl cannot tell whether port $ROUTER_PORT is free"; return 2; }
    [[ -n $out ]] || return 0
    printf '%s\n' "$out" | tr -cd '[:print:]\n' | tr -s ' '
    return 1
}

# _router_is_ours: 0 when the mc-router of this stack is running (so a listener on the port is our own, and `up` may run again)
_router_is_ours() { [[ -n $(stack_dc ps -q --status running mc-router 2>/dev/null) ]]; }

# cmd_up: start (or update) the router stack. Order: the port check, the game network, then compose. A refusal creates nothing.
cmd_up() {
    (($# == 0)) || die "usage: mcctl up" "$EX_USAGE"
    local listener rc=0 ids subnets
    listener=$(router_port_free) || rc=$?
    case $rc in
        0) ;;
        1) _router_is_ours || die "port $ROUTER_PORT is already in use, so the router cannot start. Listener: ${listener:-unknown}
       Stop whatever holds it (for another mc-router: its own stack), or run 'ss -ltnp \"sport = :$ROUTER_PORT\"' as root to see the process. Nothing was created." "$EX_PREFLIGHT" ;;
        *) die "cannot tell whether port $ROUTER_PORT is free (see above). Nothing was created." "$EX_PREFLIGHT" ;;
    esac

    ids=$(docker network ls -q --filter "name=^${GAME_NETWORK}\$") \
        || die "cannot ask Docker ('docker network ls' failed): is the daemon running, and may this user use it? Nothing was created."
    if [[ -z $ids ]]; then
        # the game containers get addresses from the half of the subnet that does not hold the router (game_ip_range)
        docker network create --driver bridge --subnet "$MCCTL_GAME_SUBNET" --ip-range "$(game_ip_range)" --label mcctl.managed=true "$GAME_NETWORK" >/dev/null \
            || die "cannot create the network $GAME_NETWORK on $MCCTL_GAME_SUBNET (see above). A subnet that overlaps another Docker network or route is the usual cause: change MCCTL_GAME_SUBNET and MCCTL_ROUTER_IP in config/mcctl.env."
    else
        # the egress rules are written for MCCTL_GAME_SUBNET: a network on another subnet would be left unguarded
        subnets=$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$GAME_NETWORK") \
            || die "cannot inspect the network $GAME_NETWORK"
        [[ " $subnets" == *" $MCCTL_GAME_SUBNET "* ]] \
            || die "the network $GAME_NETWORK exists with subnet ${subnets:-none}, but MCCTL_GAME_SUBNET is $MCCTL_GAME_SUBNET, and the egress rules guard that one. Set MCCTL_GAME_SUBNET (and MCCTL_ROUTER_IP) to match, or stop the game servers and remove the network with: docker network rm $GAME_NETWORK" "$EX_PREFLIGHT"
    fi

    stack_dc up -d --wait \
        || die "docker compose up failed (see above). The router only starts once the egress guard is healthy: see why with: docker logs mcctl-egress-guard"
    info "router up: port $ROUTER_PORT, address $MCCTL_ROUTER_IP on $GAME_NETWORK ($MCCTL_GAME_SUBNET); compose reported the egress guard healthy"
    # SFTP is its own project (lib/sftp.sh): started after the router, and a failure there does not undo the router
    sftp_up || die "the router is up, but the SFTP stack did not start (see above). Fix the cause, then run 'mcctl up' again or 'mcctl sftp repair'"
    if [[ -s $(_sftp_users_file) ]]; then info "SFTP up on $(_sftp_bind):2222 (key-only login; MCCTL_SFTP_PUBLIC=1 publishes it on 0.0.0.0)"; fi
}

# cmd_down: stop the router stack and the SFTP stack. Players connected through the router are disconnected. The game network, the
# game servers and the egress rules (they belong to the Docker host, not to the guard container) are left as they are.
cmd_down() {
    (($# == 0)) || die "usage: mcctl down" "$EX_USAGE"
    stack_dc down || die "docker compose down failed (see above)"
    sftp_down || die "the router stack is stopped, but the SFTP stack could not be stopped (see above)"
    info "router stopped. The game servers, the network $GAME_NETWORK and the egress rules are untouched: 'mcctl up' starts the router again"
}

# Nothing is sent to mc-router after a server changes: it follows Docker's events and adds or removes a route when a container starts or
# stops. Never send it SIGHUP: its reload panics (RoutesConfigLoader.isEnabled), and the router stays down until someone starts it again.

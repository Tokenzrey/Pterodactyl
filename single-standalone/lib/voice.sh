#!/usr/bin/env bash
# shellcheck shell=bash
# Voice chat (the Simple Voice Chat mod): its audio is UDP, so a server needs a UDP port of its own on the host. VOICE_PORT in server.env
# is that port, a structural key: compose.yaml publishes it (templates/server.compose.tmpl, through lib/compose.sh), the guard of the
# router stack opens it with a rate limit (templates/stack.compose.yml), and the mod's config holds the same number. Sourced by ./mcctl,
# never executed.

# voice_port_valid PORT: 0 when PORT can be a voice port: a whole number from 1024 to 65535, and not the game's router port
voice_port_valid() {
    [[ ${1-} =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$1 >= 1024 && 10#$1 <= 65535 && 10#$1 != ROUTER_PORT))
}

# voice_ports -> stdout one VOICE_PORT per line of every server, sorted, each once: the UDP ports the guard must open
voice_ports() {
    local f
    for f in "$MCCTL_ROOT"/servers/*/server.env; do
        [[ -f $f ]] || continue
        sed -n 's/^VOICE_PORT=\([0-9]\{1,5\}\)$/\1/p' -- "$f"
    done | LC_ALL=C sort -nu
}

# voice_owner PORT -> stdout the server that has PORT as its voice port; 1 when none has
voice_owner() {
    local f
    for f in "$MCCTL_ROOT"/servers/*/server.env; do
        [[ -f $f ]] || continue
        if grep -qx -- "VOICE_PORT=$1" "$f"; then basename "$(dirname "$f")"; return 0; fi
    done
    return 1
}

# _voice_guard: the egress guard alone, recreated so that its rules hold the voice ports of every server now. It is started with
# --no-deps, so the router is not touched, and `--wait` returns only when the guard is healthy (its healthcheck checks each voice rule).
_voice_guard() {
    stack_dc up -d --wait --no-deps egress-guard
}

# _voice_back NAME OLD: put server.env back to OLD, render compose.yaml again and set the guard back. A failure here only warns: what
# is left is named, and `mcctl up` sets the guard right.
_voice_back() {
    local name=$1 old=$2 dir
    dir=$(server_dir "$name") || return
    write_atomic "$dir/server.env" printf '%s' "$old" || warn "$name: server.env could not be put back as it was (see above)"
    write_compose "$name" || warn "$name: compose.yaml could not be put back (see above)"
    _voice_guard || warn "the voice rules of the guard could not be reset: run mcctl up"
}

# cmd_voice NAME [set PORT | off]: the voice chat port of NAME. Without an action it shows the current setting.
#   set PORT: the port is checked and must be free, the router stack must be running (its guard opens the port), and the mod's config
#   (config/voicechat/voicechat-server.properties in data/) must exist: the mod writes it at the first start. Then server.env, the mod's
#   config, the guard and the containers are updated; a failure takes back what was changed before the containers.
#   off: the port is no longer published; the mod's config keeps its number.
cmd_voice() {
    local usage="usage: mcctl voice NAME [set PORT | off]"
    local name=${1-} act=${2-} port=${3-} dir old owner
    (($# >= 1)) || die "$usage" "$EX_USAGE"
    _need_server "$name"
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    case $# in
        1)
            port=$(sed -n 's/^VOICE_PORT=\([0-9]\{1,5\}\)$/\1/p' -- "$dir/server.env") || die "cannot read $name's server.env (see above)" "$EX_FAIL"
            if [[ -n $port ]]; then info "$name: voice chat on UDP $port"; else info "$name: no voice chat port (mcctl voice $name set PORT)"; fi
            return 0 ;;
        2) [[ $act == off ]] || die "$usage" "$EX_USAGE" ;;
        3) [[ $act == set ]] || die "$usage" "$EX_USAGE" ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac

    if [[ $act == off ]]; then
        old=$(cat "$dir/server.env"; printf X); old=${old%X}
        server_env_unset "$name" VOICE_PORT || die "cannot write $dir/server.env (see above)" "$EX_FAIL"
        _env_write_compose "$name" "$old"
        _voice_guard || { _voice_back "$name" "$old"; die "the voice rules could not be updated (see above): $name is as it was" "$EX_FAIL"; }
        apply_pending "$name"
        return
    fi

    # -- checks: nothing is changed by any of them
    voice_port_valid "$port" \
        || die "PORT ${port@Q} is not a UDP port from 1024 to 65535 other than 25565 (the game's router port)" "$EX_USAGE"
    if owner=$(voice_owner "$port") && [[ $owner != "$name" ]]; then
        die "UDP $port is already the voice port of $owner: pick another one" "$EX_REFUSED"
    fi
    stack_dc ps -q --status running egress-guard 2>/dev/null | grep -q . \
        || die "the router stack is not running, so its guard cannot open UDP $port: run mcctl up first. Nothing was changed." "$EX_REFUSED"
    data_run "$name" test -f config/voicechat/voicechat-server.properties 2>/dev/null \
        || die "$name has no voice chat config yet (config/voicechat/voicechat-server.properties, or Docker cannot be asked): start $name once with mcctl start $name, so that the mod writes it, then run this again. Nothing was changed." "$EX_REFUSED"

    # -- the writes: server.env and compose.yaml, the guard, the mod's config, the containers
    old=$(cat "$dir/server.env"; printf X); old=${old%X}
    server_env_set "$name" VOICE_PORT "$port" || die "cannot write $dir/server.env (see above)" "$EX_FAIL"
    _env_write_compose "$name" "$old"
    _voice_guard || { _voice_back "$name" "$old"; die "the guard could not open UDP $port (see above): $name is as it was" "$EX_FAIL"; }
    data_run "$name" sh -c 'f=config/voicechat/voicechat-server.properties; sed -i "s/^port=.*/port=$1/" "$f" && grep -qx "port=$1" "$f"' sh "$port" \
        || { _voice_back "$name" "$old"; die "cannot set the port in the mod's config (see above): $name is as it was" "$EX_FAIL"; }
    info "$name: voice chat on UDP $port"
    apply_pending "$name"
}

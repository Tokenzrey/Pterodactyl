#!/usr/bin/env bash
# shellcheck shell=bash
# Game side: hostname routing (mc-router), server creation, DNS help. Sourced by ./ptero.
#
# Design: ONE public game entry point. mc-router listens on GAMES_PORT (25565) and reads the hostname the Minecraft
# client sends in its handshake, then forwards to that server's loopback port. A connection by bare IP, or by an unknown
# name, matches nothing and is dropped. Game servers themselves only bind 127.0.0.1:<port>, so they cannot be reached
# except through the router. Routing is derived automatically from the Panel's server list (lib/games.py).

games_enabled() { [[ ${GAMES_ENABLED:-no} == yes ]]; }

# Is the game port listening in the network namespace where mc-router runs (host networking)? On Docker Desktop that
# namespace is the VM, not the WSL shell, so `ss` from the shell gives a false "not listening". Probe from a container
# that shares the host network instead.
game_port_listening() {
    if have docker && docker info >/dev/null 2>&1; then
        docker run --rm --network host "$UTILITY_IMAGE" sh -c "nc -w 2 127.0.0.1 $GAMES_PORT </dev/null >/dev/null 2>&1" >/dev/null 2>&1
        return $?
    fi
    port_in_use "$GAMES_PORT"
}
routes_dir() { printf '%s/runtime/mc-router\n' "$PTERO_ROOT"; }
routes_file() { printf '%s/routes.json\n' "$(routes_dir)"; }

# the router must find a routes file at first start, even before any server exists
games_prepare_routes() {
    games_enabled || return 0
    local d f; d=$(routes_dir); f=$(routes_file)
    mkdir -p "$d" && chmod 755 "$PTERO_ROOT/runtime" "$d" || return 1
    if [[ ! -f $f ]]; then printf '{\n  "mappings": {}\n}\n' >"$f" && chmod 644 "$f" || return 1; fi
}

games_python() { # games_python ARGS... : lib/games.py with the Panel key passed through the environment
    games_enabled || die "games are disabled: set GAMES_ENABLED=yes and GAMES_DOMAIN in config/deploy.env" $EX_REFUSED
    [[ -s $(secret_path panel_api_key) ]] || die "no Panel API key. Create an Application API key (Admin -> Application API: Servers R+W, Allocations R+W, Nodes R, Eggs R, Users R) and run: ./ptero key set panel" $EX_REFUSED
    PANEL_API_URL="http://127.0.0.1:${PANEL_BIND_PORT}" PANEL_API_KEY=$(read_secret panel_api_key) \
    PANEL_CLIENT_KEY=$(read_secret panel_client_key 2>/dev/null || true) \
    ROUTES_FILE=$(routes_file) CURSEFORGE_API_KEY=$(read_secret curseforge_api_key 2>/dev/null || true) \
        python3 "$PTERO_ROOT/lib/games.py" "$@"
}

# after a change: tell the router to re-read the table (it also watches the file; HUP is the documented fallback)
games_reload_router() {
    [[ -n $(svc_id mc-router) ]] && compose kill -s HUP mc-router >/dev/null 2>&1
    return 0
}

cmd_games() {
    local sub=${1:-}; shift || true
    case $sub in
        sync)
            prepare 0
            local quiet=() out rc
            [[ ${1:-} == --quiet ]] && quiet=(--quiet)
            games_prepare_routes || die "cannot create the routes file"
            out=$(games_python sync ${quiet[@]+"${quiet[@]}"}); rc=$?
            [[ -n $out ]] && printf '%s\n' "${out%CHANGED}"
            if [[ $rc -eq 0 && $out == *CHANGED ]]; then games_reload_router; fi
            return $rc
            ;;
        list) prepare 0; games_python list ;;
        status)
            prepare 0
            games_enabled || { echo "games: disabled (GAMES_ENABLED=no)"; return 0; }
            local rc=0 s; s=$(svc_state mc-router)
            printf 'mc-router      %s\n' "$s"; [[ $s == running || $s == healthy ]] || rc=1
            if game_port_listening; then printf 'game port      %s listening\n' "$GAMES_PORT"; else printf 'game port      %s NOT listening\n' "$GAMES_PORT"; rc=1; fi
            printf 'routes         %s entries in %s\n' "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["mappings"]))' "$(routes_file)" 2>/dev/null || echo '?')" "$(routes_file)"
            return $rc
            ;;
        dns)
            prepare 0
            games_enabled || die "games are disabled (GAMES_ENABLED=no)" $EX_REFUSED
            local ip; ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
            cat <<EOF
One DNS record, once, in the Cloudflare DNS tab (no per-server work afterwards):

  Type   Name                 Content                         Proxy status
  A      *.${GAMES_DOMAIN}    <this server's public IPv4>     DNS only (grey cloud)

This host's primary address is ${ip:-unknown}; use the PUBLIC address if the server is behind NAT.

Why "DNS only": Cloudflare's proxy carries HTTP(S), not Minecraft. Players then type  <server-name>.${GAMES_DOMAIN}
with no port. The record reveals the server's IP; what limits it is the firewall (./ptero firewall: only SSH and
port ${GAMES_PORT} are open) and the router (a name it does not know, or a bare IP, is dropped).
Add an AAAA record the same way only if this host has a public IPv6 address.
EOF
            ;;
        timer)
            need_root "games timer"
            local act=${1:-}
            case $act in
                install)
                    prepare 0
                    local d; d=${PTERO_SYSTEMD_DIR:-/etc/systemd/system}
                    local f
                    for f in ptero-games-sync.service ptero-games-sync.timer; do
                        sed "s#@PTERO_ROOT@#$PTERO_ROOT#g" "$PTERO_ROOT/systemd/$f.tpl" >"$PTERO_TMP/$f" && install -m 0644 "$PTERO_TMP/$f" "$d/$f" || die "cannot install $f"
                    done
                    systemctl daemon-reload && systemctl enable --now ptero-games-sync.timer || die "cannot enable the timer"
                    info "installed: servers created in the Panel get their hostname within 2 minutes (or immediately via ./ptero game create)"
                    ;;
                remove)
                    systemctl disable --now ptero-games-sync.timer 2>/dev/null
                    rm -f "${PTERO_SYSTEMD_DIR:-/etc/systemd/system}/ptero-games-sync.service" "${PTERO_SYSTEMD_DIR:-/etc/systemd/system}/ptero-games-sync.timer"
                    systemctl daemon-reload
                    info "timer removed (routes already written stay in place)"
                    ;;
                *) die "usage: sudo ./ptero games timer {install|remove}" $EX_USAGE ;;
            esac
            ;;
        *) die "usage: ./ptero games {sync [--quiet]|list|status|dns|timer install|remove}" $EX_USAGE ;;
    esac
}

cmd_game() { # ./ptero game create --name N --source modrinth|curseforge|url --pack ID [--version V] [--mc 1.21.1] ...
    [[ ${1:-} == create ]] || die "usage: ./ptero game create --name NAME --source {modrinth|curseforge|url} --pack SLUG [--version V] [--mc X] [--memory MB] [--disk MB] [--cpu %] [--port P] [--owner EMAIL] [--label L]" $EX_USAGE
    shift
    prepare 0
    [[ $(svc_state panel) == healthy ]] || die "the Panel is not running: ./ptero setup" $EX_REFUSED
    [[ $(wings_state_ok) == yes ]] || warn "Wings is not active: creating the server record works, but the install only runs once Wings is up (sudo ./ptero wings install)"
    games_prepare_routes || die "cannot create the routes file"
    info "planning (nothing is created yet)"
    games_python create "$@" || exit $?
    confirm "Create this server now? It downloads the pack, installs the loader and routes the hostname." || die "cancelled; nothing was created" $EX_REFUSED
    local out rc
    out=$(games_python create "$@" --apply); rc=$?
    printf '%s\n' "${out%CHANGED}"
    [[ $rc -eq 0 && $out == *CHANGED ]] && games_reload_router
    return $rc
}

wings_state_ok() { if have systemctl && systemctl is-active --quiet wings 2>/dev/null; then echo yes; else echo no; fi; }

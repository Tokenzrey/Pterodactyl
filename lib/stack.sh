#!/usr/bin/env bash
# shellcheck shell=bash
# Panel stack lifecycle: init, setup, up, down, status, logs, admin, tunnel, verify, update. Sourced by ./ptero.

# ---- docker compose wrapper -----------------------------------------------------------------
compose() {
    local files=(-f "$PTERO_ROOT/compose.yml") profiles=()
    tunnel_enabled && profiles=(--profile tunnel)
    [[ ${GAMES_ENABLED:-no} == yes ]] && profiles+=(--profile games)
    # compose.wings.yml (Wings as a container) is loaded only in that mode. Its services sit behind the `wings` profile, which
    # only the `wings` commands enable (compose_wings), so a plain `up` never starts Wings before it has a configuration.
    [[ ${WINGS_MODE:-host} == container ]] && files+=(-f "$PTERO_ROOT/compose.wings.yml")
    docker compose -p "$PTERO_PROJECT" "${files[@]}" ${profiles[@]+"${profiles[@]}"} "$@"
}
# every service of every file and profile: used by `down`, so it also removes the Wings container if there is one
compose_all() { docker compose -p "$PTERO_PROJECT" -f "$PTERO_ROOT/compose.yml" -f "$PTERO_ROOT/compose.wings.yml" --profile '*' "$@"; }

svc_id() { compose --profile wings ps -q "$1" 2>/dev/null | head -n1; }
svc_state() { # healthy|unhealthy|starting|running|exited|absent
    local id; id=$(svc_id "$1")
    [[ -n $id ]] || { echo absent; return; }
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo absent
}

# SQL runs inside the database container; the password comes from that container's environment (never argv)
db_sql() {
    compose exec -T database sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb -N -B -u"$MARIADB_USER" "$MARIADB_DATABASE" -e "$0"' "$1"
}
db_is_migrated() { [[ $(db_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='panel' AND table_name='migrations'" 2>/dev/null | tr -d '[:space:]') == 1 ]]; }
db_pending_migrations() {
    compose run --rm -T panel php artisan migrate:status --no-interaction 2>/dev/null | grep -Ec '[. ]Pending[[:space:]]*$'
}

panel_var_volume() { printf '%s_panel_var\n' "$PTERO_PROJECT"; }
volume_exists() { docker volume inspect "$1" >/dev/null 2>&1; }
# is there an APP_KEY in the panel_var volume?
panel_key_present() {
    local vol; vol=$(panel_var_volume)
    volume_exists "$vol" || return 1
    docker run --rm -v "$vol":/ptero_vol:ro "$UTILITY_IMAGE" sh -c 'grep -q "^APP_KEY=.\+" /ptero_vol/.env' >/dev/null 2>&1
}

panel_http_ok() { curl -fsS -m 8 -o /dev/null "http://127.0.0.1:${PANEL_BIND_PORT}/auth/login"; }

# ---- shared front matter for commands that touch the stack ---------------------------------------
prepare() { # prepare [need_tunnel]
    load_config || exit $EX_PREFLIGHT
    validate_config
    check_secrets "${1:-0}"
    if ((${#VERRORS[@]})); then report_verrors; exit $EX_PREFLIGHT; fi
    export_stack_env
}

# ---- init ---------------------------------------------------------------------------------------
cmd_init() {
    need openssl "apt install openssl"
    mkdir -p "$PTERO_ROOT/config" || die "cannot create config/"
    mkdir_private "$PTERO_ROOT/secrets" "$PTERO_ROOT/backups" || die "cannot create secrets/ and backups/"
    if [[ -f $PTERO_ROOT/config/deploy.env ]]; then
        info "config/deploy.env already exists: left untouched"
    else
        cp -- "$PTERO_ROOT/config/deploy.env.example" "$PTERO_ROOT/config/deploy.env" && chmod 600 "$PTERO_ROOT/config/deploy.env" \
            || die "cannot create config/deploy.env"
        info "created config/deploy.env from the example"
    fi
    local n
    for n in db_password redis_password; do
        if [[ -s $(secret_path "$n") ]]; then info "secrets/$n already exists: left untouched"
        else
            write_secret "$(secret_path "$n")" "$(openssl rand -hex 24)" || die "cannot write secrets/$n"
            info "generated secrets/$n"
        fi
    done
    cat <<'EOF'

Next:
  1. Edit config/deploy.env: PANEL_FQDN, WINGS_FQDN, ADMIN_EMAIL, PTERO_ACCEPT_BETA.
  2. Cloudflare (once, in the dashboard): see docs/cloudflare.md. Create a tunnel, then:  ./ptero tunnel set-token
  3. ./ptero setup
EOF
}

# ---- setup --------------------------------------------------------------------------------------
cmd_setup() {
    prepare 0
    preflight || die "preflight failed: fix the [FAIL] lines above" $EX_PREFLIGHT
    info "pulling pinned images"
    compose pull || die "image pull failed"
    info "starting database and cache"
    compose up -d --wait --wait-timeout 240 database cache || die "database/cache did not become healthy: ./ptero logs database"

    local key=0 fresh=0
    panel_key_present && key=1
    if db_is_migrated; then
        if ((!key)); then
            die "the database already has Panel tables but panel_var has no APP_KEY. Starting now would generate a NEW key and make
       encrypted data (API keys, node tokens, 2FA) unreadable. Restore the original key first: ./ptero restore <backup>.
       Nothing was changed." $EX_REFUSED
        fi
        local pending; pending=$(db_pending_migrations)
        if [[ ${pending:-0} -gt 0 ]]; then
            die "the database has $pending pending migration(s) (unfinished install or a version change). Run: ./ptero update" $EX_REFUSED
        fi
        info "existing installation detected: no migrate, no seed, APP_KEY kept"
    else
        info "fresh database: running migrations and seeders (once)"
        fresh=1
        compose run --rm -T panel php artisan migrate --seed --force --no-interaction \
            || die "migration failed. The database is partly migrated; fix the error, then run ./ptero update"
    fi

    if tunnel_enabled; then info "starting Panel and the Cloudflare tunnel"
    else warn "secrets/tunnel_token is empty: starting the Panel WITHOUT the tunnel (reachable on 127.0.0.1:${PANEL_BIND_PORT} only)"; fi
    games_prepare_routes || die "cannot create runtime/mc-router/routes.json"
    games_enabled && info "game router enabled: Minecraft hostnames *.${GAMES_DOMAIN} on port ${GAMES_PORT}"
    compose up -d --wait --wait-timeout 300 || die "a service is unhealthy: ./ptero status ; ./ptero logs"
    wait_until 120 "the Panel to answer on 127.0.0.1:${PANEL_BIND_PORT}" panel_http_ok || die "Panel does not answer: ./ptero logs panel"
    wings_container_autostart

    # Panel extras. A failure here never undoes the working Panel: it is reported and can be re-run on its own.
    info "applying Panel extensions and theme (${PANEL_EXTENSIONS:-none}; theme ${PANEL_THEME})"
    local nb=(); ((fresh)) && nb=(--no-backup)
    ext_apply ${nb[@]+"${nb[@]}"} || warn "some extensions could not be applied (the Panel itself is up). Fix the cause, then: ./ptero ext install"
    if games_enabled; then
        info "installing the Minecraft modpack egg"
        egg_install_run || warn "the modpack egg was not installed. Retry: ./ptero egg install"
    fi

    cat <<EOF

Panel stack is up.
  Panel (loopback):   http://127.0.0.1:${PANEL_BIND_PORT}
  Panel (public):     ${PANEL_URL}   (after the Cloudflare route exists: ./ptero tunnel info)

Still manual:
  - first administrator:           ./ptero admin create
  - Cloudflare routes (dashboard): ./ptero tunnel info      (docs/cloudflare.md)
  - node + Wings:                  docs/operations.md, "Wings"
  - host firewall:                 ./ptero firewall plan     then   sudo ./ptero firewall apply
  - Minecraft servers (optional):  docs/games.md  (set GAMES_ENABLED=yes, ./ptero egg install, ./ptero game create)
Check at any time: ./ptero status   ./ptero verify   ./ptero audit
EOF
}

cmd_up() {
    prepare 0
    games_prepare_routes || die "cannot create runtime/mc-router/routes.json"
    compose up -d --wait --wait-timeout 300 || die "a service is unhealthy: ./ptero status"
    wings_container_autostart
}

cmd_down() {
    prepare 0
    info "stopping containers (named volumes and all data are kept)"
    compose_all down || die "docker compose down failed"
}

# ---- status -------------------------------------------------------------------------------------
cmd_status() {
    prepare 0
    local rc=0 s svc code
    printf '%-14s %s\n' SERVICE STATE
    for svc in database cache panel; do
        s=$(svc_state "$svc"); printf '%-14s %s\n' "$svc" "$s"
        [[ $s == healthy ]] || rc=1
    done
    if tunnel_enabled; then
        s=$(svc_state cloudflared); printf '%-14s %s\n' cloudflared "$s"
        [[ $s == healthy ]] || rc=1
    else printf '%-14s %s\n' cloudflared "not configured (no tunnel token)"; fi
    if games_enabled; then
        s=$(svc_state mc-router); printf '%-14s %s\n' mc-router "$s"
        [[ $s == running || $s == healthy ]] || rc=1
    fi
    if panel_http_ok; then printf '%-14s %s\n' panel-http "ok (127.0.0.1:${PANEL_BIND_PORT})"; else printf '%-14s %s\n' panel-http "NOT ANSWERING"; rc=1; fi
    if wings_container_mode; then
        s=$(svc_state wings)
        if [[ $s == absent ]]; then printf '%-14s %s\n' wings-container "not installed (./ptero wings install)"
        else
            printf '%-14s %s\n' wings-container "$s"
            [[ $s == running || $s == healthy ]] || rc=1
            code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WINGS_API_PORT}/" 2>/dev/null)
            if [[ -z $code || $code == 000 ]]; then printf '%-14s %s\n' wings-api "NOT ANSWERING on 127.0.0.1:${WINGS_API_PORT}"; rc=1
            else printf '%-14s %s\n' wings-api "answers (HTTP $code; 401 is normal without credentials)"; fi
            s=$(svc_state egress-guard); printf '%-14s %s\n' egress-guard "$s"
            [[ $s == healthy ]] || rc=1
        fi
    elif have systemctl && systemctl cat wings >/dev/null 2>&1; then
        s=$(systemctl is-active wings 2>/dev/null); printf '%-14s %s\n' wings-service "$s"
        [[ $s == active ]] || rc=1
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WINGS_API_PORT}/" 2>/dev/null)
        if [[ -z $code || $code == 000 ]]; then printf '%-14s %s\n' wings-api "NOT ANSWERING on 127.0.0.1:${WINGS_API_PORT}"; rc=1
        else printf '%-14s %s\n' wings-api "answers (HTTP $code; 401 is normal without credentials)"; fi
    else printf '%-14s %s\n' wings-service "not installed (sudo ./ptero wings install)"; fi
    printf '\nversions: panel %s, wings %s\n' "$PANEL_VERSION" "$WINGS_VERSION"
    return $rc
}

cmd_logs() { # logs [-f] [--tail N] [service]
    prepare 0
    local follow=() tail=100 svc=""
    while (($#)); do
        case $1 in
            -f|--follow) follow=(-f) ;;
            --tail) tail=${2:-}; shift ;;
            wings) svc=wings ;;
            *) svc=$1 ;;
        esac
        shift
    done
    [[ $tail =~ ^[0-9]+$ ]] || die "--tail needs a number" $EX_USAGE
    if wings_container_mode && [[ $svc == wings || $svc == egress-guard ]]; then
        compose_wings logs --tail "$tail" ${follow[@]+"${follow[@]}"} "$svc"
    elif [[ $svc == wings ]]; then
        have journalctl || die "journalctl not available"
        journalctl -u wings -n "$tail" --no-pager ${follow[@]+"${follow[@]}"}
    else
        compose logs --tail "$tail" ${follow[@]+"${follow[@]}"} ${svc:+"$svc"}
    fi
}

# ---- administrator ------------------------------------------------------------------------------
cmd_admin_create() {
    prepare 0
    [[ $(svc_state panel) == healthy ]] || die "the Panel is not running: ./ptero setup" $EX_REFUSED
    [[ -t 0 && -t 1 ]] || die "p:user:make is interactive; run this from a terminal. The password is typed into the Panel's own hidden prompt, never passed as an argument" $EX_REFUSED
    info "creating an administrator (answer 'yes' to administrator when asked)"
    compose exec panel php artisan p:user:make
}

# ---- tunnel -------------------------------------------------------------------------------------
cmd_tunnel() {
    case ${1:-} in
        set-token)
            load_config || exit $EX_PREFLIGHT
            mkdir_private "$PTERO_ROOT/secrets" || die "cannot create secrets/"
            local tok
            tok=$(read_hidden "Paste the tunnel token (input hidden): ")
            tok=${tok//[[:space:]]/}
            [[ -n $tok ]] || die "empty token" $EX_USAGE
            # users often paste the whole `cloudflared ... run --token XXXX` line from the dashboard
            tok=${tok##*--token}
            valid_tunnel_token "$tok" || die "that is not a Cloudflare tunnel token (base64 JSON with keys a, t, s). Copy only the token, not the whole command" $EX_USAGE
            write_secret "$(secret_path tunnel_token)" "$tok" || die "cannot write secrets/tunnel_token"
            info "saved secrets/tunnel_token (mode 600). Apply with: ./ptero up"
            ;;
        info)
            load_config || exit $EX_PREFLIGHT
            validate_config || { report_verrors; exit $EX_PREFLIGHT; }
            cat <<EOF
Cloudflare dashboard -> Zero Trust -> Networks -> Tunnels -> <your tunnel> -> Published application routes.
Add exactly these two (HTTP, not HTTPS: TLS ends at Cloudflare; the origins listen on loopback only):

  Hostname              Service URL
  ${PANEL_FQDN}   http://127.0.0.1:${PANEL_BIND_PORT}
  ${WINGS_FQDN}   http://127.0.0.1:${WINGS_API_PORT}

Notes:
  - The tunnel connector runs with host networking, which is why the origins are 127.0.0.1.
  - Do NOT put Cloudflare Access in front of ${WINGS_FQDN}: Wings is called with JWTs by the Panel and
    by browsers (console WebSocket) that cannot complete an Access login.
  - WebSockets need no extra setting. Game traffic (TCP/UDP) cannot use these routes (docs/cloudflare.md).
EOF
            ;;
        *) die "usage: ./ptero tunnel {set-token|info}" $EX_USAGE ;;
    esac
}

# ---- verify (public path, no credentials used) --------------------------------------------------
cmd_verify() {
    prepare 0
    local rc=0 code
    printf 'Public path checks (no credentials):\n'
    for host in "$PANEL_FQDN" "$WINGS_FQDN"; do
        if getent hosts "$host" >/dev/null 2>&1; then printf '  [ ok ] DNS resolves: %s\n' "$host"
        else printf '  [FAIL] DNS does not resolve: %s (zone not active, or the route/CNAME is missing)\n' "$host"; rc=1; fi
    done
    code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "${PANEL_URL}/auth/login" 2>/dev/null)
    case $code in
        200) printf '  [ ok ] Panel login page over HTTPS: 200\n' ;;
        530|502|1033) printf '  [FAIL] Panel: HTTP %s from Cloudflare: the tunnel is down or the route points at the wrong origin (./ptero tunnel info)\n' "$code"; rc=1 ;;
        *) printf '  [FAIL] Panel: HTTP %s (expected 200)\n' "${code:-none}"; rc=1 ;;
    esac
    code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "${WINGS_URL}/" 2>/dev/null)
    case $code in
        401|403|404) printf '  [ ok ] Wings endpoint reachable (HTTP %s: authentication required, as expected)\n' "$code" ;;
        530|502) printf '  [FAIL] Wings: HTTP %s from Cloudflare: Wings is not running on 127.0.0.1:%s or the route origin is wrong\n' "$code" "$WINGS_API_PORT"; rc=1 ;;
        *) printf '  [FAIL] Wings: HTTP %s (expected 401/403/404)\n' "${code:-none}"; rc=1 ;;
    esac
    return $rc
}

# ---- update -------------------------------------------------------------------------------------
# Compares the images the running containers use with the pins in config/versions.env.
drift_report() {
    local svc ref id cur pair var drift=0
    # Wings is not compared: like the host binary, it is updated by `./ptero wings update`, never by `update`.
    for pair in database:MARIADB_IMAGE cache:REDIS_IMAGE panel:PANEL_IMAGE cloudflared:CLOUDFLARED_IMAGE; do
        svc=${pair%%:*}; var=${pair##*:}; ref=${!var}
        id=$(svc_id "$svc"); [[ -n $id ]] || continue
        cur=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null)
        if [[ $cur != "$ref" ]]; then printf '  %-12s %s\n             -> %s\n' "$svc" "$cur" "$ref"; drift=1; fi
    done
    return $drift
}

cmd_update() {
    local check=0
    while (($#)); do case $1 in --check) check=1 ;; *) die "unknown option: $1" $EX_USAGE ;; esac; shift; done
    prepare 0
    [[ $(svc_state database) == healthy ]] || die "the database is not running/healthy; start the stack first: ./ptero up" $EX_REFUSED
    local pending=0 drifted=0 report
    report=$(drift_report) || drifted=1
    db_is_migrated && pending=$(db_pending_migrations)
    if ((!drifted)) && [[ ${pending:-0} -eq 0 ]]; then info "running containers already match config/versions.env and no migrations are pending: nothing to update"; return 0; fi
    printf 'Pending change:\n%s\n' "${report:-  (no image drift)}"
    [[ ${pending:-0} -gt 0 ]] && printf '  database: %s pending migration(s)\n' "$pending"
    ((check)) && return 0
    confirm "This will take a mandatory backup, pull images, stop the Panel, run 'migrate --seed' (the seeder REPLACES the bundled eggs: customised eggs must be copies) and restart. The Panel is offline for a few minutes." \
        || die "update cancelled; nothing changed" $EX_REFUSED
    local out
    out=$(backup_create pre-update) || die "backup failed: NOT updating. Fix the backup first" $EX_FAIL
    info "backup: $out"
    compose pull || die "image pull failed; nothing was stopped"
    compose stop panel || die "cannot stop the Panel"
    compose up -d --wait --wait-timeout 240 database cache || die "database/cache unhealthy after pull"
    compose run --rm -T panel php artisan migrate --seed --force --no-interaction \
        || die "migration failed. Roll back: restore $out with the previous config/versions.env (docs/operations.md, Rollback)"
    compose up -d --wait --wait-timeout 300 || die "a service is unhealthy after the update; roll back with: ./ptero restore $out"
    wait_until 120 "the Panel to answer" panel_http_ok || die "Panel does not answer after the update; roll back with: ./ptero restore $out"
    info "updated. Rollback point: $out (restore it together with the previous config/versions.env)"
}

#!/usr/bin/env bash
# shellcheck shell=bash
# Wings: install / configure / status / update / logs. Sourced by ./ptero.
# WINGS_MODE=host (default): a binary under systemd on the host. Needs root (it writes /etc and /usr/local).
# WINGS_MODE=container: a Compose service from compose.wings.yml (see the container section below). No root needed.
#
# Wings is the officially documented way: a static binary under systemd. This script does exactly what the upstream
# install page does (binary in /usr/local/bin, config in /etc/pterodactyl, systemd unit), with the download pinned to
# a version and a sha256 from config/versions.env.

wings_bin()  { printf '%s\n' "${PTERO_WINGS_BIN:-/usr/local/bin/wings}"; }
wings_etc()  { printf '%s\n' "${PTERO_WINGS_ETC:-/etc/pterodactyl}"; }
unit_dir()   { printf '%s\n' "${PTERO_SYSTEMD_DIR:-/etc/systemd/system}"; }

wings_arch() {
    case $(uname -m) in
        x86_64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) return 1 ;;
    esac
}

# wings_fetch -> path of a downloaded, sha256-verified binary (inside the private temp dir)
wings_fetch() {
    local arch var expected out url actual
    arch=$(wings_arch) || { err "no Wings build for $(uname -m)"; return 1; }
    var=WINGS_SHA256_${arch^^}; expected=${!var}
    out=$PTERO_TMP/wings_linux_$arch
    url="https://github.com/pterodactyl/wings/releases/download/${WINGS_VERSION}/wings_linux_${arch}"
    info "downloading Wings ${WINGS_VERSION} (${arch})"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 600 -o "$out" "$url" \
        || { err "download failed: $url"; return 1; }
    actual=$(sha256sum "$out" | cut -d' ' -f1)
    if [[ $actual != "$expected" ]]; then
        err "sha256 mismatch for the Wings download (got ${actual:0:16}..., pinned ${expected:0:16}...). Refusing to install. If you bumped WINGS_VERSION, update the hashes in config/versions.env too"
        return 1
    fi
    printf '%s\n' "$out"
}

wings_active() { systemctl is-active --quiet wings 2>/dev/null; }

wings_install_binary() { # wings_install_binary VERIFIED_FILE
    local src=$1 bin; bin=$(wings_bin)
    mkdir -p -- "$(dirname "$bin")" || return 1
    if [[ -f $bin ]] && ! cmp -s "$src" "$bin"; then
        cp -p -- "$bin" "$bin.prev" && info "previous binary kept as $bin.prev (rollback: mv it back and restart)"
    fi
    install -m 0755 -o root -g root -- "$src" "$bin.new" 2>/dev/null || install -m 0755 -- "$src" "$bin.new" || return 1
    mv -f -- "$bin.new" "$bin"
}

wings_install_unit() {
    local tpl="$PTERO_ROOT/systemd/wings.service.tpl" dst rendered
    dst="$(unit_dir)/wings.service"
    rendered=$PTERO_TMP/wings.service
    sed -e "s#@ETC_DIR@#$(wings_etc)#g" -e "s#@WINGS_BIN@#$(wings_bin)#g" "$tpl" >"$rendered" || return 1
    mkdir -p -- "$(unit_dir)" || return 1
    if [[ -f $dst ]] && cmp -s "$rendered" "$dst"; then info "systemd unit already up to date"; return 0; fi
    install -m 0644 -- "$rendered" "$dst" || return 1
    systemctl daemon-reload || return 1
    info "installed $dst"
}

# ---- Wings as a container (WINGS_MODE=container) ----------------------------------------------------------------------
# For machines that cannot run Wings under systemd with Docker Engine (Docker Desktop on WSL2). The Compose services are in
# compose.wings.yml. The config (it holds the node token) lives in a named volume, never in the repo tree.
wings_container_mode() { [[ ${WINGS_MODE:-host} == container ]]; }
wings_etc_volume() { printf '%s_wings_etc\n' "$PTERO_PROJECT"; }
compose_wings() { compose --profile wings "$@"; }
wings_native_active() { have systemctl && systemctl is-active --quiet wings 2>/dev/null; }
# the command a person should run to install Wings in the current mode (used in messages)
wings_install_hint() { if wings_container_mode; then echo "./ptero wings install"; else echo "sudo ./ptero wings install"; fi; }

wings_vol_has_config() {
    volume_exists "$(wings_etc_volume)" || return 1
    docker run --rm -v "$(wings_etc_volume)":/ptero_wings:ro "$UTILITY_IMAGE" sh -c 'test -s /ptero_wings/config.yml' >/dev/null 2>&1
}
wings_vol_read_config() { docker run --rm -v "$(wings_etc_volume)":/ptero_wings:ro "$UTILITY_IMAGE" sh -c 'cat /ptero_wings/config.yml'; }

# A volume made by `docker run -v` has no Compose labels, and Compose would then warn at every start that it "was not created by
# Docker Compose". Creating it with the two labels Compose looks for makes it the Compose volume wings_etc.
wings_vol_ensure() {
    local vol; vol=$(wings_etc_volume)
    volume_exists "$vol" && return 0
    docker volume create --label "com.docker.compose.project=$PTERO_PROJECT" --label "com.docker.compose.volume=wings_etc" "$vol" >/dev/null
}

# wings_vol_install_config FILE : the file goes in through stdin (never argv), mode 600, atomic, previous copy kept when it differs
wings_vol_install_config() {
    wings_vol_ensure || return 1
    docker run --rm -i -v "$(wings_etc_volume)":/ptero_wings "$UTILITY_IMAGE" sh -c '
        umask 077
        cat >/ptero_wings/config.yml.new || exit 1
        if [ -f /ptero_wings/config.yml ] && ! cmp -s /ptero_wings/config.yml.new /ptero_wings/config.yml; then
            ts=$(date -u +%Y%m%dT%H%M%SZ)
            cp -p /ptero_wings/config.yml "/ptero_wings/config.yml.bak-$ts" && chmod 600 "/ptero_wings/config.yml.bak-$ts" \
                && echo "previous config kept in the volume as config.yml.bak-$ts" >&2
        fi
        chmod 600 /ptero_wings/config.yml.new && mv -f /ptero_wings/config.yml.new /ptero_wings/config.yml' <"$1"
}

# Pulls the pinned image and (re)creates the two services. --wait: wings is "running", egress-guard only counts once its rules exist.
wings_container_up() {
    compose_wings pull wings egress-guard || { err "image pull failed"; return 1; }
    compose_wings up -d --wait --wait-timeout 240 wings egress-guard \
        || { err "wings or egress-guard did not become ready: ./ptero logs wings   ./ptero logs egress-guard"; return 1; }
}

# Used by `up` and `setup`: bring Wings back when a config exists. Never fatal: the Panel is already up.
wings_container_autostart() {
    wings_container_mode || return 0
    if ! wings_vol_has_config; then info "Wings (container): no configuration yet, not started. ./ptero wings install --config <file>"; return 0; fi
    if wings_native_active; then warn "the native Wings service is active: the Wings container was NOT started (sudo systemctl disable --now wings)"; return 0; fi
    compose_wings up -d --wait --wait-timeout 240 wings egress-guard || warn "Wings (container) did not become ready: ./ptero logs wings"
}

wings_container_install() { # wings_container_install CONFIG_FILE_OR_EMPTY
    local cfg=$1
    prepare 0
    wings_native_active && die "the native Wings service (systemd) is active: two Wings for one node clash on the API port and on SFTP port 2022. Stop it first: sudo systemctl disable --now wings" $EX_REFUSED
    confirm "Start Wings as a container (${WINGS_IMAGE%%@*}). It holds the Docker socket and bind-mounts /var/lib/pterodactyl, /tmp/pterodactyl, /var/log/pterodactyl and /run/wings; a second container, egress-guard, adds iptables rules for the game network. Continue?" \
        || die "cancelled" $EX_REFUSED
    [[ -z $cfg ]] || wings_configure "$cfg" || exit $EX_FAIL
    if ! wings_vol_has_config; then
        info "there is no Wings configuration yet, so Wings is NOT started."
        info "Create the node in the Panel (Admin -> Nodes), open its Configuration tab, save the YAML to a file, then:"
        info "  ./ptero wings install --config <file>"
        return 0
    fi
    wings_container_up || exit $EX_FAIL
    info "Wings is starting; the first start can take a minute while Docker networks are created"
    wings_wait_ready || warn "Wings did not answer yet: ./ptero logs wings"
}

wings_container_status() {
    prepare 0
    local s code
    s=$(svc_state wings)
    printf 'mode     : container (%s)\n' "${WINGS_IMAGE%%@*}"
    printf 'service  : %s\n' "$s"
    printf 'pinned   : %s (%s)\n' "$WINGS_VERSION" "${WINGS_IMAGE##*@sha256:}"
    printf 'guard    : %s\n' "$(svc_state egress-guard)"
    code=$(wings_api_code)
    printf 'api      : HTTP %s on 127.0.0.1:%s (401 is normal without credentials)\n' "${code:-000}" "$WINGS_API_PORT"
    [[ $s == running || $s == healthy ]] && wings_api_answers
}

wings_container_cmd() { # wings_container_cmd SUBCOMMAND ARGS...
    local sub=$1; shift
    case $sub in
        install)
            local cfg=""
            while (($#)); do case $1 in --config) cfg=${2:-}; shift ;; *) die "unknown option: $1" $EX_USAGE ;; esac; shift; done
            wings_container_install "$cfg"
            ;;
        configure)
            [[ -n ${1:-} ]] || die "usage: ./ptero wings configure <config.yml from the Panel node's Configuration tab>" $EX_USAGE
            prepare 0
            wings_configure "$1" || exit $EX_FAIL
            ;;
        update)
            (($# == 0)) || die "usage: ./ptero wings update [--yes]" $EX_USAGE
            prepare 0
            confirm "Pull ${WINGS_IMAGE%%@*} (pinned in config/versions.env) and recreate the Wings container? Running game containers keep running." \
                || die "cancelled" $EX_REFUSED
            wings_container_up || exit $EX_FAIL
            info "Wings container is on ${WINGS_VERSION}"
            ;;
        status) wings_container_status ;;
        logs)
            prepare 0
            compose_wings logs --tail "${1:-100}" wings egress-guard 2>&1 | redact
            ;;
        *) die "usage: ./ptero wings {install [--config FILE]|configure FILE|update|status|logs [N]}" $EX_USAGE ;;
    esac
}

# wings_configure FILE : validate + patch the Panel-generated config, install it (600), restart if running
wings_configure() {
    local file=$1 patched remote etc ts
    [[ -r $file ]] || { err "cannot read $file"; return 1; }
    local listen=() container=()
    if wings_container_mode; then
        case $WINGS_REMOTE_MODE in
            public) remote="https://${PANEL_FQDN}" ;;
            internal) remote="http://panel:80" ;;            # the Panel service on the Compose edge network
        esac
        # Inside the container Wings must listen on every interface so that the published port (loopback only on the host) reaches
        # it, and the tunnel's hop arrives from the edge network's gateway, not from 127.0.0.1.
        listen=(--host 0.0.0.0 --sftp-host 0.0.0.0 --trusted-proxy "$PANEL_EDGE_SUBNET")
        container=(--container)
    else
        case $WINGS_REMOTE_MODE in
            public) remote="https://${PANEL_FQDN}" ;;
            internal) remote="http://127.0.0.1:${PANEL_BIND_PORT}" ;;
        esac
        listen=(--trusted-proxy 127.0.0.1 --sftp-host "$WINGS_SFTP_BIND")
    fi
    patched=$PTERO_TMP/wings-config.yml
    local tune=(); [[ $WINGS_TUNING == yes ]] && tune=(--tune)
    python3 "$PTERO_ROOT/lib/wings_config.py" patch "$file" --out "$patched" --port "$WINGS_API_PORT" ${tune[@]+"${tune[@]}"} \
        --remote "$remote" --origin "https://${PANEL_FQDN}" "${listen[@]}" ${container[@]+"${container[@]}"} \
        --game-subnet "$GAME_NET_SUBNET" || { err "the configuration was rejected (see above)"; return 1; }
    python3 "$PTERO_ROOT/lib/wings_config.py" check "$patched" --remote "$remote" --port "$WINGS_API_PORT" ${container[@]+"${container[@]}"} \
        || { err "the patched configuration still fails the check"; return 1; }
    if wings_container_mode; then
        wings_vol_install_config "$patched" || { err "cannot write the configuration into the $(wings_etc_volume) volume"; return 1; }
        info "installed config.yml into the $(wings_etc_volume) volume (mode 600)"
        if [[ $(svc_state wings) != absent ]]; then compose_wings restart wings && info "Wings restarted"; fi
    else
        etc=$(wings_etc)
        mkdir_private "$etc" || return 1
        if [[ -f $etc/config.yml ]] && ! cmp -s "$patched" "$etc/config.yml"; then
            ts=$(date -u +%Y%m%dT%H%M%SZ)
            cp -p -- "$etc/config.yml" "$etc/config.yml.bak-$ts" && chmod 600 "$etc/config.yml.bak-$ts" && info "previous config kept as $etc/config.yml.bak-$ts"
        fi
        install -m 0600 -- "$patched" "$etc/config.yml.new" && mv -f -- "$etc/config.yml.new" "$etc/config.yml" || return 1
        info "installed $etc/config.yml (mode 600)"
        if wings_active; then systemctl restart wings && info "Wings restarted"; fi
    fi
    warn "the file you passed ($file) still contains the node token. Delete it when done: shred -u '$file'"
}

wings_api_code() { curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WINGS_API_PORT}/" 2>/dev/null; }
wings_api_answers() { local c; c=$(wings_api_code); [[ -n $c && $c != 000 ]]; }
wings_wait_ready() { wait_until 180 "Wings to answer on 127.0.0.1:${WINGS_API_PORT}" wings_api_answers; }

cmd_wings() {
    local sub=${1:-}; shift || true
    # WINGS_MODE decides which implementation runs, so the configuration is read first; `prepare` inside each command reports
    # any problem with it properly, so a failure here is not fatal yet.
    case $sub in install|configure|update|status|logs) load_config >/dev/null 2>&1 || true ;; esac
    if wings_container_mode; then wings_container_cmd "$sub" "$@"; return; fi
    case $sub in
        install)
            local cfg=""
            while (($#)); do case $1 in --config) cfg=${2:-}; shift ;; *) die "unknown option: $1" $EX_USAGE ;; esac; shift; done
            need_root "wings install"
            prepare 0
            need systemctl "Wings needs a systemd host"
            if ! systemctl is-active --quiet docker 2>/dev/null; then
                # WSL + Docker Desktop: dockerd runs in Docker Desktop's VM, so the distro has no docker.service unit.
                docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qx 'Docker Desktop' \
                    || die "docker.service is not active (systemctl status docker) and Docker Desktop is not reachable from this distro" $EX_PREFLIGHT
                warn "using the Docker Desktop daemon instead of docker.service; bind mounts and port publishing are not verified on this path"
            fi
            confirm "Host changes: install $(wings_bin), create $(wings_etc) (700), write $(unit_dir)/wings.service. Continue?" || die "cancelled" $EX_REFUSED
            local bin; bin=$(wings_fetch) || exit $EX_FAIL
            wings_install_binary "$bin" || die "cannot install the binary"
            wings_install_unit || die "cannot install the systemd unit"
            mkdir_private "$(wings_etc)" || die "cannot create $(wings_etc)"
            [[ -n $cfg ]] && { wings_configure "$cfg" || exit $EX_FAIL; }
            if [[ -f $(wings_etc)/config.yml ]]; then
                systemctl enable --now wings || die "cannot enable/start wings: journalctl -u wings"
                info "Wings is starting; the first start can take several minutes while Docker networks are created"
                wings_wait_ready || warn "Wings did not answer yet: ./ptero logs wings"
            else
                info "binary and unit are installed, but there is no config yet, so Wings is NOT started."
                info "Create the node in the Panel (Admin -> Nodes), open its Configuration tab, save the YAML to a file, then:"
                info "  sudo ./ptero wings configure <file>   &&   sudo systemctl enable --now wings"
            fi
            ;;
        configure)
            [[ -n ${1:-} ]] || die "usage: sudo ./ptero wings configure <config.yml from the Panel node's Configuration tab>" $EX_USAGE
            need_root "wings configure"
            prepare 0
            wings_configure "$1" || exit $EX_FAIL
            ;;
        update)
            (($# == 0)) || die "usage: sudo ./ptero wings update [--yes]" $EX_USAGE
            need_root "wings update"
            prepare 0
            confirm "Replace $(wings_bin) with Wings ${WINGS_VERSION} and restart the service (running game containers keep running)?" || die "cancelled" $EX_REFUSED
            local nb; nb=$(wings_fetch) || exit $EX_FAIL
            wings_install_binary "$nb" || die "cannot install the binary"
            wings_active && { systemctl restart wings || die "restart failed; rollback: mv $(wings_bin).prev $(wings_bin) && systemctl restart wings"; }
            info "Wings is now ${WINGS_VERSION}"
            ;;
        status)
            prepare 0
            local bin ver="not installed" code; bin=$(wings_bin)
            [[ -x $bin ]] && ver=$( { "$bin" --version || "$bin" version; } 2>/dev/null | head -n1)
            printf 'binary   : %s\n' "${ver:-unknown}"
            printf 'service  : %s\n' "$(systemctl is-active wings 2>/dev/null || echo 'inactive/not installed')"
            printf 'pinned   : %s\n' "$WINGS_VERSION"
            code=$(wings_api_code)
            printf 'api      : HTTP %s on 127.0.0.1:%s (401 is normal without credentials)\n' "${code:-000}" "$WINGS_API_PORT"
            wings_active && wings_api_answers
            ;;
        logs)
            have journalctl || die "journalctl not available"
            journalctl -u wings -n "${1:-100}" --no-pager | redact
            ;;
        *) die "usage: ./ptero wings {install [--config FILE]|configure FILE|update|status|logs [N]}" $EX_USAGE ;;
    esac
}

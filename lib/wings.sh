#!/usr/bin/env bash
# shellcheck shell=bash
# Wings on the host: install / configure / status / update / logs. Sourced by ./ptero. Needs root (it writes /etc and /usr/local).
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

# wings_configure FILE : validate + patch the Panel-generated config, install it (600), restart if running
wings_configure() {
    local file=$1 patched remote etc ts
    [[ -r $file ]] || { err "cannot read $file"; return 1; }
    case $WINGS_REMOTE_MODE in
        public) remote="https://${PANEL_FQDN}" ;;
        internal) remote="http://127.0.0.1:${PANEL_BIND_PORT}" ;;
    esac
    patched=$PTERO_TMP/wings-config.yml
    local tune=(); [[ $WINGS_TUNING == yes ]] && tune=(--tune)
    python3 "$PTERO_ROOT/lib/wings_config.py" patch "$file" --out "$patched" --port "$WINGS_API_PORT" ${tune[@]+"${tune[@]}"} \
        --remote "$remote" --origin "https://${PANEL_FQDN}" --trusted-proxy 127.0.0.1 --sftp-host "$WINGS_SFTP_BIND" \
        --game-subnet "$GAME_NET_SUBNET" || { err "the configuration was rejected (see above)"; return 1; }
    python3 "$PTERO_ROOT/lib/wings_config.py" check "$patched" --remote "$remote" --port "$WINGS_API_PORT" || { err "the patched configuration still fails the check"; return 1; }
    etc=$(wings_etc)
    mkdir_private "$etc" || return 1
    if [[ -f $etc/config.yml ]] && ! cmp -s "$patched" "$etc/config.yml"; then
        ts=$(date -u +%Y%m%dT%H%M%SZ)
        cp -p -- "$etc/config.yml" "$etc/config.yml.bak-$ts" && chmod 600 "$etc/config.yml.bak-$ts" && info "previous config kept as $etc/config.yml.bak-$ts"
    fi
    install -m 0600 -- "$patched" "$etc/config.yml.new" && mv -f -- "$etc/config.yml.new" "$etc/config.yml" || return 1
    info "installed $etc/config.yml (mode 600)"
    if wings_active; then systemctl restart wings && info "Wings restarted"; fi
    warn "the file you passed ($file) still contains the node token. Delete it when done: shred -u '$file'"
}

wings_api_code() { curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WINGS_API_PORT}/" 2>/dev/null; }
wings_api_answers() { local c; c=$(wings_api_code); [[ -n $c && $c != 000 ]]; }
wings_wait_ready() { wait_until 180 "Wings to answer on 127.0.0.1:${WINGS_API_PORT}" wings_api_answers; }

cmd_wings() {
    local sub=${1:-}; shift || true
    case $sub in
        install)
            local cfg=""
            while (($#)); do case $1 in --config) cfg=${2:-}; shift ;; *) die "unknown option: $1" $EX_USAGE ;; esac; shift; done
            need_root "wings install"
            prepare 0
            need systemctl "Wings needs a systemd host"
            systemctl is-active --quiet docker 2>/dev/null || die "docker.service is not active (systemctl status docker)" $EX_PREFLIGHT
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

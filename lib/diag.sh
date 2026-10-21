#!/usr/bin/env bash
# shellcheck shell=bash
# ./ptero diagnose [--output FILE]: one redacted report to attach to a bug report / paste to a helper.
# Best effort: a failing section is reported, never fatal. Secret values are masked by lib/redact.py
# (exact values of secrets/* plus token shapes) and secrets are never read into the report in the first place.

diag_section() { printf '\n===== %s =====\n' "$1"; }

diag_body() {
    printf 'ptero diagnose  %s  host=%s\n' "$(date -u +%FT%TZ)" "$(hostname)"
    diag_section "system"
    uname -srm; [[ -r /etc/os-release ]] && sed -n 's/^PRETTY_NAME=//p' /etc/os-release
    diag_section "pinned versions (config/versions.env)"
    grep -v '^[[:space:]]*#' "$PTERO_ROOT/config/versions.env" 2>/dev/null | grep -v '^$'

    diag_section "configuration"
    if load_config 2>&1; then
        grep -Ev '^[[:space:]]*(#|$)' "$PTERO_ROOT/config/deploy.env"
        validate_config && echo "validate_config: OK" || { printf 'validate_config: FAILED\n'; printf '  - %s\n' "${VERRORS[@]}"; }
        local n p
        for n in "${SECRET_NAMES[@]}"; do
            p=$(secret_path "$n")
            if [[ -f $p ]]; then printf 'secrets/%s: present, mode %s, %s bytes\n' "$n" "$(file_mode "$p")" "$(wc -c <"$p")"
            else printf 'secrets/%s: MISSING\n' "$n"; fi
        done
        export_stack_env
    else
        echo "config could not be loaded (see message above)"
        return 0
    fi

    diag_section "preflight"
    PTERO_PREFLIGHT_SKIP=${PTERO_PREFLIGHT_SKIP:-} preflight 2>&1 || true

    diag_section "docker"
    docker version --format 'client {{.Client.Version}} / server {{.Server.Version}}' 2>&1 || true
    docker compose version 2>&1 || true
    compose config --quiet 2>&1 && echo "compose.yml: valid" || echo "compose.yml: INVALID"
    compose ps -a 2>&1 || true
    diag_section "image drift vs config/versions.env"
    drift_report 2>&1 && echo "none" || true

    diag_section "status"
    (cmd_status) 2>&1 || true     # subshell: these call `exit` on bad config
    diag_section "public path"
    (cmd_verify) 2>&1 || true

    local svc
    for svc in database cache panel cloudflared; do
        diag_section "log tail: $svc (60 lines)"
        compose logs --no-color --tail 60 "$svc" 2>&1 || true
    done

    diag_section "wings"
    if wings_container_mode; then
        printf 'mode: container (%s)\n' "${WINGS_IMAGE%%@*}"
        compose_wings ps -a wings egress-guard 2>&1 || true
        compose_wings logs --no-color --tail 40 wings egress-guard 2>&1 || true
        if wings_vol_has_config; then
            local dcfg="$PTERO_TMP/wings-diag.yml"
            wings_vol_read_config >"$dcfg" 2>/dev/null && python3 "$PTERO_ROOT/lib/wings_config.py" check "$dcfg" --port "$WINGS_API_PORT" --container 2>&1 || true
            rm -f -- "$dcfg"
        else echo "config.yml: not in the $(wings_etc_volume) volume yet"; fi
    elif have systemctl && systemctl cat wings >/dev/null 2>&1; then
        systemctl status wings --no-pager -n 0 2>&1 | head -n 12 || true
        journalctl -u wings -n 40 --no-pager 2>&1 || true
        local cfg; cfg=$(wings_etc)/config.yml
        if [[ -r $cfg ]]; then
            printf 'config.yml: mode %s\n' "$(file_mode "$cfg")"
            python3 "$PTERO_ROOT/lib/wings_config.py" check "$cfg" --port "$WINGS_API_PORT" 2>&1 || true
        else echo "config.yml: not readable by this user (run as root to include it)"; fi
    else
        echo "wings service not installed"
    fi
}

cmd_diagnose() {
    local out=""
    while (($#)); do case $1 in --output) out=${2:-}; shift ;; *) die "usage: ./ptero diagnose [--output FILE]" $EX_USAGE ;; esac; shift; done
    if [[ -n $out ]]; then
        [[ ! -e $out ]] || die "$out already exists; not overwriting" $EX_REFUSED
        (umask 077; diag_body 2>&1 | redact >"$out") || die "could not write $out"
        info "report written to $out (mode 600). Skim it before sharing; masking is best effort"
    else
        diag_body 2>&1 | redact
    fi
}

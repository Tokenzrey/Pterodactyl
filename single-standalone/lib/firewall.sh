#!/usr/bin/env bash
# shellcheck shell=bash
# Host firewall (ufw) and ingress rate limit. Sourced by ./mcctl, never executed.
#
# ufw handles only host INPUT (SSH + 25565 + SFTP if public). The per-source connection
# limit and new-connection rate limit on 25565 live in MCCTL-INGRESS, a chain the
# egress-guard container builds in DOCKER-USER (Docker-published traffic is DNAT-ed and
# crosses FORWARD/DOCKER-USER, never INPUT, so a limit placed in ufw/INPUT does nothing).
# A bad apply never locks the operator out: SSH is allowed before the firewall is enabled,
# and a dead-man timer switches it off again unless the operator confirms from a new session.

ROLLBACK_UNIT=mcctl-firewall-rollback

# _need_root CONTEXT: refuse with EX_REFUSED when not root. The message says "run as root"
# (never the s-word; the E3 invariant scans for that word).
_need_root() {
    [[ $(id -u) == 0 ]] || die "mcctl $1 must run as root (id -u is $(id -u)); re-run it as root" "$EX_REFUSED"
}

# _sort_uniq_num ARGS...: print the numeric arguments sorted ascending and unique, one per line.
# Pure bash (no pipe, no external sort): avoids a Windows/git-bash pipe-in-command-substitution hang.
_sort_uniq_num() {
    local -A _seen=()
    local -a _u=()
    local p i j tmp
    for p in "$@"; do
        [[ -z ${_seen[$p]:-} ]] || continue
        _seen[$p]=1
        _u+=("$p")
    done
    for ((i = 0; i < ${#_u[@]}; i++)); do
        for ((j = i + 1; j < ${#_u[@]}; j++)); do
            if ((_u[j] < _u[i])); then
                tmp=${_u[i]}; _u[i]=${_u[j]}; _u[j]=$tmp
            fi
        done
    done
    ((${#_u[@]})) && printf '%s\n' "${_u[@]}"
}

# ssh_ports: one port per line on stdout (sorted unique), the reason on stderr.
# Order: MCCTL_SSH_PORTS (comma list) if set; else sshd -T lines "port N"; plus
# ss -H -ltnp lines whose process is sshd; plus the server port of $SSH_CONNECTION;
# if still nothing and something listens on 22, 22. Every port must be an integer 1..65535;
# a configured value that is not: exit 3 naming it.
ssh_ports() {
    local ports=() p
    if [[ -n ${MCCTL_SSH_PORTS:-} ]]; then
        local -a cfg
        IFS=, read -ra cfg <<<"$MCCTL_SSH_PORTS"
        for p in "${cfg[@]}"; do
            [[ -n $p ]] || continue
            if [[ ! $p =~ ^[0-9]+$ || $p -lt 1 || $p -gt 65535 ]]; then
                die "MCCTL_SSH_PORTS='$MCCTL_SSH_PORTS' has a port '$p' that is not an integer from 1 to 65535" "$EX_PREFLIGHT"
            fi
            ports+=("$p")
        done
        _sort_uniq_num "${ports[@]}"
        return 0
    fi
    if command -v sshd >/dev/null 2>&1; then
        local _sshd_out _line
        _sshd_out=$(sshd -T 2>/dev/null)
        while read -r _line; do
            [[ $_line == port\ * ]] && ports+=("${_line#port }")
        done <<<"$_sshd_out"
    fi
    local _ss_out _line _addr _n _rest
    _ss_out=$(ss -H -ltnp 2>/dev/null)
    while read -r _line; do
        [[ $_line == *'"sshd"'* ]] || continue
        read -r _ _ _ _addr _rest <<<"$_line"
        _n=${_addr##*:}
        [[ -n $_n ]] && ports+=("$_n")
    done <<<"$_ss_out"
    [[ -n ${SSH_CONNECTION:-} ]] && { read -r _ _ _ p <<<"$SSH_CONNECTION"; [[ -n $p ]] && ports+=("$p"); }
    if ((${#ports[@]} == 0)); then
        local _ss22
        _ss22=$(ss -H -ltn "( sport = :22 )" 2>/dev/null)
        [[ -n $_ss22 ]] && ports+=(22)
    fi
    _sort_uniq_num "${ports[@]}"
}

# firewall_rules: lines "rule<TAB>comment". ufw rules for host INPUT only.
# allow PORT/tcp for each SSH port; allow 25565/tcp; allow 2222/tcp only when MCCTL_SFTP_PUBLIC=1.
firewall_rules() {
    local p T=$'\t' _ports
    _ports=$(ssh_ports)
    while read -r p; do
        [[ -n $p ]] || continue
        printf 'allow %s/tcp%smcctl: ssh\n' "$p" "$T"
    done <<<"$_ports"
    printf 'allow %s/tcp%smcctl: minecraft router\n' "$ROUTER_PORT" "$T"
    [[ ${MCCTL_SFTP_PUBLIC:-0} == 1 ]] && printf 'allow 2222/tcp%smcctl: sftp\n' "$T"
}

# firewall_check_lockout: refuse when no SSH port can be detected, or when the current
# session's port is not in the detected list.
firewall_check_lockout() {
    local ports sp _ports_str
    _ports_str=$(ssh_ports)
    ports=${_ports_str//$'\n'/ }
    if [[ -z ${ports// } ]]; then
        err "cannot detect the SSH port. Set MCCTL_SSH_PORTS=22 (or your port) in config/mcctl.env or the environment; refusing to touch the firewall"
        return 1
    fi
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        read -r _ _ _ sp <<<"$SSH_CONNECTION"
        if [[ -n $sp && " $ports " != *" $sp "* ]]; then
            err "this SSH session uses port $sp, which is not in the detected list ($ports): add it to MCCTL_SSH_PORTS"
            return 1
        fi
    fi
    return 0
}

ufw_is_active() {
    local _s
    _s=$(ufw status 2>/dev/null)
    [[ $_s == *'Status: active'* ]] && return 0
    _s=$(iptables -S INPUT 2>/dev/null)
    [[ $_s == *'ufw-before-input'* ]]
}

ufw_allows_port() {
    local _s _re
    _s=$(iptables -S ufw-user-input 2>/dev/null)
    _re="-p tcp .*--dport $1( |$).*-j ACCEPT"
    [[ $_s =~ $_re ]] && return 0
    _s=$(ufw status 2>/dev/null)
    [[ $_s == *"$1/tcp"*ALLOW* ]]
}

# ingress_chain_active: 0 when MCCTL-INGRESS exists (the guard built it).
ingress_chain_active() {
    iptables -S MCCTL-INGRESS >/dev/null 2>&1
}

# firewall_listeners: one line per listening TCP socket whose local address is not loopback, "PORT<TAB>ADDRESS<TAB>PROCESS". PROCESS
# is the first name in ss's users:(("name",...) column, or - when ss shows none. Read-only; returns 1 when ss fails.
firewall_listeners() {
    local _out _line _rest _addr _host _port _proc
    local _re='users:\(\("([^"]*)"'
    _out=$(ss -H -ltnp 2>/dev/null) || return 1
    while read -r _line; do
        [[ -n $_line ]] || continue
        read -r _ _ _ _addr _rest <<<"$_line"
        _host=${_addr%:*}
        _port=${_addr##*:}
        case $_host in 127.*|'[::1]'|::1) continue ;; esac
        _proc=-
        [[ $_line =~ $_re ]] && _proc=${BASH_REMATCH[1]}
        printf '%s\t%s\t%s\n' "$_port" "$_host" "$_proc"
    done <<<"$_out"
    return 0
}

firewall_plan_text() {
    local _ports_str _rules _rule _comment _ls _allowed=" " _port _addr _proc _docker="" _blocked=""
    _ports_str=$(ssh_ports)
    echo "SSH ports kept open: ${_ports_str//$'\n'/ }"
    echo "Policy: default deny incoming, allow outgoing. Docker/forwarding policy is not touched."
    echo "Rules this tool adds (existing rules are left alone):"
    _rules=$(firewall_rules)
    while IFS=$'\t' read -r _rule _comment; do
        [[ -n $_rule ]] && printf '  ufw %s   # %s\n' "$_rule" "$_comment"
    done <<<"$_rules"
    echo "Ingress limits (on the router port $ROUTER_PORT, in the guard's MCCTL-INGRESS chain):"
    echo "  connections per source: ${MCCTL_CONN_LIMIT:-10}"
    echo "  new connections per source: ${MCCTL_RATE:-10/second}"
    if ingress_chain_active; then
        echo "  ingress chain: active"
    else
        echo "  ingress chain: not active: run mcctl up"
    fi
    # What the policy would do to the public listeners (read-only). A port in firewall_rules is allowed. A port published by Docker
    # (docker-proxy) is not filtered by ufw, so it is listed apart. Any other public listener would be blocked.
    if ! _ls=$(firewall_listeners); then
        echo "Public listeners: cannot list them (ss failed), so this plan does not know what would be blocked."
        return 0
    fi
    while IFS=$'\t' read -r _rule _comment; do
        [[ -n $_rule ]] && _allowed+="${_rule#allow } "
    done <<<"$_rules"
    while IFS=$'\t' read -r _port _addr _proc; do
        [[ -n $_port && $_allowed != *" $_port/tcp "* ]] || continue
        if [[ $_proc == docker-proxy ]]; then
            _docker+="    $_port  $_addr  $_proc"$'\n'
        else
            _blocked+="    $_port  $_addr  $_proc"$'\n'
        fi
    done <<<"$_ls"
    echo "Public listeners (not loopback), against this policy:"
    if [[ -n $_docker ]]; then
        echo "  published by Docker (ufw does not filter these; the egress guard and MCCTL-INGRESS do):"
        printf '%s' "$_docker"
    fi
    echo "  WILL BE BLOCKED by the default deny policy (not in the allow list):"
    if [[ -n $_blocked ]]; then
        printf '%s' "$_blocked"
        [[ $_blocked != *"  -"$'\n'* ]] || echo "  -: ss did not name the process (only root sees all of them), so a port published by Docker may be one of these. Run the plan as root to check."
        echo "  These services stop accepting connections from outside when this policy is applied. Before running"
        echo "  'mcctl firewall apply', add an allow rule for each one (ufw allow PORT/tcp), or accept the block."
        echo "  This list does not read existing ufw rules, so it still shows a port you allowed by hand."
    else
        echo "    none: no other public listener would be blocked"
    fi
}

cmd_firewall() {
    local sub=${1:-}; shift || true
    case $sub in
        plan)
            firewall_plan_text
            ;;
        apply)
            _need_root "firewall apply"
            command -v ufw >/dev/null 2>&1 || die "ufw is not installed. Install it first (Ubuntu/Debian: apt install ufw), then re-run" "$EX_PREFLIGHT"
            firewall_check_lockout || exit "$EX_REFUSED"
            firewall_plan_text
            local was_active=no ts bk rollback=${MCCTL_FIREWALL_ROLLBACK_SECONDS:-300}
            ufw_is_active && was_active=yes
            if [[ $was_active == no ]]; then
                if ((rollback > 0)) && ! command -v systemd-run >/dev/null 2>&1; then
                    die "ufw is inactive and the dead-man switch needs systemd-run, which this host does not have. Refusing to enable a firewall that could not switch itself off. Either run on a systemd host, or set MCCTL_FIREWALL_ROLLBACK_SECONDS=0 to accept no safety net" "$EX_PREFLIGHT"
                fi
                if ((rollback > 0)); then
                    echo "ufw is currently INACTIVE: it will be enabled, with a ${rollback}s dead-man switch (see below)."
                else
                    echo "ufw is currently INACTIVE: it will be enabled WITHOUT a dead-man switch (MCCTL_FIREWALL_ROLLBACK_SECONDS=0)."
                fi
            fi
            confirm "Apply these firewall rules on this host?" || die "cancelled; the firewall was not changed" "$EX_REFUSED"
            ts=$(date -u +%Y%m%dT%H%M%SZ)
            mkdir_private "$MCCTL_ROOT/backups" && bk="$MCCTL_ROOT/backups/firewall-before-$ts.txt" \
                && { { ufw status verbose; iptables -S; } >"$bk" 2>&1; chmod 600 "$bk"; } \
                && info "previous state saved: $bk"
            local rule comment _rules_str
            local -a args
            _rules_str=$(firewall_rules)
            while IFS=$'\t' read -r rule comment; do
                [[ -n $rule ]] || continue
                read -ra args <<<"$rule"
                ufw "${args[@]}" comment "$comment" >/dev/null || die "ufw rejected: ufw $rule (nothing is enabled yet)"
            done <<<"$_rules_str"
            ufw default deny incoming >/dev/null && ufw default allow outgoing >/dev/null || die "cannot set default policies"
            ufw --force enable >/dev/null 2>&1 || die "ufw could not be enabled"
            local p _ports_str
            _ports_str=$(ssh_ports)
            while read -r p; do
                ufw_allows_port "$p" || { ufw --force disable >/dev/null 2>&1; die "SSH port $p is not accepted by the active rule set: the firewall was switched OFF again. Nothing is locked out"; }
            done <<<"$_ports_str"
            if [[ $was_active == no ]] && ((rollback > 0)); then
                if ! systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${rollback}s" --description="mcctl firewall dead-man switch" \
                    "$(command -v ufw)" --force disable; then
                    ufw --force disable >/dev/null 2>&1
                    die "could not arm the dead-man switch, so the firewall was switched OFF again. Nothing is locked out"
                fi
                cat <<EOF

Firewall ENABLED. A dead-man switch will switch it OFF again in ${rollback}s unless you confirm.
Open a NEW ssh session to this server right now. If it works, confirm from it:

    mcctl firewall confirm

If you cannot log in, do nothing: the firewall disables itself.
EOF
            elif [[ $was_active == no ]]; then
                info "firewall ENABLED without a dead-man switch (MCCTL_FIREWALL_ROLLBACK_SECONDS=0). Test a NEW ssh session now"
            else
                info "firewall rules added; ufw was already active, so there is no dead-man switch to arm"
            fi
            ;;
        confirm)
            _need_root "firewall confirm"
            systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null
            info "dead-man switch cancelled: the firewall stays enabled"
            ;;
        rollback)
            _need_root "firewall rollback"
            ufw --force disable >/dev/null 2>&1
            systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null
            info "firewall disabled (rollback)"
            ;;
        *)
            die "usage: mcctl firewall {plan|apply|confirm|rollback}" "$EX_USAGE"
            ;;
    esac
}

#!/usr/bin/env bash
# shellcheck shell=bash
# Host firewall (ufw), game-network egress guard (iptables DOCKER-USER), and a listener audit. Sourced by ./ptero.
#
# Goals: nothing reachable from outside except what is meant to be (SSH, and the single Minecraft router port);
# game servers (which run arbitrary mod code) cannot reach the host, the LAN, or the cloud metadata service.
# Safety on a remote VPS: SSH is detected and allowed BEFORE the firewall is enabled, the current session's port and
# source address are checked, and a dead-man timer switches the firewall off again unless you confirm from a NEW session.

ROLLBACK_UNIT=ptero-firewall-rollback

# ssh_ports : one port per line, with the reason on stderr
ssh_ports() {
    local ports=() p
    if [[ -n ${FIREWALL_SSH_PORTS:-} ]]; then
        IFS=, read -ra ports <<<"$FIREWALL_SSH_PORTS"
        printf '%s\n' "${ports[@]}" | sort -un
        return 0
    fi
    if have sshd; then
        while read -r p; do [[ -n $p ]] && ports+=("$p"); done < <(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}')
    fi
    while read -r p; do [[ -n $p ]] && ports+=("$p"); done < <(${PTERO_SS:-ss} -H -ltnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}')
    [[ -n ${SSH_CONNECTION:-} ]] && { read -r _ _ _ p <<<"$SSH_CONNECTION"; [[ -n $p ]] && ports+=("$p"); }
    if ((${#ports[@]} == 0)) && [[ -n $(${PTERO_SS:-ss} -H -ltn "( sport = :22 )" 2>/dev/null) ]]; then ports+=(22); fi
    ((${#ports[@]})) && printf '%s\n' "${ports[@]}" | sort -un
}

client_ip() { [[ -n ${SSH_CONNECTION:-} ]] && awk '{print $1}' <<<"$SSH_CONNECTION"; }

cidr_contains() { # cidr_contains "a,b,c" IP
    python3 -c '
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[2])
sys.exit(0 if any(ip in ipaddress.ip_network(c.strip(), strict=False) for c in sys.argv[1].split(",") if c.strip()) else 1)' "$1" "$2" 2>/dev/null
}

valid_cidr_list() { # accepts IPs and networks, comma separated
    python3 -c '
import ipaddress, sys
for c in sys.argv[1].split(","):
    if c.strip():
        ipaddress.ip_network(c.strip(), strict=False)' "$1" 2>/dev/null
}

# firewall_rules : the ufw arguments this host should have, one rule per line: "<args>TAB<comment>"
firewall_rules() {
    local p c T=$'\t'
    local -a cs
    while read -r p; do
        [[ -n $p ]] || continue
        if [[ -n ${FIREWALL_SSH_ALLOW_CIDRS:-} ]]; then
            IFS=, read -ra cs <<<"$FIREWALL_SSH_ALLOW_CIDRS"
            for c in "${cs[@]}"; do printf 'allow from %s to any port %s proto tcp%sptero: ssh\n' "$c" "$p" "$T"; done
        elif [[ ${FIREWALL_SSH_LIMIT:-no} == yes ]]; then printf 'limit %s/tcp%sptero: ssh (rate limited)\n' "$p" "$T"
        else printf 'allow %s/tcp%sptero: ssh\n' "$p" "$T"; fi
    done < <(ssh_ports)
    if games_enabled; then
        if [[ -n ${FIREWALL_GAME_ALLOW_CIDRS:-} ]]; then
            IFS=, read -ra cs <<<"$FIREWALL_GAME_ALLOW_CIDRS"
            for c in "${cs[@]}"; do printf 'allow from %s to any port %s proto tcp%sptero: minecraft router\n' "$c" "$GAMES_PORT" "$T"; done
        else printf 'allow %s/tcp%sptero: minecraft router\n' "$GAMES_PORT" "$T"; fi
    fi
    if [[ ${WINGS_SFTP_BIND:-127.0.0.1} != 127.0.0.1 ]]; then printf 'allow 2022/tcp%sptero: wings sftp\n' "$T"; fi
}

firewall_check_lockout() {
    local ports ip
    ports=$(ssh_ports | tr '\n' ' ')
    if [[ -z ${ports// } ]]; then
        err "cannot detect the SSH port. Set FIREWALL_SSH_PORTS=22 (or your port) in config/deploy.env; refusing to touch the firewall"
        return 1
    fi
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        local sp; read -r _ _ _ sp <<<"$SSH_CONNECTION"
        if [[ " $ports " != *" $sp "* ]]; then err "this SSH session uses port $sp, which is not in the detected list ($ports): add it to FIREWALL_SSH_PORTS"; return 1; fi
        ip=$(client_ip)
        if [[ -n ${FIREWALL_SSH_ALLOW_CIDRS:-} ]] && ! cidr_contains "$FIREWALL_SSH_ALLOW_CIDRS" "$ip"; then
            err "FIREWALL_SSH_ALLOW_CIDRS does not include your current address $ip: applying it would cut this very session off"
            return 1
        fi
    fi
    return 0
}

ufw_is_active() { # ufw status can fail on some hosts; the live INPUT chain is the reliable signal
    ufw status 2>/dev/null | grep -q '^Status: active' && return 0
    iptables -S INPUT 2>/dev/null | grep -q 'ufw-before-input'
}

ufw_allows_port() { # ufw_allows_port PORT : the port is accepted in the live rule set (tcp)
    iptables -S ufw-user-input 2>/dev/null | grep -qE -- "-p tcp .*--dport $1( |\$).*-j ACCEPT" && return 0
    ufw status 2>/dev/null | grep -qE "^$1/tcp[[:space:]]+ALLOW"
}

firewall_plan_text() {
    local p
    echo "SSH ports kept open: $(ssh_ports | tr '\n' ' ')"
    echo "Policy: default deny incoming, allow outgoing. Docker/forwarding policy is not touched."
    echo "Rules this tool adds (existing rules are left alone):"
    firewall_rules | awk -F'\t' '{print "  ufw " $1 "   # " $2}'
    games_enabled || echo "  (games disabled: no game port will be opened)"
    echo "Everything else listens on 127.0.0.1 only (Panel, Wings API, SFTP by default, tunnel metrics)."
}

cmd_firewall() {
    local sub=${1:-}; shift || true
    case $sub in
        plan)
            load_config || exit $EX_PREFLIGHT
            validate_config || { report_verrors; exit $EX_PREFLIGHT; }
            firewall_plan_text
            ;;
        apply)
            need_root "firewall apply"
            prepare 0
            have ufw || die "ufw is not installed. Install it first (Ubuntu/Debian: apt install ufw), then re-run" $EX_PREFLIGHT
            firewall_check_lockout || exit $EX_REFUSED
            firewall_plan_text
            local was_active=no ts bk rollback=${FIREWALL_ROLLBACK_SECONDS:-300}
            ufw_is_active && was_active=yes
            if [[ $was_active == no ]]; then
                if ((rollback > 0)) && ! have systemd-run; then
                    die "ufw is inactive and the dead-man switch needs systemd-run, which this host does not have. Refusing to enable a firewall that could not switch itself off. Either run on a systemd host, or set FIREWALL_ROLLBACK_SECONDS=0 in config/deploy.env to accept no safety net" $EX_REFUSED
                fi
                if ((rollback > 0)); then
                    echo "ufw is currently INACTIVE: it will be enabled, with a ${rollback}s dead-man switch (see below)."
                else
                    echo "ufw is currently INACTIVE: it will be enabled WITHOUT a dead-man switch (FIREWALL_ROLLBACK_SECONDS=0)."
                fi
            fi
            confirm "Apply these firewall rules on this host?" || die "cancelled; the firewall was not changed" $EX_REFUSED
            ts=$(date -u +%Y%m%dT%H%M%SZ)
            mkdir_private "$PTERO_ROOT/backups" && bk="$PTERO_ROOT/backups/firewall-before-$ts.txt"                 && { { ufw status verbose; iptables -S; } >"$bk" 2>&1; chmod 600 "$bk"; } && info "previous state saved: $bk"
            local rule comment
            local -a args
            while IFS=$'	' read -r rule comment; do
                [[ -n $rule ]] || continue
                read -ra args <<<"$rule"
                ufw "${args[@]}" comment "$comment" >/dev/null || die "ufw rejected: ufw $rule (nothing is enabled yet)"
            done < <(firewall_rules)
            ufw default deny incoming >/dev/null && ufw default allow outgoing >/dev/null || die "cannot set default policies"
            ufw --force enable >/dev/null 2>&1 || die "ufw could not be enabled"
            # Verify, from the live rule set, that every SSH port is accepted. Otherwise undo at once.
            local p
            while read -r p; do
                ufw_allows_port "$p" || { ufw --force disable >/dev/null 2>&1; die "SSH port $p is not accepted by the active rule set: the firewall was switched OFF again. Nothing is locked out"; }
            done < <(ssh_ports)
            if [[ $was_active == no ]] && ((rollback > 0)); then
                if ! systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${rollback}s" --description="ptero firewall dead-man switch"                         "$(command -v ufw)" --force disable; then
                    ufw --force disable >/dev/null 2>&1
                    die "could not arm the dead-man switch, so the firewall was switched OFF again. Nothing is locked out"
                fi
                cat <<EOF

Firewall ENABLED. A dead-man switch will switch it OFF again in ${rollback}s unless you confirm.
Open a NEW ssh session to this server right now. If it works, confirm from it:

    sudo ./ptero firewall confirm

If you cannot log in, do nothing: the firewall disables itself.
EOF
            elif [[ $was_active == no ]]; then
                info "firewall ENABLED without a dead-man switch (FIREWALL_ROLLBACK_SECONDS=0). Test a NEW ssh session now"
            else
                info "firewall rules added; ufw was already active, so there is no dead-man switch to arm"
            fi
            ;;
        confirm)
            need_root "firewall confirm"
            systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" 2>/dev/null
            info "dead-man switch cancelled: the firewall stays enabled. Check: ./ptero audit"
            ;;
        status)
            have ufw && ufw status verbose 2>&1
            systemctl list-timers "$ROLLBACK_UNIT.timer" --no-pager 2>/dev/null | head -n 3
            ;;
        egress) cmd_egress "$@" ;;
        *) die "usage: ./ptero firewall {plan|apply|confirm|status|egress apply|status|install}" $EX_USAGE ;;
    esac
}

# ---- game-network egress guard -------------------------------------------------------------------
EGRESS_PRIVATE=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10)

egress_subnet() { # prefer the subnet Wings is really configured with
    local cfg s; cfg="$(wings_etc)/config.yml"
    if [[ -r $cfg ]]; then
        s=$(python3 "$PTERO_ROOT/lib/wings_config.py" get "$cfg" docker network interfaces v4 subnet 2>/dev/null)
        if [[ -n $s && $s != "${GAME_NET_SUBNET:-}" ]]; then warn "GAME_NET_SUBNET=${GAME_NET_SUBNET:-unset} differs from Wings' docker.network.interfaces.v4.subnet=$s; using $s" >&2; fi
        [[ -n $s ]] && { echo "$s"; return; }
    fi
    echo "$GAME_NET_SUBNET"
}

egress_apply() {
    local game="$1" quiet=${2:-0} d t=0
    have iptables || die "iptables not found (apt install iptables)" $EX_PREFLIGHT
    until iptables -S DOCKER-USER >/dev/null 2>&1; do
        t=$((t + 2)); ((t > 60)) && die "the DOCKER-USER chain does not exist: is Docker running?"
        sleep 2
    done
    # drops first (inserted at the top), then the conntrack RETURN above them so replies to inbound player traffic pass
    for d in "${EGRESS_PRIVATE[@]}"; do
        iptables -C DOCKER-USER -s "$game" -d "$d" -j DROP 2>/dev/null || iptables -I DOCKER-USER 1 -s "$game" -d "$d" -j DROP || return 1
    done
    iptables -C DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null \
        || iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN || return 1
    # containers must not open new connections to the host itself (SSH, anything bound to 0.0.0.0)
    iptables -C INPUT -s "$game" -m conntrack --ctstate NEW -j DROP 2>/dev/null || iptables -I INPUT 1 -s "$game" -m conntrack --ctstate NEW -j DROP || return 1
    ((quiet)) || info "egress guard active for $game: blocked to ${EGRESS_PRIVATE[*]} and to the host"
}

cmd_egress() {
    local sub=${1:-}; shift || true
    case $sub in
        apply)
            need_root "firewall egress apply"
            prepare 0
            egress_apply "$(egress_subnet)" "$([[ ${1:-} == --quiet ]] && echo 1 || echo 0)" || die "could not install the egress rules"
            ;;
        status)
            prepare 0
            local game; game=$(egress_subnet)
            local d ok=1
            for d in "${EGRESS_PRIVATE[@]}"; do
                iptables -C DOCKER-USER -s "$game" -d "$d" -j DROP 2>/dev/null && printf 'ok    DOCKER-USER drop %s -> %s\n' "$game" "$d" || { printf 'MISSING DOCKER-USER drop %s -> %s\n' "$game" "$d"; ok=0; }
            done
            iptables -C INPUT -s "$game" -m conntrack --ctstate NEW -j DROP 2>/dev/null && echo "ok    INPUT drop new connections from $game" || { echo "MISSING INPUT drop from $game"; ok=0; }
            ((ok))
            ;;
        install)
            need_root "firewall egress install"
            prepare 0
            local d=${PTERO_SYSTEMD_DIR:-/etc/systemd/system}
            sed "s#@PTERO_ROOT@#$PTERO_ROOT#g" "$PTERO_ROOT/systemd/ptero-egress-guard.service.tpl" >"$PTERO_TMP/g.service" \
                && install -m 0644 "$PTERO_TMP/g.service" "$d/ptero-egress-guard.service" || die "cannot install the unit"
            systemctl daemon-reload && systemctl enable --now ptero-egress-guard.service || die "cannot enable the unit"
            info "installed: the rules are re-applied at every boot, after Docker starts"
            ;;
        *) die "usage: ./ptero firewall egress {apply|status|install}" $EX_USAGE ;;
    esac
}

# ---- audit --------------------------------------------------------------------------------------
# Lists what listens beyond loopback and flags anything that is not on the expected list.
cmd_audit() {
    prepare 0
    local expected="" p addr port proto bad=0
    for p in $(ssh_ports); do expected+=" tcp:$p"; done
    games_enabled && expected+=" tcp:$GAMES_PORT"
    [[ $WINGS_SFTP_BIND != 127.0.0.1 ]] && expected+=" tcp:2022"
    printf 'Listeners reachable beyond loopback:\n'
    while read -r proto addr port; do
        [[ -n $port ]] || continue
        case $addr in 127.*|"[::1]"|::1) continue ;; esac
        if [[ " $expected " == *" $proto:$port "* ]]; then printf '  ok         %s %s:%s\n' "$proto" "$addr" "$port"
        elif [[ $proto == udp && $port =~ ^(68|123|5353|546)$ ]]; then printf '  info       %s %s:%s (usual system service: DHCP/NTP/mDNS)\n' "$proto" "$addr" "$port"
        else printf '  UNEXPECTED %s %s:%s\n' "$proto" "$addr" "$port"; bad=1; fi
    done < <(${PTERO_SS:-ss} -H -ltnu 2>/dev/null | awk '{ n = split($5, a, ":"); port = a[n]; addr = substr($5, 1, length($5) - length(port) - 1); proto = ($1 ~ /^udp/) ? "udp" : "tcp"; print proto, addr, port }')
    if have docker; then
        while read -r name ports; do
            [[ $ports =~ (0\.0\.0\.0|\[::\]):[0-9]+ ]] && { printf '  UNEXPECTED container %s publishes %s\n' "$name" "$ports"; bad=1; }
        done < <(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null)
    fi
    if have ufw && ! ufw status 2>/dev/null | grep -q '^Status: active'; then
        printf '  WARN       ufw is not active: ./ptero firewall plan\n'
    fi
    ((bad)) && { echo "Audit found unexpected exposure."; return 1; }
    echo "Audit clean: only expected ports are reachable."
}

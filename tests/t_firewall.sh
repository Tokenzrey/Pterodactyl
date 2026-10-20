#!/usr/bin/env bash
# host firewall (ufw) with lock-out protection, game egress guard, listener audit
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox; trap sandbox_cleanup EXIT
valid_config
games_config
ufwlog() { cat "$FAKE_STATE/ufw.log" 2>/dev/null; }

echo "plan (read-only)"
p firewall plan
assert_eq 0 "$RC" "plan succeeds"
assert_contains "$OUT" "allow 2222/tcp" "SSH port detected from sshd -T"
assert_contains "$OUT" "allow 25565/tcp" "the game router port is the only other rule"
assert_not_contains "$OUT" "25601" "backend (game server) ports are never opened"
assert_not_contains "$(ufwlog)" "enable" "plan does not enable anything"
sed -i 's/^GAMES_ENABLED=.*/GAMES_ENABLED=no/' "$R/config/deploy.env"
p firewall plan
assert_not_contains "$OUT" "allow 25565" "games disabled: no game port"
games_config

echo "apply: rules first, enable last, dead-man switch armed"
p firewall apply --yes
assert_eq 0 "$RC" "apply succeeds"
log=$(ufwlog)
ssh_line=$(grep -n 'allow 2222/tcp' <<<"$log" | head -n1 | cut -d: -f1)
enable_line=$(grep -n 'force enable' <<<"$log" | head -n1 | cut -d: -f1)
if [[ -n $ssh_line && -n $enable_line && $ssh_line -lt $enable_line ]]; then pass "SSH is allowed BEFORE ufw is enabled"; else fail "SSH is allowed BEFORE ufw is enabled" "$log"; fi
assert_contains "$log" "default deny incoming" "default deny incoming"
assert_contains "$log" "default allow outgoing" "default allow outgoing"
assert_not_contains "$log" "default deny routed" "the forwarding policy (Docker) is not touched"
assert_contains "$(calls)" "systemd-run --quiet --unit=ptero-firewall-rollback --on-active=300s" "dead-man switch armed (300s)"
assert_contains "$OUT" "NEW ssh session" "tells the operator to test from a new session"
ls "$R"/backups/firewall-before-*.txt >/dev/null 2>&1 && pass "previous firewall state saved" || fail "previous firewall state saved"
p firewall confirm
assert_contains "$(calls)" "stop ptero-firewall-rollback.timer" "confirm cancels the dead-man switch"
[[ -e $FAKE_STATE/rollback.armed ]] && fail "switch disarmed" || pass "switch disarmed"

echo "apply when ufw is already active: no dead-man switch, rules are only added"
: >"$FAKE_STATE/calls.log"
p firewall apply --yes
assert_eq 0 "$RC" "second apply succeeds (idempotent)"
assert_not_contains "$(calls)" "systemd-run" "no dead-man switch when ufw was already on"

echo "lock-out protection"
rm -f "$FAKE_STATE/ufw.active" "$FAKE_STATE/ufw.rules"; : >"$FAKE_STATE/ufw.log"
FAKE_SSHD_NONE=1 p firewall apply --yes
assert_eq 4 "$RC" "no SSH port detectable: refused"
assert_contains "$OUT" "FIREWALL_SSH_PORTS" "tells how to set it"
assert_not_contains "$(ufwlog)" "enable" "ufw was not enabled"
SSH_CONNECTION="198.51.100.9 50000 10.0.0.2 2200" FAKE_SSHD_NONE=1 p firewall apply --yes
assert_eq 0 "$RC" "the port of the current SSH session is detected and kept open"
assert_contains "$(ufwlog)" "allow 2200/tcp" "allow rule for the session's port"
rm -f "$FAKE_STATE/ufw.active" "$FAKE_STATE/ufw.rules"; : >"$FAKE_STATE/ufw.log"
sed -i 's/^FIREWALL_SSH_PORTS=.*/FIREWALL_SSH_PORTS=22/' "$R/config/deploy.env"
SSH_CONNECTION="198.51.100.9 50000 10.0.0.2 2200" p firewall apply --yes
assert_eq 4 "$RC" "override that excludes the session's own port is refused"
assert_contains "$OUT" "this SSH session uses port 2200" "says why"
sed -i 's/^FIREWALL_SSH_PORTS=.*/FIREWALL_SSH_PORTS=/' "$R/config/deploy.env"
sed -i 's#^FIREWALL_SSH_ALLOW_CIDRS=.*#FIREWALL_SSH_ALLOW_CIDRS=203.0.113.0/24#' "$R/config/deploy.env"
SSH_CONNECTION="198.51.100.9 50000 10.0.0.2 2222" p firewall apply --yes
assert_eq 4 "$RC" "an allow-list that excludes your own address is refused"
assert_contains "$OUT" "cut this very session off" "says why"
assert_not_contains "$(ufwlog)" "enable" "ufw stayed off"
SSH_CONNECTION="203.0.113.9 50000 10.0.0.2 2222" p firewall apply --yes
assert_eq 0 "$RC" "an allow-list that includes you is accepted"
assert_contains "$(ufwlog)" "allow from 203.0.113.0/24 to any port 2222 proto tcp comment ptero: ssh" "SSH restricted to the list"
sed -i 's#^FIREWALL_SSH_ALLOW_CIDRS=.*#FIREWALL_SSH_ALLOW_CIDRS=#' "$R/config/deploy.env"

echo "failures leave the host reachable"
rm -f "$FAKE_STATE/ufw.active" "$FAKE_STATE/ufw.rules"; : >"$FAKE_STATE/ufw.log"
FAKE_UFW_FAIL=1 p firewall apply --yes
assert_eq 1 "$RC" "ufw rejecting a rule aborts"
assert_not_contains "$(ufwlog)" "force enable" "ufw was never enabled"
: >"$FAKE_STATE/ufw.log"
FAKE_UFW_DROP_RULES=1 p firewall apply --yes
assert_eq 1 "$RC" "SSH missing from the active rule set: aborts"
assert_contains "$OUT" "switched OFF again" "and says it undid itself"
assert_contains "$(ufwlog)" "force disable" "ufw was disabled again immediately"
p firewall apply
assert_eq 4 "$RC" "without a terminal and without --yes: refused"

echo "validation of firewall settings"
for bad in 'FIREWALL_SSH_ALLOW_CIDRS=not-an-ip' 'FIREWALL_SSH_PORTS=22;reboot' 'FIREWALL_ROLLBACK_SECONDS=5' 'FIREWALL_SSH_LIMIT=maybe' 'FIREWALL_GAME_ALLOW_CIDRS=999.1.1.1'; do
    key=${bad%%=*}
    cp "$R/config/deploy.env" "$SB/env.bak"
    sed -i "s#^$key=.*#$bad#" "$R/config/deploy.env"
    p status
    assert_eq 3 "$RC" "$bad rejected"
    cp "$SB/env.bak" "$R/config/deploy.env"
done

echo "egress guard"
: >"$FAKE_STATE/ipt.rules"
p firewall egress apply
assert_eq 0 "$RC" "egress apply succeeds"
rules=$(cat "$FAKE_STATE/ipt.rules")
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
    assert_contains "$rules" "DOCKER-USER -s 172.18.0.0/16 -d $net -j DROP" "game network -> $net dropped"
done
assert_contains "$rules" "DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN" "replies to inbound player traffic still pass"
assert_contains "$rules" "INPUT -s 172.18.0.0/16 -m conntrack --ctstate NEW -j DROP" "containers cannot open new connections to the host"
n1=$(wc -l <"$FAKE_STATE/ipt.rules")
p firewall egress apply
assert_eq "$n1" "$(wc -l <"$FAKE_STATE/ipt.rules")" "second apply adds nothing (idempotent)"
p firewall egress status
assert_eq 0 "$RC" "egress status ok"
: >"$FAKE_STATE/ipt.rules"
p firewall egress status
assert_eq 1 "$RC" "egress status fails when rules are missing"
assert_contains "$OUT" "MISSING" "and says which"
mkdir -p "$PTERO_WINGS_ETC"; cp "$REPO/tests/fixtures/wings-config.yml" "$PTERO_WINGS_ETC/config.yml"
sed -i 's#^GAME_NET_SUBNET=.*#GAME_NET_SUBNET=172.30.0.0/16#' "$R/config/deploy.env"
p firewall egress apply
assert_contains "$OUT" "differs from Wings" "a subnet that differs from Wings' real one is reported"
assert_contains "$(cat "$FAKE_STATE/ipt.rules")" "-s 172.18.0.0/16 -d 10.0.0.0/8" "and Wings' value wins"
p firewall egress install
assert_eq 0 "$RC" "egress install succeeds"
assert_contains "$(cat "$PTERO_SYSTEMD_DIR/ptero-egress-guard.service")" "ExecStart=$R/ptero firewall egress apply --quiet" "unit re-applies the rules at boot"
rm -f "$FAKE_STATE/ipt.chain"
sed -i 's#^GAME_NET_SUBNET=.*#GAME_NET_SUBNET=172.18.0.0/16#' "$R/config/deploy.env"

echo "audit"
export PTERO_SS=$REPO/tests/fakebin/fakess
printf '%s\n' 'tcp   LISTEN 0 128  0.0.0.0:2222  0.0.0.0:*' 'tcp   LISTEN 0 128  [::]:2222  [::]:*' 'tcp   LISTEN 0 4096 0.0.0.0:25565 0.0.0.0:*' \
    'tcp   LISTEN 0 4096 127.0.0.1:8081 0.0.0.0:*' 'tcp   LISTEN 0 4096 [::1]:443 [::]:*' 'udp   UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:*' \
    'udp   UNCONN 0 0 0.0.0.0:68 0.0.0.0:*' >"$FAKE_STATE/ss-all.txt"
p audit
assert_eq 0 "$RC" "only SSH and the game router are exposed: audit clean"
assert_contains "$OUT" "ok         tcp 0.0.0.0:25565" "game router listed as expected"
assert_not_contains "$OUT" "8081" "loopback listeners are not reported"
printf '%s\n' 'tcp   LISTEN 0 4096 0.0.0.0:3306 0.0.0.0:*' >>"$FAKE_STATE/ss-all.txt"
p audit
assert_eq 1 "$RC" "an unexpected public listener fails the audit"
assert_contains "$OUT" "UNEXPECTED tcp 0.0.0.0:3306" "and names it"
sed -i '/3306/d' "$FAKE_STATE/ss-all.txt"
FAKE_DOCKER_PS=$'pterodactyl-panel-1 127.0.0.1:8081->80/tcp\nsneaky 0.0.0.0:9000->9000/tcp' p audit
assert_eq 1 "$RC" "a container publishing on 0.0.0.0 fails the audit"
assert_contains "$OUT" "container sneaky publishes" "and names it"

finish

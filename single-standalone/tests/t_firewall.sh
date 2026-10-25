#!/usr/bin/env bash
# lib/firewall.sh: cmd_firewall plan|apply|confirm|rollback, ssh_ports, firewall_rules,
# firewall_check_lockout. E1: the ordered call log. E3: cmd_firewall is named here, no sudo.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/router.sh"
source "$REPO/lib/firewall.sh"
sandbox
load_config 2>/dev/null

reset() {
    : >"$FAKE_STATE/calls.log"; T_UNK=0
    rm -f "$FAKE_STATE"/ufw.* "$FAKE_STATE"/sshd.* "$FAKE_STATE"/ss.* "$FAKE_STATE"/rollback.*
    rm -rf "$FAKE_STATE/systemd"; mkdir -p "$FAKE_STATE/systemd"
    unset FAKE_UID MCCTL_SSH_PORTS MCCTL_SFTP_PUBLIC MCCTL_FIREWALL_ROLLBACK_SECONDS SSH_CONNECTION
}
line_of() { grep -nF -- "$1" "$FAKE_STATE/calls.log" 2>/dev/null | head -n 1 | cut -d: -f1; }
# path_without NAME...: the current PATH minus every directory that holds an executable NAME ([[ -x ]], not command -v).
# fakebin stays first: it is kept unless it still holds a NAME, and a case removes the fake before it calls this.
path_without() {
    local dir name hide out=""
    local -a dirs
    IFS=: read -ra dirs <<<"$PATH"
    for dir in "${dirs[@]}"; do
        hide=0
        for name in "$@"; do [[ -x $dir/$name ]] && hide=1; done
        ((hide)) || out+=${out:+:}$dir
    done
    printf '%s' "$out"
}

echo "plan: no root, no mutating calls, lists ports and limits"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=1000
m firewall plan
assert_eq 0 "$RC" "plan works as non-root (FAKE_UID=1000)"
assert_eq 0 "$(count_calls 'ufw allow')" "plan makes no ufw allow call"
assert_eq 0 "$(count_calls 'ufw --force enable')" "plan makes no ufw enable call"
assert_eq 0 "$(count_calls 'ufw --force disable')" "plan makes no ufw disable call"
assert_eq 0 "$(count_calls 'ufw default')" "plan makes no ufw default call"
assert_eq 0 "$(count_calls 'systemd-run')" "plan makes no systemd-run call"
assert_contains "$OUT" "22" "plan lists the SSH port 22"
assert_contains "$OUT" "25565" "plan lists the router port 25565"
assert_contains "$OUT" "connections per source: 10" "plan lists the default conn limit"
assert_contains "$OUT" "new connections per source: 10/second" "plan lists the default rate"
assert_contains "$OUT" "not active" "plan says the ingress chain is not active"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
iptables -w 5 -N MCCTL-INGRESS
m firewall plan
assert_contains "$OUT" "ingress chain: active" "plan says active when MCCTL-INGRESS exists"
reset

echo "apply: non-root refused, ufw missing refused"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=1000
m --yes firewall apply
assert_eq 4 "$RC" "apply as non-root: EX_REFUSED"
assert_eq 0 "$(count_calls 'ufw')" "no ufw call when refused for non-root"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0
rm -f "$SB/fakebin/ufw"
PATH=$(path_without ufw) m --yes firewall apply
assert_eq 3 "$RC" "apply without ufw on PATH: EX_PREFLIGHT"
cp "$REPO/tests/fakebin/ufw" "$SB/fakebin/ufw"; chmod +x "$SB/fakebin/ufw"
reset

echo "apply: no SSH port detectable -> refused"
reset
export FAKE_UID=0
m --yes firewall apply
assert_eq 4 "$RC" "no SSH port: EX_REFUSED"
assert_eq 0 "$(count_calls 'ufw allow')" "no mutating ufw call"
assert_eq 0 "$(count_calls 'ufw --force enable')" "no enable call"
reset

echo "apply: lockout check (session port not in list)"
reset
export FAKE_UID=0
export MCCTL_SSH_PORTS=22 SSH_CONNECTION="198.51.100.7 5555 192.0.2.1 2222"
m --yes firewall apply
assert_eq 4 "$RC" "lockout: EX_REFUSED"
assert_contains "$OUT" "2222" "the message names port 2222"
assert_eq 0 "$(count_calls 'ufw allow')" "no mutating ufw call"
reset

echo "apply: order in calls (SSH allows before enable, defaults before enable)"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0
m --yes firewall apply
assert_eq 0 "$RC" "apply succeeds"
enable_line=$(line_of "ufw --force enable")
allow_line=$(line_of "ufw allow 22/tcp")
default_deny_line=$(line_of "ufw default deny incoming")
default_allow_line=$(line_of "ufw default allow outgoing")
[[ -n $enable_line && -n $allow_line ]] && pass "enable and allow calls are in the log" || fail "enable and allow calls are in the log" "enable=$enable_line allow=$allow_line"
((allow_line < enable_line)) && pass "ufw allow for SSH comes before ufw --force enable" || fail "ufw allow for SSH comes before ufw --force enable" "allow=$allow_line enable=$enable_line"
[[ -n $default_deny_line && -n $default_allow_line ]] && pass "both default calls are in the log" || fail "both default calls are in the log" "deny=$default_deny_line allow=$default_allow_line"
((default_deny_line < enable_line)) && pass "ufw default deny incoming comes before enable" || fail "ufw default deny incoming comes before enable" "deny=$default_deny_line enable=$enable_line"
((default_allow_line < enable_line)) && pass "ufw default allow outgoing comes before enable" || fail "ufw default allow outgoing comes before enable" "allow=$default_allow_line enable=$enable_line"
reset

echo "apply: SSH not accepted after enabling -> disable and exit 1"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0
touch "$FAKE_STATE/ufw.hide-rules"
m --yes firewall apply
assert_eq 1 "$RC" "SSH not accepted: EX_FAIL"
assert_eq 1 "$(count_calls 'ufw --force disable')" "ufw --force disable is called"
reset

echo "apply: timer (dead-man switch)"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0
m --yes firewall apply
assert_eq 0 "$RC" "apply with timer: succeeds"
assert_eq 1 "$(count_calls 'systemd-run')" "one systemd-run call"
assert_contains "$(calls)" "--on-active=300s" "with --on-active=300s"
assert_contains "$(calls)" "ufw --force disable" "the timer runs ufw --force disable"
assert_file "$FAKE_STATE/rollback.armed" "rollback.armed was touched"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0
rm -f "$SB/fakebin/systemd-run"
# Hide systemd-run without dropping its directory: /usr/bin also holds bash and env, which mcctl needs. hidebin is a link farm of
# every executable on the current PATH except systemd-run and the fakebin dir (fakebin stays first). First hit wins per name.
hidebin=$SB/hidebin; rm -rf "$hidebin"; mkdir -p "$hidebin"
# Collect the sources in bash (no fork per file), then make every link with ONE ln -s: a fork per file is slow on WSL.
declare -A seen=()
srcs=()
IFS=: read -ra pdirs <<<"$PATH"
for d in "${pdirs[@]}"; do
    # /mnt/* is skipped on purpose: Windows interop directories hold thousands of entries, and each stat there costs milliseconds on WSL
    [[ -d $d && $d != "$SB/fakebin" && $d != /mnt/* ]] || continue
    for f in "$d"/*; do
        n=${f##*/}
        # name checks before [[ -x ]]: a stat is paid only for names not yet seen
        [[ $n != systemd-run && -z ${seen[$n]+x} && -x $f ]] || continue
        seen[$n]=1
        srcs+=("$f")
    done
done
if ((${#srcs[@]})); then
    ln -s -- "${srcs[@]}" "$hidebin/" || fail "hidebin: the single ln -s for the PATH executables failed"
fi
hide_path="$SB/fakebin:$hidebin"
if ( PATH=$hide_path; hash -r; [[ -z $(command -v systemd-run) ]] ); then
    pass "systemd-run is not found on the hidden PATH"
    ( PATH=$hide_path; hash -r; [[ -n $(command -v bash) ]] ) && pass "bash is still found on the hidden PATH" || fail "bash is still found on the hidden PATH"
    PATH=$hide_path m --yes firewall apply
else
    fail "systemd-run is not found on the hidden PATH" "command -v still finds it: mcctl is not run, so no real systemd-run is called"
    RC=-1
fi
assert_eq 3 "$RC" "no systemd-run and timer wanted: EX_PREFLIGHT"
assert_eq 0 "$(count_calls 'ufw allow')" "no ufw allow call"
assert_eq 0 "$(count_calls 'ufw --force enable')" "no ufw enable call"
cp "$REPO/tests/fakebin/systemd-run" "$SB/fakebin/systemd-run"; chmod +x "$SB/fakebin/systemd-run"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0 MCCTL_FIREWALL_ROLLBACK_SECONDS=0
m --yes firewall apply
assert_eq 0 "$RC" "ROLLBACK_SECONDS=0: succeeds"
assert_eq 0 "$(count_calls 'systemd-run')" "no systemd-run call"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0
touch "$FAKE_STATE/ufw.active"
m --yes firewall apply
assert_eq 0 "$RC" "ufw already active: succeeds"
assert_eq 0 "$(count_calls 'systemd-run')" "no timer when ufw was already active"
reset

echo "confirm and rollback"
reset
export FAKE_UID=0
m firewall confirm
assert_eq 0 "$RC" "confirm as root: succeeds"
assert_eq 1 "$(count_calls 'systemctl stop')" "confirm calls systemctl stop"
assert_contains "$(calls)" "mcctl-firewall-rollback.timer" "confirm stops the timer"
assert_contains "$(calls)" "mcctl-firewall-rollback.service" "confirm stops the service"
reset
export FAKE_UID=0
m firewall rollback
assert_eq 0 "$RC" "rollback as root: succeeds"
assert_eq 1 "$(count_calls 'ufw --force disable')" "rollback calls ufw --force disable"
assert_eq 1 "$(count_calls 'systemctl stop')" "rollback calls systemctl stop"
reset
export FAKE_UID=1000
m firewall confirm
assert_eq 4 "$RC" "confirm as non-root: EX_REFUSED"
reset
export FAKE_UID=1000
m firewall rollback
assert_eq 4 "$RC" "rollback as non-root: EX_REFUSED"
reset

echo "SFTP: 2222 rule only with MCCTL_SFTP_PUBLIC=1"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0
m --yes firewall apply
assert_eq 0 "$(count_calls 'ufw allow 2222')" "without MCCTL_SFTP_PUBLIC: no 2222 rule"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0 MCCTL_SFTP_PUBLIC=1
m --yes firewall apply
assert_eq 1 "$(count_calls 'ufw allow 2222')" "with MCCTL_SFTP_PUBLIC=1: one 2222 rule"
reset

echo "saved state file (mode 600, dir 700)"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0
m --yes firewall apply
bk=$(ls "$SB"/backups/firewall-before-*.txt 2>/dev/null | head -n 1)
[[ -n $bk ]] && pass "a backup file was created" || fail "a backup file was created"
assert_mode "$bk" 600 "the backup file is mode 600"
assert_mode "$SB/backups" 700 "the backups directory is mode 700"
reset

echo "ssh_ports: detection order and validation"
reset
export MCCTL_SSH_PORTS=2222,22
out=$(ssh_ports); assert_eq "22
2222" "$out" "configured list (sorted unique)"
reset
export MCCTL_SSH_PORTS=22
echo 2222 >"$FAKE_STATE/sshd.ports"
out=$(ssh_ports); assert_eq "22" "$out" "configured list wins over sshd"
reset
echo 2222 >"$FAKE_STATE/sshd.ports"
out=$(ssh_ports); assert_eq "2222" "$out" "sshd -T detected"
reset
printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n' >"$FAKE_STATE/ss.listen"
out=$(ssh_ports); assert_eq "22" "$out" "ss with sshd process"
reset
export SSH_CONNECTION="198.51.100.7 5555 192.0.2.1 23"
out=$(ssh_ports); assert_eq "23" "$out" "SSH_CONNECTION port detected"
reset
printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("xinetd",pid=1,fd=3))\n' >"$FAKE_STATE/ss.listen"
out=$(ssh_ports); assert_eq "22" "$out" "22 fallback when something listens on 22"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
echo 22 >"$FAKE_STATE/sshd.ports"
printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n' >"$FAKE_STATE/ss.listen"
export SSH_CONNECTION="198.51.100.7 5555 192.0.2.1 22"
out=$(ssh_ports); assert_eq "22" "$out" "sorted unique (all sources give 22)"
reset
for v in 0 70000 abc '22;x'; do
    ( MCCTL_SSH_PORTS=$v ssh_ports ) >/dev/null 2>&1
    assert_eq 3 $? "MCCTL_SSH_PORTS='$v' refused with exit 3"
done
reset

echo "plan: the public listeners the policy would block (ss fake: mixed listeners)"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
MIXED='LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 4096 0.0.0.0:25565 0.0.0.0:* users:(("docker-proxy",pid=811,fd=4))
LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:* users:(("java",pid=900,fd=12))
LISTEN 0 4096 127.0.0.1:3306 0.0.0.0:* users:(("mysqld",pid=901,fd=20))
LISTEN 0 4096 [::1]:5432 [::]:* users:(("postgres",pid=902,fd=5))
LISTEN 0 4096 0.0.0.0:25566 0.0.0.0:* users:(("docker-proxy",pid=903,fd=4))
LISTEN 0 4096 [::]:443 [::]:* users:(("nginx",pid=904,fd=6))
LISTEN 0 4096 0.0.0.0:9000 0.0.0.0:*'
printf '%s\n' "$MIXED" >"$FAKE_STATE/ss.listen"
m firewall plan
assert_eq 0 "$RC" "plan with listeners: exit 0"
assert_eq 0 "$(count_calls 'ufw')" "7. plan with listeners makes no ufw call at all"
docker_part=${OUT%%WILL BE BLOCKED*}
blocked=${OUT#*WILL BE BLOCKED}
assert_contains "$docker_part" "published by Docker (ufw does not filter these; the egress guard and MCCTL-INGRESS do)" "the Docker heading comes before the blocked list"
assert_contains "$blocked" "8080  0.0.0.0  java" "1. java on 0.0.0.0:8080 is under WILL BE BLOCKED"
assert_contains "$blocked" "9000  0.0.0.0  -" "a listener with no process name shows -"
assert_contains "$OUT" "only root sees all of them" "and the plan says that a - may hide a Docker port, and to run it as root"
assert_not_contains "$OUT" "3306" "2. 127.0.0.1:3306 is not listed"
assert_not_contains "$OUT" "5432" "2. [::1]:5432 is not listed"
assert_eq 0 "$(grep -cE '^ +(22|25565) ' <<<"$OUT")" "3. the SSH port 22 and the router port 25565 are not listed"
assert_contains "$docker_part" "25566  0.0.0.0  docker-proxy" "4. 0.0.0.0:25566 (docker-proxy) is under the Docker heading"
assert_not_contains "$blocked" "25566" "4. and not under WILL BE BLOCKED"
assert_contains "$blocked" "443  [::]  nginx" "5. [::]:443 is under WILL BE BLOCKED, with address [::]"
assert_contains "$OUT" "stop accepting connections from outside when this policy is applied" "the plan says the blocked services stop accepting connections"
assert_contains "$OUT" "add an allow rule for each one" "and says to add an allow rule first (or accept the block)"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
printf '%s\n' 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' \
    'LISTEN 0 4096 0.0.0.0:25565 0.0.0.0:* users:(("docker-proxy",pid=811,fd=4))' \
    'LISTEN 0 4096 127.0.0.1:3306 0.0.0.0:* users:(("mysqld",pid=901,fd=20))' >"$FAKE_STATE/ss.listen"
m firewall plan
assert_contains "$OUT" "none: no other public listener would be blocked" "6. with no other public listener, the plan says so"
assert_not_contains "$OUT" "only root sees all of them" "and the root note is not printed when nothing is blocked"
assert_not_contains "$OUT" "published by Docker" "and shows no Docker heading when no Docker port is public"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
echo 1 >"$FAKE_STATE/ss.rc"
m firewall plan
assert_eq 0 "$RC" "ss fails: the plan still exits 0"
assert_contains "$OUT" "cannot list them (ss failed)" "ss fails: the plan says it could not list the listeners"
assert_not_contains "$OUT" "none: no other public listener" "and does not claim that none would be blocked"
reset
echo 22 >"$FAKE_STATE/sshd.ports"
printf '%s\n' "$MIXED" >"$FAKE_STATE/ss.listen"
export FAKE_UID=0
m firewall plan
plan_blocked=${OUT#*WILL BE BLOCKED}
m firewall apply
assert_eq 4 "$RC" "8. apply, no terminal and no --yes: the confirm is declined, EX_REFUSED"
assert_contains "$OUT" "$plan_blocked" "8. apply prints the same blocked list before its confirm"
assert_eq 0 "$(calls | grep '^ufw' | grep -vc '^ufw status$')" "8. apply declined: the only ufw call is the read-only status"
assert_eq 0 "$(count_calls 'systemd-run')" "8. apply declined: no dead-man timer armed"
reset

echo "E3: cmd_firewall is named, no sudo in firewall.sh"
grep -q 'cmd_firewall' "$0" && pass "cmd_firewall is named in t_firewall.sh" || fail "cmd_firewall is named in t_firewall.sh"
grep -qw sudo "$REPO/lib/firewall.sh" && fail "no sudo in lib/firewall.sh" || pass "no sudo in lib/firewall.sh"
grep -qw eval "$REPO/lib/firewall.sh" && fail "no eval in lib/firewall.sh" || pass "no eval in lib/firewall.sh"

echo "usage"
reset
( cmd_firewall badsub ) >/dev/null 2>&1; assert_eq 2 $? "unknown subcommand: EX_USAGE"
( cmd_firewall ) >/dev/null 2>&1; assert_eq 2 $? "no subcommand: EX_USAGE"

sandbox_cleanup
finish

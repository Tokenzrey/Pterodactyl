#!/usr/bin/env bash
# lib/router.sh and templates/stack.compose.yml: router_port_free, cmd_up, cmd_down, router_reload, and the egress guard.
# Review Focus 4: port 25565 already taken -> router_port_free names the listener and cmd_up refuses (EX_PREFLIGHT), creating nothing.
# E1: the ordered call log of every command. The guard's shell script and its healthcheck are taken out of the template and RUN
# against the fake iptables (tests/fakebin/iptables keeps the rules in order, like the kernel), then a small first-match evaluator
# reads the resulting chains. What this proves is the rules AS WRITTEN and the ORDER they are in; it does not prove that a packet
# is dropped or passed on a real host. That needs real Docker (Spike S1, owed to the acceptance run).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/router.sh"
sandbox
load_config 2>/dev/null

STACK=$REPO/templates/stack.compose.yml
SBSTACK=$SB/templates/stack.compose.yml   # the copy `m` runs against
SFTPUP="docker compose -p mcctl-sftp -f $SB/sftp.compose.yml up -d"       # up and down start and stop the SFTP stack after / before the router
SFTPDOWN="docker compose -p mcctl-sftp -f $SB/sftp.compose.yml down"
reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; rm -f "$FAKE_STATE"/ss.* "$FAKE_STATE"/docker.network.* "$FAKE_STATE"/docker.compose.*; }
reset_ipt() { rm -f "$FAKE_STATE"/iptables.*; : >"$FAKE_STATE/calls.log"; T_UNK=0; }
DP='LISTEN 0 4096 0.0.0.0:25565 0.0.0.0:* users:(("docker-proxy",pid=811,fd=4))'
SSCALL='ss -H -ltnp ( sport = :25565 )'

echo "the config reaches compose"
[[ $(declare -p MCCTL_ROUTER_IP) == "declare -x "* && $(declare -p MCCTL_GAME_SUBNET) == "declare -x "* ]] \
    && pass "MCCTL_GAME_SUBNET and MCCTL_ROUTER_IP are exported (the stack file reads them)" || fail "MCCTL_GAME_SUBNET and MCCTL_ROUTER_IP are exported"

echo "router_port_free"
reset
out=$(router_port_free); rc=$?
assert_eq 0 "$rc" "nothing listens: 0"
assert_eq "" "$out" "and nothing is printed"
assert_eq "$SSCALL" "$(calls)" "it asks ss -H -ltnp for the listeners on 25565, once"
printf '%s\n' 'LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:* users:(("nginx",pid=5,fd=6))' >"$FAKE_STATE/ss.listen"
router_port_free >/dev/null; assert_eq 0 $? "a listener on another port does not count: 0"
printf '%s\n' "$DP" >"$FAKE_STATE/ss.listen"
out=$(router_port_free); rc=$?
assert_eq 1 "$rc" "a listener on 25565: 1"
assert_contains "$out" 'docker-proxy' "and its process is named"
assert_contains "$out" '0.0.0.0:25565' "and so is the address"
printf '%s\n' 'LISTEN 0 4096 [::]:25565 [::]:* users:(("mc-router",pid=7,fd=3))' >"$FAKE_STATE/ss.listen"
out=$(router_port_free); assert_eq 1 $? "an IPv6 listener on 25565: 1"
assert_contains "$out" 'mc-router' "the process is named"
printf '%s\n' 'LISTEN 0 511 127.0.0.1:25565 0.0.0.0:*' >"$FAKE_STATE/ss.listen"
out=$(router_port_free); assert_eq 1 $? "a listener of another user (ss shows no process): 1"
assert_contains "$out" '127.0.0.1:25565' "the line is printed anyway"
printf 'LISTEN 0 4096 0.0.0.0:25565 0.0.0.0:* users:(("evil\033[31mred",pid=9,fd=4))\n' >"$FAKE_STATE/ss.listen"
out=$(router_port_free)
[[ $out != *$'\033'* ]] && pass "a control character in a process name is not printed" || fail "a control character in a process name is not printed"
assert_contains "$out" 'evil' "the rest of the line is"
echo 1 >"$FAKE_STATE/ss.rc"
router_port_free >/dev/null 2>&1; assert_eq 2 $? "ss fails: 2 (cannot tell), not 0 (free)"
rm -f "$FAKE_STATE/ss.rc"
mkdir -p "$SB/emptybin"
( PATH=$SB/emptybin; router_port_free ) >/dev/null 2>&1; assert_eq 2 $? "no ss command: 2"
out=$( ( PATH=$SB/emptybin; router_port_free ) 2>&1 ); assert_contains "$out" "install iproute2" "and it says what to install"

echo "the stack template"
no_comments() { grep -v '^[[:space:]]*#' "$STACK"; }
socks=$(no_comments | grep 'docker\.sock')
assert_eq 1 "$(grep -c . <<<"$socks")" "docker.sock is mounted once"
[[ $socks == *'/var/run/docker.sock:/var/run/docker.sock:ro' ]] && pass "and read-only (:ro)" || fail "docker.sock is mounted :ro" "$socks"
assert_eq '      - "${MCCTL_ROUTER_BIND:?run through mcctl}:25565:25565"' "$(no_comments | awk '/^[[:space:]]*ports:/ {p=1; next} p && /^[[:space:]]*-/ {print; next} {p=0}')" "exactly one published port, 25565:25565"
assert_eq 1 "$(no_comments | grep -c '^[[:space:]]*ports:')" "(one ports: key in the whole file)"
svc() { awk -v s="$1" '$0 == "  " s ":" { f = 1; next } f && /^[^ ]/ { exit } f && /^  [a-z]/ { exit } f' "$STACK"; }
assert_eq "mc-router,egress-guard" "$(sed -n '/^services:/,/^networks:/p' "$STACK" | grep -E '^  [a-z]' | tr -d ':' | tr -d ' ' | paste -sd, -)" "the services are mc-router and egress-guard"
R_=$(svc mc-router) G_=$(svc egress-guard)
assert_contains "$R_" "image: itzg/mc-router" "mc-router runs itzg/mc-router"
assert_contains "$R_" 'IN_DOCKER: "true"' "in Docker mode"
assert_contains "$R_" 'ipv4_address: ${MCCTL_ROUTER_IP:?' "with the static address MCCTL_ROUTER_IP"
assert_contains "$R_" "condition: service_healthy" "and starts only once the egress guard is healthy"
assert_not_contains "$R_" "network_mode" "mc-router is not on the host network"
assert_not_contains "$R_" "cap_add" "and gains no capability"
assert_contains "$G_" "network_mode: host" "the guard runs in the host's network namespace"
assert_contains "$G_" "cap_add: [NET_ADMIN]" "with NET_ADMIN and nothing else"
assert_not_contains "$G_" "privileged" "and is not privileged"
assert_not_contains "$G_" "ports:" "and publishes nothing"
assert_eq 'external:true' "$(sed -n '/^networks:/,$p' "$STACK" | grep external | tr -d ' ')" "the game network is external (mcctl up creates it)"
leak=$(no_comments | sed -e 's/\$\$//g' -e 's/\${MCCTL_[A-Z_]*:?[^}]*}//g' | grep -n '\$')
assert_eq "" "$leak" "every \$ is \$\$ or a \${MCCTL_*:?} (compose would otherwise fill in an empty variable)"

echo "the fake iptables (the tests below rely on it)"
reset_ipt
iptables -w 5 -N T1;                                 assert_eq 0 $? "-N creates a chain"
iptables -N T1 2>/dev/null;                          assert_eq 1 $? "-N on a chain that exists: 1"
iptables -A T1 -s 1.1.1.1 -j DROP
iptables -I T1 -j RETURN
iptables -I T1 2 -j ACCEPT
assert_eq "-N T1
-A T1 -j RETURN
-A T1 -j ACCEPT
-A T1 -s 1.1.1.1 -j DROP" "$(iptables -S T1)" "-A appends, -I puts a rule at the top, -I N at position N"
iptables -C T1 -s 1.1.1.1 -j DROP;                   assert_eq 0 $? "-C finds a rule"
iptables -C T1 -s 2.2.2.2 -j DROP 2>/dev/null;       assert_eq 1 $? "-C on a rule that is not there: 1"
iptables -F T1;                                      assert_eq "-N T1" "$(iptables -S T1)" "-F empties the chain"
iptables -S NOPE 2>/dev/null;                        assert_eq 1 $? "-S on a missing chain: 1"
assert_eq "-A DOCKER-USER -j RETURN" "$(iptables -S DOCKER-USER | grep '^-A')" "DOCKER-USER starts with Docker's own RETURN"
echo '-s 9.9.9.9' >"$FAKE_STATE/iptables.fail"
iptables -A T1 -s 9.9.9.9 -j DROP 2>/dev/null;       assert_eq 1 $? "a call that matches iptables.fail fails"
assert_eq "-N T1" "$(iptables -S T1)" "and changes nothing"

echo "the guard script and its healthcheck parse as POSIX sh (the guard runs under sh in Alpine)"
# guard_block: egress-guard's command ("- |", de-indented by 8, through the line with "exec sleep infinity");
# health_block: its CMD-SHELL healthcheck ("- |", de-indented by 10). Both: $$ becomes $, as compose does.
guard_block() {
    awk '
        $0 == "  egress-guard:" { svc = 1; next }
        svc && /^[^ ]/ { exit }
        svc && st == 0 && /^ *- \|[ ]*$/ { st = 1; next }
        st == 1 {
            line = $0
            sub(/^        /, "", line)
            print line
            if ($0 ~ /exec sleep infinity/) exit
        }' "$STACK" | sed 's/\$\$/$/g'
}
health_block() {
    awk '
        $0 == "  egress-guard:" { svc = 1; next }
        svc && /^[^ ]/ { exit }
        svc && st == 0 && /^ *- CMD-SHELL$/ { st = 1; next }
        st == 1 && /^ *- \|[ ]*$/ { st = 2; next }
        st == 2 {
            if ($0 !~ /^          /) exit
            line = $0
            sub(/^          /, "", line)
            print line
        }' "$STACK" | sed 's/\$\$/$/g'
}
guard_block >"$SB/guard-check.sh"; health_block >"$SB/health-check.sh"
sh -n "$SB/guard-check.sh"; assert_eq 0 $? "the egress-guard command parses with sh -n"
sh -n "$SB/health-check.sh"; assert_eq 0 $? "the healthcheck script parses with sh -n"
GTXT=$(<"$SB/guard-check.sh")
assert_contains "$GTXT" "MCCTL-INGRESS" "the extracted script builds MCCTL-INGRESS"
assert_contains "$GTXT" "connlimit-above" "and has the connlimit rule"
assert_contains "$GTXT" "hashlimit-above" "and the hashlimit rule"
assert_contains "$GTXT" '$CONN_LIMIT' "and reads \$CONN_LIMIT"
assert_contains "$GTXT" '$RATE' "and reads \$RATE"
assert_contains "$(<"$SB/health-check.sh")" "-C DOCKER-USER" "the healthcheck text was extracted"
printf 'if then\n' >"$SB/broken-check.sh"; sh -n "$SB/broken-check.sh" 2>/dev/null; rc=$?
((rc != 0)) && pass "(control) sh -n rejects a broken script" || fail "(control) sh -n rejects a broken script"

echo "the guard script (run against the fake iptables)"
mkdir -p "$SB/guardbin"
cat >"$SB/guardbin/apk" <<'EOF'
#!/bin/sh
echo "apk $*" >>"$FAKE_STATE/calls.log"
EOF
cat >"$SB/guardbin/sleep" <<'EOF'
#!/bin/sh
# stands in for sleep: logs it, and (Docker "starts") creates DOCKER-USER if it was missing
echo "sleep $*" >>"$FAKE_STATE/calls.log"
if ! grep -qx DOCKER-USER "$FAKE_STATE/iptables.chains" 2>/dev/null; then
    echo DOCKER-USER >>"$FAKE_STATE/iptables.chains"
    printf 'DOCKER-USER\t-j RETURN\n' >>"$FAKE_STATE/iptables.rules"
fi
EOF
chmod +x "$SB/guardbin/apk" "$SB/guardbin/sleep"

# block_after PATTERN: the literal block scalar ("- |") that follows the first line matching PATTERN, de-indented, with $$ turned
# into $ as compose does
block_after() {
    awk -v pat="$1" '
        st == 0 && $0 ~ pat { st = 1; next }
        st == 1 && /^[ ]*- \|[ ]*$/ { st = 2; next }
        st == 2 {
            if ($0 ~ /^[ ]*$/) { print ""; next }
            match($0, /^ */)
            if (bi == "") bi = RLENGTH
            if (RLENGTH < bi) exit
            print substr($0, bi + 1)
        }' "$STACK" | sed 's/\$\$/$/g'
}
GUARD=$(block_after '^ *- -c$')
HEALTH=$(block_after '^ *- CMD-SHELL$')
RANGES=$(sed -n 's/^ *PRIVATE_RANGES: "\(.*\)"$/\1/p' "$STACK")
assert_eq "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10" "$RANGES" "the private ranges the guard blocks"
assert_contains "$GUARD" "MCCTL-INGRESS" "the guard script builds MCCTL-INGRESS"
assert_contains "$GUARD" '-I DOCKER-USER 2 -j MCCTL-INGRESS' "the ingress jump sits at position 2 in DOCKER-@USER"
assert_contains "$GUARD" '-A MCCTL-INGRESS -s "$GAME_SUBNET" -j RETURN' "MCCTL-INGRESS starts with a RETURN for the game subnet"
assert_contains "$GUARD" '-d "$ROUTER_IP" -p tcp --dport 25565 -m conntrack --ctstate NEW' "the limit rules are restricted to router-bound NEW connections"
assert_contains "$GUARD" 'connlimit' "the guard has a connlimit rule"
assert_contains "$GUARD" 'hashlimit' "the guard has a hashlimit rule"
assert_contains "$HEALTH" '-C MCCTL-INGRESS' "the healthcheck checks MCCTL-INGRESS rules"
assert_contains "$HEALTH" 'connlimit' "the healthcheck checks the connlimit rule"
assert_contains "$HEALTH" 'hashlimit' "the healthcheck checks the hashlimit rule"
grep -q 'CONN_LIMIT: ${MCCTL_CONN_LIMIT:?run through mcctl}' "$STACK" && pass "the service environment passes CONN_LIMIT" || fail "the service environment passes CONN_LIMIT"
grep -q 'RATE: ${MCCTL_RATE:?run through mcctl}' "$STACK" && pass "the service environment passes RATE" || fail "the service environment passes RATE"
[[ -n $GUARD && -n $HEALTH ]] && pass "the script and the healthcheck were found in the template" || fail "the script and the healthcheck were found in the template"
# guard_env SUBNET ROUTER: run the given shell text the way the container does (env of the service, stubs for apk and sleep)
guard_run() { # TEXT SUBNET ROUTER
    GAME_SUBNET=$2 ROUTER_IP=$3 PRIVATE_RANGES=$RANGES CONN_LIMIT=${MCCTL_CONN_LIMIT:-10} RATE=${MCCTL_RATE:-10/second} PATH="$SB/guardbin:$PATH" sh -c "$1" >/dev/null 2>&1
}
GSUB=172.30.0.0/24 GROUTER=172.30.0.2
run_guard()  { guard_run "$GUARD" "${1:-$GSUB}" "${2:-$GROUTER}"; }
healthy()    { guard_run "$HEALTH" "${1:-$GSUB}" "${2:-$GROUTER}"; }

# the order in the text, as the brief asks: the router's RETURN comes before the first DROP
router_line=$(grep -nF -- '-s "$ROUTER_IP" -d "$GAME_SUBNET" -j RETURN' <<<"$GUARD" | head -n 1 | cut -d: -f1)
drop_line=$(grep -nF -- '-j DROP' <<<"$GUARD" | head -n 1 | cut -d: -f1)
[[ -n $router_line && -n $drop_line ]] && pass "the script has a RETURN for the router and a DROP" || fail "the script has a RETURN for the router and a DROP" "$router_line / $drop_line"
((router_line < drop_line)) && pass "the router's RETURN is before the first DROP in the script ($router_line < $drop_line)" || fail "the router's RETURN is before the first DROP" "$router_line / $drop_line"

reset_ipt
run_guard; assert_eq 0 $? "the script runs to its end (its last command is the stubbed sleep infinity)"
assert_eq "apk add --no-cache iptables" "$(calls | head -n 1)" "it installs iptables first"
assert_eq "sleep infinity" "$(calls | tail -n 1)" "and ends by sleeping (the container stays up)"
chain() { iptables -S "$1" | grep '^-A' | sed "s/^-A $1 //"; }
EXPECT="-m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
-s 172.30.0.2 -d 172.30.0.0/24 -j RETURN
-s 172.30.0.0/24 -d 10.0.0.0/8 -j DROP
-s 172.30.0.0/24 -d 172.16.0.0/12 -j DROP
-s 172.30.0.0/24 -d 192.168.0.0/16 -j DROP
-s 172.30.0.0/24 -d 169.254.0.0/16 -j DROP
-s 172.30.0.0/24 -d 100.64.0.0/10 -j DROP"
assert_eq "$EXPECT" "$(chain MCCTL-EGRESS)" "MCCTL-EGRESS: replies, router, then one DROP per private range, in that order"
assert_eq "-j MCCTL-EGRESS
-j MCCTL-INGRESS
-j RETURN" "$(chain DOCKER-USER)" "DOCKER-USER: egress jump first, ingress jump second, Docker's RETURN stays after"
EXPECT_INGRESS="-s 172.30.0.0/24 -j RETURN
-d 172.30.0.2 -p tcp --dport 25565 -m conntrack --ctstate NEW -m connlimit --connlimit-above 10 --connlimit-mask 32 -j DROP
-d 172.30.0.2 -p tcp --dport 25565 -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 10/second --hashlimit-mode srcip --hashlimit-name mcctl-new -j DROP"
assert_eq "$EXPECT_INGRESS" "$(chain MCCTL-INGRESS)" "MCCTL-INGRESS: game subnet RETURN, connlimit DROP, hashlimit DROP"
assert_eq "-s 172.30.0.0/24 -m conntrack --ctstate NEW -j DROP" "$(chain INPUT)" "INPUT: new connections from the game network to the host are dropped"
cp "$FAKE_STATE/iptables.rules" "$SB/rules.good"
run_guard; assert_eq 0 $? "a second run (a restart of the container) works"
assert_eq "$(sort "$SB/rules.good")" "$(sort "$FAKE_STATE/iptables.rules")" "and leaves exactly the same rules: no duplicate, no missing rule"
assert_eq "$EXPECT" "$(chain MCCTL-EGRESS)" "in the same order"
run_guard 10.50.0.0/24 10.50.0.2; assert_eq 0 $? "the same container with another subnet and router address"
assert_eq "$(sed -e 's|172\.30\.0\.0/24|10.50.0.0/24|g' -e 's|172\.30\.0\.2|10.50.0.2|g' <<<"$EXPECT")" "$(chain MCCTL-EGRESS)" "refills the chain from the new values: no rule of the old subnet is left to shadow it"
assert_eq 1 "$(chain DOCKER-USER | grep -c MCCTL-EGRESS)" "and DOCKER-USER still has one jump"
run_guard

echo "what the rules decide (a first-match model of the chains, not a packet test)"
in_cidr() { # IP CIDR|IP
    local ip base len mask
    ip=$(ipv4_int "$1") && base=$(ipv4_int "${2%/*}") || return 1
    len=32; [[ $2 == */* ]] && len=${2#*/}
    mask=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
    (( (ip & mask) == (base & mask) ))
}
# verdict CHAIN SRC DST STATE: the first rule of CHAIN that matches decides, as in the kernel; ACCEPT when none does
verdict() {
    local chain=$1 src=$2 dst=$3 st=$4 line w i s d ct tgt
    while IFS= read -r line; do
        [[ $line == "-A $chain "* ]] || continue
        read -ra w <<<"$line"; s="" d="" ct="" tgt=""
        for ((i = 0; i < ${#w[@]}; i++)); do
            case ${w[i]} in -s) s=${w[i+1]} ;; -d) d=${w[i+1]} ;; --ctstate) ct=${w[i+1]} ;; -j) tgt=${w[i+1]} ;; esac
        done
        [[ -z $s ]] || in_cidr "$src" "$s" || continue
        [[ -z $d ]] || in_cidr "$dst" "$d" || continue
        [[ -z $ct || ,$ct, == *,$st,* ]] || continue
        echo "$tgt"; return
    done < <(iptables -S "$chain")
    echo ACCEPT
}
v() { assert_eq "$1" "$(verdict "${2}" "$3" "$4" "$5")" "$6"; }
v RETURN MCCTL-EGRESS 172.30.0.2 172.30.0.5 NEW "mc-router opens a connection to a game container: passes (RETURN)"
v DROP   MCCTL-EGRESS 172.30.0.6 172.30.0.5 NEW "a game container to another game container: dropped (no game-to-game path; the backup sidecar shares its server's namespace)"
v RETURN MCCTL-EGRESS 172.30.0.5 192.168.1.50 ESTABLISHED "a game container answers a player on the LAN (established): passes"
v DROP   MCCTL-EGRESS 172.30.0.5 192.168.0.1 NEW "a game container to 192.168.0.1: dropped"
v DROP   MCCTL-EGRESS 172.30.0.5 169.254.169.254 NEW "to the cloud metadata address: dropped"
v DROP   MCCTL-EGRESS 172.30.0.5 10.1.2.3 NEW "to 10.0.0.0/8: dropped"
v DROP   MCCTL-EGRESS 172.30.0.5 172.17.0.1 NEW "to another Docker bridge (172.16.0.0/12): dropped"
v DROP   MCCTL-EGRESS 172.30.0.5 100.64.1.1 NEW "to carrier-grade NAT space: dropped"
v DROP   MCCTL-EGRESS 172.30.0.5 192.168.1.50 NEW "to the LAN, new connection: dropped"
v ACCEPT MCCTL-EGRESS 172.30.0.5 8.8.8.8 NEW "to the internet: not touched by the guard"
v ACCEPT MCCTL-EGRESS 192.168.1.50 172.30.0.2 NEW "a player on the LAN to the router: not touched (not from the game network)"
v ACCEPT MCCTL-EGRESS 172.31.0.5 192.168.0.1 NEW "another network's container: not this guard's business"
v DROP   INPUT 172.30.0.5 172.30.0.1 NEW "a game container to the host (the bridge gateway): dropped by INPUT"
v ACCEPT INPUT 172.30.0.5 172.30.0.1 ESTABLISHED "the host answering a connection that exists: not dropped"
v ACCEPT INPUT 203.0.113.9 192.168.1.2 NEW "SSH from outside to the host: not dropped"
# the model must be able to tell a wrong order: the same rules with the router's RETURN moved after the drops (the mistake the
# plan warns about)
cp "$FAKE_STATE/iptables.rules" "$SB/rules.good"
{ grep -vF -- '-s 172.30.0.2 -d 172.30.0.0/24 -j RETURN' "$SB/rules.good"; printf 'MCCTL-EGRESS\t-s 172.30.0.2 -d 172.30.0.0/24 -j RETURN\n'; } >"$FAKE_STATE/iptables.rules"
v DROP MCCTL-EGRESS 172.30.0.2 172.30.0.5 NEW "(control) with the RETURN after the drops the model reports the router cut off"
cp "$SB/rules.good" "$FAKE_STATE/iptables.rules"

echo "no game-to-game path (the backup sidecar shares its server's network namespace and needs none)"
# 1. in the text: no line of the script or the healthcheck allows a packet whose source and destination are both GAME_SUBNET
g2g=$(printf '%s\n%s\n' "$GUARD" "$HEALTH" | grep -E -- '-s +"?\$\{?GAME_SUBNET\}?"? +-d +"?\$\{?GAME_SUBNET\}?"?' | grep -E -- '-j +(RETURN|ACCEPT)')
assert_eq "" "$g2g" "neither the script nor the healthcheck has a RETURN (or ACCEPT) from GAME_SUBNET to GAME_SUBNET"
# 2. in the chain it builds: no allow rule whose source and destination are the same network
same=$(iptables -S MCCTL-EGRESS | awk '/^-A / { s = d = j = ""; for (i = 1; i <= NF; i++) { if ($i == "-s") s = $(i+1); if ($i == "-d") d = $(i+1); if ($i == "-j") j = $(i+1) }
    if ((j == "RETURN" || j == "ACCEPT") && s != "" && s == d) print }')
assert_eq "" "$same" "the chain has no allow rule with the same source and destination"
# 3. what it decides: new connections between game containers (and from one to the router address) are dropped
v DROP MCCTL-EGRESS 172.30.0.5 172.30.0.6 NEW "a game container to a second game container: dropped"
v DROP MCCTL-EGRESS 172.30.0.5 172.30.0.2 NEW "a game container to the router's address: dropped"
v DROP MCCTL-EGRESS 172.30.0.9 172.30.0.5 NEW "a third game container to the first: dropped"
# the check can fail: a script with the rule put back is caught by 1 and 2
back=$(printf '%s\n' "$GUARD" 'ipt -A MCCTL-EGRESS -s "$GAME_SUBNET" -d "$GAME_SUBNET" -j RETURN')
[[ -n $(grep -E -- '-s +"?\$\{?GAME_SUBNET\}?"? +-d +"?\$\{?GAME_SUBNET\}?"?' <<<"$back" | grep -E -- '-j +(RETURN|ACCEPT)') ]] \
    && pass "(control) the text check sees a game-to-game RETURN when one is added" || fail "(control) the text check sees a game-to-game RETURN when one is added"

echo "the healthcheck (healthy only once the rules exist)"
assert_contains "$HEALTH" "-C INPUT" "it checks an INPUT rule"
assert_contains "$HEALTH" "-C DOCKER-USER" "and a DOCKER-USER rule"
healthy; assert_eq 0 $? "with every rule in place: healthy"
reset_ipt
healthy; rc=$?; ((rc != 0)) && pass "before the script has run: unhealthy" || fail "before the script has run: unhealthy"
run_guard
cp "$FAKE_STATE/iptables.rules" "$SB/rules.good"
for gone in '-j MCCTL-EGRESS' '--ctstate ESTABLISHED,RELATED' '-s 172.30.0.2 -d 172.30.0.0/24 -j RETURN' \
            '-d 10.0.0.0/8 -j DROP' '-d 172.16.0.0/12 -j DROP' \
            '-d 192.168.0.0/16 -j DROP' '-d 169.254.0.0/16 -j DROP' '-d 100.64.0.0/10 -j DROP' '--ctstate NEW -j DROP' \
            '-j MCCTL-INGRESS' '-s 172.30.0.0/24 -j RETURN' 'connlimit' 'hashlimit'; do
    cp "$SB/rules.good" "$FAKE_STATE/iptables.rules"
    n=$(grep -cF -- "$gone" "$FAKE_STATE/iptables.rules")
    grep -vF -- "$gone" "$SB/rules.good" >"$FAKE_STATE/iptables.rules"
    healthy; rc=$?
    ((n == 1 && rc != 0)) && pass "without the rule '$gone': unhealthy" || fail "without the rule '$gone': unhealthy" "rules removed: $n, status $rc"
done
cp "$SB/rules.good" "$FAKE_STATE/iptables.rules"
healthy; assert_eq 0 $? "(control) all rules back: healthy"
healthy 10.60.0.0/24 10.60.0.2; rc=$?; ((rc != 0)) && pass "rules for another subnet do not make this one healthy" || fail "rules for another subnet do not make this one healthy"

echo "the healthcheck on the real host: -C cannot match a hashlimit rule (iptables 1.8.10, nf_tables), so the rule is read with -S"
mkdir -p "$SB/hcbin"
cat >"$SB/hcbin/iptables" <<'FAKE'
#!/bin/sh
# iptables as the WSL host answers it: -C fails for any hashlimit rule; -S prints the chain, here the one hashlimit line in FAKE_HASH
[ "$1" = "-w" ] && shift 2
case $1 in
    -C) for a in "$@"; do [ "$a" = hashlimit ] && exit 1; done; exit 0 ;;
    -S) [ -n "$FAKE_HASH" ] && printf '%s\n' "$FAKE_HASH"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$SB/hcbin/iptables"
hc_env() {
    env PATH="$SB/hcbin:$PATH" ROUTER_IP=172.30.0.2 GAME_SUBNET=172.30.0.0/24 CONN_LIMIT=10 RATE=10/second \
        PRIVATE_RANGES="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10" sh "$SB/health-check.sh"
}
REAL_HASH='-A MCCTL-INGRESS -d 172.30.0.2/32 -p tcp -m tcp --dport 25565 -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 10/sec --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-name mcctl-new -j DROP'
FAKE_HASH=$REAL_HASH hc_env >/dev/null 2>&1; assert_eq 0 $? "healthy with the hashlimit rule as iptables -S prints it"
FAKE_HASH= hc_env >/dev/null 2>&1; rc=$?; ((rc != 0)) && pass "unhealthy without the hashlimit rule" || fail "unhealthy without the hashlimit rule"
FAKE_HASH=${REAL_HASH/-d 172.30.0.2\/32/-d 10.60.0.2\/32} hc_env >/dev/null 2>&1; rc=$?; ((rc != 0)) && pass "unhealthy when the hashlimit rule is for another address" || fail "unhealthy when the hashlimit rule is for another address"

echo "the guard fails closed"
reset_ipt
echo '-d 100.64.0.0/10 -j DROP' >"$FAKE_STATE/iptables.fail"
run_guard; rc=$?
((rc != 0)) && pass "when the last DROP cannot be added the script stops with an error" || fail "when the last DROP cannot be added the script stops with an error"
assert_eq "" "$(chain DOCKER-USER | grep MCCTL-EGRESS)" "the jump into the chain was not made"
rm -f "$FAKE_STATE/iptables.fail"
healthy; rc=$?; ((rc != 0)) && pass "and the guard is not healthy" || fail "and the guard is not healthy"
run_guard; assert_eq 0 $? "a restart without the fault completes"
assert_eq "$EXPECT" "$(chain MCCTL-EGRESS)" "with the full chain"
healthy; assert_eq 0 $? "and the guard is healthy"
reset_ipt
: >"$FAKE_STATE/iptables.no-docker"
run_guard; assert_eq 0 $? "Docker not up yet (no DOCKER-USER chain): the script waits, then completes"
assert_eq "apk add --no-cache iptables
iptables -w 5 -S DOCKER-USER
sleep 2
iptables -w 5 -S DOCKER-USER" "$(calls | head -n 4)" "it asked for DOCKER-USER, slept 2 seconds, asked again"
assert_eq "$EXPECT" "$(chain MCCTL-EGRESS)" "and built the chain"
reset_ipt

echo "cmd_up"
( cmd_up extra ) >/dev/null 2>&1;   assert_eq 2 $? "cmd_up with an argument: EX_USAGE"
( cmd_down extra ) >/dev/null 2>&1; assert_eq 2 $? "cmd_down with an argument: EX_USAGE"
reset
printf 's1::1000:1000:s1\n' >"$SB/sftp-users.conf"   # one SFTP user: the SFTP stack starts (with none it does not, see below)
m up; assert_eq 0 "$RC" "up: the port is free, the network is new"
assert_eq "$SSCALL
docker network ls -q --filter name=^mcctl_game\$
docker network create --driver bridge --subnet 172.30.0.0/24 --ip-range 172.30.0.128/25 --label mcctl.managed=true mcctl_game
docker compose -p mcctl-stack -f $SBSTACK up -d --wait
$SFTPUP" "$(calls)" "the ordered call log: port check, network look-up, network create, compose up --wait, then the SFTP stack"
assert_contains "$OUT" "router up" "and it says so"

reset
echo abc123 >"$FAKE_STATE/docker.network.ls"
printf '172.30.0.0/24 \n' >"$FAKE_STATE/docker.network.inspect"
printf 's1::1000:1000:s1\n' >"$SB/sftp-users.conf"
m up; assert_eq 0 "$RC" "up: the network exists with the right subnet"
assert_eq "$SSCALL
docker network ls -q --filter name=^mcctl_game\$
docker network inspect --format {{range .IPAM.Config}}{{.Subnet}} {{end}} mcctl_game
docker compose -p mcctl-stack -f $SBSTACK up -d --wait
$SFTPUP" "$(calls)" "the ordered call log: no network create"

echo "up with no SFTP user: the SFTP stack is not started; the router gets the socket's group; down without the socket stops"
reset
echo abc123 >"$FAKE_STATE/docker.network.ls"
printf '172.30.0.0/24 \n' >"$FAKE_STATE/docker.network.inspect"
: >"$SB/sftp-users.conf"
m up; assert_eq 0 "$RC" "up with no SFTP user: exit 0"
assert_not_contains "$(calls)" "mcctl-sftp" "no SFTP compose call"
assert_not_contains "$OUT" "SFTP up on" "and no 'SFTP up' line"
assert_contains "$(<"$STACK")" 'group_add: ["${MCCTL_DOCKER_GID:?run through mcctl}"]' "the router gets the socket's group through group_add"
MCCTL_DOCKER_SOCKET=$SB/missing.sock m down; assert_eq 1 "$RC" "down with no Docker socket: exit 1, the message from stack_dc is shown"
assert_contains "$OUT" "group of the Docker socket" "and it says why"

reset
echo abc123 >"$FAKE_STATE/docker.network.ls"
printf '172.20.0.0/16 \n' >"$FAKE_STATE/docker.network.inspect"
m up; assert_eq 3 "$RC" "up: the network exists with ANOTHER subnet: EX_PREFLIGHT"
assert_contains "$OUT" "172.20.0.0/16" "the message names the subnet it found"
assert_contains "$OUT" "172.30.0.0/24" "and the one that is configured"
assert_eq 0 "$(count_calls 'up -d')" "compose up was not called (the guard would protect the wrong network)"
assert_eq 0 "$(count_calls 'network create')" "and nothing was created"

echo "cmd_up: port 25565 is taken (Review Focus 4)"
reset
printf '%s\n' 'LISTEN 0 4096 0.0.0.0:25565 0.0.0.0:* users:(("mc-router",pid=4242,fd=7))' >"$FAKE_STATE/ss.listen"
m up; assert_eq 3 "$RC" "up refuses with EX_PREFLIGHT"
assert_contains "$OUT" "mc-router" "and names the process that holds the port"
assert_contains "$OUT" "pid=4242" "(with its pid)"
assert_contains "$OUT" "Nothing was created" "and says nothing was created"
assert_eq "$SSCALL
docker compose -p mcctl-stack -f $SBSTACK ps -q --status running mc-router" "$(calls)" "the ordered call log: port check, 'is that our own router?', and nothing else"
assert_eq 0 "$(count_calls 'network')" "no network was looked up or created"
assert_eq 0 "$(count_calls ' up ')" "and compose up was not called"

reset
printf '%s\n' 'LISTEN 0 511 0.0.0.0:25565 0.0.0.0:*' >"$FAKE_STATE/ss.listen"
m up; assert_eq 3 "$RC" "a listener whose process is not visible: still refused"
assert_contains "$OUT" "0.0.0.0:25565" "and the address is shown"
assert_contains "$OUT" "as root" "with the way to see the process"
assert_eq 0 "$(count_calls 'network')" "nothing was created"

echo "cmd_up: running it again while our own router holds the port"
reset
printf '%s\n' "$DP" >"$FAKE_STATE/ss.listen"
echo cid1 >"$FAKE_STATE/docker.compose.ps.running.mc-router"
echo abc123 >"$FAKE_STATE/docker.network.ls"
printf '172.30.0.0/24 \n' >"$FAKE_STATE/docker.network.inspect"
printf 's1::1000:1000:s1\n' >"$SB/sftp-users.conf"
m up; assert_eq 0 "$RC" "up: the listener is this stack's own router: allowed"
assert_eq "$SSCALL
docker compose -p mcctl-stack -f $SBSTACK ps -q --status running mc-router
docker network ls -q --filter name=^mcctl_game\$
docker network inspect --format {{range .IPAM.Config}}{{.Subnet}} {{end}} mcctl_game
docker compose -p mcctl-stack -f $SBSTACK up -d --wait
$SFTPUP" "$(calls)" "the ordered call log"

echo "cmd_up: failures"
reset
echo 1 >"$FAKE_STATE/ss.rc"
m up; assert_eq 3 "$RC" "ss fails: EX_PREFLIGHT (an unknown is not 'free')"
assert_eq "$SSCALL" "$(calls)" "and nothing else was called"
reset
echo 1 >"$FAKE_STATE/docker.network.ls.rc"
m up; assert_eq 1 "$RC" "docker network ls fails (daemon down): EX_FAIL"
assert_eq 0 "$(count_calls 'network create')" "no network was created"
assert_eq 0 "$(count_calls ' up ')" "and compose up was not called"
reset
echo 1 >"$FAKE_STATE/docker.network.create.rc"
m up; assert_eq 1 "$RC" "docker network create fails: EX_FAIL"
assert_contains "$OUT" "MCCTL_GAME_SUBNET" "the message points at the setting"
assert_eq 0 "$(count_calls ' up ')" "compose up was not called"
reset
echo 1 >"$FAKE_STATE/docker.compose.up.rc"
m up; assert_eq 1 "$RC" "compose up fails (an unhealthy guard fails --wait): EX_FAIL"
assert_contains "$OUT" "docker logs mcctl-egress-guard" "the message says where to look"
reset
export MCCTL_GAME_SUBNET=10.50.0.0/24 MCCTL_ROUTER_IP=10.50.0.2
m up; assert_eq 0 "$RC" "up with another subnet in the configuration"
assert_contains "$(calls)" "--subnet 10.50.0.0/24 --ip-range 10.50.0.128/25 --label mcctl.managed=true mcctl_game" "the network is created on MCCTL_GAME_SUBNET, game addresses only from the half without the router"
reset
export MCCTL_ROUTER_IP=10.99.0.2
m up; assert_eq 3 "$RC" "a router address outside the subnet: EX_PREFLIGHT from the configuration check"
assert_eq "" "$(calls)" "before any call"
export MCCTL_GAME_SUBNET=172.30.0.0/24 MCCTL_ROUTER_IP=172.30.0.2
reset
m up extra; assert_eq 2 "$RC" "up extra: EX_USAGE"
assert_eq "" "$(calls)" "before any call"

echo "cmd_down"
reset
m down; assert_eq 0 "$RC" "down"
assert_eq "docker compose -p mcctl-stack -f $SBSTACK down
$SFTPDOWN" "$(calls)" "the ordered call log: one compose down of the router stack, then one of the SFTP stack"
assert_contains "$OUT" "egress rules are untouched" "and it says the egress rules stay"
reset
echo 1 >"$FAKE_STATE/docker.compose.down.rc"
m down; assert_eq 1 "$RC" "down: compose fails: EX_FAIL"
reset
m down now; assert_eq 2 "$RC" "down now: EX_USAGE"
assert_eq "" "$(calls)" "before any call"

echo "router_reload"
reset
router_reload; assert_eq 0 $? "router_reload"
assert_eq "docker compose -p mcctl-stack -f $STACK kill -s HUP mc-router" "$(calls)" "one call: compose kill -s HUP mc-router of the stack project"
assert_contains "$(calls)" "kill -s HUP mc-router" "(the HUP that tells mc-router to re-read its routes)"
echo 1 >"$FAKE_STATE/docker.compose.kill.rc"
router_reload; assert_eq 1 $? "router_reload returns the status of compose"
reset

sandbox_cleanup
finish

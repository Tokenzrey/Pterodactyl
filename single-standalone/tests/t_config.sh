#!/usr/bin/env bash
# lib/config.sh: load_config (file + environment + defaults + validators), require_config, and the commands cmd_init and cmd_doctor.
# E1: doctor's ordered call log and init's empty one. E4: a planted secret never reaches doctor's output or the call log.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
sandbox
unset MCCTL_DOMAIN MCCTL_PUBLIC_IPV4 MCCTL_CF_ZONE_ID MCCTL_GAME_SUBNET MCCTL_ROUTER_IP

# cfg LINE...: write config/mcctl.env
cfg() { mkdir -p "$SB/config"; printf '%s\n' "$@" >"$SB/config/mcctl.env"; }
# lc [VAR=value...]: load_config in a subshell with those variables exported. Prints its messages, then one result line.
lc() {
    (
        for kv in "$@"; do export "$kv"; done
        load_config; rc=$?
        echo "rc=$rc root=$MCCTL_ROOT domain=$MCCTL_DOMAIN ip=$MCCTL_PUBLIC_IPV4 zone=$MCCTL_CF_ZONE_ID subnet=$MCCTL_GAME_SUBNET router=$MCCTL_ROUTER_IP"
    ) 2>&1
}
# good KEY VALUE [VAR=value...] / bad KEY VALUE [...]: load_config accepts / rejects KEY=VALUE (and names KEY when it rejects)
good() { local out; out=$(lc "$1=$2" "${@:3}"); [[ ${out##*$'\n'} == rc=0\ * ]] && pass "$1 accepts '$2'" || fail "$1 accepts '$2'" "$out"; }
bad()  { local out last; out=$(lc "$1=$2" "${@:3}"); last=${out##*$'\n'}
         [[ $last == rc=1\ * && $out == *"$1"* ]] && pass "$1 rejects '$2'" || fail "$1 rejects '$2'" "$out"; }

echo "load_config: defaults"
rm -rf "$SB/config"
assert_eq "rc=0 root=$SB domain= ip= zone= subnet=172.30.0.0/24 router=172.30.0.2" "$(lc)" "no file, no environment: defaults, root from MCCTL_ROOT"
out=$( (load_config; env) 2>&1 )
assert_contains "$out" "MCCTL_ROUTER_IP=172.30.0.2" "the values are exported"
assert_contains "$out" "MCCTL_ROOT=$SB" "MCCTL_ROOT is exported"
out=$( (unset MCCTL_ROOT; MCCTL_HOME=$SB/home; load_config; echo "$MCCTL_ROOT") 2>&1 )
assert_eq "$SB/home" "$out" "MCCTL_ROOT defaults to MCCTL_HOME"

echo "load_config: the file"
cfg '# comment' '' 'MCCTL_DOMAIN=mc.mydomain.net' 'MCCTL_PUBLIC_IPV4=203.0.113.7' "MCCTL_CF_ZONE_ID='0123456789abcdef0123456789abcdef'  # quoted"
assert_eq "rc=0 root=$SB domain=mc.mydomain.net ip=203.0.113.7 zone=0123456789abcdef0123456789abcdef subnet=172.30.0.0/24 router=172.30.0.2" "$(lc)" "file values, a quoted value, comments and blank lines"
printf 'MCCTL_DOMAIN=mc.mydomain.net\r\nMCCTL_ROUTER_IP=172.30.0.9\r\n' >"$SB/config/mcctl.env"
assert_contains "$(lc)" "domain=mc.mydomain.net ip= zone= subnet=172.30.0.0/24 router=172.30.0.9" "a CRLF file (edited on Windows) loads"
cfg 'MCCTL_DOMAIN=one.mydomain.net' 'MCCTL_DOMAIN=two.mydomain.net'
assert_contains "$(lc)" "domain=two.mydomain.net" "a later line wins over an earlier one"
cfg 'MCCTL_DOMAIN=file.mydomain.net'
assert_contains "$(lc MCCTL_DOMAIN=env.mydomain.net)" "domain=env.mydomain.net" "a value already in the environment wins over the file"
assert_contains "$(lc MCCTL_DOMAIN=)" "domain=file.mydomain.net" "an empty variable counts as unset"
cfg 'MCCTL_DOMAIN=mc.mydomain.net'
assert_contains "$(lc MCCTL_ROUTER_IP=172.30.0.9)" "router=172.30.0.9" "the environment overrides a default"

echo "load_config: the file is parsed, never executed"
for line in 'MCCTL_DOMAIN=$(touch '"$SB"'/pwned)' 'MCCTL_DOMAIN=`touch '"$SB"'/pwned`' 'MCCTL_DOMAIN=a.b.net;touch '"$SB"'/pwned' 'MCCTL_DOMAIN=$HOME'; do
    cfg "$line"; out=$(lc)
    [[ ${out##*$'\n'} == rc=1\ * && $out == *MCCTL_DOMAIN* ]] && pass "refused: $line" || fail "refused: $line" "$out"
done
assert_no_file "$SB/pwned" "nothing in the file was executed"
cfg 'PATH=/tmp/evil';           out=$(lc); assert_contains "$out" "rc=1" "a key outside MCCTL_* is refused"; assert_contains "$out" "mcctl.env:1" "the line is named"
cfg 'DOCKER_HOST=tcp://evil:2375'; assert_contains "$(lc)" "rc=1" "DOCKER_HOST cannot be set from the file"
cfg 'not a setting';            assert_contains "$(lc)" "rc=1" "a line that is not KEY=value is refused"
cfg 'MCCTL_ROOT=/tmp/elsewhere'; out=$(lc)
assert_contains "$out" "rc=1" "MCCTL_ROOT cannot be set from the file"; assert_contains "$out" "root=$SB" "MCCTL_ROOT is left alone"
cfg 'MCCTL_CF_ZONE_ID=sk-live-abc def'; assert_not_contains "$(lc)" "sk-live" "a refused value is not echoed back"
cfg 'MCCTL_DOMAIN=ok.mydomain.net' 'garbage' 'MCCTL_PUBLIC_IPV4=999.1.1.1'
out=$(lc); assert_contains "$out" "mcctl.env:2" "every problem is reported, not only the first (line 2)"; assert_contains "$out" "MCCTL_PUBLIC_IPV4" "every problem is reported (the address)"
rm -rf "$SB/config"

echo "validators"
good MCCTL_DOMAIN mc.mydomain.net;   good MCCTL_DOMAIN play.my-domain.co.uk
for v in Mc.MyDomain.net mydomain https://mc.mydomain.net mc.mydomain.net/ -a.mydomain.net a..mydomain.net mc.mydomain.n mc.mydomain.net. 'mc .net'; do bad MCCTL_DOMAIN "$v"; done
good MCCTL_PUBLIC_IPV4 203.0.113.7;  good MCCTL_PUBLIC_IPV4 1.2.3.4
for v in 999.1.1.1 256.0.0.1 1.2.3 1.2.3.4.5 01.2.3.4 1.2.3.04 ' 1.2.3.4' '1.2.3.4 ' a.b.c.d 1.2.3.-4 1.2.3.4/32; do bad MCCTL_PUBLIC_IPV4 "$v"; done
good MCCTL_CF_ZONE_ID 0123456789abcdef0123456789abcdef
for v in a/b .. 'a b' "$(printf 'a%.0s' {1..65})" 'a?b=c'; do bad MCCTL_CF_ZONE_ID "$v"; done
good MCCTL_GAME_SUBNET 172.30.0.0/24;  good MCCTL_GAME_SUBNET 10.20.0.0/16 MCCTL_ROUTER_IP=10.20.0.2
good MCCTL_GAME_SUBNET 192.168.50.0/29 MCCTL_ROUTER_IP=192.168.50.2
for v in 172.30.0.0/8 172.30.0.0/30 172.30.0.1/24 8.8.8.0/24 172.30.0.0 300.1.1.0/24 172.30.0.0/24/1 172.15.0.0/24 172.32.0.0/24 abc; do bad MCCTL_GAME_SUBNET "$v"; done
good MCCTL_ROUTER_IP 172.30.0.254
for v in 172.30.0.0 172.30.0.1 172.30.0.255 172.31.0.2 abc 172.30.0.256; do bad MCCTL_ROUTER_IP "$v"; done
bad MCCTL_ROUTER_IP 192.168.50.2 MCCTL_GAME_SUBNET=10.20.0.0/16
bad MCCTL_GAME_SUBNET 10.20.0.0/16        # the default router address is not in this subnet; the message names the router key too
assert_contains "$(lc MCCTL_GAME_SUBNET=10.20.0.0/16)" "MCCTL_ROUTER_IP" "a router address outside the subnet is named"
bad MCCTL_ROOT relative/dir
bad MCCTL_ROOT ""        # empty is "unset": falls back to MCCTL_HOME, which is not set in the test process

echo "firewall config validators"
good MCCTL_CONN_LIMIT 10;  good MCCTL_CONN_LIMIT 1;  good MCCTL_CONN_LIMIT 65535
for v in 0 abc '10;x' 70000 -1; do bad MCCTL_CONN_LIMIT "$v"; done
good MCCTL_RATE 10/second;  good MCCTL_RATE 5/minute;  good MCCTL_RATE 1/hour
for v in 10/day 0/second 1000000/second '10/second;x' abc/second 10; do bad MCCTL_RATE "$v"; done
good MCCTL_FIREWALL_ROLLBACK_SECONDS 300;  good MCCTL_FIREWALL_ROLLBACK_SECONDS 0;  good MCCTL_FIREWALL_ROLLBACK_SECONDS 3600
for v in -1 99999 x; do bad MCCTL_FIREWALL_ROLLBACK_SECONDS "$v"; done
good MCCTL_SSH_PORTS 22;  good MCCTL_SSH_PORTS 22,2222;  good MCCTL_SSH_PORTS ""
for v in 0 70000 abc '22;x'; do bad MCCTL_SSH_PORTS "$v"; done

echo "require_config"
out=$( (require_config MCCTL_DOMAIN) 2>&1 ); rc=$?
assert_eq 3 "$rc" "an unset key exits 3 (EX_PREFLIGHT)"; assert_contains "$out" "MCCTL_DOMAIN" "the missing key is named"
out=$( (require_config MCCTL_DOMAIN MCCTL_CF_ZONE_ID MCCTL_PUBLIC_IPV4) 2>&1 ); rc=$?
assert_eq 3 "$rc" "several unset keys exit 3"
assert_contains "$out" "MCCTL_DOMAIN" "first missing key named"; assert_contains "$out" "MCCTL_CF_ZONE_ID" "second missing key named"; assert_contains "$out" "MCCTL_PUBLIC_IPV4" "third missing key named"
out=$( (MCCTL_DOMAIN=mc.mydomain.net; require_config MCCTL_DOMAIN MCCTL_CF_ZONE_ID) 2>&1 ); rc=$?
assert_eq 3 "$rc" "one of two unset still exits 3"; assert_not_contains "$out" "MCCTL_DOMAIN" "a key that is set is not named"
out=$( (MCCTL_DOMAIN=mc.mydomain.net MCCTL_CF_ZONE_ID=abc; require_config MCCTL_DOMAIN MCCTL_CF_ZONE_ID) 2>&1 ); rc=$?
assert_eq 0 "$rc" "all keys set: returns 0"; assert_eq "" "$out" "all keys set: says nothing"
out=$( (MCCTL_DOMAIN=; require_config MCCTL_DOMAIN) 2>&1 ); rc=$?
assert_eq 3 "$rc" "an empty value counts as unset"
out=$( (require_config) 2>&1 ); rc=$?
assert_eq 0 "$rc" "no keys asked: returns 0"
printf '%s\n' 'cmd_zz() { require_config MCCTL_DOMAIN; echo ran; }' >"$SB/lib/zz.sh"
m zz;                                   assert_eq 3 "$RC" "through ./mcctl: a command that needs MCCTL_DOMAIN exits 3"
assert_contains "$OUT" "MCCTL_DOMAIN" "through ./mcctl: the key is named";  assert_not_contains "$OUT" "ran" "through ./mcctl: the command stopped"
MCCTL_DOMAIN=mc.mydomain.net m zz;      assert_contains "$OUT" "ran" "through ./mcctl: the environment satisfies it"
MCCTL_PUBLIC_IPV4=999.1.1.1 m zz;       assert_eq 3 "$RC" "through ./mcctl: an invalid value stops every command (exit 3)"
assert_contains "$OUT" "MCCTL_PUBLIC_IPV4" "through ./mcctl: the invalid key is named"; assert_not_contains "$OUT" "ran" "through ./mcctl: the command did not run"
MCCTL_PUBLIC_IPV4=999.1.1.1 m --version; assert_eq 0 "$RC" "through ./mcctl: --version does not need a valid config"
MCCTL_PUBLIC_IPV4=999.1.1.1 m help;     assert_eq 0 "$RC" "through ./mcctl: help does not need a valid config"
m help;                                 assert_contains "$OUT" "init" "usage lists init"; assert_contains "$OUT" "doctor" "usage lists doctor"
rm -f "$SB/lib/zz.sh"

echo "init"
: >"$FAKE_STATE/calls.log"
m init
assert_eq 0 "$RC" "init exits 0"
assert_file "$SB/secrets" "init creates secrets/"; assert_file "$SB/servers" "init creates servers/"
assert_mode "$SB/secrets" 700 "secrets/ is mode 700"; assert_mode "$SB/servers" 700 "servers/ is mode 700"
assert_contains "$OUT" "mcctl.env" "init says how to create the config file"
assert_eq "" "$(calls)" "init makes no Docker, curl or rcon call"
chmod 755 "$SB/secrets" "$SB/servers"; printf 'keep' >"$SB/secrets/keep"
m init
assert_eq 0 "$RC" "init is idempotent"; assert_mode "$SB/secrets" 700 "a second init puts the mode back to 700"
assert_eq "keep" "$(cat "$SB/secrets/keep")" "a second init leaves existing files alone"
mkdir -p "$SB/config"; : >"$SB/config/mcctl.env"; m init
assert_not_contains "$OUT" "cp config" "no hint once config/mcctl.env exists"
m init extra;                           assert_eq 2 "$RC" "init takes no arguments (EX_USAGE)"
rm -rf "$SB/secrets" "$SB/servers" "$SB/config"
( cd "$SB" && MCCTL_ROOT=$SB/fresh/root ./mcctl init ) >/dev/null 2>&1
assert_mode "$SB/fresh" 700 "init under a new root: the parents it creates are 700 too"
assert_file "$SB/fresh/root/secrets" "init under a new root: secrets/ exists"
rm -rf "$SB/fresh"

echo "config/mcctl.env.example"
mkdir -p "$SB/config"; cp "$REPO/config/mcctl.env.example" "$SB/config/mcctl.env"
assert_contains "$(lc)" "rc=0 " "the example file loads as shipped (required values are empty, not placeholders)"
sed -E 's/^(MCCTL_DOMAIN)=.*/\1=mc.mydomain.net/; s/^(MCCTL_PUBLIC_IPV4)=.*/\1=203.0.113.7/; s/^(MCCTL_CF_ZONE_ID)=.*/\1=0123456789abcdef0123456789abcdef/' \
    "$REPO/config/mcctl.env.example" >"$SB/config/mcctl.env"
assert_eq "rc=0 root=$SB domain=mc.mydomain.net ip=203.0.113.7 zone=0123456789abcdef0123456789abcdef subnet=172.30.0.0/24 router=172.30.0.2" "$(lc)" "the example file with its blanks filled in"
for k in MCCTL_DOMAIN MCCTL_PUBLIC_IPV4 MCCTL_CF_ZONE_ID MCCTL_GAME_SUBNET MCCTL_ROUTER_IP; do
    grep -q "^$k=" "$REPO/config/mcctl.env.example" && pass "the example documents $k" || fail "the example documents $k"
done
grep -qi 'secrets/cloudflare_token' "$REPO/config/mcctl.env.example" && pass "the example says the token is a file" || fail "the example says the token is a file"
assert_not_contains "$(grep -v '^#' "$REPO/config/mcctl.env.example")" "TOKEN=" "the example holds no token value"
rm -rf "$SB/config"

echo "doctor"
printf '#!/bin/sh\nexit 0\n' >"$SB/fakebin/jq"; chmod +x "$SB/fakebin/jq"   # the host may lack jq; doctor only looks for it
: >"$FAKE_STATE/calls.log"
m doctor
assert_eq 0 "$RC" "doctor on a bare tree (before init): exit 0"
for w in "bash " "docker compose" "jq" "curl" "config" "secrets/ not created yet"; do assert_contains "$OUT" "[ok]   $w" "doctor: [ok] $w"; done
assert_not_contains "$OUT" "[FAIL]" "doctor: no failures on a healthy host"
assert_eq "docker compose version" "$(calls)" "doctor: the only external call is 'docker compose version'"
m init >/dev/null
m doctor;  assert_eq 0 "$RC" "doctor after init with no secrets: exit 0"
# real file modes, where this host keeps them
if posix_modes_ok "$SB"; then
    write_secret "$SB/secrets/cloudflare_token" "tok"
    m doctor;  assert_eq 0 "$RC" "doctor with a mode 600 secret: exit 0"; assert_contains "$OUT" "[ok]   secrets/cloudflare_token mode 600" "doctor: secret line"
    chmod 644 "$SB/secrets/cloudflare_token"
    m doctor;  assert_eq 3 "$RC" "doctor with a real mode 644 secret: exit 3 (EX_PREFLIGHT)"
    assert_contains "$OUT" "[FAIL] secrets/cloudflare_token has mode 644; run: chmod 600 secrets/cloudflare_token" "doctor: a real mode 644 gets the hint"
else
    skip "doctor on real file modes (this host has no POSIX file modes; the stubbed 'stat' below covers the logic)"
fi
# the same on every host: a stub 'stat' reports the mode in FAKE_STAT_MODE (it passes everything else to the real one)
printf '%s
' '#!/bin/sh' '[ -n "$FAKE_STAT_MODE" ] && [ "$1" = -c ] && [ "$2" = %a ] && { echo "$FAKE_STAT_MODE"; exit 0; }' 'exec /usr/bin/stat "$@"' >"$SB/fakebin/stat"
chmod +x "$SB/fakebin/stat"
printf 'tok
' >"$SB/secrets/cloudflare_token"
FAKE_STAT_MODE=600 m doctor;  assert_eq 0 "$RC" "doctor, secret reported as 600: exit 0"; assert_contains "$OUT" "[ok]   secrets/cloudflare_token mode 600" "doctor, 600: ok line"
FAKE_STAT_MODE=400 m doctor;  assert_eq 0 "$RC" "doctor, secret reported as 400: exit 0"
FAKE_STAT_MODE=644 m doctor
assert_eq 3 "$RC" "doctor, secret reported as 644: exit 3 (EX_PREFLIGHT)"
assert_contains "$OUT" "[FAIL] secrets/cloudflare_token has mode 644; run: chmod 600 secrets/cloudflare_token" "doctor: the chmod 600 hint (same wording as ptero)"
assert_contains "$OUT" "[ok]   bash" "doctor keeps going after a failure"
FAKE_STAT_MODE=660 m doctor;  assert_eq 3 "$RC" "doctor, secret reported as 660: exit 3"
FAKE_STAT_MODE=700 m doctor;  assert_eq 3 "$RC" "doctor, secret reported as 700: exit 3 (executable is not a secret mode)"
plant_canary "$SB/secrets/cloudflare_token"
: >"$FAKE_STATE/calls.log"; FAKE_STAT_MODE=644 m doctor
assert_not_contains "$OUT$(calls)" "$CANARY" "canary: a failing secret is not printed or passed to a call"
: >"$FAKE_STATE/calls.log"; FAKE_STAT_MODE=600 m doctor
assert_not_contains "$OUT$(calls)" "$CANARY" "canary: a passing secret is not printed or passed to a call"
rm -f "$SB/secrets/cloudflare_token"
printf 'x' >"$SB/secrets/a"; chmod 600 "$SB/secrets/a"; printf 'x' >"$SB/secrets/b"; chmod 600 "$SB/secrets/b"
m doctor;  assert_contains "$OUT" "secrets/a" "doctor: one line per secret file (a)"; assert_contains "$OUT" "secrets/b" "doctor: one line per secret file (b)"
rm -f "$SB/secrets/a" "$SB/secrets/b"
echo 1 >"$FAKE_STATE/docker.compose.version.rc"
m doctor;  assert_eq 3 "$RC" "doctor: 'docker compose version' failing exits 3"; assert_contains "$OUT" "[FAIL] docker compose" "doctor: the compose failure is a FAIL line"
rm -f "$FAKE_STATE/docker.compose.version.rc"
MCCTL_PUBLIC_IPV4=999.1.1.1 m doctor
assert_eq 3 "$RC" "doctor with an invalid config value: exit 3"; assert_contains "$OUT" "[FAIL] config" "doctor: config FAIL line"
assert_contains "$OUT" "MCCTL_PUBLIC_IPV4" "doctor: the invalid key is named"; assert_contains "$OUT" "[ok]   curl" "doctor still runs the other checks"
m doctor extra;  assert_eq 2 "$RC" "doctor takes no arguments (EX_USAGE)"
out=$( (doctor_need no-such-tool-xyz "install the 'x' package") 2>&1 )
assert_eq "[FAIL] no-such-tool-xyz: not found; install the 'x' package" "$out" "doctor_need: a missing tool is a FAIL line with its hint"
out=$( (DOCTOR_FAILS=0; doctor_need bash "x"; echo "fails=$DOCTOR_FAILS") 2>&1 )
assert_eq $'[ok]   bash\nfails=0' "$out" "doctor_need: a present tool is an ok line"
sandbox_cleanup
finish

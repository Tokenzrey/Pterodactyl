#!/usr/bin/env bash
# The harness itself: the ./mcctl dispatcher, the common.sh helpers t_common.sh does not reach, the strict fakes (E1), the
# zero-assertion guard and refusals of run.sh (E2), and plant_canary (E4).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
sandbox

echo "dispatcher"
m;                 assert_eq 0 "$RC" "no arguments: exit 0";       assert_contains "$OUT" "Usage: mcctl" "no arguments: usage"
m help;            assert_eq 0 "$RC" "help: exit 0"
m --version;       assert_contains "$OUT" "mcctl 0." "--version prints the version"
m version;         assert_eq 2 "$RC" "version with no NAME reaches cmd_version: its usage, exit 2"
assert_contains "$OUT" "usage: mcctl version NAME" "and the usage names the command"
mkdir -p "$SB/servers/s1/data" && printf '%s\n' TYPE=PAPER VERSION=1.21.1 EULA=TRUE MEMORY=2G CPUS=2 HOSTNAME_SLUG=s1 >"$SB/servers/s1/server.env"
fake_server s1 s1 exited; echo exited >"$FAKE_STATE/docker.inspect"; : >"$FAKE_STATE/calls.log"
m version s1 show; assert_eq 0 "$RC" "mcctl version s1 show: exit 0"
assert_contains "$OUT" "VERSION: 1.21.1" "it prints the VERSION of s1 (cmd_version ran)"
assert_contains "$OUT" "TYPE: PAPER" "and the TYPE"
assert_eq 1 "$(count_calls 'label=mcctl.name=s1')" "and it asked Docker for s1 first (_need_server), once"
m bogus;           assert_eq 2 "$RC" "unknown command: EX_USAGE";  assert_contains "$OUT" "unknown command: bogus" "unknown command is named"
m '../etc/x';      assert_eq 2 "$RC" "path-like command name: EX_USAGE"
m --yes bogus;     assert_eq 2 "$RC" "--yes does not make a command known"
cat >"$SB/lib/zz.sh" <<'EOF'
cmd_zz() { echo "yes=$MCCTL_YES args=$*"; }
cmd_zz_y() { docker system prune; true; }
EOF
m zz a b;          assert_contains "$OUT" "yes=0 args=a b" "a lib/*.sh command is dispatched, MCCTL_YES defaults to 0"
m zz --yes a;      assert_contains "$OUT" "yes=1 args=a" "--yes anywhere sets MCCTL_YES and is removed"
m help;            assert_contains "$OUT" "zz zz-y" "usage lists the cmd_* functions found"
out=$(fail() { echo FLAGGED; }; m zz-y)
assert_contains "$out" "FLAGGED" "m fails the test when a fake saw an unmodelled call"
: >"$FAKE_STATE/calls.log"; T_UNK=0
mkdir "$SB/realish" && printf '#!/bin/sh\nexit 0\n' >"$SB/realish/docker" && chmod +x "$SB/realish/docker"
( cd "$R" && PATH="$SB/realish:$PATH" ./mcctl help ) >/dev/null 2>&1; assert_eq 4 $? "test mode refuses a docker that is not the fake"
( cd "$R" && env -u DOCKER_HOST ./mcctl help ) >/dev/null 2>&1;       assert_eq 4 $? "test mode refuses a live DOCKER_HOST"

echo "common.sh"
( die "boom" 3 ) 2>/dev/null; assert_eq 3 $? "die uses the given exit code"
( die "boom" ) 2>/dev/null;   assert_eq 1 $? "die defaults to EX_FAIL"
MCCTL_YES=1 confirm "go?" 2>/dev/null;                 assert_eq 0 $? "confirm answers yes under MCCTL_YES=1"
MCCTL_YES=0 confirm "go?" </dev/null 2>/dev/null;      assert_eq 1 $? "confirm answers no without a terminal"
mkdir_private "$SB/p/q"
assert_mode "$SB/p/q" 700 "mkdir_private: last component is 700"
assert_mode "$SB/p"   700 "mkdir_private: a parent it had to create is 700 too"
write_secret "$SB/s2" "first";  assert_eq "first" "$(cat "$SB/s2")" "write_secret writes the value"
write_secret "$SB/s2" "second"; assert_eq "second" "$(cat "$SB/s2")" "write_secret replaces the value"
assert_eq "" "$(compgen -G "$SB/s2.*")" "write_secret leaves no temp file"
write_secret "$SB/nodir/x" v 2>/dev/null; assert_eq 1 $? "write_secret into a missing directory fails"
assert_eq "a-b"  "$(slugify $'  A--B \n')"          "slug: case, runs and edges"
assert_eq "a-b"  "$(slugify $'a\tb')"               "slug: a tab separates"
assert_eq "x-y"  "$(slugify 'x/../y')"              "slug: path characters never survive"
valid_server_name "$(printf 'a%.0s' {1..40})" && pass "40 characters accepted" || fail "40 characters accepted"
valid_server_name "$(printf 'a%.0s' {1..41})" && fail "41 characters refused" || pass "41 characters refused"
valid_server_name "-ab"       && fail "leading dash refused"     || pass "leading dash refused"
valid_server_name "a/b"       && fail "slash refused"            || pass "slash refused"
valid_server_name "a.b"       && fail "dot refused"              || pass "dot refused"
valid_server_name $'ab\n'     && fail "trailing newline refused" || pass "trailing newline refused"
valid_server_name $'a\nb'     && fail "inner newline refused"    || pass "inner newline refused"

echo "strict fakes"
: >"$FAKE_STATE/calls.log"
docker compose -p mcctl-x -f "$SB/x.yaml" ps -a >/dev/null; assert_eq 0 $? "docker compose ps is known"
docker run --rm -p 25565:25565 img >/dev/null;               assert_eq 0 $? "docker run is known"
assert_eq $'docker compose -p mcctl-x -f '"$SB"$'/x.yaml ps -a\ndocker run --rm -p 25565:25565 img' "$(calls)" "calls.log: one line per call, in order"
docker exec c sh -c $'a\nb' >/dev/null
assert_eq "docker exec c sh -c a\\nb" "$(calls | tail -n 1)" "calls.log: a newline in an argument stays on one line"
printf 'abc\n' >"$FAKE_STATE/docker.compose.ps"
assert_eq "abc" "$(docker compose -p mcctl-x ps)" "canned stdout is replayed (options and compose globals ignored)"
echo 5 >"$FAKE_STATE/docker.compose.ps.rc"
docker compose ps >/dev/null; assert_eq 5 $? "canned exit status is replayed"
rm -f "$FAKE_STATE"/docker.compose.ps "$FAKE_STATE"/docker.compose.ps.rc
printf 'one\n' >"$FAKE_STATE/docker.inspect"; printf 'two\n' >"$FAKE_STATE/docker.inspect.mc-x"
assert_eq "two" "$(docker inspect mc-x)" "the longest matching canned file wins"
assert_eq "one" "$(docker inspect mc-y)" "a shorter canned file answers the rest"
: >"$FAKE_STATE/calls.log"
docker system prune -f >/dev/null 2>&1;  assert_eq 97 $? "docker: unknown subcommand exits 97"
assert_eq "UNKNOWN docker system prune -f" "$(calls)" "docker: unknown subcommand is logged as UNKNOWN"
: >"$FAKE_STATE/calls.log"
curl -s https://example.invalid >/dev/null 2>&1; assert_eq 97 $? "curl: refused with 97 (no network in tests)"
rcon-cli say hi >/dev/null 2>&1;                  assert_eq 97 $? "rcon-cli: refused with 97"
assert_eq $'UNKNOWN curl -s https://example.invalid\nUNKNOWN rcon-cli say hi' "$(calls)" "curl and rcon-cli calls are logged as UNKNOWN"
: >"$FAKE_STATE/calls.log"
ss -x >/dev/null 2>&1;                          assert_eq 97 $? "ss: a flag that is not modelled exits 97"
ss -H -ltnp 'sport = :25565' >/dev/null 2>&1;   assert_eq 97 $? "ss: a filter that is not the modelled one exits 97"
iptables -L >/dev/null 2>&1;                    assert_eq 97 $? "iptables: an operation that is not modelled exits 97"
iptables -t nat -S >/dev/null 2>&1;             assert_eq 97 $? "iptables: a table option is not modelled either"
assert_eq $'UNKNOWN ss -x\nUNKNOWN ss -H -ltnp sport = :25565\nUNKNOWN iptables -L\nUNKNOWN iptables -t nat -S' "$(calls)" "ss and iptables: each unmodelled call is logged as UNKNOWN"
: >"$FAKE_STATE/calls.log"
( PATH=/usr/bin:/bin; sandbox_cleanup() { :; }; assert_fakes_first ) >/dev/null 2>&1
assert_eq 99 $? "assert_fakes_first exits 99 when a fake is not first on PATH"
( assert_fakes_first ) >/dev/null 2>&1; assert_eq 0 $? "assert_fakes_first passes inside the sandbox"

echo "fake docker: run (C1)"
: >"$FAKE_STATE/calls.log"; rm -f -- "$FAKE_STATE"/run.stdin.* "$FAKE_STATE"/mutations "$FAKE_STATE"/docker.run.ls*
docker run --rm --network none --user 1000:1000 -v "$SB/d:/data" -w /data alpine:3.20 ls -la >/dev/null
assert_eq "docker run --rm --network none --user 1000:1000 -v $SB/d:/data -w /data alpine:3.20 ls -la" "$(calls)" "run: the whole line is logged"
printf 'listing\n' >"$FAKE_STATE/docker.run.ls"
assert_eq "listing" "$(docker run --rm --cap-drop ALL --read-only --tmpfs /tmp --pids-limit 64 alpine:3.20 ls -la)" "run: the options are skipped and the output is replayed by the word after the image"
echo 3 >"$FAKE_STATE/docker.run.ls.rc"
docker run --rm alpine:3.20 ls >/dev/null; assert_eq 3 $? "run: the status is replayed from docker.run.<command>.rc"
rm -f -- "$FAKE_STATE/docker.run.ls" "$FAKE_STATE/docker.run.ls.rc"
docker run --rm alpine:3.20 cat >/dev/null; assert_eq 0 $? "run: a command with no canned file exits 0"
printf 'payload' | docker run --rm -i --network none alpine:3.20 sh -c 'cat >/dev/null' sh x >/dev/null
assert_eq "payload" "$(<"$FAKE_STATE/run.stdin.1")" "run -i: the caller's stdin is kept as run.stdin.1"
printf 'second' | docker run --rm -i alpine:3.20 cat >/dev/null
assert_eq "second" "$(<"$FAKE_STATE/run.stdin.2")" "run -i: the next one is run.stdin.2"
docker run --rm alpine:3.20 cat </dev/null >/dev/null
assert_no_file "$FAKE_STATE/run.stdin.3" "run without -i keeps no stdin"
rm -f -- "$FAKE_STATE"/run.stdin.*
FAIL_AT=1 docker run --rm alpine:3.20 ls >/dev/null 2>&1; assert_eq 0 $? "FAIL_AT=1: a read-only run (ls) is not the failing call"
assert_no_file "$FAKE_STATE/mutations" "FAIL_AT: ls leaves no count"
FAIL_AT=1 docker run --rm alpine:3.20 rm -- x >/dev/null 2>&1; assert_eq 1 $? "FAIL_AT=1: a removing run (rm) is the first mutation and fails"
assert_eq 1 "$(<"$FAKE_STATE/mutations")" "FAIL_AT: rm is counted"
rm -f -- "$FAKE_STATE/mutations"
printf 'lost' | FAIL_AT=1 docker run -i alpine:3.20 sh -c 'cat >x' sh x >/dev/null 2>&1; assert_eq 1 $? "FAIL_AT=1: a failing run with -i fails"
assert_no_file "$FAKE_STATE/run.stdin.1" "and it keeps no stdin (it changed nothing)"
rm -f -- "$FAKE_STATE/mutations"

echo "canary"
plant_canary "$SB/c1"; c1=$CANARY
plant_canary "$SB/c2"; c2=$CANARY
[[ -n $c1 && $c1 != "$c2" ]] && pass "plant_canary: values are unique" || fail "plant_canary: values are unique" "$c1 / $c2"
assert_eq "$c2" "$(cat "$SB/c2")" "plant_canary: the value is in the file"
assert_mode "$SB/c2" 600 "plant_canary: the file is mode 600"
m version
assert_not_contains "$OUT$(calls)" "$c1" "canary pattern: absent from output and call log"

echo "run.sh"
FX=$SB/fx; mkdir "$FX" && cp -r "$REPO/mcctl" "$REPO/lib" "$REPO/tests" "$FX/"
T="source ./lib.sh"
printf '%s\npass x\nfinish\n'       "$T" >"$FX/tests/t_ok.sh"
printf '%s\nfinish\n'                "$T" >"$FX/tests/t_zero.sh"
printf 'exit 0\n'                         >"$FX/tests/t_nofinish.sh"
printf '%s\nfail x\nfinish\n'        "$T" >"$FX/tests/t_bad.sh"
printf '%s\nskip x\nfinish\n'        "$T" >"$FX/tests/t_skip.sh"
run() { OUT=$(DOCKER_HOST=unix:///nonexistent "$@" 2>&1); RC=$?; }
run bash "$FX/tests/run.sh" t_ok.sh
assert_eq 0 "$RC" "run.sh: passing file, exit 0";  assert_contains "$OUT" "1 passed, 0 failed, 0 skipped" "run.sh: summary line"
run bash "$FX/tests/run.sh" t_zero.sh
[[ $RC -ne 0 ]] && pass "run.sh: zero assertions fails" || fail "run.sh: zero assertions fails"
assert_contains "$OUT" "records zero assertions" "run.sh: names the file with zero assertions"
run bash "$FX/tests/run.sh" t_nofinish.sh
[[ $RC -ne 0 ]] && pass "run.sh: a file that never finishes fails" || fail "run.sh: a file that never finishes fails"
run bash "$FX/tests/run.sh" t_bad.sh
[[ $RC -ne 0 ]] && pass "run.sh: failed assertion fails" || fail "run.sh: failed assertion fails"
assert_contains "$OUT" "0 passed, 1 failed, 0 skipped" "run.sh: failed count"
run bash "$FX/tests/run.sh" t_skip.sh
assert_eq 0 "$RC" "run.sh: a skip is not a failure";  assert_contains "$OUT" "0 passed, 0 failed, 1 skipped" "run.sh: a skip is not a pass"
run bash "$FX/tests/run.sh" t_ok.sh t_skip.sh
assert_contains "$OUT" "1 passed, 0 failed, 1 skipped" "run.sh: counts add up over files"
OUT=$(env -u DOCKER_HOST bash "$FX/tests/run.sh" t_ok.sh 2>&1); RC=$?
assert_eq 99 "$RC" "run.sh: refuses to start without DOCKER_HOST"
OUT=$(DOCKER_HOST=unix:///var/run/docker.sock bash "$FX/tests/run.sh" t_ok.sh 2>&1); RC=$?
assert_eq 99 "$RC" "run.sh: refuses to start with a live DOCKER_HOST"
rm "$FX/tests/fakebin/docker"
run bash "$FX/tests/run.sh" t_ok.sh
assert_eq 99 "$RC" "run.sh: refuses to start when the docker fake is missing";  assert_contains "$OUT" "FATAL: docker resolves to" "run.sh: says which tool"
cp "$REPO/tests/fakebin/docker" "$FX/tests/fakebin/docker"; rm "$FX/tests/fakebin/iptables"
run bash "$FX/tests/run.sh" t_ok.sh
assert_eq 99 "$RC" "run.sh: refuses to start when the iptables fake is missing";  assert_contains "$OUT" "FATAL: iptables resolves to" "run.sh: says which tool"
cp "$REPO/tests/fakebin/iptables" "$FX/tests/fakebin/iptables"; rm "$FX/tests/fakebin/ss"
run bash "$FX/tests/run.sh" t_ok.sh
assert_eq 99 "$RC" "run.sh: refuses to start when the ss fake is missing";  assert_contains "$OUT" "FATAL: ss resolves to" "run.sh: says which tool"

sandbox_cleanup
finish

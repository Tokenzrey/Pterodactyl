#!/usr/bin/env bash
# lib/versions.sh: version_cmp (the E9 table), loader_var and reinstall_flag, and the commands version, upgrade, type and reinstall.
# Commands under test: cmd_version, cmd_upgrade, cmd_type, cmd_reinstall (cmd_modpack is in t_modpack.sh).
# The cases call the functions in a sourced subshell (fn), so a refusal ends only that subshell; `mcctl version NAME ...` through ./mcctl is
# tested in t_harness.sh.
# C1: every snapshot is snapshot_members (`docker run ... tar`, never `backup now`), into safety/, before anything is written.
# A refusal or a failure before the write changes no server.env, compose.yaml or modpack.env byte.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
for _l in "$REPO"/lib/*.sh; do [[ $_l == */common.sh ]] || source "$_l"; done
sandbox
export MCCTL_DOMAIN=mc.example.net
load_config 2>/dev/null
FX=$REPO/tests/fixtures/archives
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"   # what a snapshot's `docker run ... tar` replays

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
# HEALTH_KEY: the fake's file name for `docker inspect --format {{.State.Health.Status}}` (fakebin/docker sanitises the format)
hfmt='{{.State.Health.Status}}'
HEALTH_KEY=docker.inspect.${hfmt//[^A-Za-z0-9_-]/_}
# mk NAME STATE LINE...: servers/NAME with server.env = LINE... plus the fixed keys, its compose.yaml, and the fake Docker's answers for
# it: STATE for every inspect, a player list when running
mk() {
    local n=$1 st=$2 dir
    shift 2
    dir=$SB/servers/$n
    rm -rf -- "$dir"
    mkdir -p -- "$dir/data" "$dir/backups"
    printf '%s\n' "$@" EULA=TRUE MEMORY=2G CPUS=2 "HOSTNAME_SLUG=$n" >"$dir/server.env"
    write_compose "$n" || fail "mk $n: the fixture does not render"
    fake_server "$n" "$n" "$st"
    printf '%s\n' "$st" >"$FAKE_STATE/docker.inspect"
    rm -f -- "$FAKE_STATE/docker.exec" "$FAKE_STATE/mutations"   # mutations: the count FAIL_AT is checked against
    rm -f -- "$FAKE_STATE/docker.recreates" "$FAKE_STATE"/docker.compose.recreate.*   # the numbered compose copies of this server
    [[ $st != running ]] || printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
    reset
}
# fn CMD ARGS...: run a function of lib/ in a subshell (its die ends only that subshell) with stdin closed: OUT and RC. A call the
# fakes do not model fails the test.
fn() {
    OUT=$( ("$@") 2>&1 </dev/null ); RC=$?
    local n
    n=$(grep -c '^UNKNOWN' "$FAKE_STATE/calls.log" 2>/dev/null)
    if ((${n:-0} > ${T_UNK:-0})); then T_UNK=$n; fail "the fakes received a call they do not model" "$(grep '^UNKNOWN' "$FAKE_STATE/calls.log" | tail -n 3)"; fi
}
# at PATTERN: the line number of the first call that matches PATTERN (0 when none does)
at() { grep -n -- "$1" <<<"$(calls)" | head -n 1 | cut -d: -f1; }
envsum() { cksum <"$SB/servers/$1/server.env"; }
compsum() { cksum <"$SB/servers/$1/compose.yaml"; }
snaps() { ls "$SB/servers/$1/safety/" 2>/dev/null | grep -c "^pre-$2-" ; }   # snapshots of VERB (safety/ only)

echo "version_cmp: the E9 table"
vc() { version_cmp "$1" "$2"; assert_eq "$3" "$?" "version_cmp '$1' '$2' is $3"; }
vc 1.9 1.10 2
vc 1.10 1.9 1
vc 1.21 1.21.1 2
vc 1.21.1 1.21 1
vc 1.20 1.20.0 0
vc 1.20.0 1.20 0
vc 1.20.4 1.20 1
vc 1.20 1.20.4 2
vc 1.21.1 1.20.4 1
vc 1.20.4 1.21.1 2
vc 1.21.0 1.21 0
vc 1.0 1 0
vc 1.10.0 1.10 0
vc 1.100 1.99 1
vc 1.20.0.0 1.20 0
vc LATEST 1.21 3
vc 1.21 LATEST 3
vc SNAPSHOT 1.21 3
vc 24w14a 1.21 3
vc 1.21 24w14a 3
vc 1.21-pre1 1.21 3
vc 1.21.1-rc1 1.21.1 3
vc "" 1.21 3
vc 1.21 "" 3
vc 1..2 1.2 3
vc 1.2. 1.2 3
vc 1.2.x 1.2 3
vc 1.01 1.1 3
vc 1234567890123456789012345678901234567890 1 1

echo "loader_var and reinstall_flag: every type"
while read -r t lv rf; do
    [[ $lv == - ]] && lv=""; [[ $rf == - ]] && rf=""
    assert_eq "$lv" "$(loader_var "$t")" "loader_var $t is '$lv'"
    assert_eq "$rf" "$(reinstall_flag "$t")" "reinstall_flag $t is '$rf'"
done <<'EOF'
VANILLA       -                    -
FORGE         FORGE_VERSION        FORGE_FORCE_REINSTALL
NEOFORGE      NEOFORGE_VERSION     -
FABRIC        FABRIC_LOADER_VERSION FABRIC_FORCE_REINSTALL
QUILT         -                    -
PAPER         -                    -
PUFFERFISH    -                    FORCE_REDOWNLOAD
PURPUR        -                    FORCE_REDOWNLOAD
LEAF          -                    -
FOLIA         -                    -
SPIGOT        -                    -
BUKKIT        -                    -
AUTO_CURSEFORGE -                  -
MODRINTH      -                    -
EOF

echo "version: show, set, the downgrade rule, the modpack refusal, a failed snapshot"
mk s1 running "TYPE=PAPER" "VERSION=1.21.1"
fn cmd_version s1 show
assert_eq "VERSION: 1.21.1
TYPE: PAPER" "$OUT" "show prints VERSION and TYPE"
before=$(envsum s1)
fn cmd_version s1 set 1.20.4
assert_eq 4 "$RC" "set 1.20.4 at 1.21.1: refused (exit 4)"
assert_contains "$OUT" "older" "and the message says the version is older"
assert_eq "$before" "$(envsum s1)" "server.env is byte-identical"
assert_eq 0 "$(count_calls 'run --rm')" "no snapshot was taken for the refusal"
MCCTL_YES=1 fn cmd_version s1 set 1.20.4 --allow-downgrade
assert_eq 0 "$RC" "with --allow-downgrade (and --yes for the restart question): exit 0"
assert_contains "$(<"$SB/servers/s1/server.env")" "VERSION=1.20.4" "VERSION is now 1.20.4"
assert_contains "$(<"$SB/servers/s1/compose.yaml")" 'VERSION: "1.20.4"' "and compose.yaml renders it"
assert_eq 1 "$(snaps s1 version)" "one pre-change snapshot, in safety/"
assert_eq 1 "$(count_calls 'up -d --force-recreate$')" "the containers were recreated once"
assert_eq 1 "$(count_calls 'rcon-cli save-off')" "a running server was quiesced for the snapshot (save-off)"

mk s2 exited "TYPE=PAPER" "VERSION=1.21"
b_env=$(envsum s2)
fn cmd_version s2 set LATEST
assert_eq 4 "$RC" "LATEST against 1.21 asks confirm: without a terminal or --yes it is refused (exit 4)"
assert_contains "$OUT" "confirmation required" "and says so"
assert_eq "$b_env" "$(envsum s2)" "server.env is byte-identical"
assert_eq 0 "$(snaps s2 version)" "and no snapshot was taken"
MCCTL_YES=1 fn cmd_version s2 set LATEST
assert_eq 0 "$RC" "with --yes it goes ahead"
assert_contains "$(<"$SB/servers/s2/server.env")" "VERSION=LATEST" "VERSION=LATEST is written"
assert_eq 1 "$(count_calls 'create --force-recreate$')" "a stopped server is recreated with create --force-recreate"

mk s3 exited "TYPE=MODRINTH" "MODRINTH_MODPACK=x"
fn cmd_version s3 set 1.21.1
assert_eq 4 "$RC" "a modpack server is refused (exit 4)"
assert_contains "$OUT" "mcctl modpack s3 update" "and the message names the command"
assert_eq 0 "$(count_calls 'run --rm')" "with no snapshot"

mk s4 exited "TYPE=PAPER" "VERSION=1.21.1"
b_env=$(envsum s4); b_comp=$(compsum s4)
echo 1 >"$FAKE_STATE/docker.run.tar.rc"
fn cmd_version s4 set 1.21.2
assert_eq 1 "$RC" "a failing snapshot: exit 1"
assert_eq "$b_env" "$(envsum s4)" "server.env is byte-identical after it"
assert_eq "$b_comp" "$(compsum s4)" "compose.yaml is byte-identical"
assert_eq 0 "$(count_calls 'create --force-recreate')" "and nothing was recreated"
rm -f -- "$FAKE_STATE/docker.run.tar.rc"
fn cmd_version s4 set 'a b'
assert_eq 2 "$RC" "a version with a space: exit 2"

echo "upgrade: the order (snapshot, pull, recreate) and the version pin"
mk u1 running "TYPE=PAPER"
m --yes upgrade u1
assert_eq 0 "$RC" "upgrade on VERSION=LATEST: exit 0"
s=$(at 'run --rm'); p=$(at 'compose .*pull$'); r=$(at 'up -d --force-recreate$')
((s > 0 && s < p && p < r)) && pass "the order is snapshot ($s), docker compose pull ($p), recreate ($r)" \
    || fail "upgrade runs snapshot, pull, recreate in that order" "$(calls)"
assert_contains "$OUT" "image pulled; the version is resolved at start" "the final message says the version is resolved at start"
assert_eq 1 "$(snaps u1 upgrade)" "one snapshot, in safety/"

mk u2 exited "TYPE=PAPER"
b_env=$(envsum u2)
echo 1 >"$FAKE_STATE/docker.compose.pull.rc"
m --yes upgrade u2 --to 1.21.5
assert_eq 1 "$RC" "a failed pull: exit 1"
assert_eq "$b_env" "$(envsum u2)" "and server.env is byte-identical (the pin is written after the pull)"
assert_eq 0 "$(count_calls 'create --force-recreate')" "nothing was recreated"
rm -f -- "$FAKE_STATE/docker.compose.pull.rc"
m --yes upgrade u2 --to 1.21.4
assert_eq 0 "$RC" "--to 1.21.4 on a stopped server: exit 0"
assert_contains "$(<"$SB/servers/u2/server.env")" "VERSION=1.21.4" "VERSION is pinned to 1.21.4 before the recreate"
assert_contains "$(<"$SB/servers/u2/compose.yaml")" 'VERSION: "1.21.4"' "and compose.yaml renders it"

mk u3 exited "TYPE=PAPER" "VERSION=1.21.1"
m upgrade u3 --to 1.20.4
assert_eq 4 "$RC" "--to an older version is the downgrade rule: refused (exit 4)"
assert_eq 0 "$(count_calls 'run --rm')" "with no snapshot"
m upgrade u3 --to 1.20.4 --allow-downgrade
assert_eq 0 "$RC" "with --allow-downgrade: exit 0"

mk u4 exited "TYPE=AUTO_CURSEFORGE"
m upgrade u4
assert_eq 4 "$RC" "a modpack server is refused (exit 4): the pack decides the version"
assert_contains "$OUT" "mcctl modpack u4 update" "and the message names the command"

mk u6 exited "TYPE=PAPER" "VERSION=1.21.1"
b_env=$(envsum u6); b_comp=$(compsum u6)
echo 1 >"$FAKE_STATE/docker.run.tar.rc"
m --yes upgrade u6 --to 1.21.4
assert_eq 1 "$RC" "upgrade with a failing snapshot: exit 1"
assert_eq "$b_env" "$(envsum u6)" "server.env is byte-identical"
assert_eq "$b_comp" "$(compsum u6)" "compose.yaml is byte-identical"
assert_eq 0 "$(count_calls 'pull$')" "no pull was run"
rm -f -- "$FAKE_STATE/docker.run.tar.rc"

mk u5 running "TYPE=PAPER" "VERSION=1.21.1"
FAIL_AT=2 m --yes upgrade u5 --to 1.21.4
assert_eq 1 "$RC" "the recreate fails (second mutating call): exit 1"
assert_contains "$OUT" "run the same command again" "the message says to run it again"

echo "type: the switch, the jars, the loader variable, the refusals"
mk t1 exited "TYPE=FORGE" "FORGE_VERSION=47.2.0"
printf '0\n' >"$FAKE_STATE/docker.run.sh"
m type t1 set FABRIC
assert_eq 0 "$RC" "FORGE to FABRIC with no jars: exit 0"
assert_contains "$(<"$SB/servers/t1/server.env")" "TYPE=FABRIC" "TYPE=FABRIC"
assert_eq 0 "$(grep -c '^FORGE_VERSION=' "$SB/servers/t1/server.env")" "a stale FORGE_VERSION is removed"
assert_eq 0 "$(grep -c 'FORGE_VERSION' "$SB/servers/t1/compose.yaml")" "and is not in compose.yaml"
m type t1 set FABRIC --loader-version 0.16.9
assert_eq 0 "$RC" "with --loader-version 0.16.9: exit 0"
assert_contains "$(<"$SB/servers/t1/server.env")" "FABRIC_LOADER_VERSION=0.16.9" "FABRIC_LOADER_VERSION=0.16.9 is written"
m type t1 set PAPER --loader-version 1.0
assert_eq 2 "$RC" "--loader-version for PAPER, which has no loader variable: exit 2"
assert_contains "$OUT" "no loader-version variable" "and says so"

mk t2 exited "TYPE=FORGE"
printf '2\n' >"$FAKE_STATE/docker.run.sh"
b_env=$(envsum t2)
m type t2 set FABRIC
assert_eq 4 "$RC" "FORGE to FABRIC with two jars in mods/: refused (exit 4)"
assert_contains "$OUT" "2 jar(s)" "the message gives the count"
assert_eq "$b_env" "$(envsum t2)" "and server.env is unchanged"
m --yes type t2 set FABRIC
assert_eq 0 "$RC" "with --yes the switch goes ahead: exit 0"

mk t3 exited "TYPE=PAPER"
printf '3\n' >"$FAKE_STATE/docker.run.sh"
m type t3 set QUILT
assert_eq 4 "$RC" "PAPER to QUILT with three jars in plugins/: refused (exit 4)"
assert_contains "$OUT" "plugins/" "the message names the folder"
MCCTL_YES=1 m type t3 set QUILT
assert_eq 0 "$RC" "MCCTL_YES=1 goes ahead"

mk t4 exited "TYPE=VANILLA"
m type t4 set AUTO_CURSEFORGE
assert_eq 4 "$RC" "AUTO_CURSEFORGE is set only by mcctl modpack (exit 4)"
m type t4 set modrinth
assert_eq 4 "$RC" "MODRINTH likewise, whatever the case"
m type t4 set SPONGE
assert_eq 2 "$RC" "an unknown type: exit 2"
assert_contains "$OUT" "unknown type" "and the message says so"

mk t5 exited "TYPE=VANILLA"
echo 1 >"$FAKE_STATE/docker.run.tar.rc"
b_env=$(envsum t5)
m type t5 set PAPER
assert_eq 1 "$RC" "a failing snapshot before a type change: exit 1"
assert_eq "$b_env" "$(envsum t5)" "server.env is byte-identical"
rm -f -- "$FAKE_STATE/docker.run.tar.rc"

mk t6 exited "TYPE=AUTO_CURSEFORGE"
m type t6 set PAPER
assert_eq 4 "$RC" "a modpack server: type set refuses (exit 4), the pack is removed with mcctl modpack remove"
assert_contains "$OUT" "mcctl modpack t6 remove" "and the message names the command"

echo "reinstall: the flag cycle, the health wait, the timeout, a stopped server"
mk r1 exited "TYPE=PAPER"
m reinstall r1
assert_eq 2 "$RC" "a type with no reinstall flag: exit 2"
assert_contains "$OUT" "no reinstall flag" "and says so"
assert_eq 0 "$(count_calls 'create --force-recreate')" "nothing was recreated"

# Two recreates (R10): the first carries the flag, the wait follows, the second recreate has no flag, so the container's environment
# never keeps it. The recreates are docker.compose.recreate.1.yml and .2.yml (tests/fakebin/docker).
mk r2 running "TYPE=FORGE" "FORGE_VERSION=47.2.0"
printf 'starting\nhealthy\n' >"$FAKE_STATE/$HEALTH_KEY.seq"
m --yes reinstall r2 --timeout 5   # a short timeout: a missing answer fails in seconds, not after the default 600
assert_eq 0 "$RC" "running FORGE: the health goes starting, then healthy: exit 0"
assert_eq 2 "$(count_calls 'up -d --force-recreate$')" "two recreates: the one with the flag and the one without"
assert_contains "$(<"$FAKE_STATE/docker.compose.recreate.1.yml")" 'FORGE_FORCE_REINSTALL: "TRUE"' "the first recreate holds the flag"
assert_eq 0 "$(grep -c 'FORCE_REINSTALL' "$FAKE_STATE/docker.compose.recreate.2.yml")" "the second recreate has no *_FORCE_REINSTALL line"
assert_eq 0 "$(grep -c 'FORCE_REINSTALL\|FORCE_REDOWNLOAD\|REMOVE_OLD_MODS' "$SB/servers/r2/server.env" "$SB/servers/r2/compose.yaml" | awk -F: '{s+=$2} END {print s+0}')" "no flag in the final server.env or compose.yaml"
L=$(calls); up1=$(grep -n 'up -d --force-recreate$' <<<"$L" | sed -n 1p | cut -d: -f1); up2=$(grep -n 'up -d --force-recreate$' <<<"$L" | sed -n 2p | cut -d: -f1)
hp=$(grep -nF 'State.Health.Status' <<<"$L" | head -n 1 | cut -d: -f1)
((up1 > 0 && up1 < hp && hp < up2)) && pass "the order is recreate ($up1), the health wait ($hp), recreate again ($up2)" \
    || fail "recreate, wait, recreate again" "$L"
printf 'running|healthy|r2.mc.example.net|itzg/minecraft-server|2026-10-24T01:02:03.5Z|%s\n' "$(config_hash r2)" >"$FAKE_STATE/docker.inspect"
m status r2
assert_contains "$OUT" "config:    current" "status then says config: current (the one-shot key does not make it pending)"

mk r3 running "TYPE=FABRIC"
printf 'starting\n' >"$FAKE_STATE/$HEALTH_KEY"
m --yes reinstall r3 --timeout 1
assert_eq 1 "$RC" "a health that stays starting: the timeout exits 1"
assert_contains "$OUT" "not healthy after 1 s" "and says so"
assert_eq 2 "$(count_calls 'up -d --force-recreate$')" "the second recreate still runs after the timeout"
assert_eq 0 "$(grep -c FORCE_REINSTALL "$SB/servers/r3/server.env" "$SB/servers/r3/compose.yaml" | awk -F: '{s+=$2} END {print s+0}')" "the flag is removed from both files anyway"
assert_eq 0 "$(grep -c FABRIC_FORCE_REINSTALL "$FAKE_STATE/docker.compose.recreate.2.yml")" "and the second recreate does not carry it"
rm -f -- "$FAKE_STATE/$HEALTH_KEY"

mk r4 exited "TYPE=PURPUR"
b=$(envsum r4)
m reinstall r4
assert_eq 4 "$RC" "a stopped server is refused (exit 4): reinstall needs a running server to finish"
assert_contains "$OUT" "start it first" "and the message says so"
assert_eq "$b" "$(envsum r4)" "server.env is byte-identical"
assert_eq 0 "$(count_calls 'create --force-recreate')" "nothing was recreated"

mk r5 running "TYPE=FORGE"
FAIL_AT=1 m --yes reinstall r5 --timeout 5
assert_eq 1 "$RC" "the first recreate fails: exit 1"
assert_eq 2 "$(count_calls 'up -d --force-recreate$')" "the second recreate is still attempted"
assert_eq 0 "$(grep -c FORCE_REINSTALL "$SB/servers/r5/server.env" "$SB/servers/r5/compose.yaml" | awk -F: '{s+=$2} END {print s+0}')" "the flag is still removed from both files"

mk r6 running "TYPE=FORGE"
printf 'starting\nhealthy\n' >"$FAKE_STATE/$HEALTH_KEY.seq"
# mutations of a running recreate: up (1), up again (2): FAIL_AT=2 is the second up
FAIL_AT=2 m --yes reinstall r6 --timeout 5
assert_eq 1 "$RC" "the second recreate fails: exit 1"
assert_eq 0 "$(grep -c FORCE_REINSTALL "$SB/servers/r6/server.env" "$SB/servers/r6/compose.yaml" | awk -F: '{s+=$2} END {print s+0}')" "the flag is removed from both files even then"
assert_contains "$OUT" "run the same command again" "and the message says to run it again"

mk r7 running "TYPE=PURPUR"
printf 'starting\nhealthy\n' >"$FAKE_STATE/$HEALTH_KEY.seq"
m --yes reinstall r7 --timeout 5
assert_eq 0 "$RC" "running PURPUR, healthy: exit 0"
assert_contains "$(<"$FAKE_STATE/docker.compose.recreate.1.yml")" 'FORCE_REDOWNLOAD: "TRUE"' "the first recreate holds FORCE_REDOWNLOAD"
assert_eq 0 "$(grep -c 'FORCE_REDOWNLOAD\|FORCE_REINSTALL' "$FAKE_STATE/docker.compose.recreate.2.yml")" "the second recreate has no FORCE_REDOWNLOAD or *_FORCE_REINSTALL line"

sandbox_cleanup
finish

#!/usr/bin/env bash
# lib/worlds.sh (`mcctl world`): valid_world_name, the world list and info, use, new, rename, delete, reset, backup, export, restore,
# import, seed and datapack. Covers the safety archive before every removal (E7 by FAIL_AT), the autosave sequence of a live backup
# (Review Focus 6, a signal included), hostile archives refused before any removal (E8, C2), E4 (the RCON password is in no output
# or call), E12 (safety/ and backups/ are 700, archives 600) and E1 (the ordered call log). The helper runs the world commands, so the calls the
# fake logs are `docker run ... sh -c SCRIPT`; tags() turns the call log into short words for the ordered assertions.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
for f in "$REPO"/lib/*.sh; do [[ $f == */common.sh ]] || source "$f"; done
sandbox
export MCCTL_DOMAIN=mc.example.net
FX=$REPO/tests/fixtures/archives

reset() { : >"$FAKE_STATE/calls.log"; rm -f -- "$FAKE_STATE"/run.stdin.*; T_UNK=0; }
# canned_run CMD RC [OUT]: the helper's answer to CMD (the word after the image): exit RC, and OUT on stdout when given
canned_run() {
    rm -f -- "$FAKE_STATE/docker.run.$1" "$FAKE_STATE/docker.run.$1.rc"
    printf '%s\n' "$2" >"$FAKE_STATE/docker.run.$1.rc"
    if (($# >= 3)); then printf '%s' "$3" >"$FAKE_STATE/docker.run.$1"; fi
}
FMT_LABEL='{{index .Config.Labels "mcctl.config_hash"}}'
# canned_label HASH: the answer of `docker inspect` for the config label (the state answer is the plain docker.inspect file)
canned_label() { printf '%s\n' "$1" >"$FAKE_STATE/docker.inspect.${FMT_LABEL//[^A-Za-z0-9_-]/_}"; }
# the docker run line of every helper call for s1, with and without -i (data_pipe)
HELPER="docker run --rm --network none --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp --pids-limit 64 --memory 128m -v $SB/servers/s1/data:/data -w /data alpine:3.20"
HELPERI="docker run --rm -i --network none --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp --pids-limit 64 --memory 128m -v $SB/servers/s1/data:/data -w /data alpine:3.20"
# tags: the call log as short words, one per line; the staging folder of an import reads STAGE
tags() {
    local l
    while IFS= read -r l; do
        case $l in
            "docker ps -a -q --filter label=mcctl.name="*) echo "name?" ;;
            "docker inspect --format {{.State.Status}} "*) echo "state" ;;
            "docker inspect --format {{index"*) echo "label" ;;
            "docker exec -i mc-s1 rcon-cli "*) echo "rcon ${l#docker exec -i mc-s1 rcon-cli }" ;;
            "docker compose -p mcctl-s1 "*" create --force-recreate") echo "create" ;;
            "$HELPER sh -c for d in "*) echo "scan" ;;
            "$HELPER sh -c "*) echo "sh" ;;
            "$HELPER tar -czf - -- "*) echo "tar-out ${l#"$HELPER tar -czf - -- "}" ;;
            "$HELPERI tar -xzf - "*) echo "tar-in ${l#"$HELPERI tar -xzf - "}" ;;
            "$HELPERI sh -c "*) echo "pipe-sh" ;;
            "$HELPER "*) echo "helper ${l#"$HELPER "}" ;;
            *) echo "other: $l" ;;
        esac
    done < <(calls) | sed -E 's/\.mcctl-import-[0-9]+/STAGE/g'
}
# mk NAME STATE [LEVEL]: a server folder (server.env, compose.yaml, RCON secret, data/, backups/) and Docker's answers for it
mk() {
    local n=$1 st=${2:-exited} lvl=${3-}
    mkdir -p "$SB/servers/$n/data" "$SB/servers/$n/backups" "$SB/secrets"
    printf 'TYPE=PAPER\nVERSION=LATEST\nMEMORY=4G\nCPUS=2\nHOSTNAME_SLUG=%s\nEULA=TRUE\n' "$n" >"$SB/servers/$n/server.env"
    [[ -z $lvl ]] || printf 'LEVEL=%s\n' "$lvl" >>"$SB/servers/$n/server.env"
    chmod 600 "$SB/servers/$n/server.env"
    write_compose "$n" && chmod 600 "$SB/servers/$n/compose.yaml"
    printf 'test-rcon-pass-%s\n' "$n" >"$SB/secrets/rcon-$n"; chmod 600 "$SB/secrets/rcon-$n"
    fake_server "$n" "$n" "$st"
    printf '%s\n' "$st" >"$FAKE_STATE/docker.inspect"
    canned_label "$(config_hash "$n")"
    reset
}
# the scan of data/ (WORLD_SCAN): world and bonus hold level.dat; world_nether and old do not
ROWS=$'world\t1\t120\t1729771200\nworld_nether\t0\t-\t-\nbonus\t1\t50\t1729000000\nold\t0\t-\t-'
# the same with bonus's nether, for the rename of a world that is not active
ROWS2=$'world\t1\t120\t1729771200\nworld_nether\t0\t-\t-\nbonus\t1\t50\t1729000000\nbonus_nether\t0\t-\t-'
scan_default() { canned_run sh 0 "$ROWS"; }
# E7: FAIL_AT=N for one command: the mutation count is reset first (the fake counts across the whole sandbox)
fail_at() { local n=$1; shift; rm -f -- "$FAKE_STATE/mutations"; FAIL_AT=$n m "$@"; }
# the safety archive of the group NAME (the most recent one) and how many there are
# arch_in FOLDER W: the first world-W archive in servers/s1/FOLDER (empty when none); count_in FOLDER W: how many there are
arch_in() { ls "$SB/servers/s1/$1"/world-"$2"-*.tar.gz 2>/dev/null | head -n 1; }
count_in() { ls "$SB/servers/s1/$1" 2>/dev/null | grep -c "^world-$2-" || true; }
safety_of() { arch_in safety "$1"; }
count_safety() { count_in safety "$1"; }
# drop_in FOLDER W: remove the world-W archives of servers/s1/FOLDER (if any) so that the next test starts clean
drop_in() { rm -f -- "$SB/servers/s1/$1"/world-"$2"-*.tar.gz; }
drop_safety() { drop_in safety "$1"; }

echo "valid_world_name (C5)"
for w in world bonus-2 a.b Z9_x; do valid_world_name "$w"; assert_eq 0 "$?" "$w is a world name"; done
for w in plugins mods backups config datapacks x_nether x_the_end -x .hidden "" "$(printf 'a%.0s' {1..65})"; do
    valid_world_name "$w"; assert_eq 1 "$?" "${w:0:20} is refused"
done
valid_world_name "$(printf 'a%.0s' {1..64})"; assert_eq 0 "$?" "64 characters is the longest"
valid_world_name "a/b"; assert_eq 1 "$?" "a slash is refused"

echo "WORLD_SCAN, run locally on a folder (the script the helper runs in data/)"
D=$SB/tmp/scan-data
rm -rf -- "$D"; mkdir -p "$D/world/region" "$D/world_nether/DIM-1" "$D/bonus" "$D/.hidden" "$D/mods"
echo level >"$D/world/level.dat"; echo level >"$D/bonus/level.dat"; echo x >"$D/readme.txt"; echo level >"$D/.hidden/level.dat"
scan=$(cd "$D" && sh -c "$WORLD_SCAN")
assert_contains "$scan" $'world\t1\t' "world holds level.dat: level 1, a size, an mtime"
assert_contains "$scan" $'bonus\t1\t' "bonus too"
assert_contains "$scan" $'world_nether\t0\t-\t-' "world_nether has no level.dat: level 0"
assert_contains "$scan" $'mods\t0\t-\t-' "a folder with no level.dat is listed as 0"
assert_not_contains "$scan" "readme" "files are not listed"
assert_not_contains "$scan" "hidden" "hidden folders are not listed"
assert_eq 4 "$(wc -l <<<"$scan" | tr -d ' ')" "one line per folder"
mkdir -p "$SB/tmp/emptyd"
assert_eq "" "$(cd "$SB/tmp/emptyd" && sh -c "$WORLD_SCAN")" "an empty data/ prints nothing (no literal */ row)"
rm -rf -- "$D" "$SB/tmp/emptyd"

echo "list (E1, E4): the active world is marked, newest first, no registry read"
mk s1 exited
scan_default
reset; m world s1 list
assert_eq 0 "$RC" "list exits 0"
assert_contains "$OUT" "* world" "the active world (the default LEVEL) is marked"
assert_contains "$OUT" "  bonus" "the other world is listed unmarked"
assert_not_contains "$OUT" "old" "a folder without level.dat is ignored"
assert_not_contains "$OUT" "world_nether" "a sibling without level.dat is ignored"
pos_w=$(grep -n ' world ' <<<"$OUT" | cut -d: -f1); pos_b=$(grep -n ' bonus ' <<<"$OUT" | cut -d: -f1)
((pos_w < pos_b)) && pass "newest first: world (1729771200) before bonus (1729000000)" || fail "newest first" "$OUT"
assert_eq "name?
scan" "$(tags)" "calls: the name check, then the one scan (no state: list reads only)"
reset; assert_eq "world
bonus" "$(world_dirs s1)" "world_dirs: the folders that hold level.dat, one per line (old and world_nether are not worlds)"
rm -f -- "$SB/servers/s1/server.env" "$SB/servers/s1/compose.yaml"
reset; m world s1 list
assert_eq 0 "$RC" "list still works with server.env and compose.yaml gone (nothing is read from a registry)"
assert_contains "$OUT" "* world" "and world, the default, is the active one then"
mk s1 exited bonus
scan_default
reset; m world s1 list
assert_contains "$OUT" "* bonus" "LEVEL=bonus in server.env marks bonus"
assert_eq bonus "$(server_env_get s1 LEVEL)" "server_env_get: a key that is set prints its value"; server_env_get s1 SEED >/dev/null; assert_eq 1 "$?" "server_env_get: a key that is absent exits 1"
mk s1 exited "bad/name"
scan_default
reset; m world s1 list
assert_eq 3 "$RC" "a LEVEL that is not a world name: EX_PREFLIGHT"
assert_contains "$OUT" "not a world name" "and it says so"
mk s1 exited
scan_default

echo "info"
reset; m world s1 info
assert_eq 0 "$RC" "info of the active world"
assert_contains "$OUT" "world:    world" "names the world"
assert_contains "$OUT" "path:     $SB/servers/s1/data/world" "gives its host path"
assert_contains "$OUT" "size:     120 KiB" "its size"
assert_contains "$OUT" "siblings: world_nether" "the sibling that exists"
assert_contains "$OUT" "active:   yes" "and that it is active"
reset; m world s1 info bonus
assert_contains "$OUT" "active:   no (mcctl world s1 use bonus)" "another world: not active, with the command"
reset; m world s1 info nope
assert_eq 1 "$RC" "info of a missing world: exit 1"
assert_contains "$OUT" "no world nope in s1" "and says so"

echo "use (E1): LEVEL in server.env, then apply_pending; server.properties is never written"
mk s1 exited
scan_default
reset; m world s1 use bonus
assert_eq 0 "$RC" "use bonus exits 0"
assert_contains "$(<"$SB/servers/s1/server.env")" "LEVEL=bonus" "LEVEL=bonus is written to server.env"
assert_no_file "$SB/servers/s1/data/server.properties" "server.properties is not created"
assert_eq "name?
state
scan
label
state
create" "$(tags)" "calls: check, state, scan, the config label, state, then create --force-recreate (stopped)"
mk s1 exited
scan_default
reset; m world s1 use nope
assert_eq 1 "$RC" "use of a missing world: exit 1"
assert_contains "$OUT" "mcctl world s1 new nope --use" "and says how to make it"
assert_eq "name?
state
scan" "$(tags)" "no change: check, state, scan"
mk s1 running
scan_default
reset; m world s1 use bonus
assert_eq 4 "$RC" "use on a running server: exit 4"
assert_contains "$OUT" "mcctl stop s1" "names mcctl stop"
assert_eq "name?
state" "$(tags)" "and nothing else is asked or changed"
mk s1 exited
scan_default

echo "new (C6, E1): the settings are written; LEVEL only with --use; an existing name and a bad value change nothing"
mk s1 exited
scan_default
printf '{"a": 1,\n "b": "x"}\n' >"$SB/tmp/gen.json"
reset; m world s1 new nether2 --seed -42 --type minecraft:flat --hardcore --datapacks-enable vanilla,file/a.zip --datapacks-disable c --generator-settings "$SB/tmp/gen.json"
assert_eq 0 "$RC" "new without --use exits 0"
env_now=$(<"$SB/servers/s1/server.env")
assert_contains "$env_now" "SEED=-42" "SEED: a negative seed"
assert_contains "$env_now" "LEVEL_TYPE=minecraft:flat" "LEVEL_TYPE"
assert_contains "$env_now" "HARDCORE=TRUE" "HARDCORE=TRUE"
assert_contains "$env_now" "INITIAL_ENABLED_PACKS=vanilla,file/a.zip" "the enabled packs"
assert_contains "$env_now" "INITIAL_DISABLED_PACKS=c" "the disabled packs"
assert_contains "$env_now" 'GENERATOR_SETTINGS={"a":1,"b":"x"}' "GENERATOR_SETTINGS is stored as compact JSON"
assert_not_contains "$env_now" "LEVEL=" "without --use, LEVEL is not written"
assert_contains "$OUT" "is not the active world" "and it says how to switch"
assert_contains "$OUT" "config pending: mcctl apply s1" "the settings are pending"
assert_not_contains "$(tags)" "create" "no recreate without --use"
mk s1 exited
scan_default
reset; m world s1 new nether3 --use --seed "hello world"
assert_eq 0 "$RC" "new --use exits 0"
assert_contains "$(<"$SB/servers/s1/server.env")" "LEVEL=nether3" "--use writes LEVEL"
assert_contains "$(<"$SB/servers/s1/server.env")" "SEED=hello world" "a text seed"
assert_contains "$(tags)" "create" "and applies: the container is recreated"
mk s1 exited
scan_default
printf 'not json\n' >"$SB/tmp/bad.json"; before=$(cat "$SB/servers/s1/server.env")
reset; m world s1 new nether4 --seed 1 --generator-settings "$SB/tmp/bad.json"
assert_eq 2 "$RC" "a settings file that is not JSON: EX_USAGE"
assert_contains "$OUT" "not JSON" "and says so"
assert_eq "$before" "$(cat "$SB/servers/s1/server.env")" "server.env is as it was (nothing written)"
assert_not_contains "$(calls)" "docker run" "and no helper call"
reset; m world s1 new bonus
assert_eq 4 "$RC" "an existing name is refused: EX_REFUSED"
assert_contains "$OUT" "already exists" "and says so"
reset; m world s1 new plugins
assert_eq 2 "$RC" "a reserved name is refused: EX_USAGE"
reset; m world s1 new nether5 --seed
assert_eq 2 "$RC" "--seed with no value: EX_USAGE"
reset; m world s1 new nether6 --datapacks-enable "a b"
assert_eq 2 "$RC" "a pack list with a space is refused"
mk s1 running
reset; m world s1 new nether7
assert_eq 4 "$RC" "new on a running server: exit 4"
assert_contains "$OUT" "mcctl stop s1" "names mcctl stop"
assert_eq "name?
state" "$(tags)" "and only the checks are made"
mk s1 exited
scan_default

echo "rename (E1): the siblings move first, the world last; LEVEL follows when the world is active; an existing target is refused"
mk s1 exited
canned_run sh 0 "$ROWS2"
reset; m world s1 rename bonus bonus2
assert_eq 0 "$RC" "rename bonus bonus2 exits 0"
assert_eq "name?
state
scan
scan
helper mv -- bonus_nether bonus2_nether
helper mv -- bonus bonus2" "$(tags)" "the order: two scans, the sibling moved, then the world"
assert_not_contains "$(<"$SB/servers/s1/server.env")" "LEVEL=" "LEVEL is not written when the world is not active"
for n in 3 4; do
    mk s1 exited; canned_run sh 0 "$ROWS2"
    reset; fail_at "$n" world s1 rename bonus bonus2
    assert_eq 1 "$RC" "E7: rename with the docker run $n failing (a move): exit 1"
    assert_contains "$OUT" "mcctl world s1 list shows what is left" "  and it says what is left"
done
mk s1 exited; canned_run sh 0 "$ROWS2"
reset; m world s1 rename bonus bonus2
assert_eq 0 "$RC" "E7: the same rename, run again, completes"
mk s1 exited world
scan_default
reset; m world s1 rename world world2
assert_eq 0 "$RC" "rename of the active world exits 0"
assert_contains "$(<"$SB/servers/s1/server.env")" "LEVEL=world2" "LEVEL follows the active world"
assert_contains "$(tags)" "create" "and the container is recreated with it"
mk s1 exited
scan_default
reset; m world s1 rename bonus world
assert_eq 4 "$RC" "rename onto an existing name: exit 4"
assert_contains "$OUT" "already exists" "and says so"
assert_not_contains "$(tags)" "helper mv" "no move"
reset; m world s1 rename nope nope2
assert_eq 1 "$RC" "rename of a missing world: exit 1"
mk s1 exited
scan_default

echo "delete (E7, E1): refuses the active world; the verified safety archive first; a refused confirm removes nothing"
mk s1 exited
scan_default
canned_run tar 0
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"
reset; m --yes world s1 delete world
assert_eq 4 "$RC" "delete of the active world: exit 4"
assert_contains "$OUT" "active world" "and says so"
assert_not_contains "$(tags)" "helper" "no archive and no removal"
reset; m --yes world s1 delete bonus
assert_eq 0 "$RC" "delete bonus (not active) exits 0"
assert_eq "name?
state
scan
state
tar-out bonus
helper rm -rf -- bonus" "$(tags)" "the order: checks, scan, the archive of the group, then the removal"
safety=$(safety_of bonus)
assert_file "$safety" "a world-bonus-<UTC>.tar.gz archive is in safety/"
assert_eq 0 "$(count_in backups bonus)" "and none is in backups/ (the folder prune reads)"
assert_mode "$SB/servers/s1/safety" 700 "E12: safety/ is 700"
assert_mode "$safety" 600 "E12: the archive is 600"
assert_contains "$OUT" "the copy is in" "the output names the copy"
# prune reads backups/ only: with PRUNE_BACKUPS_COUNT=0 its archives go and the safety archive stays
printf 'PRUNE_BACKUPS_COUNT=0\n' >"$SB/servers/s1/backup.env"
: >"$SB/servers/s1/backups/s1-20260101T000000Z.tar.gz"; : >"$SB/servers/s1/backups/s1-20260102T000000Z.tar.gz"
reset; m backup s1 prune
assert_eq 0 "$RC" "backup s1 prune with PRUNE_BACKUPS_COUNT=0 exits 0"
assert_eq 0 "$(ls "$SB/servers/s1/backups" | wc -l | tr -d ' ')" "the backups/ archives are removed, as before"
assert_file "$safety" "and the safety archive in safety/ is still there"
rm -f -- "$SB/servers/s1/backup.env"
mk s1 exited
scan_default
reset; m world s1 delete bonus
assert_eq 4 "$RC" "without --yes there is no terminal to confirm on: exit 4"
assert_not_contains "$(tags)" "helper rm" "a refused confirm removes nothing"
assert_file "$(safety_of bonus)" "and the copy is kept"
drop_safety bonus
mk s1 exited
scan_default
echo 1 >"$FAKE_STATE/docker.run.tar.rc"
reset; m --yes world s1 delete bonus
assert_eq 1 "$RC" "a failing archive: exit 1"
assert_not_contains "$(tags)" "helper rm" "with the archive failing there is NO removal call"
assert_eq 0 "$(count_safety bonus)" "and the archive does not exist"
rm -f -- "$FAKE_STATE/docker.run.tar.rc"
mk s1 exited
scan_default
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"
for n in 1 2 3; do
    reset; fail_at "$n" --yes world s1 delete bonus
    assert_eq 1 "$RC" "E7: delete with the docker run $n failing (FAIL_AT=$n): exit 1"
    drop_safety bonus
done
reset; fail_at 3 --yes world s1 delete bonus
assert_contains "$(tags)" "helper rm -rf -- bonus" "E7: FAIL_AT=3 is the removal: it was attempted and failed"
reset; m --yes world s1 delete bonus
assert_eq 0 "$RC" "E7: a re-run completes"
drop_safety bonus
mk s1 exited
scan_default

echo "reset (E7): the group of the active world is copied, then removed; the next start makes a new one"
mk s1 exited
scan_default
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"
reset; m --yes world s1 reset
assert_eq 0 "$RC" "reset of the active world exits 0"
assert_contains "$OUT" "makes a new world at its next start" "and says what happens next"
assert_contains "$(tags)" "helper rm -rf -- world" "the group is removed"
assert_file "$(safety_of world)" "reset: the copy is in safety/"
assert_eq 0 "$(count_in backups world)" "and none is in backups/"
drop_safety world
reset; fail_at 2 --yes world s1 reset
assert_eq 1 "$RC" "E7: reset with the archive failing (FAIL_AT=2): exit 1"
assert_not_contains "$(tags)" "helper rm" "and the world is not removed"
drop_safety world
reset; m --yes world s1 reset nope
assert_eq 1 "$RC" "reset of a missing world: exit 1"

echo "backup and export (E12, E4): on a stopped server; the default name; OUT must not exist"
mk s1 exited
scan_default
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"
reset; m world s1 backup bonus
assert_eq 0 "$RC" "backup bonus exits 0"
out=$(arch_in backups bonus)
assert_file "$out" "the default name is backups/world-bonus-<UTC>.tar.gz"
assert_eq "name?
scan
state
tar-out bonus" "$(tags)" "calls: the checks, the scan, the state, the archive (a stopped server needs no RCON)"
reset; m world s1 export bonus "$out"
assert_eq 4 "$RC" "export onto an existing file: exit 4"
assert_contains "$OUT" "already exists" "and says so"
reset; m world s1 export bonus "$SB/tmp/exported.tar.gz"
assert_eq 0 "$RC" "export to a new OUT exits 0"
assert_file "$SB/tmp/exported.tar.gz" "the export is written"
tar -tzf "$SB/tmp/exported.tar.gz" >/dev/null 2>&1; assert_eq 0 "$?" "and it reads back with tar -tzf (verified)"
reset; m world s1 export bonus
assert_eq 2 "$RC" "export without OUT: EX_USAGE"
reset; m world s1 backup --out "$SB/tmp/bk.tar.gz" nope
assert_eq 1 "$RC" "backup of a missing world: exit 1"
assert_no_file "$SB/tmp/bk.tar.gz" "and no archive is left"
rm -f -- "$SB/tmp/exported.tar.gz" "$out"

echo "backup on a live server (Review Focus 6): save-off, save-all flush, the archive, save-on, in that order"
mk s1 running
scan_default
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"
plant_canary "$SB/secrets/rcon-s1"; rcon_canary=$CANARY
live_seq="name?
scan
state
rcon save-off
rcon save-all flush
tar-out bonus
rcon save-on"
reset; m world s1 backup bonus
assert_eq 0 "$RC" "backup bonus on a running server exits 0"
assert_eq "$live_seq" "$(tags)" "the order: save-off, save-all flush, the archive, save-on"
assert_not_contains "$OUT$(calls)" "$rcon_canary" "E4: the RCON password is in no output and no call"
assert_file "$(arch_in backups bonus)" "the live backup is written to backups/"
drop_in backups bonus
echo 1 >"$FAKE_STATE/docker.run.tar.rc"
reset; m world s1 backup bonus
assert_eq 1 "$RC" "a failing tar on a live server: exit 1"
assert_eq "$live_seq" "$(tags)" "a failing tar still sends save-on (the EXIT trap)"
assert_eq 0 "$(count_in backups bonus)" "and no archive is left"
rm -f -- "$FAKE_STATE/docker.run.tar.rc"
echo 1 >"$FAKE_STATE/docker.exec.mc-s1.rcon-cli.save-off.rc"
reset; m world s1 backup bonus
assert_eq 1 "$RC" "a failing save-off: exit 1"
assert_contains "$OUT" "autosave state unknown: run mcctl rcon s1 save-on" "the message about autosave"
assert_eq "name?
scan
state
rcon save-off" "$(tags)" "no tar when save-off fails"
rm -f -- "$FAKE_STATE/docker.exec.mc-s1.rcon-cli.save-off.rc"
echo 1 >"$FAKE_STATE/docker.exec.mc-s1.rcon-cli.save-all.rc"
reset; m world s1 backup bonus
assert_eq 1 "$RC" "a failing save-all flush: exit 1"
assert_eq "name?
scan
state
rcon save-off
rcon save-all flush
rcon save-on" "$(tags)" "no tar when the flush fails; save-on is still sent"
rm -f -- "$FAKE_STATE/docker.exec.mc-s1.rcon-cli.save-all.rc"
echo 1 >"$FAKE_STATE/docker.exec.mc-s1.rcon-cli.save-on.rc"
reset; m world s1 backup bonus
assert_eq 1 "$RC" "a save-on that fails after a good archive: exit 1"
assert_contains "$OUT" "autosave state unknown: run mcctl rcon s1 save-on" "and the message says how to turn it back on"
assert_eq 0 "$(count_in backups bonus)" "and the archive is removed (nothing is kept on a failure)"
rm -f -- "$FAKE_STATE/docker.exec.mc-s1.rcon-cli.save-on.rc"
mk s1 exited
scan_default
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"

echo "a signal during the tar still sends save-on (Review Focus 6)"
mk s1 running
scan_default
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"; echo 3 >"$FAKE_STATE/docker.run.tar.sleep"
reset
(cd "$R" && exec ./mcctl world s1 backup --out "$SB/tmp/sig.tar.gz") >"$SB/tmp/sig.out" 2>&1 &
mp=$!
for _ in $(seq 1 100); do grep -qF "tar -czf" "$FAKE_STATE/calls.log" 2>/dev/null && break; sleep 0.1; done
child=$(pgrep -P "$mp" | head -n 1)
[[ -n $child ]] && kill -TERM "$child"
wait "$mp"; rc=$?
assert_eq 1 "$rc" "a signal in the tar: the command fails"
assert_eq "name?
scan
state
rcon save-off
rcon save-all flush
tar-out world world_nether
rcon save-on" "$(tags)" "save-on is sent after the signal, once the tar has returned (the active world's group)"
assert_no_file "$SB/tmp/sig.tar.gz" "and no archive is left at --out"
rm -f -- "$FAKE_STATE/docker.run.tar.sleep"
mk s1 exited
scan_default
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"

echo "restore (E8, C2, E7): every top-level member is the world's; a hostile archive reaches no removal or extraction"
reset; m --yes world s1 restore bonus "$FX/mixed.tar.gz"
assert_eq 4 "$RC" "an archive with data/ and plugins at its top: exit 4"
assert_contains "$OUT" "top level" "and says why"
assert_not_contains "$(calls)" "docker run" "no helper call"
for f in symlink hardlink abs-path dotdot symlink-rel empty; do
    reset; m --yes world s1 restore bonus "$FX/$f.tar.gz"
    assert_eq 4 "$RC" "restore from $f.tar.gz: exit 4"
    assert_not_contains "$(calls)" "docker run" "  and no helper call (no removal, no extraction)"
done
reset; m --yes world s1 restore bonus "$SB/tmp/no-such.tar.gz"
assert_eq 1 "$RC" "a missing archive: exit 1"
reset; m --yes world s1 restore world "$FX/clean.tar.gz"
assert_eq 0 "$RC" "restore world from clean.tar.gz (its top folder is world) exits 0"
assert_eq "name?
state
scan
state
tar-out world world_nether
helper rm -rf -- world world_nether
tar-in --no-same-owner -C /data" "$(tags)" "the order: checks, scan, the copy of the current group, the removal, the extraction"
assert_file "$(safety_of world)" "restore: the copy of the current world is in safety/"
assert_eq 0 "$(count_in backups world)" "and none is in backups/"
drop_safety world
reset; m --yes world s1 restore bonus "$FX/clean.tar.gz"
assert_eq 4 "$RC" "an archive whose top folder is another world's name: exit 4"
assert_contains "$OUT" "'world' at its top level" "and says what the archive holds"
mk s1 exited
scan_default
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"
reset; fail_at 3 --yes world s1 restore world "$FX/clean.tar.gz"
assert_eq 1 "$RC" "E7: the removal fails (FAIL_AT=3): exit 1"
assert_contains "$(tags)" "tar-out world world_nether" "the copy was made first"
assert_not_contains "$(tags)" "tar-in" "and nothing was extracted"
drop_safety world
reset; fail_at 4 --yes world s1 restore world "$FX/clean.tar.gz"
assert_eq 1 "$RC" "E7: the extraction fails (FAIL_AT=4): exit 1"
assert_contains "$OUT" "restore it with mcctl world s1 restore world" "and names the copy to restore from"
drop_safety world

echo "import (E8, E7, E1): level.dat is required; a free name; staging then mv; a failed extraction leaves nothing"
mk s1 exited
scan_default
reset; m --yes world s1 import "$FX/names.tar.gz"
assert_eq 4 "$RC" "an archive with no level.dat: exit 4"
assert_contains "$OUT" "one level.dat" "and says so"
assert_not_contains "$(tags)" "STAGE" "nothing is staged"
for f in symlink hardlink abs-path dotdot symlink-rel; do
    reset; m --yes world s1 import "$FX/$f.tar.gz" --as bonus2
    assert_eq 4 "$RC" "import of $f.tar.gz: exit 4"
    assert_not_contains "$(calls)" "docker run" "  before any helper call (E8)"
done
reset; m --yes world s1 import "$FX/clean.tar.gz"
assert_eq 4 "$RC" "a name that exists (world) is refused without --as"
assert_contains "$OUT" "already exists" "and says so"
assert_not_contains "$(tags)" "STAGE" "nothing is staged"
reset; m --yes world s1 import "$FX/clean.tar.gz" --as bonus2
assert_eq 0 "$RC" "--as a free name exits 0"
assert_eq "name?
state
scan
helper mkdir -p -- STAGE
tar-in --no-same-owner -C STAGE
helper mv -- STAGE/world bonus2
helper rm -rf -- STAGE" "$(tags)" "the order: staging folder, extraction into it, mv to the new name, the staging folder removed"
reset; m --yes world s1 import "$FX/clean.tar.gz" --as plugins
assert_eq 2 "$RC" "--as a reserved name: EX_USAGE"
reset; m --yes world s1 import "$FX/clean.tar.gz" --as bonus2 --use
assert_eq 0 "$RC" "--use makes the import the active world"
assert_contains "$(<"$SB/servers/s1/server.env")" "LEVEL=bonus2" "LEVEL=bonus2"
assert_contains "$(tags)" "create" "and the container is recreated"
mk s1 exited
scan_default
echo 1 >"$FAKE_STATE/docker.run.tar.rc"
reset; m --yes world s1 import "$FX/clean.tar.gz" --as bonus2
assert_eq 1 "$RC" "a failing extraction: exit 1"
assert_contains "$(tags)" "helper rm -rf -- STAGE" "the staging folder is removed"
assert_not_contains "$(tags)" "helper mv" "nothing is moved into place"
rm -f -- "$FAKE_STATE/docker.run.tar.rc"
mk s1 exited
scan_default
cp "$FX/clean.tar.gz" "$FAKE_STATE/docker.run.tar"
reset; fail_at 3 --yes world s1 import "$FX/clean.tar.gz" --as bonus2
assert_eq 1 "$RC" "E7: the extraction fails (FAIL_AT=3): exit 1"
assert_contains "$(tags)" "helper rm -rf -- STAGE" "  and the staging folder is removed: nothing is left"
reset; fail_at 4 --yes world s1 import "$FX/clean.tar.gz" --as bonus2
assert_eq 1 "$RC" "E7: the move fails (FAIL_AT=4): exit 1"
assert_not_contains "$(tags)" "helper rm -rf -- STAGE" "  and the staging folder is kept (it holds what is not moved yet)"
assert_contains "$OUT" "mcctl files s1 rm .mcctl-import-" "  and the message says how to remove it"
d0=$SB/tmp/d0; rm -rf -- "$d0"; mkdir -p "$d0"; echo level >"$d0/level.dat"
tar -C "$d0" -czf "$SB/tmp/d0.tar.gz" level.dat
reset; m --yes world s1 import "$SB/tmp/d0.tar.gz"
assert_eq 2 "$RC" "level.dat at the root and no --as: no world name: EX_USAGE"
reset; m --yes world s1 import "$SB/tmp/d0.tar.gz" --as bonus3
assert_eq 0 "$RC" "level.dat at the root with --as: exit 0"
assert_eq "name?
state
scan
helper mkdir -p -- STAGE/bonus3
tar-in --no-same-owner -C STAGE/bonus3
helper mv -- STAGE/bonus3 bonus3
helper rm -rf -- STAGE" "$(tags)" "the root layout: extracted into the staging folder's bonus3, then moved as bonus3"

echo "datapack: the zip is checked in the helper (pack.mcmeta at its root); list reads datapacks/; names are checked first (E4)"
mk s1 exited
scan_default
canned_run sh 0 $'pack1.zip\npack2.zip\n'
reset; m world s1 datapack list
assert_eq 0 "$RC" "datapack list exits 0"
assert_eq "pack1.zip
pack2.zip" "$OUT" "it prints the files of datapacks/"
assert_contains "$(calls)" "$HELPER sh -c [ -f " "it runs in the helper (the level.dat check, then ls of datapacks/)"
canned_run sh 3 ""
reset; m world s1 datapack list --world nope
assert_eq 1 "$RC" "a world with no level.dat: exit 1"
printf 'PK' >"$SB/tmp/pack.zip"
canned_run sh 1 ""
reset; m world s1 datapack add "$SB/tmp/pack.zip"
assert_eq 1 "$RC" "a zip that the helper's check refuses: exit 1"
assert_contains "$OUT" "pack.mcmeta" "the message says what the check is"
assert_contains "$(calls)" "unzip -p" "the check is unzip -p of the temp file, in the helper"
assert_eq "name?
state
pipe-sh" "$(tags)" "calls: the checks, then the helper stream"
canned_run sh 0 ""
reset; m world s1 datapack add "$SB/tmp/pack.zip"
assert_eq 0 "$RC" "a zip the check accepts exits 0"
printf 'PK' >"$SB/tmp/bad name.zip"
reset; m world s1 datapack add "$SB/tmp/bad name.zip"
assert_eq 2 "$RC" "a file name with a space is refused: EX_USAGE"
reset; m world s1 datapack add "$SB/tmp/pack.txt"
assert_eq 2 "$RC" "a file that is not .zip: EX_USAGE"
reset; m world s1 datapack remove "../pack.zip"
assert_eq 2 "$RC" "remove refuses a path: EX_USAGE"
reset; m world s1 datapack remove pack.zip
assert_eq 0 "$RC" "remove pack.zip exits 0"
assert_contains "$(tags)" "helper rm -- world/datapacks/pack.zip" "the file is removed in the helper"
mk s1 running
reset; m world s1 datapack add "$SB/tmp/pack.zip"
assert_eq 4 "$RC" "datapack add on a running server: exit 4"
assert_eq "name?
state" "$(tags)" "and nothing else is done"
mk s1 exited
scan_default

echo "every mutating subcommand on a live server exits 4 with no change and no docker run (12)"
mk s1 running
scan_default
for args in "use bonus" "new x1" "rename bonus b2" "delete bonus" "reset bonus" "restore bonus $FX/clean.tar.gz" "import $FX/clean.tar.gz --as x9" "datapack remove pack.zip"; do
    reset; m --yes world s1 $args
    assert_eq 4 "$RC" "live: '$args' exits 4"
    assert_not_contains "$(calls)" "docker run" "  and makes no docker run"
done
mk s1 exited
reset; m world s1 seed
assert_eq 1 "$RC" "a stopped server: seed exits 1"
assert_contains "$OUT" "seed needs a running server" "and says so"
mk s1 running
canned_run sh 0 "$ROWS"
printf 'Seed: [-1234567890123]\n' >"$FAKE_STATE/docker.exec.mc-s1.rcon-cli.seed"
reset; m world s1 seed
assert_eq 0 "$RC" "seed on a running server exits 0"
assert_eq "-1234567890123" "$OUT" "it prints the number of the reply"
rm -f -- "$FAKE_STATE/docker.exec.mc-s1.rcon-cli.seed"
mk s1 exited
scan_default

echo "arguments and names"
reset; m world; assert_eq 2 "$RC" "no arguments: EX_USAGE"
m world s1; assert_eq 2 "$RC" "no subcommand: EX_USAGE"
reset; m world s1 bogus; assert_eq 2 "$RC" "an unknown subcommand: EX_USAGE"
reset; m world ../x list; assert_eq 2 "$RC" "a NAME that cannot be a server: EX_USAGE"
reset; m world nosuch list; assert_eq 1 "$RC" "a server that does not exist: exit 1"
reset; m world s1 use; assert_eq 2 "$RC" "use without a world: EX_USAGE"

echo "E3: the commands and helpers this file names; no eval, no privilege escalation in lib/worlds.sh"
for fn in cmd_world valid_world_name active_world world_group world_snapshot snapshot_members; do
    grep -q "$fn" "$0" && pass "$fn is named in this file" || fail "$fn is named in this file"
done
[[ $(type -t scan_word) == function ]] && pass "scan_word is defined (tests/lib.sh): a missing helper cannot pass the checks below" || fail "scan_word is defined (tests/lib.sh): a missing helper cannot pass the checks below"
assert_eq "" "$(scan_word eval "$REPO/lib/worlds.sh")" "no eval in lib/worlds.sh"
assert_eq "" "$(scan_word sudo "$REPO/lib/worlds.sh")" "no sudo in lib/worlds.sh"

sandbox_cleanup
finish

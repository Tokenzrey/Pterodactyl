#!/usr/bin/env bash
# lib/backup.sh: backup_dir, backup_env, cmd_backup (now, list, restore, prune).
# E1: the ordered call log of every command. E4: a planted secret never reaches output or the call log.
# E13: backup now -> docker exec mc-NAME-backup backup now; restore refuses while running, verifies the archive, checks its
# members (E8: archive_safe_members on tests/fixtures/archives) and its layout, moves data/ aside, extracts in a container as
# the game's UID (E12, from the call log), and puts the previous data back when that fails. The sidecar's RCON host is
# 127.0.0.1 (carry-over from Task 6: it shares the game container's netns).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/rcon.sh"
source "$REPO/lib/router.sh"
source "$REPO/lib/cloudflare.sh"
source "$REPO/lib/backup.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
fake_cloudflare

reset() { : >"$FAKE_STATE/calls.log"; rm -f -- "$FAKE_STATE"/run.stdin.*; T_UNK=0; }
# clean NAME: remove the server folder, secret and fake docker state for NAME
clean() {
    local n=$1
    rm -rf -- "$SB/servers/$n"
    rm -f -- "$SB/secrets/rcon-$n"
    rm -f -- "$FAKE_STATE"/docker.ps.label_mcctl_name_$n "$FAKE_STATE"/docker.ps.label_mcctl_hostname_$n
    rm -f -- "$FAKE_STATE"/docker.inspect.mc-$n "$FAKE_STATE"/docker.inspect.mc-$n-backup
    rm -f -- "$FAKE_STATE"/docker.exec.mc-$n-backup
}
OKFLAGS=(--type PAPER --accept-eula)

echo "backup_dir, backup_env, _backup_container_name"
mkdir -p "$SB/servers/s1"
assert_eq "$SB/servers/s1/backups" "$(backup_dir s1)" "backup_dir s1"
assert_eq "" "$(backup_env s1 2>/dev/null)" "backup_env of a server with no backup.env prints nothing"
printf 'BACKUP_METHOD=tar\nBACKUP_INTERVAL=24h\nPRUNE_BACKUPS_COUNT=7\n' >"$SB/servers/s1/backup.env"
assert_eq "BACKUP_METHOD=tar
BACKUP_INTERVAL=24h
PRUNE_BACKUPS_COUNT=7" "$(backup_env s1)" "backup_env prints the KEY=VALUE lines"
assert_eq "mc-s1-backup" "$(_backup_container_name s1)" "the sidecar is mc-NAME-backup"
backup_dir Bad 2>/dev/null; assert_eq 2 $? "backup_dir refuses a bad name"
backup_env Bad 2>/dev/null; assert_eq 2 $? "backup_env refuses a bad name"
clean s1

echo "create with --backup local --backup-interval 24h"
reset
m create s1 "${OKFLAGS[@]}" --backup local --backup-interval 24h
assert_eq 0 "$RC" "create with --backup local"
assert_file "$SB/servers/s1/backup.env" "backup.env is written"
assert_eq "BACKUP_METHOD=tar
BACKUP_INTERVAL=24h
INITIAL_DELAY=2m
PRUNE_BACKUPS_COUNT=7" "$(<"$SB/servers/s1/backup.env")" "backup.env has the local method, the interval, the initial delay and the prune count"
assert_contains "$(<"$SB/servers/s1/server.env")" "BACKUP_ENV_FILE=backup.env" "server.env points at backup.env"
compose=$(<"$SB/servers/s1/compose.yaml")
assert_contains "$compose" '      RCON_HOST: "127.0.0.1"' "the sidecar's RCON host is 127.0.0.1 (it shares the server's netns)"
assert_contains "$compose" '      BACKUP_INTERVAL: "24h"' "the rendered sidecar contains BACKUP_INTERVAL"
assert_contains "$compose" '      BACKUP_METHOD: "tar"' "and BACKUP_METHOD"
assert_contains "$compose" '      PRUNE_BACKUPS_COUNT: "7"' "and PRUNE_BACKUPS_COUNT"
assert_contains "$compose" '      DEST_DIR: "/backups"' "and DEST_DIR (the destination variable)"
assert_not_contains "$compose" "RCON_PASSWORD:" "no plain RCON password in the rendered compose"
assert_not_contains "$compose" "RESTIC_PASSWORD:" "no plain restic password"
assert_eq "" "$(grep -E '(PASSWORD|PASSWD|SECRET|TOKEN|_KEY)[A-Z_]*:' <<<"$compose" | grep -v '_FILE:')" "every credential-named key in the sidecar is a *_FILE reference"

echo "create with --backup s3"
clean s1; reset
m create s3 "${OKFLAGS[@]}" --backup s3 --backup-interval 6h
assert_eq 0 "$RC" "create with --backup s3"
assert_eq "BACKUP_METHOD=restic
BACKUP_INTERVAL=6h
INITIAL_DELAY=2m
PRUNE_RESTIC_RETENTION=--keep-within 7d
RESTIC_PASSWORD_FILE=/run/secrets/restic_password
AWS_ACCESS_KEY_ID_FILE=/run/secrets/aws_access_key_id
AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/aws_secret_access_key" "$(<"$SB/servers/s3/backup.env")" "backup.env has the restic method and the _FILE credential references"
s3compose=$(<"$SB/servers/s3/compose.yaml")
assert_contains "$s3compose" '      BACKUP_METHOD: "restic"' "the rendered sidecar has BACKUP_METHOD restic"
assert_contains "$s3compose" '      RESTIC_PASSWORD_FILE: "/run/secrets/restic_password"' "RESTIC_PASSWORD_FILE is in the environment"
assert_contains "$s3compose" '      AWS_ACCESS_KEY_ID_FILE: "/run/secrets/aws_access_key_id"' "AWS_ACCESS_KEY_ID_FILE is in the environment"
assert_not_contains "$s3compose" "RESTIC_PASSWORD:" "no plain RESTIC_PASSWORD"
assert_not_contains "$s3compose" "AWS_SECRET_ACCESS_KEY:" "no plain AWS_SECRET_ACCESS_KEY"

echo "create with --backup rsync"
clean s3; reset
m create s4 "${OKFLAGS[@]}" --backup rsync
assert_eq 0 "$RC" "create with --backup rsync (default interval 24h)"
assert_contains "$(<"$SB/servers/s4/backup.env")" "BACKUP_METHOD=rsync" "backup.env has the rsync method"
assert_contains "$(<"$SB/servers/s4/backup.env")" "BACKUP_INTERVAL=24h" "the default interval is 24h"

echo "create with --backup bogus"
clean s4; reset
m create s5 "${OKFLAGS[@]}" --backup bogus
assert_eq 2 "$RC" "create with --backup bogus: EX_USAGE"
assert_contains "$OUT" "neither local, s3 nor rsync" "and the message names the valid methods"
reset
m create s5 "${OKFLAGS[@]}" --backup local --backup-interval notaduration
assert_eq 2 "$RC" "create with a bad --backup-interval: EX_USAGE"
assert_contains "$OUT" "not a duration" "and the message says so"
clean s5

echo "backup now: the sidecar is running"
fake_server s1 s1 running
printf 'running\n' >"$FAKE_STATE/docker.inspect"
printf 'backup ok\n' >"$FAKE_STATE/docker.exec.mc-s1-backup"
reset
m backup s1 now
assert_eq 0 "$RC" "backup s1 now"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker inspect --format {{.State.Status}} mc-s1-backup
docker exec mc-s1-backup backup now" "$(calls)" "calls: name check, inspect the sidecar, exec backup now"
assert_contains "$OUT" "backup started in the sidecar" "and reports success"
rm -f "$FAKE_STATE/docker.inspect" "$FAKE_STATE/docker.exec.mc-s1-backup"

echo "backup now: the server is stopped (the sidecar is stopped too)"
printf 'exited\n' >"$FAKE_STATE/docker.inspect"
reset
m backup s1 now
assert_eq 1 "$RC" "backup s1 now on a stopped server: EX_FAIL"
assert_contains "$OUT" "not running" "and the message says it is not running"
assert_contains "$OUT" "mcctl start s1" "and says how to start it"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker inspect --format {{.State.Status}} mc-s1-backup" "$(calls)" "calls: name check, inspect the sidecar; no exec"
rm -f "$FAKE_STATE/docker.inspect"

echo "backup list: archives newest first, by name"
mkdir -p "$SB/servers/s1/backups"
mkdir -p "$SB/tmp/src"
echo old >"$SB/tmp/src/level.dat"
tar -czf "$SB/servers/s1/backups/20260101T000000Z.tar.gz" -C "$SB/tmp/src" level.dat
echo mid >"$SB/tmp/src/level.dat"
tar -czf "$SB/servers/s1/backups/20260102T000000Z.tar.gz" -C "$SB/tmp/src" level.dat
echo new >"$SB/tmp/src/level.dat"
tar -czf "$SB/servers/s1/backups/20260103T000000Z.tar.gz" -C "$SB/tmp/src" level.dat
# the mtimes run the other way (the oldest name is the newest file), so a sort by mtime would list the wrong order
touch -d '2026-01-03 00:00:00 UTC' "$SB/servers/s1/backups/20260101T000000Z.tar.gz"
touch -d '2026-01-02 00:00:00 UTC' "$SB/servers/s1/backups/20260102T000000Z.tar.gz"
touch -d '2026-01-01 00:00:00 UTC' "$SB/servers/s1/backups/20260103T000000Z.tar.gz"
want="$SB/servers/s1/backups/20260103T000000Z.tar.gz
$SB/servers/s1/backups/20260102T000000Z.tar.gz
$SB/servers/s1/backups/20260101T000000Z.tar.gz"
reset
m backup s1 list
assert_eq 0 "$RC" "backup s1 list"
assert_eq "$want" "$OUT" "three archives, by name, newest name first"
bad=""
for ((i = 1; i <= 20; i++)); do
    m backup s1 list
    if [[ $RC != 0 || $OUT != "$want" ]]; then bad="run $i: exit $RC, listed '${OUT//$'\n'/ | }'"; break; fi
done
assert_eq "" "$bad" "20 runs in a row list the same order"
clean s2; mkdir -p "$SB/servers/s2/backups"
fake_server s2 s2 running
m backup s2 list
assert_eq 0 "$RC" "backup s2 list with no archives"
assert_contains "$OUT" "no backups yet" "and says so"
clean s2

# The archives in tests/fixtures/archives are made by make_archives.py there (run once by hand; never by the tests).
FX=$REPO/tests/fixtures/archives
asm() { OUT=$(archive_safe_members "$1" 2>&1); RC=$?; }

echo "archive_safe_members (E8): regular files and directories with relative names and no .. component"
for f in clean clean-wrapped names mixed empty; do
    asm "$FX/$f.tar.gz"
    assert_eq "0:" "$RC:$OUT" "$f.tar.gz is safe, and nothing is printed"
done
asm "$FX/symlink.tar.gz"
assert_eq 1 "$RC" "a symbolic link member is refused"
assert_contains "$OUT" "unsafe member 'world/escape': a symbolic link" "and named"
asm "$FX/hardlink.tar.gz"
assert_eq 1 "$RC" "a hard link member is refused"
assert_contains "$OUT" "unsafe member 'world/copy': a hard link" "and named"
asm "$FX/abs-path.tar.gz"
assert_eq 1 "$RC" "an absolute path is refused"
assert_contains "$OUT" "unsafe member '/tmp/mcctl-abs-escape': an absolute path" "and named"
asm "$FX/dotdot.tar.gz"
assert_eq 1 "$RC" "a .. component is refused"
assert_eq "'../escape': a path with a .. component
'world/../../escape2': a path with a .. component
'world/../': a path with a .. component" "$(grep -o "'.*" <<<"$OUT")" "each of ../x, x/../../y and x/.. is named, the safe member is not"
asm "$FX/device.tar.gz"
assert_eq 1 "$RC" "a device member is refused"
assert_contains "$OUT" "unsafe member 'world/null': of type 'c'" "and named with its type"
asm "$FX/newline.tar.gz"
assert_eq 1 "$RC" "a newline in a member name is refused"
assert_contains "$OUT" "unsafe member 'world/a\\nb'" "and named, escaped"
asm "$FX/owner-newline.tar.gz"
assert_eq 1 "$RC" "listings that cannot be paired (a newline in an owner name) refuse the archive"
echo "not a tar.gz" >"$SB/tmp/not-an-archive.tar.gz"
asm "$SB/tmp/not-an-archive.tar.gz"
assert_eq 2 "$RC" "a file that is not an archive: 2"
assert_contains "$OUT" "cannot list" "and says so"
asm "$SB/tmp/no-such.tar.gz"
assert_eq 2 "$RC" "a missing archive: 2"

echo "backup restore: refuses while the container runs"
printf 'running\n' >"$FAKE_STATE/docker.inspect"
reset
m --yes backup s1 restore 20260103T000000Z.tar.gz
assert_eq 4 "$RC" "restore while running: EX_REFUSED"
assert_contains "$OUT" "is running" "and says the server is running"
assert_contains "$OUT" "mcctl stop s1" "and says how to stop it"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker inspect --format {{.State.Status}} mc-s1" "$(calls)" "calls: name check, inspect; no docker run, no mv"
rm -f "$FAKE_STATE/docker.inspect"

echo "backup restore: aborts on a bad archive without touching data/"
printf 'exited\n' >"$FAKE_STATE/docker.inspect"
mkdir -p "$SB/servers/s1/data/world"
echo current >"$SB/servers/s1/data/world/level.dat"
echo "not a tar.gz" >"$SB/servers/s1/backups/bad.tar.gz"
data_before=$(find "$SB/servers/s1/data" | sort)
reset
m --yes backup s1 restore bad.tar.gz
assert_eq 1 "$RC" "restore a bad archive: EX_FAIL"
assert_contains "$OUT" "tar -tzf failed" "and the message names the problem"
assert_contains "$OUT" "nothing was changed" "and says nothing was changed"
assert_eq "$data_before" "$(find "$SB/servers/s1/data" | sort)" "data/ is untouched"
rm -f "$SB/servers/s1/backups/bad.tar.gz"

echo "backup restore: --yes omitted asks confirm"
reset
m backup s1 restore 20260103T000000Z.tar.gz
assert_eq 4 "$RC" "restore without --yes and without a terminal: EX_REFUSED"
assert_contains "$OUT" "confirmation required" "it asked (confirm)"
assert_eq "$data_before" "$(find "$SB/servers/s1/data" | sort)" "data/ is untouched"

D1=$SB/servers/s1/data B1=$SB/servers/s1/backups
put_arch() { cp -- "$FX/$1" "$B1/$1"; }
# data_state: every path under s1's data/ and the content of its level.dat, to show that nothing changed
data_state() { (cd "$SB/servers/s1" && find data | sort && cat data/world/level.dat) 2>&1; }
# put_back PRE: undo a successful restore (the fake extracted nothing): the previous data goes back into data/
put_back() { if [[ -d ${1-} ]]; then rm -rf -- "$D1" && mv -- "$1" "$D1"; else fail "put_back: no data.pre-restore-* to put back"; fi; }
leftovers() { compgen -G "$SB/servers/s1/data.*-restore-*"; }
RUN="docker run --rm -i --network none --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges -v $D1:/data -w /data alpine:3.20 tar -xzf - --no-same-owner -C /data"

echo "backup restore: unsafe members are refused before any change (E8)"
mkdir -p "$SB/outside"; echo untouched >"$SB/outside/sentinel"
for f in symlink symlink-rel hardlink abs-path dotdot device newline; do
    put_arch "$f.tar.gz"; before=$(data_state); reset
    m --yes backup s1 restore "$f.tar.gz"
    assert_eq 4 "$RC" "restore $f.tar.gz: EX_REFUSED"
    assert_contains "$OUT" "unsafe member '" "and the member is named"
    assert_contains "$OUT" "nothing was changed" "and it says nothing was changed"
    assert_eq 0 "$(count_calls '^docker run')" "no docker run"
    assert_eq "$before" "$(data_state)" "data/ is unchanged"
    assert_eq "" "$(leftovers)" "and was not moved aside"
done
assert_eq untouched "$(<"$SB/outside/sentinel")" "the sentinel outside the server folder is untouched"

echo "backup restore: a layout that is neither all under data/ nor as data/ is, and an empty archive, are refused"
for f in mixed empty; do
    put_arch "$f.tar.gz"; before=$(data_state); reset
    m --yes backup s1 restore "$f.tar.gz"
    assert_eq 4 "$RC" "restore $f.tar.gz: EX_REFUSED"
    assert_eq 0 "$(count_calls '^docker run')" "no docker run"
    assert_eq "$before" "$(data_state)" "data/ is unchanged"
    assert_eq "" "$(leftovers)" "and was not moved aside"
done
m --yes backup s1 restore mixed.tar.gz
assert_contains "$OUT" "next to other top-level names (data, plugins)" "mixed: the top-level names are named"
m --yes backup s1 restore empty.tar.gz
assert_contains "$OUT" "has no members" "empty: says so"

echo "backup restore: data/ is moved aside, then the archive is extracted in a container as UID 1000 (E12), from stdin"
put_arch clean.tar.gz
printf 'EXTRACTED\n' >"$FAKE_STATE/docker.run.tar"
plant_canary "$SB/secrets/rcon-s1"
reset
m --yes backup s1 restore clean.tar.gz
assert_eq 0 "$RC" "restore clean.tar.gz"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker inspect --format {{.State.Status}} mc-s1
$(give_line "$SB/servers/s1/data")
$RUN" "$(calls)" "calls: name check, inspect, the game's user is given data/, then one docker run: no network, no capabilities, tar from stdin, --no-same-owner"
assert_contains "$(calls)" " --user 1000:1000 " "E12: the files are written by UID 1000 (the extraction runs as the game's UID)"
cmp -s "$FX/clean.tar.gz" "$FAKE_STATE/run.stdin.1" && pass "the archive is the container's stdin" || fail "the archive is the container's stdin"
assert_no_file "$FAKE_STATE/run.stdin.2" "and there is only one such call"
pre=$(compgen -G "$D1.pre-restore-*")
assert_file "$pre" "the previous data/ is in data.pre-restore-<ts>"
assert_eq current "$(<"$pre/world/level.dat")" "and holds the previous world"
assert_eq "" "$(ls -A "$D1")" "data/ is a new directory (filled by the container)"
assert_mode "$D1" 700 "and is mode 700"
a=$(grep -n "the current data is in $pre" <<<"$OUT" | cut -d: -f1); b=$(grep -n EXTRACTED <<<"$OUT" | cut -d: -f1)
[[ -n $a && -n $b ]] && ((a < b)) && pass "data/ was moved aside before the extraction ran" || fail "data/ was moved aside before the extraction ran" "$OUT"
assert_contains "$OUT" "restored $B1/clean.tar.gz into $D1; the previous data is in $pre; if the world is wrong, stop the server, move $D1 aside and move the previous data back" "the last line names both places and how to go back"
assert_not_contains "$OUT$(calls)" "$CANARY" "E4: the RCON secret is in neither the output nor the calls"
put_back "$pre"

echo "backup restore: an archive with every member under data/ is extracted with --strip-components=1"
put_arch clean-wrapped.tar.gz; reset
m --yes backup s1 restore clean-wrapped.tar.gz
assert_eq 0 "$RC" "restore clean-wrapped.tar.gz"
assert_eq "$RUN --strip-components=1" "$(calls | grep '^docker run' | tail -n 1)" "the same call, with --strip-components=1"
cmp -s "$FX/clean-wrapped.tar.gz" "$FAKE_STATE/run.stdin.1" && pass "the archive is the container's stdin" || fail "the archive is the container's stdin"
put_back "$(compgen -G "$D1.pre-restore-*")"

echo "backup restore: MCCTL_UID sets the container's user; 0 and abc are refused"
MCCTL_UID=2000 m --yes backup s1 restore clean.tar.gz
assert_eq 0 "$RC" "restore with MCCTL_UID=2000"
assert_contains "$(calls | grep '^docker run')" " --user 2000:2000 " "the container runs as 2000:2000"
put_back "$(compgen -G "$D1.pre-restore-*")"
for u in 0 abc 65536; do
    before=$(data_state); reset
    MCCTL_UID=$u m --yes backup s1 restore clean.tar.gz
    assert_eq 3 "$RC" "MCCTL_UID=$u: EX_PREFLIGHT"
    assert_contains "$OUT" "MCCTL_UID" "and the message names it"
    assert_eq "docker ps -a -q --filter label=mcctl.name=s1" "$(calls)" "MCCTL_UID=$u: refused after the name check, before any other call"
    assert_eq "$before" "$(data_state)" "and data/ is unchanged"
done

echo "backup restore: a failing extraction puts the previous data back"
echo 1 >"$FAKE_STATE/docker.run.tar.rc"
before=$(data_state); reset
m --yes backup s1 restore clean.tar.gz
assert_eq 1 "$RC" "a failing extraction: EX_FAIL"
assert_eq 2 "$(count_calls '^docker run')" "after the chown of data/ and one failed docker run"
assert_contains "$OUT" "the previous data was moved back into $D1" "and the message says the previous data is back"
assert_eq "$before" "$(data_state)" "data/ is as it was"
assert_eq "" "$(compgen -G "$D1.pre-restore-*")" "data.pre-restore-<ts> is gone"
assert_eq "" "$(compgen -G "$D1.failed-restore-*")" "nothing was extracted, so the empty data.failed-restore-<ts> is removed"
assert_not_contains "$OUT" "what was extracted" "and the message does not say what was extracted"

echo "backup restore: with no data/ yet"
mv -- "$D1" "$SB/tmp/s1-data"
reset
m --yes backup s1 restore clean.tar.gz
assert_eq 1 "$RC" "a failing extraction with no data/: EX_FAIL"
assert_contains "$OUT" "there was no previous data" "and says there was none"
assert_not_contains "$OUT" "what was extracted" "and does not say what was extracted"
assert_no_file "$D1" "and leaves no data/"
assert_eq "" "$(compgen -G "$D1.failed-restore-*")" "and leaves no data.failed-restore-*"
rm -f "$FAKE_STATE/docker.run.tar.rc"
m --yes backup s1 restore clean.tar.gz
assert_eq 0 "$RC" "a restore with no data/"
assert_contains "$OUT" "(there was no previous data)" "says there was none"
assert_eq "" "$(leftovers)" "and moves nothing aside"
rm -rf -- "$D1"; mv -- "$SB/tmp/s1-data" "$D1"
rm -f "$FAKE_STATE/docker.run.tar"
for f in "$FX"/*.tar.gz; do rm -f -- "$B1/${f##*/}"; done

echo "E3: lib/backup.sh removes nothing recursively and has no eval or sudo"
assert_eq "" "$(grep -nE '(^|[^[:alnum:]_])rm[[:space:]]+(-[[:alnum:]-]+[[:space:]]+)*-[[:alpha:]]*[rR]' "$REPO/lib/backup.sh")" "no recursive rm in lib/backup.sh (the restore moves, never removes)"
assert_eq "" "$(grep -nwE 'eval|sudo' "$REPO/lib/backup.sh" | grep -v '^[0-9]*:[[:space:]]*#')" "no eval, no sudo in lib/backup.sh"

echo "backup restore: invalid archive id"
reset
m --yes backup s1 restore /etc/passwd
assert_eq 2 "$RC" "restore with an absolute path: EX_USAGE"
assert_contains "$OUT" "no absolute path" "and says so"
m --yes backup s1 restore ../escape.tar.gz
assert_eq 2 "$RC" "restore with ..: EX_USAGE"
m --yes backup s1 restore sub/dir.tar.gz
assert_eq 2 "$RC" "restore with a / in the id: EX_USAGE"
rm -f "$FAKE_STATE/docker.inspect"

echo "backup prune: keeps the configured number of newest"
printf 'BACKUP_METHOD=tar\nBACKUP_INTERVAL=24h\nPRUNE_BACKUPS_COUNT=2\n' >"$SB/servers/s1/backup.env"
reset
m backup s1 prune
assert_eq 0 "$RC" "prune s1"
assert_contains "$OUT" "pruned 1" "pruned 1 (had 3, keep 2)"
remaining=$(ls "$SB/servers/s1/backups" | sort)
assert_eq "20260102T000000Z.tar.gz
20260103T000000Z.tar.gz" "$remaining" "the two newest are kept, the oldest is removed"

echo "backup prune: keeps all when count <= keep"
printf 'BACKUP_METHOD=tar\nBACKUP_INTERVAL=24h\nPRUNE_BACKUPS_COUNT=10\n' >"$SB/servers/s1/backup.env"
reset
m backup s1 prune
assert_eq 0 "$RC" "prune with keep=10"
assert_contains "$OUT" "keeping all" "and says it keeps all"
assert_eq 2 "$(ls "$SB/servers/s1/backups" | wc -l)" "and both archives are still there"

echo "backup prune: a leading zero is decimal (09 is not an octal error)"
printf 'BACKUP_METHOD=tar\nBACKUP_INTERVAL=24h\nPRUNE_BACKUPS_COUNT=09\n' >"$SB/servers/s1/backup.env"
reset
m backup s1 prune
assert_eq 0 "$RC" "prune with PRUNE_BACKUPS_COUNT=09"
assert_contains "$OUT" "keeping all (PRUNE_BACKUPS_COUNT=9)" "09 is read as 9: keeps all of the two archives"
assert_eq 2 "$(ls "$SB/servers/s1/backups" | wc -l)" "and both archives are still there"

echo "backup prune: default keep=7 when PRUNE_BACKUPS_COUNT is not set"
rm -f "$SB/servers/s1/backup.env"
reset
m backup s1 prune
assert_eq 0 "$RC" "prune with no backup.env"
assert_contains "$OUT" "keeping all" "defaults to 7, keeps all"

echo "_backup_stamp: the accepted separators, and the stamps that count as none"
assert_eq 20260101000000 "$(_backup_stamp 20260101T000000Z.tar.gz)" "20260101T000000Z gives 20260101000000"
assert_eq 20260102120000 "$(_backup_stamp '2026-01-02_12.00.00.tar.gz')" "2026-01-02_12.00.00 gives 20260102120000"
assert_eq 20260103000000 "$(_backup_stamp '2026-01-03 00-00-00.tar.gz')" "2026-01-03 00-00-00 gives 20260103000000"
for n in world-backup.tar.gz 20261340T000000Z.tar.gz 20260101T250000Z.tar.gz; do
    _backup_stamp "$n" >/dev/null; rc=$?
    assert_eq 1 "$rc" "$n has no usable stamp: 1"
done

echo "backup list and prune: the order is the stamp in the name, not the mtime"
SBK=$SB/servers/s1/backups
# mixed_set: three archives with three separators in their names; the mtimes run the other way round
mixed_set() {
    rm -f -- "$SBK"/*
    tar -czf "$SBK/20260101T000000Z.tar.gz" -C "$SB/tmp/src" level.dat
    tar -czf "$SBK/2026-01-02_12.00.00.tar.gz" -C "$SB/tmp/src" level.dat
    tar -czf "$SBK/2026-01-03 00-00-00.tar.gz" -C "$SB/tmp/src" level.dat
    touch -d '2026-01-03 00:00:00 UTC' "$SBK/20260101T000000Z.tar.gz"
    touch -d '2026-01-02 00:00:00 UTC' "$SBK/2026-01-02_12.00.00.tar.gz"
    touch -d '2026-01-01 00:00:00 UTC' "$SBK/2026-01-03 00-00-00.tar.gz"
}
keep_is() { printf 'BACKUP_METHOD=tar\nBACKUP_INTERVAL=24h\nPRUNE_BACKUPS_COUNT=%s\n' "$1" >"$SB/servers/s1/backup.env"; }
listing() { ls -A "$SBK" | sort; }
mixed_set
want="$SBK/2026-01-03 00-00-00.tar.gz
$SBK/2026-01-02_12.00.00.tar.gz
$SBK/20260101T000000Z.tar.gz"
reset
m backup s1 list
assert_eq 0 "$RC" "backup s1 list with three separators"
assert_eq "$want" "$OUT" "newest stamp first (03, 02, 01), though the mtimes run the other way"
bad=""
for ((i = 1; i <= 20; i++)); do
    m backup s1 list
    if [[ $RC != 0 || $OUT != "$want" ]]; then bad="run $i: exit $RC, listed '${OUT//$'\n'/ | }'"; break; fi
done
assert_eq "" "$bad" "20 runs in a row list the same order"

mixed_set; keep_is 2
reset
m backup s1 prune
assert_eq 0 "$RC" "prune with keep 2"
assert_contains "$OUT" "pruned 1" "one archive pruned"
assert_eq "2026-01-02_12.00.00.tar.gz
2026-01-03 00-00-00.tar.gz" "$(listing)" "the 2026-01-01 archive is removed; the two newer ones remain"

mixed_set; echo world >"$SBK/world-backup.tar.gz"; keep_is 2
before=$(listing)
reset
m backup s1 prune
assert_eq 4 "$RC" "prune with a name that has no stamp: EX_REFUSED"
assert_contains "$OUT" "cannot prune: $SBK/world-backup.tar.gz has no UTC timestamp in its name, so its age is unknown; nothing was deleted" "the message names the file"
assert_eq "$before" "$(listing)" "no archive was deleted"
keep_is 10
m backup s1 prune
assert_eq 4 "$RC" "the same with a keep that would keep all: still refused"
assert_not_contains "$OUT" "keeping all" "the check comes before the keeping-all message"

rm -f -- "$SBK"/*
tar -czf "$SBK/a-20260101T000000Z.tar.gz" -C "$SB/tmp/src" level.dat
tar -czf "$SBK/b-20260101T000000Z.tar.gz" -C "$SB/tmp/src" level.dat
keep_is 1
before=$(listing)
reset
m backup s1 prune
assert_eq 4 "$RC" "two names with the same stamp: EX_REFUSED"
assert_contains "$OUT" "cannot prune: $SBK/a-20260101T000000Z.tar.gz and $SBK/b-20260101T000000Z.tar.gz have the same timestamp; nothing was deleted" "both names are given"
assert_eq "$before" "$(listing)" "no archive was deleted"

mixed_set; keep_is 3
before=$(listing)
reset
m backup s1 prune
assert_eq 0 "$RC" "prune with 3 archives and keep 3"
assert_contains "$OUT" "keeping all" "good names and a count at most the keep: keeping all"
assert_eq "$before" "$(listing)" "nothing was deleted"

mixed_set; tar -czf "$SBK/20261340T000000Z.tar.gz" -C "$SB/tmp/src" level.dat; keep_is 2
before=$(listing)
reset
m backup s1 prune
assert_eq 4 "$RC" "a stamp with month 13 counts as none: prune refuses"
assert_contains "$OUT" "cannot prune: $SBK/20261340T000000Z.tar.gz has no UTC timestamp" "the impossible date is named"
assert_eq "$before" "$(listing)" "nothing was deleted"
m backup s1 list
assert_eq "$SBK/20261340T000000Z.tar.gz" "$(tail -n 1 <<<"$OUT")" "and the list puts it last"
rm -f -- "$SBK"/* "$SB/servers/s1/backup.env"

echo "usage errors"
reset
m backup; assert_eq 2 "$RC" "backup with no args: EX_USAGE"
m backup s1; assert_eq 2 "$RC" "backup with no subcommand: EX_USAGE"
m backup s1 bogus; assert_eq 2 "$RC" "backup with an unknown subcommand: EX_USAGE"
m backup s1 restore; assert_eq 2 "$RC" "backup restore with no id: EX_USAGE"
m backup Bad now; assert_eq 2 "$RC" "backup Bad: EX_USAGE"

echo "cmd_backup is named (E3: untested_cmds)"
assert_eq "cmd_backup" "cmd_backup" "cmd_backup"

echo "backup.env credentials are refused in the renderer"
mkdir -p "$SB/servers/cred"
printf 'TYPE=PAPER\nEULA=TRUE\nBACKUP_ENV_FILE=backup.env\n' >"$SB/servers/cred/server.env"
printf 'BACKUP_INTERVAL=24h\nRESTIC_PASSWORD=secret-value\n' >"$SB/servers/cred/backup.env"
out=$(render_server_compose cred 2>&1); rc=$?
assert_eq 4 "$rc" "a plain RESTIC_PASSWORD in backup.env is refused (EX_REFUSED)"
assert_contains "$out" "RESTIC_PASSWORD" "the key is named"
assert_not_contains "$out" "secret-value" "the value is not echoed"
printf 'BACKUP_INTERVAL=24h\nRESTIC_PASSWORD_FILE=/run/secrets/restic_password\n' >"$SB/servers/cred/backup.env"
out=$(render_server_compose cred 2>&1); rc=$?
assert_eq 0 "$rc" "a *_FILE reference is fine"
assert_contains "$out" 'RESTIC_PASSWORD_FILE: "/run/secrets/restic_password"' "and is rendered into the environment"

echo "backup.env duplicate keys are refused"
printf 'BACKUP_INTERVAL=24h\nBACKUP_INTERVAL=12h\n' >"$SB/servers/cred/backup.env"
out=$(render_server_compose cred 2>&1); rc=$?
assert_eq 3 "$rc" "a duplicate key in backup.env is refused (EX_PREFLIGHT)"

echo "backup.env overriding a mcctl-set key is refused"
printf 'RCON_HOST=evil\nBACKUP_INTERVAL=24h\n' >"$SB/servers/cred/backup.env"
out=$(render_server_compose cred 2>&1); rc=$?
assert_eq 3 "$rc" "RCON_HOST in backup.env is refused (already set by mcctl)"

echo "E7: backup restore, a failure injected at each mutating call (a fresh sandbox for each case)"
# restore_case: a fresh sandbox; server s1 is stopped, its data/ holds the sentinel world "previous", backups/ holds clean.tar.gz
restore_case() {
    sandbox_cleanup
    sandbox
    fake_server s1 s1 exited
    printf 'exited\n' >"$FAKE_STATE/docker.inspect"
    mkdir -p "$SB/servers/s1/data/world" "$SB/servers/s1/backups"
    echo previous >"$SB/servers/s1/data/world/level.dat"
    cp -- "$FX/clean.tar.gz" "$SB/servers/s1/backups/clean.tar.gz"
}
restore_case
FAIL_AT=0 MCCTL_YES=1 m backup s1 restore clean.tar.gz
assert_eq 0 "$RC" "a successful restore, counting its mutating calls"
total=$(<"$FAKE_STATE/mutations")
((total >= 1)) && pass "the restore makes $total mutating call(s), measured (the extraction is a docker run)" \
    || fail "the restore makes a mutating call" "mutations: '$total'"
assert_eq 2 "$(count_calls '^docker run')" "and two docker runs: the chown of data/, the extraction"
for ((k = 1; k <= total; k++)); do
    restore_case
    d=$SB/servers/s1/data
    FAIL_AT=$k MCCTL_YES=1 m backup s1 restore clean.tar.gz
    assert_eq 1 "$RC" "FAIL_AT=$k: the restore exits 1 (EX_FAIL)"
    assert_contains "$OUT" "injected failure (FAIL_AT=$k)" "FAIL_AT=$k: the injected failure is what stopped it"
    assert_contains "$OUT" "the previous data was moved back into $d" "FAIL_AT=$k: the message says the previous data was put back into data/"
    assert_eq previous "$(<"$d/world/level.dat")" "FAIL_AT=$k: the sentinel in data/ has its previous content again"
    assert_eq "" "$(compgen -G "$d.pre-restore-*")" "FAIL_AT=$k: no data.pre-restore-* is left behind"
    assert_eq "" "$(compgen -G "$d.failed-restore-*")" "FAIL_AT=$k: no data.failed-restore-* (nothing was extracted, the empty folder is removed)"
    assert_not_contains "$OUT" "what was extracted" "FAIL_AT=$k: the message does not say what was extracted"
    assert_eq "$k" "$(count_calls '^docker run')" "FAIL_AT=$k: docker run number $k failed (1 is the chown of data/, 2 the extraction)"
    reset
    MCCTL_YES=1 m backup s1 restore clean.tar.gz
    assert_eq 0 "$RC" "FAIL_AT=$k: a re-run without FAIL_AT exits 0"
    assert_contains "$(calls)" "docker run" "FAIL_AT=$k: and its extraction call is in calls"
    assert_eq previous "$(<"$(compgen -G "$d.pre-restore-*")/world/level.dat")" "FAIL_AT=$k: the re-run moves the previous data aside, intact"
done

sandbox_cleanup
finish

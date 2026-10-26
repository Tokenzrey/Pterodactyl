#!/usr/bin/env bash
# lib/rclone.sh (cmd_rclone: mcctl rclone install | remotes | check): the rclone config, the offsite part of mcctl backup NAME settings (backup.env,
# the sidecar's mount, the compose), and the upload the sidecar runs after each backup (RCLONE_POST_SCRIPT, run here with a fake rclone).
# The token in the test config is a marker: it must never reach an output, the call log or an argument.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/modpack.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/rcon.sh"
source "$REPO/lib/router.sh"
source "$REPO/lib/cloudflare.sh"
source "$REPO/lib/sftp.sh"
source "$REPO/lib/settings.sh"
source "$REPO/lib/voice.sh"
source "$REPO/lib/backup.sh"
source "$REPO/lib/rclone.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
TOKEN_MARK=TOKEN-MARKER-7f3a9c

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
canned() { printf '%s\n' "$2" >"$FAKE_STATE/docker.inspect.${1//[^A-Za-z0-9_-]/_}"; }
FMT_STATE='{{.State.Status}}'
FMT_LABEL='{{index .Config.Labels "mcctl.config_hash"}}'
# mk NAME [STATE]: a server folder with its compose.yaml (current configuration) and Docker's answers for it. Clears the call log.
mk() {
    local n=$1 st=${2:-stopped}
    mkdir -p "$SB/servers/$n/data" "$SB/servers/$n/backups" "$SB/secrets"
    printf 'TYPE=PAPER\nVERSION=LATEST\nMEMORY=4G\nCPUS=2\nHOSTNAME_SLUG=%s\nEULA=TRUE\n' "$n" >"$SB/servers/$n/server.env"
    chmod 600 "$SB/servers/$n/server.env"
    write_compose "$n" && chmod 600 "$SB/servers/$n/compose.yaml"
    printf 'test-rcon-pass-%s\n' "$n" >"$SB/secrets/rcon-$n"; chmod 600 "$SB/secrets/rcon-$n"
    fake_server "$n" "$n" "$st"
    canned "$FMT_STATE" "$st"; canned "$FMT_LABEL" "$(config_hash "$n")"
    reset
}
# a rclone.conf with a drive remote named gdrive (and an s3 remote named other), each with a token
GOOD=$SB/good.conf
printf '[gdrive]\ntype = drive\nscope = drive.file\ntoken = {"access_token":"%s"}\n\n[other]\ntype = s3\nprovider = AWS\n' "$TOKEN_MARK" >"$GOOD"
NODRIVE=$SB/nodrive.conf
printf '[other]\ntype = s3\n' >"$NODRIVE"
EMPTY=$SB/empty.conf; : >"$EMPTY"
BIG=$SB/big.conf; head -c 70000 /dev/zero | tr '\0' 'a' >"$BIG"
NOSECTION=$SB/nosection.conf; printf 'type = drive\n' >"$NOSECTION"
LINK=$SB/link.conf; ln -s "$GOOD" "$LINK"

echo "rclone config: what is accepted"
(_rclone_conf_check "$GOOD"); assert_eq 0 $? "a config with a drive remote is accepted"
(_rclone_conf_check "$LINK") >/dev/null 2>&1; assert_eq 2 $? "a symbolic link is refused (EX_USAGE)"
(_rclone_conf_check "$EMPTY") >/dev/null 2>&1; assert_eq 4 $? "an empty file is refused (EX_REFUSED)"
(_rclone_conf_check "$BIG") >/dev/null 2>&1; assert_eq 4 $? "a file over 64 KiB is refused"
(_rclone_conf_check "$NODRIVE") >/dev/null 2>&1; assert_eq 4 $? "a config without a drive remote is refused"
(_rclone_conf_check "$NOSECTION") >/dev/null 2>&1; assert_eq 4 $? "a config without any [remote] is refused"
assert_eq "gdrive drive
other s3" "$(awk "$RCLONE_AWK" "$GOOD")" "the names and types are read, and only those (the token is not in the output)"
assert_not_contains "$(awk "$RCLONE_AWK" "$GOOD")" "$TOKEN_MARK" "no token in what the config's reader prints"

echo "rclone install: the copy is given to the game's user and moved into place; a second install needs --replace"
m rclone install "$GOOD"; assert_eq 0 "$RC" "mcctl rclone install exits 0"
assert_file "$SB/secrets/rclone/rclone.conf" "secrets/rclone/rclone.conf is in place"
assert_eq "$(cat "$GOOD")" "$(cat "$SB/secrets/rclone/rclone.conf")" "it is the file that was installed, byte for byte"
assert_no_file "$SB/secrets/.rclone-new" "the staging copy is gone after the move"
assert_contains "$OUT" "rclone config installed" "and it says so"
assert_contains "$OUT" "gdrive drive" "and lists the remotes by name and type"
assert_not_contains "$OUT" "$TOKEN_MARK" "the token is in no output"
assert_contains "$OUT" "delete" "and it says to delete the source file: it holds the token"
assert_file "$GOOD" "the source file is not changed or removed by mcctl"
assert_contains "$(calls)" "sh -c chown" "the copy is given to the game's user (CHOWN, through a helper)"
assert_contains "$(calls)" 'chmod "$3" /m' "with this user's group and a mode (the host can see and read it, not write it)"
# the file is given first: once the folder is the game's, the host cannot look inside it to give the file (a live bug, fixed here)
fl=$(calls | grep -n 'rclone.conf:/m:rw' | head -n 1 | cut -d: -f1)
dl=$(calls | grep -n '\.rclone-new:/m:rw' | head -n 1 | cut -d: -f1)
[[ -n $fl && -n $dl ]] && ((fl < dl)) && pass "the file is given before its folder" || fail "the file is given before its folder" "$fl / $dl"
m rclone install "$GOOD"; assert_eq 4 "$RC" "a second install without --replace: EX_REFUSED"
assert_contains "$OUT" "add --replace" "and it names the option"
printf '[new]\ntype = drive\n' >"$SB/new.conf"
m rclone install "$SB/new.conf" --replace; assert_eq 0 "$RC" "--replace installs the new config"
assert_eq "$(cat "$SB/new.conf")" "$(cat "$SB/secrets/rclone/rclone.conf")" "the installed config is the new one"
m rclone install "$SB/new.conf" --replace --nope; assert_eq 2 "$RC" "an unknown option: EX_USAGE"
m rclone install; assert_eq 2 "$RC" "install with no file: EX_USAGE"
m rclone install "$NODRIVE"; assert_eq 4 "$RC" "a file without a drive remote is refused before anything is written"
assert_eq "$(cat "$SB/new.conf")" "$(cat "$SB/secrets/rclone/rclone.conf")" "and the installed config is unchanged by the refusal"
m rclone install "$GOOD" --replace >/dev/null
assert_contains "$(calls)" "sh -c rm -rf -- /m/rclone" "the replacement removes the old folder through the helper only"

echo "rclone remotes: names and types, never the token"
m rclone remotes; assert_eq 0 "$RC" "mcctl rclone remotes exits 0"
assert_contains "$OUT" "gdrive drive" "gdrive is listed as a drive"
assert_not_contains "$OUT" "$TOKEN_MARK" "no token is printed"
m rclone remotes extra; assert_eq 2 "$RC" "remotes with an argument: EX_USAGE"
rm -rf -- "$SB/secrets/rclone"
m rclone remotes; assert_eq 4 "$RC" "no config installed: EX_REFUSED"
assert_contains "$OUT" "no rclone config is installed" "and it says to install one"

echo "rclone check: the token is asked through the sidecar's image, as the game's user, with the installed config"
m rclone install "$GOOD" >/dev/null
echo 0 >"$FAKE_STATE/docker.run.about.rc"
m rclone check gdrive; assert_eq 0 "$RC" "mcctl rclone check gdrive exits 0 when rclone answers"
assert_contains "$(calls)" "--entrypoint rclone itzg/mc-backup about gdrive:" "the check runs rclone about in the sidecar's image"
assert_contains "$(calls)" "--user 1000:1000" "as the game's user"
assert_contains "$(calls)" "-v $SB/secrets/rclone:/config/rclone" "with the installed config mounted where the sidecar reads it"
assert_contains "$OUT" "gdrive: reachable" "and it says it is reachable"
assert_not_contains "$OUT$(calls)" "$TOKEN_MARK" "the token is in no output and no argument"
echo 1 >"$FAKE_STATE/docker.run.about.rc"
m rclone check gdrive; assert_eq 1 "$RC" "rclone cannot reach the remote: EX_FAIL"
assert_contains "$OUT" "the offsite copy would fail now" "and it says what that means"
rm -f "$FAKE_STATE/docker.run.about.rc"
m rclone check other; assert_eq 4 "$RC" "a remote that is not drive is refused"
m rclone check "bad name"; assert_eq 2 "$RC" "a remote name with a space: EX_USAGE"

echo "backup settings: show, then write the offsite schedule, the mount and the compose"
mk s1 stopped
m backup s1 settings; assert_eq 0 "$RC" "settings with no option shows the current settings"
assert_contains "$OUT" "backups every 24h" "the default interval is 24h, as the sidecar has it"
assert_contains "$OUT" "no offsite copy" "and there is no offsite copy"
assert_no_file "$SB/servers/s1/backup.env" "showing the settings writes nothing"
m backup s1 settings --interval 6h --offsite rclone --remote gdrive --local-days 2 --keep-days 7 --bwlimit 5M
assert_eq 0 "$RC" "the offsite schedule is written and applied"
benv=$(<"$SB/servers/s1/backup.env")
assert_contains "$benv" "BACKUP_INTERVAL=6h" "every 6 hours"
assert_contains "$benv" "BACKUP_ON_STARTUP=false" "no backup when the sidecar starts (a restart must not start one while players join)"
assert_contains "$benv" "PAUSE_IF_NO_PLAYERS=false" "a backup runs whether players are online or not"
assert_contains "$benv" "BACKUP_METHOD=tar" "the archive is written locally by tar (the image's rclone method would delete it)"
assert_contains "$benv" "TAR_COMPRESS_PARAMETERS=-1" "the fastest gzip: the save-off pause is as short as it can be"
assert_contains "$benv" "PRUNE_BACKUPS_DAYS=2" "local archives are kept 2 days"
assert_contains "$benv" "RCLONE_REMOTE=gdrive" "the remote is gdrive"
assert_contains "$benv" "RCLONE_DEST_DIR=mcctl/s1" "its folder is mcctl/NAME, one per server"
assert_contains "$benv" "RCLONE_KEEP_DAYS=7" "the remote keeps 7 days"
assert_contains "$benv" "RCLONE_BWLIMIT=5M" "the upload is limited to 5 MiB a second"
assert_contains "$benv" 'POST_BACKUP_SCRIPT=[ "${1:-2}" -le 1 ]' "the upload script is set"
assert_contains "$(<"$SB/servers/s1/server.env")" "BACKUP_ENV_FILE=backup.env" "server.env names backup.env, so the sidecar reads it"
ct=$(<"$SB/servers/s1/compose.yaml")
assert_contains "$ct" "      - ../../secrets/rclone:/config/rclone" "the sidecar gets the rclone config at /config/rclone"
assert_contains "$ct" "    cpus: 1" "the sidecar has one CPU at most"
assert_contains "$ct" "    mem_limit: 512m" "and 512 MiB"
assert_contains "$ct" 'POST_BACKUP_SCRIPT: "[ \"$${1:-2}\" -le 1 ]' "the script's $ is doubled in the compose file (compose must not fill it in)"
assert_not_contains "$ct" "$TOKEN_MARK" "no token in the compose file"
assert_contains "$(calls)" "docker compose -p mcctl-s1" "the server is applied (stopped: made again, still stopped)"
m backup s1 settings; assert_contains "$OUT" "offsite copy to gdrive:mcctl/s1, kept 7 day(s), upload limit 5M" "showing the settings shows the offsite copy"

echo "backup settings: refusals change nothing"
before=$(<"$SB/servers/s1/backup.env"); bcompose=$(<"$SB/servers/s1/compose.yaml")
for bad in "--interval 10m" "--interval 0h" "--interval 6x" "--local-days 0" "--local-days 400" "--keep-days 0" "--bwlimit 5X" "--offsite ftp" "--offsite none --remote gdrive" "--remote bad.name" "--remote nope" "--interval" "--wat 1"; do
    m backup s1 settings $bad
    case $bad in
        --remote\ nope) want=4 ;;
        *) want=2 ;;
    esac
    assert_eq "$want" "$RC" "settings $bad: refused (exit $want), nothing written"
done
assert_eq "$before" "$(<"$SB/servers/s1/backup.env")" "backup.env is as it was after the refusals"
assert_eq "$bcompose" "$(<"$SB/servers/s1/compose.yaml")" "compose.yaml is as it was after the refusals"
m backup s1 settings --offsite none; assert_eq 0 "$RC" "back to no offsite copy"
benv=$(<"$SB/servers/s1/backup.env")
assert_contains "$benv" "BACKUP_INTERVAL=6h" "the interval stays"
assert_not_contains "$benv" "RCLONE_REMOTE" "no RCLONE_REMOTE any more"
assert_not_contains "$benv" "POST_BACKUP_SCRIPT" "no upload script any more"
assert_not_contains "$(<"$SB/servers/s1/compose.yaml")" "secrets/rclone" "the sidecar's mount is removed"
m backup s1 settings --offsite rclone --remote gdrive; assert_eq 0 "$RC" "offsite again"
assert_contains "$(<"$SB/servers/s1/backup.env")" "RCLONE_REMOTE=gdrive" "and back in backup.env"
echo "PRUNE_BACKUPS_COUNT=7" >>"$SB/servers/s1/backup.env"
m backup s1 settings --local-days 3; assert_eq 0 "$RC" "a retention change"
assert_not_contains "$(<"$SB/servers/s1/backup.env")" "PRUNE_BACKUPS_COUNT" "the old count-based retention is removed: days are the rule"
assert_contains "$(<"$SB/servers/s1/backup.env")" "PRUNE_BACKUPS_DAYS=3" "and the days are set"

echo "backup settings: no installed config, or a remote that is not drive"
rm -rf -- "$SB/secrets/rclone"
m backup s1 settings --offsite rclone --remote gdrive; assert_eq 4 "$RC" "offsite with no config installed: EX_REFUSED"
assert_contains "$OUT" "no rclone config is installed" "and it says to install one"
(render_server_compose s1 "" >/dev/null 2>&1); assert_eq 3 $? "a backup.env that names a remote does not render without the installed config (EX_PREFLIGHT)"
m rclone install "$GOOD" >/dev/null
m backup s1 settings --offsite rclone --remote gdrive; assert_eq 0 "$RC" "installed: the same settings apply"

echo "the upload the sidecar runs after each backup: copies the newest archive of this server, deletes its old remote archives"
T=$SB/post; rm -rf -- "$T"; mkdir -p "$T/bk" "$T/bin"
cat >"$T/bin/rclone" <<'SH'
#!/bin/bash
echo "rclone $*" >>"$RCLONE_LOG"
[[ ${RCLONE_FAIL-} == 1 && $1 == copy ]] && exit 1
exit 0
SH
chmod +x "$T/bin/rclone"
POST=$(sed -n 's/^POST_BACKUP_SCRIPT=//p' "$SB/servers/s1/backup.env")
printf '#!/bin/bash\n\n%s' "$POST" >"$T/post"; chmod +x "$T/post"
touch -d '2026-10-25 10:00' "$T/bk/s1-20261025-100000.tar.gz"
touch -d '2026-10-25 16:00' "$T/bk/s1-20261025-160000.tar.gz"
touch -d '2026-10-25 04:00' "$T/bk/other-20261025-040000.tar.gz"
run_post() {  # STATUS [FAIL]: the sidecar's call, with the environment mcctl gives the sidecar
    : >"$T/log"
    env -i PATH="$T/bin:/usr/bin:/bin" RCLONE_LOG="$T/log" DEST_DIR="$T/bk" BACKUP_NAME=s1 \
        RCLONE_REMOTE=gdrive RCLONE_DEST_DIR=mcctl/s1 RCLONE_KEEP_DAYS=7 RCLONE_FAIL="${2-}" "$T/post" "$1" "$T/backup.log"
}
run_post 0
assert_eq "rclone copy $T/bk/s1-20261025-160000.tar.gz gdrive:mcctl/s1
rclone delete gdrive:mcctl/s1 --min-age 7d --include s1-*.tar.gz" "$(cat "$T/log")" "status 0: the newest archive of s1 is copied, then the old remote ones are deleted (other servers' archives are not touched)"
run_post 1
assert_contains "$(cat "$T/log")" "rclone copy $T/bk/s1-20261025-160000.tar.gz" "status 1 (a file changed while it was read): the archive is whole, so it is uploaded"
run_post 2
assert_eq "" "$(cat "$T/log")" "status 2 (tar failed): nothing is uploaded and nothing is deleted"
run_post ""
assert_eq "" "$(cat "$T/log")" "no status: nothing is uploaded (the default is the failure)"
run_post 0 1
assert_eq "rclone copy $T/bk/s1-20261025-160000.tar.gz gdrive:mcctl/s1" "$(cat "$T/log")" "a failed copy: the delete does not run, so no remote archive is lost"
rm -f -- "$T/bk"/*
run_post 0
assert_eq "" "$(cat "$T/log")" "no archive at all: nothing is called"
assert_not_contains "$(cat "$T/log")" "$TOKEN_MARK" "no token in the upload's log"

echo "rclone and the CLI: every command is named, and an unknown subcommand is EX_USAGE"
m rclone; assert_eq 2 "$RC" "mcctl rclone with no subcommand: EX_USAGE"
m rclone frob; assert_eq 2 "$RC" "an unknown subcommand: EX_USAGE"
m backup s1 frob; assert_eq 2 "$RC" "an unknown backup subcommand: EX_USAGE"

echo "the token marker reaches no output, log or argument of any command above"
assert_not_contains "$ALL$(calls)$(cat "$SB/servers/s1/compose.yaml" "$SB/servers/s1/backup.env" 2>/dev/null)" "$TOKEN_MARK" \
    "the token is not in the compose file or backup.env (it lives only in secrets/rclone)"

sandbox_cleanup
finish

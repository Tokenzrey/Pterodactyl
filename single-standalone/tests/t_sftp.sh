#!/usr/bin/env bash
# lib/sftp.sh: sftp_add_user, sftp_remove_user, sftp_render, sftp_repair, cmd_sftp (add-key, remove-key, repair), and the SFTP parts
# of create, delete, up and down. The SFTP service is its own compose project (mcctl-sftp, the generated sftp.compose.yml); the
# router stack has nothing of it. E1: ordered call logs. E3: no eval, no sudo, no $ in the generated file. E4: the key text
# never reaches output or the call log. E12: modes. Whether atmoz/sftp reads the key mount, and whether a login works, is for the
# acceptance run on a real host (Task 23); here the generated file is checked as text.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/rcon.sh"
source "$REPO/lib/router.sh"
source "$REPO/lib/cloudflare.sh"
source "$REPO/lib/backup.sh"
source "$REPO/lib/sftp.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
fake_cloudflare

COMPOSE=$SB/sftp.compose.yml
UPCALL="docker compose -p mcctl-sftp -f $COMPOSE up -d --force-recreate sftp"
reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
# clean NAME: forget the server and all of SFTP's state; the SFTP container is "not running" again
clean() {
    local n=$1
    rm -rf -- "$SB/servers/$n" "$SB/sftp-users.conf" "$SB/sftp-keys" "$COMPOSE" "$SB/secrets/rcon-$n"
    rm -f -- "$FAKE_STATE"/docker.ps.label_mcctl_name_$n "$FAKE_STATE"/docker.ps.label_mcctl_hostname_$n "$FAKE_STATE/docker.compose.ps.running.sftp"
}
make_server_dir() { mkdir -p "$SB/servers/$1/data"; }
make_pubkey() { printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey test@example.com\n' >"$SB/testkey.pub"; printf '%s\n' "$SB/testkey.pub"; }
sftp_running() { echo cid-sftp >"$FAKE_STATE/docker.compose.ps.running.sftp"; }
# the lines of the generated file that are mounts, as they must read
m_users() { printf '      - "%s/sftp-users.conf:/etc/sftp/users.conf:ro"' "$SB"; }
m_data()  { printf '      - "%s/servers/%s/data:/home/%s/%s"' "$SB" "$1" "$1" "$1"; }
m_key()   { printf '      - "%s/sftp-keys/%s:/home/%s/.ssh/keys/%s.pub:ro"' "$SB" "$1" "$1" "$1"; }
has_line() { grep -qxF -- "$1" "$COMPOSE" 2>/dev/null; }
assert_line()    { if has_line "$1"; then pass "$2"; else fail "$2" "no such line: $1"; fi; }
assert_no_line() { if has_line "$1"; then fail "$2" "unexpected line: $1"; else pass "$2"; fi; }
# body: the generated file without comments
body() { sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]*#.*$//' "$COMPOSE"; }

echo "sftp_add_user: users.conf and the generated compose file"
reset; clean s1; make_server_dir s1
sftp_add_user s1 2>/dev/null; assert_eq 0 "$?" "sftp_add_user s1 succeeds"
assert_file "$SB/sftp-users.conf" "users.conf is created"
assert_eq "s1::1000:1000:s1" "$(<"$SB/sftp-users.conf")" "the line is exactly NAME::1000:1000:NAME (empty password, bare directory name)"
assert_mode "$SB/sftp-users.conf" 600 "users.conf is mode 600"
assert_file "$COMPOSE" "sftp.compose.yml is written"
assert_line "$(m_users)" "it mounts users.conf read-only at /etc/sftp/users.conf"
assert_line "$(m_data s1)" "the data folder of s1 is mounted read-write at /home/s1/s1"
assert_no_line "$(m_key s1)" "and there is no key mount while there is no key (Docker would make a directory of the missing file)"
assert_eq 'services:
  sftp:
    image: atmoz/sftp
    container_name: mcctl-sftp
    restart: unless-stopped
    ports:
      - "127.0.0.1:2222:22"
    volumes:
      - "'"$SB"'/sftp-users.conf:/etc/sftp/users.conf:ro"
      - "'"$SB"'/servers/s1/data:/home/s1/s1"
      - mcctl-sftp-hostkeys:/etc/ssh
    cap_drop: [ALL]
    cap_add: [CHOWN, SETGID, SETUID, FOWNER, DAC_OVERRIDE, SYS_CHROOT]
    security_opt: ["no-new-privileges:true"]
    mem_limit: 128m
    pids_limit: 128

volumes:
  mcctl-sftp-hostkeys:' "$(body)" "the whole generated file, comments aside"
assert_mode "$COMPOSE" 644 "sftp.compose.yml is mode 644"
assert_eq "" "$(find "$SB" -maxdepth 1 -name 'sftp.compose.yml.*')" "and no temporary file is left beside it"

echo "sftp_add_user is idempotent"
reset
sftp_add_user s1 2>/dev/null
assert_eq 1 "$(grep -c '^s1:' "$SB/sftp-users.conf")" "only one entry per user"
assert_eq 1 "$(grep -c '/home/s1/s1"$' "$COMPOSE")" "and one data mount"

echo "sftp_add_user: refusals"
reset
sftp_add_user 'BAD NAME!' 2>/dev/null; assert_eq "$EX_USAGE" "$?" "a bad name exits EX_USAGE"
sftp_add_user '../x' 2>/dev/null;      assert_eq "$EX_USAGE" "$?" "a path as the name exits EX_USAGE"
clean s1
sftp_add_user s1 2>/dev/null; assert_eq "$EX_FAIL" "$?" "a missing data directory exits EX_FAIL"
assert_no_file "$COMPOSE" "and nothing is rendered"
assert_eq "" "$(calls)" "and Docker is not asked"

echo "one entry and two mounts per server"
reset; clean s1; clean s2; make_server_dir s1; make_server_dir s2
sftp_add_user s1 2>/dev/null
sftp_add_user s2 2>/dev/null
assert_eq 2 "$(grep -c ':' "$SB/sftp-users.conf")" "two entries for two servers"
assert_line "$(m_data s1)" "the data mount of s1"
assert_line "$(m_data s2)" "the data mount of s2"
assert_eq 1 "$(grep -c 'ports:' "$COMPOSE")" "one ports: key in the file"
assert_eq '      - "127.0.0.1:2222:22"' "$(awk '/^[[:space:]]*ports:/ {p=1; next} p && /^[[:space:]]*-/ {print; next} {p=0}' "$COMPOSE")" "and one published port, on 127.0.0.1 by default"

echo "the published port"
MCCTL_SFTP_PUBLIC=1 sftp_render 2>/dev/null
assert_eq '      - "0.0.0.0:2222:22"' "$(awk '/^[[:space:]]*ports:/ {p=1; next} p && /^[[:space:]]*-/ {print; next} {p=0}' "$COMPOSE")" "MCCTL_SFTP_PUBLIC=1 publishes it on 0.0.0.0, and it is still the only one"
MCCTL_SFTP_PUBLIC=0 sftp_render 2>/dev/null
assert_line '      - "127.0.0.1:2222:22"' "MCCTL_SFTP_PUBLIC=0 is 127.0.0.1"
MCCTL_SFTP_PUBLIC=yes sftp_render 2>/dev/null
assert_line '      - "127.0.0.1:2222:22"' "and so is any value but 1"
sftp_render 2>/dev/null
assert_line '      - "127.0.0.1:2222:22"' "and so is no value"
clean s2

echo "the router stack has no SFTP"
for f in "$REPO/templates/stack.compose.yml" "$SB/templates/stack.compose.yml"; do
    assert_eq 0 "$(grep -c '^  sftp:' "$f")" "${f#"$SB"/}: no sftp service"
    assert_eq 0 "$(grep -c 2222 "$f")" "${f#"$SB"/}: no port 2222"
    assert_eq 0 "$(grep -ci 'sftp' "$f")" "${f#"$SB"/}: not even the word"
done
assert_file "$REPO/templates/sftp.compose.yml" "the SFTP template is its own file"

echo "a path that cannot be written safely is refused before any file is written"
reset; clean s1; make_server_dir s1
sftp_add_user s1 2>/dev/null
cp "$COMPOSE" "$SB/sftp.compose.before"
NLROOT="$SB/nl"$'\n'"x"
mkdir -p "$NLROOT/servers/s1/data" 2>/dev/null
printf 's1::1000:1000:s1\n' >"$NLROOT/sftp-users.conf" 2>/dev/null
( MCCTL_ROOT=$NLROOT; sftp_render ) 2>/dev/null; assert_eq "$EX_PREFLIGHT" "$?" "a newline in the folder path: EX_PREFLIGHT"
assert_no_file "$NLROOT/sftp.compose.yml" "and no sftp.compose.yml is written there"
assert_eq "" "$(ls -A "$NLROOT" 2>/dev/null | grep -F 'tmp')" "and no temporary file"
out=$( ( MCCTL_ROOT=$NLROOT; sftp_render ) 2>&1 ); assert_contains "$out" "control character" "the message says why"
( MCCTL_ROOT="$SB/a:b"; sftp_render ) 2>/dev/null; assert_eq "$EX_PREFLIGHT" "$?" "a ':' in the folder path: EX_PREFLIGHT (it would end the host path of the mount)"
assert_eq "$(<"$SB/sftp.compose.before")" "$(<"$COMPOSE")" "and the generated file of the real root is as it was"
printf 'Bad!::1000:1000:x\n' >>"$SB/sftp-users.conf"
sftp_render 2>/dev/null; assert_eq "$EX_PREFLIGHT" "$?" "a users.conf line that is not a server name: EX_PREFLIGHT"
assert_eq "$(<"$SB/sftp.compose.before")" "$(<"$COMPOSE")" "and the old file stays"
reset; clean s1
printf 'Bad!::1000:1000:x\n' >"$SB/sftp-users.conf"
sftp_render 2>/dev/null; assert_no_file "$COMPOSE" "and none is made"
rm -rf -- "$SB/nl"* "$SB/sftp.compose.before"
clean s1

echo "a user whose data folder is gone is left out, not fatal"
reset; make_server_dir s1; make_server_dir s2
sftp_add_user s1 2>/dev/null; sftp_add_user s2 2>/dev/null
rm -rf -- "$SB/servers/s1"
out=$(sftp_render 2>&1); assert_eq 0 "$?" "render still succeeds"
assert_contains "$out" "s1: $SB/servers/s1/data does not exist" "and warns"
assert_no_line "$(m_data s1)" "s1 gets no mount (Docker would make a root-owned folder there)"
assert_line "$(m_data s2)" "s2 keeps its mount"
clean s1; clean s2

echo "cmd_sftp add-key"
reset; clean s1; make_server_dir s1
sftp_add_user s1 2>/dev/null
_kf=$(make_pubkey)
( cmd_sftp add-key s1 "$_kf" ) 2>/dev/null; assert_eq 0 "$?" "a valid public key is accepted"
assert_file "$SB/sftp-keys/s1" "the key file sftp-keys/s1 is created"
assert_eq "$(<"$_kf")" "$(<"$SB/sftp-keys/s1")" "and holds the key"
assert_mode "$SB/sftp-keys/s1" 600 "mode 600"
assert_line "$(m_key s1)" "the key is mounted read-only at /home/s1/.ssh/keys/s1.pub (the place atmoz/sftp reads)"
assert_line "$(m_data s1)" "and the data mount is still there"
printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQsecondkey second@example.com\n' >"$SB/second.pub"
( cmd_sftp add-key s1 "$SB/second.pub" ) 2>/dev/null
assert_eq 2 "$(grep -c . "$SB/sftp-keys/s1")" "a second key is appended, not replacing the first"
assert_eq 1 "$(grep -c 'keys/s1.pub' "$COMPOSE")" "and the key mount is still one line"
_badf=$SB/badkey.txt
printf 'this is not a key\n' >"$_badf"
( cmd_sftp add-key s1 "$_badf" ) 2>/dev/null; assert_eq "$EX_USAGE" "$?" "a file that is not a public key exits EX_USAGE"
assert_eq 2 "$(grep -c . "$SB/sftp-keys/s1")" "and is not appended"
( cmd_sftp add-key s1 /nonexistent ) 2>/dev/null; assert_eq "$EX_USAGE" "$?" "a missing file exits EX_USAGE"
( cmd_sftp add-key 'BAD!' "$_kf" ) 2>/dev/null; assert_eq "$EX_USAGE" "$?" "a bad server name exits EX_USAGE"
( cmd_sftp add-key s1 ) 2>/dev/null; assert_eq "$EX_USAGE" "$?" "a missing argument exits EX_USAGE"
clean s1

echo "cmd_sftp remove-key"
reset; clean s1; make_server_dir s1
sftp_add_user s1 2>/dev/null
( cmd_sftp add-key s1 "$_kf" ) 2>/dev/null
assert_line "$(m_key s1)" "(before: the key mount exists)"
( cmd_sftp remove-key s1 ) 2>/dev/null; assert_eq 0 "$?" "remove-key s1"
assert_no_file "$SB/sftp-keys/s1" "the key file is removed"
assert_no_line "$(m_key s1)" "and so is its mount line"
assert_line "$(m_data s1)" "the data mount stays"
assert_eq "s1::1000:1000:s1" "$(<"$SB/sftp-users.conf")" "and so does the user"
( cmd_sftp remove-key s1 ) 2>/dev/null; assert_eq 0 "$?" "remove-key again (no key left) is fine"
( cmd_sftp remove-key 'BAD!' ) 2>/dev/null; assert_eq "$EX_USAGE" "$?" "a bad server name exits EX_USAGE"
( cmd_sftp remove-key ) 2>/dev/null; assert_eq "$EX_USAGE" "$?" "no name exits EX_USAGE"
( cmd_sftp ) 2>/dev/null; assert_eq "$EX_USAGE" "$?" "no subcommand exits EX_USAGE"
( cmd_sftp bogus ) 2>/dev/null; assert_eq "$EX_USAGE" "$?" "an unknown subcommand exits EX_USAGE"
( cmd_sftp repair now ) 2>/dev/null; assert_eq "$EX_USAGE" "$?" "repair takes no argument"
clean s1

echo "sftp_remove_user"
reset; clean s1; make_server_dir s1; make_server_dir s2
sftp_add_user s1 2>/dev/null; sftp_add_user s2 2>/dev/null
( cmd_sftp add-key s1 "$_kf" ) 2>/dev/null
sftp_remove_user s1; assert_eq 0 "$?" "sftp_remove_user s1"
assert_eq "s2::1000:1000:s2" "$(<"$SB/sftp-users.conf")" "the user line is gone, the other stays"
assert_no_file "$SB/sftp-keys/s1" "the key file is gone"
assert_no_line "$(m_data s1)" "the data mount is gone"
assert_no_line "$(m_key s1)" "and the key mount"
assert_line "$(m_data s2)" "the other server keeps its mount"
reset; clean s1; clean s2
sftp_remove_user s1; assert_eq 0 "$?" "removing a user that does not exist is fine"
assert_no_file "$COMPOSE" "and writes nothing"
assert_eq "" "$(calls)" "and does not ask Docker"
sftp_remove_user 'BAD!' 2>/dev/null; assert_eq "$EX_USAGE" "$?" "a bad name exits EX_USAGE"

echo "a users.conf that grep cannot read is left as it was"
# grep exits 2 when it cannot read the file (1 only means no line is left, which the idempotent add and the delete above rely on). A
# shell function named grep shadows the real one inside the subshell; it makes grep -v fail the way a read error does.
reset; clean s1; clean s2; make_server_dir s1; make_server_dir s2
sftp_add_user s1 2>/dev/null; sftp_add_user s2 2>/dev/null
( cmd_sftp add-key s1 "$_kf" ) 2>/dev/null
before=$(cksum "$SB/sftp-users.conf"); reset
out=$( grep() { return 2; }; sftp_add_user s1 2>&1 ); rc=$?
assert_eq "$EX_FAIL" "$rc" "sftp_add_user for an existing user, grep failing: EX_FAIL"
assert_contains "$out" "cannot read $SB/sftp-users.conf; nothing was changed" "and it says what happened"
assert_eq "$before" "$(cksum "$SB/sftp-users.conf")" "users.conf is byte-identical (the other user's line is not lost)"
assert_no_file "$SB/sftp-users.conf.tmp" "and no users.conf.tmp is left"
assert_eq "" "$(calls)" "and Docker is not asked"
out=$( grep() { return 2; }; sftp_remove_user s1 2>&1 ); rc=$?
assert_eq "$EX_FAIL" "$rc" "sftp_remove_user for an existing user, grep failing: EX_FAIL"
assert_contains "$out" "cannot read $SB/sftp-users.conf; nothing was changed" "and it says what happened"
assert_eq "$before" "$(cksum "$SB/sftp-users.conf")" "users.conf is byte-identical"
assert_no_file "$SB/sftp-users.conf.tmp" "and no users.conf.tmp is left"
assert_file "$SB/sftp-keys/s1" "and the key file is still there (nothing was changed)"
assert_eq "" "$(calls)" "and Docker is not asked"
clean s1; clean s2

echo "create sets SFTP up; delete takes it away"
reset; clean s1
m create c1 --type PAPER --accept-eula
assert_eq 0 "$RC" "create c1 succeeds"
assert_eq "c1::1000:1000:c1" "$(<"$SB/sftp-users.conf")" "create adds the user line"
assert_line "$(m_data c1)" "and the mount of its data folder, in sftp.compose.yml"
assert_contains "$(calls)" "$(sftp_ps_call)" "create asked whether SFTP runs"
assert_not_contains "$(calls)" "force-recreate" "and, as it does not, did not recreate it"
m sftp add-key c1 "$_kf"
assert_eq 0 "$RC" "mcctl sftp add-key c1 KEY"
assert_line "$(m_key c1)" "the key mount appears"
reset
m --yes delete c1
assert_eq 0 "$RC" "delete c1 succeeds"
assert_eq "" "$(<"$SB/sftp-users.conf")" "delete removes the user line"
assert_no_file "$SB/sftp-keys/c1" "and the key file"
assert_no_line "$(m_data c1)" "and the data mount"
assert_no_line "$(m_key c1)" "and the key mount"
assert_eq 1 "$(count_calls "$(sftp_ps_call)")" "delete asked whether SFTP runs, once"
assert_eq 0 "$(count_calls 'force-recreate')" "and, as it does not, recreated nothing"

echo "a running SFTP container is recreated; a stopped one is not"
reset; clean s1; make_server_dir s1
sftp_add_user s1 2>/dev/null
sftp_running
reset
( cmd_sftp add-key s1 "$_kf" ) 2>/dev/null
assert_eq "$(sftp_ps_call)
$UPCALL" "$(calls)" "add-key: asks, then docker compose -p mcctl-sftp up -d --force-recreate sftp"
reset
( cmd_sftp remove-key s1 ) 2>/dev/null
assert_eq "$(sftp_ps_call)
$UPCALL" "$(calls)" "remove-key: the same"
reset
sftp_add_user s1 2>/dev/null
assert_eq "$(sftp_ps_call)
$UPCALL" "$(calls)" "sftp_add_user: the same"
reset
( cmd_sftp repair ) 2>/dev/null; assert_eq 0 "$?" "mcctl sftp repair"
assert_eq "$(sftp_ps_call)
$UPCALL" "$(calls)" "repair: the same"
rm -f "$FAKE_STATE/docker.compose.ps.running.sftp"
reset
( cmd_sftp add-key s1 "$_kf" ) 2>/dev/null
assert_eq "$(sftp_ps_call)" "$(calls)" "SFTP stopped, add-key: only the question, no recreate"
reset
( cmd_sftp remove-key s1 ) 2>/dev/null
assert_eq "$(sftp_ps_call)" "$(calls)" "SFTP stopped, remove-key: the same"
reset
( cmd_sftp repair ) 2>/dev/null
assert_eq "$(sftp_ps_call)" "$(calls)" "SFTP stopped, repair: the same"
echo 1 >"$FAKE_STATE/docker.compose.up.rc"; sftp_running
reset
( cmd_sftp repair ) 2>/dev/null; assert_eq "$EX_FAIL" "$?" "repair when the recreate fails: EX_FAIL"
sftp_add_user s1 2>/dev/null; assert_eq "$EX_FAIL" "$?" "sftp_add_user when the recreate fails: EX_FAIL"
rm -f "$FAKE_STATE/docker.compose.up.rc"
clean s1

echo "delete of the last SFTP user stops a running SFTP container (it would restart-loop with no user)"
reset; clean s1
m create c2 --type PAPER --accept-eula
assert_eq 0 "$RC" "create c2 succeeds"
sftp_running
reset
m --yes delete c2
assert_eq 0 "$RC" "delete c2 succeeds"
assert_eq 1 "$(count_calls "docker compose -p mcctl-sftp -f $COMPOSE stop sftp")" "delete ran docker compose -p mcctl-sftp stop sftp once"
assert_eq 0 "$(count_calls "$UPCALL")" "and no recreate, since no user is left"
assert_contains "$(calls)" "$(sftp_ps_call)
docker compose -p mcctl-sftp -f $COMPOSE stop sftp" "right after it asked"
assert_no_line "$(m_data c2)" "and the data mount of c2 is gone from the file the container was recreated from"
rm -f "$FAKE_STATE/docker.compose.ps.running.sftp"

echo "a failing SFTP does not block create"
reset; clean s1
mkdir -p "$COMPOSE"   # a directory where the generated file belongs: sftp_render cannot write it
m create c3 --type PAPER --accept-eula
assert_eq 0 "$RC" "create c3 still succeeds"
assert_contains "$OUT" "WARN: c3: SFTP could not be set up" "it warns, naming the server"
assert_contains "$OUT" "mcctl sftp repair" "and the next step"
assert_contains "$OUT" "cannot write $COMPOSE" "the cause is shown, not hidden"
assert_file "$SB/servers/c3/compose.yaml" "the server exists"
assert_contains "$(calls)" "docker compose -p mcctl-c3 -f $SB/servers/c3/compose.yaml create" "and its container was made"
assert_eq "c3::1000:1000:c3" "$(<"$SB/sftp-users.conf")" "its user line is in users.conf"
rmdir "$COMPOSE"
m sftp repair
assert_eq 0 "$RC" "mcctl sftp repair, after the cause is gone"
assert_line "$(m_data c3)" "writes the file with its mount"
reset
rm -f "$COMPOSE"; mkdir -p "$COMPOSE"
m --yes delete c3
assert_eq 0 "$RC" "a failing SFTP does not block delete either"
assert_contains "$OUT" "WARN: c3: SFTP could not be updated" "it warns"
assert_contains "$OUT" "mcctl sftp repair" "and names the next step"
assert_no_file "$SB/servers/c3" "the server is deleted"
rmdir "$COMPOSE"
m sftp repair; assert_eq 0 "$RC" "repair after the delete"
assert_no_line "$(m_data c3)" "leaves no mount of the deleted server"

echo "_remove_files: the name check sits right above the rm"
reset; clean s1; make_server_dir s1; make_server_dir s2
mkdir -p "$SB/keepme"; touch "$SB/keepme/sentinel"
sftp_add_user s1 2>/dev/null
_remove_files '../keepme' 2>/dev/null; assert_eq "$EX_USAGE" "$?" "a path as the name is refused: EX_USAGE"
assert_file "$SB/keepme/sentinel" "and nothing outside servers/ was removed"
_remove_files 'S1' 2>/dev/null; assert_eq "$EX_USAGE" "$?" "an upper-case name is refused"
_remove_files '' 2>/dev/null; assert_eq "$EX_USAGE" "$?" "an empty name is refused"
assert_file "$SB/servers/s1/data" "and servers/s1 is untouched"
assert_eq "s1::1000:1000:s1" "$(<"$SB/sftp-users.conf")" "as is its SFTP user"
_remove_files s1 2>/dev/null; assert_eq 0 "$?" "a valid name is removed"
assert_no_file "$SB/servers/s1" "its folder is gone"
assert_eq "" "$(<"$SB/sftp-users.conf")" "and its SFTP user"
assert_file "$SB/servers/s2/data" "another server is untouched"
rm -rf -- "$SB/keepme"
grep -B1 'rm -rf -- "\$MCCTL_ROOT/servers/\$name"' "$REPO/lib/servers.sh" | head -n 1 | grep -q 'valid_server_name "\$name" || return "\$EX_USAGE"' \
    && pass "(servers.sh: the line above the rm -rf is the valid_server_name check)" || fail "servers.sh: valid_server_name is not directly above the rm -rf"
clean s1; clean s2

echo "mcctl up starts the router stack and then SFTP; mcctl down stops both"
reset; clean s1; make_server_dir s1
sftp_add_user s1 2>/dev/null
rm -f "$COMPOSE"
reset
m up
assert_eq 0 "$RC" "up succeeds"
assert_eq "docker compose -p mcctl-stack -f $SB/templates/stack.compose.yml up -d --wait
docker compose -p mcctl-sftp -f $COMPOSE up -d --force-recreate sftp" "$(calls | grep ' up ')" "up: the router stack first, then mcctl-sftp, recreated"
assert_line "$(m_data s1)" "sftp.compose.yml was rendered first (it holds the mount of s1)"
assert_contains "$OUT" "SFTP up on 127.0.0.1:2222" "and the message names the address"
reset
MCCTL_SFTP_PUBLIC=1 m up
assert_contains "$OUT" "SFTP up on 0.0.0.0:2222" "with MCCTL_SFTP_PUBLIC=1 it says 0.0.0.0"
assert_line '      - "0.0.0.0:2222:22"' "and the file says it too"
reset
m down
assert_eq 0 "$RC" "down succeeds"
assert_eq "docker compose -p mcctl-stack -f $SB/templates/stack.compose.yml down
docker compose -p mcctl-sftp -f $COMPOSE down" "$(calls | grep ' down')" "down: the router stack, then mcctl-sftp"
reset
echo 1 >"$FAKE_STATE/docker.compose.up.rc"
m up
assert_eq 1 "$RC" "up when compose up fails: EX_FAIL"
assert_eq 1 "$(calls | grep -c ' up ')" "and SFTP is not started after a failed router stack"
rm -f "$FAKE_STATE/docker.compose.up.rc"
reset
echo 1 >"$FAKE_STATE/docker.compose.down.rc"
m down
assert_eq 1 "$RC" "down when compose down fails: EX_FAIL"
assert_eq 1 "$(calls | grep -c ' down')" "and SFTP is not stopped by a failed router stack down (the message says what is still up)"
rm -f "$FAKE_STATE/docker.compose.down.rc"
clean s1

echo "E3: no eval, no sudo, no \$ or placeholder in the generated file"
assert_eq "" "$(grep -nwE 'eval|sudo' "$REPO/lib/sftp.sh" "$REPO/templates/sftp.compose.yml" | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#')" "lib/sftp.sh and its template have neither eval nor sudo"
reset; clean s1; make_server_dir s1
sftp_add_user s1 2>/dev/null
( cmd_sftp add-key s1 "$_kf" ) 2>/dev/null
assert_eq 0 "$(grep -c '[$]' "$COMPOSE")" "the generated file has no \$"
assert_eq 0 "$(grep -c '{{' "$COMPOSE")" "and no placeholder is left in it"
assert_eq 0 "$(grep -c '[$]' "$REPO/templates/sftp.compose.yml")" "the template has no \$ either"
for fn in sftp_render sftp_repair cmd_sftp sftp_up sftp_down; do
    declare -F "$fn" >/dev/null && pass "$fn is defined" || fail "$fn is defined"
done
m sftp bogus; assert_eq 2 "$RC" "mcctl sftp bogus: EX_USAGE"
assert_contains "$OUT" "usage: mcctl sftp add-key NAME PUBKEYFILE | remove-key NAME | repair" "with the usage"
m help; assert_contains "$OUT" "sftp" "mcctl help lists the sftp command"

echo "E4: the key text never reaches output or the call log"
reset; clean s1; make_server_dir s1
sftp_add_user s1 2>/dev/null
plant_canary "$SB/canary.tmp"; _kc=$CANARY
printf 'ssh-ed25519 %s canary@example.com\n' "$_kc" >"$SB/canary.pub"
sftp_running
reset
m sftp add-key s1 "$SB/canary.pub"
assert_eq 0 "$RC" "add-key of the canary key"
assert_not_contains "$OUT$(calls)" "$_kc" "its text is in neither the output nor the call log"
assert_not_contains "$(<"$COMPOSE")" "$_kc" "nor in the generated compose file (only the path of the key file is)"
assert_contains "$(<"$SB/sftp-keys/s1")" "$_kc" "(it is in the key file, which is the point)"
reset; ALL=""
m sftp repair; ALL+=$OUT
m sftp remove-key s1; ALL+=$OUT
assert_not_contains "$ALL$(calls)" "$_kc" "nor after repair or remove-key"
assert_not_contains "$ALL$(calls)" "$CF_TOKEN" "and the Cloudflare token is in none of them either"
rm -f "$SB/canary.tmp" "$SB/canary.pub" "$FAKE_STATE/docker.compose.ps.running.sftp"
clean s1

echo "E12: modes"
reset; clean s1; make_server_dir s1
sftp_add_user s1 2>/dev/null
( cmd_sftp add-key s1 "$_kf" ) 2>/dev/null
assert_mode "$SB/sftp-users.conf" 600 "sftp-users.conf is 600"
assert_mode "$SB/sftp-keys" 700 "sftp-keys/ is 700"
assert_mode "$SB/sftp-keys/s1" 600 "a key file is 600"
assert_mode "$COMPOSE" 644 "sftp.compose.yml is 644"
clean s1

finish

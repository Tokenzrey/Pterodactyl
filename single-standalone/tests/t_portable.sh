#!/usr/bin/env bash
# lib/portable.sh (Task 21): info, clone, rename, export, import, exec and shell, and the create steps they share (_provision in
# lib/servers.sh). Each command runs as ./mcctl in a sandbox with the fakes: the docker fake keeps the containers (docker.stateful), and
# fakebin/curl keeps the DNS records. E1: the ordered call log. E4: the RCON passwords and the Cloudflare token are in no output and no
# call. The E7 loops are in t_failure.sh, the hostile archives in t_archive.sh, the round trip and the flows in t_flows.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
for _lib in "$REPO"/lib/*.sh; do [[ $_lib == */common.sh ]] || source "$_lib"; done   # the same set, in-process, as mcctl loads
sandbox
export MCCTL_DOMAIN=mc.example.net MCCTL_HOME=$REPO
fake_cloudflare
: >"$FAKE_STATE/docker.stateful"
ALL=""                                                   # every output, searched for the secrets at the end (E4)
run() { m "$@"; ALL+=$OUT$'\n'; }
reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; rm -f -- "$FAKE_STATE"/run.stdin.* "$FAKE_STATE/docker.run.tar.rc"; }
pos() { calls | grep -n -E -- "$1" | head -n 1 | cut -d: -f1; }   # the position of the first call that matches, in the ordered log
secret() { cat -- "$SB/secrets/rcon-$1"; }
dnsof() { dns_records | grep -E "^$1\.mc\.example\.net " || true; }   # the DNS records of one host name (the zone holds many)
same() { if cmp -s -- "$1" "$2"; then pass "$3"; else fail "$3" "$1 and $2 differ"; fi; }
# data_tar: the helper's answer for data/ (tar -cf - -C / data): one world, kept as docker.run.tar for the fake
data_tar() {
    rm -rf -- "$SB/exp"; mkdir -p "$SB/exp/data/world" && echo level >"$SB/exp/data/world/level.dat"
    tar -cf "$FAKE_STATE/docker.run.tar" -C "$SB/exp" data
}
# mkarch OUT MEMBER...: a gzip tar of the named members of $SB/arch, with their own names (as an export writes them)
mkarch() { local out=$1; shift; tar -czf "$out" -C "$SB/arch" "$@"; }
MCCTL_OK=(--type PAPER --accept-eula)

echo "info"
run info nope;                                    assert_eq 1 "$RC" "info of an unknown server: exit 1"
run info;                                         assert_eq 2 "$RC" "info with no name: exit 2"
run create s1 "${MCCTL_OK[@]}" --hostname s1h --backup local; assert_eq 0 "$RC" "create s1 (with a local backup)"
WANT=$(config_hash s1)
echo "exited|0001-01-01T00:00:00Z|$WANT" >"$FAKE_STATE/docker.inspect"
echo $'4096\t.' >"$FAKE_STATE/docker.run.du"
reset; run info s1; assert_eq 0 "$RC" "info of a stopped server: exit 0"
assert_contains "$OUT" "server:    s1" "the name"
assert_contains "$OUT" "type:      PAPER" "the type"
assert_contains "$OUT" "version:   LATEST" "the version (LATEST when none is set)"
assert_contains "$OUT" "modpack:   none" "no modpack: none"
assert_contains "$OUT" "memory:    4G" "the memory"
assert_contains "$OUT" "cpus:      2" "the cpus"
assert_contains "$OUT" "hostname:  s1h (s1h.mc.example.net)" "the hostname and its fqdn"
assert_contains "$OUT" "state:     exited" "the state (no uptime for a stopped server)"
assert_contains "$OUT" "config:    current" "config: current, the label is the hash of the files"
assert_contains "$OUT" "world:     world, 4096 KiB" "the active world and its size"
assert_contains "$OUT" "data:      4096 KiB" "the data size (du in the helper)"
assert_contains "$OUT" "backup:    tar, newest file none" "the backup method from backup.env, and no backup yet"
assert_eq "" "$(calls | grep -v -E '^docker (ps|inspect|run) ')" "info only reads: docker ps, inspect and the helper's du"
echo "running|$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)|$WANT" >"$FAKE_STATE/docker.inspect"
run info s1; assert_contains "$OUT" "state:     running, up 2h" "a running server shows its uptime"
echo "exited|0001-01-01T00:00:00Z|0000" >"$FAKE_STATE/docker.inspect"
run info s1; assert_contains "$OUT" "config:    pending" "a hash that differs from the files' is pending"
echo "exited||" >"$FAKE_STATE/docker.inspect"
run info s1; assert_contains "$OUT" "config:    unknown" "no label (created before tracking): unknown"
echo "exited|0001-01-01T00:00:00Z|$WANT" >"$FAKE_STATE/docker.inspect"
echo 1 >"$FAKE_STATE/docker.run.du.rc"
run info s1; assert_contains "$OUT" "world:     world, unknown" "the world size is unknown when the helper cannot measure it"
assert_contains "$OUT" "data:      unknown" "and so is the data size"
assert_eq 0 "$RC" "info still exits 0"
rm -f "$FAKE_STATE/docker.run.du.rc"
mkdir -p "$SB/servers/s1/backups" && echo x >"$SB/servers/s1/backups/20260101T000000Z.tar.gz"
run info s1; assert_contains "$OUT" "backup:    tar, newest file 20" "the time of the newest file in backups/"
rm -f "$SB/servers/s1/backups/20260101T000000Z.tar.gz"
run create mp --accept-eula --modpack-source modrinth --modpack fabulously-optimized; assert_eq 0 "$RC" "create mp (a Modrinth pack)"
run info mp; assert_contains "$OUT" "modpack:   MODRINTH fabulously-optimized" "the modpack source and id"
run --yes delete mp; assert_eq 0 "$RC" "delete mp"
rm -f "$FAKE_STATE/docker.run.du"

echo "clone: what is refused"
run create s2 "${MCCTL_OK[@]}" --hostname s2h; assert_eq 0 "$RC" "create s2"
echo exited >"$FAKE_STATE/docker.inspect"; echo $'4096\t.' >"$FAKE_STATE/docker.run.du"
run clone s1 s1;                                  assert_eq 2 "$RC" "clone onto itself: exit 2"
run clone s1 s2;                                  assert_eq 4 "$RC" "NEW exists: exit 4"
assert_contains "$OUT" "server s2 already exists" "and it says so"
run clone s1 x --hostname Big;                    assert_eq 2 "$RC" "an invalid --hostname: exit 2"
run clone nope x;                                 assert_eq 1 "$RC" "an unknown source: exit 1"
run clone s1 c0 --hostname s2h;                   assert_eq 4 "$RC" "a hostname that another server uses: exit 4"
assert_contains "$OUT" "hostname s2h is already used by server s2" "and it names the owner"
assert_no_file "$SB/servers/c0" "nothing was made for c0"
run clone s1;                                     assert_eq 2 "$RC" "clone with no NEW: exit 2"
run clone s1 c1 --bogus;                          assert_eq 2 "$RC" "an unknown option: exit 2"

echo "clone: what is copied"
mkdir -p "$SB/servers/s1/lists" "$SB/servers/s1/mods" "$SB/servers/s1/plugins"
printf 'mod-a\n' >"$SB/servers/s1/lists/mods.list"
printf 'PK-jar\n' >"$SB/servers/s1/mods/a.jar"; chmod 644 "$SB/servers/s1/mods/a.jar"
printf 'PK-plug\n' >"$SB/servers/s1/plugins/p.jar"; chmod 644 "$SB/servers/s1/plugins/p.jar"
echo old-backup >"$SB/servers/s1/backups/keep.tgz"
reset; run clone s1 c1; assert_eq 0 "$RC" "clone s1 c1 (default hostname)"
assert_contains "$OUT" "players join at c1.mc.example.net" "the default hostname is slugify(NEW)"
assert_eq "HOSTNAME_SLUG=c1" "$(grep -E '^HOSTNAME_SLUG=' "$SB/servers/c1/server.env")" "server.env of the clone names the new host"
assert_eq "$(grep -v '^HOSTNAME_SLUG=' "$SB/servers/s1/server.env")" "$(grep -v '^HOSTNAME_SLUG=' "$SB/servers/c1/server.env")" "and every other line is the source's"
assert_eq "mod-a" "$(<"$SB/servers/c1/lists/mods.list")" "lists/ is copied"
assert_eq "PK-jar" "$(<"$SB/servers/c1/mods/a.jar")" "mods/ is copied"
assert_eq "PK-plug" "$(<"$SB/servers/c1/plugins/p.jar")" "plugins/ is copied"
assert_mode "$SB/servers/c1/mods/a.jar" 644 "a copied jar keeps mode 644 (the game's user reads it)"
assert_mode "$SB/servers/c1/mods" 755 "mods/ of the clone is mode 755"
assert_file "$SB/servers/c1/backup.env" "backup.env is copied"
assert_no_file "$SB/servers/c1/backups/keep.tgz" "backups/ is never copied"
assert_eq "" "$(ls -A "$SB/servers/c1/backups")" "the clone's backups/ is empty"
assert_mode "$SB/secrets/rcon-c1" 600 "the clone has its own RCON secret, mode 600"
pw1=$(secret c1); pw0=$(secret s1)
[[ $pw1 != "$pw0" ]] && pass "a different password from the source's" || fail "a different password from the source's"
[[ ${#pw1} == 32 ]] && pass "and it is 32 characters" || fail "and it is 32 characters" "${#pw1}"
assert_eq 0 "$(calls | grep -c 'start')" "the clone is created stopped: no start"
assert_eq 1 "$(calls | grep -c -- '-X POST')" "one DNS record for the clone"
assert_contains "$(calls)" "compose -p mcctl-c1 -f $SB/servers/c1/compose.yaml create" "compose create of the clone"
pos_create=$(pos "mcctl-c1 .* create"); pos_post=$(pos "^curl .* -X POST"); pos_hup=$(pos "kill -s HUP")
[[ $pos_post -lt $pos_create && $pos_create -lt $pos_hup ]] && pass "clone order: DNS, compose create, router" \
    || fail "clone order: DNS, compose create, router" "POST $pos_post create $pos_create HUP $pos_hup"
run clone s1 c2 --hostname ch2; assert_eq 0 "$RC" "an explicit --hostname"
assert_eq "HOSTNAME_SLUG=ch2" "$(grep -E '^HOSTNAME_SLUG=' "$SB/servers/c2/server.env")" "and it is in server.env"
assert_contains "$OUT" "ch2.mc.example.net" "and the players' address"
assert_not_contains "$ALL" "$pw0" "E4: no RCON password of s1 in any output"

echo "clone --with-data: the world goes helper to helper"
data_tar; reset
run clone s1 d1 --with-data; assert_eq 0 "$RC" "clone --with-data of a stopped server"
assert_contains "$(calls)" "docker run --rm --network none --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp --pids-limit 64 --memory 128m -v $SB/servers/s1/data:/data -w /data alpine:3.20 tar -cf - -C /data ." "one helper runs tar -cf - -C /data . on the source"
assert_contains "$(calls)" "docker run --rm -i --network none --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp --pids-limit 64 --memory 128m -v $SB/servers/d1/data:/data -w /data alpine:3.20 tar -xf - --no-same-owner -C /data" "a second helper, with stdin, runs tar -xf - on the new data/"
same "$FAKE_STATE/docker.run.tar" "$FAKE_STATE/run.stdin.1" "the stream of the one is the stream of the other, unchanged"
assert_eq 0 "$(calls | grep -c 'rcon-cli save-')" "a stopped source is not quiesced"

echo "clone --with-data of a running source: save-off, save-on, refused without --yes"
echo running >"$FAKE_STATE/docker.inspect"; reset
run clone s1 d2 --with-data; assert_eq 4 "$RC" "a running source is refused without --yes (no terminal to confirm)"
assert_no_file "$SB/servers/d2" "and nothing was made"
assert_eq 0 "$(calls | grep -c -- '-X POST')" "no DNS record was made"
reset; run --yes clone s1 d2 --with-data; assert_eq 0 "$RC" "with --yes: the clone is made"
p_off=$(pos "rcon-cli save-off"); p_flush=$(pos "rcon-cli save-all flush"); p_run=$(pos "tar -cf - -C /data ."); p_on=$(pos "rcon-cli save-on")
[[ -n $p_off && $p_off -lt $p_flush && $p_flush -lt $p_run && $p_run -lt $p_on ]] && pass "save-off, save-all flush, the copy, then save-on" \
    || fail "save-off, save-all flush, the copy, then save-on" "off $p_off flush $p_flush run $p_run on $p_on"
reset; echo 1 >"$FAKE_STATE/docker.run.tar.rc"
run --yes clone s1 d3 --with-data; assert_eq 1 "$RC" "the copy fails: exit 1"
assert_contains "$(calls)" "rcon-cli save-on" "save-on still runs when the copy fails"
assert_no_file "$SB/servers/d3" "the new server is taken back"
assert_eq "" "$(dnsof d3)" "and its DNS record is gone"
assert_no_file "$SB/secrets/rcon-d3" "and its secret"
rm -f "$FAKE_STATE/docker.run.tar.rc"; echo exited >"$FAKE_STATE/docker.inspect"
rm -f "$FAKE_STATE/docker.run.tar" "$FAKE_STATE/docker.run.du"

echo "rename: what is refused"
run rename s1;                                    assert_eq 2 "$RC" "rename with no NEW: exit 2"
run rename s1 s1 --yes;                           assert_eq 2 "$RC" "rename onto itself: exit 2"
run --yes rename nope x;                          assert_eq 1 "$RC" "rename of an unknown server: exit 1"
run --yes rename s1 Bad;                          assert_eq 2 "$RC" "an invalid NEW: exit 2"
run --yes rename s1 s2;                           assert_eq 4 "$RC" "NEW exists: exit 4"
run --yes rename s1 nx --hostname s2h;            assert_eq 4 "$RC" "a hostname another server uses: exit 4"
assert_contains "$OUT" "hostname s2h is already used by server s2" "and it names the owner"
assert_file "$SB/servers/s1/compose.yaml" "s1 is as it was"
run rename s1 nx;                                 assert_eq 4 "$RC" "no --yes and no terminal: the confirmation is refused, exit 4"
assert_file "$SB/servers/s1/compose.yaml" "and s1 is as it was"

echo "rename, stopped, to a new hostname: DNS first, containers, folder, then the old record"
mkdir -p "$SB/sftp-keys"; echo "ssh-ed25519 AAAAkey s1" >"$SB/sftp-keys/s1"
secret_before=$(secret s1); reset
run --yes rename s1 r1; assert_eq 0 "$RC" "rename s1 r1"
assert_contains "$OUT" "renamed s1 to r1: r1.mc.example.net, still stopped" "the message"
p_post=$(pos "^curl .* -X POST"); p_rm=$(pos "mcctl-s1 .* rm -s -f"); p_create=$(pos "mcctl-r1 .* create"); p_hup=$(pos "kill -s HUP"); p_del=$(pos "^curl .* -X DELETE")
[[ -n $p_post && $p_post -lt $p_rm && $p_rm -lt $p_create && $p_create -lt $p_hup && $p_hup -lt $p_del ]] \
    && pass "order: new DNS record, containers removed, folder moved, containers made, router told, old DNS record deleted" \
    || fail "order of the rename steps" "post $p_post rm $p_rm create $p_create hup $p_hup del $p_del"
assert_eq 0 "$(calls | grep -c 'mcctl-s1 .* stop')" "a stopped server is not stopped again"
assert_eq 0 "$(calls | grep -c 'mcctl-r1 .* start')" "and it is not started (it was stopped)"
assert_no_file "$SB/servers/s1" "the old folder is gone"
assert_file "$SB/servers/r1/compose.yaml" "the new folder has the compose file"
assert_contains "$(<"$SB/servers/r1/compose.yaml")" 'container_name: "mc-r1"' "compose.yaml names mc-r1"
assert_eq "HOSTNAME_SLUG=r1" "$(grep -E '^HOSTNAME_SLUG=' "$SB/servers/r1/server.env")" "server.env names the new host"
assert_eq "$secret_before" "$(secret r1)" "the RCON secret moved with the server: the same password"
assert_no_file "$SB/secrets/rcon-s1" "and the old secret is gone"
assert_no_file "$FAKE_STATE/docker.ps.label_mcctl_name_s1" "no container carries the name s1 any more"
assert_file "$FAKE_STATE/docker.ps.label_mcctl_name_r1" "a container carries r1"
assert_eq "r1.mc.example.net mcctl name=r1" "$(dnsof r1)" "the new DNS record"
assert_eq "" "$(dnsof s1h)" "the old DNS record is gone"
assert_eq "ssh-ed25519 AAAAkey s1" "$(<"$SB/sftp-keys/r1")" "the SFTP key moved to r1"
assert_no_file "$SB/sftp-keys/s1" "and its old name is gone"
assert_contains "$(<"$SB/sftp-users.conf")" "r1::1000:1000:r1" "the SFTP user is r1"
assert_eq 0 "$(grep -c '^s1:' "$SB/sftp-users.conf" || true)" "and the user s1 is gone"
run --yes rename r1 s1 --hostname s1h; assert_eq 0 "$RC" "and back: rename r1 s1 --hostname s1h (the name s1 is used again)"
assert_eq "s1h.mc.example.net mcctl name=s1" "$(dnsof s1h)" "the record of s1h is made again"
assert_file "$SB/servers/s1/compose.yaml" "s1 is back, with its folder"
assert_eq "$secret_before" "$(secret s1)" "and its secret"

echo "rename, running, to the same hostname: the record is relabelled, the server is started again"
run create sh1 "${MCCTL_OK[@]}" --hostname shh; assert_eq 0 "$RC" "create sh1 (hostname shh)"
echo running >"$FAKE_STATE/docker.inspect"; reset
run --yes rename sh1 sh2 --hostname shh; assert_eq 0 "$RC" "rename sh1 sh2 --hostname shh (the hostname is kept)"
assert_eq "shh.mc.example.net mcctl name=sh2" "$(dnsof shh)" "the record now says mcctl name=sh2 (relabelled by PATCH)"
assert_eq 1 "$(calls | grep -c -- '-X PATCH')" "one PATCH"
assert_eq 0 "$(calls | grep -c -E -- '-X (POST|DELETE)')" "no record was created or deleted"
p_stop=$(pos "mcctl-sh1 .* stop"); p_rm=$(pos "mcctl-sh1 .* rm -s -f"); p_start=$(pos "mcctl-sh2 .* start")
[[ -n $p_stop && $p_stop -lt $p_rm && $p_rm -lt $p_start ]] && pass "a running server is stopped, its containers made again, then started" \
    || fail "running: stop, rm, start" "stop $p_stop rm $p_rm start $p_start"
assert_eq "shh" "$(grep -E '^HOSTNAME_SLUG=' "$SB/servers/sh2/server.env" | cut -d= -f2)" "the hostname is unchanged in server.env"
echo exited >"$FAKE_STATE/docker.inspect"

echo "rename: a failing DNS call leaves the server as it was"
run create ff1 "${MCCTL_OK[@]}" --hostname ffh; assert_eq 0 "$RC" "create ff1"
reset; export FAIL_AT=1
run --yes rename ff1 ff2; unset FAIL_AT
assert_eq 1 "$RC" "the new record cannot be made: exit 1"
assert_file "$SB/servers/ff1/compose.yaml" "ff1 is as it was"
assert_no_file "$SB/servers/ff2" "and ff2 was never made"
assert_eq "ffh.mc.example.net mcctl name=ff1" "$(dnsof ffh)" "the DNS record of ff1 is intact"
assert_eq "" "$(dnsof ff2)" "and no record of ff2 is left"
assert_eq 0 "$(calls | grep -c 'mcctl-ff1 .* rm -s -f')" "no container was removed"
run --yes rename ff1 ff2; assert_eq 0 "$RC" "the same rename, run again, completes"

echo "rename: a hostname another server uses is refused"
run create tk1 "${MCCTL_OK[@]}" --hostname tkh; assert_eq 0 "$RC" "create tk1"
run --yes rename ff2 tk2 --hostname tkh; assert_eq 4 "$RC" "rename to a hostname tk1 uses: exit 4"
assert_contains "$OUT" "hostname tkh is already used by server tk1" "and it names the owner"
assert_file "$SB/servers/ff2/compose.yaml" "ff2 is as it was"

echo "export"
echo exited >"$FAKE_STATE/docker.inspect"; data_tar; reset
run export nope "$SB/x.tar.gz";                   assert_eq 1 "$RC" "export of an unknown server: exit 1"
run export s1;                                    assert_eq 2 "$RC" "export with no OUT: exit 2"
run export s1 "$SB/out.tar.gz" --bogus;           assert_eq 2 "$RC" "an unknown option: exit 2"
echo keep >"$SB/taken.tar.gz"
run export s1 "$SB/taken.tar.gz";                 assert_eq 4 "$RC" "OUT exists: exit 4"
assert_eq keep "$(<"$SB/taken.tar.gz")" "and it is not touched"
reset; run export s1 "$SB/s1.tar.gz"; assert_eq 0 "$RC" "export s1 to a new archive"
assert_mode "$SB/s1.tar.gz" 600 "the archive is mode 600"
members=$(tar -tzf "$SB/s1.tar.gz" | sort | paste -sd' ' -)
assert_eq "backup.env data/ data/world/ data/world/level.dat lists/ lists/mods.list mcctl-export mods/ mods/a.jar plugins/ plugins/p.jar server.env" "$members" \
    "the layout: marker, server.env, backup.env, lists/, mods/, plugins/, data/; no secrets/, backups/ or compose.yaml"
marker=$(tar -xzOf "$SB/s1.tar.gz" mcctl-export)
assert_eq "format=1" "$(sed -n 1p <<<"$marker")" "the marker says format=1"
assert_eq "name=s1" "$(sed -n 2p <<<"$marker")" "and the name"
assert_contains "$marker" "mcctl=0.1.0" "and the mcctl version"
assert_contains "$marker" "secrets=0" "and that it holds no secrets"
assert_contains "$marker" "created=20" "and the UTC time"
assert_eq "$(<"$SB/servers/s1/server.env")" "$(tar -xzOf "$SB/s1.tar.gz" server.env)" "server.env in the archive is the server's"
assert_eq "mod-a" "$(tar -xzOf "$SB/s1.tar.gz" lists/mods.list)" "lists/ is in the archive"
echo "running server: autosave off around the copy of the data"
echo running >"$FAKE_STATE/docker.inspect"; reset
run export s1 "$SB/live.tar.gz"; assert_eq 0 "$RC" "export of a running server"
p_off=$(pos "rcon-cli save-off"); p_run=$(pos "tar -cf - -C / data"); p_on=$(pos "rcon-cli save-on")
[[ -n $p_off && $p_off -lt $p_run && $p_run -lt $p_on ]] && pass "save-off, the copy, save-on" || fail "save-off, the copy, save-on" "off $p_off run $p_run on $p_on"
echo exited >"$FAKE_STATE/docker.inspect"
echo "export --with-secrets"
reset; run export s1 "$SB/withsec.tar.gz" --with-secrets; assert_eq 0 "$RC" "export --with-secrets"
assert_mode "$SB/withsec.tar.gz" 600 "mode 600"
assert_contains "$OUT" "holds the RCON password of s1" "a warning that the archive holds a credential"
assert_eq "secrets/rcon-s1" "$(tar -tzf "$SB/withsec.tar.gz" | grep '^secrets/' | paste -sd' ' -)" "the one file added is secrets/rcon-s1"
assert_eq "$(secret s1)" "$(tar -xzOf "$SB/withsec.tar.gz" secrets/rcon-s1)" "and it is the server's password"
assert_contains "$(tar -xzOf "$SB/withsec.tar.gz" mcctl-export)" "secrets=1" "the marker says secrets=1"
assert_not_contains "$OUT" "$(secret s1)" "E4: the password is not printed"
echo "a failing export writes nothing"
reset; echo 1 >"$FAKE_STATE/docker.run.tar.rc"
run export s1 "$SB/broken.tar.gz"; assert_eq 1 "$RC" "the data cannot be read: exit 1"
assert_no_file "$SB/broken.tar.gz" "no archive is left"
assert_eq "" "$(ls -A "$SB" | grep -F 'broken' || true)" "and no temporary file beside it"
rm -f "$FAKE_STATE/docker.run.tar.rc"

echo "import: what is refused, before anything is made"
rm -rf -- "$SB/arch"; mkdir -p "$SB/arch"
printf 'TYPE=PAPER\nEULA=TRUE\nHOSTNAME_SLUG=im1\n' >"$SB/arch/server.env"
printf 'format=1\nname=im1\n' >"$SB/arch/mcctl-export"
mkarch "$SB/nomarker.tgz" server.env
reset; run import "$SB/nomarker.tgz";             assert_eq 4 "$RC" "no marker: exit 4"
assert_contains "$OUT" "has no mcctl-export marker" "and it says so"
printf 'format=2\nname=im1\n' >"$SB/arch/mcctl-export"; mkarch "$SB/f2.tgz" mcctl-export server.env
run import "$SB/f2.tgz";                          assert_eq 4 "$RC" "format=2: exit 4"
assert_contains "$OUT" "reads format 1 only" "and it says so"
printf 'format=1\nname=im1\n' >"$SB/arch/mcctl-export"; echo x >"$SB/arch/modpack.env"
mkarch "$SB/noenv.tgz" mcctl-export modpack.env
run import "$SB/noenv.tgz";                       assert_eq 4 "$RC" "no server.env: exit 4"
mkdir -p "$SB/arch/evil"; echo x >"$SB/arch/evil/x"; mkarch "$SB/top.tgz" mcctl-export server.env evil
run import "$SB/top.tgz";                         assert_eq 4 "$RC" "an unknown top-level member: exit 4"
assert_contains "$OUT" "'evil/' at its top level" "named"
run import "$SB/nothing.tgz";                     assert_eq 1 "$RC" "a file that does not exist: exit 1"
mkarch "$SB/ok.tgz" mcctl-export server.env
run import "$SB/ok.tgz" s1;                       assert_eq 4 "$RC" "an existing name is refused: exit 4"
assert_contains "$OUT" "server s1 already exists" "and it says so"
assert_eq "" "$(calls | grep 'docker run' || true)" "no helper container ran for any refusal"

echo "import: made stopped, from the export of s1"
run import "$SB/s1.tar.gz" im2; assert_eq 4 "$RC" "the archive's hostname (s1h) is taken by s1: exit 4"
assert_contains "$OUT" "hostname s1h is already used by server s1: pick another one with --hostname" "and it names the owner"
assert_no_file "$SB/servers/im2" "nothing was made"
rm -f "$FAKE_STATE/docker.run.tar"; reset
run import "$SB/s1.tar.gz" im2 --hostname im2h; assert_eq 0 "$RC" "import under a new name and hostname"
assert_eq "HOSTNAME_SLUG=im2h" "$(grep -E '^HOSTNAME_SLUG=' "$SB/servers/im2/server.env")" "server.env names the given hostname"
assert_eq "$(grep -v '^HOSTNAME_SLUG=' "$SB/servers/s1/server.env")" "$(grep -v '^HOSTNAME_SLUG=' "$SB/servers/im2/server.env")" "and the rest of server.env is the archive's"
assert_eq "mod-a" "$(<"$SB/servers/im2/lists/mods.list")" "lists/ is extracted"
assert_mode "$SB/servers/im2/mods/a.jar" 644 "a jar is extracted with mode 644 (the umask does not hide it from the game)"
assert_contains "$(calls)" "tar -xzf - --no-same-owner --strip-components=1 -C /data data" "data/ goes through a helper (tar -xzf - on the archive, data/ only)"
same "$SB/s1.tar.gz" "$FAKE_STATE/run.stdin.1" "the archive is the helper's stdin, unchanged"
assert_eq 0 "$(calls | grep -c ' start')" "the imported server is stopped"
assert_eq "im2h.mc.example.net mcctl name=im2" "$(dnsof im2h)" "the DNS record of im2h exists"
assert_mode "$SB/secrets/rcon-im2" 600 "no secret in the archive: a fresh one, mode 600"

echo "import: the RCON secret"
reset; run import "$SB/s1.tar.gz" im3 --hostname im3h; assert_eq 0 "$RC" "import again, as im3"
pw3=$(secret im3); [[ ${#pw3} == 32 ]] && pass "a fresh secret of 32 characters" || fail "a fresh secret of 32 characters" "${#pw3}"
run --yes delete im3; assert_eq 0 "$RC" "delete im3"
run export s1 "$SB/withsec2.tgz" --with-secrets; assert_eq 0 "$RC" "export s1 with its secret"
reset; run import "$SB/withsec2.tgz" im4 --hostname im4h; assert_eq 0 "$RC" "import an archive that holds a secret"
assert_eq "$(tar -xzOf "$SB/withsec2.tgz" secrets/rcon-s1)" "$(secret im4)" "the archive's secret is written as rcon-im4"
assert_not_contains "$OUT" "$(secret im4)" "E4: the secret is in no output"
assert_not_contains "$(calls)" "$(secret im4)" "and in no call"
run --yes delete im4; assert_eq 0 "$RC" "delete im4"

echo "import: a server.env the renderer refuses is taken back"
mkdir -p "$SB/arch/data/world"; echo level >"$SB/arch/data/world/level.dat"
printf 'TYPE=PAPER\nEULA=TRUE\nHOSTNAME_SLUG=im5h\nDB_PASSWORD=hunter2\n' >"$SB/arch/server.env"
printf 'format=1\nname=im5\n' >"$SB/arch/mcctl-export"
mkarch "$SB/cred.tgz" mcctl-export server.env data
reset; run import "$SB/cred.tgz"; assert_eq 1 "$RC" "a credential as a plain value: exit 1"
assert_contains "$OUT" "DB_PASSWORD looks like a credential" "the renderer names the key"
assert_no_file "$SB/servers/im5" "nothing is left of im5"
assert_no_file "$SB/secrets/rcon-im5" "and no secret"
assert_eq "" "$(dnsof im5h)" "and no DNS record"
assert_not_contains "$ALL" "hunter2" "the value is in no output"
assert_not_contains "$(calls)" "hunter2" "or in no call"

echo "exec and shell"
echo exited >"$FAKE_STATE/docker.inspect"; reset
run exec s1 ls -la;                               assert_eq 1 "$RC" "exec on a stopped server: exit 1"
assert_contains "$OUT" "is not running" "and it says so"
assert_contains "$OUT" "mcctl start s1" "and how to start it"
echo running >"$FAKE_STATE/docker.inspect"
printf 'listing\n' >"$FAKE_STATE/docker.exec"; reset
run exec s1 ls -la; assert_eq 0 "$RC" "exec on a running server: exit 0"
assert_eq "listing" "$OUT" "the command's output"
assert_eq "docker exec -u 1000:1000 mc-s1 ls -la" "$(calls | grep '^docker exec -u')" "one docker exec, as the game's user (1000:1000)"
run exec s1;                                      assert_eq 2 "$RC" "exec with no command: exit 2"
run exec s1 -x;                                   assert_eq 2 "$RC" "a command that starts with '-': exit 2"
run exec s1 "";                                   assert_eq 2 "$RC" "an empty command: exit 2"
echo 7 >"$FAKE_STATE/docker.exec.rc"
run exec s1 false; assert_eq 7 "$RC" "the exit status of the command passes through: 7"
rm -f "$FAKE_STATE/docker.exec.rc"
reset; export MCCTL_UID=1001; run exec s1 id -u; unset MCCTL_UID
assert_eq "docker exec -u 1001:1001 mc-s1 id -u" "$(calls | grep '^docker exec -u')" "MCCTL_UID sets the user"
export MCCTL_UID=abc; run exec s1 id; unset MCCTL_UID
assert_eq 3 "$RC" "MCCTL_UID that is not a number: exit 3"
run shell s1;                                     assert_eq 2 "$RC" "shell with no terminal (the test has none): exit 2"
echo exited >"$FAKE_STATE/docker.inspect"; run shell s1; assert_eq 1 "$RC" "shell on a stopped server: exit 1 (checked first)"
echo running >"$FAKE_STATE/docker.inspect"; reset
(_have_terminal() { return 0; }; cmd_shell s1) >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "shell with a terminal stand-in: exit 0"
assert_eq "docker exec -it -u 1000:1000 mc-s1 bash" "$(calls | grep '^docker exec')" "one docker exec -it as the game's user, running bash"

echo "E3: the commands are defined, and nothing here uses eval or sudo"
for c in cmd_info cmd_clone cmd_rename cmd_export cmd_import cmd_exec cmd_shell; do
    grep -q "^$c()" "$REPO/lib/portable.sh" && pass "$c is defined in lib/portable.sh" || fail "$c is defined in lib/portable.sh"
done
grep -q '^_provision()' "$REPO/lib/servers.sh" && pass "_provision is defined in lib/servers.sh" || fail "_provision is defined in lib/servers.sh"
assert_eq "" "$(grep -n -E '(^|[^[:alnum:]_])(eval|sudo)([^[:alnum:]_]|$)' "$REPO/lib/portable.sh" | grep -v -E ':[[:space:]]*#' || true)" "no eval, no sudo in lib/portable.sh"

echo "E4: the Cloudflare token is in no output and no call"
assert_not_contains "$ALL$(calls)" "$CF_TOKEN" "the token is in no output and no call"

sandbox_cleanup
finish

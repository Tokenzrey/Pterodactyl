#!/usr/bin/env bash
# lib/servers.sh: create, start, stop, restart, kill, delete, list, status, and the Docker queries (server_exists, hostname_taken,
# server_label). E1: the ordered call log of every command. E4: the generated RCON secret and a planted one never reach output
# or the call log. E12: modes after create (SKIP on a host without POSIX modes). The fake docker is stateless; fake_server (in
# tests/lib.sh) writes the canned answers for "this container exists". fakebin/curl plays Cloudflare (its own detail is in
# t_cloudflare.sh); here the DNS calls appear in their place in the ordered call log.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/modpack.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/router.sh"
source "$REPO/lib/cloudflare.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
load_config 2>/dev/null

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
assert_ne() { if [[ $1 != "$2" ]]; then pass "$3"; else fail "$3" "both are '$1'"; fi; }
# files_now: what create and delete may have left under servers/ and secrets/
files_now() { (cd "$SB" && find servers secrets -print 2>/dev/null | sort | paste -sd, -); }
OKFLAGS=(--type PAPER --accept-eula)
CF=docker.compose.create.rc

echo "create: refused before anything is touched"
reset
m create s1 --type PAPER
assert_eq 2 "$RC" "no --accept-eula: EX_USAGE"
assert_contains "$OUT" "https://aka.ms/MinecraftEULA" "the message links the Mojang EULA"
assert_contains "$OUT" "--accept-eula" "and names the flag that accepts it"
m create Survival "${OKFLAGS[@]}"
assert_eq 2 "$RC" "create Survival: EX_USAGE (upper case)"
assert_contains "$OUT" "invalid server name 'Survival'" "the message names the problem"
assert_contains "$OUT" "try: survival" "and offers the slug"
for bad in '!!!' '---' '$$$' 'ÄÖ' ''; do
    m create "$bad" "${OKFLAGS[@]}"
    assert_eq 2 "$RC" "create ${bad@Q}: EX_USAGE"
    assert_contains "$OUT" "has no letter or digit" "create ${bad@Q}: the message says the slug is empty"
done
m create "$(printf 'a%.0s' {1..41})" "${OKFLAGS[@]}"
assert_eq 2 "$RC" "a 41-character name: EX_USAGE"
m create '../x' "${OKFLAGS[@]}";    assert_eq 2 "$RC" "a path as the name: EX_USAGE"
m create;                           assert_eq 2 "$RC" "no arguments: EX_USAGE"; assert_contains "$OUT" "usage: mcctl create NAME" "and the usage"
m create --type PAPER;              assert_eq 2 "$RC" "a flag where the name belongs: EX_USAGE"
m create s1 --accept-eula;          assert_eq 2 "$RC" "no --type: EX_USAGE"; assert_contains "$OUT" "--type is required" "and it says so"
m create s1 "${OKFLAGS[@]}" --bogus;  assert_eq 2 "$RC" "an unknown option: EX_USAGE"; assert_contains "$OUT" "unknown option '--bogus'" "named"
m create s1 "${OKFLAGS[@]}" --memory; assert_eq 2 "$RC" "a flag with no value: EX_USAGE"; assert_contains "$OUT" "--memory needs a value" "named"
for kv in '--memory lots' '--memory 0G' '--cpus 0' '--cpus two' '--version 1/2' '--hostname Big' '--hostname ab-' '--hostname a.b' '--type PA-PER'; do
    # shellcheck disable=SC2086  # the pair is two words on purpose
    m create s1 --type PAPER --accept-eula $kv
    key=${kv%% *}; key=${key#--}
    assert_eq 2 "$RC" "create $kv: EX_USAGE"
    assert_contains "$OUT" "mcctl create: ${key^^}" "create $kv: the message names ${key^^}"
done
m create BAD --memory lots --cpus 0
assert_eq 2 "$RC" "several problems at once: EX_USAGE"
[[ $OUT == *"invalid server name"* && $OUT == *MEMORY* && $OUT == *CPUS* && $OUT == *EULA* && $OUT == *"--type is required"* ]] \
    && pass "and every one is reported, not only the first" || fail "every problem is reported" "$OUT"
m create p "${OKFLAGS[@]}" --modpack-source bogus --modpack x;   assert_eq 2 "$RC" "modpack source other than curseforge/modrinth: EX_USAGE"
m create p --accept-eula --modpack-source modrinth;              assert_eq 2 "$RC" "a modpack source with no --modpack: EX_USAGE"
m create p --accept-eula --modpack x;                            assert_eq 2 "$RC" "--modpack with no source: EX_USAGE"
m create p --accept-eula --type PAPER --modpack-source modrinth --modpack x
assert_eq 2 "$RC" "a modpack source with another --type: EX_USAGE"; assert_contains "$OUT" "runs as --type MODRINTH" "and says what to do"
m create p --accept-eula --modpack-source curseforge --modpack x --modpack-version latest
assert_eq 2 "$RC" "a CurseForge modpack version that is not a file id: EX_USAGE"
m create p --accept-eula --modpack-source modrinth --modpack 'a b'; assert_eq 2 "$RC" "a modpack id with a space: EX_USAGE"
assert_eq "" "$(calls)" "none of these refusals reached Docker"
assert_eq "" "$(files_now)" "and none left a file behind"
MCCTL_DOMAIN= m create s1 "${OKFLAGS[@]}"
assert_eq 3 "$RC" "no MCCTL_DOMAIN: EX_PREFLIGHT"; assert_contains "$OUT" "MCCTL_DOMAIN" "named"
assert_eq "" "$(calls)$(files_now)" "and nothing was asked or written"
fake_cloudflare   # from here on: the DNS settings and secrets/cloudflare_token (tests/lib.sh)

echo "create s1"
reset
m create s1 "${OKFLAGS[@]}" --version 1.21.1 --memory 6G --cpus 3 --hostname survival
assert_eq 0 "$RC" "create s1 succeeds"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker ps -a -q --filter label=mcctl.hostname=survival
$(dns_made survival s1)
$(give_line "$SB/servers/s1/data")
$(give_line "$SB/secrets/rcon-s1.TMP")
$(sftp_ps_call)
docker compose -p mcctl-s1 -f $SB/servers/s1/compose.yaml create" "$(calls)" "calls: name check, hostname check, the DNS record, the game's user is given data and the secret, is SFTP running, compose create, in that order"
assert_eq "survival.mc.example.net mcctl name=s1" "$(dns_records)" "the DNS record survival.mc.example.net is made, its comment naming s1"
assert_eq "# Written by mcctl create. mcctl reads this file; it never runs it.
TYPE=PAPER
VERSION=1.21.1
MEMORY=6G
CPUS=3
HOSTNAME_SLUG=survival
EULA=TRUE" "$(<"$SB/servers/s1/server.env")" "server.env holds the flags, and EULA=TRUE because --accept-eula was given"
assert_file "$SB/servers/s1/compose.yaml" "compose.yaml is written"
assert_eq "$(render_server_compose s1 "$(config_hash s1)" 2>/dev/null)" "$(<"$SB/servers/s1/compose.yaml")" "and is exactly what the renderer makes of server.env, with the config label"
assert_contains "$(<"$SB/servers/s1/compose.yaml")" '      - "mcctl.hostname=survival"' "with the hostname label Docker will be asked about"
assert_no_file "$SB/servers/s1/modpack.env" "no modpack.env without a modpack"
[[ -d $SB/servers/s1/data && -d $SB/servers/s1/backups ]] && pass "data/ and backups/ exist (owned by the host user, not made by Docker)" || fail "data/ and backups/ exist"
assert_contains "$OUT" "mcctl start s1" "the message says how to start it"
assert_contains "$OUT" "survival.mc.example.net" "and where players join"
pw=$(<"$SB/secrets/rcon-s1")
assert_eq 32 "${#pw}" "the RCON password is 32 characters"
[[ $pw =~ ^[A-Za-z0-9]+$ ]] && pass "of letters and digits" || fail "of letters and digits" "$pw"
assert_not_contains "$OUT$(calls)" "$pw" "the RCON password is in neither the output nor the call log (E4)"
assert_not_contains "$(<"$SB/servers/s1/server.env")$(<"$SB/servers/s1/compose.yaml")" "$pw" "nor in server.env or compose.yaml"
m create s2 --type vanilla --accept-eula
assert_eq 0 "$RC" "create s2 with only the required flags"
assert_eq "# Written by mcctl create. mcctl reads this file; it never runs it.
TYPE=VANILLA
VERSION=LATEST
MEMORY=4G
CPUS=2
HOSTNAME_SLUG=s2
EULA=TRUE" "$(<"$SB/servers/s2/server.env")" "defaults: TYPE upper-cased, VERSION LATEST, 4G, 2 CPUs, hostname = the name"
assert_ne "$(<"$SB/secrets/rcon-s1")" "$(<"$SB/secrets/rcon-s2")" "every server gets its own password"
m create dash- "${OKFLAGS[@]}"
assert_contains "$(<"$SB/servers/dash-/server.env")" "HOSTNAME_SLUG=dash" "a name ending in '-' gets the trimmed slug as its default hostname"
m create modrinth-pack --accept-eula --modpack-source modrinth --modpack fabulously-optimized --modpack-version 5.0.1 --memory 3G
assert_eq 0 "$RC" "a Modrinth modpack"
assert_eq "# Written by mcctl create. mcctl reads this file; it never runs it.
TYPE=MODRINTH
MEMORY=3G
CPUS=2
HOSTNAME_SLUG=modrinth-pack
EULA=TRUE" "$(<"$SB/servers/modrinth-pack/server.env")" "TYPE=MODRINTH and no VERSION (the pack decides)"
assert_eq "MOD_PLATFORM=MODRINTH
MODRINTH_MODPACK=fabulously-optimized
MODRINTH_VERSION=5.0.1" "$(<"$SB/servers/modrinth-pack/modpack.env")" "modpack.env holds the platform, the pack and its version (modpack_env)"
assert_contains "$(<"$SB/servers/modrinth-pack/compose.yaml")" '      MODRINTH_MODPACK: "fabulously-optimized"' "which the renderer passes to the game container"
assert_not_contains "$(<"$SB/servers/modrinth-pack/compose.yaml")" "cf_api_key" "and a Modrinth server gets no CurseForge key"
m create cf-pack --accept-eula --modpack-source curseforge --modpack all-the-mods-9 --modpack-version 5000000
assert_eq 3 "$RC" "a CurseForge modpack without secrets/curseforge_api_key: EX_PREFLIGHT"
assert_contains "$OUT" "secrets/curseforge_api_key" "the message names the key file"
assert_no_file "$SB/servers/cf-pack" "and nothing was written"
plant_canary "$SB/secrets/curseforge_api_key"
m create cf-pack --accept-eula --modpack-source curseforge --modpack all-the-mods-9 --modpack-version 5000000
assert_eq 0 "$RC" "a CurseForge modpack, with the key file in place"
assert_contains "$(<"$SB/servers/cf-pack/server.env")" "TYPE=AUTO_CURSEFORGE" "TYPE=AUTO_CURSEFORGE"
assert_eq "MOD_PLATFORM=AUTO_CURSEFORGE
CF_SLUG=all-the-mods-9
CF_FILE_ID=5000000" "$(<"$SB/servers/cf-pack/modpack.env")" "modpack.env holds the platform, the slug and the file id"
assert_not_contains "$OUT" "API key" "and there is no longer a warning that the key is missing"
assert_contains "$(<"$SB/servers/cf-pack/compose.yaml")" '      CF_API_KEY_FILE: "/run/secrets/cf_api_key"' "the key reaches the container only as CF_API_KEY_FILE"
assert_not_contains "$OUT$(calls)$(<"$SB/servers/cf-pack/server.env")$(<"$SB/servers/cf-pack/modpack.env")$(<"$SB/servers/cf-pack/compose.yaml")" "$CANARY" "the key value is in no output, call log, env file or compose file (E4)"

echo "create: conflicts are refused and nothing is written"
reset
fake_server first survival
files_before=$(files_now)
m create other "${OKFLAGS[@]}" --hostname survival
assert_eq 4 "$RC" "a hostname that an existing server uses: EX_REFUSED"
assert_contains "$OUT" "hostname survival is already used by server first" "the message names the first server"
assert_eq "docker ps -a -q --filter label=mcctl.name=other
docker ps -a -q --filter label=mcctl.hostname=survival
docker ps -a --filter label=mcctl.hostname=survival --format {{.Label \"mcctl.name\"}}" "$(calls)" "calls: the two checks and the lookup for the message, no create"
assert_eq "$files_before" "$(files_now)" "and no file was written"
reset
m create first "${OKFLAGS[@]}" --hostname another
assert_eq 4 "$RC" "a name that Docker already has: EX_REFUSED"; assert_contains "$OUT" "server first already exists" "named"
assert_eq "docker ps -a -q --filter label=mcctl.name=first" "$(calls)" "calls: only the name check"
mkdir -p "$SB/servers/leftover"; echo keep >"$SB/servers/leftover/sentinel"
m create leftover "${OKFLAGS[@]}"
assert_eq 4 "$RC" "a folder with no container (interrupted create or delete): EX_REFUSED"
assert_contains "$OUT" "mcctl delete leftover" "the message says how to clean up"
assert_file "$SB/servers/leftover/sentinel" "and the folder is left alone"
assert_no_file "$SB/secrets/rcon-leftover" "and no secret was made"
reset
echo 1 >"$FAKE_STATE/docker.ps.rc"
m create s9 "${OKFLAGS[@]}"
assert_eq 1 "$RC" "Docker cannot be asked: EX_FAIL, not 'the name is free'"
assert_contains "$OUT" "cannot ask Docker" "and it says so"
assert_no_file "$SB/servers/s9" "and nothing was written"
rm -f "$FAKE_STATE/docker.ps.rc"
rm -rf "$SB/servers/leftover"; fake_gone first survival

echo "create: a failure takes everything back"
reset
echo 1 >"$FAKE_STATE/$CF"
files_before=$(files_now)
m create s3 "${OKFLAGS[@]}"
assert_eq 1 "$RC" "docker compose create fails: EX_FAIL"
assert_no_file "$SB/servers/s3" "servers/s3 is gone"
assert_no_file "$SB/secrets/rcon-s3" "and so is the RCON secret"
assert_eq "$files_before" "$(files_now)" "nothing else changed under servers/ and secrets/"
assert_eq "docker ps -a -q --filter label=mcctl.name=s3
docker ps -a -q --filter label=mcctl.hostname=s3
$(dns_made s3)
$(give_line "$SB/servers/s3/data")
$(give_line "$SB/secrets/rcon-s3.TMP")
$(sftp_ps_call)
docker compose -p mcctl-s3 -f $SB/servers/s3/compose.yaml create
docker compose -p mcctl-s3 -f $SB/servers/s3/compose.yaml rm -s -f
$(cf_get name=s3.mc.example.net)
$(cf_del "$(cf_last_id)")
$(sftp_ps_call)
$(clear_line "$SB/servers/s3")" "$(calls)" "calls: DNS, the game's user is given data and the secret, SFTP, create, then in reverse: the containers it may have made, the DNS record, the SFTP user, the game's data"
assert_eq 0 "$(dns_records | grep -c 's3\.')" "the DNS record of s3 is gone again"
reset
echo 1 >"$FAKE_STATE/docker.compose.rm.rc"
m create s3 "${OKFLAGS[@]}"
assert_eq 1 "$RC" "create fails and so does the clean-up: EX_FAIL"
assert_file "$SB/servers/s3/compose.yaml" "the folder is kept: a container may exist and must not lose its folder"
assert_file "$SB/secrets/rcon-s3" "and so is the secret"
assert_eq 1 "$(dns_records | grep -c 's3\.')" "and the DNS record (the container may exist)"
assert_contains "$OUT" "mcctl delete s3" "the message says how to finish the clean-up"
rm -f "$FAKE_STATE/docker.compose.rm.rc" "$FAKE_STATE/$CF"
m --yes delete s3
assert_eq 0 "$RC" "delete finishes it (the folder exists, the container does not)"
assert_eq "$files_before" "$(files_now)" "and everything is back to how it was"
assert_eq 0 "$(dns_records | grep -c 's3\.')" "the DNS record included"
plant_canary "$SB/secrets/rcon-s5"; old=$CANARY
m create s5 "${OKFLAGS[@]}"
assert_eq 0 "$RC" "a stale secret of the same name does not stop create"
assert_ne "$old" "$(<"$SB/secrets/rcon-s5")" "it is replaced by a new password"

echo "start, stop, restart"
fake_server s1 survival
for verb in start stop restart; do
    reset
    m "$verb" s1
    assert_eq 0 "$RC" "$verb s1"
    assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker compose -p mcctl-s1 -f $SB/servers/s1/compose.yaml $verb" "$(calls)" "$verb: asks Docker, then runs docker compose $verb"
    reset
    m "$verb" nope
    assert_eq 1 "$RC" "$verb of an unknown server: EX_FAIL"
    assert_contains "$OUT" "no server named 'nope'" "$verb: and it names the server"
    assert_eq "docker ps -a -q --filter label=mcctl.name=nope" "$(calls)" "$verb: and does not run compose"
    reset
    m "$verb" Bad; assert_eq 2 "$RC" "$verb Bad: EX_USAGE"
    m "$verb";     assert_eq 2 "$RC" "$verb with no name: EX_USAGE"
    m "$verb" s1 s2; assert_eq 2 "$RC" "$verb with two names: EX_USAGE"
    assert_eq "" "$(calls)" "$verb: usage errors make no docker call"
    echo 1 >"$FAKE_STATE/docker.compose.$verb.rc"
    m "$verb" s1; assert_eq 1 "$RC" "$verb: a failing docker compose is EX_FAIL"
    rm -f "$FAKE_STATE/docker.compose.$verb.rc"
done

echo "kill"
reset
m kill s1
assert_eq 4 "$RC" "kill without --yes and without a terminal: EX_REFUSED"
assert_contains "$OUT" "confirmation required" "it asked (confirm)"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1" "$(calls)" "and did not kill"
reset
m --yes kill s1
assert_eq 0 "$RC" "kill --yes"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker compose -p mcctl-s1 -f $SB/servers/s1/compose.yaml kill" "$(calls)" "calls: asks Docker, then docker compose kill"
MCCTL_YES=1 m kill s1; assert_eq 0 "$RC" "MCCTL_YES=1 answers too"
m --yes kill nope; assert_eq 1 "$RC" "kill of an unknown server: EX_FAIL"
m kill; assert_eq 2 "$RC" "kill with no name: EX_USAGE"
out=$( (confirm() { echo "ASKED: $1"; return 1; }; cmd_kill s1) 2>&1 ); rc=$?
assert_contains "$out" "ASKED: Kill s1 now?" "the question names the server"
assert_eq 4 "$rc" "and a no answer is EX_REFUSED"

echo "delete"
mkdir -p "$SB/servers/s1/data/world"; echo level >"$SB/servers/s1/data/world/level.dat"
plant_canary "$SB/secrets/rcon-s1"; canary=$CANARY
reset
m delete s1
assert_eq 4 "$RC" "delete without --yes and without a terminal: EX_REFUSED"
assert_contains "$OUT" "confirmation required" "it asked (confirm)"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1" "$(calls)" "and removed nothing"
assert_file "$SB/servers/s1/data/world/level.dat" "the world is still there"
assert_file "$SB/secrets/rcon-s1" "and so is the secret"
out=$( (confirm() { echo "ASKED: $1"; return 1; }; cmd_delete s1) 2>&1 ); rc=$?
assert_contains "$out" "ASKED: Delete s1?" "the question names the server"
assert_contains "$out" "world, mods and backups" "and says that the world goes"
[[ $out =~ "archived to $SB/trash/s1-"[0-9]{8}T[0-9]{6}Z\.tar\.gz ]] && pass "and names the archive it is first written to" || fail "the question names the archive" "$out"
assert_not_contains "$out" "cannot be brought back" "and does not say it cannot be brought back (the archive can)"
assert_eq 4 "$rc" "a no answer is EX_REFUSED"
assert_file "$SB/servers/s1/compose.yaml" "and the folder is untouched"
reset
echo 1 >"$FAKE_STATE/docker.compose.rm.rc"
m --yes delete s1
assert_eq 1 "$RC" "delete when docker compose rm fails: EX_FAIL"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker compose -p mcctl-s1 -f $SB/servers/s1/compose.yaml stop
$(archive_line "$SB/servers/s1" "data backups")
$(dns_gone s1 rec1)
docker compose -p mcctl-s1 -f $SB/servers/s1/compose.yaml rm -s -f" "$(calls)" "calls: stop, the archive, the DNS record (before the containers), then the failing rm"
assert_file "$SB/servers/s1/data/world/level.dat" "the folder is still there"
assert_file "$SB/secrets/rcon-s1" "and so is the secret"
assert_eq "" "$(dns_records | grep 'name=s1$')" "the DNS record went first: a container without a record, never a record without a container"
assert_contains "$OUT" "its archive is $SB/trash/s1-" "the message names the archive that was written"
rm -f "$FAKE_STATE/docker.compose.rm.rc"
# a world safety archive (servers/s1/safety, made by mcctl world delete or reset) goes into the trash archive with the rest
mkdir -p "$SB/servers/s1/safety" && cp "$REPO/tests/fixtures/archives/clean.tar.gz" "$SB/servers/s1/safety/world-world-20260101T000000Z.tar.gz"
reset
m --yes delete s1
assert_eq 0 "$RC" "delete s1 --yes"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker compose -p mcctl-s1 -f $SB/servers/s1/compose.yaml stop
$(archive_line "$SB/servers/s1" "data backups safety")
$(cf_get 'comment.exact=mcctl%20name%3Ds1')
docker compose -p mcctl-s1 -f $SB/servers/s1/compose.yaml rm -s -f
$(sftp_ps_call)
$(clear_line "$SB/servers/s1")" "$(calls)" "calls: asks Docker, stops, archives (with the safety archive), looks for the DNS record (the failed run deleted it), removes the containers, updates SFTP, clears the game's data"
assert_no_file "$SB/servers/s1" "servers/s1 is gone"
assert_no_file "$SB/secrets/rcon-s1" "and so is secrets/rcon-s1 (it would leak after the delete)"
assert_eq "" "$(dns_records | grep 'name=s1$')" "and the DNS record"
newest=$(ls -t "$SB"/trash/s1-*.tar.gz | head -n 1)
assert_eq "level" "$(tar -xzOf "$newest" data/world/level.dat)" "the world is in trash/, in an archive that reads back"
tar -tzf "$newest" | grep -qxF "safety/world-world-20260101T000000Z.tar.gz" && pass "and so is the world safety archive (safety/), so a server delete keeps it" || fail "the world safety archive is in the trash archive" "$(tar -tzf "$newest" 2>&1)"
assert_contains "$OUT" "$newest" "and the output names it"
assert_not_contains "$OUT$(calls)" "$canary" "the secret value is in neither the output nor the call log (E4)"
assert_file "$SB/servers/s2" "other servers are untouched"
assert_file "$SB/secrets/rcon-s2" "and so are their secrets"
fake_gone s1 survival
reset
m --yes delete s1
assert_eq 1 "$RC" "delete of a server that is gone altogether: EX_FAIL"
assert_contains "$OUT" "no server named 's1'" "and it says so"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
$(cf_get 'comment.exact=mcctl%20name%3Ds1')" "$(calls)" "calls: Docker, then Cloudflare is asked for a record a failed delete left (there is none)"
m --yes delete Bad; assert_eq 2 "$RC" "delete Bad: EX_USAGE"
m delete; assert_eq 2 "$RC" "delete with no name: EX_USAGE"
m --yes delete ../servers/s2; assert_eq 2 "$RC" "delete of a path: EX_USAGE"
assert_file "$SB/servers/s2/server.env" "and nothing was deleted"
echo "-- the container is already gone (docker rm by hand), the folder is not"
reset
plant_canary "$SB/secrets/rcon-s2"
m --yes delete s2
assert_eq 0 "$RC" "delete is idempotent: it finishes the job"
assert_eq "docker ps -a -q --filter label=mcctl.name=s2
docker compose -p mcctl-s2 -f $SB/servers/s2/compose.yaml stop
$(archive_line "$SB/servers/s2" "data backups")
$(dns_gone s2 rec2)
docker compose -p mcctl-s2 -f $SB/servers/s2/compose.yaml rm -s -f
$(sftp_ps_call)
$(clear_line "$SB/servers/s2")" "$(calls)" "calls: stop, the archive, the DNS record, then rm (stop and rm are harmless with no container), SFTP, the game's data"
assert_no_file "$SB/servers/s2" "servers/s2 is gone"
assert_no_file "$SB/secrets/rcon-s2" "and its secret"
echo "-- a container with no compose.yaml"
fake_server orphan orphan; mkdir -p "$SB/servers/orphan"; touch "$SB/servers/orphan/server.env"
reset
m --yes delete orphan
assert_eq 1 "$RC" "mcctl cannot remove containers it has no compose file for: EX_FAIL"
assert_contains "$OUT" "compose.yaml is missing" "and says why"
assert_file "$SB/servers/orphan/server.env" "and deletes nothing"
assert_eq "docker ps -a -q --filter label=mcctl.name=orphan
docker ps -a -q --filter label=mcctl.name=orphan" "$(calls)" "calls: only the two lookups"
fake_gone orphan orphan; rm -rf "$SB/servers/orphan"

echo "list"
rm -rf "$SB/servers"
fake_server alpha alpha-host running
fake_server beta beta-host created
reset
m list
assert_eq 0 "$RC" "list"
assert_eq 3 "$(wc -l <<<"$OUT")" "a header and one row per container that carries mcctl.managed=true"
assert_contains "$OUT" "NAME" "the header"
[[ $OUT == *alpha*running*alpha-host.mc.example.net*"Up 1 hour"* ]] && pass "a row has the name, state, address and docker status" || fail "a row has the name, state, address and status" "$OUT"
[[ $OUT == *beta*created*beta-host.mc.example.net* ]] && pass "a stopped server (created) is listed too" || fail "a created server is listed" "$OUT"
assert_eq "docker ps -a --filter label=mcctl.managed=true --format {{.Label \"mcctl.name\"}}|{{.State}}|{{.Label \"mc-router.host\"}}|{{.Status}}" "$(calls)" "calls: one query, filtered on mcctl.managed=true"
assert_no_file "$SB/servers" "servers/ does not exist, and list never needed it: Docker is the record"
fake_gone alpha alpha-host; fake_gone beta beta-host
m list
assert_eq 0 "$RC" "list with no servers: exit 0"
assert_contains "$OUT" "no servers yet" "and a hint"
assert_not_contains "$OUT" "ADDRESS" "and no empty table"
echo 1 >"$FAKE_STATE/docker.ps.rc"
m list; assert_eq 1 "$RC" "list when Docker cannot be asked: EX_FAIL"
rm -f "$FAKE_STATE/docker.ps.rc"
m list now; assert_eq 2 "$RC" "list with an argument: EX_USAGE"

echo "status"
fake_server s1 survival
printf 'running|healthy|survival.mc.example.net|itzg/minecraft-server|2026-10-24T01:02:03.5Z\n' >"$FAKE_STATE/docker.inspect"
reset
m status s1
assert_eq 0 "$RC" "status s1"
assert_eq "server:    s1
container: mc-s1 (running, healthy)
address:   survival.mc.example.net
image:     itzg/minecraft-server
config:    unknown (server.env does not render; mcctl apply s1 shows why)
started:   2026-10-24T01:02:03.5Z" "$OUT" "state, health, address, image, config (no server.env here) and start time"
assert_eq "docker ps -a -q --filter label=mcctl.name=s1
docker inspect --format {{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{index .Config.Labels \"mc-router.host\"}}|{{.Config.Image}}|{{.State.StartedAt}}|{{index .Config.Labels \"mcctl.config_hash\"}} mc-s1" "$(calls)" "calls: asks Docker, then one inspect of mc-s1 (with the config label)"
printf 'exited||survival.mc.example.net|itzg/minecraft-server|0001-01-01T00:00:00Z\n' >"$FAKE_STATE/docker.inspect"
m status s1
assert_contains "$OUT" "container: mc-s1 (exited)" "a stopped server: the state, no health"
assert_not_contains "$OUT" "started:" "and no start time"
rm -f "$FAKE_STATE/docker.inspect"
m status nope; assert_eq 1 "$RC" "status of an unknown server: EX_FAIL"
m status; assert_eq 2 "$RC" "status with no name: EX_USAGE"

echo "server_exists, hostname_taken, server_label"
fake_server h1 hostone
reset
server_exists h1;        assert_eq 0 $? "server_exists: 0 for a server Docker knows"
server_exists nobody;    assert_eq 1 $? "server_exists: 1 for one it does not"
assert_eq "docker ps -a -q --filter label=mcctl.name=h1
docker ps -a -q --filter label=mcctl.name=nobody" "$(calls)" "server_exists asks docker ps -a -q --filter label=mcctl.name=NAME"
reset
server_exists "../x"; assert_eq 1 $? "server_exists: 1 for a name that cannot be a server"
server_exists "";     assert_eq 1 $? "server_exists: 1 for an empty name"
assert_eq "" "$(calls)" "and does not ask Docker about it"
hostname_taken hostone;   assert_eq 0 $? "hostname_taken: 0 for a host name a container uses"
hostname_taken freehost;  assert_eq 1 $? "hostname_taken: 1 for a free one"
assert_eq "docker ps -a -q --filter label=mcctl.hostname=hostone
docker ps -a -q --filter label=mcctl.hostname=freehost" "$(calls)" "hostname_taken asks docker ps -a -q --filter label=mcctl.hostname=HOST"
assert_eq "h1" "$(hostname_owner hostone)" "hostname_owner names the server"
echo 1 >"$FAKE_STATE/docker.ps.label_mcctl_name_h1.rc"
out=$( server_exists h1 2>&1 ); rc=$?
[[ $rc -eq 1 && $out == *"cannot ask Docker"* ]] && pass "server_exists: a failing docker ps dies with a message" || fail "server_exists: a failing docker ps dies with a message" "rc=$rc $out"
echo 1 >"$FAKE_STATE/docker.ps.label_mcctl_hostname_hostone.rc"
out=$( hostname_taken hostone 2>&1 ); rc=$?
[[ $rc -eq 1 && $out == *"cannot ask Docker"* ]] && pass "hostname_taken: so does it" || fail "hostname_taken: a failing docker ps dies with a message" "rc=$rc $out"
rm -f "$FAKE_STATE"/docker.ps.label_mcctl_*.rc
printf 'hostone\n' >"$FAKE_STATE/docker.inspect"
reset
assert_eq "hostone" "$(server_label h1 mcctl.hostname)" "server_label prints the label value"
assert_eq "docker inspect --format {{index .Config.Labels \"mcctl.hostname\"}} mc-h1" "$(calls)" "via docker inspect --format of the label on mc-NAME"
reset
server_label h1 'a"b' 2>/dev/null; assert_eq 2 $? "server_label: a label key with a quote is refused (it would break the template)"
server_label Bad mcctl.name 2>/dev/null; assert_eq 2 $? "server_label: a bad server name is refused"
assert_eq "" "$(calls)" "and neither asks Docker"
echo 1 >"$FAKE_STATE/docker.inspect.rc"
server_label h1 mcctl.name >/dev/null 2>&1; assert_eq 1 $? "server_label: docker's failure is its failure"
rm -f "$FAKE_STATE/docker.inspect" "$FAKE_STATE/docker.inspect.rc"

echo "usage errors, called directly"
for fn in cmd_create cmd_start cmd_stop cmd_restart cmd_kill cmd_delete cmd_status; do
    out=$( "$fn" 2>&1 ); rc=$?
    assert_eq 2 "$rc" "$fn with no arguments: EX_USAGE"
done
out=$( cmd_list extra 2>&1 ); assert_eq 2 $? "cmd_list with an argument: EX_USAGE"

echo "write_compose"
fake_gone h1 hostone
srvdir=$SB/servers/wc; mkdir -p "$srvdir"; printf 'TYPE=PAPER\nEULA=TRUE\n' >"$srvdir/server.env"
write_compose wc; assert_eq 0 $? "write_compose renders servers/NAME/compose.yaml"
assert_contains "$(<"$srvdir/compose.yaml")" 'container_name: "mc-wc"' "and it is the rendered file"
before=$(<"$srvdir/compose.yaml")
printf 'MEMORY=lots\n' >>"$srvdir/server.env"
write_compose wc 2>/dev/null; assert_eq 3 $? "write_compose with an invalid server.env fails (EX_PREFLIGHT)"
assert_eq "$before" "$(<"$srvdir/compose.yaml")" "and the old compose.yaml is exactly as it was"
assert_eq "compose.yaml,server.env" "$(ls -A "$srvdir" | paste -sd, -)" "with no temp file beside it"
write_compose "../x" 2>/dev/null; assert_eq 2 $? "write_compose of a bad name: EX_USAGE"

echo "permissions (E12)"
rm -rf "$SB/servers" "$SB/secrets"
fake_cloudflare
m create perm "${OKFLAGS[@]}"
assert_eq 0 "$RC" "create for the permission check"
assert_mode "$SB/secrets/rcon-perm" 600 "the RCON secret is mode 600"
assert_mode "$SB/secrets" 700 "secrets/ is mode 700"
assert_mode "$SB/servers" 700 "servers/ is mode 700"
assert_mode "$SB/servers/perm" 700 "the server folder is mode 700"
assert_mode "$SB/servers/perm/data" 700 "data/ is mode 700"
assert_mode "$SB/servers/perm/backups" 700 "backups/ is mode 700"
assert_mode "$SB/servers/perm/server.env" 600 "server.env is mode 600"
assert_mode "$SB/servers/perm/compose.yaml" 600 "compose.yaml is mode 600"
assert_mode "$SB/servers/perm/mods" 755 "mods/ (the attach point, Task 20 C2) is mode 755"
assert_mode "$SB/servers/perm/plugins" 755 "plugins/ is mode 755"

sandbox_cleanup
finish

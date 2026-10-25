#!/usr/bin/env bash
# lib/modpack.sh: modpack_env (CurseForge and Modrinth), plus how the CurseForge API key reaches the container: a file under
# secrets/, mounted by compose and named only through CF_API_KEY_FILE. E4: a planted key never reaches output, the call log,
# server.env, modpack.env or compose.yaml. E6 (fuzz of modpack_env) lives in t_fuzz.sh. E12: modpack.env mode.
#
# Variable names, from the itzg docs (read 2026-10-24): MOD_PLATFORM, CF_SLUG, CF_FILE_ID, CF_API_KEY_FILE for CurseForge;
# MOD_PLATFORM, MODRINTH_MODPACK, MODRINTH_VERSION for Modrinth. If upstream renames one, change lib/modpack.sh and the lines below.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/modpack.sh"
source "$REPO/lib/servers.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
load_config 2>/dev/null

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
# block TEXT SERVICE: the lines of one service of the rendered file (same helper as t_compose.sh)
block() { local b=${1#*$'\n'"  $2:"$'\n'}; b=${b%%$'\n'  [a-z]*:*}; echo "${b%%$'\n'[a-z]*}"; }
# refused ARGS...: modpack_env must fail with exit 2 and print nothing on stdout; ERR holds what it said
refused() {
    OUT=$(modpack_env "$@" 2>"$SB/err"); RC=$?; ERR=$(<"$SB/err")
    [[ $RC -eq 2 && -z $OUT && -n $ERR ]] && pass "modpack_env ${*@Q}: exit 2, nothing printed, a message" || fail "modpack_env ${*@Q} is refused" "rc=$RC out=$OUT err=$ERR"
}

echo "modpack_env: CurseForge"
assert_eq "MOD_PLATFORM=AUTO_CURSEFORGE
CF_SLUG=all-the-mods-10
CF_FILE_ID=9190157" "$(modpack_env curseforge all-the-mods-10 9190157)" "slug and file id"
assert_eq "MOD_PLATFORM=AUTO_CURSEFORGE
CF_SLUG=craftoria" "$(modpack_env curseforge craftoria)" "slug only: no CF_FILE_ID (the image takes the latest file)"
assert_eq "MOD_PLATFORM=AUTO_CURSEFORGE
CF_SLUG=craftoria" "$(modpack_env curseforge craftoria '')" "an empty version is no version"
assert_eq 0 "$(modpack_env curseforge a.b_c-d 1 >/dev/null; echo $?)" "a slug may hold letters, digits, '.', '_' and '-'"
assert_eq "" "$(modpack_env curseforge craftoria 9190157 | grep -E 'API_KEY|PASSWORD|SECRET|TOKEN')" "no credential variable is ever printed (the key is a file, wired by the renderer)"
refused curseforge 1234567
[[ $ERR == *"CF_SLUG"* && $ERR == *"project id"* ]] && pass "a numeric CurseForge id is refused with the reason: the image has no project-id variable, only the slug" || fail "numeric id message" "$ERR"
refused curseforge ""
refused curseforge
refused curseforge craftoria latest
refused curseforge craftoria 12.5
refused curseforge craftoria 1234567890123
refused curseforge craftoria $'123\n456'
refused curseforge craftoria 'CF_API_KEY=x'

echo "modpack_env: Modrinth"
assert_eq "MOD_PLATFORM=MODRINTH
MODRINTH_MODPACK=adrenaserver" "$(modpack_env modrinth adrenaserver)" "slug only"
assert_eq "MOD_PLATFORM=MODRINTH
MODRINTH_MODPACK=fabulously-optimized
MODRINTH_VERSION=5.0.1" "$(modpack_env modrinth fabulously-optimized 5.0.1)" "slug and version number"
assert_eq "MOD_PLATFORM=MODRINTH
MODRINTH_MODPACK=P7dR8mSH
MODRINTH_VERSION=1.0.0+mc1.21" "$(modpack_env modrinth P7dR8mSH '1.0.0+mc1.21')" "a project id and a version with '+'"
assert_eq "MOD_PLATFORM=MODRINTH
MODRINTH_MODPACK=12345678" "$(modpack_env modrinth 12345678)" "a Modrinth id may be all digits"
refused modrinth ""
refused modrinth adrenaserver 'a b'
refused modrinth adrenaserver 'v=1'
refused modrinth adrenaserver $'1.0\nMODRINTH_PROJECTS=evil'
refused modrinth adrenaserver '-1'

echo "modpack_env: refused input"
refused ftb some-pack
refused "" some-pack
refused CurseForge some-pack
refused
for bad in $'a\nb' $'a\n' $'\nb' 'a=b' '=' 'a b' ' a' 'a ' 'a/b' '../x' '-a' '.a' 'a$b' 'a"b' "a'b" 'a\b' 'a;b' 'a`b' 'a|b' "$(printf 'a%.0s' {1..101})"; do
    refused modrinth "$bad"
    refused curseforge "$bad"
done
OUT=$(modpack_env modrinth "$(printf 'a%.0s' {1..100})" 2>&1); assert_eq 0 $? "an id of 100 characters is the longest accepted"
refused modrinth 'a b' 'v v'
[[ $ERR == *"modpack id"* && $ERR == *"modpack version"* ]] && pass "a bad id and a bad version are both reported" || fail "both problems reported" "$ERR"

echo "renderer: the CurseForge API key is a file secret"
srv() { local n=$1; shift; rm -rf -- "$SB/servers/$n"; mkdir -p "$SB/servers/$n"; printf '%s\n' "$@" >"$SB/servers/$n/server.env"; }
mp() { local n=$1; shift; printf '%s\n' "$@" >"$SB/servers/$n/modpack.env"; }
render() { OUT=$(render_server_compose "$@" 2>"$SB/err"); RC=$?; ERR=$(<"$SB/err"); }
srv cf 'TYPE=AUTO_CURSEFORGE' 'MEMORY=6G' 'EULA=TRUE'; mp cf "$(modpack_env curseforge all-the-mods-10 9190157)"
render cf
assert_eq 0 "$RC" "a CurseForge server renders"
mcb=$(block "$OUT" mc); bkb=$(block "$OUT" backup)
assert_contains "$mcb" $'      MOD_PLATFORM: "AUTO_CURSEFORGE"\n      CF_SLUG: "all-the-mods-10"\n      CF_FILE_ID: "9190157"\n      CF_API_KEY_FILE: "/run/secrets/cf_api_key"' "modpack.env entries, then CF_API_KEY_FILE"
assert_contains "$mcb" $'    secrets:\n      - rcon_password\n      - cf_api_key\n' "the game container is given both secrets"
assert_not_contains "$bkb" "cf_api_key" "the backup sidecar is not"
assert_contains "$OUT" $'secrets:\n  rcon_password:\n    file: "../../secrets/rcon-cf"\n  cf_api_key:\n    file: "../../secrets/curseforge_api_key"' "the key is a file under secrets/, next to the RCON secret"
assert_eq "" "$(grep -E '(PASSWORD|SECRET|TOKEN|_KEY)[A-Z_]*:' <<<"$OUT" | grep -v '_FILE:')" "every credential-named key in the output is a *_FILE reference"
assert_not_contains "$mcb" "curseforge_api_key" "the host path is not mounted as a volume: compose mounts the secret itself, read-only, at /run/secrets"
assert_not_contains "$OUT" "CF_API_KEY:" "there is no plain CF_API_KEY"
srv cf2 'TYPE=FORGE' 'EULA=TRUE'; mp cf2 'MOD_PLATFORM=AUTO_CURSEFORGE' 'CF_SLUG=x'; render cf2
assert_contains "$OUT" 'CF_API_KEY_FILE: "/run/secrets/cf_api_key"' "MOD_PLATFORM=AUTO_CURSEFORGE in modpack.env is enough"
srv cf3 'TYPE=FORGE' 'EULA=TRUE'; mp cf3 'MODPACK_PLATFORM=AUTO_CURSEFORGE' 'CF_SLUG=x'; render cf3
assert_contains "$OUT" 'cf_api_key:' "so is MODPACK_PLATFORM=AUTO_CURSEFORGE"
srv mr 'TYPE=MODRINTH' 'EULA=TRUE'; mp mr "$(modpack_env modrinth adrenaserver)"; render mr
assert_eq 0 "$RC" "a Modrinth server renders"
assert_not_contains "$OUT" "cf_api_key" "and gets no CurseForge key"
assert_not_contains "$OUT" "CF_API_KEY" "not even the variable"
srv v 'TYPE=VANILLA' 'EULA=TRUE'; render v
assert_not_contains "$OUT" "cf_api_key" "a plain server gets no CurseForge key"
srv cf4 'TYPE=AUTO_CURSEFORGE' 'EULA=TRUE'; mp cf4 'CF_SLUG=x' 'CF_API_KEY_FILE=/somewhere/else'; render cf4
assert_eq 3 "$RC" "CF_API_KEY_FILE in modpack.env of a CurseForge server is refused (mcctl owns it): exit 3"
assert_eq "" "$OUT" "nothing is emitted"
assert_contains "$ERR" "CF_API_KEY_FILE" "and the message names the variable"
srv cf5 'TYPE=AUTO_CURSEFORGE' 'EULA=TRUE'; mp cf5 'CF_SLUG=x' 'CF_API_KEY=plain-value-never-written'; render cf5
assert_eq 4 "$RC" "a plain CF_API_KEY in modpack.env is refused (exit 4)"
assert_not_contains "$ERR$OUT" "plain-value-never-written" "and its value is not echoed"

echo "create: the CurseForge API key (E4)"
rm -rf "$SB/servers" "$SB/secrets"
mkdir_private "$SB/secrets"
fake_cloudflare   # the DNS settings and secrets/cloudflare_token that create needs (tests/lib.sh)
reset
m create cf --accept-eula --modpack-source curseforge --modpack all-the-mods-10 --modpack-version 9190157
assert_eq 3 "$RC" "no secrets/curseforge_api_key: EX_PREFLIGHT"
assert_contains "$OUT" "$SB/secrets/curseforge_api_key" "the message gives the path to create"
assert_eq "" "$(calls)" "Docker was not asked"
assert_eq "" "$(cd "$SB" && find servers secrets -mindepth 1 2>/dev/null | grep -vx secrets/cloudflare_token)" "and nothing was written"
printf '\n  \n' >"$SB/secrets/curseforge_api_key"
m create cf --accept-eula --modpack-source curseforge --modpack all-the-mods-10
assert_eq 3 "$RC" "a key file with nothing in it: EX_PREFLIGHT too"
m create cf --accept-eula --modpack-source modrinth --modpack adrenaserver
assert_eq 0 "$RC" "a Modrinth pack does not need the key"
assert_not_contains "$(<"$SB/servers/cf/compose.yaml")" "cf_api_key" "(and its compose file has none)"
m --yes delete cf >/dev/null; rm -f "$SB/secrets/curseforge_api_key"
reset
m create cf --accept-eula --modpack-source curseforge --modpack 1234567
assert_eq 2 "$RC" "a numeric CurseForge id: EX_USAGE (flags are checked before the key)"
assert_eq "" "$(calls)" "no Docker call"
plant_canary "$SB/secrets/curseforge_api_key"
reset
m create cf --accept-eula --modpack-source curseforge --modpack all-the-mods-10 --modpack-version 9190157 --memory 6G
assert_eq 0 "$RC" "with the key file in place, create succeeds"
assert_eq "docker ps -a -q --filter label=mcctl.name=cf
docker ps -a -q --filter label=mcctl.hostname=cf
$(dns_made cf)
$(sftp_ps_call)
docker compose -p mcctl-cf -f $SB/servers/cf/compose.yaml create
$(reload_call)" "$(calls)" "calls: name check, hostname check, the DNS record, is SFTP running, compose create, the router signal"
assert_eq "MOD_PLATFORM=AUTO_CURSEFORGE
CF_SLUG=all-the-mods-10
CF_FILE_ID=9190157" "$(<"$SB/servers/cf/modpack.env")" "modpack.env is what modpack_env prints"
assert_eq "$(render_server_compose cf "$(config_hash cf)" 2>/dev/null)" "$(<"$SB/servers/cf/compose.yaml")" "and compose.yaml is exactly what the renderer makes of it, with the config label"
assert_contains "$(<"$SB/servers/cf/compose.yaml")" '      CF_API_KEY_FILE: "/run/secrets/cf_api_key"' "the compose file passes the key only as CF_API_KEY_FILE"
assert_contains "$(<"$SB/servers/cf/compose.yaml")" '    file: "../../secrets/curseforge_api_key"' "pointing at the secret file"
for f in server.env modpack.env compose.yaml; do
    assert_not_contains "$(<"$SB/servers/cf/$f")" "$CANARY" "the key value is not in $f"
done
assert_not_contains "$OUT" "$CANARY" "nor in the output of create"
assert_not_contains "$(calls)" "$CANARY" "nor in the call log"
assert_eq "$CANARY" "$(<"$SB/secrets/curseforge_api_key")" "and the key file itself is untouched"
assert_mode "$SB/servers/cf/modpack.env" 600 "modpack.env is mode 600"
echo 1 >"$FAKE_STATE/docker.compose.create.rc"
m create cf2 --accept-eula --modpack-source curseforge --modpack x-pack
assert_eq 1 "$RC" "a failing docker compose create"
assert_no_file "$SB/servers/cf2" "takes the folder back"
assert_eq "$CANARY" "$(<"$SB/secrets/curseforge_api_key")" "but never the key: it belongs to the operator, not to the server"
assert_not_contains "$OUT" "$CANARY" "and the failure message does not print it"
rm -f "$FAKE_STATE/docker.compose.create.rc"
m --yes delete cf >/dev/null; m --yes delete cf2 >/dev/null 2>&1
assert_eq "$CANARY" "$(<"$SB/secrets/curseforge_api_key")" "delete leaves the shared key alone"
assert_not_contains "$OUT" "$CANARY" "(and does not print it)"

echo "modpack: info, set, update, remove (lib/modpack.sh, cmd_modpack)"
# The snapshot's `docker run ... tar` replays this archive; the modpack commands take their snapshot with snapshot_members (C1)
cp "$REPO/tests/fixtures/archives/clean.tar.gz" "$FAKE_STATE/docker.run.tar"
# mpsrv NAME STATE TYPE [LINE...]: a server of TYPE, server.env = its LINE..., no modpack.env yet; the fake Docker answers for it
mpsrv() {
    local n=$1 st=$2 t=$3
    shift 3
    rm -rf -- "$SB/servers/$n"
    mkdir -p -- "$SB/servers/$n/data/mods" "$SB/servers/$n/backups"
    printf '%s\n' "TYPE=$t" EULA=TRUE MEMORY=2G CPUS=2 "HOSTNAME_SLUG=$n" "$@" >"$SB/servers/$n/server.env"
    fake_server "$n" "$n" "$st"
    printf '%s\n' "$st" >"$FAKE_STATE/docker.inspect"
    rm -f -- "$FAKE_STATE/docker.exec" "$FAKE_STATE/docker.exec.rc" "$FAKE_STATE/mutations"
    rm -f -- "$FAKE_STATE/docker.recreates" "$FAKE_STATE"/docker.compose.recreate.*
    [[ $st != running ]] || printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
    reset
}
# HEALTH_KEY: the fake's file name for `docker inspect --format {{.State.Health.Status}}` (fakebin/docker sanitises the format)
hfmt='{{.State.Health.Status}}'
HEALTH_KEY=docker.inspect.${hfmt//[^A-Za-z0-9_-]/_}
# snapshots NAME VERB: how many pre-VERB archives are in servers/NAME/safety (the folder backup prune never reads)
snapshots() { ls "$SB/servers/$1/safety" 2>/dev/null | grep -c "^pre-$2-"; }
# at PATTERN: the line number of the first call that matches PATTERN (0 when none does)
at() { grep -n -- "$1" <<<"$(calls)" | head -n 1 | cut -d: -f1; }

mpsrv m1 exited AUTO_CURSEFORGE
printf '%s\n' "$(modpack_env curseforge all-the-mods-10 9190157)" >"$SB/servers/m1/modpack.env"
m modpack m1 info
assert_eq 0 "$RC" "info: exit 0"
assert_contains "$OUT" "source:  curseforge" "info: the source"
assert_contains "$OUT" "pack:    all-the-mods-10" "info: the pack id"
assert_contains "$OUT" "version: pinned 9190157" "info: the pinned version"
assert_contains "$OUT" "resolved name/version: unknown" "info: a stopped container cannot say, so the resolved values are unknown"
mpsrv m1 running AUTO_CURSEFORGE
printf '%s\n' "$(modpack_env curseforge all-the-mods-10 9190157)" >"$SB/servers/m1/modpack.env"
printf 'Name\n1.2\n' >"$FAKE_STATE/docker.exec"
m modpack m1 info
assert_contains "$OUT" "resolved name: Name" "info: a running container exposing MODPACK_NAME gives the name"
assert_contains "$OUT" "resolved version: 1.2" "info: and MODPACK_VERSION the version"
echo 1 >"$FAKE_STATE/docker.exec.rc"
m modpack m1 info
assert_contains "$OUT" "resolved name/version: unknown" "info: a failing docker exec gives unknown"
mpsrv m2 exited MODRINTH
printf '%s\n' "$(modpack_env modrinth adrenaserver)" >"$SB/servers/m2/modpack.env"
m modpack m2 info
assert_contains "$OUT" "version: latest" "info: no pin says latest"
assert_contains "$OUT" "pack:    adrenaserver" "info: and names the Modrinth pack"
mpsrv m3 exited PAPER "VERSION=1.20.1"
m modpack m3 info
assert_eq "no modpack" "$OUT" "info: a server with no modpack prints 'no modpack'"

rm -f -- "$SB/secrets/curseforge_api_key"
b=$(cksum <"$SB/servers/m3/server.env")
m modpack m3 set --source curseforge --pack all-the-mods-10
assert_eq 3 "$RC" "set a CurseForge pack with no key file: exit 3, before anything else"
assert_contains "$OUT" "$SB/secrets/curseforge_api_key" "and the message gives the file"
assert_eq "" "$(ls "$SB/servers/m3/safety" 2>/dev/null)" "no snapshot was taken"
assert_eq "$b" "$(cksum <"$SB/servers/m3/server.env")" "server.env is byte-identical"
m modpack m3 set --source ftb --pack x
assert_eq 2 "$RC" "an unknown source: exit 2"
m modpack m3 set --source modrinth --pack ''
assert_eq 2 "$RC" "an empty pack id: exit 2"
m modpack m3 set --source curseforge --pack 1234567
assert_eq 2 "$RC" "a numeric CurseForge pack: exit 2"
assert_eq 0 "$(count_calls 'run --rm')" "none of the refusals asked for a snapshot"

mpsrv m3 exited PAPER "VERSION=1.20.1"
b=$(cksum <"$SB/servers/m3/server.env")
m modpack m3 set --source modrinth --pack adrenaserver
assert_eq 4 "$RC" "a declined confirm (no terminal, no --yes): exit 4"
assert_eq "$b" "$(cksum <"$SB/servers/m3/server.env")" "server.env is byte-identical after the decline"
assert_no_file "$SB/servers/m3/modpack.env" "no modpack.env was written"
assert_eq 1 "$(snapshots m3 modpack-set)" "the snapshot was taken before the question, as the order says"

plant_canary "$SB/secrets/curseforge_api_key"
mpsrv m4 exited PAPER "VERSION=1.20.1"
m --yes modpack m4 set --source curseforge --pack all-the-mods-10 --version 9190157
assert_eq 0 "$RC" "set a CurseForge pack with --yes: exit 0"
assert_contains "$(<"$SB/servers/m4/server.env")" "TYPE=AUTO_CURSEFORGE" "TYPE is the platform"
assert_eq 0 "$(grep -c '^VERSION=' "$SB/servers/m4/server.env")" "VERSION is removed: the pack decides it"
assert_eq "$(modpack_env curseforge all-the-mods-10 9190157)" "$(<"$SB/servers/m4/modpack.env")" "modpack.env is what modpack_env prints"
assert_contains "$(<"$SB/servers/m4/compose.yaml")" 'CF_API_KEY_FILE: "/run/secrets/cf_api_key"' "the key is a file reference only"
for f in server.env modpack.env compose.yaml; do
    assert_not_contains "$(<"$SB/servers/m4/$f")" "$CANARY" "the key value is not in $f"
done
assert_not_contains "$(calls)" "$CANARY" "nor in the call log"
assert_not_contains "$OUT" "$CANARY" "nor in the output"
assert_eq 1 "$(snapshots m4 modpack-set)" "one snapshot first"
assert_eq 1 "$(count_calls 'create --force-recreate$')" "the stopped server is recreated once"

mpsrv m7 exited AUTO_CURSEFORGE "VERSION=1.20.1"
printf '%s\n' "$(modpack_env curseforge all-the-mods-10 9190157)" >"$SB/servers/m7/modpack.env"
write_compose m7
b_all=$(cksum <"$SB/servers/m7/server.env"; cksum <"$SB/servers/m7/modpack.env"; cksum <"$SB/servers/m7/compose.yaml")
echo 1 >"$FAKE_STATE/docker.run.tar.rc"
m --yes modpack m7 set --source modrinth --pack adrenaserver
assert_eq 1 "$RC" "modpack set with a failing snapshot: exit 1"
assert_eq "$b_all" "$(cksum <"$SB/servers/m7/server.env"; cksum <"$SB/servers/m7/modpack.env"; cksum <"$SB/servers/m7/compose.yaml")" "server.env, modpack.env and compose.yaml are byte-identical"
m --yes modpack m7 remove --type FORGE --version 1.20.1
assert_eq 1 "$RC" "modpack remove with a failing snapshot: exit 1"
assert_eq "$b_all" "$(cksum <"$SB/servers/m7/server.env"; cksum <"$SB/servers/m7/modpack.env"; cksum <"$SB/servers/m7/compose.yaml")" "and so are the three files after remove"
reset
m --yes modpack m7 update --latest --clean   # stopped: --clean needs a running server (R10), refused before anything
assert_eq 4 "$RC" "modpack update --clean on a stopped server: refused (exit 4)"
assert_contains "$OUT" "start it first" "and says so"
assert_eq "$b_all" "$(cksum <"$SB/servers/m7/server.env"; cksum <"$SB/servers/m7/modpack.env"; cksum <"$SB/servers/m7/compose.yaml")" "the three files are unchanged"
assert_eq 0 "$(count_calls 'run --rm')" "no snapshot was taken for the refusal"
rm -f -- "$FAKE_STATE/docker.run.tar.rc"

mpsrv m8 running AUTO_CURSEFORGE "VERSION=1.20.1"
printf '%s\n' "$(modpack_env curseforge all-the-mods-10 9190157)" >"$SB/servers/m8/modpack.env"
write_compose m8
b_all=$(cksum <"$SB/servers/m8/server.env"; cksum <"$SB/servers/m8/modpack.env"; cksum <"$SB/servers/m8/compose.yaml")
echo 1 >"$FAKE_STATE/docker.run.tar.rc"
m --yes modpack m8 update --latest --clean   # m8 is pinned: --latest says what to do with the pin
assert_eq 1 "$RC" "modpack update --latest --clean on a running server with a failing snapshot: exit 1"
assert_eq "$b_all" "$(cksum <"$SB/servers/m8/server.env"; cksum <"$SB/servers/m8/modpack.env"; cksum <"$SB/servers/m8/compose.yaml")" "the three files are unchanged (the pin is dropped only after the snapshot)"
assert_eq 0 "$(count_calls 'up -d --force-recreate$')" "nothing was recreated"
rm -f -- "$FAKE_STATE/docker.run.tar.rc"

echo "modpack update: the pin, --latest, --clean"
mpsrv m5 exited AUTO_CURSEFORGE
printf '%s\n' "$(modpack_env curseforge all-the-mods-10 9190157)" >"$SB/servers/m5/modpack.env"
b=$(cksum <"$SB/servers/m5/modpack.env")
m modpack m5 update
assert_eq 4 "$RC" "a pinned pack without --latest or --version is refused (exit 4)"
assert_contains "$OUT" "pinned to 9190157" "and the message prints the pin"
assert_eq "$b" "$(cksum <"$SB/servers/m5/modpack.env")" "modpack.env is byte-identical"
m --yes modpack m5 update --version 9200000
assert_eq 0 "$RC" "--version 9200000: exit 0"
assert_contains "$(<"$SB/servers/m5/modpack.env")" "CF_FILE_ID=9200000" "the pin is rewritten"
assert_contains "$(<"$SB/servers/m5/modpack.env")" "CF_SLUG=all-the-mods-10" "and the pack is kept"
m --yes modpack m5 update --latest
assert_eq 0 "$RC" "--latest: exit 0"
assert_eq 0 "$(grep -c CF_FILE_ID "$SB/servers/m5/modpack.env")" "the pin is dropped"
m modpack m5 update --version 9200000 --latest
assert_eq 2 "$RC" "--version and --latest together: exit 2"
m modpack m5 update --version 'a b'
assert_eq 2 "$RC" "a version with a space: exit 2 (modpack_env says why)"

mpsrv m6 running AUTO_CURSEFORGE
printf '%s\n' "$(modpack_env curseforge all-the-mods-10)" >"$SB/servers/m6/modpack.env"
printf 'starting\nhealthy\n' >"$FAKE_STATE/$HEALTH_KEY.seq"
reset
m --yes modpack m6 update --clean --timeout 5
assert_eq 0 "$RC" "--clean on a running server, healthy within the timeout: exit 0"
assert_contains "$OUT" "REMOVE_OLD_MODS" "--clean says what it sets"
assert_contains "$OUT" "All content of the mods or plugins directory will be deleted" "and quotes itzg's warning"
assert_contains "$OUT" "recreated without it" "and says the containers are recreated without it"
assert_eq 1 "$(snapshots m6 modpack-update)" "a snapshot is taken first"
s=$(at 'run --rm'); c=$(at 'up -d --force-recreate$')
((s > 0 && s < c)) && pass "the snapshot ($s) comes before the first recreate ($c)" || fail "snapshot before recreate" "$(calls)"
assert_eq 2 "$(count_calls 'up -d --force-recreate$')" "two recreates: the one with the flag, then the one without"
assert_contains "$(<"$FAKE_STATE/docker.compose.recreate.1.yml")" 'REMOVE_OLD_MODS: "TRUE"' "the first recreate holds REMOVE_OLD_MODS"
assert_eq 0 "$(grep -c 'REMOVE_OLD_MODS\|FORCE_REINSTALL\|FORCE_REDOWNLOAD' "$FAKE_STATE/docker.compose.recreate.2.yml")" "the second recreate has none of the one-shot lines"
assert_eq 0 "$(grep -c REMOVE_OLD_MODS "$SB/servers/m6/server.env" "$SB/servers/m6/compose.yaml" | awk -F: '{s+=$2} END {print s+0}')" "the flag is gone from server.env and compose.yaml afterwards"
assert_eq 0 "$(grep -c '^CF_FILE_ID' "$SB/servers/m6/modpack.env")" "(the pack is unchanged: unpinned before, unpinned after)"

mpsrv m9 running AUTO_CURSEFORGE
printf '%s\n' "$(modpack_env curseforge all-the-mods-10)" >"$SB/servers/m9/modpack.env"
printf 'starting\n' >"$FAKE_STATE/$HEALTH_KEY"
m --yes modpack m9 update --clean --timeout 1
assert_eq 1 "$RC" "--clean, a health that stays starting: the timeout exits 1"
assert_contains "$OUT" "not healthy after 1 s" "and says so"
assert_eq 2 "$(count_calls 'up -d --force-recreate$')" "the second recreate still runs after the timeout"
assert_eq 0 "$(grep -c REMOVE_OLD_MODS "$SB/servers/m9/server.env" "$SB/servers/m9/compose.yaml" | awk -F: '{s+=$2} END {print s+0}')" "and the flag is removed from both files"
rm -f -- "$FAKE_STATE/$HEALTH_KEY"

mpsrv m10 exited AUTO_CURSEFORGE
printf '%s\n' "$(modpack_env curseforge all-the-mods-10)" >"$SB/servers/m10/modpack.env"
b=$(cksum <"$SB/servers/m10/server.env"; cksum <"$SB/servers/m10/modpack.env")
m --yes modpack m10 update --clean
assert_eq 4 "$RC" "--clean on a stopped server: refused (exit 4), since the install must run in a running container"
assert_eq "$b" "$(cksum <"$SB/servers/m10/server.env"; cksum <"$SB/servers/m10/modpack.env")" "server.env and modpack.env are byte-identical"
assert_eq 0 "$(count_calls 'run --rm')" "with no snapshot"
m --yes modpack m10 update --latest --timeout 5
assert_eq 2 "$RC" "--timeout without --clean: exit 2"
m modpack m3 update
assert_eq 1 "$RC" "update on a server with no modpack: exit 1"

echo "modpack remove: the type, the version, the mods, the purge"
mpsrv r1 exited AUTO_CURSEFORGE "VERSION=1.20.1"
printf '%s\n' "$(modpack_env curseforge all-the-mods-10 9190157)" >"$SB/servers/r1/modpack.env"
m modpack r1 remove
assert_eq 2 "$RC" "remove without --type: exit 2, with the reason"
assert_contains "$OUT" "--type is required" "and the reason"
assert_contains "$(<"$SB/servers/r1/server.env")" "TYPE=AUTO_CURSEFORGE" "nothing was changed"

mpsrv r2 exited AUTO_CURSEFORGE
printf '%s\n' "$(modpack_env curseforge all-the-mods-10 9190157)" >"$SB/servers/r2/modpack.env"
b=$(cksum <"$SB/servers/r2/server.env")
m modpack r2 remove --type FORGE
assert_eq 4 "$RC" "no VERSION and no --version: refused, since LATEST can upgrade the world (exit 4)"
assert_eq "$b" "$(cksum <"$SB/servers/r2/server.env")" "server.env is byte-identical"
: >"$SB/servers/r2/data/mods/keep.jar"
m --yes modpack r2 remove --type FORGE --version 1.20.1 --loader-version 47.2.0
assert_eq 0 "$RC" "with --version and --loader-version: exit 0"
assert_contains "$(<"$SB/servers/r2/server.env")" "TYPE=FORGE" "TYPE is the plain type"
assert_contains "$(<"$SB/servers/r2/server.env")" "FORGE_VERSION=47.2.0" "the loader version is written"
assert_contains "$(<"$SB/servers/r2/server.env")" "VERSION=1.20.1" "and the version"
assert_eq "" "$(<"$SB/servers/r2/modpack.env")" "modpack.env is emptied"
assert_file "$SB/servers/r2/data/mods/keep.jar" "the installed mods stay without --purge-mods"
assert_eq 1 "$(snapshots r2 modpack-remove)" "a snapshot is taken first"

mpsrv r3 exited AUTO_CURSEFORGE "VERSION=1.20.1"
printf '%s\n' "$(modpack_env curseforge all-the-mods-10 9190157)" >"$SB/servers/r3/modpack.env"
m --yes modpack r3 remove --type FORGE --purge-mods
assert_eq 0 "$RC" "--purge-mods on a stopped server: exit 0"
s=$(at 'run --rm'); p=$(at 'find mods -mindepth 1 -maxdepth 1 -delete')
((s > 0 && p > 0 && s < p)) && pass "the mods are removed in the helper, after the snapshot" \
    || fail "purge after the snapshot, in the helper" "$(calls)"

mpsrv r4 running AUTO_CURSEFORGE "VERSION=1.20.1"
printf '%s\n' "$(modpack_env curseforge all-the-mods-10 9190157)" >"$SB/servers/r4/modpack.env"
m --yes modpack r4 remove --type FORGE --purge-mods
assert_eq 4 "$RC" "--purge-mods on a running server: refused, stop it first (exit 4)"
assert_contains "$OUT" "stop it first" "and says so"
assert_eq 0 "$(snapshots r4 modpack-remove)" "with no snapshot"

mpsrv r5 exited AUTO_CURSEFORGE "VERSION=1.20.1"
m modpack r5 remove --type AUTO_CURSEFORGE
assert_eq 2 "$RC" "a modpack platform as the new type: exit 2"
m modpack r5 remove --type PAPER --loader-version 1.0
assert_eq 2 "$RC" "--loader-version for PAPER: exit 2"

sandbox_cleanup
finish

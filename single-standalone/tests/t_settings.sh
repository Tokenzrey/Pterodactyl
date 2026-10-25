#!/usr/bin/env bash
# lib/settings.sh: set, get, unset, env, apply, properties, motd, icon, resourcepack, autostart; settings_check and apply_pending.
# Spec section 5: the validation table (1), the refusals (2), set and its render (3, 4, 8), the status and apply states (5 to 7),
# properties (9), icon, resourcepack and autostart (10), atomicity (12), the secret canary (13), and the usage of every command (E3).
# The goldens (11) are in t_compose.sh, t_edit.sh is unchanged (14), the flow (15) is in t_flows.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/modpack.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/rcon.sh"
source "$REPO/lib/router.sh"
source "$REPO/lib/cloudflare.sh"
source "$REPO/lib/sftp.sh"
source "$REPO/lib/settings.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
# canned FORMAT OUT: the answer of the fake docker to `docker inspect --format FORMAT ...` (fakebin/docker names the file after the
# sanitized format). Three formats are used here: the state, the config label, and the line that status reads.
canned() { printf '%s\n' "$2" >"$FAKE_STATE/docker.inspect.${1//[^A-Za-z0-9_-]/_}"; }
FMT_STATE='{{.State.Status}}'
FMT_LABEL='{{index .Config.Labels "mcctl.config_hash"}}'
FMT_STATUS='{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{index .Config.Labels "mc-router.host"}}|{{.Config.Image}}|{{.State.StartedAt}}|{{index .Config.Labels "mcctl.config_hash"}}'
# run_as STATE LABEL: Docker's answers for s1 in STATE, whose game container carries the config label LABEL
run_as() {
    canned "$FMT_STATE" "$1"
    canned "$FMT_STATUS" "$1|healthy|s1.mc.example.net|itzg/minecraft-server|2026-10-24T01:02:03Z|$2"
    canned "$FMT_LABEL" "$2"
}
ZERO=$(printf '0%.0s' {1..64})   # a label that matches no configuration
# mk NAME [STATE]: a server folder (server.env, compose.yaml, RCON secret) and Docker's answers for it, in STATE, with the label of the
# current configuration (what a container made by this version carries). Clears the call log.
mk() {
    local n=$1 st=${2:-running}
    mkdir -p "$SB/servers/$n/data" "$SB/servers/$n/backups" "$SB/secrets"
    printf '# Written by mcctl create. mcctl reads this file; it never runs it.\nTYPE=PAPER\nVERSION=LATEST\nMEMORY=4G\nCPUS=2\nHOSTNAME_SLUG=%s\nEULA=TRUE\n' "$n" >"$SB/servers/$n/server.env"
    chmod 600 "$SB/servers/$n/server.env"
    write_compose "$n" && chmod 600 "$SB/servers/$n/compose.yaml"
    printf 'test-rcon-pass-%s\n' "$n" >"$SB/secrets/rcon-$n"; chmod 600 "$SB/secrets/rcon-$n"
    fake_server "$n" "$n" "$st"
    run_as "$st" "$(config_hash "$n")"
    reset
}
# clean NAME: no folder, secret or Docker answer for NAME
clean() {
    local n=$1
    rm -rf -- "$SB/servers/$n"; rm -f -- "$SB/secrets/rcon-$n"
    fake_gone "$n" "$n"
    rm -f -- "$FAKE_STATE"/docker.inspect* "$FAKE_STATE"/docker.exec*
    reset
}
SRV=$SB/servers/s1
ASK="docker ps -a -q --filter label=mcctl.name=s1"
RELOAD=$(reload_call)

echo "1. Validation table (settings_check, test 1)"
# vt KEY TYPE VALUE WANT: WANT is the value as it is stored, or REFUSED (exit 2, nothing printed)
vt() {
    local out rc
    out=$(settings_check "$1" "$2" "$3" 2>/dev/null); rc=$?
    if [[ $4 == REFUSED ]]; then
        [[ $rc -eq 2 && -z $out ]] && pass "$1 ${3:0:24}: refused" || fail "$1 ${3:0:24}: refused" "rc=$rc out=$out"
    else
        [[ $rc -eq 0 && $out == "$4" ]] && pass "$1 ${3:0:24} -> $4" || fail "$1 ${3:0:24} -> $4" "rc=$rc out=$out"
    fi
}
vt PVP "$(settings_type PVP)" true TRUE
vt PVP "$(settings_type PVP)" TRUE TRUE
vt PVP "$(settings_type PVP)" false FALSE
vt PVP "$(settings_type PVP)" FALSE FALSE
vt PVP "$(settings_type PVP)" maybe REFUSED
vt PVP "$(settings_type PVP)" '' REFUSED
vt PVP "$(settings_type PVP)" tRUE REFUSED
vt MAX_PLAYERS "$(settings_type MAX_PLAYERS)" 20 20
vt MAX_PLAYERS "$(settings_type MAX_PLAYERS)" 0 0
vt MAX_PLAYERS "$(settings_type MAX_PLAYERS)" -1 REFUSED
vt MAX_PLAYERS "$(settings_type MAX_PLAYERS)" 1e3 REFUSED
vt MAX_PLAYERS "$(settings_type MAX_PLAYERS)" 123456789 123456789
vt MAX_PLAYERS "$(settings_type MAX_PLAYERS)" 1234567890 REFUSED
vt MAX_PLAYERS "$(settings_type MAX_PLAYERS)" '' REFUSED
vt DIFFICULTY "$(settings_type DIFFICULTY)" hard hard
vt DIFFICULTY "$(settings_type DIFFICULTY)" HARD hard
vt DIFFICULTY "$(settings_type DIFFICULTY)" impossible REFUSED
vt ICON "$(settings_type ICON)" https://x.example/a.png https://x.example/a.png
vt ICON "$(settings_type ICON)" http://x.example/a.png REFUSED
vt ICON "$(settings_type ICON)" 'https://x.example/a b.png' REFUSED
vt ICON "$(settings_type ICON)" 'https://' REFUSED
SHA=0123456789abcdef0123456789abcdef01234567
vt RESOURCE_PACK_SHA1 "$(settings_type RESOURCE_PACK_SHA1)" "$SHA" "$SHA"
vt RESOURCE_PACK_SHA1 "$(settings_type RESOURCE_PACK_SHA1)" "${SHA^^}" "$SHA"
vt RESOURCE_PACK_SHA1 "$(settings_type RESOURCE_PACK_SHA1)" "${SHA:0:39}" REFUSED
vt RESOURCE_PACK_SHA1 "$(settings_type RESOURCE_PACK_SHA1)" "${SHA}0" REFUSED
vt RESOURCE_PACK_SHA1 "$(settings_type RESOURCE_PACK_SHA1)" "${SHA:0:39}g" REFUSED
LONG=$(printf 'a%.0s' {1..1000})
vt MOTD "$(settings_type MOTD)" "$LONG" "$LONG"
vt MOTD "$(settings_type MOTD)" "${LONG}a" REFUSED
vt GENERATOR_SETTINGS "$(settings_type GENERATOR_SETTINGS)" '{"a": 1}' '{"a":1}'
vt GENERATOR_SETTINGS "$(settings_type GENERATOR_SETTINGS)" '{bad' REFUSED
OK8192="[$(printf '1,%.0s' {1..4094})11]"
vt GENERATOR_SETTINGS "$(settings_type GENERATOR_SETTINGS)" "$OK8192" "$OK8192"
vt GENERATOR_SETTINGS "$(settings_type GENERATOR_SETTINGS)" "[$(printf '1,%.0s' {1..4095})1]" REFUSED
assert_eq 1 "$(settings_type NOT_A_KEY >/dev/null; echo $?)" "settings_type: 1 for a key that is not a known setting"

echo "2. KEY forms, control characters, repeated keys, missing arguments: refused before anything is touched"
mk s1
env_before=$(cksum "$SRV/server.env"); cmp_before=$(cksum "$SRV/compose.yaml")
for bad in pvp=true 1X=1 A-B=1 =1 noequals; do m set s1 "$bad"; assert_eq 2 "$RC" "set s1 $bad: EX_USAGE"; done
m set s1 $'MOTD=a\nb'; assert_eq 2 "$RC" "a newline in a value: EX_USAGE"
m set s1 $'MOTD=a\tb'; assert_eq 2 "$RC" "a tab in a value (a control character): EX_USAGE"
m set s1 MOTD=one MOTD=two; assert_eq 2 "$RC" "a key given twice: EX_USAGE"
m set s1; assert_eq 2 "$RC" "set with no pair: EX_USAGE"
m set --apply; assert_eq 2 "$RC" "set without NAME: EX_USAGE"
m set nope MOTD=x; assert_eq 1 "$RC" "set of an unknown server: EX_FAIL"
m set Bad MOTD=x; assert_eq 2 "$RC" "set of a bad name: EX_USAGE"
assert_eq "$env_before" "$(cksum "$SRV/server.env")" "server.env byte-identical after all of them"
assert_eq "$cmp_before" "$(cksum "$SRV/compose.yaml")" "compose.yaml byte-identical"
assert_eq 0 "$(count_calls '^docker compose')" "no docker compose call"

echo "3. Refusals that --force does not lift (test 2); an unknown key is refused without --force and stored with it"
clean s1; mk s1
env_before=$(cksum "$SRV/server.env")
for kv in RCON_PASSWORD=x CF_API_KEY=x FOO_TOKEN=x RCON_PORT=1 ENABLE_RCON=false TYPE=FABRIC MEMORY=9G AUTOSTART=maybe; do
    m set s1 "$kv"; assert_eq 4 "$RC" "set $kv: refused (EX_REFUSED)"
    m set s1 "$kv" --force; assert_eq 4 "$RC" "set $kv --force: still refused"
done
assert_eq "$env_before" "$(cksum "$SRV/server.env")" "server.env unchanged by the refusals"
m set s1 FOO=bar; assert_eq 2 "$RC" "an unknown key without --force: EX_USAGE"
assert_contains "$OUT" "FOO is not a known setting" "and the message names it"
assert_eq "$env_before" "$(cksum "$SRV/server.env")" "server.env still unchanged"
m set s1 FOO=bar --force; assert_eq 0 "$RC" "an unknown key with --force is stored"
assert_contains "$(<"$SRV/server.env")" "FOO=bar" "FOO=bar is in server.env"
assert_contains "$(<"$SRV/compose.yaml")" '      FOO: "bar"' "and rendered into the game container"

echo "4. set writes, renders and says config pending; a render that fails puts server.env back (tests 3, 4, 8, 12)"
clean s1; mk s1; reset
m set s1 PVP=false MAX_PLAYERS=20; assert_eq 0 "$RC" "set PVP=false MAX_PLAYERS=20"
assert_contains "$OUT" "config pending: mcctl apply s1" "the answer says config pending"
assert_eq "$ASK" "$(calls)" "the only call is the name check: no docker compose"
assert_contains "$(<"$SRV/server.env")" "PVP=FALSE" "PVP is stored as FALSE"
assert_contains "$(<"$SRV/server.env")" "MAX_PLAYERS=20" "MAX_PLAYERS=20 is stored"
assert_contains "$(<"$SRV/compose.yaml")" $'      RCON_PASSWORD_FILE: "/run/secrets/rcon_password"\n      MAX_PLAYERS: "20"\n      PVP: "FALSE"\n    labels:' "compose.yaml has MAX_PLAYERS then PVP, sorted, before the labels (test 3)"
clean s1; mk s1
printf 'PVP=TRUE\n' >"$SRV/modpack.env"
env_before=$(cksum "$SRV/server.env"); cmp_before=$(cksum "$SRV/compose.yaml")
m set s1 PVP=false; assert_eq 1 "$RC" "a render that fails (PVP is also in modpack.env): EX_FAIL"
assert_contains "$OUT" "server.env was put back as it was" "the message says server.env was put back"
assert_eq "$env_before" "$(cksum "$SRV/server.env")" "server.env is byte-identical to before (test 12)"
assert_eq "$cmp_before" "$(cksum "$SRV/compose.yaml")" "compose.yaml is byte-identical to before"
assert_eq 0 "$(count_calls '^docker compose')" "no docker compose call"
assert_eq 0 "$(find "$SRV" -name '*.tmp' | wc -l)" "no .tmp file left"
clean s1; mk s1
m set s1 'MOTD=$HOME "q" \n §'; assert_eq 0 "$RC" "a MOTD with \$, quotes, a backslash and a section sign is accepted"
assert_contains "$(<"$SRV/compose.yaml")" '      MOTD: "$$HOME \"q\" \\n §"' "rendered inert: \$ doubled, quotes and the backslash escaped, nothing interpolated (test 4)"
clean s1; mk s1
env_before=$(cksum "$SRV/server.env")
m set s1 MOTD=ok 'BAD KEY=x'; assert_eq 2 "$RC" "one invalid pair among valid ones: EX_USAGE"
m set s1 MOTD=ok RCON_PASSWORD=x; assert_eq 4 "$RC" "a refused pair among valid ones: EX_REFUSED"
m set s1 MOTD=ok PVP=maybe; assert_eq 2 "$RC" "a bad value among valid ones: EX_USAGE"
assert_eq "$env_before" "$(cksum "$SRV/server.env")" "server.env is byte-identical after the batch (test 12)"
assert_not_contains "$(<"$SRV/server.env")" "MOTD=ok" "and nothing of the batch was written"
rm -f -- "$SRV/server.env"
m set s1 MOTD=x; assert_eq 1 "$RC" "a server with no server.env: EX_FAIL"
assert_no_file "$SRV/server.env" "and the set does not create one"

echo "5. status: current, pending, unknown (test 6); a one-shot key leaves the config current (test 5)"
clean s1; mk s1
h=$(config_hash s1)
run_as running "$h"; m status s1; assert_contains "$OUT" "config:    current" "a label that matches: current"
run_as running "$ZERO"; m status s1; assert_contains "$OUT" "config:    pending (mcctl apply s1)" "a label that differs: pending"
run_as running ""; m status s1; assert_contains "$OUT" "config:    unknown (created before tracking; mcctl apply s1 stamps it)" "no label: the unknown form"
run_as running "$h"
for kv in FABRIC_FORCE_REINSTALL=TRUE FORCE_REDOWNLOAD=TRUE REMOVE_OLD_MODS=TRUE; do
    m set s1 "$kv" --force; assert_eq 0 "$RC" "set $kv"
    m status s1; assert_contains "$OUT" "config:    current" "$kv: still current"
    m unset s1 "${kv%%=*}"; assert_eq 0 "$RC" "unset ${kv%%=*}"
    m status s1; assert_contains "$OUT" "config:    current" "and after the unset: still current"
done
m set s1 MOTD=changed; m status s1; assert_contains "$OUT" "config:    pending (mcctl apply s1)" "a setting that is not one-shot: pending"

echo "6. apply (test 7): equal makes no docker compose call; differing recreates the whole project; stopped creates; players refuse"
clean s1; mk s1 running; h=$(config_hash s1); run_as running "$h"; reset
m apply s1; assert_eq 0 "$RC" "apply with the config current: exit 0"
assert_contains "$OUT" "nothing to apply" "says nothing to apply"
assert_eq 0 "$(count_calls '^docker compose')" "zero docker compose calls"
assert_eq 0 "$(count_calls 'rcon-cli')" "and no RCON call"
clean s1; mk s1 running; m set s1 MOTD=new >/dev/null; run_as running "$h"
printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"; reset
m --yes apply s1; assert_eq 0 "$RC" "apply with --yes and no players: exit 0"
assert_eq "$ASK
docker inspect --format $FMT_LABEL mc-s1
docker inspect --format $FMT_STATE mc-s1
docker exec -i mc-s1 rcon-cli list
docker compose -p mcctl-s1 -f $SRV/compose.yaml up -d --force-recreate
$RELOAD" "$(calls)" "the ordered calls: name, label, state, list, up -d --force-recreate (no service name), HUP"
clean s1; mk s1 exited; m set s1 MOTD=new >/dev/null; run_as exited "$ZERO"; reset
m --yes apply s1; assert_eq 0 "$RC" "apply on a stopped server: exit 0"
assert_eq "$ASK
docker inspect --format $FMT_LABEL mc-s1
docker inspect --format $FMT_STATE mc-s1
docker compose -p mcctl-s1 -f $SRV/compose.yaml create --force-recreate" "$(calls)" "a stopped server gets create --force-recreate (no exec, no up, no HUP)"
clean s1; mk s1 running; m set s1 MOTD=new3 >/dev/null; run_as running "$ZERO"
printf 'There are 2 of a max of 20 players online: a, b\n' >"$FAKE_STATE/docker.exec"
env_before=$(cksum "$SRV/server.env"); cmp_before=$(cksum "$SRV/compose.yaml"); reset
m apply s1; assert_eq 4 "$RC" "2 players, no --yes: EX_REFUSED"
assert_contains "$OUT" "2 players online" "the message says so"
assert_eq "$env_before" "$(cksum "$SRV/server.env")" "server.env unchanged"
assert_eq "$cmp_before" "$(cksum "$SRV/compose.yaml")" "compose.yaml unchanged"
assert_eq 0 "$(count_calls '^docker compose')" "no docker compose call"
m status s1; assert_contains "$OUT" "config:    pending (mcctl apply s1)" "the config stays pending"
clean s1; mk s1 exited; m set s1 MOTD=new4 >/dev/null; run_as exited "$ZERO"
FAIL_AT=1 m --yes apply s1; assert_eq 1 "$RC" "a failing create: EX_FAIL"
assert_contains "$OUT" "the files are already written" "the message says the files are written"
clean s1
m apply nope; assert_eq 1 "$RC" "apply of an unknown server: EX_FAIL"

echo "7. set --apply: the write, then the same ordered calls as apply (test 8); nothing to apply when the change is a no-op"
clean s1; mk s1 running; run_as running "$ZERO"
printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"; reset
m --yes set s1 MOTD=applied --apply; assert_eq 0 "$RC" "set --apply with --yes: exit 0"
assert_eq "$ASK
docker inspect --format $FMT_LABEL mc-s1
docker inspect --format $FMT_STATE mc-s1
docker exec -i mc-s1 rcon-cli list
docker compose -p mcctl-s1 -f $SRV/compose.yaml up -d --force-recreate
$RELOAD" "$(calls)" "set --apply: name, label, state, list, up, HUP"
run_as running "$(config_hash s1)"; reset
m set s1 MOTD=applied --apply; assert_contains "$OUT" "nothing to apply" "a set that changes nothing: nothing to apply"
assert_eq 0 "$(count_calls '^docker compose')" "and no docker compose call"

echo "8. get, unset, env (test 1 of the commands in section 4.1)"
clean s1; mk s1; reset
m set s1 PVP=false >/dev/null
m get s1 PVP; assert_eq 0 "$RC" "get PVP"; assert_eq FALSE "$OUT" "get prints the stored value"
m get s1 NOPE; assert_eq 1 "$RC" "get of a key that is not set: EX_FAIL"
m get s1 pvp; assert_eq 2 "$RC" "get with a bad KEY: EX_USAGE"
m unset s1 PVP; assert_eq 0 "$RC" "unset PVP"
assert_not_contains "$(<"$SRV/server.env")" "PVP=" "PVP is gone from server.env"
assert_eq 0 "$(grep -c '      PVP:' "$SRV/compose.yaml")" "and from compose.yaml"
m unset s1 TYPE; assert_eq 4 "$RC" "unset of a structural key: EX_REFUSED"
m unset s1 bad-key; assert_eq 2 "$RC" "unset with a bad KEY: EX_USAGE"
m unset s1; assert_eq 2 "$RC" "unset with no key: EX_USAGE"
m env s1; assert_eq 0 "$RC" "env"
assert_not_contains "$OUT" "# Written" "env drops the comments"
assert_contains "$OUT" "TYPE=PAPER" "and prints the KEY=value lines"
printf 'TYPE=PAPER\nthis is not a key\n' >"$SRV/server.env"
m env s1; assert_eq 3 "$RC" "a server.env with a bad line: env exits 3"
assert_contains "$OUT" "server.env:2" "and names the line"

echo "9. properties (test 9)"
clean s1; mk s1; reset
m properties s1 set max-players 20; assert_eq 0 "$RC" "properties set max-players 20"
assert_contains "$(<"$SRV/server.env")" "MAX_PLAYERS=20" "writes MAX_PLAYERS=20"
m properties s1 set max-players abc; assert_eq 2 "$RC" "a value that fails the type of the variable: EX_USAGE"
m properties s1 set rcon.port 1; assert_eq 4 "$RC" "rcon.port is refused (EX_REFUSED)"
assert_contains "$OUT" "RCON port" "with the reason"
m properties s1 set rcon.password x; assert_eq 4 "$RC" "rcon.password is refused"
assert_contains "$OUT" "rotate-rcon" "with the reason"
m properties s1 get rcon.password; assert_eq 4 "$RC" "rcon.password is refused on get too"
m properties s1 set nosuch-prop 1; assert_eq 2 "$RC" "an unmapped property exits 2"
m properties s1 get max-players; assert_eq 0 "$RC" "get max-players"; assert_eq 20 "$OUT" "and prints the value"
m properties s1 get spawn-protection; assert_eq 1 "$RC" "a mapped property that is not set exits 1"
m properties s1 set spawn-protection 0; assert_eq 0 "$RC" "a mapped row without a type is stored (with --force)"
assert_contains "$(<"$SRV/server.env")" "SPAWN_PROTECTION=0" "SPAWN_PROTECTION=0 is in server.env"
m properties s1 list; assert_eq 0 "$RC" "properties list"
assert_eq "${#SERVER_PROPERTY[@]}" "$(printf '%s\n' "$OUT" | wc -l)" "list prints every row of the embedded table, one per line"
assert_contains "$OUT" "max-players" "a row names the property"
rm -f -- "$SRV/data/server.properties"
m properties s1 dump; assert_eq 1 "$RC" "dump with no data/server.properties: EX_FAIL"
printf 'max-players=20\nrcon.password=SECRETVALUE\nrcon.port=25575\n' >"$SRV/data/server.properties"
m properties s1 dump; assert_eq 0 "$RC" "dump reads data/server.properties"
assert_contains "$OUT" "max-players=20" "and prints it"
assert_contains "$OUT" "rcon.password=<redacted>" "with the RCON password redacted"
assert_not_contains "$OUT" "SECRETVALUE" "the password is in no output"
doc=$REPO/docs/itzg/configuration.md
if [[ -f $doc ]]; then
    n=0 bad=""
    while IFS='|' read -r _ env prop _; do
        env=${env//[\` ]/}; prop=${prop// /}
        [[ $env =~ ^[A-Z0-9_]+$ ]] || continue
        n=$((n + 1))
        [[ ${SERVER_PROPERTY[$env]-} == "$prop" ]] || bad+=" $env"
    done < <(sed -n '/^## Other Server Property Mappings/,/^## Cross-References/p' "$doc")
    assert_eq "" "$bad" "doc sync (C5): every row of the doc's table is in SERVER_PROPERTY with the same property"
    assert_eq "${#SERVER_PROPERTY[@]}" "$n" "and the doc has as many rows as the array ($n)"
else
    skip "docs/itzg/configuration.md is missing: the doc-sync check did not run"
fi

echo "10. motd, icon, resourcepack, autostart (test 10)"
clean s1; mk s1; reset
m icon s1 http://x.example/a.png; assert_eq 2 "$RC" "icon: a non-https URL is refused (EX_USAGE)"
assert_contains "$OUT" "ICON" "and names ICON"
m icon s1 https://x.example/a.png; assert_eq 0 "$RC" "icon with an https URL"
assert_contains "$(<"$SRV/server.env")" "ICON=https://x.example/a.png" "ICON is stored"
assert_not_contains "$(<"$SRV/server.env")" "OVERRIDE_ICON" "and no OVERRIDE_ICON without --override"
m icon s1 https://x.example/b.png --override; assert_eq 0 "$RC" "icon --override"
assert_contains "$(<"$SRV/server.env")" "OVERRIDE_ICON=TRUE" "--override adds OVERRIDE_ICON=TRUE"
echo x >"$SB/icon.png"
m icon s1 "$SB/icon.png"; assert_eq 2 "$RC" "a local icon file is refused (EX_USAGE)"
assert_contains "$OUT" "task 15" "and the message says it comes later (task 15)"
m icon s1; assert_eq 2 "$RC" "icon with no URL: EX_USAGE"
m icon s1 https://x.example/a.png --bogus; assert_eq 2 "$RC" "icon with an unknown option: EX_USAGE"
m motd s1 "Hello there"; assert_eq 0 "$RC" "motd"
assert_contains "$(<"$SRV/server.env")" "MOTD=Hello there" "motd stores MOTD=TEXT"
m motd s1; assert_eq 2 "$RC" "motd with no text: EX_USAGE"
m resourcepack s1 https://x.example/rp.zip --sha1 "$SHA"; assert_eq 0 "$RC" "resourcepack with --sha1"
assert_contains "$(<"$SRV/server.env")" "RESOURCE_PACK_SHA1=$SHA" "RESOURCE_PACK_SHA1 is stored"
assert_not_contains "$(<"$SRV/server.env")" "RESOURCE_PACK_ENFORCE" "no enforce key without --enforce"
m resourcepack s1 https://x.example/rp.zip --sha1 "$SHA" --enforce; assert_eq 0 "$RC" "resourcepack --enforce"
assert_contains "$(<"$SRV/server.env")" "RESOURCE_PACK_ENFORCE=TRUE" "--enforce adds RESOURCE_PACK_ENFORCE=TRUE"
m resourcepack s1 https://x.example/rp.zip; assert_eq 2 "$RC" "resourcepack without --sha1: EX_USAGE"
m resourcepack s1 https://x.example/rp.zip --sha1 abc; assert_eq 2 "$RC" "resourcepack with a short --sha1: EX_USAGE"
m resourcepack s1 http://x.example/rp.zip --sha1 "$SHA"; assert_eq 2 "$RC" "resourcepack with a non-https URL: EX_USAGE"
clean s1; mk s1; reset
m autostart s1 off; assert_eq 0 "$RC" "autostart off"
assert_contains "$(<"$SRV/server.env")" "AUTOSTART=off" "AUTOSTART=off is stored"
assert_eq 2 "$(grep -c '^    restart: "no"$' "$SRV/compose.yaml")" "both services get restart \"no\""
assert_eq "$ASK" "$(calls)" "autostart: the name check only, no docker compose call"
m autostart s1 on; assert_eq 0 "$RC" "autostart on"
assert_eq 2 "$(grep -c '^    restart: unless-stopped$' "$SRV/compose.yaml")" "and both services get unless-stopped again"
m autostart s1 maybe; assert_eq 2 "$RC" "autostart maybe: EX_USAGE"
m autostart s1; assert_eq 2 "$RC" "autostart with no value: EX_USAGE"

echo "11. Secret canary (E4, test 13): the RCON password is in no output and no call"
clean s1; mk s1 running; plant_canary "$SB/secrets/rcon-s1"
run_as running "$ZERO"
printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
ALL=""; reset
m set s1 MOTD=canary-check; ALL+=$OUT$'\n'
m status s1; ALL+=$OUT$'\n'
m --yes apply s1; ALL+=$OUT$'\n'
m status s1; ALL+=$OUT$'\n'
m --yes set s1 PVP=true --apply; ALL+=$OUT$'\n'
assert_not_contains "$ALL$(calls)" "$CANARY" "the RCON password is in neither output nor the call log"

echo "12. Every command is named here, and each refuses a missing argument with EX_USAGE (E3)"
for fn in cmd_set cmd_get cmd_unset cmd_env cmd_apply cmd_properties cmd_motd cmd_icon cmd_resourcepack cmd_autostart; do
    out=$( "$fn" 2>&1 ); rc=$?
    assert_eq 2 "$rc" "$fn with no arguments: EX_USAGE"
done

sandbox_cleanup
finish

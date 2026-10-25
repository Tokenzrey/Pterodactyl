#!/usr/bin/env bash
# lib/compose.sh: server_dir, container_name, dc, compose_escape and render_server_compose (templates/server.compose.tmpl).
# Snapshot assertions on the rendered text (no Docker). E1: dc's ordered call log. E4: a planted secret never reaches the output
# or the call log. E5: golden renders in tests/golden/ for eight fixtures (UPDATE_GOLDEN=1 rewrites them; without it a diff fails).
# Settings: the server.env keys that are environment entries, the restart policy, the config hash (config_hash, write_compose).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
sandbox
unset MCCTL_PUBLIC_IPV4 MCCTL_CF_ZONE_ID MCCTL_GAME_SUBNET MCCTL_ROUTER_IP
export MCCTL_DOMAIN=mc.example.net
load_config 2>/dev/null

# srv NAME [SERVER.ENV LINE...]: servers/NAME with the given server.env (default: the basic fixture); no modpack.env
srv() {
    local n=$1; shift
    rm -rf -- "$SB/servers/$n"; mkdir -p "$SB/servers/$n"
    if (($#)); then printf '%s\n' "$@" >"$SB/servers/$n/server.env"; else cp "$REPO/tests/fixtures/server.env.basic" "$SB/servers/$n/server.env"; fi
}
# mp NAME LINE...: servers/NAME/modpack.env
mp() { local n=$1; shift; printf '%s\n' "$@" >"$SB/servers/$n/modpack.env"; }
# render NAME: OUT = stdout, ERR = stderr, RC = status
render() { OUT=$(render_server_compose "$@" 2>"$SB/err"); RC=$?; ERR=$(<"$SB/err"); }
# block TEXT SERVICE: the lines of one service of the rendered file
block() { local b=${1#*$'\n'"  $2:"$'\n'}; b=${b%%$'\n'  [a-z]*:*}; echo "${b%%$'\n'[a-z]*}"; }
refused() { # MSG: the last render failed with status RC, printed nothing, and did not echo a secret
    [[ $RC -ne 0 && -z $OUT ]] && pass "$1" || fail "$1" "rc=$RC out=${OUT:0:200} err=$ERR"
}

echo "paths"
assert_eq "$SB/servers/demo" "$(server_dir demo)" "server_dir NAME is \$MCCTL_ROOT/servers/NAME"
assert_eq "mc-demo" "$(container_name demo)" "container_name NAME is mc-NAME"
for bad in "" "../x" "a/b" "Demo" "-a" "a b" ".."; do
    out=$(server_dir "$bad" 2>/dev/null); rc=$?
    [[ $rc -eq 2 && -z $out ]] && pass "server_dir refuses '$bad' (exit 2, no path)" || fail "server_dir refuses '$bad'" "rc=$rc out=$out"
    out=$(container_name "$bad" 2>/dev/null); rc=$?
    [[ $rc -eq 2 && -z $out ]] && pass "container_name refuses '$bad'" || fail "container_name refuses '$bad'" "rc=$rc out=$out"
done

echo "compose_escape"
assert_eq 'a$$b\"c' "$(compose_escape 'a$b"c')" 'a$b"c becomes a$$b\"c'
assert_eq 'a\\b' "$(compose_escape 'a\b')" "a backslash is doubled"
assert_eq '$$$$' "$(compose_escape '$$')" "every dollar is doubled"
assert_eq '\\\"' "$(compose_escape '\"')" "a backslash then a quote: both escaped, in that order"
assert_eq 'a & b {{NAME}} ${X}' "$(compose_escape 'a & b {{NAME}} ${X}' | sed 's/\$\$/$/g')" "& and {{ }} pass through untouched"
assert_eq "" "$(compose_escape '')" "the empty value stays empty"
assert_eq $'a\tb' "$(compose_escape $'a\tb')" "a tab is allowed"
for v in $'a\nb' $'a\rb' $'a\x01b' $'\n' $'a\x7fb'; do
    out=$(compose_escape "$v" 2>/dev/null); rc=$?
    [[ $rc -eq 2 && -z $out ]] && pass "a control character is refused with exit 2 and no output ($(printf %q "$v"))" || fail "control character refused ($(printf %q "$v"))" "rc=$rc out=$out"
done

echo "renderer: the basic fixture"
srv demo
mkdir -p "$SB/servers/demo/data"; before=$(find "$SB/servers" | sort)
render demo
assert_eq 0 "$RC" "render_server_compose exits 0"
assert_eq "" "$ERR" "and says nothing on stderr"
assert_contains "$OUT" "    image: itzg/minecraft-server" "the game container runs itzg/minecraft-server"
assert_contains "$OUT" '      - "mcctl.managed=true"' "label mcctl.managed=true"
assert_contains "$OUT" '      - "mcctl.name=demo"' "label mcctl.name=NAME"
assert_contains "$OUT" '      - "mcctl.hostname=survival"' "label mcctl.hostname=HOSTNAME_SLUG"
assert_contains "$OUT" '      - "mc-router.host=survival.mc.example.net"' "label mc-router.host=HOST.DOMAIN"
assert_contains "$OUT" '    container_name: "mc-demo"' "container_name is mc-NAME"
assert_contains "$OUT" '    mem_limit: "2816m"' "mem_limit is the heap plus 25% plus 256 MiB (2G)"
assert_contains "$OUT" '    cpus: 2' "cpus"
assert_contains "$OUT" '      MEMORY: "2G"' "MEMORY is the JVM heap"
assert_contains "$OUT" '      TYPE: "VANILLA"' "TYPE"
assert_contains "$OUT" '      VERSION: "1.21.1"' "VERSION"
assert_contains "$OUT" '      EULA: "TRUE"' "EULA comes from server.env"
assert_not_contains "$OUT" "ports:" "no ports key at all"
assert_not_contains "$OUT" "25565" "and no port number anywhere"
assert_eq 1 "$(grep -c network_mode <<<"$OUT")" "network_mode appears once in the file (the backup sidecar's, checked below)"
assert_contains "$OUT" 'RCON_PASSWORD_FILE: "/run/secrets/rcon_password"' "RCON_PASSWORD_FILE is used"
assert_not_contains "$OUT" "RCON_PASSWORD:" "RCON_PASSWORD: is not"
assert_eq "" "$(grep -E '(PASSWORD|SECRET|TOKEN|_KEY)[A-Z_]*:' <<<"$OUT" | grep -v '_FILE:')" "every credential-named key in the output is a *_FILE reference"
assert_contains "$OUT" '    file: "../../secrets/rcon-demo"' "the secret is a file path under secrets/"
mcb=$(block "$OUT" mc); bkb=$(block "$OUT" backup)
assert_contains "$mcb" $'      - ./data:/data\n      - ./mods:/mods:ro\n      - ./plugins:/plugins:ro' "the game container mounts the attach points read-only, next to the data (C2)"
assert_contains "$mcb" $'    networks:\n      - mcctl_game' "the game container is attached to mcctl_game"
assert_contains "$bkb" '    network_mode: "service:mc"' "the backup sidecar shares the network namespace of the game container (it reaches RCON over localhost)"
assert_contains "$bkb" "    depends_on: [mc]" "and starts after it"
assert_not_contains "$bkb" "networks:" "the sidecar has no network of its own (it is not on mcctl_game)"
assert_not_contains "$bkb" "ports:" "and no ports"
assert_not_contains "$mcb" "network_mode" "the game container has no network_mode"
assert_contains "$OUT" $'networks:\n  mcctl_game:\n    external: true' "mcctl_game is the external network"
assert_contains "$bkb" "    image: itzg/mc-backup" "the backup sidecar uses itzg/mc-backup"
assert_contains "$bkb" '      RCON_HOST: "127.0.0.1"' "the sidecar reaches RCON on localhost (it shares the game container's netns)"
assert_contains "$bkb" "      - ./data:/data:ro" "the sidecar mounts the world read-only"
assert_not_contains "$bkb" "mcctl.managed" "the sidecar is not a managed server (it must not be listed as one)"
assert_not_contains "$mcb" "env_file" "no env_file on the game container"
assert_not_contains "$bkb" "env_file" "and none on the sidecar (backup.env is rendered into environment entries)"
render demo; again=$OUT
assert_eq "$again" "$(render_server_compose demo 2>/dev/null)" "rendering twice gives identical output"
assert_eq "$before" "$(find "$SB/servers" | sort)" "the renderer wrote no file (no compose.yaml)"

echo "renderer: defaults and values"
srv demo '# nothing set'
render demo
assert_eq 0 "$RC" "an empty server.env renders"
assert_contains "$OUT" '      EULA: "FALSE"' "no EULA acceptance unless server.env says TRUE"
assert_contains "$OUT" '      TYPE: "VANILLA"' "TYPE defaults to VANILLA"
assert_not_contains "$OUT" "VERSION" "no VERSION line without VERSION (the image or the modpack decides)"
assert_contains "$OUT" '      - "mc-router.host=demo.mc.example.net"' "HOSTNAME_SLUG defaults to the server name"
assert_contains "$OUT" '      MEMORY: "2G"' "MEMORY defaults to 2G"
srv demo 'MEMORY=1536M' 'CPUS=1.5'
render demo
assert_contains "$OUT" '    mem_limit: "2176m"' "mem_limit from MEMORY in M (1536 + 384 + 256)"
assert_contains "$OUT" '    cpus: 1.5' "a fractional CPUS"
srv demo 'MEMORY=6g'
render demo; assert_contains "$OUT" '    mem_limit: "7936m"' "mem_limit from a lower-case g (6144 + 1536 + 256)"
srv demo 'BACKUP_ENV_FILE=backup.env'
printf 'BACKUP_INTERVAL=2h\nPRUNE_BACKUPS_COUNT=7\n' >"$SB/servers/demo/backup.env"
render demo
assert_contains "$(block "$OUT" backup)" '      BACKUP_INTERVAL: "2h"' "BACKUP_ENV_FILE renders the sidecar's env entries into the environment block"
assert_contains "$(block "$OUT" backup)" '      PRUNE_BACKUPS_COUNT: "7"' "and PRUNE_BACKUPS_COUNT too"
assert_not_contains "$(block "$OUT" mc)" "BACKUP_INTERVAL" "and only the sidecar's"
srv demo 'HOSTNAME_SLUG=a-b' 'EULA=TRUE' $'TYPE=PAPER\r' $'VERSION=1.20.4\r'
render demo; assert_eq 0 "$RC" "a CRLF server.env renders"; assert_contains "$OUT" '      TYPE: "PAPER"' "the CR is not part of the value"

echo "renderer: invalid input is reported, and nothing is emitted"
for kv in 'MEMORY=lots' 'MEMORY=0G' 'MEMORY=2' 'MEMORY=2GB' 'CPUS=0' 'CPUS=-1' 'CPUS=02' 'CPUS=1,5' 'CPUS=two' 'EULA=yes' 'EULA=true' \
          'HOSTNAME_SLUG=../x' 'HOSTNAME_SLUG=Survival' 'HOSTNAME_SLUG=a.b' 'HOSTNAME_SLUG=-a' 'TYPE=PA PER' 'TYPE=1PAPER' 'VERSION=1.21 1' \
          'VERSION=$(id)' 'BACKUP_ENV_FILE=/etc/passwd' 'BACKUP_ENV_FILE=../x.env' 'BACKUP_ENV_FILE=a b'; do
    srv demo "$kv"; render demo
    key=${kv%%=*}
    [[ $RC -eq 3 && -z $OUT && $ERR == *"$key"* ]] && pass "$kv: exit 3, nothing emitted, the key is named" || fail "$kv is refused" "rc=$RC out=${OUT:0:100} err=$ERR"
done
srv demo 'MEMORY=lots' 'CPUS=0' 'EULA=maybe'; render demo
[[ $ERR == *MEMORY* && $ERR == *CPUS* && $ERR == *EULA* ]] && pass "every problem is reported, not only the first" || fail "every problem is reported" "$ERR"
srv demo 'type=paper'; render demo; refused "a lower-case key is refused"
srv demo 'TYPE PAPER'; render demo; refused "a line that is not KEY=value is refused"
srv demo; render nosuch; refused "a server with no folder: no output"; assert_eq 1 "$RC" "exit 1 when there is no server.env"
for bad in "../x" "Demo" "" "a/b"; do render "$bad"; [[ $RC -eq 2 && -z $OUT ]] && pass "render refuses the name '$bad' (exit 2)" || fail "render refuses the name '$bad'" "rc=$RC out=$OUT"; done
out=$(unset MCCTL_DOMAIN; render_server_compose demo 2>"$SB/err"); rc=$?
[[ $rc -eq 3 && -z $out && $(<"$SB/err") == *MCCTL_DOMAIN* ]] && pass "no MCCTL_DOMAIN: exit 3, named, nothing emitted" || fail "no MCCTL_DOMAIN" "rc=$rc out=$out"
out=$(MCCTL_DOMAIN=$'mc.example.net\nports: ["25565:25565"]'; render_server_compose demo 2>/dev/null); rc=$?
[[ $rc -ne 0 && -z $out ]] && pass "a newline in the domain makes the renderer fail instead of emitting" || fail "a newline in the domain" "rc=$rc out=$out"

echo "renderer: modpack.env"
srv demo
mp demo 'MODRINTH_PROJECTS=fabric-api,lithium' '# a comment' '' 'SPAWN_PROTECTION=0'
render demo
assert_eq 0 "$RC" "modpack.env renders"
assert_contains "$OUT" $'      RCON_PASSWORD_FILE: "/run/secrets/rcon_password"\n      MODRINTH_PROJECTS: "fabric-api,lithium"\n      SPAWN_PROTECTION: "0"\n    labels:' "extra entries follow, in file order, inside the game container's environment"
assert_not_contains "$(block "$OUT" backup)" "MODRINTH" "and not in the sidecar"
mp demo $'MOTD=hello\r'; render demo; assert_contains "$OUT" '      MOTD: "hello"' "a CRLF modpack.env renders"
mp demo 'MOTD=line one' 'line two'; render demo; refused "a value with a newline (the second line is not KEY=value): fails, emits nothing"
mp demo $'MOTD=a\rb'; render demo; refused "a carriage return inside a value: fails, emits nothing"; assert_eq 4 "$RC" "and it is a refusal (exit 4)"
mp demo $'MOTD=a\x01b'; render demo; refused "another control character inside a value: fails, emits nothing"
mp demo 'EULA=TRUE'; render demo; refused "an extra key that mcctl sets itself is refused (a duplicate YAML key)"; assert_eq 3 "$RC" "exit 3"
mp demo 'MOTD=a' 'MOTD=b'; render demo; refused "an extra key set twice is refused"
mp demo 'RCON_PASSWORD_FILE=/x'; render demo; refused "RCON_PASSWORD_FILE cannot be overridden from modpack.env"
for k in RCON_PASSWORD CF_API_KEY MODRINTH_TOKEN DB_SECRET ADMIN_PASSWD; do
    mp demo "$k=hunter2-not-a-real-secret"; render demo
    [[ $RC -eq 4 && -z $OUT && $ERR != *hunter2* && $ERR == *"$k"* ]] && pass "$k as a plain value is refused (exit 4), named, the value not echoed" || fail "$k as a plain value" "rc=$RC out=$OUT err=$ERR"
done
mp demo 'CF_API_KEY_FILE=/run/secrets/cf_api_key'; render demo
assert_eq 0 "$RC" "a *_FILE reference to a credential is fine"

echo "renderer: a value cannot inject a variable, a key or a placeholder"
srv demo
mp demo 'MOTD=Cost: $5 "VIP" C:\games' 'A=${HOME} $(id) `id`' 'B=x", EVIL: "y' 'C={{NAME}} {{NOPE}} & \1'
render demo
assert_eq 0 "$RC" "hostile values render"
assert_contains "$OUT" '      MOTD: "Cost: $$5 \"VIP\" C:\\games"' 'MOTD: $ doubled, " and \ escaped'
assert_contains "$OUT" '      A: "$${HOME} $$(id) `id`"' 'no variable or command is left to interpolate'
assert_contains "$OUT" '      B: "x\", EVIL: \"y"' "a quote cannot close the scalar"
assert_contains "$OUT" '      C: "{{NAME}} {{NOPE}} & \\1"' "a placeholder inside a value stays text (no second expansion)"
assert_eq "" "$(grep -E '^ *EVIL' <<<"$OUT")" "no injected key"
assert_eq $(( $(wc -l <<<"$again") + 4 )) "$(( $(wc -l <<<"$OUT") ))" "four extra entries add exactly four lines"

echo "dc (E1)"
: >"$FAKE_STATE/calls.log"
dc demo up -d; rc1=$?
dc demo ps; dc demo logs -f --tail 5
assert_eq 0 "$rc1" "dc passes docker's exit status through"
assert_eq "docker compose -p mcctl-demo -f $SB/servers/demo/compose.yaml up -d
docker compose -p mcctl-demo -f $SB/servers/demo/compose.yaml ps
docker compose -p mcctl-demo -f $SB/servers/demo/compose.yaml logs -f --tail 5" "$(calls)" "dc NAME ARGS runs docker compose -p mcctl-NAME -f servers/NAME/compose.yaml ARGS, in order"
echo 3 >"$FAKE_STATE/docker.compose.up.rc"; dc demo up -d >/dev/null 2>&1; assert_eq 3 "$?" "a failing docker compose fails dc with the same status"; rm -f "$FAKE_STATE/docker.compose.up.rc"
n=$(count_calls .); dc "../x" ps 2>/dev/null; rc=$?; dc "" ps 2>/dev/null
assert_eq 2 "$rc" "dc refuses a bad name (exit 2)"; assert_eq "$n" "$(count_calls .)" "and does not call docker"

echo "secret canary (E4)"
mkdir_private "$SB/secrets"; plant_canary "$SB/secrets/rcon-demo"
srv demo; mp demo 'MODRINTH_PROJECTS=fabric-api'
: >"$FAKE_STATE/calls.log"
render demo; dc demo up -d >/dev/null 2>&1; dc demo ps >/dev/null 2>&1
assert_not_contains "$OUT$ERR" "$CANARY" "the secret value is not in the rendered file or its messages"
assert_not_contains "$(calls)" "$CANARY" "nor in the docker call log"
assert_contains "$OUT" '../../secrets/rcon-demo' "only the path of the secret is"
assert_eq 0 "$RC" "the render does not need to read the secret"

echo "renderer: settings in server.env (C1), the restart policy, the config hash"
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'PVP=FALSE' 'MAX_PLAYERS=20' 'MOTD=old'
mp demo 'SPAWN_PROTECTION=0'
render demo
assert_eq 0 "$RC" "server.env keys that are not structural render"
assert_contains "$OUT" $'      RCON_PASSWORD_FILE: "/run/secrets/rcon_password"\n      MAX_PLAYERS: "20"\n      MOTD: "old"\n      PVP: "FALSE"\n      SPAWN_PROTECTION: "0"\n    labels:' "sorted by key, then the modpack.env entries (C1)"
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'PVP=FALSE'; mp demo 'PVP=TRUE'
render demo; refused "a key in both server.env and modpack.env is refused"; assert_eq 3 "$RC" "exit 3 (set twice)"
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'FOO_TOKEN=hunter2-not-a-real-secret'; render demo
[[ $RC -eq 4 && -z $OUT && $ERR != *hunter2* && $ERR == *FOO_TOKEN* ]] && pass "a credential-looking server.env key is refused (exit 4), named, the value not echoed" || fail "a credential in server.env" "rc=$RC err=$ERR"
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'MOTD=$HOME "q" \n §'; render demo
assert_eq 0 "$RC" "a MOTD with \$, quotes, a backslash and a section sign renders"
assert_contains "$OUT" '      MOTD: "$$HOME \"q\" \\n §"' "and is inert: \$ doubled, quotes and the backslash escaped (test 4)"
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'AUTOSTART=off'; render demo
assert_contains "$(block "$OUT" mc)" '    restart: "no"' "AUTOSTART=off: the game container gets restart \"no\""
assert_contains "$(block "$OUT" backup)" '    restart: "no"' "and so does the sidecar"
srv demo 'TYPE=PAPER' 'EULA=TRUE'; render demo
assert_contains "$(block "$OUT" mc)" '    restart: unless-stopped' "without AUTOSTART the game container is unless-stopped"
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'AUTOSTART=maybe'; render demo; refused "AUTOSTART=maybe is refused"; assert_eq 3 "$RC" "exit 3"
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'MOTD=one'
h1=$(config_hash demo); h2=$(config_hash demo)
assert_eq "$h1" "$h2" "config_hash is stable across two renders"
[[ $h1 =~ ^[0-9a-f]{64}$ ]] && pass "and is a sha256 (64 hex digits)" || fail "config_hash is 64 hex digits" "$h1"
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'MOTD=two'
[[ $(config_hash demo) != "$h1" ]] && pass "a different MOTD gives another hash" || fail "a different MOTD gives another hash"
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'MOTD=one' 'AUTOSTART=off'
[[ $(config_hash demo) != "$h1" ]] && pass "AUTOSTART changes the hash (it changes the container)" || fail "AUTOSTART changes the hash"
for one in FABRIC_FORCE_REINSTALL=TRUE FORCE_REDOWNLOAD=TRUE REMOVE_OLD_MODS=TRUE; do
    srv demo 'TYPE=PAPER' 'EULA=TRUE' 'MOTD=one' "$one"
    assert_eq "$h1" "$(config_hash demo)" "$one does not change the hash (a one-shot key)"
    render demo; assert_contains "$OUT" "      ${one%%=*}: \"TRUE\"" "and it is still rendered into the container"
done
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'MOTD=one'
a=$(render_server_compose demo "$h1" 2>/dev/null); b=$(render_server_compose demo "other" 2>/dev/null)
assert_contains "$a" "      - \"mcctl.config_hash=$h1\"" "the label carries the hash it is given"
assert_contains "$b" '      - "mcctl.config_hash=other"' "and any other value"
assert_eq "$h1" "$(config_hash demo)" "the label never feeds the hash"
write_compose demo; assert_eq 0 "$?" "write_compose renders with the hash"
assert_contains "$(<"$SB/servers/demo/compose.yaml")" "      - \"mcctl.config_hash=$h1\"" "compose.yaml carries the label"
srv demo 'TYPE=PAPER' 'EULA=TRUE' 'MOTD=one'; rm -f "$SB/servers/demo/compose.yaml"
out=$(config_hash "../x" 2>/dev/null); rc=$?; [[ $rc -eq 2 && -z $out ]] && pass "config_hash of a bad name: exit 2, nothing printed" || fail "config_hash of a bad name" "rc=$rc"

echo "golden renders (E5)"
# fixture NAME: write servers/NAME for one golden file
fixture() {
    case $1 in
        vanilla)         srv "$1" 'TYPE=VANILLA' 'VERSION=1.21.1' 'MEMORY=2G' 'CPUS=2' 'HOSTNAME_SLUG=vanilla' 'EULA=TRUE' ;;
        paper)           srv "$1" 'TYPE=PAPER' 'VERSION=1.21.1' 'MEMORY=4G' 'CPUS=2' 'HOSTNAME_SLUG=paper' 'EULA=TRUE' 'BACKUP_ENV_FILE=backup.env'
                         mp "$1" 'ENABLE_WHITELIST=true' 'SPAWN_PROTECTION=0'
                         printf 'BACKUP_INTERVAL=2h\nPRUNE_BACKUPS_COUNT=7\n' >"$SB/servers/$1/backup.env" ;;
        fabric-modrinth) srv "$1" 'TYPE=FABRIC' 'VERSION=1.20.4' 'MEMORY=4G' 'CPUS=3' 'HOSTNAME_SLUG=fabric' 'EULA=TRUE'
                         mp "$1" 'MODRINTH_PROJECTS=fabric-api,lithium,ferrite-core' 'MODRINTH_DOWNLOAD_DEPENDENCIES=required' ;;
        curseforge)      srv "$1" 'TYPE=AUTO_CURSEFORGE' 'MEMORY=6G' 'CPUS=4' 'HOSTNAME_SLUG=atm9' 'EULA=TRUE'
                         mp "$1" 'CF_SLUG=all-the-mods-9' ;;
        forge)           srv "$1" 'TYPE=FORGE' 'VERSION=1.20.1' 'MEMORY=6G' 'CPUS=4' 'HOSTNAME_SLUG=forge' 'EULA=TRUE'
                         mp "$1" 'FORGE_VERSION=47.3.0' ;;
        motd-special)    srv "$1" 'TYPE=PAPER' 'VERSION=LATEST' 'MEMORY=1536M' 'CPUS=1.5' 'HOSTNAME_SLUG=motd' 'EULA=FALSE'
                         mp "$1" 'MOTD=Cost: $5 "VIP" C:\games' ;;
        settings)        srv "$1" 'TYPE=PAPER' 'VERSION=1.21.1' 'MEMORY=2G' 'CPUS=2' 'HOSTNAME_SLUG=settings' 'EULA=TRUE' \
                             'PVP=FALSE' 'MAX_PLAYERS=20' 'AUTOSTART=off' 'MOTD=Cost: $5 "VIP" C:\games §'
                         mp "$1" 'SPAWN_PROTECTION=0' ;;
        lists)           srv "$1" 'TYPE=FABRIC' 'VERSION=1.21.1' 'MEMORY=4G' 'CPUS=2' 'HOSTNAME_SLUG=lists' 'EULA=TRUE'
                         mkdir -p "$SB/servers/$1/lists"
                         printf '%s\n' 'https://cdn.example.net/a.jar' '/mods/local.jar' >"$SB/servers/$1/lists/mods.list"
                         printf '%s\n' '/plugins/common' >"$SB/servers/$1/lists/plugins.list"
                         printf '%s\n' 'fabric-api' 'lithium:mc1.21-0.13.0' >"$SB/servers/$1/lists/modrinth_projects.list" ;;
    esac
}
GOLD=$REPO/tests/golden
mkdir -p "$GOLD"
for g in vanilla paper fabric-modrinth curseforge forge motd-special settings lists; do
    fixture "$g"; render "$g"
    [[ $RC -eq 0 ]] || { fail "golden $g: the fixture renders" "rc=$RC $ERR"; continue; }
    assert_not_contains "$OUT" "ports:" "golden $g: no ports key"
    assert_not_contains "$OUT" "RCON_PASSWORD:" "golden $g: no plain RCON password"
    if [[ ${UPDATE_GOLDEN:-0} == 1 ]]; then
        render_server_compose "$g" >"$GOLD/$g.compose.yaml" 2>/dev/null && pass "golden $g rewritten (UPDATE_GOLDEN=1)" || fail "golden $g rewrite"
    elif [[ ! -f $GOLD/$g.compose.yaml ]]; then
        fail "golden $g exists" "missing $GOLD/$g.compose.yaml (run: UPDATE_GOLDEN=1 bash tests/t_compose.sh, then read the file)"
    elif diff -u "$GOLD/$g.compose.yaml" <(render_server_compose "$g" 2>/dev/null) >"$SB/gdiff" 2>&1; then
        pass "golden $g matches"
    else
        fail "golden $g matches (UPDATE_GOLDEN=1 rewrites it; read the diff first)" "$(head -n 8 "$SB/gdiff")"
    fi
done
assert_contains "$(render_server_compose motd-special 2>/dev/null)" '      MOTD: "Cost: $$5 \"VIP\" C:\\games"' "golden motd-special: \$ doubled, \" and \\ escaped"
assert_not_contains "$(render_server_compose curseforge 2>/dev/null)" "VERSION" "golden curseforge: no VERSION (the pack decides)"

echo "renderer: JAVA picks the image's Java version, and is never an environment entry"
srv javaed17; printf 'JAVA=17\n' >>"$SB/servers/javaed17/server.env"
render javaed17
assert_contains "$OUT" "    image: itzg/minecraft-server:java17" "JAVA=17: the game image is itzg/minecraft-server:java17"
assert_not_contains "$OUT" "JAVA:" "and JAVA is not an environment entry of the game container"
srv javaless
render javaless
assert_contains "$OUT" "    image: itzg/minecraft-server"$'\n' "no JAVA: the image has no tag (the image default)"
assert_not_contains "$OUT" "minecraft-server:java" "and no Java tag is written"
srv javabad; printf 'JAVA=8\n' >>"$SB/servers/javabad/server.env"
render javabad
refused "JAVA=8 is refused: exit 3, nothing rendered"
assert_contains "$ERR" "JAVA is '8', expected 17, 21, 25 or nothing" "and the message names the accepted values"

sandbox_cleanup
finish

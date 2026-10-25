#!/usr/bin/env bash
# shellcheck shell=bash
# The settings engine: set, get, unset, env, apply, properties, and the shortcuts motd, icon, resourcepack and autostart. Sourced by
# ./mcctl, never executed.
#
# A setting is a KEY=VALUE line of servers/NAME/server.env. A change is validated, written there in one write, and rendered into
# compose.yaml (write_compose). The running container keeps its old configuration until `apply` (or `set --apply`) recreates it:
# status compares the label mcctl.config_hash of the container with config_hash NAME (lib/compose.sh) and says current or pending.
# set refuses, even with --force: a credential (_is_credential), a structural key (SE_STRUCTURAL in lib/compose.sh) and a reserved
# key (SE_RESERVED): rcon, the backup sidecar, rotate-rcon and the CurseForge key assume them.

# The known keys and their types. bool; int (at most 9 digits); text (at most 1000 characters); json (stored compact, at most 8192
# characters); https-url; sha1 (40 hex digits, stored in lower case); enum:A,B,C (case-insensitive, stored as listed).
declare -A SETTING_TYPE=(
    [MOTD]=text [MAX_PLAYERS]=int [DIFFICULTY]=enum:peaceful,easy,normal,hard [MODE]=enum:survival,creative,adventure,spectator
    [PVP]=bool [LEVEL_TYPE]=text [SEED]=text [ICON]=https-url [OVERRIDE_ICON]=bool [RESOURCE_PACK]=https-url
    [RESOURCE_PACK_SHA1]=sha1 [RESOURCE_PACK_ENFORCE]=bool [ENABLE_WHITELIST]=bool [OPS]=text [WHITELIST]=text
    [VIEW_DISTANCE]=int [ALLOW_NETHER]=bool [HARDCORE]=bool [GENERATOR_SETTINGS]=json
)
# The reserved keys. The two credential keys of the RCON password and of the CurseForge key are refused by _is_credential before this.
SE_RESERVED=" RCON_PORT ENABLE_RCON RCON_PASSWORD_FILE CF_API_KEY_FILE "

# The itzg environment variable -> server.properties name (docs/single-standalone/configuration.md, "Other Server Property Mappings").
# The doc-sync test in tests/t_settings.sh checks every row against that doc. Embedded, so that no run reads the docs folder.
declare -A SERVER_PROPERTY=(
    [ACCEPTS_TRANSFERS]=accepts-transfers [ALLOW_FLIGHT]=allow-flight [ALLOW_NETHER]=allow-nether
    [ANNOUNCE_PLAYER_ACHIEVEMENTS]=announce-player-achievements [BROADCAST_CONSOLE_TO_OPS]=broadcast-console-to-ops
    [BROADCAST_RCON_TO_OPS]=broadcast-rcon-to-ops [BUG_REPORT_LINK]=bug-report-link [ENABLE_COMMAND_BLOCK]=enable-command-block
    [ENABLE_STATUS]=enable-status [ENFORCE_SECURE_PROFILE]=enforce-secure-profile
    [ENTITY_BROADCAST_RANGE_PERCENTAGE]=entity-broadcast-range-percentage [FORCE_GAMEMODE]=force-gamemode
    [FUNCTION_PERMISSION_LEVEL]=function-permission-level [GENERATE_STRUCTURES]=generate-structures
    [GENERATOR_SETTINGS]=generator-settings [HARDCORE]=hardcore [HIDE_ONLINE_PLAYERS]=hide-online-players [LOG_IPS]=log-ips
    [MAX_BUILD_HEIGHT]=max-build-height [MAX_COMMAND_CHAIN_LENGTH]=max-command-chain-length
    [MAX_ENTITY_CRAMMING]=max-entity-cramming [MAX_ENTITY_COLLISION_RADIUS]=max-entity-collision-radius
    [MAX_FUNCTION_CHAIN_DEPTH]=max-function-chain-depth [MAX_NEIGHBORS]=max-neighbors
    [MAX_CHAINED_NEIGHBOR_UPDATES]=max-chained-neighbor-updates [MAX_PLAYERS]=max-players [MAX_TICK_TIME]=max-tick-time
    [MAX_WORLD_SIZE]=max-world-size [NETWORK_COMPRESSION_THRESHOLD]=network-compression-threshold [ONLINE_MODE]=online-mode
    [OP_PERMISSION_LEVEL]=op-permission-level [PAUSE_WHEN_EMPTY_SECONDS]=pause-when-empty-seconds
    [PLAYER_IDLE_TIMEOUT]=player-idle-timeout [PREVENT_PROXY_CONNECTIONS]=prevent-proxy-connections [PVP]=pvp
    [RATE_LIMIT]=rate-limit [REGION_FILE_COMPRESSION]=region-file-compression [RESOURCE_PACK_ID]=resource-pack-id
    [RESOURCE_PACK_PROMPT]=resource-pack-prompt [SERVER_NAME]=server-name [SIMULATION_DISTANCE]=simulation-distance
    [SPAWN_ANIMALS]=spawn-animals [SPAWN_MONSTERS]=spawn-monsters [SPAWN_NPCS]=spawn-npcs [SPAWN_PROTECTION]=spawn-protection
    [STATUS_HEARTBEAT_INTERVAL]=status-heartbeat-interval [SYNC_CHUNK_WRITES]=sync-chunk-writes
    [USE_NATIVE_TRANSPORT]=use-native-transport [VIEW_DISTANCE]=view-distance
)

# ---- values ------------------------------------------------------------------------------------------------------------------

# settings_type KEY -> stdout the type of KEY; 1 when KEY is not a known setting
settings_type() {
    [[ -n ${1-} && -n ${SETTING_TYPE[$1]+x} ]] || return 1
    printf '%s\n' "${SETTING_TYPE[$1]}"
}

# settings_check KEY TYPE VALUE -> stdout VALUE as it is stored; 2 with a message when VALUE is not valid for TYPE
settings_check() {
    local k=$1 t=$2 v=$3 out=$3 want="" re="" o ok=0
    local -a opts=()
    case $t in
        bool)
            case $v in
                true|TRUE) out=TRUE; ok=1 ;;
                false|FALSE) out=FALSE; ok=1 ;;
                *) want="true or false" ;;
            esac ;;
        int) re='^[0-9]{1,9}$'; want="a whole number of at most 9 digits" ;;
        enum:*)
            want="one of ${t#enum:}"
            IFS=, read -ra opts <<<"${t#enum:}"
            for o in "${opts[@]}"; do [[ ${o,,} == "${v,,}" ]] && { out=$o; ok=1; }; done ;;
        https-url) re='^https://[^[:space:]]+$'; want="an https:// address with no space" ;;
        sha1) re='^[0-9a-fA-F]{40}$'; out=${v,,}; want="40 hex digits (a SHA-1)" ;;
        text) want="text of at most 1000 characters"; ((${#v} <= 1000)) && ok=1 ;;
        json)
            command -v jq >/dev/null || { err "$k needs jq, which is not installed"; return "$EX_FAIL"; }
            want="JSON of at most 8192 characters"
            out=$(jq -c . <<<"$v" 2>/dev/null) && ((${#out} <= 8192)) && ok=1 ;;
    esac
    [[ -z $re ]] || { [[ $v =~ $re ]] && ok=1; }
    if ((ok)); then printf '%s\n' "$out"; return 0; fi
    err "$k is ${v@Q}, expected $want"
    return "$EX_USAGE"
}

# ---- the write -----------------------------------------------------------------------------------------------------------------

# _settings_store NAME KEY VALUE [KEY VALUE...]: one write of server.env, then compose.yaml. A render that fails puts the old
# server.env back (_env_write_compose), so a failed set changes nothing.
_settings_store() {
    local name=$1 dir old
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    [[ -f $dir/server.env ]] || die "no $dir/server.env" "$EX_FAIL"
    old=$(cat "$dir/server.env"; printf X); old=${old%X}
    server_env_set "$name" "${@:2}" || die "cannot write $dir/server.env (see above)" "$EX_FAIL"
    _env_write_compose "$name" "$old"
}

# apply_pending NAME: recreate the containers of NAME when their configuration is not the one they run. config_hash NAME is compared
# with the label of the game container: equal means nothing to do (no docker compose call). Otherwise compose.yaml is written, the
# players are checked (_recreate_guard) and the containers are recreated (_recreate_apply).
apply_pending() {
    local name=$1 want have
    want=$(config_hash "$name") || die "$name: server.env does not render (see above): nothing was applied" "$EX_PREFLIGHT"
    have=$(server_label "$name" mcctl.config_hash) || die "cannot inspect mc-$name (see above): nothing was applied"
    if [[ $have == "$want" ]]; then info "$name: nothing to apply: the container runs this configuration"; return 0; fi
    write_compose "$name" || die "cannot render $name's compose.yaml (see above): nothing was applied" "$EX_FAIL"
    _recreate_guard "$name"
    _recreate_apply "$name"
}

# ---- commands ------------------------------------------------------------------------------------------------------------------

# cmd_set NAME KEY=VALUE... [--apply] [--force]: every pair is validated first, and nothing is written unless all of them pass.
# --apply then applies the change (apply_pending); without it the answer says config pending. --force stores a KEY that is not a
# known setting (it never lifts a refusal).
cmd_set() {
    local usage="usage: mcctl set NAME KEY=VALUE... [--apply] [--force]"
    local name=${1-} p k v nv t i bad=0 apply=0 force=0
    local -a keys=() vals=() pairs=() args=()
    local -A seen=()
    (($# >= 1)) && [[ $name != --* ]] || die "NAME is missing (it comes right after set). $usage" "$EX_USAGE"
    shift
    for p in "$@"; do
        case $p in
            --apply) apply=1 ;;
            --force) force=1 ;;
            *) args+=("$p") ;;
        esac
    done
    for p in "${args[@]}"; do
        if [[ $p != *=* ]]; then err "${p@Q} is not KEY=VALUE"; bad=$EX_USAGE; continue; fi
        k=${p%%=*} v=${p#*=}
        if [[ ! $k =~ ^[A-Z][A-Z0-9_]*$ ]]; then err "KEY ${k@Q} must be capitals, digits and _, and start with a letter"; bad=$EX_USAGE; continue; fi
        if [[ $v == *[[:cntrl:]]* ]]; then err "$k: the value must be one line with no control character"; bad=$EX_USAGE; continue; fi
        if _is_credential "$k"; then err "$k looks like a credential: put it in a file under secrets/ and set ${k}_FILE"; bad=$EX_REFUSED; continue; fi
        if [[ $SE_STRUCTURAL == *" $k "* ]]; then
            err "$k is structural: set does not change it (MEMORY and CPUS: mcctl edit; AUTOSTART: mcctl autostart)"; bad=$EX_REFUSED; continue
        fi
        if [[ $SE_RESERVED == *" $k "* ]]; then err "$k is reserved: mcctl's RCON and CurseForge wiring depends on it"; bad=$EX_REFUSED; continue; fi
        if t=$(settings_type "$k"); then
            nv=$(settings_check "$k" "$t" "$v") || { bad=$EX_USAGE; continue; }
            v=$nv
        elif ((!force)); then
            err "$k is not a known setting: add --force to store it anyway"; bad=$EX_USAGE; continue
        fi
        if [[ -n ${seen[$k]+x} ]]; then err "$k is given twice"; bad=$EX_USAGE; continue; fi
        seen[$k]=1; keys+=("$k"); vals+=("$v")
    done
    ((bad == 0)) || { err "nothing was written"; exit "$bad"; }
    ((${#keys[@]})) || die "no KEY=VALUE given. $usage" "$EX_USAGE"
    _need_server "$name"
    for i in "${!keys[@]}"; do pairs+=("${keys[i]}" "${vals[i]}"); done
    _settings_store "$name" "${pairs[@]}"
    if ((apply)); then apply_pending "$name"; else info "$name: config pending: mcctl apply $name"; fi
}

# server_env_get NAME KEY -> stdout the value of KEY in servers/NAME/server.env (the last line that sets it); 1 when KEY is not set;
# EX_USAGE for a KEY that is not capitals, digits and _. A malformed server.env passes its EX_PREFLIGHT through (kv_lines names the line).
server_env_get() {
    local key=${2-} dir lines line
    [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] || return "$EX_USAGE"
    dir=$(server_dir "${1-}") || return
    lines=$(kv_lines "$dir/server.env") || return "$EX_PREFLIGHT"
    line=$(grep -E "^$key=" <<<"$lines" | tail -n 1)
    [[ -n $line ]] || return 1
    printf '%s\n' "${line#*=}"
}

# cmd_get NAME KEY: the value of KEY in server.env; exit 1 when it is not set
cmd_get() {
    local usage="usage: mcctl get NAME KEY"
    (($# == 2)) || die "$usage" "$EX_USAGE"
    local name=$1 k=$2 dir lines line
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || die "KEY ${k@Q} must be capitals, digits and _, and start with a letter" "$EX_USAGE"
    _need_server "$name"
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    lines=$(kv_lines "$dir/server.env") || exit "$EX_PREFLIGHT"
    line=$(grep -E "^$k=" <<<"$lines" | tail -n 1)
    [[ -n $line ]] || die "$k is not set for $name" "$EX_FAIL"
    printf '%s\n' "${line#*=}"
}

# cmd_java NAME set 17|21|25|default: the Java major version of the server's image (itzg/minecraft-server:javaN). Forge 1.20.1 needs 17,
# and the image's default is the newest Java, so an older modpack must be given 17. The value is the structural key JAVA in server.env,
# and it is applied like any setting: the containers are recreated if the server runs, or made again (still stopped) if it does not.
cmd_java() {
    local name=${1-} act=${2-} v=${3-}
    (($# == 3)) && [[ $act == set ]] || die "usage: mcctl java NAME set 17|21|25|default" "$EX_USAGE"
    _need_server "$name"
    local old
    old=$(<"$(server_dir "$name")/server.env") || die "cannot read $name's server.env (see above)" "$EX_FAIL"
    case $v in
        17|21|25) server_env_set "$name" JAVA "$v" ;;
        default) server_env_unset "$name" JAVA ;;
        *) die "JAVA ${v@Q} is not offered: use 17, 21, 25 or default" "$EX_USAGE" ;;
    esac
    _env_write_compose "$name" "$old"   # renders compose.yaml; server.env goes back if that fails
    apply_pending "$name"
}

# cmd_unset NAME KEY...: remove the keys from server.env. A structural key is refused.
cmd_unset() {
    local usage="usage: mcctl unset NAME KEY..."
    (($# >= 2)) || die "$usage" "$EX_USAGE"
    local name=$1 k dir old
    shift
    for k; do
        [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || die "KEY ${k@Q} must be capitals, digits and _, and start with a letter" "$EX_USAGE"
        [[ $SE_STRUCTURAL != *" $k "* ]] || die "$k is structural: unset does not remove it (MEMORY and CPUS: mcctl edit; AUTOSTART: mcctl autostart)" "$EX_REFUSED"
    done
    _need_server "$name"
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    [[ -f $dir/server.env ]] || die "no $dir/server.env" "$EX_FAIL"
    old=$(cat "$dir/server.env"; printf X); old=${old%X}
    server_env_unset "$name" "$@" || die "cannot write $dir/server.env (see above)" "$EX_FAIL"
    _env_write_compose "$name" "$old"
    info "$name: removed. config pending: mcctl apply $name"
}

# cmd_env NAME: server.env without its comments and blank lines (every line must be KEY=value)
cmd_env() {
    (($# == 1)) || die "usage: mcctl env NAME" "$EX_USAGE"
    _need_server "$1"
    kv_lines "$(server_dir "$1")/server.env" || exit "$EX_PREFLIGHT"
}

# cmd_apply NAME: apply the pending configuration (recreates the containers; asks first when players are online)
cmd_apply() {
    (($# == 1)) || die "usage: mcctl apply NAME" "$EX_USAGE"
    _need_server "$1"
    apply_pending "$1"
}

# property_to_env PROPERTY -> stdout the environment variable of a server.properties name (upper case, '-' and '.' become '_'). 2 when
# the result is neither a row of SERVER_PROPERTY nor one of the six names that map to themselves; 4 for rcon.port and rcon.password.
property_to_env() {
    local p=${1-} e
    case $p in
        rcon.port) err "rcon.port is not set here: itzg warns against changing the RCON port, and mcctl rcon, the backup sidecar and rotate-rcon assume the default"; return "$EX_REFUSED" ;;
        rcon.password) err "rcon.password is not set here: the RCON password is secrets/rcon-NAME, and mcctl rotate-rcon NAME makes a new one"; return "$EX_REFUSED" ;;
    esac
    e=${p^^}; e=${e//[-.]/_}
    if [[ -n $e && ( -n ${SERVER_PROPERTY[$e]+x} || " MOTD DIFFICULTY MODE LEVEL LEVEL_TYPE SEED " == *" $e "* ) ]]; then
        printf '%s\n' "$e"
        return 0
    fi
    err "no environment variable for the server property ${p@Q} (mcctl properties NAME list shows the mapped ones)"
    return "$EX_USAGE"
}

# cmd_properties NAME list | get KEY | set KEY VALUE | dump: server.properties names, through the mapping above. set stores the
# mapped variable with --force, because a row without a type in SETTING_TYPE is stored as text (add its type there to check it).
# dump prints data/server.properties of the server with the RCON password redacted.
cmd_properties() {
    local usage="usage: mcctl properties NAME list | get KEY | set KEY VALUE | dump"
    (($# >= 2)) || die "$usage" "$EX_USAGE"
    local name=$1 act=$2 env f k
    shift 2
    case $act in
        list)
            (($# == 0)) || die "$usage" "$EX_USAGE"
            for k in $(printf '%s\n' "${!SERVER_PROPERTY[@]}" | LC_ALL=C sort); do
                printf '%-36s %s\n' "${SERVER_PROPERTY[$k]}" "$k"
            done ;;
        get)
            (($# == 1)) || die "$usage" "$EX_USAGE"
            env=$(property_to_env "$1") || exit $?
            cmd_get "$name" "$env" ;;
        set)
            (($# == 2)) || die "$usage" "$EX_USAGE"
            env=$(property_to_env "$1") || exit $?
            cmd_set "$name" "$env=$2" --force ;;
        dump)
            (($# == 0)) || die "$usage" "$EX_USAGE"
            _need_server "$name"
            f=$(server_dir "$name")/data/server.properties
            [[ -f $f ]] || die "no $f yet (the server writes it on its first start)" "$EX_FAIL"
            sed -E 's/^(rcon\.password)=.*/\1=<redacted>/' "$f" ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac
}

# cmd_motd NAME TEXT: set MOTD
cmd_motd() {
    (($# == 2)) || die "usage: mcctl motd NAME TEXT" "$EX_USAGE"
    cmd_set "$1" "MOTD=$2"
}

# cmd_icon NAME URL [--override]: set ICON (an https URL); --override also sets OVERRIDE_ICON=TRUE. A local file is task 15's.
cmd_icon() {
    local usage="usage: mcctl icon NAME URL [--override]"
    case $# in
        2) ;;
        3) [[ $3 == --override ]] || die "$usage" "$EX_USAGE" ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac
    [[ ! -f $2 ]] || die "local icon files come later (task 15): give an https:// URL" "$EX_USAGE"
    local -a kv=("ICON=$2")
    (($# == 3)) && kv+=(OVERRIDE_ICON=TRUE)
    cmd_set "$1" "${kv[@]}"
}

# cmd_resourcepack NAME URL --sha1 HEX [--enforce]: RESOURCE_PACK and RESOURCE_PACK_SHA1 (both required), RESOURCE_PACK_ENFORCE=TRUE
cmd_resourcepack() {
    local usage="usage: mcctl resourcepack NAME URL --sha1 HEX [--enforce]"
    (($# >= 2)) || die "$usage" "$EX_USAGE"
    local name=$1 url=$2 sha="" enforce=0
    local -a kv
    shift 2
    while (($#)); do
        case $1 in
            --sha1) (($# >= 2)) || die "--sha1 needs a value. $usage" "$EX_USAGE"; sha=$2; shift ;;
            --enforce) enforce=1 ;;
            *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
        esac
        shift
    done
    [[ -n $sha ]] || die "--sha1 is required (the SHA-1 of the pack, 40 hex digits). $usage" "$EX_USAGE"
    kv=("RESOURCE_PACK=$url" "RESOURCE_PACK_SHA1=$sha")
    ((enforce)) && kv+=(RESOURCE_PACK_ENFORCE=TRUE)
    cmd_set "$name" "${kv[@]}"
}

# cmd_autostart NAME on|off: restart policy of both services (the structural key AUTOSTART; the renderer writes restart)
cmd_autostart() {
    (($# == 2)) && [[ $2 == on || $2 == off ]] || die "usage: mcctl autostart NAME on|off" "$EX_USAGE"
    _need_server "$1"
    _settings_store "$1" AUTOSTART "$2"
    info "$1: autostart $2. config pending: mcctl apply $1"
}

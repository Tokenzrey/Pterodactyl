#!/usr/bin/env bash
# shellcheck shell=bash
# Per-server paths, the `dc` docker compose wrapper, and the compose renderer. Sourced by ./mcctl, never executed.
#
# The renderer is pure: it reads servers/NAME/server.env and servers/NAME/modpack.env and prints the compose YAML on stdout. It
# writes no file (write_compose writes compose.yaml atomically) and prints nothing at all when it fails, so a failed render cannot
# leave a half-written file behind. It never reads secrets/: a credential is only ever a *_FILE path in the YAML.
#
# server.env  KEY=VALUE lines, parsed and never sourced. Read: TYPE VERSION MEMORY CPUS HOSTNAME_SLUG EULA BACKUP_ENV_FILE AUTOSTART;
#             every other key is an environment entry of the game container (sorted by key, before modpack.env).
# modpack.env zero or more extra KEY=VALUE lines that become environment entries of the game container (modpack and mod settings).
# Lists       servers/NAME/lists/{mods,plugins,modrinth_projects}.list (lib/mods.sh): MODS, PLUGINS, MODRINTH_PROJECTS, one literal block each.
# Mounts      ./data, and the attach points ./mods:/mods:ro and ./plugins:/plugins:ro (lib/mods.sh puts local jars there).
# Secrets     secrets/rcon-NAME holds the RCON password; the compose file points at it (../../secrets/rcon-NAME).
#             A CurseForge server (TYPE or MOD_PLATFORM or MODPACK_PLATFORM is AUTO_CURSEFORGE) also gets the CurseForge API key,
#             the file secrets/curseforge_api_key, mounted read-only by compose at /run/secrets/cf_api_key and passed on only as
#             CF_API_KEY_FILE. The renderer owns that variable; modpack.env may not set it.
# Services    "mc" (container mc-NAME) lives on the external network mcctl_game. "backup" (container mc-NAME-backup) shares the
#             network namespace of "mc" (network_mode "service:mc"): it reaches RCON over localhost, so the egress guard needs no
#             rule that lets game containers reach each other, and the sidecar has no network, no address and no port of its own.

COMPOSE_TMPL=$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates" 2>/dev/null && pwd -P)/server.compose.tmpl
CF_KEY_SECRET=curseforge_api_key   # secrets/<this>: the CurseForge API key, one for all servers

# ---- paths and docker compose ------------------------------------------------------------------------------------------------

# _need_name NAME: 0 when NAME can be a server name; else a message and EX_USAGE. Every path below is built from a name that
# passed this, so no caller can reach outside servers/ through a name.
_need_name() {
    local n=${1-}
    valid_server_name "$n" && return 0
    err "invalid server name ${n@Q} (lower-case letters, digits and '-', 1 to 40 characters, starting with a letter or digit)"
    return "$EX_USAGE"
}

# server_dir NAME -> stdout $MCCTL_ROOT/servers/NAME
server_dir() { _need_name "${1-}" && printf '%s\n' "$MCCTL_ROOT/servers/$1"; }

# list_file NAME KEY -> stdout servers/NAME/lists/<KEY in lower case>.list, for KEY MODS, PLUGINS or MODRINTH_PROJECTS; 2 for any other KEY
list_file() {
    local key=${2-} dir
    case $key in MODS|PLUGINS|MODRINTH_PROJECTS) ;; *) err "no list named ${key@Q}"; return "$EX_USAGE" ;; esac
    dir=$(server_dir "${1-}") || return
    printf '%s/lists/%s.list\n' "$dir" "${key,,}"
}

# attach_dir NAME ATTACH -> stdout servers/NAME/ATTACH (ATTACH is mods or plugins), made with mode 755 when it is missing. The compose
# file mounts it: Docker would create a missing bind source as a root-owned folder, which the game's user could not use.
attach_dir() {
    local dir
    dir=$(server_dir "${1-}") || return
    (umask 022 && mkdir -p -- "$dir/$2") || return
    printf '%s/%s\n' "$dir" "$2"
}

# container_name NAME -> stdout mc-NAME
container_name() { _need_name "${1-}" && printf 'mc-%s\n' "$1"; }

# dc NAME ARGS...: docker compose for one server (project mcctl-NAME, file servers/NAME/compose.yaml)
dc() {
    local name=${1-}
    _need_name "$name" || return
    shift
    docker compose -p "mcctl-$name" -f "$MCCTL_ROOT/servers/$name/compose.yaml" "$@"
}

# ---- escaping ----------------------------------------------------------------------------------------------------------------

# compose_escape VALUE -> stdout VALUE made safe inside a double-quoted compose scalar: `$` becomes `$$` (no variable
# interpolation), `\` becomes `\\` and `"` becomes `\"`. A newline, a carriage return or any other control character (a tab is
# fine) is refused with EX_USAGE and no output: it could end the scalar or the line.
compose_escape() {
    local LC_ALL=C v=${1-} bs='\' q='"' d='$' t
    t=${v//$'\t'/}
    if [[ $t == *[[:cntrl:]]* ]]; then
        err "a newline or other control character cannot be written into a compose file"
        return "$EX_USAGE"
    fi
    v=${v//"$bs"/"$bs$bs"}; v=${v//"$q"/"$bs$q"}; v=${v//"$d"/"$d$d"}
    printf '%s\n' "$v"
}

# block_escape LINE -> stdout LINE for a literal block scalar (`KEY: |`, the lists). Inside one only `$` is special (compose
# interpolates it), so it becomes `$$`; a backslash and a quote are plain text there. A control character (a tab too) is refused
# with EX_USAGE and no output: it could end the block or the line.
block_escape() {
    local LC_ALL=C v=${1-} d='$'
    if [[ $v == *[[:cntrl:]]* ]]; then
        err "a control character cannot be written into a compose file"
        return "$EX_USAGE"
    fi
    v=${v//"$d"/"$d$d"}
    printf '%s\n' "$v"
}

# ---- parsing -----------------------------------------------------------------------------------------------------------------

# kv_lines FILE: print the KEY=VALUE lines of FILE (blank lines, # comments and a trailing CR dropped). KEY is capitals, digits
# and _. The value is everything after the first "=", verbatim: never evaluated, never unquoted. Returns 1, naming the line
# number (never its text, which may be a secret), for any other line.
kv_lines() {
    local file=$1 line n=0 bad=0 pair='^[A-Z][A-Z0-9_]*=' blank='^[[:space:]]*(#.*)?$'
    [[ -r $file ]] || { err "cannot read $file"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ $line =~ $blank ]] && continue
        if [[ $line =~ $pair ]]; then printf '%s\n' "$line"; else err "$file:$n: expected KEY=value (KEY in capitals, digits and _)"; bad=1; fi
    done <"$file"
    return "$bad"
}

# kv_read FILE ARRAY: fill the associative array ARRAY (a name, by reference) with the KEY=VALUE lines of FILE (kv_lines). Dies, after
# kv_lines has named the bad line, when FILE cannot be read or is not valid.
kv_read() {
    local -n _kv=$2
    local lines line
    lines=$(kv_lines "$1") || die "$1 is not valid (see above): nothing was changed" "$EX_PREFLIGHT"
    _kv=()
    while IFS= read -r line; do [[ -z $line ]] || _kv[${line%%=*}]=${line#*=}; done <<<"$lines"
}

# _se_check KEY VALUE REGEX WANT: 0 when VALUE matches REGEX; else a message and 1. Messages start with $SE_CTX (default
# "server.env"); `create` sets it to "mcctl create" because there the values come from flags.
_se_check() { [[ $2 =~ $3 ]] && return 0; err "${SE_CTX:-server.env}: $1 is ${2@Q}, expected $4"; return 1; }

# check_server_values TYPE VERSION MEMORY CPUS EULA HOST BACKUP_ENV_FILE: the one place that says what a server.env value may
# be (the renderer and `mcctl create` both ask it). VERSION and BACKUP_ENV_FILE may be empty. Prints every problem, never
# stops at the first; returns 0, or EX_PREFLIGHT when any value is invalid.
check_server_values() {
    local srv_type=$1 version=$2 mem=$3 cpus=$4 eula=$5 host=$6 benv=$7 rc=0
    _se_check TYPE "$srv_type" '^[A-Za-z][A-Za-z0-9_]*$' "letters, digits and _ (for example PAPER)" || rc=$EX_PREFLIGHT
    [[ -z $version ]] || _se_check VERSION "$version" '^[A-Za-z0-9][A-Za-z0-9._+-]*$' "a version such as 1.21.1, LATEST or SNAPSHOT" || rc=$EX_PREFLIGHT
    _se_check MEMORY "$mem" '^[1-9][0-9]{0,5}[MmGg]$' "a size such as 2G or 1536M" || rc=$EX_PREFLIGHT
    _se_check CPUS "$cpus" '^(0|[1-9][0-9]{0,2})(\.[0-9]{1,2})?$' "a number such as 2 or 1.5" || rc=$EX_PREFLIGHT
    [[ $cpus =~ [1-9] ]] || { err "${SE_CTX:-server.env}: CPUS is ${cpus@Q}, expected more than 0"; rc=$EX_PREFLIGHT; }
    _se_check EULA "$eula" '^(TRUE|FALSE)$' "TRUE or FALSE" || rc=$EX_PREFLIGHT
    # a host name is a DNS label: no '-' at either end
    { valid_server_name "$host" && [[ $host != *- ]]; } \
        || { err "${SE_CTX:-server.env}: HOSTNAME_SLUG is ${host@Q}, expected lower-case letters, digits and '-', not ending in '-'"; rc=$EX_PREFLIGHT; }
    [[ -z $benv ]] || { [[ $benv =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ && $benv != *..* ]] \
        || { err "${SE_CTX:-server.env}: BACKUP_ENV_FILE is ${benv@Q}, expected a relative path inside the server folder"; rc=$EX_PREFLIGHT; }; }
    return "$rc"
}

# ---- the renderer ------------------------------------------------------------------------------------------------------------

# SE_STRUCTURAL: the server.env keys mcctl reads for itself. They are never environment entries of the game container.
SE_STRUCTURAL=" TYPE VERSION MEMORY CPUS EULA HOSTNAME_SLUG BACKUP_ENV_FILE AUTOSTART JAVA "

# _is_credential KEY: 0 when KEY looks like a secret, whose value must then be a file (KEY_FILE), never a plain value
_is_credential() { [[ ${1-} =~ (PASSWORD|PASSWD|SECRET|TOKEN|_KEY)$ ]]; }

# _fill_template FILE ASSOC: print FILE with every {{KEY}} replaced by ASSOC[KEY] (an unknown KEY is an error). A value is
# appended to the output and never scanned again, so a value that contains {{ is inert. A placeholder alone on a line stands for
# a block; the line disappears when the block is empty. Prints nothing unless the whole template was filled.
_fill_template() {
    local -n _tv=$2
    local line pre rest key out="" o='{{' c='}}' whole='^\{\{[A-Z_]+\}\}$'
    [[ -r $1 ]] || { err "cannot read the template $1"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ $whole ]]; then
            key=${line:2:${#line}-4}
            [[ -n ${_tv[$key]+x} ]] || { err "template: no value for {{$key}}"; return 1; }
            [[ -z ${_tv[$key]} ]] || out+=${_tv[$key]}$'\n'
            continue
        fi
        while [[ $line == *"$o"*"$c"* ]]; do
            pre=${line%%"$o"*} rest=${line#*"$o"} key=${rest%%"$c"*}
            [[ -n ${_tv[$key]+x} ]] || { err "template: no value for {{$key}}"; return 1; }
            out+=$pre${_tv[$key]}
            line=${rest#*"$c"}
        done
        out+=$line$'\n'
    done <"$1"
    printf '%s' "$out"
}

# _list_block KEY FILE -> stdout one environment entry for a list file: `      KEY: |` with each line on its own, indented 8 spaces and
# written through block_escape; `      KEY: ""` when FILE is empty (the --remove-installed state). EX_REFUSED for a line that cannot be
# written: a control character, or a leading space (it would move the block's indentation, and compose would refuse the file).
_list_block() {
    local key=$1 file=$2 line body=""
    if [[ ! -s $file ]]; then printf '      %s: ""\n' "$key"; return 0; fi
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line != [[:blank:]]* ]] || { err "$file: an entry starts with a space: $key cannot be written"; return "$EX_REFUSED"; }
        line=$(block_escape "$line") || return "$EX_REFUSED"
        body+="        $line"$'\n'
    done <"$file"
    printf '      %s: |\n%s' "$key" "$body"
}

# render_server_compose NAME [CONFIG_HASH] -> stdout the compose YAML of servers/NAME. Needs MCCTL_DOMAIN (load_config). CONFIG_HASH is
# the value of the label mcctl.config_hash (empty for config_hash itself). Exit status: 1 no server.env, 2 bad NAME, 3 a value or
# file that is not valid (every problem is reported), 4 refused (a control character in a value or a list entry, or a credential
# written as a plain environment value).
render_server_compose() {
    local name=${1-} chash=${2-} dir lines mlines line k v mb rc=0 extra="" benv_block="" version_line="" cf=0 cf_file=0 mc_secret="" top_secret="" restart=unless-stopped
    local lf b lblock=""
    local -A se=() tv=() used=([EULA]=1 [TYPE]=1 [VERSION]=1 [MEMORY]=1 [RCON_PASSWORD_FILE]=1)
    dir=$(server_dir "$name") || return
    [[ -n ${MCCTL_DOMAIN:-} ]] || { err "MCCTL_DOMAIN is not set: the router label needs it (see config/mcctl.env.example)"; return "$EX_PREFLIGHT"; }
    [[ -f $dir/server.env ]] || { err "no $dir/server.env"; return 1; }

    lines=$(kv_lines "$dir/server.env") || return "$EX_PREFLIGHT"
    while IFS= read -r line; do [[ -z $line ]] || se[${line%%=*}]=${line#*=}; done <<<"$lines"
    # JAVA picks the image's Java major version (itzg/minecraft-server:javaN); empty is the image default. Forge 1.20.1 needs 17.
    case ${se[JAVA]-} in
        ''|17|21|25) ;;
        *) err "server.env: JAVA is ${se[JAVA]@Q}, expected 17, 21, 25 or nothing (mcctl java NAME set 17)"; return "$EX_PREFLIGHT" ;;
    esac
    local image=itzg/minecraft-server
    [[ -z ${se[JAVA]-} ]] || image+=":java${se[JAVA]}"
    local srv_type=${se[TYPE]:-VANILLA} version=${se[VERSION]:-} mem=${se[MEMORY]:-2G} cpus=${se[CPUS]:-2}
    local host=${se[HOSTNAME_SLUG]:-$name} eula=${se[EULA]:-FALSE} benv=${se[BACKUP_ENV_FILE]:-}

    check_server_values "$srv_type" "$version" "$mem" "$cpus" "$eula" "$host" "$benv" || rc=$?
    case ${se[AUTOSTART]:-on} in
        on) ;;
        off) restart='"no"' ;;
        *) err "server.env: AUTOSTART is ${se[AUTOSTART]@Q}, expected on or off"; rc=$EX_PREFLIGHT ;;
    esac
    [[ $srv_type != AUTO_CURSEFORGE ]] || cf=1

    # the lists (lib/mods.sh): a list file that exists owns its key, so server.env and modpack.env may not set that key as well
    for k in MODS PLUGINS MODRINTH_PROJECTS; do
        lf=$(list_file "$name" "$k") || return
        [[ -e $lf ]] || continue
        used[$k]=1
        b=$(_list_block "$k" "$lf") || return "$EX_REFUSED"
        lblock+=${lblock:+$'\n'}$b
    done

    # the environment entries of the game container, in this order: every server.env key that is not structural (sorted by key),
    # then the modpack.env lines (file order). A credential must be a *_FILE reference.
    lines=""
    while IFS= read -r k; do
        [[ -n $k && $SE_STRUCTURAL != *" $k "* ]] || continue
        lines+="$k=${se[$k]}"$'\n'
    done < <(printf '%s\n' "${!se[@]}" | LC_ALL=C sort)
    if [[ -f $dir/modpack.env ]]; then
        mlines=$(kv_lines "$dir/modpack.env") || return "$EX_PREFLIGHT"
        lines+=$mlines$'\n'
    fi
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        k=${line%%=*} v=${line#*=}
        [[ $k != CF_API_KEY_FILE ]] || cf_file=1
        if [[ $v == AUTO_CURSEFORGE && ( $k == MOD_PLATFORM || $k == MODPACK_PLATFORM ) ]]; then cf=1; fi
        if _is_credential "$k"; then
            err "$k looks like a credential; a credential is never a plain value. Put it in a file under secrets/ and set ${k}_FILE"
            return "$EX_REFUSED"
        fi
        [[ -z ${used[$k]:-} ]] || { err "$k is set twice (server.env, modpack.env) or is already set by mcctl"; rc=$EX_PREFLIGHT; continue; }
        used[$k]=1
        v=$(compose_escape "$v") || return "$EX_REFUSED"
        extra+=${extra:+$'\n'}"      $k: \"$v\""
    done <<<"$lines"
    if ((cf)); then
        ((cf_file == 0)) || { err "modpack.env: CF_API_KEY_FILE is set by mcctl on a CurseForge server (it points at secrets/$CF_KEY_SECRET); remove it"; rc=$EX_PREFLIGHT; }
        extra+=${extra:+$'\n'}'      CF_API_KEY_FILE: "/run/secrets/cf_api_key"'
        mc_secret='      - cf_api_key'
        top_secret=$'  cf_api_key:\n'"    file: \"../../secrets/$CF_KEY_SECRET\""
    fi
    ((rc == 0)) || return "$rc"

    mb=${mem%[MmGg]}
    [[ $mem == *[Gg] ]] && mb=$((mb * 1024))
    # no VERSION line without a VERSION: the image then picks LATEST, or the version a modpack asks for
    [[ -z $version ]] || version_line="      VERSION: \"$(compose_escape "$version")\"" || return "$EX_REFUSED"
    if [[ -n $benv ]]; then
        local benv_file="$dir/$benv" benv_lines benv_k benv_v
        local -A used_benv=([RCON_HOST]=1 [RCON_PASSWORD_FILE]=1 [SRC_DIR]=1 [DEST_DIR]=1 [BACKUP_NAME]=1)
        if [[ -f $benv_file ]]; then
            benv_lines=$(kv_lines "$benv_file") || return "$EX_PREFLIGHT"
            while IFS= read -r line; do
                [[ -n $line ]] || continue
                benv_k=${line%%=*} benv_v=${line#*=}
                if [[ $benv_k =~ (PASSWORD|PASSWD|SECRET|TOKEN|_KEY)$ ]]; then
                    err "backup.env: $benv_k looks like a credential; a credential is never a plain value. Put it in a file under secrets/ and set ${benv_k}_FILE"
                    return "$EX_REFUSED"
                fi
                [[ -z ${used_benv[$benv_k]:-} ]] || { err "backup.env: $benv_k is set twice or is already set by mcctl"; rc=$EX_PREFLIGHT; continue; }
                used_benv[$benv_k]=1
                benv_v=$(compose_escape "$benv_v") || return "$EX_REFUSED"
                benv_block+=${benv_block:+$'\n'}"      $benv_k: \"$benv_v\""
            done <<<"$benv_lines"
        fi
    fi
    ((rc == 0)) || return "$rc"
    # mem_limit leaves room above the JVM heap (MEMORY) for metaspace, threads and the OS: heap + 25% + 256 MiB
    tv=([NAME]="$name" [CONTAINER]="mc-$name" [HOST]="$host" [DOMAIN]="$MCCTL_DOMAIN" [TYPE]="$srv_type" [IMAGE]="$image"
        [VERSION_ENV]="$version_line" [MEMORY]="$mem" [EULA]="$eula" [CPUS]="$cpus" [MEM_LIMIT]="$((mb + mb / 4 + 256))m" [EXTRA_ENV]="$extra" [BACKUP_ENV]="$benv_block"
        [LIST_ENV]="$lblock" [MC_SECRET]="$mc_secret" [TOP_SECRET]="$top_secret" [RESTART]="$restart" [CONFIG_HASH]="$chash")
    # every scalar is escaped; the blocks (EXTRA_ENV, VERSION_ENV, BACKUP_ENV, LIST_ENV, MC_SECRET, TOP_SECRET) were escaped or are fixed text
    for k in NAME CONTAINER HOST DOMAIN TYPE MEMORY EULA; do
        tv[$k]=$(compose_escape "${tv[$k]}") || return "$EX_REFUSED"
    done
    _fill_template "$COMPOSE_TMPL" tv || return 1
}

# config_hash NAME -> stdout the sha256 (64 hex) of the compose text NAME renders with its label left empty and without the one-shot
# keys (*_FORCE_REINSTALL, FORCE_REDOWNLOAD, REMOVE_OLD_MODS: they are acted on once, so they do not make a config pending). The
# label mcctl.config_hash that write_compose sets is this value, so it never feeds its own hash.
config_hash() {
    local text
    text=$(render_server_compose "${1-}" "") || return
    printf '%s\n' "$text" | grep -v -E '^      ([A-Z][A-Z0-9_]*_FORCE_REINSTALL|FORCE_REDOWNLOAD|REMOVE_OLD_MODS): ' | sha256sum | cut -c1-64
}

# write_compose NAME: render servers/NAME/compose.yaml from server.env and modpack.env, atomically (write_atomic), with the label
# mcctl.config_hash set to config_hash NAME. When the render fails the old compose.yaml, if any, stays as it was.
write_compose() {
    local dir hash
    dir=$(server_dir "${1-}") || return
    hash=$(config_hash "$1") || return
    write_atomic "$dir/compose.yaml" render_server_compose "$1" "$hash"
}

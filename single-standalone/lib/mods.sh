#!/usr/bin/env bash
# shellcheck shell=bash
# Mods, plugins and Modrinth projects: `mcctl mods|plugins|modrinth NAME VERB`. Sourced by ./mcctl, never executed.
#
# The lists are the truth: servers/NAME/lists/{mods,plugins,modrinth_projects}.list, one entry per line. compose.yaml renders each one
# that exists into the itzg variable MODS, PLUGINS or MODRINTH_PROJECTS (lib/compose.sh), and itzg installs what is listed at every
# start. A change takes effect when the containers are recreated: `sync` does that (apply_pending). A local jar is not in a list: it
# is copied to the attach point servers/NAME/mods or plugins, which the compose file mounts read-only at /mods or /plugins.

MOD_LOADER_TYPES=" FORGE NEOFORGE FABRIC QUILT "
PLUGIN_TYPES=" PAPER SPIGOT BUKKIT PURPUR PUFFERFISH LEAF FOLIA "
JAR_MAX_BYTES=209715200
MODRINTH_RE='^[a-z0-9_-]{1,64}(:[A-Za-z0-9._-]{1,64})?$'

# valid_mod_entry ENTRY: 0 when ENTRY is an https:// URL or a container path under /mods/ or /plugins/, else 1. At most 500 characters,
# no whitespace, control character, quote, backtick, '$' or backslash. A URL has no '@' in its host part (a credential would be a plain
# value in compose.yaml), and a container path has no '..' component.
valid_mod_entry() {
    local e=${1-} LC_ALL=C auth
    ((${#e} >= 1 && ${#e} <= 500)) || return 1
    [[ $e =~ ^[[:graph:]]+$ && $e != *[\"\'\`\$\\]* ]] || return 1
    case $e in
        https://*) auth=${e#https://}; auth=${auth%%/*}; [[ -n $auth && $auth != *@* ]] ;;
        /mods/?*|/plugins/?*) [[ /$e/ != */../* ]] ;;
        *) return 1 ;;
    esac
}

# valid_modrinth_entry ENTRY: 0 when ENTRY is a Modrinth project slug, with an optional :VERSION (fabric-api, lithium:mc1.21-0.13.0)
valid_modrinth_entry() { local LC_ALL=C; [[ ${1-} =~ $MODRINTH_RE ]]; }

# _jar_name_ok NAME: 0 when NAME can name a local file of an attach point: a letter or digit first, no '/' and no control character
_jar_name_ok() { local LC_ALL=C; [[ ${1-} =~ ^[A-Za-z0-9][^/[:cntrl:]]*$ ]]; }

# _jar_check FILE: 0 when FILE can be added as a jar: a usable name, the zip signature PK at its start, at most 200 MB. A sanity check,
# not a scan. Else a message and 1.
_jar_check() {
    local f=$1 size
    _jar_name_ok "${f##*/}" || { err "${f@Q}: the file name must start with a letter or digit and hold no '/' or control character"; return 1; }
    size=$(stat -c %s -- "$f") || return 1
    ((size <= JAR_MAX_BYTES)) || { err "${f@Q} is $size bytes: a jar of more than 200 MB is refused"; return 1; }
    [[ $(head -c 2 -- "$f" | od -An -tx1 | tr -d ' \n') == 504b ]] || { err "${f@Q} does not start with the zip signature PK: it is not a jar"; return 1; }
}

# _attach_put NAME ATTACH SRC: copy the checked jar SRC into servers/NAME/ATTACH atomically, mode 644 (the game's user reads it through
# the read-only mount; the umask would make it 600)
_attach_put() {
    local dir base
    dir=$(attach_dir "$1" "$2") || return
    base=${3##*/}
    write_atomic "$dir/$base" cat -- "$3" && chmod 644 -- "$dir/$base"
}

# _list_has FILE ENTRY: 0 when FILE has a line equal to ENTRY
_list_has() { [[ -e $1 ]] && grep -qxF -- "$2" "$1"; }

# _list_write FILE CMD ARGS...: write_atomic into FILE, making its lists/ folder first
_list_write() { mkdir -p -- "$(dirname -- "$1")" && write_atomic "$@"; }

# _list_append FILE ENTRY: the lines of FILE, then ENTRY (the CMD form of write_atomic)
_list_append() {
    local line
    if [[ -e $1 ]]; then while IFS= read -r line || [[ -n $line ]]; do printf '%s\n' "$line"; done <"$1"; fi
    printf '%s\n' "$2"
}

# _list_drop FILE ENTRY: the lines of FILE without the line ENTRY (the CMD form of write_atomic). grep exits 1 when nothing is left;
# that is an empty list, not a failure.
_list_drop() { grep -vxF -- "$2" "$1" || [[ $? == 1 ]]; }

# _type_guard NAME KIND FORCE: a mod on a plugin server (PAPER, ...) or a plugin on a mod loader (FORGE, ...) is refused unless FORCE is 1.
# A server.env without TYPE is VANILLA, the renderer's default.
_type_guard() {
    local t bad=""
    t=$(server_env_get "$1" TYPE) || [[ $? == 1 ]] || die "server.env of $1 is not valid (see above): nothing was changed" "$EX_PREFLIGHT"
    t=${t:-VANILLA}
    case $2 in
        mods) [[ $PLUGIN_TYPES != *" $t "* ]] || bad="$t is a plugin server, which does not run mods" ;;
        plugins) [[ $MOD_LOADER_TYPES != *" $t "* ]] || bad="$t is a mod loader, which does not run plugins" ;;
    esac
    [[ -z $bad || $3 == 1 ]] || die "$bad (add --force to add it anyway)" "$EX_REFUSED"
}

# _list_show NAME KEY ATTACH: the declared list, then the local files of the attach point (ATTACH empty: none)
_list_show() {
    local lf dir f
    lf=$(list_file "$1" "$2") || return
    if [[ ! -e $lf ]]; then echo "(no $2 list: itzg does not manage it)"
    elif [[ ! -s $lf ]]; then echo "(empty list: the next sync removes what itzg installed from it)"
    else cat -- "$lf"; fi
    [[ -n $3 ]] || return 0
    dir=$(server_dir "$1") || return
    for f in "$dir/$3"/*; do [[ -f $f ]] && printf '%s  (local file, not in the list)\n' "${f##*/}"; done
    return 0
}

# _list_cmd KIND NAME VERB ARGS...: the verbs of mods, plugins and modrinth. Every change says whether the server must be synced.
_list_cmd() {
    local kind=$1 name=${2-} verb=${3-} key attach="" usage lf dir a restart=0 force=0 hybrid=0 bad=0 changed=0 want have
    local -a args=() jars=() ents=()
    case $kind in
        mods)     key=MODS attach=mods ;;
        plugins)  key=PLUGINS attach=plugins ;;
        modrinth) key=MODRINTH_PROJECTS ;;
    esac
    usage="usage: mcctl $kind NAME list | installed | add ENTRY... | remove ENTRY | clear [--remove-installed] | sync [--restart]"
    [[ $kind != modrinth ]] || usage="usage: mcctl modrinth NAME list | add PROJECT[:VERSION]... | remove PROJECT | clear | sync"
    (($# >= 3)) || die "$usage" "$EX_USAGE"
    shift 3
    _need_server "$name"
    lf=$(list_file "$name" "$key") || exit
    dir=$(server_dir "$name") || exit

    case $verb in
        list)
            (($# == 0)) || die "$usage" "$EX_USAGE"
            _list_show "$name" "$key" "$attach" ;;
        installed)
            [[ -n $attach && $# == 0 ]] || die "$usage" "$EX_USAGE"
            data_run "$name" ls -la -- "$attach" \
                || die "cannot list $attach/ in the data of $name (see above): it appears once the server has started" "$EX_FAIL" ;;
        add)
            for a in "$@"; do
                case $a in
                    --force) force=1 ;;
                    --hybrid) hybrid=1 ;;
                    *) args+=("$a") ;;
                esac
            done
            ((${#args[@]} > 0)) || die "$usage" "$EX_USAGE"
            ((hybrid == 0)) || [[ $kind == plugins ]] || die "--hybrid is for plugins: a server that runs plugins as well as mods" "$EX_USAGE"
            _type_guard "$name" "$kind" "$force"
            # validate everything first: nothing is written unless every argument is good
            for a in "${args[@]}"; do
                if [[ -d $a ]]; then
                    err "${a@Q} is a folder: name a jar file, an https:// URL or a container path"; bad=$EX_USAGE
                elif [[ $kind != modrinth && -f $a ]]; then
                    if _jar_check "$a"; then jars+=("$a"); else bad=$EX_REFUSED; fi
                elif [[ $kind == modrinth ]]; then
                    valid_modrinth_entry "$a" && ents+=("$a") \
                        || { err "${a@Q} is not a Modrinth project: a slug, or slug:version, of letters, digits, '.', '_' and '-'"; bad=$EX_USAGE; }
                else
                    valid_mod_entry "$a" && ents+=("$a") \
                        || { err "${a@Q} is not a file, an https:// URL (no credentials) or a container path under /mods/ or /plugins/ (no '..')"; bad=$EX_USAGE; }
                fi
            done
            ((bad == 0)) || { err "nothing was changed"; exit "$bad"; }
            for a in "${jars[@]}"; do
                _attach_put "$name" "$attach" "$a" || die "cannot copy ${a@Q} into $attach/ (see above)" "$EX_FAIL"
                info "copied ${a##*/} into $attach/: a local file, not in the list; it is used at the next start"
            done
            for a in "${ents[@]}"; do
                if _list_has "$lf" "$a"; then info "$a is already in the list"; continue; fi
                _list_write "$lf" _list_append "$lf" "$a" || die "cannot write $lf (see above)" "$EX_FAIL"
                changed=1
            done
            if ((hybrid)); then
                server_env_set "$name" USES_PLUGINS true || die "cannot write server.env of $name (see above)" "$EX_FAIL"
                changed=1
            fi
            ((changed == 0)) || info "config pending: mcctl mods $name sync" ;;
        remove)
            (($# == 1)) || die "$usage" "$EX_USAGE"
            a=$1
            if _list_has "$lf" "$a"; then
                _list_write "$lf" _list_drop "$lf" "$a" || die "cannot write $lf (see above)" "$EX_FAIL"
                info "removed $a: config pending: mcctl mods $name sync"
                # an empty list renders KEY: "", which the image reads as "remove what you installed from it"
                [[ -s $lf ]] || warn "the $key list of $name is empty now: at the next sync the image removes what it installed from it"
            elif [[ -n $attach ]] && _jar_name_ok "$a" && [[ -f $dir/$attach/$a ]]; then
                rm -f -- "$dir/$attach/$a" || die "cannot remove $dir/$attach/$a" "$EX_FAIL"
                info "removed the local file $a from $attach/. A copy in data/$attach stays until you remove it there: mcctl files $name rm $attach/$a"
            else
                die "$a is not in the list${attach:+ or a local file in $attach/}" "$EX_FAIL"
            fi ;;
        clear)
            if [[ ${1-} == --remove-installed ]]; then
                (($# == 1)) || die "$usage" "$EX_USAGE"
                confirm "Empty the $key list of $name? At its next start itzg removes every file it installed from that list. (Unverified against the real image: see docs.)" \
                    || die "the $key list of $name was not changed" "$EX_REFUSED"
                _list_write "$lf" true || die "cannot write $lf (see above)" "$EX_FAIL"
                info "emptied the $key list of $name: config pending: mcctl mods $name sync"
            else
                (($# == 0)) || die "$usage" "$EX_USAGE"
                rm -f -- "$lf"
                info "removed the $key list of $name: itzg stops managing it, the files it installed stay. config pending: mcctl mods $name sync"
            fi ;;
        sync)
            [[ $# == 0 || ( $# == 1 && $1 == --restart ) ]] || die "$usage" "$EX_USAGE"
            [[ ${1-} != --restart ]] || restart=1
            # the compose file mounts both attach points: make them now, since Docker would make a missing one root-owned (a server
            # made before this task has none)
            attach_dir "$name" mods >/dev/null && attach_dir "$name" plugins >/dev/null \
                || die "cannot make the attach points of $name (see above): nothing was applied" "$EX_FAIL"
            want=$(config_hash "$name") || die "$name: server.env does not render (see above): nothing was applied" "$EX_PREFLIGHT"
            have=$(server_label "$name" mcctl.config_hash) || die "cannot inspect mc-$name (see above): nothing was applied"
            if ((restart)) && [[ $have == "$want" ]]; then
                _recreate_guard "$name"
                dc "$name" restart || die "docker compose restart failed for $name (see above)"
                info "$name: restarted (nothing was pending)"
            else
                apply_pending "$name"
            fi ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac
}

cmd_mods()     { _list_cmd mods "$@"; }
cmd_plugins()  { _list_cmd plugins "$@"; }
cmd_modrinth() { _list_cmd modrinth "$@"; }

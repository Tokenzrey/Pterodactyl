#!/usr/bin/env bash
# shellcheck shell=bash
# Modpack environment mapping. Sourced by ./mcctl, never executed.
#
# modpack_env is the ONE place that knows which itzg/minecraft-server variables select a CurseForge or Modrinth pack, so a
# change in the upstream names is one edit here. Names read from the itzg documentation on 2026-10-24:
#   CurseForge  .../types-and-platforms/mod-platforms/auto-curseforge/
#     MOD_PLATFORM=AUTO_CURSEFORGE, CF_SLUG (the slug in the pack's page URL), CF_FILE_ID (numeric file id; unset = latest file).
#     There is no variable for a numeric project id of a pack, so a number is refused (see below).
#     The API key is CF_API_KEY_FILE, a path to a file inside the container. It is not here: lib/compose.sh adds it, and mounts
#     secrets/curseforge_api_key there, for every CurseForge server. The key value never enters modpack.env or any argument.
#   Modrinth    .../types-and-platforms/mod-platforms/modrinth-modpacks/
#     MOD_PLATFORM=MODRINTH, MODRINTH_MODPACK (slug or project id), MODRINTH_VERSION (version id or number; unset = latest).

# modpack_env SOURCE ID [VERSION] -> stdout KEY=VALUE lines for servers/NAME/modpack.env, in file order.
# SOURCE is curseforge or modrinth; ID is the pack's slug (Modrinth: slug or project id); VERSION is empty (latest), a CurseForge
# file id (digits) or a Modrinth version. Every problem is reported on stderr and nothing is printed; exit 2 (EX_USAGE).
modpack_env() {
    local src=${1-} id=${2-} ver=${3-} rc=0 plat idvar verkey verre verhint
    local idre='^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'
    case $src in
        curseforge) plat=AUTO_CURSEFORGE idvar=CF_SLUG verkey=CF_FILE_ID verre='^[0-9]{1,12}$' verhint="a CurseForge file id (digits)" ;;
        modrinth)   plat=MODRINTH idvar=MODRINTH_MODPACK verkey=MODRINTH_VERSION verre='^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$' verhint="a Modrinth version id or number" ;;
        *) err "modpack source ${src@Q} is neither curseforge nor modrinth"; return "$EX_USAGE" ;;
    esac
    if [[ -z $id ]]; then
        err "the modpack id is empty: give the pack's slug (the last part of its page URL)"; rc=$EX_USAGE
    elif [[ ! $id =~ $idre ]]; then
        err "modpack id ${id@Q} must be the pack's slug or id: letters, digits, '.', '_' and '-' (no space, '=' or newline), at most 100 characters"; rc=$EX_USAGE
    elif [[ $src == curseforge && $id =~ ^[0-9]+$ ]]; then
        err "CurseForge pack ${id@Q} is a number: the image finds a pack by its slug (CF_SLUG, the last part of its page URL, e.g. all-the-mods-10), not by project id"; rc=$EX_USAGE
    fi
    [[ -z $ver || $ver =~ $verre ]] || { err "modpack version ${ver@Q} for $src must be $verhint"; rc=$EX_USAGE; }
    ((rc == 0)) || return "$rc"
    printf 'MOD_PLATFORM=%s\n%s=%s\n' "$plat" "$idvar" "$id"
    [[ -z $ver ]] || printf '%s=%s\n' "$verkey" "$ver"
}

# modpack_require_key: exit EX_PREFLIGHT, nothing touched, unless secrets/curseforge_api_key has a key in it, belongs to the game's user (the
# server container reads it as that user) and is readable by this one. create and modpack set ask it before a CurseForge pack is written.
# Only the owner and that the file has content are checked: the key is never read into a variable or printed. mcctl cannot chown this
# file itself (it is the operator's file, and this user has no root), so a wrong owner is reported with the command that fixes it.
modpack_require_key() {
    local key=$MCCTL_ROOT/secrets/$CF_KEY_SECRET uid owner
    uid=$(game_uid) || exit "$EX_PREFLIGHT"
    grep -q '[^[:space:]]' -- "$key" 2>/dev/null \
        || die "a CurseForge pack needs your CurseForge API key in the file $key (the key alone on one line, readable by this user; see 'mcctl create' in docs/reference.md). Nothing was changed." "$EX_PREFLIGHT"
    owner=$(stat -c %u -- "$key") || die "cannot read the owner of $key. Nothing was changed." "$EX_FAIL"
    [[ $owner == "$uid" ]] \
        || die "$key belongs to UID $owner, but the server reads it as UID $uid. As root, run: chown $uid:$(id -g) $key && chmod 640 $key (then run this again). Nothing was changed." "$EX_PREFLIGHT"
}

# ---- the modpack command -----------------------------------------------------------------------------------------------------
# cmd_modpack NAME info | set | update | remove. The pack's variables live in modpack.env, the platform in TYPE (AUTO_CURSEFORGE or
# MODRINTH). A change that can damage a world takes a snapshot first (_pre_snapshot), and the recreate is _recreate_apply.

cmd_modpack() {
    local usage="usage: mcctl modpack NAME info | set --source curseforge|modrinth --pack ID [--version V] | update [--latest | --version V] [--clean [--timeout SECONDS]] | remove --type TYPE [--version V] [--loader-version V] [--purge-mods]"
    (($# >= 2)) || die "$usage" "$EX_USAGE"
    local name=$1 act=$2
    shift 2
    _need_server "$name"
    case $act in
        info) (($# == 0)) || die "$usage" "$EX_USAGE"; _mp_info "$name" ;;
        set) _mp_set "$name" "$@" ;;
        update) _mp_update "$name" "$@" ;;
        remove) _mp_remove "$name" "$@" ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac
}

# _mp_render NAME OLD_ENV OLD_MP: write_compose after server.env and modpack.env were changed. When the render fails both files are put
# back as OLD_ENV and OLD_MP (their text before the change) and the command dies, so nothing is recreated.
_mp_render() {
    local name=$1 dir
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    write_compose "$name" && return 0
    printf '%s' "$2" | write_atomic "$dir/server.env" || err "server.env could not be put back: check it by hand"
    printf '%s' "$3" | write_atomic "$dir/modpack.env" || err "modpack.env could not be put back: check it by hand"
    die "cannot render $dir/compose.yaml (see above); server.env and modpack.env were put back as they were" "$EX_FAIL"
}

# _mp_info NAME: the source, the pack and the version mcctl knows from modpack.env; then the pack's name and version as the running
# container exposes them (printenv MODPACK_NAME MODPACK_VERSION), or unknown. The itzg names are placeholders for other values, so
# they may not be in the environment at all.
_mp_info() {
    local name=$1 dir t src id pin c out
    local -A srv=() mp=()
    local -a got=()
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    kv_read "$dir/server.env" srv
    t=${srv[TYPE]:-VANILLA}
    if [[ " $MODPACK_TYPES " != *" $t "* ]]; then printf 'no modpack\n'; return 0; fi
    kv_read "$dir/modpack.env" mp
    if [[ $t == AUTO_CURSEFORGE ]]; then src=curseforge; id=${mp[CF_SLUG]:-}; pin=${mp[CF_FILE_ID]:-}
    else src=modrinth; id=${mp[MODRINTH_MODPACK]:-}; pin=${mp[MODRINTH_VERSION]:-}; fi
    printf 'source:  %s\npack:    %s\n' "$src" "$id"
    if [[ -n $pin ]]; then printf 'version: pinned %s\n' "$pin"; else printf 'version: latest\n'; fi
    c=$(container_name "$name") || exit "$EX_USAGE"
    if out=$(docker exec "$c" printenv MODPACK_NAME MODPACK_VERSION 2>/dev/null) && mapfile -t got <<<"$out" && ((${#got[@]} == 2)); then
        printf 'resolved name: %s\nresolved version: %s\n' "${got[0]}" "${got[1]}"
    else
        printf 'resolved name/version: unknown\n'
    fi
}

# _mp_set NAME --source curseforge|modrinth --pack ID [--version V]: a new pack. The pack is checked first (modpack_env: exit 2; a CurseForge
# pack also needs the key file: exit 3). Then the server is checked (_recreate_guard), snapshotted, the change is confirmed, and written.
# The pack decides the version, so a VERSION in server.env is removed.
_mp_set() {
    local name=$1 src="" pack="" ver="" mpenv want dir old_env old_mp
    local -A srv=()
    shift
    while (($#)); do
        (($# >= 2)) && [[ $1 == --source || $1 == --pack || $1 == --version ]] \
            || die "unknown option or missing value ${1@Q}. usage: mcctl modpack NAME set --source curseforge|modrinth --pack ID [--version V]" "$EX_USAGE"
        case $1 in
            --source) src=$2 ;;
            --pack) pack=$2 ;;
            --version) ver=$2 ;;
        esac
        shift 2
    done
    mpenv=$(modpack_env "$src" "$pack" "$ver") || exit "$EX_USAGE"
    if [[ $src == curseforge ]]; then want=AUTO_CURSEFORGE; modpack_require_key; else want=MODRINTH; fi
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    kv_read "$dir/server.env" srv
    _recreate_guard "$name"
    _pre_snapshot "$name" modpack-set
    confirm "Switch $name to the $src pack $pack? The pack then decides its mods and version; the containers are recreated." \
        || die "$name was not changed (its snapshot is in safety/)" "$EX_REFUSED"
    old_env=$(cat "$dir/server.env"; printf X); old_env=${old_env%X}
    old_mp=$(cat "$dir/modpack.env" 2>/dev/null; printf X); old_mp=${old_mp%X}
    printf '%s\n' "$mpenv" | write_atomic "$dir/modpack.env" || die "cannot write $dir/modpack.env (see above)" "$EX_FAIL"
    server_env_set "$name" TYPE "$want" || die "cannot write $dir/server.env (see above)" "$EX_FAIL"
    server_env_unset "$name" VERSION || die "cannot write $dir/server.env (see above)" "$EX_FAIL"
    _mp_render "$name" "$old_env" "$old_mp"
    _recreate_apply "$name"
}

# _mp_update NAME [--latest | --version V] [--clean]: the pack's version. A pinned pack (CF_FILE_ID or MODRINTH_VERSION) is refused unless
# --version V (a new pin) or --latest (no pin) says what to do. --clean sets REMOVE_OLD_MODS for one apply, after a snapshot: itzg then
# deletes the mods/ folder before it installs the pack. The containers are recreated with it, waited for (healthy, or --timeout seconds,
# default 600) and recreated again without it (_flag_recreate). A stopped server is refused for --clean (exit 4, nothing changed).
_mp_update() {
    local name=$1 latest=0 ver="" have_ver=0 clean=0 timeout=600 have_timeout=0 dir t src id pin pinkey old_env old_mp
    local -A srv=() mp=()
    local usage="usage: mcctl modpack NAME update [--latest | --version V] [--clean [--timeout SECONDS]]"
    shift
    while (($#)); do
        case $1 in
            --latest) latest=1 ;;
            --clean) clean=1 ;;
            --version) (($# >= 2)) || die "--version needs a value. $usage" "$EX_USAGE"; ver=$2; have_ver=1; shift ;;
            --timeout) (($# >= 2)) || die "--timeout needs a value. $usage" "$EX_USAGE"; timeout=$2; have_timeout=1; shift ;;
            *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
        esac
        shift
    done
    if ((latest && have_ver)); then die "give --latest or --version V, not both. $usage" "$EX_USAGE"; fi
    if ((have_timeout && !clean)); then die "--timeout is for --clean (the wait after the recreate). $usage" "$EX_USAGE"; fi
    [[ $timeout =~ ^[0-9]{1,5}$ ]] || die "--timeout ${timeout@Q} is not a number of seconds. $usage" "$EX_USAGE"
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    kv_read "$dir/server.env" srv
    t=${srv[TYPE]:-VANILLA}
    if [[ " $MODPACK_TYPES " != *" $t "* ]]; then
        die "$name has no modpack: mcctl modpack $name set --source curseforge|modrinth --pack ID first" "$EX_FAIL"
    fi
    kv_read "$dir/modpack.env" mp
    if [[ $t == AUTO_CURSEFORGE ]]; then src=curseforge; id=${mp[CF_SLUG]:-}; pin=${mp[CF_FILE_ID]:-}; pinkey=CF_FILE_ID
    else src=modrinth; id=${mp[MODRINTH_MODPACK]:-}; pin=${mp[MODRINTH_VERSION]:-}; pinkey=MODRINTH_VERSION; fi
    if [[ -n $pin ]] && ((!latest && !have_ver)); then
        die "$name is pinned to $pin: say what to do with --version V (a new pin) or --latest (follow the latest pack)" "$EX_REFUSED"
    fi
    if ((have_ver)); then modpack_env "$src" "$id" "$ver" >/dev/null || exit "$EX_USAGE"; fi
    _recreate_guard "$name"
    if ((clean && !RECREATE_LIVE)); then
        die "$name is stopped: start it first (mcctl start $name). --clean recreates the containers, waits for the install and recreates them again without REMOVE_OLD_MODS, which needs a running server; nothing was changed" "$EX_REFUSED"
    fi
    old_env=$(cat "$dir/server.env"; printf X); old_env=${old_env%X}
    old_mp=$(cat "$dir/modpack.env"; printf X); old_mp=${old_mp%X}
    if ((clean)); then
        _pre_snapshot "$name" modpack-update
        warn "--clean sets REMOVE_OLD_MODS=TRUE for the recreate only. itzg's warning (docs/single-standalone/modpacks.md): \"All content of the mods or plugins directory will be deleted before unpacking new content from the MODPACK\". The snapshot is in safety/. Then the containers are recreated without it."
    fi
    if ((have_ver)); then
        write_atomic "$dir/modpack.env" _env_put_body "$dir/modpack.env" "$pinkey" "$ver" || die "cannot write $dir/modpack.env (see above)" "$EX_FAIL"
    elif ((latest)) && [[ -n $pin ]]; then
        write_atomic "$dir/modpack.env" sed -E '/^(CF_FILE_ID|MODRINTH_VERSION)=/d' "$dir/modpack.env" || die "cannot write $dir/modpack.env (see above)" "$EX_FAIL"
    fi
    if ((clean)); then
        _flag_recreate "$name" REMOVE_OLD_MODS "$timeout" "$old_env" "$old_mp"
    else
        _mp_render "$name" "$old_env" "$old_mp"
        _recreate_apply "$name"
    fi
}

# _mp_remove NAME --type TYPE [--version V] [--loader-version V] [--purge-mods]: the server stops being a modpack and runs TYPE, a plain type.
# modpack.env is emptied. The installed mods stay unless --purge-mods, which needs a stopped server. Without --version a server with no
# VERSION would run the image's LATEST, which can upgrade the world, so VERSION is then required.
_mp_remove() {
    local name=$1 type="" lv="" have_lv=0 ver="" have_ver=0 purge=0 lvar dir st old_env old_mp
    local -A srv=()
    local usage="usage: mcctl modpack NAME remove --type TYPE [--version V] [--loader-version V] [--purge-mods]"
    shift
    while (($#)); do
        if [[ $1 == --purge-mods ]]; then purge=1; shift; continue; fi
        (($# >= 2)) && [[ $1 == --type || $1 == --version || $1 == --loader-version ]] || die "unknown option or missing value ${1@Q}. $usage" "$EX_USAGE"
        case $1 in
            --type) type=${2^^} ;;
            --version) ver=$2; have_ver=1 ;;
            *) lv=$2; have_lv=1 ;;
        esac
        shift 2
    done
    [[ -n $type ]] || die "--type is required: the plain type the server runs now, for example FORGE, FABRIC or PAPER. $usage" "$EX_USAGE"
    if [[ " $SERVER_TYPES " != *" $type "* ]]; then die "${type@Q} is not a plain server type (the types are $SERVER_TYPES)" "$EX_USAGE"; fi
    lvar=$(loader_var "$type")
    if ((have_lv)); then
        [[ -n $lvar ]] || die "$type has no loader-version variable (FORGE, NEOFORGE and FABRIC have one): nothing was changed" "$EX_USAGE"
        SE_CTX="mcctl modpack" _se_check "$lvar" "$lv" "$VERSION_RE" "a loader version such as 0.16.9" || exit "$EX_USAGE"
    fi
    if ((have_ver)); then SE_CTX="mcctl modpack" _se_check VERSION "$ver" "$VERSION_RE" "a version such as 1.21.1" || exit "$EX_USAGE"; fi
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    kv_read "$dir/server.env" srv
    if [[ " $MODPACK_TYPES " != *" ${srv[TYPE]:-VANILLA} "* ]]; then die "$name has no modpack: nothing to remove" "$EX_FAIL"; fi
    if ((!have_ver)) && [[ -z ${srv[VERSION]:-} ]]; then
        die "$name has no VERSION, so without --version V it would run the image's LATEST, and a newer version can upgrade the world (that cannot be undone): give --version V" "$EX_REFUSED"
    fi
    if ((purge)); then
        st=$(_server_state "$name") && [[ -n $st ]] || die "cannot read the state of $(container_name "$name") (docker inspect failed): nothing was changed" "$EX_FAIL"
        case $st in running|restarting|paused) die "$name is $st: stop it first (mcctl stop $name); --purge-mods changes the mods of a stopped server. Nothing was changed" "$EX_REFUSED" ;; esac
    fi
    _recreate_guard "$name"
    _pre_snapshot "$name" modpack-remove
    if ((purge)); then
        data_run "$name" sh -c '[ ! -d mods ] || find mods -mindepth 1 -maxdepth 1 -delete' \
            || die "could not remove the mods (see above): $name is unchanged; its snapshot is in safety/" "$EX_FAIL"
    fi
    old_env=$(cat "$dir/server.env"; printf X); old_env=${old_env%X}
    old_mp=$(cat "$dir/modpack.env" 2>/dev/null; printf X); old_mp=${old_mp%X}
    printf '' | write_atomic "$dir/modpack.env" || die "cannot write $dir/modpack.env (see above)" "$EX_FAIL"
    _set_type "$name" "$type" "$lv" || die "cannot write $dir/server.env (see above)" "$EX_FAIL"
    if ((have_ver)); then server_env_set "$name" VERSION "$ver" || die "cannot write $dir/server.env (see above)" "$EX_FAIL"; fi
    _mp_render "$name" "$old_env" "$old_mp"
    _recreate_apply "$name"
}

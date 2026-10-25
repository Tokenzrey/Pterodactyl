#!/usr/bin/env bash
# shellcheck shell=bash
# The version, loader type, upgrade and reinstall of a server: cmd_version, cmd_upgrade, cmd_type, cmd_reinstall. Sourced by
# ./mcctl, never executed.
#
# Each command changes what the containers run, then recreates them. A change that can damage a world takes a verified snapshot
# first (_pre_snapshot, into safety/, which backup prune does not read), and every refusal before the write changes nothing. The
# recreate does not go through apply_pending: a one-shot key is not part of the config hash (lib/compose.sh), so a change of one
# never makes the config pending. These commands call _recreate_guard and _recreate_apply themselves.
# `mcctl version NAME ...` reaches cmd_version (mcctl's dispatcher matches --version only for the version print).

# The server types of docs/single-standalone/server-types.md. The modpack platforms are set only by `mcctl modpack`.
SERVER_TYPES="VANILLA FORGE NEOFORGE FABRIC QUILT PAPER PUFFERFISH PURPUR LEAF FOLIA SPIGOT BUKKIT"
MODPACK_TYPES="AUTO_CURSEFORGE MODRINTH"
# Every loader-version variable; type set and modpack remove drop the ones that belong to another type
LOADER_VARS=(FORGE_VERSION NEOFORGE_VERSION FABRIC_LOADER_VERSION)
# A VERSION: a version such as 1.21.1, LATEST or SNAPSHOT (the rule of check_server_values)
VERSION_RE='^[A-Za-z0-9][A-Za-z0-9._+-]*$'

# ---- pure functions ----------------------------------------------------------------------------------------------------------

# version_cmp A B: 0 when A and B are the same version, 1 when A is newer, 2 when A is older, 3 when they cannot be compared (LATEST,
# SNAPSHOT, a snapshot such as 24w14a, a pre-release such as 1.21-pre1, nothing). Trailing zero components are dropped first (1.20 is
# 1.20.0), because sort -V puts 1.20 before 1.20.0.
version_cmp() {
    local a=${1-} b=${2-} re='^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))*$' zero='\.0+$' first
    while [[ $a =~ $zero ]]; do a=${a%.0*}; done
    while [[ $b =~ $zero ]]; do b=${b%.0*}; done
    [[ $a =~ $re && $b =~ $re ]] || return 3
    [[ $a == "$b" ]] && return 0
    first=$(printf '%s\n%s\n' "$a" "$b" | LC_ALL=C sort -V | head -n 1)
    [[ $first == "$a" ]] && return 2
    return 1
}

# loader_var TYPE -> stdout the itzg variable that holds the loader version of TYPE (nothing for a type without one)
loader_var() {
    case ${1-} in
        FORGE) echo FORGE_VERSION ;;
        NEOFORGE) echo NEOFORGE_VERSION ;;
        FABRIC) echo FABRIC_LOADER_VERSION ;;
    esac
}

# reinstall_flag TYPE -> stdout the one-shot variable that makes the installer of TYPE run again (nothing when there is none)
reinstall_flag() {
    case ${1-} in
        FORGE) echo FORGE_FORCE_REINSTALL ;;
        FABRIC) echo FABRIC_FORCE_REINSTALL ;;
        PURPUR|PUFFERFISH) echo FORCE_REDOWNLOAD ;;
    esac
}

# type_folder TYPE -> stdout the folder under data/ that holds TYPE's jars: mods for a mod loader, plugins for a plugin type (nothing for
# VANILLA and the modpack platforms)
type_folder() {
    case ${1-} in
        FORGE|NEOFORGE|FABRIC|QUILT) echo mods ;;
        PAPER|PUFFERFISH|PURPUR|LEAF|FOLIA|SPIGOT|BUKKIT) echo plugins ;;
    esac
}

# ---- helpers -----------------------------------------------------------------------------------------------------------------

# _pre_snapshot NAME VERB: a verified snapshot of all of data/ into safety/pre-VERB-<UTC>.tar.gz, before a change. snapshot_members quiesces
# a running server and reads a stopped one. Dies, nothing changed, when it fails. It is in safety/, not backups/: `mcctl backup NAME
# prune` counts every archive in backups/ and would delete the oldest one, this one included.
_pre_snapshot() {
    local name=$1 verb=$2 dir base out n=1
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    mkdir_private "$dir/safety" || die "cannot create $dir/safety: nothing was changed" "$EX_FAIL"
    base=$dir/safety/pre-$verb-$(date -u +%Y%m%dT%H%M%SZ); out=$base.tar.gz
    while [[ -e $out || -L $out ]]; do n=$((n + 1)); out=$base-$n.tar.gz; done
    snapshot_members "$name" "$out" . || die "the snapshot $out failed (see above): nothing was changed" "$EX_FAIL"
    info "$name: snapshot $out"
}

# _version_guard CURRENT NEW ALLOW: may VERSION go from CURRENT to NEW? A downgrade (version_cmp 2) is refused unless ALLOW is 1: a
# world saved by a newer version can be damaged by an older one. A change that cannot be compared (3) asks confirm. Dies when refused.
_version_guard() {
    local cur=$1 new=$2 allow=$3 cmp=0
    version_cmp "$new" "$cur" || cmp=$?
    case $cmp in
        2) ((allow)) || die "refused: $new is older than ${cur:-the current version}. A world saved by a newer version can be damaged by an older one; pass --allow-downgrade to change it anyway" "$EX_REFUSED" ;;
        3) confirm "Set the version to $new? ${cur:-(not set, so LATEST)} cannot be compared with it (LATEST, a snapshot or a pre-release), so mcctl cannot tell whether it is a downgrade." \
            || die "nothing was changed" "$EX_REFUSED" ;;
    esac
}

# _jar_count NAME FOLDER -> stdout the number of *.jar files directly in data/FOLDER (0 when there is no such folder). Fails, with the
# reason already printed, when the helper container cannot run.
_jar_count() {
    local n
    n=$(data_run "$1" sh -c '[ -d "$1" ] || { echo 0; exit 0; }; find "$1" -maxdepth 1 -name "*.jar" -type f | wc -l' sh "$2") || return 1
    n=${n//[[:space:]]/}
    [[ $n =~ ^[0-9]+$ ]] || { err "could not count the jars in $2/ (the helper printed ${n@Q})"; return 1; }
    printf '%s\n' "$n"
}

# _set_type NAME TYPE LOADER_VERSION: TYPE into server.env, the loader variables of the other types removed, and LOADER_VERSION (when not
# empty; the caller has checked that TYPE has one) in the variable of TYPE. Nothing is rendered or recreated: the caller does that.
_set_type() {
    local name=$1 type=$2 lv=$3 own v
    own=$(loader_var "$type")
    server_env_set "$name" TYPE "$type" || return
    for v in "${LOADER_VARS[@]}"; do
        [[ $v == "$own" ]] || server_env_unset "$name" "$v" || return
    done
    [[ -z $lv ]] || server_env_set "$name" "$own" "$lv"
}

# _reinstall_wait NAME SECONDS: 0 once the game container reports healthy, 1 when SECONDS pass first (the health is read once a second)
_reinstall_wait() {
    local name=$1 deadline h c
    deadline=$((SECONDS + $2))
    c=$(container_name "$name") || return 1
    while :; do
        h=$(docker inspect --format '{{.State.Health.Status}}' "$c" 2>/dev/null)
        [[ $h == healthy ]] && return 0
        ((SECONDS < deadline)) || return 1
        sleep 1
    done
}

# _flag_recreate NAME KEY SECONDS OLD_ENV OLD_MP: a one-shot KEY=TRUE (reinstall, modpack update --clean) runs once and must not stay in the
# container's environment (REMOVE_OLD_MODS would delete mods/ at every restart). Steps: KEY into server.env, the containers recreated
# with it (_recreate_apply in a subshell, so its failure is a status and the steps go on); when SECONDS is not empty and that worked, the
# game container is waited for until healthy (_reinstall_wait; a timeout is a failure); then KEY is removed from server.env and
# compose.yaml and the containers are recreated once more, whatever happened above. Returns the first failure, else the second
# recreate's status. OLD_ENV and OLD_MP are the texts before the change, put back when a render fails (_mp_render). The caller has
# checked that the server runs (RECREATE_LIVE): a stopped container cannot finish an install.
_flag_recreate() {
    local name=$1 key=$2 secs=$3 dir rc=0 rc2=0
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    server_env_set "$name" "$key" TRUE || die "cannot write $dir/server.env (see above): nothing was recreated" "$EX_FAIL"
    _mp_render "$name" "$4" "$5"
    (_recreate_apply "$name") || rc=$?
    if ((rc == 0)) && [[ -n $secs ]]; then
        _reinstall_wait "$name" "$secs" \
            || { rc=$EX_FAIL; err "$name is not healthy after $secs s (the install may still run: mcctl logs $name)"; }
    fi
    server_env_unset "$name" "$key" || die "cannot write $dir/server.env: remove $key from it by hand; the container still has it" "$EX_FAIL"
    write_compose "$name" || die "cannot render $dir/compose.yaml without $key (see above): check it by hand; the container still has $key" "$EX_FAIL"
    (_recreate_apply "$name") || rc2=$?
    ((rc == 0)) || return "$rc"
    return "$rc2"
}

# ---- commands ----------------------------------------------------------------------------------------------------------------

# cmd_version NAME show | set V [--allow-downgrade]: the VERSION of a server, or a new one. A modpack server is refused (its pack decides
# the version). A downgrade needs --allow-downgrade; a change that cannot be compared asks confirm (_version_guard).
cmd_version() {
    local usage="usage: mcctl version NAME show | set V [--allow-downgrade]"
    (($# >= 2)) || die "$usage" "$EX_USAGE"
    local name=$1 act=$2 v allow=0 dir old type
    local -A srv=()
    shift 2
    _need_server "$name"
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    kv_read "$dir/server.env" srv
    type=${srv[TYPE]:-VANILLA}
    case $act in
        show)
            (($# == 0)) || die "$usage" "$EX_USAGE"
            printf 'VERSION: %s\nTYPE: %s\n' "${srv[VERSION]:-(not set: the image uses LATEST)}" "$type" ;;
        set)
            (($# >= 1)) && [[ $1 != --* ]] || die "$usage" "$EX_USAGE"
            v=$1
            shift
            while (($#)); do
                [[ $1 == --allow-downgrade ]] || die "unknown option ${1@Q}. $usage" "$EX_USAGE"
                allow=1
                shift
            done
            if [[ " $MODPACK_TYPES " == *" $type "* ]]; then
                die "$name runs a modpack, and the modpack decides the version: mcctl modpack $name update" "$EX_REFUSED"
            fi
            SE_CTX="mcctl version" _se_check VERSION "$v" "$VERSION_RE" "a version such as 1.21.1, LATEST or SNAPSHOT" || exit "$EX_USAGE"
            _version_guard "${srv[VERSION]:-}" "$v" "$allow"
            _recreate_guard "$name"
            _pre_snapshot "$name" version
            old=$(cat "$dir/server.env"; printf X); old=${old%X}
            server_env_set "$name" VERSION "$v" || die "cannot write $dir/server.env (see above)" "$EX_FAIL"
            _env_write_compose "$name" "$old"
            _recreate_apply "$name" ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac
}

# cmd_upgrade NAME [--to V] [--allow-downgrade]: a snapshot, the newest itzg image (docker compose pull) and a recreate. --to V pins
# VERSION first (the same downgrade rule as version set). The Minecraft version of VERSION=LATEST is resolved again at every start.
cmd_upgrade() {
    local usage="usage: mcctl upgrade NAME [--to V] [--allow-downgrade]"
    (($# >= 1)) && [[ $1 != --* ]] || die "NAME is missing (it comes right after upgrade). $usage" "$EX_USAGE"
    local name=$1 to="" allow=0 dir old
    local -A srv=()
    shift
    while (($#)); do
        case $1 in
            --to) (($# >= 2)) || die "--to needs a value. $usage" "$EX_USAGE"; to=$2; shift ;;
            --allow-downgrade) allow=1 ;;
            *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
        esac
        shift
    done
    _need_server "$name"
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    kv_read "$dir/server.env" srv
    if [[ " $MODPACK_TYPES " == *" ${srv[TYPE]:-VANILLA} "* ]]; then
        die "$name runs a modpack, and the modpack decides the version: mcctl modpack $name update" "$EX_REFUSED"
    fi
    if [[ -n $to ]]; then
        SE_CTX="mcctl upgrade" _se_check VERSION "$to" "$VERSION_RE" "a version such as 1.21.4 or LATEST" || exit "$EX_USAGE"
        _version_guard "${srv[VERSION]:-}" "$to" "$allow"
    fi
    _recreate_guard "$name"
    _pre_snapshot "$name" upgrade
    dc "$name" pull || die "docker compose pull failed for $name (see above): nothing was changed; the snapshot is in safety/" "$EX_FAIL"
    old=$(cat "$dir/server.env"; printf X); old=${old%X}
    if [[ -n $to ]]; then server_env_set "$name" VERSION "$to" || die "cannot write $dir/server.env (see above)" "$EX_FAIL"; fi
    _env_write_compose "$name" "$old"
    _recreate_apply "$name"
    info "$name: image pulled; the version is resolved at start"
}

# cmd_type NAME set TYPE [--loader-version V]: the server type (a plain one; the modpack platforms are set by mcctl modpack). A switch away
# from a mod loader or a plugin type is refused while its folder holds jars, unless --yes; the jars are kept either way. The loader
# variables of the other types are removed, and V goes in the variable of TYPE.
cmd_type() {
    local usage="usage: mcctl type NAME set TYPE [--loader-version V]"
    (($# >= 3)) && [[ $1 != --* ]] || die "$usage" "$EX_USAGE"
    local name=$1 act=$2 new=${3^^} lv="" have_lv=0 lvar dir old old_env folder n
    local -A srv=()
    shift 3
    while (($#)); do
        [[ $1 == --loader-version ]] && (($# >= 2)) || die "unknown option or missing value ${1@Q}. $usage" "$EX_USAGE"
        lv=$2 have_lv=1
        shift 2
    done
    [[ $act == set ]] || die "$usage" "$EX_USAGE"
    if [[ " $MODPACK_TYPES " == *" $new "* ]]; then
        die "$new is a modpack platform: set it with mcctl modpack $name set (the pack decides the rest)" "$EX_REFUSED"
    fi
    [[ " $SERVER_TYPES " == *" $new "* ]] || die "unknown type ${new@Q}: the types are $SERVER_TYPES" "$EX_USAGE"
    lvar=$(loader_var "$new")
    if ((have_lv)); then
        [[ -n $lvar ]] || die "$new has no loader-version variable (FORGE, NEOFORGE and FABRIC have one): nothing was changed" "$EX_USAGE"
        SE_CTX="mcctl type" _se_check "$lvar" "$lv" "$VERSION_RE" "a loader version such as 0.16.9" || exit "$EX_USAGE"
    fi
    _need_server "$name"
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    kv_read "$dir/server.env" srv
    old=${srv[TYPE]:-VANILLA}
    if [[ " $MODPACK_TYPES " == *" $old "* ]]; then
        die "$name runs a modpack ($old): change it with mcctl modpack $name remove --type $new" "$EX_REFUSED"
    fi
    folder=$(type_folder "$old")
    if [[ -n $folder && $old != "$new" && ${MCCTL_YES:-0} != 1 ]]; then
        n=$(_jar_count "$name" "$folder") || exit "$EX_FAIL"
        ((n == 0)) || die "refused: $folder/ of $name holds $n jar(s) for $old, which $new does not load. Remove them, or pass --yes to switch anyway (the jars are kept)" "$EX_REFUSED"
    fi
    _recreate_guard "$name"
    _pre_snapshot "$name" type
    old_env=$(cat "$dir/server.env"; printf X); old_env=${old_env%X}
    _set_type "$name" "$new" "$lv" || die "cannot write $dir/server.env (see above)" "$EX_FAIL"
    _env_write_compose "$name" "$old_env"
    _recreate_apply "$name"
}

# cmd_reinstall NAME [--timeout SECONDS]: run a server's installer again (reinstall_flag) when it will not start right. The containers are
# recreated with the flag, waited for until healthy, then recreated without it (_flag_recreate; exit 1 on a timeout, and the flag is gone
# either way). No snapshot: the installer does not touch the world. A stopped server is refused (exit 4, nothing changed): start it first.
cmd_reinstall() {
    local usage="usage: mcctl reinstall NAME [--timeout SECONDS]"
    (($# >= 1)) && [[ $1 != --* ]] || die "NAME is missing (it comes right after reinstall). $usage" "$EX_USAGE"
    local name=$1 timeout=600 flag type dir old_env old_mp
    local -A srv=()
    shift
    while (($#)); do
        [[ $1 == --timeout ]] && (($# >= 2)) || die "unknown option or missing value ${1@Q}. $usage" "$EX_USAGE"
        timeout=$2
        shift 2
    done
    [[ $timeout =~ ^[0-9]{1,5}$ ]] || die "--timeout ${timeout@Q} is not a number of seconds. $usage" "$EX_USAGE"
    _need_server "$name"
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    kv_read "$dir/server.env" srv
    type=${srv[TYPE]:-VANILLA}
    flag=$(reinstall_flag "$type")
    [[ -n $flag ]] || die "$type has no reinstall flag, so its installer cannot be made to run again (FORGE, FABRIC, PUFFERFISH and PURPUR have one): nothing was changed" "$EX_USAGE"
    _recreate_guard "$name"
    ((RECREATE_LIVE)) || die "$name is stopped: start it first (mcctl start $name). reinstall runs the installer, waits for it and recreates the containers without the flag, which needs a running server; nothing was changed" "$EX_REFUSED"
    old_env=$(cat "$dir/server.env"; printf X); old_env=${old_env%X}
    old_mp=$(cat "$dir/modpack.env" 2>/dev/null; printf X); old_mp=${old_mp%X}
    _flag_recreate "$name" "$flag" "$timeout" "$old_env" "$old_mp" || exit "$EX_FAIL"
    info "$name: reinstalled, healthy; $flag is gone from the container"
}

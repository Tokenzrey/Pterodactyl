#!/usr/bin/env bash
# shellcheck shell=bash
# Worlds: `mcctl world NAME SUB ...` (list, info, use, new, rename, delete, reset, backup, export, restore, import, seed, datapack).
# Sourced by ./mcctl, never executed.
#
# A world is a folder of servers/NAME/data that holds level.dat; the active one is LEVEL in server.env (default world). Paper keeps
# a world's nether and end beside it as WORLD_nether and WORLD_the_end: the three are one group and move together. Every read and
# write of data/ runs in the helper container (data_run, data_pipe; lib/data.sh), never on the host.
# Changing a world needs a stopped server (exit 4, nothing changed, otherwise). list, info, backup, export, seed and datapack list
# also work on a running server. Whatever removes or overwrites a world (delete, reset, restore) first writes a verified safety
# archive, servers/NAME/safety/world-WORLD-<UTC>.tar.gz (a folder backup prune never reads), and stops when that fails.
# server.properties is never touched: the active world is LEVEL in
# server.env, applied with apply_pending.

# WORLD_SCAN: the script the helper runs in data/ (its working directory). One line per folder: NAME, then 1 when the folder holds
# level.dat (its size in KiB, and the mtime of level.dat in epoch seconds), else 0 and "-". Files and hidden folders are not listed.
WORLD_SCAN='for d in */; do [ -d "$d" ] || continue; n=${d%/}
if [ -f "$n/level.dat" ]; then printf "%s\t1\t%s\t%s\n" "$n" "$(du -sk -- "$n" | cut -f1)" "$(stat -c %Y -- "$n/level.dat")"
else printf "%s\t0\t-\t-\n" "$n"; fi; done'

# DATAPACK_PUT: the helper's script for `datapack add`. $1 is the world's folder, $2 the datapack's path. The zip is read from stdin
# into a temp file beside it, checked (pack.mcmeta at its root) and moved into place only then.
DATAPACK_PUT='[ -f "$1/level.dat" ] || { echo "no world $1 in the server data" >&2; exit 3; }
mkdir -p -- "$1/datapacks" && cat >"$2.mcctl-tmp" && unzip -p "$2.mcctl-tmp" pack.mcmeta >/dev/null && mv -- "$2.mcctl-tmp" "$2"
s=$?; rm -f -- "$2.mcctl-tmp"; exit $s'
DATAPACK_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.zip$'

# valid_world_name W: 0 when W can be a world folder: letters, digits, '_', '.' and '-' (starting with a letter or digit, at most 64
# characters), not the name of a folder the server itself uses, and not a Paper sibling (*_nether, *_the_end). Else 1.
valid_world_name() {
    local LC_ALL=C w=${1-} re='^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'
    [[ $w =~ $re ]] || return 1
    case $w in
        plugins|mods|config|logs|libraries|versions|cache|crash-reports|defaultconfigs|resourcepacks|datapacks|backups) return 1 ;;
        *_nether|*_the_end) return 1 ;;
    esac
}

# _world_name_or_exit W: exit EX_USAGE (with the rule) unless W is a world name
_world_name_or_exit() {
    valid_world_name "${1-}" || die "invalid world name ${1@Q}: 1 to 64 letters, digits, '_', '.' or '-', starting with a letter or digit; not plugins, mods, config or another server folder, and not *_nether or *_the_end" "$EX_USAGE"
}

# active_world NAME -> stdout LEVEL from server.env, or world when there is none. A LEVEL that is not a world name is refused (EX_PREFLIGHT).
active_world() {
    local dir l="" rc=0
    dir=$(server_dir "${1-}") || return
    if [[ -f $dir/server.env ]]; then
        l=$(server_env_get "$1" LEVEL) || rc=$?
        ((rc <= 1)) || return "$rc"
    fi
    l=${l:-world}
    valid_world_name "$l" || { err "LEVEL in $dir/server.env is ${l@Q}, which is not a world name"; return "$EX_PREFLIGHT"; }
    printf '%s\n' "$l"
}

# world_scan NAME -> stdout one WORLD_SCAN row per folder of data/
world_scan() { data_run "$1" sh -c "$WORLD_SCAN"; }

# world_dirs NAME -> stdout the names of the folders that hold level.dat (the worlds), one per line
world_dirs() { world_scan "$1" | awk -F'\t' '$2 == 1 { print $1 }'; }

# world_group NAME W -> stdout W, W_nether and W_the_end, the ones that exist (folders), one per line
world_group() {
    world_scan "$1" | awk -F'\t' -v w="$2" '$1 == w || $1 == w "_nether" || $1 == w "_the_end" { print $1 }'
}

# _world_row ROWS W -> stdout the WORLD_SCAN row of W when W holds level.dat (nothing otherwise)
_world_row() { awk -F'\t' -v w="$2" '$1 == w && $2 == 1' <<<"$1"; }

# _world_need_stopped NAME: exit EX_REFUSED, nothing changed, unless the game container of NAME is stopped
_world_need_stopped() {
    local st
    st=$(_server_state "$1") && [[ -n $st ]] \
        || die "cannot read the state of $(container_name "$1") (docker inspect failed): nothing was changed"
    case $st in
        running|restarting|paused) die "$1 is $st: stop it first (mcctl stop $1). World changes need a stopped server; nothing was changed" "$EX_REFUSED" ;;
    esac
}

# _world_archive_path NAME W FOLDER -> stdout servers/NAME/FOLDER/world-W-<UTC>.tar.gz (a -2, -3 ... suffix when that name is taken).
# FOLDER is safety (the copy that delete, reset and restore make first: nothing prunes it) or backups (what backup writes by default:
# `mcctl backup NAME prune` keeps the newest there). The folder is made 700 on demand.
_world_archive_path() {
    local dir base out n=1
    dir=$(server_dir "$1") || return
    dir=$dir/$3
    mkdir_private "$dir" || { err "cannot create $dir"; return 1; }
    base=$dir/world-$2-$(date -u +%Y%m%dT%H%M%SZ)
    out=$base.tar.gz
    while [[ -e $out || -L $out ]]; do n=$((n + 1)); out=$base-$n.tar.gz; done
    printf '%s\n' "$out"
}

# ---- snapshots -----------------------------------------------------------------------------------------------------------------

# _snapshot_write NAME OUT MEMBER...: tar -czf of the members (paths relative to data/) in the helper, written to OUT with write_atomic
# (mode 600) and read back with tar -tzf. Nothing is left at OUT on failure.
_snapshot_write() {
    local name=$1 out=$2
    shift 2
    write_atomic "$out" data_run "$name" tar -czf - -- "$@" \
        || { err "could not archive $name's data to $out (see above): nothing was archived"; return 1; }
    _backup_verify_archive "$out" || { rm -f -- "$out"; err "$out does not read back: removed, nothing was archived"; return 1; }
}

# _snapshot_live NAME OUT MEMBER...: autosave off (save-off, save-all flush), the archive, then save-on. save-on runs from the EXIT trap
# of a subshell, so it runs when the tar fails and when INT or TERM arrives (Review Focus 6). Nothing is started after a failed save-off.
# ponytail: a world backup that overlaps a sidecar backup may be taken with autosave on; the sidecar has no lock to ask for.
_snapshot_live() {
    local name=$1 out=$2 rc=0
    shift 2
    rcon_exec "$name" save-off >/dev/null || { err "autosave state unknown: run mcctl rcon $name save-on"; return 1; }
    (
        trap 'rcon_exec "$name" save-on >/dev/null || { err "autosave state unknown: run mcctl rcon $name save-on"; exit 1; }' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        rcon_exec "$name" save-all flush >/dev/null || { err "autosave state unknown: run mcctl rcon $name save-on"; exit 1; }
        _snapshot_write "$name" "$out" "$@"
    ) || rc=$?
    ((rc == 0)) || rm -f -- "$out"
    return "$rc"
}

# snapshot_members NAME OUT MEMBER...: archive the MEMBERs of servers/NAME/data to OUT (new; "." is all of data/). A running server is
# quiesced (_snapshot_live), a stopped one is not (no RCON). Refuses an existing OUT.
snapshot_members() {
    local name=$1 out=$2 st
    shift 2
    (($#)) || { err "nothing to archive"; return 1; }
    [[ ! -e $out && ! -L $out ]] || { err "$out already exists: refused, nothing was archived"; return 1; }
    st=$(_server_state "$name") && [[ -n $st ]] \
        || { err "cannot read the state of $(container_name "$name") (docker inspect failed): nothing was archived"; return 1; }
    case $st in
        running|restarting|paused) _snapshot_live "$name" "$out" "$@" ;;
        *) _snapshot_write "$name" "$out" "$@" ;;
    esac
}

# world_snapshot NAME W OUT: snapshot_members of the group of W (1 when W does not exist)
world_snapshot() {
    local group
    local -a grp=()
    group=$(world_group "$1" "$2") || return
    [[ -n $group ]] || { err "no world $2 in $1 (mcctl world $1 list shows the worlds)"; return 1; }
    mapfile -t grp <<<"$group"
    snapshot_members "$1" "$3" "${grp[@]}"
}

# _world_remove NAME MEMBER...: remove the folders of a group in the helper (each name is checked by safe_path first)
_world_remove() {
    local name=$1 m
    shift
    for m; do safe_path "$m" >/dev/null || return 1; done
    data_run "$name" rm -rf -- "$@"
}

# _world_archive_ok ARCHIVE: every member is safe (archive_safe_members); dies, nothing changed, when not
_world_archive_ok() {
    local rc
    archive_safe_members "$1"; rc=$?
    ((rc != 2)) || die "cannot list the members of $1 (not a readable gzip tar): nothing was changed" "$EX_FAIL"
    ((rc == 0)) || die "$1 has unsafe members (named above): nothing was changed" "$EX_REFUSED"
}

# ---- list, info, use, seed -----------------------------------------------------------------------------------------------------

# _world_list NAME: one row per world, newest first; '*' marks the active one
_world_list() {
    local name=$1 act rows n kb ep mark
    act=$(active_world "$name") || exit
    rows=$(world_scan "$name") || die "cannot list the worlds of $name (see above)"
    rows=$(awk -F'\t' '$2 == 1' <<<"$rows" | sort -t $'\t' -k4,4nr)
    if [[ -z $rows ]]; then info "$name: no worlds yet (the server makes its world at its first start)"; return 0; fi
    printf '  %-24s %10s  %s\n' WORLD KiB 'MODIFIED (UTC)'
    while IFS=$'\t' read -r n _ kb ep; do
        mark=" "
        [[ $n == "$act" ]] && mark="*"
        printf '%s %-24s %10s  %s\n' "$mark" "$n" "$kb" "$(date -u -d "@$ep" '+%Y-%m-%d %H:%M')"
    done <<<"$rows"
}

# _world_info NAME W: path, size, modified time, siblings, and whether W is the active world
_world_info() {
    local name=$1 w=$2 act rows row kb ep sibs
    act=$(active_world "$name") || exit
    w=${w:-$act}
    _world_name_or_exit "$w"
    rows=$(world_scan "$name") || die "cannot list the worlds of $name (see above)"
    row=$(_world_row "$rows" "$w")
    [[ -n $row ]] || die "no world $w in $name (mcctl world $name list shows the worlds)"
    IFS=$'\t' read -r _ _ kb ep <<<"$row"
    sibs=$(awk -F'\t' -v w="$w" '$1 == w "_nether" || $1 == w "_the_end" { printf "%s ", $1 }' <<<"$rows")
    printf 'world:    %s\n' "$w"
    printf 'path:     %s/data/%s\n' "$(server_dir "$name")" "$w"
    printf 'size:     %s KiB\n' "$kb"
    printf 'modified: %s UTC\n' "$(date -u -d "@$ep" '+%Y-%m-%d %H:%M')"
    printf 'siblings: %s\n' "${sibs:-none}"
    if [[ $w == "$act" ]]; then printf 'active:   yes\n'; else printf 'active:   no (mcctl world %s use %s)\n' "$name" "$w"; fi
}

# _world_use NAME W: LEVEL=W in server.env, then apply_pending. W must exist.
_world_use() {
    local name=$1 w=$2 rows
    _world_name_or_exit "$w"
    _world_need_stopped "$name"
    rows=$(world_scan "$name") || die "cannot list the worlds of $name (see above)"
    [[ -n $(_world_row "$rows" "$w") ]] \
        || die "no world $w in $name: mcctl world $name new $w --use creates the switch to it (the world is made at the first start)" "$EX_FAIL"
    _settings_store "$name" LEVEL "$w"
    apply_pending "$name"
}

# _world_seed NAME: the seed of the running world, from the server's `seed` command
_world_seed() {
    local name=$1 st reply num
    st=$(_server_state "$name") || st=""
    case $st in
        running|restarting|paused) ;;
        *) die "seed needs a running server (the game reports the seed): start it with mcctl start $name" "$EX_FAIL" ;;
    esac
    reply=$(rcon_exec "$name" seed) || die "rcon seed failed on $name (see above)"
    num=$(grep -oE -- '-?[0-9]+' <<<"$reply" | head -n 1)
    [[ -n $num ]] || die "no seed in the reply of the server: ${reply@Q}" "$EX_FAIL"
    printf '%s\n' "$num"
}

# ---- new, rename, delete, reset, backup, restore, import -----------------------------------------------------------------------

# _world_setting KEY TYPE VALUE -> stdout VALUE as stored (settings_check); EX_USAGE with a message when it is not valid
_world_setting() {
    [[ $3 != *[[:cntrl:]]* ]] || { err "$1: the value must be one line with no control character"; return "$EX_USAGE"; }
    settings_check "$1" "$2" "$3"
}

# _world_new NAME W [--seed S] [--type T] [--generator-settings FILE] [--hardcore] [--datapacks-enable a,b] [--datapacks-disable a,b] [--use]
_world_new() {
    local name=$1 w=$2 usage="usage: mcctl world NAME new WORLD [--seed S] [--type T] [--generator-settings FILE] [--hardcore] [--datapacks-enable a,b] [--datapacks-disable a,b] [--use]"
    local seed="" type="" gen="" en="" dis="" hard=0 use=0 hs=0 ht=0 hg=0 he=0 hd=0 v act rows
    local pack_re='^[A-Za-z0-9_./:-]+(,[A-Za-z0-9_./:-]+)*$'
    local -a pairs=()
    shift 2
    while (($#)); do
        case $1 in
            --seed) (($# >= 2)) || die "$1 needs a value. $usage" "$EX_USAGE"; seed=$2; hs=1; shift ;;
            --type) (($# >= 2)) || die "$1 needs a value. $usage" "$EX_USAGE"; type=$2; ht=1; shift ;;
            --generator-settings) (($# >= 2)) || die "$1 needs a file. $usage" "$EX_USAGE"; gen=$2; hg=1; shift ;;
            --datapacks-enable) (($# >= 2)) || die "$1 needs a value. $usage" "$EX_USAGE"; en=$2; he=1; shift ;;
            --datapacks-disable) (($# >= 2)) || die "$1 needs a value. $usage" "$EX_USAGE"; dis=$2; hd=1; shift ;;
            --hardcore) hard=1 ;;
            --use) use=1 ;;
            *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
        esac
        shift
    done
    _world_name_or_exit "$w"
    # every value is checked before anything else happens
    if ((hs)); then v=$(_world_setting SEED text "$seed") || exit "$EX_USAGE"; pairs+=(SEED "$v"); fi
    if ((ht)); then v=$(_world_setting LEVEL_TYPE text "$type") || exit "$EX_USAGE"; pairs+=(LEVEL_TYPE "$v"); fi
    if ((hg)); then
        [[ -f $gen && -r $gen ]] || die "$gen is not a readable file" "$EX_USAGE"
        command -v jq >/dev/null || die "--generator-settings needs jq, which is not installed" "$EX_FAIL"
        jq -e . <"$gen" >/dev/null 2>&1 || die "$gen is not JSON (jq -e . fails): nothing was changed" "$EX_USAGE"
        v=$(jq -c . <"$gen") && v=$(_world_setting GENERATOR_SETTINGS json "$v") || exit "$EX_USAGE"
        pairs+=(GENERATOR_SETTINGS "$v")
    fi
    ((hard)) && pairs+=(HARDCORE TRUE)
    if ((he)); then
        [[ $en =~ $pack_re ]] || die "--datapacks-enable ${en@Q} is not a comma-separated list of pack names" "$EX_USAGE"
        pairs+=(INITIAL_ENABLED_PACKS "$en")
    fi
    if ((hd)); then
        [[ $dis =~ $pack_re ]] || die "--datapacks-disable ${dis@Q} is not a comma-separated list of pack names" "$EX_USAGE"
        pairs+=(INITIAL_DISABLED_PACKS "$dis")
    fi
    _world_need_stopped "$name"
    act=$(active_world "$name") || exit
    rows=$(world_scan "$name") || die "cannot list the worlds of $name (see above)"
    [[ -z $(awk -F'\t' -v w="$w" '$1 == w' <<<"$rows") ]] || die "$w already exists in $name: nothing was changed" "$EX_REFUSED"
    ((use)) && pairs+=(LEVEL "$w")
    if ((${#pairs[@]})); then _settings_store "$name" "${pairs[@]}"; fi
    if ((use)); then
        apply_pending "$name"
        info "$name: $w is the active world; the server makes it at its next start if it does not exist yet"
    else
        ((${#pairs[@]} == 0)) || info "$name: config pending: mcctl apply $name"
        info "$name: $w is not the active world (LEVEL is $act): add --use to make it the one the server starts with"
    fi
}

# _world_rename NAME OLD NEW: the group moves (siblings first, the world last); LEVEL follows when OLD is active
_world_rename() {
    local name=$1 old=$2 new=$3 act group newg g
    local -a grp=()
    _world_need_stopped "$name"
    act=$(active_world "$name") || exit
    group=$(world_group "$name" "$old") || exit
    [[ -n $group ]] || die "no world $old in $name (mcctl world $name list shows the worlds)" "$EX_FAIL"
    newg=$(world_group "$name" "$new") || exit
    [[ -z $newg ]] || die "$new (or its nether or end) already exists in $name: nothing was changed" "$EX_REFUSED"
    mapfile -t grp <<<"$group"
    # while the world keeps its name, the server still finds its active world: the siblings go first
    for g in "${grp[@]}"; do
        [[ $g == "$old" ]] && continue
        data_run "$name" mv -- "$g" "$new${g#"$old"}" \
            || die "renaming $g failed (see above): $old is still there; mcctl world $name list shows what is left" "$EX_FAIL"
    done
    data_run "$name" mv -- "$old" "$new" \
        || die "renaming $old failed (see above): its nether and end, if any, are already named $new; mcctl world $name list shows what is left" "$EX_FAIL"
    if [[ $act == "$old" ]]; then
        _settings_store "$name" LEVEL "$new"
        apply_pending "$name"
    fi
    info "$name: $old renamed to $new"
}

# _world_delete NAME W RESET(0|1): snapshot the group, confirm, remove the group. delete refuses the active world; reset does not.
_world_delete() {
    local name=$1 w=$2 reset=$3 act group out
    local -a grp=()
    _world_name_or_exit "$w"
    _world_need_stopped "$name"
    act=$(active_world "$name") || exit
    if ((!reset)) && [[ $w == "$act" ]]; then
        die "$w is the active world of $name: switch to another one first (mcctl world $name use OTHER), then delete it" "$EX_REFUSED"
    fi
    group=$(world_group "$name" "$w") || exit
    [[ -n $group ]] || die "no world $w in $name (mcctl world $name list shows the worlds)" "$EX_FAIL"
    mapfile -t grp <<<"$group"
    out=$(_world_archive_path "$name" "$w" safety) || exit
    snapshot_members "$name" "$out" "${grp[@]}" || die "could not archive $w to $out (see above): nothing was removed" "$EX_FAIL"
    if ((reset)); then
        confirm "Reset $w of $name? The world is removed (a verified copy is in $out); the server makes a new $w at its next start, from SEED if it is set." \
            || die "$w was not reset: nothing was removed (the copy $out is kept)" "$EX_REFUSED"
    else
        confirm "Delete $w of $name? The world and its nether and end are removed (a verified copy is in $out)." \
            || die "$w was not deleted: nothing was removed (the copy $out is kept)" "$EX_REFUSED"
    fi
    _world_remove "$name" "${grp[@]}" || die "could not remove $w (see above); the verified copy is in $out" "$EX_FAIL"
    if ((reset)); then info "$name: $w reset; the server makes a new $w at its next start (from SEED if it is set); the copy is in $out"
    else info "$name: $w deleted; the copy is in $out"; fi
}

# _world_backup NAME W OUT: a verified archive of the group of W (OUT empty: backups/world-W-<UTC>.tar.gz); OUT must not exist
_world_backup() {
    local name=$1 w=$2 out=$3
    _world_name_or_exit "$w"
    if [[ -n $out && ( -e $out || -L $out ) ]]; then die "$out already exists: refused (choose another --out)" "$EX_REFUSED"; fi
    if [[ -z $out ]]; then out=$(_world_archive_path "$name" "$w" backups) || exit; fi
    world_snapshot "$name" "$w" "$out" || die "the backup of $w failed (see above)" "$EX_FAIL"
    info "$name: $w saved to $out (verified with tar -tzf)"
}

# _world_restore NAME W ARCHIVE: replace the group of W with the one in ARCHIVE; the current group is copied to safety/ first
_world_restore() {
    local name=$1 w=$2 arch=$3 group top out="" has=0
    local -a grp=() tops=()
    _world_name_or_exit "$w"
    [[ -f $arch && -r $arch ]] || die "$arch is not a readable file: nothing was changed" "$EX_FAIL"
    _world_need_stopped "$name"
    _world_archive_ok "$arch"
    mapfile -t tops < <(tar -tzf "$arch" | cut -d/ -f1 | sort -u)
    for top in "${tops[@]}"; do
        case $top in
            "$w") has=1 ;;
            "${w}_nether"|"${w}_the_end") ;;
            *) die "$arch has ${top@Q} at its top level: a world archive holds only $w, ${w}_nether and ${w}_the_end; nothing was changed" "$EX_REFUSED" ;;
        esac
    done
    ((has)) || die "$arch has no $w folder at its top level: nothing was changed" "$EX_REFUSED"
    group=$(world_group "$name" "$w") || exit
    if [[ -n $group ]]; then
        mapfile -t grp <<<"$group"
        out=$(_world_archive_path "$name" "$w" safety) || exit
        snapshot_members "$name" "$out" "${grp[@]}" || die "could not copy the current $w to $out (see above): nothing was changed" "$EX_FAIL"
    fi
    confirm "Replace $w of $name with the one in $arch? ${out:+The current one is copied to $out first.}" \
        || die "$w was not restored: nothing was removed${out:+ (the copy $out is kept)}" "$EX_REFUSED"
    if ((${#grp[@]})); then
        _world_remove "$name" "${grp[@]}" || die "could not remove the current $w (see above): nothing was extracted${out:+; its copy is $out}" "$EX_FAIL"
    fi
    data_pipe "$name" tar -xzf - --no-same-owner -C /data <"$arch" \
        || die "extracting $arch failed (see above)${out:+; the previous $w is in $out: restore it with mcctl world $name restore $w $out}" "$EX_FAIL"
    info "$name: $w restored from $arch"
}

# _world_unstage NAME STAGE: remove an import's staging folder (in the helper; a dot folder, so no world list shows it)
_world_unstage() {
    local p
    p=$(safe_path "$2") && data_run "$1" rm -rf -- "$p"
}

# _world_import NAME ARCHIVE [--as W] [--use]: extract into a staging folder of data/, check the names, then move into place
_world_import() {
    local name=$1 arch=$2 as="" use=0 names n x="" f stage ext t i depth0=0 found
    local -a tops=() srcs=() targets=()
    shift 2
    while (($#)); do
        case $1 in
            --as) (($# >= 2)) || die "usage: mcctl world NAME import ARCHIVE [--as WORLD] [--use]" "$EX_USAGE"; as=$2; shift ;;
            --use) use=1 ;;
            *) die "unknown option ${1@Q}: usage: mcctl world NAME import ARCHIVE [--as WORLD] [--use]" "$EX_USAGE" ;;
        esac
        shift
    done
    if [[ -n $as ]]; then _world_name_or_exit "$as"; fi
    [[ -f $arch && -r $arch ]] || die "$arch is not a readable file: nothing was changed" "$EX_FAIL"
    _world_archive_ok "$arch"
    names=$(tar -tzf "$arch") || die "cannot list $arch: nothing was changed" "$EX_FAIL"
    n=$(grep -cE '^([^/]+/)?level\.dat$' <<<"$names")
    ((n == 1)) || die "$arch must hold one level.dat, at its root or in one folder (it holds $n): nothing was changed" "$EX_REFUSED"
    if grep -qFx 'level.dat' <<<"$names"; then
        depth0=1
        [[ -n $as ]] || die "$arch has level.dat at its root, so it names no world: give the world name with --as WORLD" "$EX_USAGE"
        f=$as
        srcs=("$f")
        targets=("$f")
    else
        x=$(grep -E '^[^/]+/level\.dat$' <<<"$names")
        x=${x%/level.dat}
        if [[ -z $as ]]; then
            valid_world_name "$x" || die "the world in $arch is named ${x@Q}, which is not a world name: give another with --as WORLD" "$EX_REFUSED"
        fi
        f=${as:-$x}
        mapfile -t tops < <(cut -d/ -f1 <<<"$names" | sort -u)
        for t in "${tops[@]}"; do
            case $t in
                "$x"|"${x}_nether"|"${x}_the_end") ;;
                *) die "$arch has ${t@Q} at its top level: a world archive may hold only $x, ${x}_nether and ${x}_the_end: nothing was changed" "$EX_REFUSED" ;;
            esac
            srcs+=("$t")
            targets+=("$f${t#"$x"}")
        done
    fi
    valid_world_name "$f" || die "${f@Q} is not a world name (1 to 64 letters, digits, '_', '.' or '-'; not a server folder or a sibling name)" "$EX_USAGE"
    _world_need_stopped "$name"
    found=$(world_scan "$name") || die "cannot list the worlds of $name (see above): nothing was changed" "$EX_FAIL"
    for t in "${targets[@]}"; do
        [[ -z $(awk -F'\t' -v w="$t" '$1 == w' <<<"$found") ]] \
            || die "$t already exists in $name: pass --as WORLD with a free name; nothing was changed" "$EX_REFUSED"
    done
    stage=.mcctl-import-$$
    ext=$stage
    ((depth0)) && ext=$stage/$f
    data_run "$name" mkdir -p -- "$ext" \
        || { _world_unstage "$name" "$stage"; die "cannot make the staging folder in $name's data (see above): nothing was added" "$EX_FAIL"; }
    data_pipe "$name" tar -xzf - --no-same-owner -C "$ext" <"$arch" \
        || { _world_unstage "$name" "$stage"; die "extracting $arch failed (see above): nothing was added to $name" "$EX_FAIL"; }
    # a failed move keeps the staging folder: what is not moved yet is still in it
    for i in "${!srcs[@]}"; do
        data_run "$name" mv -- "$stage/${srcs[i]}" "${targets[i]}" \
            || die "moving ${srcs[i]} into place failed (see above). The rest of the archive is in $name's data/$stage, and what was moved is in its world list: mcctl world $name list; remove the rest with mcctl files $name rm $stage --recursive" "$EX_FAIL"
    done
    _world_unstage "$name" "$stage" || warn "$name: the staging folder $stage could not be removed (see above)"
    if ((use)); then
        _settings_store "$name" LEVEL "$f"
        apply_pending "$name"
        info "$name: imported $f and made it the active world"
    else
        info "$name: imported $f; it is not the active world: mcctl world $name use $f"
    fi
}

# ---- datapacks -----------------------------------------------------------------------------------------------------------------

# _world_datapack NAME VERB [ARG] [--world W]: list, add FILE, remove PACK. Only the world folder's datapacks/ is touched.
_world_datapack() {
    local name=$1 verb=${2-} w="" base="" out rc act
    local -a pos=()
    local usage="usage: mcctl world NAME datapack list [--world W] | add FILE [--world W] | remove PACK [--world W]"
    shift 2
    while (($#)); do
        case $1 in
            --world) (($# >= 2)) || die "$usage" "$EX_USAGE"; w=$2; shift ;;
            -*) die "$usage" "$EX_USAGE" ;;
            *) pos+=("$1") ;;
        esac
        shift
    done
    if [[ -n $w ]]; then _world_name_or_exit "$w"; fi
    act=$(active_world "$name") || exit
    w=${w:-$act}
    case $verb in
        list)
            ((${#pos[@]} == 0)) || die "$usage" "$EX_USAGE"
            out=$(data_run "$name" sh -c '[ -f "$1/level.dat" ] || exit 3; [ -d "$1/datapacks" ] || exit 0; ls -1 -- "$1/datapacks"' sh "$w")
            rc=$?
            case $rc in
                0) [[ -z $out ]] || printf '%s\n' "$out" ;;
                3) die "no world $w in $name (mcctl world $name list shows the worlds)" "$EX_FAIL" ;;
                *) die "cannot list the datapacks of $w (see above)" "$EX_FAIL" ;;
            esac ;;
        add)
            ((${#pos[@]} == 1)) || die "$usage" "$EX_USAGE"
            base=${pos[0]##*/}
            [[ $base =~ $DATAPACK_NAME_RE ]] \
                || die "a datapack is a .zip named with letters, digits, '.', '_' or '-' (up to 64 characters before .zip): ${base@Q} is not" "$EX_USAGE"
            [[ -f ${pos[0]} && -r ${pos[0]} ]] || die "${pos[0]} is not a readable file" "$EX_FAIL"
            _world_need_stopped "$name"
            data_pipe "$name" sh -c "$DATAPACK_PUT" sh "$w" "$w/datapacks/$base" <"${pos[0]}" \
                || die "datapack $base was not written (see above): it must be a zip with pack.mcmeta at its root, and $w must be a world of $name" "$EX_FAIL"
            info "$name: datapack $base written to $w/datapacks" ;;
        remove)
            ((${#pos[@]} == 1)) || die "$usage" "$EX_USAGE"
            base=${pos[0]}
            [[ $base =~ $DATAPACK_NAME_RE ]] \
                || die "a datapack is a .zip named with letters, digits, '.', '_' or '-' (up to 64 characters before .zip): ${base@Q} is not" "$EX_USAGE"
            _world_need_stopped "$name"
            data_run "$name" rm -- "$w/datapacks/$base" \
                || die "datapack $base was not removed from $w (see above; mcctl world $name datapack list shows them)" "$EX_FAIL"
            info "$name: datapack $base removed from $w" ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac
}

# ---- the command ---------------------------------------------------------------------------------------------------------------

# cmd_world NAME SUB ARGS...: every world subcommand (the usage line lists them). Exit codes: 2 usage, 3 invalid, 4 refused, 1 failed.
cmd_world() {
    local usage="usage: mcctl world NAME list | info [WORLD] | use WORLD | new WORLD [OPTIONS] [--use] | rename OLD NEW | delete WORLD | reset [WORLD] | backup [WORLD] [--out FILE] | export WORLD OUT.tar.gz | restore WORLD ARCHIVE | import ARCHIVE [--as WORLD] [--use] | seed | datapack list|add|remove ..."
    local name=${1-} sub=${2-} w="" out=""
    [[ -n $name && -n $sub ]] || die "$usage" "$EX_USAGE"
    _need_name "$name" || exit "$EX_USAGE"
    shift 2
    _need_server "$name"
    case $sub in
        list) (($# == 0)) || die "$usage" "$EX_USAGE"; _world_list "$name" ;;
        info) (($# <= 1)) || die "$usage" "$EX_USAGE"; _world_info "$name" "${1-}" ;;
        use) (($# == 1)) || die "$usage" "$EX_USAGE"; _world_use "$name" "$1" ;;
        new) (($# >= 1)) && [[ $1 != --* ]] || die "$usage" "$EX_USAGE"; _world_new "$name" "$@" ;;
        rename) (($# == 2)) || die "$usage" "$EX_USAGE"; _world_name_or_exit "$1"; _world_name_or_exit "$2"; _world_rename "$name" "$1" "$2" ;;
        delete) (($# == 1)) || die "$usage" "$EX_USAGE"; _world_delete "$name" "$1" 0 ;;
        reset)
            (($# <= 1)) || die "$usage" "$EX_USAGE"
            w=${1-}
            [[ -n $w ]] || { w=$(active_world "$name") || exit; }
            _world_delete "$name" "$w" 1 ;;
        backup|export)
            if [[ $sub == export ]]; then
                (($# == 2)) && [[ -n $2 ]] || die "usage: mcctl world NAME export WORLD OUT.tar.gz" "$EX_USAGE"
                w=$1 out=$2
            else
                while (($#)); do
                    case $1 in
                        --out) (($# >= 2)) || die "$usage" "$EX_USAGE"; out=$2; shift ;;
                        -*) die "$usage" "$EX_USAGE" ;;
                        *) [[ -z $w ]] || die "$usage" "$EX_USAGE"; w=$1 ;;
                    esac
                    shift
                done
                [[ -n $w ]] || { w=$(active_world "$name") || exit; }
            fi
            _world_backup "$name" "$w" "$out" ;;
        restore) (($# == 2)) || die "$usage" "$EX_USAGE"; _world_restore "$name" "$1" "$2" ;;
        import) (($# >= 1)) && [[ $1 != --* ]] || die "$usage" "$EX_USAGE"; _world_import "$name" "$@" ;;
        seed) (($# == 0)) || die "$usage" "$EX_USAGE"; _world_seed "$name" ;;
        datapack) _world_datapack "$name" "$@" ;;
        *) die "unknown world command ${sub@Q}. $usage" "$EX_USAGE" ;;
    esac
}

#!/usr/bin/env bash
# shellcheck shell=bash
# The data access primitive and `mcctl files`: read and change the files in servers/NAME/data through a throw-away helper
# container that sees only that folder, so neither the host user's permissions nor sudo are needed. Sourced by ./mcctl, never executed.
#
# The helper runs MCCTL_DATA_IMAGE (default alpine:3.20, pinned; the first call pulls it) as MCCTL_UID (default 1000, the game's
# user) with no network, no capabilities, a read-only root file system (only /data and /tmp are writable) and a memory limit.
# A container script is a fixed string; the values the user typed follow it as arguments (sh -c 'script' sh "$path"), never inside it.
# A path is checked twice: safe_path on the host (lexically), then _confine in the helper (readlink -f). The container is the
# boundary; the readlink check is a barrier if the mount ever grows.

DATA_IMAGE=alpine:3.20

# safe_path PATH -> stdout the normalised relative path (./mods/a.jar -> mods/a.jar, a//b/ -> a/b, -x -> ./-x, ./ -> .); 2 with a
# message for an empty path, an absolute path, a .. component or a control character (a newline, a tab, an escape byte).
safe_path() {
    local LC_ALL=C IFS=/ p=${1-} c out
    local -a comps parts=()
    if [[ -z $p ]]; then err "empty path: name a file or folder in the server's data/ folder ('.' is the folder itself)"; return "$EX_USAGE"; fi
    if [[ $p == *[[:cntrl:]]* ]]; then err "path has a control character (newline, tab or escape): refused"; return "$EX_USAGE"; fi
    if [[ $p == /* ]]; then err "path ${p@Q} is absolute: name it relative to the server's data/ folder"; return "$EX_USAGE"; fi
    read -r -a comps <<<"$p"
    for c in "${comps[@]}"; do
        case $c in
            ''|.) ;;
            ..) err "path ${p@Q} has a .. component: refused"; return "$EX_USAGE" ;;
            *) parts+=("$c") ;;
        esac
    done
    if ((${#parts[@]} == 0)); then printf '.\n'; return 0; fi
    out="${parts[*]}"
    if [[ $out == -* ]]; then out="./$out"; fi
    printf '%s\n' "$out"
}

# _data_dir NAME -> stdout servers/NAME/data. EX_USAGE for a name that cannot be a server; 1 with a message when there is no such folder.
_data_dir() {
    local dir
    dir=$(server_dir "${1-}") || return
    [[ -d $dir/data ]] || { err "no data folder for '$1': no server named '$1' (mcctl list shows the servers)"; return "$EX_FAIL"; }
    printf '%s/data\n' "$dir"
}

# game_uid -> stdout the user the game runs as: MCCTL_UID, default 1000, a number from 1 to 65535. Anything else dies (EX_PREFLIGHT).
game_uid() {
    local uid=${MCCTL_UID:-1000}
    [[ $uid =~ ^[1-9][0-9]{0,4}$ ]] && ((uid <= 65535)) \
        || die "MCCTL_UID=${uid@Q} must be a number from 1 to 65535 (the user the file helper runs as; the game's user in itzg's image is 1000)" "$EX_PREFLIGHT"
    printf '%s\n' "$uid"
}

# _data_docker STDIN NAME CMD...: one docker run of CMD with servers/NAME/data as /data. STDIN 1 keeps the caller's stdin (-i).
# The user and the image are checked here, before any Docker call, and an invalid value exits EX_PREFLIGHT.
_data_docker() {
    local stdin=$1 name=$2 dir uid image=${MCCTL_DATA_IMAGE:-$DATA_IMAGE}
    local -a io=()
    local image_re='^[a-z0-9][a-z0-9./:_-]*$'
    shift 2
    uid=$(game_uid) || exit "$EX_PREFLIGHT"
    [[ $image =~ $image_re ]] \
        || die "MCCTL_DATA_IMAGE=${image@Q} is not an image reference (e.g. alpine:3.20)" "$EX_PREFLIGHT"
    dir=$(_data_dir "$name") || return
    if ((stdin)); then io=(-i); fi
    docker run --rm "${io[@]}" --network none --user "$uid:$uid" --cap-drop ALL \
        --security-opt no-new-privileges --read-only --tmpfs /tmp --pids-limit 64 --memory 128m \
        -v "$dir:/data" -w /data "$image" "$@"
}

# data_run NAME CMD...: run CMD in the helper container, with no stdin
data_run() { _data_docker 0 "$@"; }
# data_pipe NAME CMD...: as data_run, but CMD reads the caller's stdin (put and edit stream a file through it)
data_pipe() { _data_docker 1 "$@"; }

# _root_docker MODE PATH CAPS CMD...: one docker run as root with only the capabilities in CAPS (a space-separated list) added. PATH, a
# file or a folder, is mounted at /m (MODE ro or rw) and the container has no network. The image is the pinned DATA_IMAGE, never
# MCCTL_DATA_IMAGE: this one runs as root. The caller fixes CMD; the paths in it are inside /m. PATH must exist: Docker would make a
# missing one as root.
_root_docker() {
    local mode=$1 path=$2 caps=$3 cap
    local -a capargs=()
    shift 3
    [[ $path != *:* ]] || { err "${path@Q} has a colon, which the mount cannot take: refused"; return "$EX_FAIL"; }
    [[ -e $path ]] || { err "${path@Q} does not exist: refused (Docker would create it as root)"; return "$EX_FAIL"; }
    for cap in $caps; do capargs+=(--cap-add "$cap"); done
    docker run --rm --network none --cap-drop ALL "${capargs[@]}" --security-opt no-new-privileges \
        --read-only --tmpfs /tmp --pids-limit 64 --memory 128m -v "$path:/m:$mode" "$DATA_IMAGE" "$@"
}

# _give_to_game PATH: PATH (a file or a folder) belongs to the game's user from now on, its mode unchanged. The server reads its secrets
# and writes its data as that user, and mcctl runs as the host user, which cannot chown: a helper with CHOWN alone does it.
_give_to_game() {
    local path=$1 uid
    uid=$(game_uid) || exit "$EX_PREFLIGHT"
    _root_docker rw "$path" CHOWN sh -c 'chown -- "$1:$1" /m && [ "$(stat -c %u /m)" = "$1" ]' sh "$uid" \
        || { err "cannot give ${path@Q} to UID $uid (see above)"; return "$EX_FAIL"; }
}

# _confine NAME PATH: 0 when PATH resolves inside data/ in the helper. A missing last part is fine (put and mkdir name paths that do
# not exist yet). A symbolic link that leads out of data/ is refused before any read or write.
_confine() {
    local rc=0
    data_run "$1" sh -c 'p=$(readlink -f -- "$1" 2>/dev/null) || p=$(readlink -f -- "$(dirname "$1")"); case $p in /data|/data/*) ;; *) exit 3 ;; esac' sh "$2" || rc=$?
    if ((rc == 0)); then return 0; fi
    if ((rc == 3)); then err "${2@Q} is not inside the server's data/ folder (a symbolic link leads out, or its folder is missing): refused"
    else err "cannot check that ${2@Q} is inside data/ (helper exit $rc): refused"; fi
    return "$EX_USAGE"
}

# _files_target NAME PATH -> stdout the normalised PATH when it is safe and resolves inside data/
_files_target() {
    local p
    p=$(safe_path "$2") || return
    _confine "$1" "$p" || return
    printf '%s\n' "$p"
}

# _store NAME PATH SRC: write the local file SRC over PATH in data/ through a temp file beside PATH and mv, so a failure leaves PATH as it was
_store() { data_pipe "$1" sh -c 'cat > "$1.mcctl-tmp" && mv -- "$1.mcctl-tmp" "$1"' sh "$2" <"$3"; }

# _edit NAME PATH: copy PATH to a private folder (700; the copy is 600), open ${EDITOR:-vi} on the copy, and write it back only when
# its content changed. A file over 1 MB is refused before the copy and again after the edit. The folder goes on every exit,
# interrupts included: the subshell's traps remove it.
_edit() {
    local name=$1 p=$2 size dir
    size=$(data_run "$name" stat -c %s -- "$p") || die "cannot read $p (see above)" "$EX_FAIL"
    ((size <= 1048576)) || die "$p is $size bytes: files over 1 MB are not edited here (use get and put)" "$EX_REFUSED"
    (
        dir=$(mktemp -d) || exit "$EX_FAIL"
        trap 'rm -f -- "$dir/copy" "$dir/orig"; rmdir -- "$dir"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        data_run "$name" cat -- "$p" >"$dir/copy" || die "cannot copy $p (see above): nothing was changed" "$EX_FAIL"
        cp "$dir/copy" "$dir/orig" || exit "$EX_FAIL"
        ${EDITOR:-vi} "$dir/copy" || die "the editor failed: $p was not changed" "$EX_FAIL"
        if cmp -s "$dir/copy" "$dir/orig"; then info "$p: no changes, nothing written"; exit 0; fi
        size=$(stat -c %s "$dir/copy")
        ((size <= 1048576)) || die "the edited $p is over 1 MB: nothing was written" "$EX_REFUSED"
        _store "$name" "$p" "$dir/copy" || die "could not write $p (see above): it is as it was" "$EX_FAIL"
        info "$p: written"
    )
}

# cmd_files NAME VERB ARGS...: ls, cat, get, put, rm, mkdir, mv, edit on servers/NAME/data. The refusals and exit codes are in docs/reference.md.
cmd_files() {
    local usage="usage: mcctl files NAME ls [PATH] | cat PATH | get PATH [DEST] | put SRC PATH [--force] | rm PATH [--recursive] | mkdir PATH | mv SRC DEST | edit PATH"
    local name=${1-} verb=${2-} a p src dest kind force=0 rec=0
    local -a pos=()
    (($# >= 2)) || die "$usage" "$EX_USAGE"
    shift 2
    _need_name "$name" || exit "$EX_USAGE"
    _data_dir "$name" >/dev/null || exit
    for a in "$@"; do
        case $a in
            --force) force=1 ;;
            --recursive) rec=1 ;;
            *) pos+=("$a") ;;
        esac
    done
    case $verb in
        ls)
            ((${#pos[@]} <= 1)) || die "$usage" "$EX_USAGE"
            p=$(_files_target "$name" "${pos[0]-.}") || exit
            data_run "$name" ls -la -- "$p"
            ;;
        cat)
            ((${#pos[@]} == 1)) || die "$usage" "$EX_USAGE"
            p=$(_files_target "$name" "${pos[0]}") || exit
            data_run "$name" cat -- "$p"
            ;;
        get)
            ((${#pos[@]} == 1 || ${#pos[@]} == 2)) || die "$usage" "$EX_USAGE"
            p=$(_files_target "$name" "${pos[0]}") || exit
            if ((${#pos[@]} == 2)); then dest=${pos[1]}; else dest=./${p##*/}; fi
            [[ -n $dest ]] || die "$usage" "$EX_USAGE"
            [[ ! -e $dest ]] || die "$dest already exists: refused, nothing was changed (choose another DEST)" "$EX_REFUSED"
            write_atomic "$dest" data_run "$name" cat -- "$p" \
                || die "could not copy $p to $dest (see above): nothing was written" "$EX_FAIL"
            info "$p copied to $dest"
            ;;
        put)
            ((${#pos[@]} == 2)) || die "$usage" "$EX_USAGE"
            src=${pos[0]}
            [[ -f $src && -r $src ]] || die "$src is not a readable file" "$EX_FAIL"
            p=$(_files_target "$name" "${pos[1]}") || exit
            # one stat answers both: a folder is never replaced (the file would land inside it); anything else needs --force.
            # A failing stat reads as "absent": the store that follows goes through the same helper and would fail too.
            if kind=$(data_run "$name" stat -c %F -- "$p" 2>/dev/null); then
                [[ $kind != directory ]] || die "$p is a folder: put replaces files only" "$EX_REFUSED"
                ((force)) || die "$p already exists in the data of $name: refused (add --force to replace it)" "$EX_REFUSED"
            fi
            _store "$name" "$p" "$src" || die "could not write $p (see above)" "$EX_FAIL"
            info "$p written"
            ;;
        rm)
            ((${#pos[@]} == 1)) || die "$usage" "$EX_USAGE"
            p=$(safe_path "${pos[0]}") || exit
            [[ $p != . ]] || die "the data folder itself cannot be removed: name a file or folder inside it" "$EX_REFUSED"
            _confine "$name" "$p" || exit
            if data_run "$name" test -d "$p" 2>/dev/null; then
                ((rec)) || die "$p is a folder: add --recursive to remove it and everything in it" "$EX_REFUSED"
                confirm "Delete the folder $p and everything in it from the data of $name? This cannot be undone." \
                    || die "$p was not deleted" "$EX_REFUSED"
                p=$(safe_path "$p") || exit   # the sink re-checks: rm -rf below only ever gets a normalised path
                data_run "$name" rm -rf -- "$p"
            else
                data_run "$name" rm -- "$p"
            fi
            ;;
        mkdir)
            ((${#pos[@]} == 1)) || die "$usage" "$EX_USAGE"
            p=$(_files_target "$name" "${pos[0]}") || exit
            data_run "$name" mkdir -- "$p"
            ;;
        mv)
            ((${#pos[@]} == 2)) || die "$usage" "$EX_USAGE"
            src=$(_files_target "$name" "${pos[0]}") || exit
            p=$(_files_target "$name" "${pos[1]}") || exit
            if data_run "$name" test -e "$p" 2>/dev/null; then die "$p already exists: refused, nothing was moved" "$EX_REFUSED"; fi
            data_run "$name" mv -- "$src" "$p"
            ;;
        edit)
            ((${#pos[@]} == 1)) || die "$usage" "$EX_USAGE"
            p=$(_files_target "$name" "${pos[0]}") || exit
            _edit "$name" "$p"
            ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac
}

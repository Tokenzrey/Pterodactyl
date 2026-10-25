#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers. Sourced by ./mcctl and by the tests, never executed.
#
# Error handling: no `set -e`. Every step that can fail is checked and ends in `die`/`return 1` with a message that says what
# to do next. Exit codes: 0 ok, 1 failure, 2 usage, 3 preflight/validation failed, 4 refused (unsafe state or declined confirm).

# shellcheck disable=SC2034  # used by the other lib files
EX_FAIL=1 EX_USAGE=2 EX_PREFLIGHT=3 EX_REFUSED=4

info() { printf '[mcctl] %s\n' "$*" >&2; }
warn() { printf '[mcctl] WARN: %s\n' "$*" >&2; }
err()  { printf '[mcctl] ERROR: %s\n' "$*" >&2; }
die()  { err "$1"; exit "${2:-$EX_FAIL}"; }

# confirm PROMPT -> 0 yes, 1 no. MCCTL_YES=1 (the --yes flag) answers yes; with no terminal and no MCCTL_YES the answer is no.
confirm() {
    local reply
    [[ ${MCCTL_YES:-0} == 1 ]] && return 0
    [[ -t 0 && -t 2 ]] || { err "confirmation required but there is no terminal; set MCCTL_YES=1 (or pass --yes) if you are sure"; return 1; }
    printf '%s [y/N] ' "$1" >&2
    read -r reply || return 1
    [[ $reply == y || $reply == Y || $reply == yes ]]
}

# mkdir_private DIR...: create with mode 700; directories it has to create on the way are 700 too (`mkdir -p -m` would only
# set the mode of the last component). A parent that already exists keeps its mode.
mkdir_private() { (umask 077 && mkdir -p -- "$@") && chmod 700 -- "$@"; }

# write_secret PATH VALUE: mode 600, atomic (temp file beside the target, then mv). VALUE never reaches a process argv.
write_secret() {
    local path=$1 value=$2 tmp
    [[ -n $path ]] || return 1
    tmp=$(umask 077 && mktemp "${path}.XXXXXX") || return 1
    if printf '%s\n' "$value" >"$tmp" && chmod 600 -- "$tmp" && mv -f -- "$tmp" "$path"; then return 0; fi
    rm -f -- "$tmp"
    return 1
}

# slugify NAME -> stdout. Same rule as lib/games.py slugify in the repo root: lower-case, each run of characters outside
# [a-z0-9] becomes one "-", trim "-", cut to 40, trim "-" again. May print nothing (a name with no usable character).
slugify() {
    local LC_ALL=C s
    s=$(printf '%s' "${1,,}" | LC_ALL=C tr -cs 'a-z0-9' '-')
    s=${s#-}; s=${s%-}; s=${s:0:40}; s=${s%-}
    printf '%s\n' "$s"
}

# valid_server_name NAME -> 0 when NAME is usable as a server name (folder, container and host label)
valid_server_name() {
    local LC_ALL=C re='^[a-z0-9][a-z0-9-]{0,39}$'
    [[ $1 =~ $re ]]
}

# write_atomic PATH [CMD ARGS...]: replace PATH with the output of CMD (default: stdin), atomically. The output goes to a temp
# file beside PATH and is moved into place only when CMD succeeded, so a failing CMD (or a full disk) leaves the old file as it
# was and no *.tmp behind. Returns CMD's status. Use the CMD form for a producer that can fail: a pipe cannot tell the
# writer that its left side failed.
write_atomic() {
    local path=${1-} tmp rc
    [[ -n $path && ! -d $path ]] || return 1
    shift
    (($#)) || set -- cat
    tmp=$(mktemp "${path}.XXXXXX.tmp") || return 1
    "$@" >"$tmp"; rc=$?
    ((rc == 0)) && { mv -f -- "$tmp" "$path"; rc=$?; }
    ((rc == 0)) || rm -f -- "$tmp"
    return "$rc"
}

# archive_safe_members ARCHIVE: check every member of the gzip tar ARCHIVE before anything is extracted from it. 0 when all are
# safe; 1 after naming each unsafe member (stderr); 2 when ARCHIVE cannot be listed. A member must be a regular file or a
# directory (`-` or `d` in the first column of `tar -tv`: a symbolic or hard link, a device or a FIFO could make the extraction
# write outside its target) with a relative name that has no `..` component and no backslash. --quoting-style=escape prints a
# newline or another control character in a name as a backslash sequence, so the backslash rule refuses those too. Names come
# from `tar -t` and only the type from `tar -tv`, paired line by line: the verbose line also holds the owner name, which tar
# does not escape (a space in it shifts the columns, a newline adds a line), so listings of different length refuse the archive.
# ponytail: outside a UTF-8 locale tar escapes non-ASCII names as well, so such archives are refused; run in a UTF-8 locale.
archive_safe_members() {
    local arch=${1-} names types n t why i bad=0
    local -a nl tl
    names=$(tar --quoting-style=escape -tzf "$arch" 2>/dev/null) && types=$(tar --quoting-style=escape -tvzf "$arch" 2>/dev/null) \
        || { err "cannot list $arch (not a readable gzip tar archive)"; return 2; }
    [[ -n $names$types ]] || return 0
    mapfile -t nl <<<"$names"; mapfile -t tl <<<"$types"
    ((${#nl[@]} == ${#tl[@]})) || { err "$arch: its two member listings differ in length (a newline in an owner name?)"; return 1; }
    for i in "${!nl[@]}"; do
        n=${nl[i]} t=${tl[i]:0:1} why=""
        case $t in
            -|d) ;;
            l) why="a symbolic link" ;;
            h) why="a hard link" ;;
            *) why="of type '$t' (only regular files and directories are allowed)" ;;
        esac
        if [[ -n $why ]]; then :
        elif [[ $n == /* ]]; then why="an absolute path"
        elif [[ /${n%/}/ == */../* ]]; then why="a path with a .. component"
        elif [[ $n == *\\* ]]; then why="a name with a backslash or a control character"
        fi
        [[ -z $why ]] || { err "$arch: unsafe member '$n': $why"; bad=1; }
    done
    return "$bad"
}

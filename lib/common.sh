#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers. Sourced by ./ptero, never executed.
#
# Error handling: no `set -e`. Every step that can fail is checked and ends in `die`/`return 1`
# with a message that says what to do next. Exit codes: 0 ok, 1 failure, 2 usage,
# 3 preflight/validation failed, 4 refused (unsafe state or declined confirmation).

# shellcheck disable=SC2034  # used by the other lib files
EX_FAIL=1 EX_USAGE=2 EX_PREFLIGHT=3 EX_REFUSED=4

info() { printf '[ptero] %s\n' "$*" >&2; }
warn() { printf '[ptero] WARN: %s\n' "$*" >&2; }
err()  { printf '[ptero] ERROR: %s\n' "$*" >&2; }
die()  { err "$1"; exit "${2:-$EX_FAIL}"; }

have() { command -v "$1" >/dev/null 2>&1; }
mkdir_private() { mkdir -p -- "$@" && chmod 700 -- "$@"; }   # `mkdir -p -m` would only set the mode of the last component
need() { have "$1" || die "required command not found: $1 ($2)" "$EX_PREFLIGHT"; }

is_root() { [[ ${EUID:-$(id -u)} -eq 0 || ${PTERO_TEST_MODE:-0} == 1 ]]; }   # PTERO_TEST_MODE is for tests/ only
need_root() { is_root || die "this command changes the host and must run as root: sudo ./ptero $*" "$EX_REFUSED"; }

# --- temp files: one private dir per run, removed on exit (it only ever contains files this run created)
PTERO_TMP=""
mktmp() {
    if [[ -z $PTERO_TMP ]]; then
        PTERO_TMP=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/ptero.XXXXXXXX") || die "cannot create a temp directory"
    fi
    printf '%s\n' "$PTERO_TMP"
}
cleanup() { [[ -n $PTERO_TMP && -d $PTERO_TMP ]] && rm -rf -- "$PTERO_TMP"; PTERO_TMP=""; }
on_signal() { err "interrupted ($1)"; cleanup; exit $((128 + $2)); }
trap cleanup EXIT
trap 'on_signal INT 2' INT
trap 'on_signal TERM 15' TERM

# --- confirmation. PTERO_YES=1 (set by --yes) skips; otherwise a real terminal is required.
# confirm "what will happen" [phrase]   -> with phrase the operator must type it exactly
confirm() {
    local msg=$1 phrase=${2:-} reply
    [[ ${PTERO_YES:-0} == 1 ]] && return 0
    [[ -t 0 && -t 2 ]] || { err "confirmation required but there is no terminal; re-run with --yes if you are sure"; return 1; }
    if [[ -n $phrase ]]; then
        printf '%s\nType %s to continue: ' "$msg" "$phrase" >&2
        read -r reply || return 1
        [[ $reply == "$phrase" ]]
    else
        printf '%s [y/N] ' "$msg" >&2
        read -r reply || return 1
        [[ $reply == y || $reply == Y || $reply == yes ]]
    fi
}

# --- polling: wait_until SECONDS "description" cmd args...
wait_until() {
    local secs=$1 what=$2 t=0; shift 2
    while ! "$@" >/dev/null 2>&1; do
        t=$((t + 3))
        if ((t > secs)); then err "timed out after ${secs}s waiting for: $what"; return 1; fi
        sleep 3
    done
}

# --- secrets never go through argv: read them from files, hide terminal echo when prompting
read_hidden() { # read_hidden "prompt" -> value on stdout
    local v
    [[ -t 0 ]] || { IFS= read -r v; printf '%s' "$v"; return; }
    printf '%s' "$1" >&2
    IFS= read -rs v; printf '\n' >&2
    printf '%s' "$v"
}

write_secret() { # write_secret path value   (mode 600, atomic)
    local path=$1 value=$2 tmp
    tmp=$(umask 077 && mktemp "${path}.XXXXXX") || return 1
    printf '%s\n' "$value" >"$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$path"
}

file_mode() { stat -c '%a' -- "$1" 2>/dev/null; }

# redact: stdin -> stdout with every known secret and token shape masked
redact() {
    local files=""
    local f
    for f in "$PTERO_ROOT"/secrets/*; do [[ -f $f ]] && files+="$f:"; done
    PTERO_REDACT_FILES="$files" python3 "$PTERO_ROOT/lib/redact.py"
}

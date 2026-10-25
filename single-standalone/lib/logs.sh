#!/usr/bin/env bash
# shellcheck shell=bash
# Live logs: mcctl logs. Sourced by ./mcctl, never executed.
#

# colorize_log_line LINE: print LINE with colour, after removing control chars (C3).
# Recognises [HH:MM:SS] [Thread/LEVEL]: message. NO_COLOR: no ESC.
colorize_log_line() {
    local line=$1 probe=${1//$'\t'/}
    # C3: control characters out. tr runs only for a line that has one; a tab is not removed, so it does not count.
    if [[ $probe == *[[:cntrl:]]* ]]; then line=$(LC_ALL=C tr -d '\000-\010\013-\037\177' <<<"$line"); fi

    if [[ -n ${NO_COLOR:-} ]]; then
        printf '%s\n' "$line"
        return 0
    fi

    local re='^\[([0-9]{2}:[0-9]{2}:[0-9]{2})\] \[([^]]*)/(INFO|WARN|ERROR|FATAL|DEBUG|TRACE)\]: (.*)$'
    if [[ $line =~ $re ]]; then
        local ts=${BASH_REMATCH[1]} thread=${BASH_REMATCH[2]} level=${BASH_REMATCH[3]} msg=${BASH_REMATCH[4]}
        local level_color="" msg_color="" reset=$'\033[0m'
        case $level in
            INFO)  level_color=$'\033[32m' ;;
            WARN)  level_color=$'\033[33m'; msg_color=$'\033[33m' ;;
            ERROR) level_color=$'\033[1;31m'; msg_color=$'\033[1;31m' ;;
            FATAL) level_color=$'\033[1;31m'; msg_color=$'\033[1;31m' ;;
            DEBUG) level_color=$'\033[2m' ;;
            TRACE) level_color=$'\033[2m' ;;
        esac
        _LOG_LAST_COLOR=$msg_color
        printf '\033[2m[%s]\033[0m [%s/%s%s%s]: %s%s%s\n' "$ts" "$thread" "$level_color" "$level" "$reset" "$msg_color" "$msg" "$reset"
    elif [[ $line == $'\t'* || $line == "at "* || $line == "Caused by:"* || $line == "..."* ]]; then
        if [[ -n ${_LOG_LAST_COLOR:-} ]]; then
            printf '%s%s\033[0m\n' "$_LOG_LAST_COLOR" "$line"
        else
            printf '%s\n' "$line"
        fi
    else
        printf '%s\n' "$line"
    fi
}

# _log_process THRESH GREP USE_COLOR: read lines on stdin, filter and colour
_log_process() {
    local thresh=$1 grep=$2 use_color=$3
    local line level level_n probe
    local re='^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] \[[^]]*/(INFO|WARN|ERROR|FATAL|DEBUG|TRACE)\]: '
    local -A lvl_num=([DEBUG]=0 [TRACE]=0 [INFO]=1 [WARN]=2 [ERROR]=3 [FATAL]=4)
    _LOG_KEEP=1
    _LOG_LAST_COLOR=""

    while IFS= read -r line || [[ -n $line ]]; do
        # C3 first: the filters and the output see the same text, so an escape sequence before the timestamp cannot hide the
        # level. A whole sequence (ESC [ ... letter) goes, not only its ESC, so no "[0m" is left in front of the timestamp.
        # sed runs only for a line with an ESC, tr only for a line with a control character (a tab does not count).
        if [[ $line == *$'\x1b'* ]]; then line=$(LC_ALL=C sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' <<<"$line"); fi
        probe=${line//$'\t'/}
        if [[ $probe == *[[:cntrl:]]* ]]; then line=$(LC_ALL=C tr -d '\000-\010\013-\037\177' <<<"$line"); fi
        if [[ -n $grep ]]; then
            [[ ${line,,} == *"${grep,,}"* ]] || continue
        fi
        if [[ -n $thresh && $thresh -gt 0 ]]; then
            if [[ $line =~ $re ]]; then
                level=${BASH_REMATCH[1]}
                level_n=${lvl_num[$level]:-0}
                if ((level_n >= thresh)); then _LOG_KEEP=1; else _LOG_KEEP=0; fi
            fi
            (( _LOG_KEEP )) || continue
        fi
        if ((use_color)); then
            colorize_log_line "$line"
        else
            printf '%s\n' "$line"
        fi
    done
}

# cmd_logs NAME [-f] [--tail N] [--level INFO|WARN|ERROR] [--grep TEXT]
cmd_logs() {
    local usage="usage: mcctl logs NAME [-f] [--tail N] [--level INFO|WARN|ERROR] [--grep TEXT]"
    local name="" follow=0 tail=100 level="" grep="" have_grep=0

    (($# >= 1)) || die "$usage" "$EX_USAGE"
    name=$1
    shift

    while (($#)); do
        case $1 in
            -f) follow=1; shift ;;
            --tail)  (($# >= 2)) || die "--tail needs a value. $usage" "$EX_USAGE"; tail=$2; shift 2 ;;
            --level) (($# >= 2)) || die "--level needs a value. $usage" "$EX_USAGE"; level=$2; shift 2 ;;
            --grep)  (($# >= 2)) || die "--grep needs a value. $usage" "$EX_USAGE"; grep=$2; have_grep=1; shift 2 ;;
            *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
        esac
    done

    _need_server "$name"

    [[ $tail =~ ^[0-9]+$ ]] || die "--tail '$tail' is not a non-negative integer. $usage" "$EX_USAGE"
    ((tail <= 100000)) || die "--tail '$tail' is too large (max 100000). $usage" "$EX_USAGE"

    local thresh=0
    if [[ -n $level ]]; then
        case ${level^^} in
            INFO)  thresh=1 ;;
            WARN)  thresh=2 ;;
            ERROR) thresh=3 ;;
            *) die "--level '$level' is not INFO, WARN or ERROR. $usage" "$EX_USAGE" ;;
        esac
    fi

    if ((have_grep)); then
        [[ -n $grep ]] || die "--grep must not be empty. $usage" "$EX_USAGE"
        ((${#grep} <= 200)) || die "--grep is too long (max 200 characters). $usage" "$EX_USAGE"
    fi

    local use_color=0
    if [[ -t 1 && -z ${NO_COLOR:-} ]]; then use_color=1; fi

    local -a dargs=(logs --tail "$tail")
    ((follow)) && dargs+=(-f)
    dargs+=("mc-$name")

    if ((follow)); then
        # Ctrl-C ends the follow with 0 (spec 4.4). The INT handler is set in a subshell, so no trap of the caller changes. It is a
        # handler, not an ignored INT: an ignored INT would be inherited by docker, and docker would not stop.
        ( trap : INT; docker "${dargs[@]}" 2>&1 | _log_process "$thresh" "$grep" "$use_color" )
        return 0
    else
        local output
        output=$(docker "${dargs[@]}" 2>&1) || {
            printf '%s\n' "$output" >&2
            die "cannot read the logs of $name (docker logs failed, see above): is the daemon running?" "$EX_FAIL"
        }
        _log_process "$thresh" "$grep" "$use_color" <<<"$output"
    fi
}

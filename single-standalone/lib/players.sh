#!/usr/bin/env bash
# shellcheck shell=bash
# Player lists and the runtime commands (Task 17): ban-ip, pardon, pardon-ip, deop, banlist, the operator list (ops), whitelist
# import and --names, and say, save, gamerule, time, weather, worldborder, difficulty and defaultgamemode. Sourced by ./mcctl,
# never executed.
#
# Each command checks its arguments first (valid_player, valid_ip, valid_runtime_arg: no Docker call on a refusal), then sends
# through _send (lib/rcon.sh). ops is the one exception: it reads servers/NAME/data/ops.json through data_run (lib/data.sh).

# ---- checks ------------------------------------------------------------------------------------------------------------------

# valid_ip ADDR: 0 when ADDR is an IPv4 address (four decimal parts, each 0 to 255, no leading zero except a lone 0) or an IPv6
# address (2 to 8 groups of 1 to 4 hex digits, at least two colons, at most one '::'; that caps it at 39 characters, so the
# 45 limit holds). Else a message and EX_USAGE, nothing on stdout.
valid_ip() {
    local LC_ALL=C a=${1-} p re_v4='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' re_big='(^|:)[0-9A-Fa-f]{5}'
    local -a g
    if [[ $a =~ $re_v4 ]]; then
        for p in "${BASH_REMATCH[@]:1}"; do
            [[ $p == 0 || $p != 0* ]] && ((10#$p <= 255)) || { err "invalid IPv4 address ${a@Q}: four parts, each 0 to 255, no leading zero"; return "$EX_USAGE"; }
        done
        return 0
    fi
    if [[ $a =~ ^[0-9A-Fa-f:]+$ && $a == *:*:* && $a != *:::* && $a != :[!:]* && $a != *[!:]: && ${a#*::} != *::* && ! $a =~ $re_big ]]; then
        read -ra g <<<"${a//:/ }"
        ((${#g[@]} >= 2 && ${#g[@]} <= 8)) && return 0
    fi
    err "invalid address ${a@Q}: an IPv4 address (1.2.3.4) or an IPv6 address (2 to 8 groups of hex digits)"
    return "$EX_USAGE"
}

# _in_range V LO HI: 0 when V is 1 to 9 digits and LO <= V <= HI (10# so that a leading zero is not read as octal)
_in_range() { [[ $1 =~ ^[0-9]{1,9}$ ]] && ((10#$1 >= $2 && 10#$1 <= $3)); }

# valid_runtime_arg KIND VALUE: 0 when VALUE is a legal argument of KIND, else a message and EX_USAGE, nothing on stdout. The one
# place the patterns of the runtime commands live. Lengths are bytes (LC_ALL=C), so non-ASCII text counts for more than one.
valid_runtime_arg() {
    local LC_ALL=C kind=${1-} v=${2-} max=0 want
    case $kind in
        say|reason)
            max=256; [[ $kind == reason ]] && max=100
            want="1 to $max characters, no control character"
            [[ -n $v && ${#v} -le $max && $v != *[[:cntrl:]]* ]] ;;
        rule)           want="a letter, then up to 63 letters, digits or '_'"; [[ $v =~ ^[A-Za-z][A-Za-z0-9_]{0,63}$ ]] ;;
        rule_value)     want="true, false or a whole number of at most 9 digits"; [[ $v =~ ^(true|false|[0-9]{1,9})$ ]] ;;
        time)           want="day, night, noon, midnight or a whole number of at most 8 digits"; [[ $v =~ ^(day|night|noon|midnight|[0-9]{1,8})$ ]] ;;
        weather)        want="clear, rain or thunder"; [[ $v =~ ^(clear|rain|thunder)$ ]] ;;
        difficulty)     want="peaceful, easy, normal or hard"; [[ $v =~ ^(peaceful|easy|normal|hard)$ ]] ;;
        gamemode)       want="survival, creative, adventure or spectator"; [[ $v =~ ^(survival|creative|adventure|spectator)$ ]] ;;
        seconds)        want="a whole number of seconds from 1 to 1000000"; _in_range "$v" 1 1000000 ;;
        border)         want="a width from 1 to 59999968"; _in_range "$v" 1 59999968 ;;
        border_seconds) want="a whole number of seconds from 0 to 1000000"; _in_range "$v" 0 1000000 ;;
        center)         want="a whole number from -29999984 to 29999984"; [[ $v =~ ^-?[0-9]{1,8}$ ]] && _in_range "${v#-}" 0 29999984 ;;
        *) return "$EX_USAGE" ;;
    esac && return 0
    err "invalid $kind ${v@Q}: expected $want"
    return "$EX_USAGE"
}

# ---- bans --------------------------------------------------------------------------------------------------------------------

# _send_with_reason VERB SERVER TARGET REASON: "VERB TARGET REASON", after REASON is checked (one argument, see valid_runtime_arg)
_send_with_reason() {
    valid_runtime_arg reason "$4" || exit "$?"
    _send "$2" "$1" "$3" "$4"
}

# cmd_ban_ip SERVER ADDR [--reason TEXT]
cmd_ban_ip() {
    if (($# == 4)) && [[ ${3-} == --reason ]]; then
        valid_ip "$2" || exit "$?"
        _send_with_reason ban-ip "$1" "$2" "$4"
    else
        (($# == 2)) || die "usage: mcctl ban-ip SERVER ADDR [--reason TEXT]" "$EX_USAGE"
        valid_ip "$2" || exit "$?"
        _send "$1" ban-ip "$2"
    fi
}

# cmd_pardon SERVER PLAYER, cmd_deop SERVER PLAYER: the player wrappers of lib/rcon.sh
cmd_pardon() { _player_cmd pardon "$@"; }
cmd_deop()   { _player_cmd deop "$@"; }

# cmd_pardon_ip SERVER ADDR
cmd_pardon_ip() {
    (($# == 2)) || die "usage: mcctl pardon-ip SERVER ADDR" "$EX_USAGE"
    valid_ip "$2" || exit "$?"
    _send "$1" pardon-ip "$2"
}

# cmd_banlist SERVER [--names]: the server's reply; with --names, the name or address of each entry, one per line
cmd_banlist() {
    if (($# == 2)) && [[ ${2-} == --names ]]; then
        _banlist_names "$1"
    else
        (($# == 1)) || die "usage: mcctl banlist SERVER [--names]" "$EX_USAGE"
        _send "$1" banlist
    fi
}

# ---- the lists ---------------------------------------------------------------------------------------------------------------

# _whitelist_names SERVER: the names in "There are N whitelisted players: a, b", one per line; a reply with no list prints nothing
_whitelist_names() {
    local r
    r=$(_send "$1" whitelist list) || exit "$?"
    [[ $r == *": "* ]] || return 0
    r=${r#*: }
    r=${r//, /$'\n'}
    printf '%s\n' "$r"
}

# _banlist_names SERVER: the name or address of each entry ("Notch was banned by Server: reason"), one per line
_banlist_names() {
    local r line
    r=$(_send "$1" banlist) || exit "$?"
    while IFS= read -r line; do
        if [[ $line == *" was banned by "* ]]; then printf '%s\n' "${line%% was banned by *}"; fi
    done <<<"$r"
}

# _whitelist_import SERVER FILE: "whitelist add" for each name in FILE, one per line. Blank lines and lines starting with '#' are
# skipped, and a CR at the end of a line is dropped. The whole file is checked before anything is sent, and a bad line is refused
# by its number, never by its text. At most 500 lines. A progress line every 50 names.
_whitelist_import() {
    local srv=$1 file=$2 line i
    local -a lines names=()
    mapfile -t lines 2>/dev/null <"$file" || die "cannot read $file: give a text file with one player name per line" "$EX_USAGE"
    ((${#lines[@]} <= 500)) || die "$file has ${#lines[@]} lines: at most 500 are imported at a time, split the file" "$EX_USAGE"
    for ((i = 0; i < ${#lines[@]}; i++)); do
        line=${lines[i]%$'\r'}
        [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
        valid_player "$line" || die "$file line $((i + 1)): not a player name (1 to 16 letters, digits, '_' or '.'): nothing was sent" "$EX_USAGE"
        names+=("$line")
    done
    for ((i = 1; i <= ${#names[@]}; i++)); do
        _send "$srv" whitelist add "${names[i - 1]}"
        if ((i % 50 == 0)); then info "whitelist import: $i of ${#names[@]} names sent"; fi
    done
    info "whitelist import: ${#names[@]} names sent from $file"
}

# ---- operators ---------------------------------------------------------------------------------------------------------------

# cmd_ops SERVER: the operators named in servers/NAME/data/ops.json, read through the helper container. Works on a stopped server.
cmd_ops() {
    local json names rc=0
    (($# == 1)) || die "usage: mcctl ops SERVER" "$EX_USAGE"
    _need_server "$1"
    json=$(data_run "$1" cat -- ops.json) || rc=$?
    if ((rc != 0)); then
        # cat exits 1 for a missing file (no operator was ever made); any other status is Docker failing, and its message is above
        ((rc == 1)) || die "cannot read ops.json of $1 (see above)"
        echo "no operators"
        return 0
    fi
    names=$(jq -r '.[].name' <<<"$json") || die "cannot read the names in ops.json of $1 (see above): it must be JSON, and jq must be installed"
    if [[ -n $names ]]; then printf '%s\n' "$names"; else echo "no operators"; fi
}

# ---- runtime commands --------------------------------------------------------------------------------------------------------

# cmd_say SERVER MESSAGE
cmd_say() {
    (($# == 2)) || die "usage: mcctl say SERVER MESSAGE" "$EX_USAGE"
    valid_runtime_arg say "$2" || exit "$?"
    _send "$1" say "$2"
}

# cmd_save SERVER: write the world to disk now
cmd_save() {
    (($# == 1)) || die "usage: mcctl save SERVER" "$EX_USAGE"
    _send "$1" save-all flush
}

# cmd_gamerule SERVER RULE [VALUE]: set a game rule, or read it when there is no VALUE
cmd_gamerule() {
    (($# == 2 || $# == 3)) || die "usage: mcctl gamerule SERVER RULE [true|false|N]" "$EX_USAGE"
    valid_runtime_arg rule "$2" || exit "$?"
    if (($# == 3)); then
        valid_runtime_arg rule_value "$3" || exit "$?"
        _send "$1" gamerule "$2" "$3"
    else
        _send "$1" gamerule "$2"
    fi
}

# cmd_time SERVER set day|night|noon|midnight|N
cmd_time() {
    (($# == 3)) && [[ $2 == set ]] || die "usage: mcctl time SERVER set day|night|noon|midnight|N" "$EX_USAGE"
    valid_runtime_arg time "$3" || exit "$?"
    _send "$1" time set "$3"
}

# cmd_weather SERVER clear|rain|thunder [SECONDS]
cmd_weather() {
    (($# == 2 || $# == 3)) || die "usage: mcctl weather SERVER clear|rain|thunder [SECONDS]" "$EX_USAGE"
    valid_runtime_arg weather "$2" || exit "$?"
    if (($# == 3)); then
        valid_runtime_arg seconds "$3" || exit "$?"
        _send "$1" weather "$2" "$3"
    else
        _send "$1" weather "$2"
    fi
}

# cmd_worldborder SERVER get | set SIZE [SECONDS] | center X Z
cmd_worldborder() {
    local usage="usage: mcctl worldborder SERVER get | set SIZE [SECONDS] | center X Z"
    case ${2-} in
        get)
            (($# == 2)) || die "$usage" "$EX_USAGE"
            _send "$1" worldborder get ;;
        set)
            (($# == 3 || $# == 4)) || die "$usage" "$EX_USAGE"
            valid_runtime_arg border "$3" || exit "$?"
            if (($# == 4)); then
                valid_runtime_arg border_seconds "$4" || exit "$?"
                _send "$1" worldborder set "$3" "$4"
            else
                _send "$1" worldborder set "$3"
            fi ;;
        center)
            (($# == 4)) || die "$usage" "$EX_USAGE"
            valid_runtime_arg center "$3" || exit "$?"
            valid_runtime_arg center "$4" || exit "$?"
            _send "$1" worldborder center "$3" "$4" ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac
}

# cmd_difficulty SERVER peaceful|easy|normal|hard [--persist]: the change on the running server. --persist also stores it in
# server.env, where mcctl apply picks it up (the config is pending until then). The runtime change comes first: when it fails,
# nothing is stored.
cmd_difficulty() {
    local persist=0
    if (($# == 3)) && [[ ${3-} == --persist ]]; then persist=1; fi
    (($# == 2 || persist)) || die "usage: mcctl difficulty SERVER peaceful|easy|normal|hard [--persist]" "$EX_USAGE"
    valid_runtime_arg difficulty "$2" || exit "$?"
    _send "$1" difficulty "$2"
    ((persist)) || return 0
    server_env_set "$1" DIFFICULTY "$2" || die "cannot write server.env of $1 (see above): the running server has the new difficulty, the stored one does not"
    info "$1: config pending: mcctl apply $1"
}

# cmd_defaultgamemode SERVER survival|creative|adventure|spectator
cmd_defaultgamemode() {
    (($# == 2)) || die "usage: mcctl defaultgamemode SERVER survival|creative|adventure|spectator" "$EX_USAGE"
    valid_runtime_arg gamemode "$2" || exit "$?"
    _send "$1" defaultgamemode "$2"
}

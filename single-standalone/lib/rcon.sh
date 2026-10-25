#!/usr/bin/env bash
# shellcheck shell=bash
# RCON, the console and player management. Sourced by ./mcctl, never executed.
#
# One raw primitive, rcon_exec; every command here is a thin layer over it. mcctl never handles the RCON password: it runs
# `docker exec -i mc-NAME rcon-cli CMD...` and rcon-cli, inside the container, finds the password itself. The password is a random
# file, secrets/rcon-NAME (mode 600, made once per server by `create`), that compose hands to the game container and to its backup
# sidecar as RCON_PASSWORD_FILE. It is never printed, never in an argument, and is replaced by `mcctl rotate-rcon`.
# Nothing a player or an operator types reaches RCON before it was checked: valid_player for names, check_rcon_words for text.

# ---- the secret --------------------------------------------------------------------------------------------------------------

# _write_rcon_secret NAME: replace secrets/rcon-NAME with a new random password (32 letters and digits, mode 600, owned by the game's user:
# the server container reads it as that user). The new file is written beside the old one, given to the game's user, and only then
# moved into place: a failure leaves the old password where it was.
_write_rcon_secret() {
    local name=${1-} f pw tmp
    _need_name "$name" || return
    f=$MCCTL_ROOT/secrets/rcon-$name
    [[ ! -d $f ]] || { err "$f is a directory (Docker makes one when a bind-mounted file is missing): remove it, then run this again"; return 1; }
    mkdir_private "$MCCTL_ROOT/secrets" || return
    pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    ((${#pw} == 32)) || { err "cannot read random bytes for the RCON password"; return 1; }
    tmp=$(umask 077 && mktemp "$f.XXXXXX") || return 1
    if printf '%s\n' "$pw" >"$tmp" && chmod 600 -- "$tmp" && _give_to_game "$tmp" && mv -f -- "$tmp" "$f"; then return 0; fi
    rm -f -- "$tmp"
    return 1
}

# ensure_rcon_secret NAME: 0 when secrets/rcon-NAME holds a password; makes one when the file is missing or empty
ensure_rcon_secret() {
    _need_name "${1-}" || return
    [[ -s $MCCTL_ROOT/secrets/rcon-$1 && -f $MCCTL_ROOT/secrets/rcon-$1 ]] && return 0
    _write_rcon_secret "$1"
}

# ---- checks ------------------------------------------------------------------------------------------------------------------

# valid_player NAME: 0 when NAME can be a player name: 1 to 16 letters, digits, '_' or '.' (Java names; Bedrock names through
# Floodgate start with '.'). No space, '@' (a selector), '-' or quote, so a name is never more than one word of one command.
valid_player() {
    local LC_ALL=C re='^[.A-Za-z0-9_]{1,16}$'
    [[ ${1-} =~ $re ]]
}

# check_rcon_words WORD...: 0 when WORD... can be one RCON command; else a message and EX_USAGE, nothing on stdout. There must be
# a first word, and it may not start with '-' (rcon-cli would read it as one of its own options). No word may hold a control
# character: a newline would end the command and could begin another.
check_rcon_words() {
    local LC_ALL=C w
    (($#)) && [[ -n $1 ]] || { err "no command to send"; return "$EX_USAGE"; }
    [[ $1 != -* ]] || { err "an RCON command cannot start with '-' (rcon-cli would read it as an option)"; return "$EX_USAGE"; }
    for w; do
        [[ $w != *[[:cntrl:]]* ]] || { err "a newline or other control character cannot be sent over RCON"; return "$EX_USAGE"; }
    done
}

# _need_player NAME: exit EX_USAGE, before any Docker call, for a name valid_player refuses
_need_player() {
    local p=${1-}
    valid_player "$p" || die "invalid player name ${p@Q}: 1 to 16 letters, digits, '_' or '.'" "$EX_USAGE"
}

# _need_running NAME: exit EX_FAIL, saying how to start it, unless the game container of NAME is running
_need_running() {
    local c st
    c=$(container_name "${1-}") || exit "$EX_USAGE"
    st=$(docker inspect --format '{{.State.Status}}' "$c") || die "cannot inspect $c"
    [[ $st == running ]] || die "$1 is not running (state: ${st:-unknown}): start it with: mcctl start $1"
}

# ---- the primitive -----------------------------------------------------------------------------------------------------------

# rcon_exec NAME CMD...: send the command to the server NAME; stdout is the server's reply. Returns rcon-cli's status, or
# EX_USAGE for a command check_rcon_words refuses. The caller makes sure the server is running.
rcon_exec() {
    local c
    c=$(container_name "${1-}") || return
    shift
    check_rcon_words "$@" || return
    docker exec -i "$c" rcon-cli "$@"
}

# _send NAME WORD...: the checks every command below makes (the text first, so a refusal asks Docker nothing), then rcon_exec
_send() {
    local name=${1-}
    shift
    check_rcon_words "$@" || exit $?
    _need_server "$name"
    _need_running "$name"
    rcon_exec "$name" "$@" || die "rcon-cli failed on $name (see above). A server that has just started needs a minute before it answers: mcctl status $name shows its health"
}

# ---- commands ----------------------------------------------------------------------------------------------------------------

# cmd_rcon NAME COMMAND [ARGS...]: any RCON command, the server's reply on stdout
cmd_rcon() {
    (($# >= 2)) || die "usage: mcctl rcon NAME COMMAND [ARGS...]   (example: mcctl rcon survival say hello)" "$EX_USAGE"
    _send "$@"
}

# cmd_console NAME: the server console, interactively (leave it with Ctrl-D)
cmd_console() {
    (($# == 1)) || die "usage: mcctl console NAME" "$EX_USAGE"
    _need_server "$1"
    _need_running "$1"
    _have_terminal || die "the console needs a terminal; to send one command use: mcctl rcon $1 COMMAND" "$EX_USAGE"
    docker exec -it "$(container_name "$1")" rcon-cli
}
_have_terminal() { [[ -t 0 && -t 1 ]]; }   # a function so that a test can stand in for a terminal

# _player_cmd VERB SERVER PLAYER: send "VERB PLAYER". The player is checked before anything else happens.
_player_cmd() {
    local verb=$1
    shift
    (($# == 2)) || die "usage: mcctl $verb SERVER PLAYER" "$EX_USAGE"
    _need_player "$2"
    _send "$1" "$verb" "$2"
}
# cmd_ban SERVER PLAYER [--reason TEXT]: the reason is one argument, checked in lib/players.sh (not a positional word: that form is refused)
cmd_ban() {
    if (($# == 4)) && [[ ${3-} == --reason ]]; then
        _need_player "$2"
        _send_with_reason ban "$1" "$2" "$4"
    else
        _player_cmd ban "$@"
    fi
}
cmd_kick() { _player_cmd kick "$@"; }
cmd_op()   { _player_cmd op "$@"; }

# cmd_whitelist add|remove SERVER PLAYER, list [--names]|on|off|reload SERVER, or import SERVER FILE (lib/players.sh)
cmd_whitelist() {
    local usage="usage: mcctl whitelist add|remove SERVER PLAYER   or   mcctl whitelist list [--names]|on|off|reload SERVER   or   mcctl whitelist import SERVER FILE" act=${1-}
    case $act in
        add|remove) (($# == 3)) || die "$usage" "$EX_USAGE"; _need_player "$3"; _send "$2" whitelist "$act" "$3" ;;
        list)
            if (($# == 3)) && [[ $3 == --names ]]; then _whitelist_names "$2"
            else (($# == 2)) || die "$usage" "$EX_USAGE"; _send "$2" whitelist list; fi ;;
        on|off|reload) (($# == 2)) || die "$usage" "$EX_USAGE"; _send "$2" whitelist "$act" ;;
        import) (($# == 3)) || die "$usage" "$EX_USAGE"; _whitelist_import "$2" "$3" ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac
}

# cmd_players NAME: who is online (the server's own `list` reply)
cmd_players() {
    (($# == 1)) || die "usage: mcctl players NAME" "$EX_USAGE"
    _send "$1" list
}

# cmd_rotate_rcon NAME: a new RCON password. The server and its backup sidecar read it when they start, so a running server has
# to restart: that disconnects its players, hence the question first, and nothing is changed on a no. A stopped server just gets
# the new file.
cmd_rotate_rcon() {
    (($# == 1)) || die "usage: mcctl rotate-rcon NAME" "$EX_USAGE"
    local name=$1 st
    _need_server "$name"
    st=$(docker inspect --format '{{.State.Status}}' "$(container_name "$name")") || die "cannot inspect mc-$name"
    if [[ $st == running ]]; then
        confirm "Restart $name to give it a new RCON password? Its players are disconnected." \
            || die "$name was not changed: the RCON password stays as it is" "$EX_REFUSED"
    fi
    _write_rcon_secret "$name" || die "cannot write secrets/rcon-$name; the old password is unchanged"
    if [[ $st != running ]]; then
        info "$name: new RCON password written; it applies when the server next starts"
        return 0
    fi
    dc "$name" restart || die "the new RCON password is written but 'docker compose restart' failed (see above); it applies once you run: mcctl restart $name"
    info "$name: new RCON password in use (restarted)"
}

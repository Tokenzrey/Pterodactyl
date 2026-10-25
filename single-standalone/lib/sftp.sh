#!/usr/bin/env bash
# shellcheck shell=bash
# Shared SFTP container (atmoz/sftp): one container, one chrooted user per server. Sourced by ./mcctl, never executed.
#
# SFTP is its own compose project, mcctl-sftp, so the router stack keeps exactly one published port. Its file is GENERATED:
# templates/sftp.compose.yml is the template, sftp_render writes MCCTL_ROOT/sftp.compose.yml from it, and nobody edits that by hand.
# The state is three things under MCCTL_ROOT: sftp-users.conf (one line per user), sftp-keys/NAME (the public keys of NAME) and the
# generated compose file. Each user has two bind mounts: servers/NAME/data -> /home/NAME/NAME (read-write) and, once a key exists,
# sftp-keys/NAME -> /home/NAME/.ssh/keys/NAME.pub (read-only; the place atmoz/sftp reads keys from). The mount is left out while
# the key file does not exist, because Docker would make a directory of a missing bind-mount source.
# Key-only login: the password field of every user is empty. The port is 127.0.0.1:2222 unless MCCTL_SFTP_PUBLIC=1 (then 0.0.0.0).
# atmoz/sftp reads users and keys only when it starts, so a change recreates the container when it runs (a few seconds without SFTP).

SFTP_PROJECT=mcctl-sftp
SFTP_TMPL=$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates" 2>/dev/null && pwd -P)/sftp.compose.yml

# _sftp_users_file -> stdout: the path to the users.conf of the sftp container
_sftp_users_file() { printf '%s/sftp-users.conf\n' "$MCCTL_ROOT"; }

# _sftp_keys_dir -> stdout: the directory holding the public keys, one file per server
_sftp_keys_dir() { printf '%s/sftp-keys\n' "$MCCTL_ROOT"; }

# _sftp_compose_file -> stdout: the generated compose file
_sftp_compose_file() { printf '%s/sftp.compose.yml\n' "$MCCTL_ROOT"; }

# _sftp_bind -> stdout: the address the SFTP port is published on
_sftp_bind() { if [[ ${MCCTL_SFTP_PUBLIC:-0} == 1 ]]; then echo 0.0.0.0; else echo 127.0.0.1; fi; }

# sftp_dc ARGS...: docker compose for the SFTP project
sftp_dc() { docker compose -p "$SFTP_PROJECT" -f "$(_sftp_compose_file)" "$@"; }

# _sftp_vol SRC DST [MODE] -> stdout: one volume line of the compose file, escaped (compose_escape). EX_PREFLIGHT, with no output,
# for a path that cannot be written safely: one with a control character, or with a ':' (it would end the host path).
_sftp_vol() {
    local v
    [[ $1 != *:* ]] || { err "the path ${1@Q} holds a ':', which a compose volume cannot carry"; return "$EX_PREFLIGHT"; }
    v=$(compose_escape "$1:$2${3:+:$3}") || return "$EX_PREFLIGHT"
    printf '      - "%s"\n' "$v"
}

# _sftp_render_file -> stdout: the compose YAML for the users in sftp-users.conf. Pure: writes no file, and prints nothing at all
# when it fails (EX_PREFLIGHT: a path, or a line of users.conf, that cannot be written safely).
_sftp_render_file() {
    local users keys line name n=0 data v mounts=""
    local -A tv=()
    users=$(_sftp_users_file)
    keys=$(_sftp_keys_dir)
    tv[SFTP_BIND]=$(_sftp_bind)
    tv[USERS_MOUNT]=$(_sftp_vol "$users" /etc/sftp/users.conf ro) || return
    if [[ -f $users ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            n=$((n + 1))
            [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
            name=${line%%:*}
            valid_server_name "$name" || { err "$users:$n: ${name@Q} is not a server name"; return "$EX_PREFLIGHT"; }
            data=$MCCTL_ROOT/servers/$name/data
            [[ -d $data ]] || { warn "$name: $data does not exist, so $name has nothing to share over SFTP"; continue; }
            v=$(_sftp_vol "$data" "/home/$name/$name") || return
            mounts+=${mounts:+$'\n'}$v
            if [[ -f $keys/$name ]]; then
                v=$(_sftp_vol "$keys/$name" "/home/$name/.ssh/keys/$name.pub" ro) || return
                mounts+=$'\n'$v
            fi
        done <"$users"
    fi
    tv[SERVER_MOUNTS]=$mounts
    _fill_template "$SFTP_TMPL" tv
}

# sftp_render: write sftp.compose.yml (mode 644, atomically) from the template and users.conf. A failing render leaves the old
# file as it was. Also makes sure sftp-users.conf exists: Docker would otherwise make a directory of the missing mount source.
sftp_render() {
    local out users file
    users=$(_sftp_users_file)
    file=$(_sftp_compose_file)
    out=$(_sftp_render_file) || return
    write_atomic "$file" printf '%s\n' "$out" && chmod 644 -- "$file" || { err "cannot write $file"; return "$EX_FAIL"; }
    [[ -f $users ]] || (umask 077; : >"$users") || { err "cannot create $users"; return "$EX_FAIL"; }
}

# _sftp_running: 0 when the SFTP container is running
_sftp_running() { [[ -n $(sftp_dc ps -q --status running sftp 2>/dev/null) ]]; }

# sftp_repair: render sftp.compose.yml again and, when the SFTP container is running, recreate it so that it reads the new users and
# keys. Every change to SFTP ends here; `mcctl sftp repair` runs it by hand after the cause of a failure was fixed.
sftp_repair() {
    sftp_render || return
    _sftp_running || return 0
    sftp_dc up -d --force-recreate sftp >/dev/null || { err "docker compose could not recreate the SFTP container (see above)"; return "$EX_FAIL"; }
    info "SFTP container recreated; SFTP users are disconnected for a few seconds"
}

# sftp_up: start the SFTP stack (rendering its file first) when there is at least one user; sftp_down: stop it. For mcctl up and
# mcctl down. With no user the container is not started: atmoz/sftp exits at once when users.conf is empty (its entrypoint's grep
# has no line to copy and set -e stops it).
sftp_up() {
    sftp_render || return
    if [[ -s $(_sftp_users_file) ]]; then sftp_dc up -d
    else info "SFTP not started: no user yet (a server created with SFTP access adds one)"; fi
}
sftp_down() { sftp_render && sftp_dc down; }

# sftp_add_user NAME: add NAME to users.conf (UID/GID 1000:1000, the itzg/minecraft-server user; no password; the directory field is
# the bare name, which atmoz/sftp creates under /home/NAME), then render and recreate when running.
sftp_add_user() {
    local name=${1-} users keys dir line
    valid_server_name "$name" || { err "invalid server name ${name@Q}"; return "$EX_USAGE"; }
    dir=$MCCTL_ROOT/servers/$name/data
    [[ -d $dir ]] || { err "$dir does not exist; create the server first"; return "$EX_FAIL"; }
    users=$(_sftp_users_file)
    keys=$(_sftp_keys_dir)
    mkdir_private "$keys"
    # Remove any existing entry for this user (idempotent), then append. grep -v exits 1 when no line is left (fine) and 2 when it
    # cannot read users.conf: then the partial users.tmp must not replace it.
    if [[ -f $users ]]; then
        grep -v "^$name:" "$users" >"$users.tmp"
        (($? < 2)) || { rm -f -- "$users.tmp"; err "cannot read $users; nothing was changed"; return "$EX_FAIL"; }
        mv -f "$users.tmp" "$users"
    fi
    # atmoz/sftp users.conf format: username:password:uid:gid:dir1,dir2,...  The password is empty (key-only login).
    line="$name::1000:1000:$name"
    printf '%s\n' "$line" >>"$users"
    chmod 600 "$users"
    sftp_repair || return
    info "$name: SFTP user added (key-only, UID 1000; servers/$name/data is /home/$name/$name)"
}

# sftp_remove_user NAME: remove the user line and the key file, then render and recreate when running. A name that has neither
# changes nothing and calls nothing.
sftp_remove_user() {
    local name=${1-} users keys had=0
    valid_server_name "$name" || return "$EX_USAGE"
    users=$(_sftp_users_file)
    keys=$(_sftp_keys_dir)
    if [[ -f $users ]]; then
        ! grep -q "^$name:" "$users" || had=1
        grep -v "^$name:" "$users" >"$users.tmp"   # status 1 (no line left) is fine, 2 (cannot read) is not: see sftp_add_user
        (($? < 2)) || { rm -f -- "$users.tmp"; err "cannot read $users; nothing was changed"; return "$EX_FAIL"; }
        mv -f "$users.tmp" "$users"
    fi
    [[ ! -e $keys/$name ]] || had=1
    rm -f -- "$keys/$name"
    ((had)) || return 0
    sftp_repair
}

# _valid_pubkey FILE: 0 when FILE looks like an OpenSSH public key
_valid_pubkey() {
    local f=${1-} first
    [[ -f $f ]] || return 1
    read -r first _ <"$f" 2>/dev/null
    case $first in
        ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) return 0 ;;
    esac
    return 1
}

# cmd_sftp add-key NAME PUBKEYFILE | remove-key NAME | repair
cmd_sftp() {
    local usage="usage: mcctl sftp add-key NAME PUBKEYFILE | remove-key NAME | repair"
    local sub=${1-} name keyfile keys keypath rc
    shift || true
    case $sub in
        add-key)
            (($# == 2)) || die "usage: mcctl sftp add-key NAME PUBKEYFILE" "$EX_USAGE"
            name=$1 keyfile=$2
            valid_server_name "$name" || die "invalid server name ${name@Q}" "$EX_USAGE"
            _valid_pubkey "$keyfile" || die "$keyfile is not an OpenSSH public key (expected ssh-rsa, ssh-ed25519, ecdsa-sha2-*, etc.)" "$EX_USAGE"
            keys=$(_sftp_keys_dir)
            keypath=$keys/$name
            mkdir_private "$keys"
            # Append the key (multiple keys per user are allowed)
            cat -- "$keyfile" >>"$keypath"
            chmod 600 "$keypath"
            sftp_repair || { rc=$?; die "$name: the key is in $keypath, but SFTP was not updated (see above): run 'mcctl sftp repair' after fixing the cause" "$rc"; }
            info "$name: SSH key installed for SFTP access"
            ;;
        remove-key)
            (($# == 1)) || die "usage: mcctl sftp remove-key NAME" "$EX_USAGE"
            name=$1
            valid_server_name "$name" || die "invalid server name ${name@Q}" "$EX_USAGE"
            keypath=$(_sftp_keys_dir)/$name
            rm -f -- "$keypath"
            sftp_repair || { rc=$?; die "$name: the key file is removed, but SFTP was not updated (see above): run 'mcctl sftp repair' after fixing the cause" "$rc"; }
            info "$name: SFTP keys removed; $name can no longer log in over SFTP"
            ;;
        repair)
            (($# == 0)) || die "usage: mcctl sftp repair" "$EX_USAGE"
            sftp_repair || { rc=$?; die "SFTP was not updated (see above)" "$rc"; }
            info "SFTP: $(_sftp_compose_file) is up to date"
            ;;
        *)
            die "$usage" "$EX_USAGE"
            ;;
    esac
}

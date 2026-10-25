#!/usr/bin/env bash
# shellcheck shell=bash
# Server lifecycle: create, start, stop, restart, kill, delete, list, status. Sourced by ./mcctl, never executed.
#
# Docker is the record. A server exists when a container carries the label mcctl.name=NAME (the generated compose file puts it
# there); servers/NAME only holds its files, and nothing here reads servers/ to find out which servers exist. The three helpers
# that ask Docker die, rather than answer "none", when Docker cannot be asked: a dead daemon must never look like a free name.

EULA_URL=https://aka.ms/MinecraftEULA

# ---- asking Docker -----------------------------------------------------------------------------------------------------------

# _ids_by_label LABEL=VALUE: set _IDS to the ids of the containers (running or not) that carry the label
_ids_by_label() {
    _IDS=$(docker ps -a -q --filter "label=$1") \
        || die "cannot ask Docker ('docker ps' failed): is the daemon running, and may this user use it? Nothing was changed."
}

# server_exists NAME: 0 when Docker has a container for the server NAME, else 1 (also for a name that cannot be a server)
server_exists() { valid_server_name "${1-}" && _ids_by_label "mcctl.name=$1" && [[ -n $_IDS ]]; }

# hostname_taken HOST: 0 when a container already uses HOST as its mcctl.hostname label
hostname_taken() { valid_server_name "${1-}" && _ids_by_label "mcctl.hostname=$1" && [[ -n $_IDS ]]; }

# hostname_owner HOST -> stdout the name of a server that uses HOST (for messages)
hostname_owner() { docker ps -a --filter "label=mcctl.hostname=$1" --format '{{.Label "mcctl.name"}}' | head -n 1; }

# server_label NAME KEY -> stdout the value of label KEY on the game container of NAME (empty when it has no such label)
server_label() {
    local c k=${2-}
    c=$(container_name "${1-}") || return
    [[ $k =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { err "invalid label key ${k@Q}"; return "$EX_USAGE"; }
    docker inspect --format '{{index .Config.Labels "'"$k"'"}}' "$c"
}

# _need_server NAME: exit EX_USAGE for a name that cannot be a server, EX_FAIL when Docker has no such server
_need_server() {
    _need_name "${1-}" || exit "$EX_USAGE"
    server_exists "$1" || die "no server named '$1' (mcctl list shows the servers)"
}

# ---- removing what a server owns ---------------------------------------------------------------------------------------------

# _remove_files NAME: delete servers/NAME and its RCON secret secrets/rcon-NAME (the container is the caller's business)
_remove_files() {
    local name=${1-}
    sftp_remove_user "$name" || warn "$name: SFTP could not be updated (see above): run 'mcctl sftp repair' after fixing the cause"   # lib/sftp.sh; the user line, the key, the mounts. Never blocks the delete
    valid_server_name "$name" || return "$EX_USAGE"
    rm -rf -- "$MCCTL_ROOT/servers/$name" || return 1
    rm -f -- "$MCCTL_ROOT/secrets/rcon-$name"
}

# _create_undo NAME HOST: take back a create that failed half way, in reverse order. A `compose create` can fail after it made one
# of the two containers, so they go first; only when that worked are the DNS record, the folder and the secret removed, so a
# container is never left without its folder or its record. When it did not work all of them stay, and `mcctl delete NAME`
# finishes the job. A DNS record that cannot be deleted does not keep the folder: `mcctl delete NAME` finds the record by its comment.
_create_undo() {
    local name=$1 host=$2
    if [[ -f $MCCTL_ROOT/servers/$name/compose.yaml ]] && ! dc "$name" rm -s -f >/dev/null; then
        warn "could not remove the containers made for $name, so servers/$name, its secret and the DNS record $(fqdn_for "$host") were kept: run 'mcctl delete $name' once Docker works"
        return 1
    fi
    cf_delete_record "$host" "$name" || warn "the DNS record $(fqdn_for "$host") is left over: run 'mcctl delete $name' to remove it"
    _remove_files "$name"
}

# _create_fail NAME HOST MESSAGE: report, undo, and exit EX_FAIL
_create_fail() {
    err "$3"
    _create_undo "$1" "$2"
    exit "$EX_FAIL"
}

# ---- create ------------------------------------------------------------------------------------------------------------------

# _provision NAME HOST WRITE_FN: the steps create, clone and import share, in this order. The name and the host are checked against Docker
# (nothing is touched when one is taken); then the DNS record; the folders (data, backups, and the attach points mods and plugins, mode
# 755: attach_dir, lib/compose.sh); the RCON secret; "WRITE_FN NAME HOST" (the server's files; it calls _create_fail itself when one
# fails); compose.yaml; the SFTP user; `compose create`; mc-router is told. A failure after the DNS record takes back what was done
# (_create_fail, in reverse order).
_provision() {
    local name=$1 host=$2 write=$3 dir rc
    dir=$MCCTL_ROOT/servers/$name
    server_exists "$name" && die "server $name already exists (mcctl list shows the servers)" "$EX_REFUSED"
    hostname_taken "$host" && die "hostname $host is already used by server $(hostname_owner "$host"): pick another one with --hostname" "$EX_REFUSED"
    [[ ! -e $dir && ! -L $dir ]] \
        || die "$dir exists but Docker has no server $name: a leftover of an interrupted create or delete. Look inside it, then run: mcctl delete $name" "$EX_REFUSED"

    # -- the DNS record first: when it cannot be made, nothing has been written
    cf_create_record "$host" "$name" >/dev/null || {
        rc=$?; ((rc == EX_REFUSED)) || rc=$EX_FAIL
        die "no DNS record for $(fqdn_for "$host") (see above), so nothing was created" "$rc"
    }

    # -- write the files; from here on a failure takes back the files and the record
    mkdir_private "$MCCTL_ROOT/servers" "$MCCTL_ROOT/secrets" "$dir" "$dir/data" "$dir/backups" || _create_fail "$name" "$host" "cannot create $dir"
    attach_dir "$name" mods >/dev/null && attach_dir "$name" plugins >/dev/null \
        || _create_fail "$name" "$host" "cannot create the mods and plugins folders of $name (see above)"
    _write_rcon_secret "$name" || _create_fail "$name" "$host" "cannot write secrets/rcon-$name"   # lib/rcon.sh; a stale file of that name is replaced
    "$write" "$name" "$host"
    write_compose "$name" || _create_fail "$name" "$host" "cannot render $dir/compose.yaml (see above)"
    sftp_add_user "$name" || warn "$name: SFTP could not be set up (see above); the server is created anyway: run 'mcctl sftp repair' after fixing the cause"   # lib/sftp.sh; SFTP never blocks a create
    dc "$name" create || _create_fail "$name" "$host" "docker compose create failed (see above); nothing was kept"
    router_reload || _create_fail "$name" "$host" "mc-router could not be told about $name ('docker compose kill -s HUP mc-router' failed, see above); nothing was kept"
}

# cmd_create NAME --type T --accept-eula [--version V] [--memory 4G] [--cpus 2] [--hostname H]
#                 [--modpack-source curseforge|modrinth --modpack ID [--modpack-version V]]
# Order: validate every flag and the configuration (nothing is touched) -> check name and hostname against Docker -> the DNS
# record -> write the files -> `compose create` (the container now exists, stopped: from here on Docker is the record) ->
# router_reload. Any failure after the DNS record takes back what was done, in reverse order (_create_undo).
cmd_create() {
    local usage="usage: mcctl create NAME --type TYPE --accept-eula [--version V] [--memory 4G] [--cpus 2] [--hostname H] [--modpack-source curseforge|modrinth --modpack ID [--modpack-version V]] [--backup local|s3|rsync] [--backup-interval 24h]"
    local name=${1-} type="" version="" mem=4G cpus=2 host="" eula=0 src="" pack="" packver="" want="" bad=0 slug mpenv=""
    local backup_method="" backup_interval=""
    (($# > 0)) && [[ ! $1 =~ ^--[a-z] ]] || die "NAME is missing (it comes right after create). $usage" "$EX_USAGE"
    shift
    while (($#)); do
        case $1 in
            --accept-eula) eula=1; shift; continue ;;
            --type|--version|--memory|--cpus|--hostname|--modpack-source|--modpack|--modpack-version|--backup|--backup-interval) ;;
            *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
        esac
        (($# >= 2)) || die "$1 needs a value. $usage" "$EX_USAGE"
        case $1 in
            --type) type=${2^^} ;;
            --version) version=$2 ;;
            --memory) mem=$2 ;;
            --cpus) cpus=$2 ;;
            --hostname) host=$2 ;;
            --modpack-source) src=$2 ;;
            --modpack) pack=$2 ;;
            --modpack-version) packver=$2 ;;
            --backup) backup_method=$2 ;;
            --backup-interval) backup_interval=$2 ;;
        esac
        shift 2
    done

    # -- validate: every problem is reported, nothing is touched
    if ! valid_server_name "$name"; then
        slug=$(slugify "$name")
        if [[ -z $slug ]]; then
            err "server name ${name@Q} has no letter or digit, so no name can be made from it (use lower-case letters, digits and '-')"
        else
            err "invalid server name ${name@Q}: use lower-case letters, digits and '-', start with a letter or digit, at most 40 characters (try: $slug)"
        fi
        bad=1
    fi
    case $src in
        "")         [[ -z $pack$packver ]] || { err "--modpack and --modpack-version need --modpack-source curseforge|modrinth"; bad=1; } ;;
        curseforge) want=AUTO_CURSEFORGE ;;
        modrinth)   want=MODRINTH ;;
        *)          err "--modpack-source ${src@Q} is neither curseforge nor modrinth"; bad=1 ;;
    esac
    if [[ -n $want ]]; then
        [[ -n $type ]] || type=$want
        [[ $type == "$want" ]] || { err "--modpack-source $src runs as --type $want (leave --type out), not $type"; bad=1; }
        mpenv=$(modpack_env "$src" "$pack" "$packver") || bad=1   # lib/modpack.sh checks --modpack and --modpack-version and says what is wrong
    elif [[ -z $type ]]; then
        err "--type is required (for example PAPER, FABRIC, FORGE or VANILLA)"; bad=1; type=VANILLA
    fi
    # a modpack decides its own game version; a plain server runs the latest unless told otherwise
    [[ -n $version || -n $want ]] || version=LATEST
    [[ -n $host ]] || host=$(slugify "$name")
    SE_CTX="mcctl create" check_server_values "$type" "$version" "$mem" "$cpus" TRUE "${host:-x}" "" || bad=1
    ((eula)) || { err "the Minecraft EULA ($EULA_URL) must be accepted to run a server: read it, then add --accept-eula"; bad=1; }
    case $backup_method in
        ""|local|s3|rsync) ;;
        *) err "--backup ${backup_method@Q} is neither local, s3 nor rsync"; bad=1 ;;
    esac
    if [[ -n $backup_interval ]]; then
        [[ $backup_interval =~ ^[0-9]+[smhd]?$ ]] || { err "--backup-interval ${backup_interval@Q} is not a duration (e.g. 24h, 30m, 2h, 7d)"; bad=1; }
    fi
    ((bad == 0)) || { err "$usage"; exit "$EX_USAGE"; }
    cf_ready   # lib/cloudflare.sh: MCCTL_DOMAIN, MCCTL_PUBLIC_IPV4, MCCTL_CF_ZONE_ID, curl, jq and the token, or exit 3
    [[ $src != curseforge ]] || modpack_require_key   # lib/modpack.sh: exit 3 when the key file is empty or missing

    _provision "$name" "$host" _create_files
    info "created $name (stopped). Start it with: mcctl start $name; players join at $host.$MCCTL_DOMAIN"
    dns_hint "$host.$MCCTL_DOMAIN"
}

# _create_files NAME HOST: the files of a create (the WRITE_FN of _provision). It reads the flags that cmd_create parsed (type, version,
# mem, cpus, src, mpenv, backup_method, backup_interval) from cmd_create's locals, as bash's dynamic scope allows.
_create_files() {
    local name=$1 host=$2 dir lines=() benv_lines=""
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    lines=("TYPE=$type")
    [[ -z $version ]] || lines+=("VERSION=$version")
    lines+=("MEMORY=$mem" "CPUS=$cpus" "HOSTNAME_SLUG=$host" "EULA=TRUE")
    if [[ -n $backup_method ]]; then
        [[ -z $backup_interval ]] && backup_interval=24h
        case $backup_method in
            local)
                benv_lines="BACKUP_METHOD=tar
BACKUP_INTERVAL=$backup_interval
INITIAL_DELAY=2m
PRUNE_BACKUPS_COUNT=7" ;;
            s3)
                benv_lines="BACKUP_METHOD=restic
BACKUP_INTERVAL=$backup_interval
INITIAL_DELAY=2m
PRUNE_RESTIC_RETENTION=--keep-within 7d
RESTIC_PASSWORD_FILE=/run/secrets/restic_password
AWS_ACCESS_KEY_ID_FILE=/run/secrets/aws_access_key_id
AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/aws_secret_access_key" ;;
            rsync)
                benv_lines="BACKUP_METHOD=rsync
BACKUP_INTERVAL=$backup_interval
INITIAL_DELAY=2m
PRUNE_BACKUPS_COUNT=7" ;;
        esac
        lines+=("BACKUP_ENV_FILE=backup.env")
    fi
    write_atomic "$dir/server.env" printf '%s\n' "# Written by mcctl create. mcctl reads this file; it never runs it." "${lines[@]}" \
        || _create_fail "$name" "$host" "cannot write $dir/server.env"
    if [[ -n $src ]]; then
        write_atomic "$dir/modpack.env" printf '%s\n' "$mpenv" || _create_fail "$name" "$host" "cannot write $dir/modpack.env"
    fi
    if [[ -n $backup_method ]]; then
        write_atomic "$dir/backup.env" printf '%s\n' "$benv_lines" || _create_fail "$name" "$host" "cannot write $dir/backup.env"
    fi
}

# ---- start, stop, restart, kill ----------------------------------------------------------------------------------------------

# _lifecycle VERB NAME: `docker compose VERB` for both containers of NAME (the game server and its backup sidecar)
_lifecycle() {
    local verb=$1
    shift
    (($# == 1)) || die "usage: mcctl $verb NAME" "$EX_USAGE"
    _need_server "$1"
    dc "$1" "$verb" || die "docker compose $verb failed for $1 (see above)"
    info "$1: $verb done"
}
cmd_start()   { _lifecycle start "$@"; }
cmd_stop()    { _lifecycle stop "$@"; }
cmd_restart() { _lifecycle restart "$@"; }

# cmd_kill NAME: SIGKILL, no save. Asks first, because whatever the server had not saved is lost.
cmd_kill() {
    (($# == 1)) || die "usage: mcctl kill NAME" "$EX_USAGE"
    _need_server "$1"
    confirm "Kill $1 now? It gets no chance to save: progress since its last save is lost and the world can be damaged. 'mcctl stop $1' saves first." \
        || die "$1 was not killed" "$EX_REFUSED"
    dc "$1" kill || die "docker compose kill failed for $1 (see above)"
    info "$1: killed"
}

# ---- edit --------------------------------------------------------------------------------------------------------------------

# _env_put_body FILE KEY VALUE [KEY VALUE...]: print FILE with each KEY= line replaced by KEY=VALUE; every other line (comments included)
# is kept byte for byte, and a KEY that is not in FILE is appended, in argument order. Used through write_atomic by server_env_set.
_env_put_body() {
    local file=$1 line k
    local -A new=() seen=()
    local -a keys=()
    shift
    while (($# >= 2)); do keys+=("$1"); new[$1]=$2; shift 2; done
    if [[ -r $file ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            k=${line%%=*}
            if [[ -n $k && $line == *=* && -n ${new[$k]+x} ]]; then
                printf '%s=%s\n' "$k" "${new[$k]}"
                seen[$k]=1
            else
                printf '%s\n' "$line"
            fi
        done <"$file"
    fi
    for k in "${keys[@]}"; do
        [[ -n ${seen[$k]+x} ]] || printf '%s=%s\n' "$k" "${new[$k]}"
    done
}

# server_env_set NAME KEY VALUE [KEY VALUE...]: write the pairs into servers/NAME/server.env in one write (write_atomic). Nothing else
# in the file changes. Renders nothing: see _env_write_compose.
server_env_set() {
    local dir
    dir=$(server_dir "${1-}") || return
    write_atomic "$dir/server.env" _env_put_body "$dir/server.env" "${@:2}"
}

# server_env_unset NAME KEY...: remove the KEY= lines from servers/NAME/server.env in one write (write_atomic). Nothing else in the file
# changes, and nothing is rendered (see _env_write_compose).
server_env_unset() {
    local dir re="" k
    dir=$(server_dir "${1-}") || return
    (($# >= 2)) || return "$EX_USAGE"
    for k in "${@:2}"; do
        [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || return "$EX_USAGE"
        re+=${re:+|}$k
    done
    write_atomic "$dir/server.env" sed -E "/^($re)=/d" "$dir/server.env"
}

# _env_write_compose NAME OLD_ENV: render compose.yaml of NAME. When that fails, server.env is put back to OLD_ENV (its text before the
# change) and the command dies; nothing is recreated.
_env_write_compose() {
    local name=$1 old=$2 dir
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    write_compose "$name" && return 0
    printf '%s' "$old" | write_atomic "$dir/server.env" \
        || die "cannot render $dir/compose.yaml (see above), and server.env could not be put back: check it by hand (the new values are in it)" "$EX_FAIL"
    die "cannot render $dir/compose.yaml (see above); server.env was put back as it was" "$EX_FAIL"
}

# RECREATE_LIVE: set by _recreate_guard, read by _recreate_apply. 1 when the game container of the server runs (or restarts, or pauses).
RECREATE_LIVE=0

# _recreate_guard NAME: decides whether the containers of NAME may be recreated now (they are, with a stopped server, at no cost). A
# running one: when nobody is online, the question is asked (confirm); when players are online, or the answer cannot be read, --yes
# (MCCTL_YES=1) is required, else exit 4. Changes nothing itself.
_recreate_guard() {
    local name=$1 c st reply n rrc
    c=$(container_name "$name") || exit "$EX_USAGE"
    st=$(docker inspect --format '{{.State.Status}}' "$c") || die "cannot inspect $c"
    RECREATE_LIVE=0
    case $st in
        running|restarting|paused) RECREATE_LIVE=1 ;;
        *) return 0 ;;
    esac
    reply=$(rcon_exec "$name" list 2>/dev/null); rrc=$?
    if ((rrc == 0)) && [[ $reply =~ There\ are\ ([0-9]+)\ of\ a\ max ]]; then
        n=${BASH_REMATCH[1]}
        info "$name: $n players online"
        if ((n > 0)); then
            [[ ${MCCTL_YES:-0} == 1 ]] || die "$name has $n players online; pass --yes to restart it and apply the change" "$EX_REFUSED"
        else
            confirm "Restart $name now to apply the change?" \
                || die "$name was not changed: nothing was changed" "$EX_REFUSED"
        fi
    else
        info "$name: could not ask who is online"
        [[ ${MCCTL_YES:-0} == 1 ]] || die "$name may have players online; pass --yes to restart it and apply the change" "$EX_REFUSED"
    fi
}

# _recreate_apply NAME: recreate the containers of NAME from the files as they are: a running server with up -d --force-recreate (then
# mc-router is told; a failure there only warns), a stopped one with create --force-recreate. Uses RECREATE_LIVE from _recreate_guard.
_recreate_apply() {
    local name=$1
    if ((RECREATE_LIVE)); then
        dc "$name" up -d --force-recreate \
            || die "the files are already written but docker compose up failed (see above); run the same command again to re-apply" "$EX_FAIL"
        router_reload || warn "could not signal mc-router (see above): the container is already up with the new settings"
        info "$name: applied (restarted)"
    else
        dc "$name" create --force-recreate \
            || die "the files are already written but docker compose create failed (see above); run the same command again to re-apply" "$EX_FAIL"
        info "$name: applied (recreated, still stopped)"
    fi
}

# cmd_edit NAME [--memory SIZE] [--cpus N]: change the memory and CPU limits of a server. Regenerates server.env and compose.yaml
# and recreates the containers so the new limits take effect. Never restarts a server with players online unless --yes (the global
# flag, read as MCCTL_YES) is given. A stopped server is recreated with create --force-recreate. Order: validate, ask, write,
# then recreate. A "no" or a refusal changes nothing on disk.
cmd_edit() {
    local usage="usage: mcctl edit NAME [--memory SIZE] [--cpus N]"
    local name=${1-} opt_mem="" opt_cpus="" have_mem=0 have_cpus=0
    (($# > 0)) && [[ ! $1 =~ ^--[a-z] ]] || die "NAME is missing (it comes right after edit). $usage" "$EX_USAGE"
    name=$1
    shift
    while (($#)); do
        case $1 in
            --memory|--cpus) ;;
            *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
        esac
        (($# >= 2)) || die "$1 needs a value. $usage" "$EX_USAGE"
        case $1 in
            --memory) opt_mem=$2; have_mem=1 ;;
            --cpus)   opt_cpus=$2; have_cpus=1 ;;
        esac
        shift 2
    done
    ((have_mem || have_cpus)) || die "at least one of --memory or --cpus is required. $usage" "$EX_USAGE"

    _need_server "$name"
    local dir
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    [[ -f $dir/server.env ]] || die "no $dir/server.env" "$EX_FAIL"

    local lines line srv_type version mem cpus host eula benv
    local -A se=()
    lines=$(kv_lines "$dir/server.env") || die "$dir/server.env is not a valid server.env (see above)" "$EX_USAGE"
    while IFS= read -r line; do [[ -z $line ]] || se[${line%%=*}]=${line#*=}; done <<<"$lines"
    srv_type=${se[TYPE]:-VANILLA}
    version=${se[VERSION]:-}
    mem=${se[MEMORY]:-2G}
    cpus=${se[CPUS]:-2}
    host=${se[HOSTNAME_SLUG]:-$name}
    eula=${se[EULA]:-FALSE}
    benv=${se[BACKUP_ENV_FILE]:-}
    ((have_mem)) || opt_mem=$mem
    ((have_cpus)) || opt_cpus=$cpus
    SE_CTX="mcctl edit" check_server_values "$srv_type" "$version" "$opt_mem" "$opt_cpus" "$eula" "$host" "$benv" \
        || { err "$usage"; exit "$EX_USAGE"; }

    _recreate_guard "$name"

    local old_env env_ok=1
    old_env=$(cat "$dir/server.env"; printf X); old_env=${old_env%X}
    if ((have_mem)); then server_env_set "$name" MEMORY "$opt_mem" || env_ok=0; fi
    if ((env_ok && have_cpus)); then server_env_set "$name" CPUS "$opt_cpus" || env_ok=0; fi
    if ((!env_ok)); then
        # MEMORY may be written when CPUS fails, so the saved text is the undo (not a key-by-key one); nothing is rendered or recreated
        printf '%s' "$old_env" | write_atomic "$dir/server.env" \
            || die "cannot write $dir/server.env, and it could not be put back as it was (see above); check it by hand" "$EX_FAIL"
        die "cannot write $dir/server.env; server.env was put back as it was" "$EX_FAIL"
    fi
    _env_write_compose "$name" "$old_env"
    _recreate_apply "$name"
}

# ---- delete ------------------------------------------------------------------------------------------------------------------

# _archive DIR ARCHIVE MEMBER...: DIR/MEMBER... as a tar.gz at ARCHIVE (mode 600; written beside it and moved into place, so a
# failing tar leaves nothing), then read back in full with tar -tzf. 1, with no archive left, when either step fails.
_archive() {
    local dir=$1 arch=$2
    shift 2
    mkdir_private "${arch%/*}" || return 1
    write_atomic "$arch" tar -czf - -C "$dir" "$@" || { err "tar could not archive $dir"; return 1; }
    tar -tzf "$arch" >/dev/null || { err "the archive $arch does not read back"; rm -f -- "$arch"; return 1; }
}

# cmd_delete NAME: in this order, each step safe to repeat: stop the containers; archive data/ and backups/ to
# trash/NAME-<UTC>.tar.gz and read it back; delete the DNS records mcctl made for NAME; remove the containers; tell mc-router; delete
# servers/NAME and secrets/rcon-NAME. The DNS records go before the containers so that no record is ever left pointing at a server
# that is gone: when the archive or the DNS step fails, delete stops and nothing has been removed (the server is only stopped), so
# running it again starts clean. With nothing left of NAME but its DNS records (a create whose clean-up could not reach Cloudflare),
# delete removes those.
cmd_delete() {
    (($# == 1)) || die "usage: mcctl delete NAME" "$EX_USAGE"
    local name=$1 dir arch="" what
    local -a keep=()
    _need_name "$name" || exit "$EX_USAGE"
    cf_ready
    dns_on || info "DNS is off: no DNS record is touched. A record made while DNS was on stays in Cloudflare until you remove it there"
    dir=$MCCTL_ROOT/servers/$name
    if ! server_exists "$name" && [[ ! -e $dir && ! -L $dir ]]; then
        _delete_dns "$name" || die "the DNS record of $name could not be deleted (see above): run 'mcctl delete $name' again once Cloudflare answers"
        ((CF_FOUND > 0)) || die "no server named '$name' (mcctl list shows the servers)"
        info "$name: only its DNS record was left, and it is removed"
        return 0
    fi
    [[ -d $dir/data ]] && keep+=(data)
    [[ -d $dir/backups ]] && keep+=(backups)
    [[ -d $dir/safety ]] && keep+=(safety)
    # ponytail: trash/ is never pruned, it grows until its files are removed by hand; add 'mcctl trash prune --older-than' when disk matters
    if ((${#keep[@]})); then
        arch=$MCCTL_ROOT/trash/$name-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
        what="its world, mods and backups (${keep[*]}) are first archived to $arch, which stays until you remove it"
    else
        what="it has no data/ or backups/ to archive"
    fi
    confirm "Delete $name? Its containers, its DNS record and its RCON secret are removed and $dir is deleted; $what." \
        || die "$name was not deleted" "$EX_REFUSED"

    # 1. stop, so that the archive does not catch a world that is being written
    if [[ -f $dir/compose.yaml ]]; then
        dc "$name" stop || die "docker compose stop failed for $name (see above); nothing was deleted"
    elif server_exists "$name"; then
        die "Docker has containers for $name but $dir/compose.yaml is missing, so mcctl cannot remove them; remove mc-$name and mc-$name-backup with docker, then run this again"
    fi
    # 2. the archive; without it nothing is removed
    if [[ -n $arch ]]; then
        _archive "$dir" "$arch" "${keep[@]}" \
            || die "could not archive $dir to $arch (see above), so nothing was deleted; $name is stopped (mcctl start $name)" "$EX_REFUSED"
    fi
    # 3. DNS, before the containers: when it fails nothing has been removed
    _delete_dns "$name" \
        || die "the DNS record of $name could not be deleted (see above), so nothing was removed: $name is stopped and its containers and $dir are as they were${arch:+ (its archive is $arch)}. Run 'mcctl delete $name' again once Cloudflare answers"
    # 4. the containers
    if [[ -f $dir/compose.yaml ]]; then
        dc "$name" rm -s -f || die "docker compose rm failed for $name (see above): its DNS record is deleted, its containers and $dir are still there${arch:+ (its archive is $arch)}. Run 'mcctl delete $name' again"
    fi
    # 5. the router: a failure is reported, but the containers are gone, so their folder goes too
    local ok=1
    router_reload || { warn "could not signal mc-router (see above): it may keep a route to $name until it restarts"; ok=0; }
    # 6. the files
    _remove_files "$name" || die "could not delete $dir (files owned by another user? remove it by hand, then run this again)"
    if ((ok)); then
        info "$name: deleted${arch:+. Its world, mods and backups are in $arch: remove that file when you no longer need it}"
        return 0
    fi
    err "$name: deleted, but mc-router was not signalled${arch:+ (its world, mods and backups are in $arch)}"
    exit "$EX_FAIL"
}

# _delete_dns NAME: the DNS records of NAME (cf_delete_server, which deletes by id only records whose comment, as Cloudflare answered
# it, is exactly "mcctl name=NAME"). 1 when one of them could not be deleted or Cloudflare could not be asked; each is named above.
_delete_dns() { cf_delete_server "$1"; }

# ---- list, status ------------------------------------------------------------------------------------------------------------

# cmd_list: one row per container that carries mcctl.managed=true. Docker answers; servers/ is never read.
cmd_list() {
    (($# == 0)) || die "usage: mcctl list" "$EX_USAGE"
    local rows name state addr status
    rows=$(docker ps -a --filter label=mcctl.managed=true \
        --format '{{.Label "mcctl.name"}}|{{.State}}|{{.Label "mc-router.host"}}|{{.Status}}') \
        || die "cannot ask Docker ('docker ps' failed): is the daemon running, and may this user use it?"
    if [[ -z $rows ]]; then info "no servers yet: mcctl create NAME --type PAPER --accept-eula"; return 0; fi
    printf '%-24s %-10s %-40s %s\n' NAME STATE ADDRESS STATUS
    while IFS='|' read -r name state addr status; do
        [[ -z $name ]] || printf '%-24s %-10s %-40s %s\n' "$name" "$state" "$addr" "$status"
    done < <(sort <<<"$rows")
}

# cmd_status NAME: what Docker says about the game container of NAME
cmd_status() {
    (($# == 1)) || die "usage: mcctl status NAME" "$EX_USAGE"
    _need_server "$1"
    local c line state health addr image since have want cfg
    c=$(container_name "$1")
    line=$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{index .Config.Labels "mc-router.host"}}|{{.Config.Image}}|{{.State.StartedAt}}|{{index .Config.Labels "mcctl.config_hash"}}' "$c") \
        || die "cannot inspect $c"
    IFS='|' read -r state health addr image since have <<<"$line"
    want=$(config_hash "$1" 2>/dev/null) || want=""
    if [[ -z $want ]]; then cfg="unknown (server.env does not render; mcctl apply $1 shows why)"
    elif [[ -z $have ]]; then cfg="unknown (created before tracking; mcctl apply $1 stamps it)"
    elif [[ $have == "$want" ]]; then cfg=current
    else cfg="pending (mcctl apply $1)"
    fi
    printf 'server:    %s\n' "$1"
    printf 'container: %s (%s%s)\n' "$c" "$state" "${health:+, $health}"
    printf 'address:   %s\n' "$addr"
    printf 'image:     %s\n' "$image"
    printf 'config:    %s\n' "$cfg"
    [[ $state != running ]] || printf 'started:   %s\n' "$since"
}

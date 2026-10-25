#!/usr/bin/env bash
# shellcheck shell=bash
# info, clone, rename, export, import, exec and shell: what a server is, copies and moves of a whole server (files, DNS record,
# containers), a portable archive, and commands in the game container. Sourced by ./mcctl, never executed.
#
# clone and import are made by _provision (lib/servers.sh), so a failure takes them back as a create does. rename is a list of steps,
# each with an undo: a failure runs the undo of every step that ran, newest first (_rn_rollback). A running server whose data/ is read
# is quiesced by _quiesced (autosave off, then on from a trap). An archive is checked by archive_safe_members before anything is read
# from it on the host; data/ is only ever written by the helper container (data_pipe).

# _game_user: set _GAME_USER to UID:UID, the user the game runs as (MCCTL_UID, 1000 by default: the itzg image's user, under its root
# entry point). Dies on a value that is not a number from 1 to 65535.
_game_user() {
    local uid=${MCCTL_UID:-1000}
    [[ $uid =~ ^[1-9][0-9]{0,4}$ ]] && ((uid <= 65535)) \
        || die "MCCTL_UID=${uid@Q} must be a number from 1 to 65535 (the user the game runs as; the itzg image's user is 1000)" "$EX_PREFLIGHT"
    _GAME_USER="$uid:$uid"
}

# _kib NAME PATH -> stdout the size of PATH in data/ of NAME, in KiB (du in the helper); 1 when it cannot be measured
_kib() {
    local out
    out=$(data_run "$1" du -sk -- "$2" 2>/dev/null) || return 1
    out=${out%%[[:space:]]*}
    [[ $out =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$out"
}

# ---- info ----------------------------------------------------------------------------------------------------------------------

# cmd_info NAME: what the server is and holds, read from its files and from Docker. Works on a stopped server. A size reads "unknown"
# when the helper cannot measure it. config is the comparison of `mcctl status` (config_hash against the label on the container).
cmd_info() {
    (($# == 1)) || die "usage: mcctl info NAME" "$EX_USAGE"
    _need_server "$1"
    local name=$1 dir c line state since have want cfg up t lvl size dsize method newest pack host
    local -A se=() mp=() bk=()
    dir=$(server_dir "$name") && c=$(container_name "$name") || exit "$EX_USAGE"
    kv_read "$dir/server.env" se
    [[ -f $dir/modpack.env ]] && kv_read "$dir/modpack.env" mp
    [[ -f $dir/backup.env ]] && kv_read "$dir/backup.env" bk
    line=$(docker inspect --format '{{.State.Status}}|{{.State.StartedAt}}|{{index .Config.Labels "mcctl.config_hash"}}' "$c") \
        || die "cannot inspect $c (see above)"
    IFS='|' read -r state since have <<<"$line"

    want=$(config_hash "$name" 2>/dev/null) || want=""
    if [[ -z $want || -z $have ]]; then cfg=unknown
    elif [[ $have == "$want" ]]; then cfg=current
    else cfg=pending
    fi
    up=""
    if [[ $state == running ]] && t=$(date -u -d "$since" +%s 2>/dev/null); then
        t=$(($(date -u +%s) - t))
        up=$(printf ', up %dh%02dm' $((t / 3600)) $((t % 3600 / 60)))
    fi
    lvl=$(active_world "$name") || lvl=unknown
    size=$(_kib "$name" "$lvl") && size="$size KiB" || size=unknown
    dsize=$(_kib "$name" .) && dsize="$dsize KiB" || dsize=unknown
    method=${bk[BACKUP_METHOD]:-none}
    newest=$(cd "$dir/backups" 2>/dev/null && ls -t 2>/dev/null | head -n 1)
    [[ -z $newest ]] || newest=$(stat -c %y -- "$dir/backups/$newest" 2>/dev/null)
    newest=${newest%%.*}
    if [[ -n ${mp[MOD_PLATFORM]:-} ]]; then pack="${mp[MOD_PLATFORM]} ${mp[CF_SLUG]:-${mp[MODRINTH_MODPACK]:-?}}"; else pack=none; fi
    host=${se[HOSTNAME_SLUG]:-$name}

    printf 'server:    %s\n' "$name"
    printf 'type:      %s\n' "${se[TYPE]:-VANILLA}"
    printf 'version:   %s\n' "${se[VERSION]:-LATEST}"
    printf 'modpack:   %s\n' "$pack"
    printf 'memory:    %s\n' "${se[MEMORY]:-2G}"
    printf 'cpus:      %s\n' "${se[CPUS]:-2}"
    printf 'hostname:  %s (%s)\n' "$host" "$(fqdn_for "$host")"
    printf 'state:     %s%s\n' "$state" "$up"
    printf 'config:    %s\n' "$cfg"
    printf 'world:     %s, %s\n' "$lvl" "$size"
    printf 'data:      %s\n' "$dsize"
    printf 'backup:    %s, newest file %s\n' "$method" "${newest:-none}"
}

# ---- the live quiesce ----------------------------------------------------------------------------------------------------------

# _quiesced NAME CMD...: run CMD, which reads NAME's data/, with autosave off when NAME runs: save-off, save-all flush, CMD, then save-on
# from an EXIT trap, so save-on also runs when CMD fails or INT or TERM arrives (as _snapshot_live in lib/worlds.sh). A stopped NAME runs
# CMD as it is. 1, with a message, when the state cannot be read or save-off fails (CMD is then not run).
# ponytail: the same bracket as _snapshot_live, which writes its own archive; fold the two into one when lib/worlds.sh is next changed.
_quiesced() {
    local name=$1 st rc=0
    shift
    st=$(_server_state "$name") && [[ -n $st ]] \
        || { err "cannot read the state of $(container_name "$name") (docker inspect failed): nothing was done"; return 1; }
    case $st in
        running|restarting|paused) ;;
        *) "$@"; return ;;
    esac
    rcon_exec "$name" save-off >/dev/null || { err "autosave state unknown: run mcctl rcon $name save-on"; return 1; }
    (
        trap 'rcon_exec "$name" save-on >/dev/null || { err "autosave state unknown: run mcctl rcon $name save-on"; exit 1; }' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        rcon_exec "$name" save-all flush >/dev/null || { err "autosave state unknown: run mcctl rcon $name save-on"; exit 1; }
        "$@"
    ) || rc=$?
    return "$rc"
}

# ---- clone -----------------------------------------------------------------------------------------------------------------------

# cmd_clone NAME NEW [--with-data] [--hostname H]: a second server from NAME, made stopped. It copies server.env (with the new hostname),
# modpack.env, backup.env, lists/, mods/ and plugins/; never secrets/ (it gets its own RCON password) and never backups/. --with-data
# copies the world too (data/, helper to helper). A running NAME is then quiesced for the copy, and needs a confirmation (or --yes).
cmd_clone() {
    local usage="usage: mcctl clone NAME NEW [--with-data] [--hostname H]"
    local src=${1-} new=${2-} host="" data=0
    (($# >= 2)) || die "$usage" "$EX_USAGE"
    shift 2
    while (($#)); do
        case $1 in
            --with-data) data=1 ;;
            --hostname) (($# >= 2)) || die "--hostname needs a value. $usage" "$EX_USAGE"; host=$2; shift ;;
            *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
        esac
        shift
    done
    _need_server "$src"
    _need_name "$new" || exit "$EX_USAGE"
    [[ $new != "$src" ]] || die "NEW must differ from NAME ($src)" "$EX_USAGE"
    [[ -n $host ]] || host=$(slugify "$new")
    { valid_server_name "$host" && [[ $host != *- ]]; } \
        || die "hostname ${host@Q} is not a DNS label (lower-case letters, digits and '-', not ending in '-')" "$EX_USAGE"
    cf_ready
    if ((data)) && [[ $(_server_state "$src") =~ ^(running|restarting|paused)$ ]]; then
        confirm "$src is running: its world is copied with autosave off (save-off, then save-on when the copy ends). Copy it?" \
            || die "$src was not cloned: nothing was changed (pass --yes to copy a running server)" "$EX_REFUSED"
    fi
    _provision "$new" "$host" _clone_files
    info "cloned $src to $new (stopped). Start it with: mcctl start $new; players join at $(fqdn_for "$host")"
    dns_hint "$(fqdn_for "$host")"
}

# _clone_files NEW HOST: the files of a clone (the WRITE_FN of _provision). It reads $src and $data from cmd_clone (dynamic scope).
_clone_files() {
    local new=$1 host=$2 sdir ddir f d
    sdir=$(server_dir "$src") && ddir=$(server_dir "$new") || _create_fail "$new" "$host" "cannot find the folders of $src and $new"
    write_atomic "$ddir/server.env" _env_put_body "$sdir/server.env" HOSTNAME_SLUG "$host" \
        || _create_fail "$new" "$host" "cannot write $ddir/server.env"
    # the voice chat port belongs to one server: the clone has none until mcctl voice NEW set PORT gives it one
    server_env_unset "$new" VOICE_PORT || _create_fail "$new" "$host" "cannot write $ddir/server.env (see above)"
    for f in modpack.env backup.env; do
        [[ ! -f $sdir/$f ]] || write_atomic "$ddir/$f" cat -- "$sdir/$f" || _create_fail "$new" "$host" "cannot copy $f to $ddir"
    done
    # cp -p keeps the modes: a jar must stay readable by the game's user (644). mods and plugins exist already (_provision)
    for d in lists mods plugins; do
        [[ -d $sdir/$d ]] || continue
        cp -Rp -- "$sdir/$d/." "$ddir/$d" || _create_fail "$new" "$host" "cannot copy $sdir/$d (see above)"
    done
    if ((data)); then
        _quiesced "$src" _clone_data "$src" "$new" || _create_fail "$new" "$host" "the world of $src could not be copied (see above)"
    fi
}

# _clone_data SRC NEW: data/ of SRC into data/ of NEW, streamed between two helper containers (nothing is extracted on the host)
_clone_data() { data_run "$1" tar -cf - -C /data . | data_pipe "$2" tar -xf - --no-same-owner -C /data; }

# ---- rename ----------------------------------------------------------------------------------------------------------------------

# _rn_rollback: run the undo of every step that ran, newest first (done_steps, a local of cmd_rename, holds the step numbers in order)
_rn_rollback() {
    local i
    for ((i = ${#done_steps[@]} - 1; i >= 0; i--)); do _rn_undo "${done_steps[i]}"; done
}

# _rn_fail RC MESSAGE...: report, take back the steps that ran, exit RC
_rn_fail() {
    local rc=$1
    shift
    err "$*"
    _rn_rollback
    exit "$rc"
}

# _rn_undo STEP: take back one step of cmd_rename (it reads cmd_rename's locals: old, new, host, oldhost, ran, dir_o, dir_n, sec_o, sec_n,
# keys, key_moved, sftp_old, old_env, old_compose). A failing undo is a warning that says what is left; the other undos still run.
_rn_undo() {
    case $1 in
        1)  if [[ $host == "$oldhost" ]]; then
                cf_relabel_record "$host" "$new" "$old" >/dev/null \
                    || warn "the DNS record $(fqdn_for "$host") still says 'mcctl name=$new': set it back to 'mcctl name=$old' by hand"
            else
                cf_delete_record "$host" "$new" || warn "the DNS record $(fqdn_for "$host") of $new is left: 'mcctl delete $new' removes it"
            fi ;;
        3)  dc "$old" start || warn "could not start $old again: mcctl start $old" ;;
        4)  dc "$old" create >/dev/null || warn "could not create the containers of $old again: mcctl apply $old, once Docker works" ;;
        5)  mv -- "$dir_n" "$dir_o" || warn "the folder is still $dir_n: move it back to $dir_o by hand"
            if ((sftp_old)); then sftp_add_user "$old" >/dev/null || warn "the SFTP user of $old is not back: mcctl sftp repair"; fi ;;
        6)  mv -- "$sec_n" "$sec_o" || warn "the RCON secret is still $sec_n: move it back to $sec_o by hand" ;;
        7)  if ((key_moved)); then mv -- "$keys/$new" "$keys/$old" || warn "the SFTP key is still $keys/$new: move it back by hand"; fi
            sftp_remove_user "$new" || warn "the SFTP user $new is left: mcctl sftp repair" ;;
        8)  write_atomic "$dir_n/server.env" printf '%s' "$old_env" || warn "server.env of $new could not be put back as it was (see above)"
            write_atomic "$dir_n/compose.yaml" printf '%s' "$old_compose" || warn "compose.yaml of $new could not be put back (see above)" ;;
        9)  dc "$new" rm -s -f >/dev/null || warn "the containers of $new are left: docker compose -p mcctl-$new rm -s -f" ;;
    esac
}

# cmd_rename NAME NEW [--hostname H] [--yes]: the server under the name NEW. Its containers are removed and made again, its folder, RCON
# secret, SFTP user and SFTP key move to NEW, its server.env and compose.yaml are rewritten for NEW, and its DNS record moves to the
# hostname NEW (or H; the same hostname relabels the record). A running server is stopped first and started again at the end. Each step
# has an undo (see _rn_undo); a failure takes back the steps that ran, so the server is left as NAME or as NEW, never neither.
cmd_rename() {
    local usage="usage: mcctl rename NAME NEW [--hostname H] [--yes]"
    local old=${1-} new=${2-} host="" oldhost="" ran=0 st what rc
    local dir_o dir_n sec_o sec_n keys old_env old_compose key_moved=0 sftp_old=0
    local -a done_steps=()
    local -A se=()
    (($# >= 2)) || die "$usage" "$EX_USAGE"
    shift 2
    while (($#)); do
        case $1 in
            --hostname) (($# >= 2)) || die "--hostname needs a value. $usage" "$EX_USAGE"; host=$2; shift ;;
            *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
        esac
        shift
    done
    _need_server "$old"
    _need_name "$new" || exit "$EX_USAGE"
    [[ $new != "$old" ]] || die "NEW must differ from NAME ($old)" "$EX_USAGE"
    cf_ready
    dir_o=$(server_dir "$old") && dir_n=$(server_dir "$new") || exit "$EX_USAGE"
    [[ -f $dir_o/server.env && -f $dir_o/compose.yaml ]] \
        || die "$dir_o has no server.env or compose.yaml: rename needs a server that mcctl created (mcctl delete $old removes it)" "$EX_FAIL"
    kv_read "$dir_o/server.env" se
    oldhost=${se[HOSTNAME_SLUG]:-$old}
    [[ -n $host ]] || host=$(slugify "$new")
    { valid_server_name "$host" && [[ $host != *- ]]; } \
        || die "hostname ${host@Q} is not a DNS label (lower-case letters, digits and '-', not ending in '-')" "$EX_USAGE"

    # -- checks: nothing is changed by any of them
    server_exists "$new" && die "server $new already exists (mcctl list shows the servers)" "$EX_REFUSED"
    [[ ! -e $dir_n && ! -L $dir_n && ! -e $MCCTL_ROOT/secrets/rcon-$new ]] \
        || die "$dir_n or secrets/rcon-$new is there, but Docker has no server $new: a leftover of an interrupted create or delete. Look inside it, then run: mcctl delete $new" "$EX_REFUSED"
    if [[ $host != "$oldhost" ]] && hostname_taken "$host"; then
        die "hostname $host is already used by server $(hostname_owner "$host"): pick another one with --hostname" "$EX_REFUSED"
    fi
    st=$(_server_state "$old") && [[ -n $st ]] || die "cannot read the state of $(container_name "$old") (docker inspect failed): nothing was changed" "$EX_FAIL"
    case $st in running|restarting|paused) ran=1 ;; esac
    if ((ran)); then what="it is stopped, and started again when the rename is done"; else what="it is stopped already and stays stopped"; fi
    confirm "Rename $old to $new? Its containers are made again: $what. Its hostname becomes $(fqdn_for "$host")." \
        || die "$old was not renamed: nothing was changed" "$EX_REFUSED"
    sec_o=$MCCTL_ROOT/secrets/rcon-$old sec_n=$MCCTL_ROOT/secrets/rcon-$new
    keys=$(_sftp_keys_dir)

    # 1. DNS for the new hostname (the same hostname: the record is relabelled). Before this nothing has moved.
    if [[ $host == "$oldhost" ]]; then
        cf_relabel_record "$host" "$old" "$new" >/dev/null || die "$old was not renamed: its DNS record could not be relabelled (see above); nothing was changed" "$EX_FAIL"
    else
        cf_create_record "$host" "$new" >/dev/null || {
            rc=$?; ((rc == EX_REFUSED)) || rc=$EX_FAIL
            die "$old was not renamed: no DNS record for $(fqdn_for "$host") (see above); nothing was changed" "$rc"
        }
    fi
    done_steps+=(1)
    # 2. stop a running server, and remove its containers (the stop is undone only when it ran)
    if ((ran)); then
        done_steps+=(3)
        dc "$old" stop || _rn_fail "$EX_FAIL" "docker compose stop failed for $old (see above)"
    fi
    done_steps+=(4)
    dc "$old" rm -s -f || _rn_fail "$EX_FAIL" "docker compose rm failed for $old (see above)"
    # 3. the folder (with backups/ and the data) and the RCON secret
    mv -- "$dir_o" "$dir_n" || _rn_fail "$EX_FAIL" "cannot move $dir_o to $dir_n (see above)"
    done_steps+=(5)
    if [[ -e $sec_o ]]; then
        mv -- "$sec_o" "$sec_n" || _rn_fail "$EX_FAIL" "cannot move $sec_o to $sec_n (see above)"
        done_steps+=(6)
    fi
    # 4. SFTP: the key and the user move from OLD to NEW (lib/sftp.sh is the only writer of users.conf)
    if grep -q "^$old:" "$(_sftp_users_file)" 2>/dev/null; then sftp_old=1; fi
    if [[ -e $keys/$old ]]; then
        mv -- "$keys/$old" "$keys/$new" || _rn_fail "$EX_FAIL" "cannot move the SFTP key of $old (see above)"
        key_moved=1
    fi
    done_steps+=(7)
    sftp_remove_user "$old" || _rn_fail "$EX_FAIL" "the SFTP user of $old could not be removed (see above)"
    sftp_add_user "$new" || _rn_fail "$EX_FAIL" "the SFTP user of $new could not be added (see above)"
    # 5. server.env (the hostname label) and compose.yaml (the names of the containers, the labels) for NEW; the old texts are the undo
    old_env=$(cat -- "$dir_n/server.env"; printf X); old_env=${old_env%X}
    old_compose=$(cat -- "$dir_n/compose.yaml"; printf X); old_compose=${old_compose%X}
    done_steps+=(8)
    server_env_set "$new" HOSTNAME_SLUG "$host" || _rn_fail "$EX_FAIL" "cannot write $dir_n/server.env (see above)"
    write_compose "$new" || _rn_fail "$EX_FAIL" "cannot render $dir_n/compose.yaml (see above)"
    # 6. the containers of NEW, and NEW started when OLD ran
    done_steps+=(9)
    dc "$new" create || _rn_fail "$EX_FAIL" "docker compose create failed for $new (see above)"
    if ((ran)); then dc "$new" start || _rn_fail "$EX_FAIL" "docker compose start failed for $new (see above)"; fi
    # 7. the old DNS record, once the new one serves (a failure is a warning: the rename is done)
    if [[ $host != "$oldhost" ]]; then
        cf_delete_record "$oldhost" "$old" || warn "the old DNS record $(fqdn_for "$oldhost") is left: 'mcctl delete $old' removes it once Cloudflare answers"
    fi
    if ((ran)); then what="started again"; else what="still stopped"; fi
    info "renamed $old to $new: $(fqdn_for "$host"), $what"
    dns_hint "$(fqdn_for "$host")"
}

# ---- export and import -----------------------------------------------------------------------------------------------------------

# _export_data NAME FILE: the data/ folder of NAME as a tar in FILE (its members are data/...; the helper reads it, nothing is extracted)
_export_data() { data_run "$1" tar -cf - -C / data >"$2"; }

# cmd_export NAME OUT.tar.gz [--with-secrets]: the server as one archive (mode 600). Layout: the marker mcctl-export (format=1, name=, mcctl=,
# created= in UTC, secrets=0|1), then server.env, modpack.env and backup.env when present, lists/, mods/, plugins/, data/ and, only with
# --with-secrets, secrets/rcon-NAME. backups/, safety/ and compose.yaml are left out: the backups are large, and compose.yaml is made again
# from server.env. The archive holds a credential with --with-secrets.
cmd_export() {
    local usage="usage: mcctl export NAME OUT.tar.gz [--with-secrets]"
    local name=${1-} out=${2-} secrets=0 dir f
    local -a targs=()
    (($# >= 2)) || die "$usage" "$EX_USAGE"
    shift 2
    while (($#)); do
        case $1 in
            --with-secrets) secrets=1 ;;
            *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
        esac
        shift
    done
    _need_server "$name"
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    [[ -d $dir/data ]] || die "no data folder for $name: nothing was exported" "$EX_FAIL"
    [[ ! -e $out && ! -L $out ]] || die "$out already exists: refused, nothing was written (choose another OUT)" "$EX_REFUSED"
    ((!secrets)) || [[ -f $MCCTL_ROOT/secrets/rcon-$name ]] || die "secrets/rcon-$name is missing: nothing was exported" "$EX_FAIL"
    (
        tmp=$(mktemp -d) || exit "$EX_FAIL"
        trap 'rm -f -- "$tmp/mcctl-export" "$tmp/data.tar" "$tmp/all.tar" "$tmp/secrets/rcon-$name"; rmdir -- "$tmp/secrets" "$tmp" 2>/dev/null' EXIT
        printf 'format=1\nname=%s\nmcctl=%s\ncreated=%s\nsecrets=%s\n' "$name" "$MCCTL_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$secrets" \
            >"$tmp/mcctl-export" || exit "$EX_FAIL"
        # the members are read where they are: tar switches the folder (-C) for each one, so no copy is made
        targs=(-C "$tmp" mcctl-export)
        for f in server.env modpack.env backup.env lists mods plugins; do
            [[ ! -e $dir/$f ]] || targs+=(-C "$dir" "$f")
        done
        if ((secrets)); then
            # the secret belongs to the game's user: a read-only helper that may read it (DAC_READ_SEARCH) copies it into the private folder
            mkdir -- "$tmp/secrets" && _root_docker ro "$MCCTL_ROOT/secrets/rcon-$name" DAC_READ_SEARCH cat /m >"$tmp/secrets/rcon-$name" \
                && chmod 600 -- "$tmp/secrets/rcon-$name" \
                || die "cannot read secrets/rcon-$name (see above): nothing was written" "$EX_FAIL"
            targs+=(-C "$tmp" "secrets/rcon-$name")
        fi
        _quiesced "$name" _export_data "$name" "$tmp/data.tar" || die "the data of $name could not be read (see above): nothing was written" "$EX_FAIL"
        tar -cf "$tmp/all.tar" "${targs[@]}" && tar -Af "$tmp/all.tar" "$tmp/data.tar" \
            || die "could not assemble the archive (see above): nothing was written" "$EX_FAIL"
        write_atomic "$out" gzip -c "$tmp/all.tar" || die "cannot write $out (see above)" "$EX_FAIL"
        tar -tzf "$out" >/dev/null 2>&1 || { rm -f -- "$out"; die "$out does not read back: removed" "$EX_FAIL"; }
        ((!secrets)) || warn "$out holds the RCON password of $name: keep it as you keep the secret itself (mode 600)"
        info "exported $name to $out"
    )
}

# cmd_import ARCHIVE [NAME] [--hostname H]: a server made from an export, stopped. Before anything is made the archive is checked: every
# member is safe (archive_safe_members), every top-level name is one an export writes, the marker says format=1 and server.env is there.
# NAME defaults to the marker's name and must be free; the hostname is HOSTNAME_SLUG of the archive, or H, and must be free. The RCON
# secret is the archive's (renamed to secrets/rcon-NAME) when it has one, else a fresh one. A failure takes everything back (_provision).
cmd_import() {
    local usage="usage: mcctl import ARCHIVE [NAME] [--hostname H]"
    local arch=${1-} name="" host="" names marker line mname="" fmt=""
    (($# >= 1)) || die "$usage" "$EX_USAGE"
    shift
    while (($#)); do
        case $1 in
            --hostname) (($# >= 2)) || die "--hostname needs a value. $usage" "$EX_USAGE"; host=$2; shift ;;
            --*) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
            *) [[ -z $name ]] || die "$usage" "$EX_USAGE"; name=$1 ;;
        esac
        shift
    done
    [[ -f $arch && -r $arch ]] || die "$arch is not a readable file: nothing was imported" "$EX_FAIL"
    archive_safe_members "$arch" || die "$arch is refused (see above): nothing was imported" "$EX_REFUSED"
    names=$(tar -tzf "$arch") || die "cannot list $arch: nothing was imported" "$EX_REFUSED"
    while IFS= read -r line; do
        case ${line%%/*} in
            mcctl-export|server.env|modpack.env|backup.env|lists|mods|plugins|data|secrets) ;;
            *) die "$arch has the member ${line@Q} at its top level, which an export never writes: nothing was imported" "$EX_REFUSED" ;;
        esac
    done <<<"$names"
    grep -qxF -- mcctl-export <<<"$names" || die "$arch has no mcctl-export marker: it is not an export of mcctl: nothing was imported" "$EX_REFUSED"
    marker=$(tar -xzOf "$arch" mcctl-export) || die "cannot read the marker of $arch: nothing was imported" "$EX_REFUSED"
    while IFS= read -r line; do
        case ${line%%=*} in
            format) fmt=${line#*=} ;;
            name) mname=${line#*=} ;;
        esac
    done <<<"$marker"
    [[ $fmt == 1 ]] || die "$arch: its marker says format ${fmt@Q}, and this mcctl reads format 1 only: nothing was imported" "$EX_REFUSED"
    [[ -n $name ]] || name=$mname
    valid_server_name "$name" || die "the server name ${name@Q} is not valid: give one (mcctl import ARCHIVE NAME)" "$EX_USAGE"
    grep -qxF -- server.env <<<"$names" || die "$arch has no server.env: nothing was imported" "$EX_REFUSED"
    if [[ -z $host ]]; then
        host=$(tar -xzOf "$arch" server.env | sed -n 's/^HOSTNAME_SLUG=//p' | tail -n 1)
        host=${host:-$(slugify "$name")}
    fi
    { valid_server_name "$host" && [[ $host != *- ]]; } \
        || die "hostname ${host@Q} is not a DNS label: give one with --hostname H" "$EX_USAGE"
    cf_ready
    _provision "$name" "$host" _import_files
    info "imported $arch as $name (stopped). Start it with: mcctl start $name; players join at $(fqdn_for "$host")"
    dns_hint "$(fqdn_for "$host")"
}

# _import_files NAME HOST: the files of an import (the WRITE_FN of _provision). It reads $arch, $names and $mname from cmd_import (dynamic
# scope). The small files and lists/, mods/, plugins/ are extracted with tar (--no-same-owner, the umask 022 so the game can read the
# jars); data/ goes through the helper container; the RCON secret is written from the archive. The renderer checks server.env afterwards.
_import_files() {
    local name=$1 host=$2 dir f d
    local -a small=()
    dir=$(server_dir "$name") || exit "$EX_USAGE"
    for f in server.env modpack.env backup.env; do
        grep -qxF -- "$f" <<<"$names" || continue
        write_atomic "$dir/$f" tar -xzOf "$arch" "$f" || _create_fail "$name" "$host" "cannot write $dir/$f (see above)"
    done
    server_env_set "$name" HOSTNAME_SLUG "$host" || _create_fail "$name" "$host" "cannot write $dir/server.env (see above)"
    # the voice chat port belongs to one server: the import has none until mcctl voice NAME set PORT gives it one
    server_env_unset "$name" VOICE_PORT || _create_fail "$name" "$host" "cannot write $dir/server.env (see above)"
    for d in lists mods plugins; do
        grep -q "^$d/" <<<"$names" && small+=("$d")
    done
    if ((${#small[@]})); then
        (umask 022 && tar -xzf "$arch" --no-same-owner --no-same-permissions -C "$dir" "${small[@]}") \
            || _create_fail "$name" "$host" "cannot extract the lists, mods and plugins of $arch (see above)"
    fi
    if grep -q '^data/' <<<"$names"; then
        # ponytail: data/ is picked by name inside the helper's tar (member filter, then strip): checked with GNU tar; busybox (the
        # image's tar) is not run against a real image yet (Task 23)
        data_pipe "$name" tar -xzf - --no-same-owner --strip-components=1 -C /data data <"$arch" \
            || _create_fail "$name" "$host" "cannot copy the data of $arch (see above)"
    fi
    if grep -qxF -- "secrets/rcon-$mname" <<<"$names"; then
        write_atomic "$MCCTL_ROOT/secrets/rcon-$name" tar -xzOf "$arch" "secrets/rcon-$mname" \
            || _create_fail "$name" "$host" "cannot write secrets/rcon-$name (see above)"
        _give_to_game "$MCCTL_ROOT/secrets/rcon-$name" \
            || _create_fail "$name" "$host" "cannot give secrets/rcon-$name to the game's user (see above)"
    fi
}

# ---- exec and shell --------------------------------------------------------------------------------------------------------------

# cmd_exec NAME COMMAND [ARGS...]: one command in the game container, as the game's user. The exit status is the command's. The
# server must run (mcctl start otherwise).
cmd_exec() {
    local usage="usage: mcctl exec NAME COMMAND [ARGS...]   (example: mcctl exec survival ls -la)"
    local name=${1-} c
    (($# >= 2)) || die "$usage" "$EX_USAGE"
    shift
    [[ -n $1 && $1 != -* ]] || die "the command cannot be empty or start with '-' (docker exec would read it as one of its options)" "$EX_USAGE"
    _need_server "$name"
    _need_running "$name"
    _game_user
    c=$(container_name "$name") || exit "$EX_USAGE"
    docker exec -u "$_GAME_USER" "$c" "$@"
}

# cmd_shell NAME: a bash in the game container, as the game's user. Needs a terminal (exit 2 without one) and a running server.
cmd_shell() {
    local c
    (($# == 1)) || die "usage: mcctl shell NAME" "$EX_USAGE"
    _need_server "$1"
    _need_running "$1"
    _have_terminal || die "the shell needs a terminal; to run one command use: mcctl exec $1 COMMAND" "$EX_USAGE"
    _game_user
    c=$(container_name "$1") || exit "$EX_USAGE"
    docker exec -it -u "$_GAME_USER" "$c" bash
}

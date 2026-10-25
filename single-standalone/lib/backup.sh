#!/usr/bin/env bash
# shellcheck shell=bash
# Backup and restore: the backup sidecar's env, on-demand backup, list, restore, prune.
# Sourced by ./mcctl, never executed.
#
# The sidecar (itzg/mc-backup) shares the game container's network namespace (network_mode: service:mc), so it reaches RCON
# on 127.0.0.1. On-demand backup is `docker exec mc-NAME-backup backup now` (itzg/mc-backup's "backup now" command, see
# https://github.com/itzg/docker-mc-backup#on-demand-backups). Restore: the server must be stopped; the archive is verified
# with tar -tzf and its members checked on the host (archive_safe_members: regular files and directories only, no absolute
# path, no ..); its layout is read (members as they are in data/, or all under one top-level data/); after the confirm the
# current data/ is moved aside to data.pre-restore-<UTC>, and the archive is extracted into a new data/ by a throw-away
# container that runs as the game's UID (MCCTL_UID, default 1000), so the restored files belong to the game. A failed
# extraction moves the previous data back. Prune keeps the N newest archives (PRUNE_BACKUPS_COUNT in backup.env, default 7).
#
# Variables (itzg/mc-backup): BACKUP_INTERVAL (default 24h), BACKUP_METHOD (tar|rsync|restic|rclone), DEST_DIR (/backups for
# tar/rsync), RESTIC_REPOSITORY (restic), PRUNE_BACKUPS_DAYS, PRUNE_BACKUPS_COUNT, PRUNE_RESTIC_RETENTION, INITIAL_DELAY (2m),
# RCON_HOST, RCON_PORT, RCON_PASSWORD_FILE. S3 credentials: AWS_ACCESS_KEY_ID_FILE, AWS_SECRET_ACCESS_KEY_FILE (restic _FILE
# convention). rsync credentials: an SSH key mounted into the container (no env var).

# backup_dir NAME -> stdout servers/NAME/backups
backup_dir() {
    local dir
    dir=$(server_dir "${1-}") || return
    printf '%s\n' "$dir/backups"
}

# backup_env NAME -> stdout the KEY=VALUE lines of servers/NAME/backup.env (nothing when the file is missing)
backup_env() {
    local dir file
    dir=$(server_dir "${1-}") || return
    file=$dir/backup.env
    [[ -f $file ]] || return 0
    kv_lines "$file"
}

# _backup_container_name NAME -> stdout mc-NAME-backup
_backup_container_name() {
    local c
    c=$(container_name "${1-}") || return
    printf '%s-backup\n' "$c"
}

# _backup_sidecar_state NAME -> stdout the State.Status of the backup sidecar; empty when docker inspect fails
_backup_sidecar_state() {
    local c
    c=$(_backup_container_name "${1-}") || return
    docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null
}

# _server_state NAME -> stdout the State.Status of the game container; empty when docker inspect fails
_server_state() {
    local c
    c=$(container_name "${1-}") || return
    docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null
}

# _backup_stamp_set BASENAME: set _BACKUP_STAMP to the UTC stamp YYYYMMDDHHMMSS in BASENAME and return 0; else clear it, return 1.
# The first match of the pattern is used, and its parts must be a real time (month 01-12, day 01-31, hour 00-23, minute and
# second 00-59): 2026-01-02_12.00.00 and 20260102T120000Z give the same stamp; 20261340T000000Z gives none.
_backup_stamp_set() {
    local re='([0-9]{4})-?([0-9]{2})-?([0-9]{2})[T_ -]?([0-9]{2})[.:_-]?([0-9]{2})[.:_-]?([0-9]{2})'
    local mo d h mi s
    _BACKUP_STAMP=""
    [[ ${1-} =~ $re ]] || return 1
    mo=${BASH_REMATCH[2]} d=${BASH_REMATCH[3]} h=${BASH_REMATCH[4]} mi=${BASH_REMATCH[5]} s=${BASH_REMATCH[6]}
    ((10#$mo >= 1 && 10#$mo <= 12 && 10#$d >= 1 && 10#$d <= 31 && 10#$h <= 23 && 10#$mi <= 59 && 10#$s <= 59)) || return 1
    _BACKUP_STAMP=${BASH_REMATCH[1]}$mo$d$h$mi$s
}

# _backup_stamp BASENAME: print the UTC stamp in BASENAME (see _backup_stamp_set), or print nothing and return 1
_backup_stamp() {
    _backup_stamp_set "${1-}" && printf '%s\n' "$_BACKUP_STAMP"
}

# _backup_list NAME: print the archives in servers/NAME/backups, newest first (one path per line). The order is the UTC stamp in
# the name, not the mtime (archives written in one second share it). An archive with no stamp is listed last, by name. Each row
# is "stamp<TAB>path" (the stamp is empty when there is none): one LC_ALL=C sort puts the stamps in reverse order with the empty
# ones last, and the path (same directory, so the name) orders the rest.
_backup_list() {
    local name=$1 bdir f line rows=""
    bdir=$(backup_dir "$name") || return
    [[ -d $bdir ]] || return 0
    while IFS= read -r f; do
        _backup_stamp_set "${f##*/}"
        rows+="$_BACKUP_STAMP"$'\t'"$f"$'\n'
    done < <(find "$bdir" -maxdepth 1 -type f \( -name '*.tgz' -o -name '*.tar.gz' \) 2>/dev/null)
    [[ -n $rows ]] || return 0
    while IFS= read -r line; do printf '%s\n' "${line#*$'\t'}"; done < <(printf '%s' "$rows" | LC_ALL=C sort -t $'\t' -k1,1r -k2,2)
}

# _backup_verify_archive PATH: 0 when PATH is a readable gzip tar; else a message and 1
_backup_verify_archive() {
    local arch=$1
    [[ -f $arch ]] || { err "no archive at $arch"; return 1; }
    tar -tzf "$arch" >/dev/null 2>&1 || { err "$arch is not a readable gzip tar archive (tar -tzf failed)"; return 1; }
}

# _backup_extract DATA_DIR UID ARCHIVE [TAR-OPTION...]: extract the gzip tar ARCHIVE (fed on stdin) into DATA_DIR in a
# throw-away container that runs as UID:UID, with no network and no capabilities; --no-same-owner makes the files the UID's.
# ponytail: a copy of Task 15's data_pipe, kept to this one call; replace it by data_pipe when Task 15 lands.
_backup_extract() {
    local data_dir=$1 uid=$2 arch=$3
    shift 3
    docker run --rm -i --network none --user "$uid:$uid" --cap-drop ALL --security-opt no-new-privileges \
        -v "$data_dir:/data" -w /data alpine:3.20 tar -xzf - --no-same-owner -C /data "$@" <"$arch"
}

# cmd_backup NAME now|list|restore ID|prune
cmd_backup() {
    local usage="usage: mcctl backup NAME now|list|restore ID|prune   (restore asks --yes unless MCCTL_YES=1)"
    local name=${1-} sub=${2-}
    [[ -n $name && -n $sub ]] || die "$usage" "$EX_USAGE"
    _need_server "$name"
    case $sub in
        now)
            local st c
            st=$(_backup_sidecar_state "$name")
            c=$(_backup_container_name "$name")
            [[ $st == running ]] \
                || die "$name is not running (its backup sidecar is ${st:-stopped}): start it with: mcctl start $name" "$EX_FAIL"
            docker exec "$c" backup now \
                || die "the immediate backup of $name failed (see above). The sidecar logs say more: docker logs $c"
            info "$name: backup started in the sidecar ($c)"
            ;;
        list)
            local out
            out=$(_backup_list "$name") || die "cannot list the backups of $name"
            if [[ -z $out ]]; then info "no backups yet for $name"; return 0; fi
            printf '%s\n' "$out"
            ;;
        restore)
            local id=${3-} arch bdir pre failed ts data_dir dir sst uid rc top strip="" moved=0 back partial="" hint=""
            [[ -n $id ]] || die "$usage" "$EX_USAGE"
            [[ $id != /* && $id != *..* && $id != */* ]] \
                || die "invalid archive id ${id@Q}: use a filename in backups/ (no absolute path, no .., no /)" "$EX_USAGE"
            uid=${MCCTL_UID:-1000}
            [[ $uid =~ ^[1-9][0-9]{0,4}$ ]] && ((uid <= 65535)) \
                || die "MCCTL_UID=${uid@Q} must be a number from 1 to 65535 (the UID the game runs as; default 1000)" "$EX_PREFLIGHT"
            dir=$(server_dir "$name")
            bdir=$(backup_dir "$name")
            data_dir=$dir/data
            arch=$bdir/$id
            # 1. refuse while the server runs
            sst=$(_server_state "$name")
            [[ $sst != running ]] \
                || die "$name is running: stop it first (mcctl stop $name) before restoring, or the world will be damaged" "$EX_REFUSED"
            # 2. verify the archive (tar -tzf), its members and its layout -- abort without touching data/
            _backup_verify_archive "$arch" \
                || die "$arch is not a readable archive (tar -tzf failed); nothing was changed" "$EX_FAIL"
            archive_safe_members "$arch"; rc=$?
            ((rc != 2)) || die "cannot list the members of $arch; nothing was changed" "$EX_FAIL"
            ((rc == 0)) || die "$arch has unsafe members (named above); nothing was changed" "$EX_REFUSED"
            # the layout: every member under one top-level data/ (strip it), or the members as they are in data/
            # ponytail: two layouts until the acceptance run shows which one itzg/mc-backup writes; then keep that one
            top=$(tar -tzf "$arch" | cut -d/ -f1 | sort -u)
            [[ -n $top ]] || die "$arch has no members; nothing was changed" "$EX_REFUSED"
            if [[ $top == data ]]; then
                strip=--strip-components=1
            elif grep -qx data <<<"$top"; then
                die "$arch has data/ next to other top-level names (${top//$'\n'/, }): it is neither all under data/ nor laid out as data/ is; nothing was changed" "$EX_REFUSED"
            fi
            # 3. confirm
            confirm "Restore $name from $arch? The current data/ is moved aside first (to data.pre-restore-<timestamp>), then the archive is extracted." \
                || die "$name was not restored" "$EX_REFUSED"
            # 4. move current data/ aside (mv -T: never into a directory that already has that name)
            ts=$(date -u +%Y%m%dT%H%M%SZ)
            pre=$dir/data.pre-restore-$ts failed=$dir/data.failed-restore-$ts
            if [[ -e $data_dir ]]; then
                mv -T -- "$data_dir" "$pre" || die "cannot move $data_dir aside to $pre; nothing was extracted" "$EX_FAIL"
                moved=1 hint="; the previous data is in $pre: move $data_dir away and $pre back to $data_dir by hand"
                info "$name: the current data is in $pre until the restore has finished"
            fi
            # 5. extract into a new data/ that belongs to the game's UID (root hands it over; any other user must be that UID)
            if mkdir_private "$data_dir" && { ((EUID != 0)) || chown -- "$uid:$uid" "$data_dir"; } \
                && _backup_extract "$data_dir" "$uid" "$arch" ${strip:+"$strip"}; then
                # 6. report both paths
                ((moved)) || { info "$name: restored $arch into $data_dir (there was no previous data)"; return 0; }
                info "$name: restored $arch into $data_dir; the previous data is in $pre; if the world is wrong, stop the server, move $data_dir aside and move the previous data back"
                return 0
            fi
            # the extraction failed: put the previous data back, keep what was extracted for a look (an empty folder is removed)
            if [[ -e $data_dir ]]; then
                mv -T -- "$data_dir" "$failed" \
                    || die "extracting $arch failed and $data_dir could not be moved aside$hint" "$EX_FAIL"
                if [[ -n $(find "$failed" -mindepth 1 -print -quit) ]]; then
                    partial="; what was extracted is in $failed"
                else
                    rmdir -- "$failed"
                fi
            fi
            back="there was no previous data"
            if ((moved)); then
                mv -T -- "$pre" "$data_dir" \
                    || die "extracting $arch failed and the previous data could not be moved back: it is in $pre; move it back to $data_dir by hand" "$EX_FAIL"
                back="the previous data was moved back into $data_dir"
            fi
            die "extracting $arch into $data_dir failed (see above; the helper runs as UID $uid, which must be able to write there): $back$partial" "$EX_FAIL"
            ;;
        prune)
            local bdir keep=7 line k v count=0 i
            local -a all=() stamps=()
            bdir=$(backup_dir "$name")
            [[ -d $bdir ]] || { info "$name: no backups directory"; return 0; }
            while IFS= read -r line; do
                [[ -n $line ]] || continue
                k=${line%%=*} v=${line#*=}
                [[ $k == PRUNE_BACKUPS_COUNT ]] && keep=$v
            done < <(backup_env "$name")
            [[ $keep =~ ^[0-9]+$ ]] || die "PRUNE_BACKUPS_COUNT is ${keep@Q}, expected a non-negative integer" "$EX_PREFLIGHT"
            keep=$((10#$keep))   # 10#: a leading zero ("08") would otherwise be read as octal
            while IFS= read -r line; do [[ -n $line ]] && all+=("$line"); done < <(_backup_list "$name")
            count=${#all[@]}
            # before anything is deleted: every archive needs a stamp (else its age is unknown), and no two may share one
            for ((i = 0; i < count; i++)); do
                _backup_stamp_set "${all[i]##*/}" \
                    || die "cannot prune: ${all[i]} has no UTC timestamp in its name, so its age is unknown; nothing was deleted" "$EX_REFUSED"
                stamps[i]=$_BACKUP_STAMP
            done
            for ((i = 1; i < count; i++)); do
                [[ ${stamps[i]} != "${stamps[i-1]}" ]] \
                    || die "cannot prune: ${all[i-1]} and ${all[i]} have the same timestamp; nothing was deleted" "$EX_REFUSED"
            done
            ((count <= keep)) && { info "$name: $count archive(s), keeping all (PRUNE_BACKUPS_COUNT=$keep)"; return 0; }
            for ((i = keep; i < count; i++)); do
                rm -f -- "${all[i]}" || die "cannot remove ${all[i]}"
            done
            info "$name: pruned $((count - keep)) archive(s), kept $keep of $count"
            ;;
        *)
            die "$usage" "$EX_USAGE"
            ;;
    esac
}

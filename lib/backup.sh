#!/usr/bin/env bash
# shellcheck shell=bash
# Backup, restore, restore-config. Sourced by ./ptero.
#
# A backup is a directory under backups/ (mode 700, files 600):
#   db.sql.gz       consistent mariadb-dump (--single-transaction) of the `panel` database
#   panel_var.tgz   the panel_var volume: /app/var/.env holds APP_KEY + HASHIDS_SALT (without it the DB is useless)
#   extensions.tgz  extension packages + published assets
#   config.tgz      config/deploy.env, config/versions.env, secrets/*, and /etc/pterodactyl/config.yml when readable
#   MANIFEST, SHA256SUMS
# With BACKUP_AGE_RECIPIENT set the directory is replaced by a single <name>.tar.age.
# Nothing here ever deletes an existing backup. Retention and off-site copies are the operator's job (docs/operations.md).

vol() { printf '%s_%s\n' "$PTERO_PROJECT" "$1"; }

# tar_volume_out OUTDIR FILE VOLUME[:SUBDIR]...  -> OUTDIR/FILE owned by the calling user, mode 600
tar_volume_out() {
    local outdir=$1 file=$2; shift 2
    local args=() spec v sub
    for spec in "$@"; do
        v=${spec%%:*}; sub=${spec#*:}; [[ $sub == "$spec" ]] && sub=""
        volume_exists "$(vol "$v")" || { err "volume $(vol "$v") does not exist (has ./ptero setup been run?)"; return 1; }
        args+=(-v "$(vol "$v")":"/ptero_vol${sub:+/$sub}":ro)
    done
    docker run --rm -e U="$(id -u)" -e G="$(id -g)" "${args[@]}" -v "$outdir":/ptero_out "$UTILITY_IMAGE" \
        sh -c 'f="/ptero_out/$1" && tar czf "$f" -C /ptero_vol . && chown "$U:$G" "$f" && chmod 600 "$f"' _ "$file"
}

backup_create() { # backup_create [label] -> prints the path of the finished backup on stdout
    local label=${1:-manual} ts root dir work
    [[ $label =~ ^[a-z0-9-]{1,32}$ ]] || { err "backup label must match [a-z0-9-]{1,32}"; return 1; }
    if [[ -n ${BACKUP_AGE_RECIPIENT:-} ]] && ! have age; then err "BACKUP_AGE_RECIPIENT is set but 'age' is not installed (apt install age)"; return 1; fi
    [[ $(svc_state database) == healthy ]] || { err "the database container is not healthy: start it with ./ptero up"; return 1; }
    root=$PTERO_ROOT/backups
    mkdir_private "$root" || { err "cannot create $root"; return 1; }
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    dir=$root/$ts-$label
    if [[ -e $dir || -e $dir.partial || -e $dir.tar.age ]]; then err "$dir already exists; not overwriting"; return 1; fi
    work=$dir.partial
    mkdir -m 700 "$work" || { err "cannot create $work"; return 1; }

    # 1. database: kept only if the dump is complete and readable
    if ! compose exec -T database sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb-dump --single-transaction --quick --routines --events --no-tablespaces -u"$MARIADB_USER" "$MARIADB_DATABASE"' \
            | gzip -c >"$work/db.sql.gz"; then
        err "database dump failed; the partial backup is left in $work for inspection (safe to delete)"; return 1
    fi
    if ! gzip -t "$work/db.sql.gz" 2>/dev/null || ! gzip -dc "$work/db.sql.gz" | tail -n 3 | grep -q 'Dump completed'; then
        err "database dump is incomplete or corrupt; partial backup left in $work"; return 1
    fi
    # 2. APP_KEY volume, 3. extensions
    tar_volume_out "$work" panel_var.tgz panel_var || { err "could not archive the panel_var volume; partial backup in $work"; return 1; }
    tar_volume_out "$work" extensions.tgz panel_extensions:extensions panel_extension_assets:assets \
        || { err "could not archive extensions; partial backup in $work"; return 1; }
    # 4. host-side configuration and secrets (+ the Wings config when this user can read it)
    local stage="$PTERO_TMP/cfg-$ts"
    mkdir -p "$stage/repo/config" "$stage/repo/secrets" "$stage/wings"
    cp -- "$PTERO_ROOT/config/deploy.env" "$PTERO_ROOT/config/versions.env" "$stage/repo/config/" || { err "cannot read config/"; return 1; }
    cp -- "$PTERO_ROOT"/secrets/* "$stage/repo/secrets/" 2>/dev/null
    [[ -r ${PTERO_WINGS_ETC:-/etc/pterodactyl}/config.yml ]] && cp -- "${PTERO_WINGS_ETC:-/etc/pterodactyl}/config.yml" "$stage/wings/config.yml"
    tar czf "$work/config.tgz" -C "$stage" repo wings || { err "cannot archive configuration"; return 1; }
    rm -rf -- "$stage"

    # 5. manifest + checksums, then publish by renaming (a directory without .partial is a complete backup)
    {
        printf 'format=1\ncreated=%s\nlabel=%s\nhost=%s\n' "$ts" "$label" "$(hostname)"
        printf 'panel_version=%s\npanel_image=%s\nmariadb_image=%s\nwings_version=%s\n' "$PANEL_VERSION" "$PANEL_IMAGE" "$MARIADB_IMAGE" "$WINGS_VERSION"
    } >"$work/MANIFEST"
    (cd "$work" && sha256sum db.sql.gz panel_var.tgz extensions.tgz config.tgz MANIFEST >SHA256SUMS) || { err "cannot write checksums"; return 1; }
    chmod 600 "$work"/* && mv -- "$work" "$dir" || { err "cannot finalise $dir"; return 1; }

    if [[ -n ${BACKUP_AGE_RECIPIENT:-} ]]; then
        if tar -C "$root" -cf - "$(basename "$dir")" | age -r "$BACKUP_AGE_RECIPIENT" -o "$dir.tar.age" && [[ -s $dir.tar.age ]]; then
            chmod 600 "$dir.tar.age"
            rm -rf -- "$dir"   # only the plaintext copy this very run created
            printf '%s\n' "$dir.tar.age"; return 0
        fi
        err "encryption failed; the unencrypted backup is kept at $dir"; return 1
    fi
    printf '%s\n' "$dir"
}

# backup_open PATH [IDENTITY] -> prints the directory holding the (decrypted) backup files
backup_open() {
    local path=$1 identity=${2:-} tmp d
    if [[ -d $path ]]; then (cd "$path" && pwd -P); return 0; fi
    if [[ -f $path && $path == *.tar.age ]]; then
        have age || { err "age is not installed (apt install age)"; return 1; }
        [[ -r $identity ]] || { err "encrypted backup: pass your private key with --identity FILE"; return 1; }
        tmp=$PTERO_TMP/open
        mkdir -m 700 "$tmp" || { err "cannot create $tmp"; return 1; }
        age -d -i "$identity" "$path" | tar -x -C "$tmp" || { err "could not decrypt/extract $path"; return 1; }
        d=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)
        [[ -n $d ]] || { err "archive is empty"; return 1; }
        printf '%s\n' "$d"; return 0
    fi
    err "not a backup directory or .tar.age file: $path"; return 1
}

backup_verify() { # backup_verify DIR
    local d=$1 f
    for f in MANIFEST SHA256SUMS db.sql.gz panel_var.tgz extensions.tgz config.tgz; do
        [[ -f $d/$f ]] || { err "backup is incomplete: $f is missing"; return 1; }
    done
    (cd "$d" && sha256sum --check --quiet SHA256SUMS >/dev/null 2>&1) || { err "checksum mismatch: the backup is corrupt or was modified"; return 1; }
    tar -xzOf "$d/panel_var.tgz" ./.env 2>/dev/null | grep -q '^APP_KEY=.\+' || { err "the backup's panel_var has no APP_KEY: it cannot decrypt the database"; return 1; }
}

manifest_get() { sed -n "s/^$2=//p" "$1/MANIFEST" | head -n1; }

cmd_backup() {
    local label=manual
    while (($#)); do case $1 in --label) label=${2:-}; shift ;; *) die "unknown option: $1 (usage: ./ptero backup [--label name])" $EX_USAGE ;; esac; shift; done
    prepare 0
    local out; out=$(backup_create "$label") || exit $EX_FAIL
    info "backup written: $out"
    printf '%s\n' "$out"
    warn "this backup is on the same machine. Copy it off-site (docs/operations.md, Backups); it contains APP_KEY and secrets"
}

cmd_restore() {
    local identity="" allow_mismatch=0 safety=1 path=""
    while (($#)); do
        case $1 in
            --identity) identity=${2:-}; shift ;;
            --allow-version-mismatch) allow_mismatch=1 ;;
            --no-safety-backup) safety=0 ;;
            -*) die "unknown option: $1" $EX_USAGE ;;
            *) path=$1 ;;
        esac; shift
    done
    [[ -n $path ]] || die "usage: ./ptero restore [--yes] [--identity KEY] [--allow-version-mismatch] <backup dir | .tar.age>" $EX_USAGE
    prepare 0
    local src; src=$(backup_open "$path" "$identity") || exit $EX_FAIL
    backup_verify "$src" || exit $EX_REFUSED

    local b_img; b_img=$(manifest_get "$src" panel_image)
    if [[ $b_img != "$PANEL_IMAGE" ]] && ((!allow_mismatch)); then
        die "version mismatch: the backup was taken with
         $b_img
       but config/versions.env pins
         $PANEL_IMAGE
       A database dump must be restored with the Panel version that wrote it (migrations are not reversible).
       Put the matching versions.env back (rollback) or pass --allow-version-mismatch if you know it is safe." $EX_REFUSED
    fi
    [[ $(svc_state database) == healthy ]] || die "the database is not running. On a new machine run ./ptero setup first, then restore" $EX_REFUSED

    local has_data=no; db_is_migrated && has_data=yes
    cat >&2 <<EOF
Restore target : project '$PTERO_PROJECT' on this host ($(hostname))
Backup         : $(manifest_get "$src" created) label=$(manifest_get "$src" label) from $(manifest_get "$src" host)
Existing data  : Panel database has tables: $has_data
This REPLACES the Panel database and the panel_var volume (APP_KEY) with the backup's contents.
Wings, servers and /var/lib/pterodactyl are not touched.
EOF
    confirm "Continue?" RESTORE || die "restore cancelled; nothing changed" $EX_REFUSED

    if [[ $has_data == yes ]] && ((safety)); then
        info "taking a safety backup of the current state first"
        local sb; sb=$(backup_create pre-restore) || die "safety backup failed: aborting before anything was changed (or use --no-safety-backup)"
        info "safety backup: $sb"
    fi
    compose stop panel cloudflared >/dev/null 2>&1 || true   # either may simply not be running

    info "importing the database"
    if ! gzip -dc "$src/db.sql.gz" | compose exec -T database sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb -u"$MARIADB_USER" "$MARIADB_DATABASE"'; then
        die "database import failed; the Panel is left STOPPED. The safety backup (if taken) can be restored. See ./ptero logs database"
    fi
    info "restoring panel_var (APP_KEY) and extensions"
    docker run --rm -v "$(vol panel_var)":/ptero_vol -v "$src":/ptero_out:ro "$UTILITY_IMAGE" \
        sh -c 'tar xzf /ptero_out/panel_var.tgz -C /ptero_vol' || die "could not restore panel_var; Panel left stopped"
    docker run --rm -v "$(vol panel_extensions)":/ptero_vol/extensions -v "$(vol panel_extension_assets)":/ptero_vol/assets -v "$src":/ptero_out:ro "$UTILITY_IMAGE" \
        sh -c 'tar xzf /ptero_out/extensions.tgz -C /ptero_vol' || die "could not restore extensions; Panel left stopped"

    compose up -d --wait --wait-timeout 300 || die "services unhealthy after restore: ./ptero status"
    wait_until 120 "the Panel to answer" panel_http_ok || die "Panel does not answer after restore: ./ptero logs panel"
    info "restore complete. Wings is unchanged; on a new machine also run: ./ptero restore-config, then sudo ./ptero wings install --config <file>"
}

cmd_restore_config() {
    local identity="" path=""
    while (($#)); do
        case $1 in --identity) identity=${2:-}; shift ;; -*) die "unknown option: $1" $EX_USAGE ;; *) path=$1 ;; esac; shift
    done
    [[ -n $path ]] || die "usage: ./ptero restore-config [--identity KEY] <backup dir | .tar.age>" $EX_USAGE
    local src; src=$(backup_open "$path" "$identity") || exit $EX_FAIL
    backup_verify "$src" || exit $EX_REFUSED
    local existing=() f
    [[ -e $PTERO_ROOT/config/deploy.env ]] && existing+=(config/deploy.env)
    for f in "$PTERO_ROOT"/secrets/*; do [[ -e $f ]] && existing+=("secrets/$(basename "$f")"); done
    if ((${#existing[@]})); then
        die "refusing to overwrite existing files: ${existing[*]}. Move them away yourself first; this command only fills an empty checkout." $EX_REFUSED
    fi
    confirm "Restore config/deploy.env and secrets/* from this backup into $PTERO_ROOT?" || die "cancelled" $EX_REFUSED
    local tmp=$PTERO_TMP/cfg
    mkdir -m 700 "$tmp" || die "cannot create temp dir"
    tar -xzf "$src/config.tgz" -C "$tmp" || die "cannot extract config.tgz"
    mkdir_private "$PTERO_ROOT/secrets" && mkdir -p "$PTERO_ROOT/config" || die "cannot create config/ or secrets/"
    cp -- "$tmp/repo/config/deploy.env" "$PTERO_ROOT/config/deploy.env" && chmod 600 "$PTERO_ROOT/config/deploy.env" || die "cannot restore deploy.env"
    cp -- "$tmp"/repo/secrets/* "$PTERO_ROOT/secrets/" && chmod 600 "$PTERO_ROOT"/secrets/* || die "cannot restore secrets"
    info "restored config/deploy.env and secrets/. The backup's versions.env was NOT applied: this checkout's pinned versions stay in force"
    if [[ -f $tmp/wings/config.yml ]]; then
        cp -- "$tmp/wings/config.yml" "$PTERO_ROOT/config/wings-config.restored.yml" && chmod 600 "$PTERO_ROOT/config/wings-config.restored.yml"
        info "Wings config saved to config/wings-config.restored.yml. Install it with: sudo ./ptero wings install --config config/wings-config.restored.yml"
    fi
}

#!/usr/bin/env bash
# shellcheck shell=bash
# rclone: an offsite copy of each backup, in a Google Drive (or another rclone remote of type drive) that the operator set up once.
#
# Design. The backup stays the sidecar's own tar archive, written in backups/ (BACKUP_METHOD=tar). The image's rclone method is NOT
# used: it deletes the local archive right after the upload, so a failed upload would lose the backup. Instead RCLONE_POST_SCRIPT
# (backup.env, POST_BACKUP_SCRIPT) runs after every backup: it copies the newest archive to REMOTE:mcctl/NAME, and deletes the remote
# archives of this server older than RCLONE_KEEP_DAYS. The local archive stays until PRUNE_BACKUPS_DAYS. A failed upload leaves the
# archive where it was.
#
# The rclone.conf holds the OAuth token: one file for all servers, in secrets/rclone/. That is a folder, owned by the game's user
# (UID 1000) with this user's group, mode 750, and rclone.conf inside, mode 640. The game's user writes it (rclone writes a refreshed
# token back into it, so it must be a writable folder, not a single file mounted on its own); this user can see it and read it, but
# not write it. The sidecar gets it at /config/rclone (XDG_CONFIG_HOME=/config, the image's rclone reads /config/rclone/rclone.conf)
# only when its backup.env names a remote (lib/compose.sh).
#
# Only names and types ever leave the config: no token is printed, logged or put in an argument.

# the sidecar's image: its rclone is the one that runs, so `check` uses that same image
RCLONE_IMAGE=itzg/mc-backup

# The upload, run by the sidecar after each backup (POST_BACKUP_SCRIPT). $1 is tar's status: 0 ok, 1 a file changed while it was read
# (the archive is whole, so it is uploaded); anything else is not uploaded. The text is fixed: the names come from the sidecar's
# environment (BACKUP_NAME, DEST_DIR, RCLONE_*), which mcctl sets from validated values only.
RCLONE_POST_SCRIPT='[ "${1:-2}" -le 1 ] && f=$(ls -t "${DEST_DIR}/${BACKUP_NAME}"-*.tar.gz 2>/dev/null | head -n 1) && [ -n "$f" ] && rclone copy "$f" "${RCLONE_REMOTE}:${RCLONE_DEST_DIR}" && rclone delete "${RCLONE_REMOTE}:${RCLONE_DEST_DIR}" --min-age "${RCLONE_KEEP_DAYS}d" --include "${BACKUP_NAME}-*.tar.gz"'

# RCLONE_AWK: "NAME TYPE" for each [section] of a rclone.conf. Reads the section names and the type lines only; every other line,
# the tokens included, is skipped.
RCLONE_AWK='
/^[ \t]*\[.*\][ \t]*$/ {
    name = $0; sub(/^[ \t]*\[/, "", name); sub(/\][ \t]*$/, "", name)
    order[++n] = name; type[name] = ""; next
}
/^[ \t]*type[ \t]*=/ {
    t = $0; sub(/^[ \t]*type[ \t]*=[ \t]*/, "", t); sub(/[ \t\r]+$/, "", t)
    if (name != "") type[name] = t
}
END { for (i = 1; i <= n; i++) print order[i], type[order[i]] }
'

# _rclone_dir -> stdout secrets/rclone (the folder, whether or not it exists)
_rclone_dir() { printf '%s\n' "$MCCTL_ROOT/secrets/rclone"; }

# _rclone_installed: 0 when secrets/rclone/rclone.conf exists
_rclone_installed() { [[ -f $(_rclone_dir)/rclone.conf ]]; }

# _rclone_valid_remote NAME: 0 for a remote name mcctl accepts (letters, digits, - and _, at most 64)
_rclone_valid_remote() { [[ ${1-} =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }

# _rclone_conf_check FILE: FILE is a rclone.conf mcctl accepts: a regular file (not a link), 1 byte to 64 KiB, with at least one
# [remote] and one of type drive. Reads this user's own file on the host; prints nothing of it but a message when it is refused.
_rclone_conf_check() {
    local f=$1 size pairs
    [[ -f $f && ! -L $f ]] || die "${f@Q} is not a regular file (a symbolic link is refused)" "$EX_USAGE"
    size=$(stat -c %s -- "$f") || die "cannot read the size of ${f@Q}" "$EX_FAIL"
    ((size > 0 && size <= 65536)) \
        || die "${f@Q} is $size bytes: a rclone.conf is a few hundred bytes (at most 64 KiB is accepted)" "$EX_REFUSED"
    pairs=$(awk "$RCLONE_AWK" "$f") || die "cannot read ${f@Q}" "$EX_FAIL"
    [[ -n $pairs ]] || die "${f@Q} has no remote (no [name] section): make one with rclone config, on a machine with a browser" "$EX_REFUSED"
    grep -q ' drive$' <<<"$pairs" \
        || die "${f@Q} has no remote of type drive (Google Drive): make one with rclone config, choosing drive" "$EX_REFUSED"
}

# _rclone_remotes -> stdout "NAME TYPE" for each remote of the installed rclone.conf. The file belongs to the game's user, so this user
# reads it through a read-only helper (DAC_READ_SEARCH); the helper runs awk with RCLONE_AWK and nothing else.
_rclone_remotes() {
    _rclone_installed || die "no rclone config is installed: install one with mcctl rclone install FILE" "$EX_REFUSED"
    _root_docker ro "$(_rclone_dir)" DAC_READ_SEARCH awk "$RCLONE_AWK" /m/rclone.conf
}

# _rclone_is_drive REMOTE: 0 when REMOTE is a remote of the installed config and its type is drive
_rclone_is_drive() {
    local list
    list=$(_rclone_remotes) || return
    grep -qxF -- "$1 drive" <<<"$list"
}

# _rclone_discard_staging: remove secrets/.rclone-new (it may belong to the game's user after a give, so the helper removes it)
_rclone_discard_staging() {
    [[ -e $MCCTL_ROOT/secrets/.rclone-new ]] || return 0
    _root_docker rw "$MCCTL_ROOT/secrets" DAC_OVERRIDE sh -c 'rm -rf -- /m/.rclone-new'
}

# _rclone_install FILE REPLACE: put FILE in place as secrets/rclone/rclone.conf. The copy is made in secrets/.rclone-new, given to the
# game's user, and then moved into place by a helper (the old folder goes first, only when REPLACE is 1). FILE itself is not changed:
# delete it afterwards, it holds the token.
_rclone_install() {
    local file=$1 replace=$2 staging=$MCCTL_ROOT/secrets/.rclone-new
    _rclone_conf_check "$file"
    if _rclone_installed && ((!replace)); then
        die "a rclone config is already installed: add --replace to replace it (the backups use whatever is installed when they run)" "$EX_REFUSED"
    fi
    mkdir_private "$MCCTL_ROOT/secrets" || die "cannot create $MCCTL_ROOT/secrets" "$EX_FAIL"
    _rclone_discard_staging || die "a leftover $staging could not be removed (see above): nothing was changed" "$EX_FAIL"
    mkdir_private "$staging" || die "cannot create $staging: nothing was changed" "$EX_FAIL"
    if ! (umask 077 && cp -- "$file" "$staging/rclone.conf") || ! chmod 600 -- "$staging/rclone.conf"; then
        rm -f -- "$staging/rclone.conf"; rmdir -- "$staging" 2>/dev/null
        die "cannot copy ${file@Q} into $staging (see above): nothing was changed" "$EX_FAIL"
    fi
    # the file first, then the folder: once the folder is the game's, this user cannot look inside it to give the file away
    if ! _give_to_group "$staging/rclone.conf" 640 || ! _give_to_group "$staging" 750; then
        _rclone_discard_staging
        die "cannot give the copy to the game's user (see above): nothing was changed" "$EX_FAIL"
    fi
    if ! _root_docker rw "$MCCTL_ROOT/secrets" DAC_OVERRIDE sh -c 'rm -rf -- /m/rclone && mv -- /m/.rclone-new /m/rclone'; then
        die "the rclone config could not be put in place (see above). The copy is still in $staging: run this command again, with --replace if an old config is there" "$EX_FAIL"
    fi
    info "rclone config installed in $(_rclone_dir). Remotes:"
    _rclone_remotes | sed 's/^/  /'
    info "now delete ${file@Q}: it holds the token, and the installed copy is the one the backups use"
}

# _rclone_check REMOTE: ask Google Drive (`rclone about`) through the sidecar's image, as the game's user, with the installed config.
# It answers whether the token works and how much space is free. The output of rclone is shown, token-free.
_rclone_check() {
    local remote=$1 out rc=0 uid
    _rclone_valid_remote "$remote" || die "REMOTE ${remote@Q} is not a remote name (letters, digits, - and _)" "$EX_USAGE"
    _rclone_installed || die "no rclone config is installed: install one with mcctl rclone install FILE" "$EX_REFUSED"
    _rclone_is_drive "$remote" || die "${remote@Q} is not a remote of type drive in the installed config (mcctl rclone remotes lists them)" "$EX_REFUSED"
    uid=$(game_uid) || exit "$EX_PREFLIGHT"
    out=$(docker run --rm --user "$uid:$uid" --cap-drop ALL --security-opt no-new-privileges \
        -e XDG_CONFIG_HOME=/config -v "$(_rclone_dir):/config/rclone" --entrypoint rclone "$RCLONE_IMAGE" about "$remote:" 2>&1) || rc=$?
    if ((rc)); then
        err "rclone could not reach ${remote}: (exit $rc). What rclone said:"
        head -n 8 <<<"$out" | sed 's/^/  /' >&2
        die "the offsite copy would fail now: check the token (a Google test app's token expires after 7 days, see docs/troubleshooting.md)" "$EX_FAIL"
    fi
    info "$remote: reachable"
    sed 's/^/  /' <<<"$out"
}

# cmd_rclone install FILE [--replace] | remotes | check REMOTE
cmd_rclone() {
    local usage="usage: mcctl rclone install FILE [--replace] | mcctl rclone remotes | mcctl rclone check REMOTE"
    local sub=${1-} file replace=0
    case $sub in
        install)
            (($# >= 2)) || die "$usage" "$EX_USAGE"
            file=$2
            shift 2
            while (($#)); do
                case $1 in
                    --replace) replace=1 ;;
                    *) die "unknown option ${1@Q}. $usage" "$EX_USAGE" ;;
                esac
                shift
            done
            _rclone_install "$file" "$replace" ;;
        remotes)
            (($# == 1)) || die "$usage" "$EX_USAGE"
            _rclone_remotes ;;
        check)
            (($# == 2)) || die "$usage" "$EX_USAGE"
            _rclone_check "$2" ;;
        *) die "$usage" "$EX_USAGE" ;;
    esac
}

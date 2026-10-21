#!/usr/bin/env bash
# shellcheck shell=bash
# Panel extensions and the active theme, from extensions/extensions.lock. Sourced by ./ptero.
#
# Desired state lives in config/deploy.env (PANEL_EXTENSIONS=a,b,c  PANEL_THEME=unix|classic); `./ptero setup` applies it,
# `./ptero ext install` re-applies it. Each package is pinned by sha256 and must match the version in the lock file.
# Nothing is ever removed automatically: extensions keep their database tables even when removed, so removal is a human decision.

ext_lock() { printf '%s/extensions/extensions.lock\n' "$PTERO_ROOT"; }

ext_wanted() { local a; IFS=, read -ra a <<<"${PANEL_EXTENSIONS:-}"; printf '%s\n' "${a[@]}" | sed '/^$/d'; }

# ext_lock_entry ID -> "sha version source" or nothing
ext_lock_entry() { awk -v id="$1" '$1 == id {print $2, $3, $4; exit}' <(grep -v '^[[:space:]]*#' "$(ext_lock)"); }

# installed extensions as "id version state error" lines
ext_installed() {
    compose exec -T panel php artisan p:extension:list 2>/dev/null |
        awk -F'|' '/^\|/ && $2 !~ /ID/ { for (i = 2; i <= 7; i++) gsub(/^ +| +$/, "", $i); print $2, $4, $6, ($7 == "" ? "-" : $7) }'
}

# the active theme id, or "classic"
theme_active() {
    local t
    t=$(compose exec -T panel php artisan p:theme:list 2>/dev/null | awk -F'|' '/^\|/ && $5 ~ /^ *active *$/ { gsub(/^ +| +$/, "", $2); print $2; exit }')
    echo "${t:-classic}"
}

# ext_fetch ID SHA SOURCE DEST : put the package at DEST, verified
ext_fetch() {
    local id=$1 sha=$2 src=$3 dest=$4 got
    case $src in
        https://*) curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 300 -o "$dest" "$src" || { err "download failed: $src"; return 1; } ;;
        local:*) cp -- "$PTERO_ROOT/extensions/${src#local:}" "$dest" || { err "missing local package: ${src#local:}"; return 1; } ;;
        *) err "$id: unsupported source '$src' in extensions.lock"; return 1 ;;
    esac
    got=$(sha256sum "$dest" | cut -d' ' -f1)
    [[ $got == "$sha" ]] || { err "$id: sha256 mismatch (got ${got:0:16}..., locked ${sha:0:16}...). Refusing to install"; return 1; }
}

# ext_install_one ID SHA VERSION SOURCE [REPLACE]
# REPLACE=1 when the Panel already has this id installed (any state, any version). The Panel then refuses a plain install
# ("already installed ... must be confirmed. Pass --replace"), even when the installed copy is "not registered".
ext_install_one() {
    local id=$1 sha=$2 ver=$3 src=$4 replace=${5:-0} file ext tmp meta pv flags=(--enable --no-interaction)
    ext=${src##*.}; [[ $ext == zip || $ext == pteroext ]] || { err "$id: package must end in .zip or .pteroext"; return 1; }
    file="$PTERO_TMP/$id.$ext"
    ext_fetch "$id" "$sha" "$src" "$file" || return 1
    meta=$(python3 "$PTERO_ROOT/lib/ext_vet.py" info "$file") || { err "$id: not a Panel extension package"; return 1; }
    pv=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["id"], d["version"])' "$meta")
    [[ $pv == "$id $ver" ]] || { err "$id: the package says '$pv' but extensions.lock says '$id $ver'"; return 1; }
    tmp="/tmp/ptero-ext-$id.$ext"
    compose exec -T panel sh -c "umask 077; cat >'$tmp'" <"$file" || { err "$id: cannot hand the package to the Panel container"; return 1; }
    local out rc
    ((replace)) && flags+=(--replace)
    out=$(compose exec -T panel php artisan p:extension:install "$tmp" "${flags[@]}" 2>&1); rc=$?
    compose exec -T panel rm -f "$tmp" >/dev/null 2>&1
    if [[ $rc -ne 0 ]]; then printf '%s\n' "$out" | tail -n 8 >&2; err "$id: p:extension:install failed"; return 1; fi
    # upstream: the web user must own both extension directories
    compose exec -T panel chown -R nginx:nginx /app/extensions /app/public/assets/extensions >/dev/null 2>&1 \
        || warn "could not chown the extension directories to nginx; if the Panel shows asset errors run: ./ptero compose exec panel chown -R nginx:nginx /app/extensions /app/public/assets/extensions"
    info "installed extension $id $ver"
}

# ext_apply [--no-backup] : make the Panel match PANEL_EXTENSIONS / PANEL_THEME. Returns 1 if anything failed.
ext_apply() {
    local backup=1 rc=0 id entry sha ver src todo=() installed line
    [[ ${1:-} == --no-backup ]] && backup=0
    if [[ ${PANEL_EXTENSIONS_ENABLED:-true} != true ]]; then info "extensions are switched off (PANEL_EXTENSIONS_ENABLED=false): skipping"; return 0; fi
    local wanted; wanted=$(ext_wanted)
    [[ -z $wanted && ${PANEL_THEME:-classic} == classic ]] && return 0
    installed=$(ext_installed)
    while read -r id; do
        [[ -n $id ]] || continue
        entry=$(ext_lock_entry "$id")
        if [[ -z $entry ]]; then err "extension '$id' is in PANEL_EXTENSIONS but not in extensions/extensions.lock (vet it first: ./ptero ext vet <file>)"; rc=1; continue; fi
        read -r sha ver src <<<"$entry"
        line=$(awk -v id="$id" '$1 == id' <<<"$installed")
        if [[ -n $line ]] && read -r _ iv st er <<<"$line" && [[ $iv == "$ver" && $st == enabled && $er == - ]]; then
            info "extension $id $ver: already installed and enabled"
        else
            todo+=("$id")
        fi
    done <<<"$wanted"
    ((rc)) && return 1
    if ((${#todo[@]})); then
        if ((backup)); then
            local b; b=$(backup_create pre-extensions) || { err "backup failed: NOT touching extensions (migrations cannot be undone). Fix the backup first"; return 1; }
            info "backup before installing extensions: $b"
        fi
        for id in "${todo[@]}"; do
            read -r sha ver src <<<"$(ext_lock_entry "$id")"
            local replace=0
            awk -v id="$id" '$1 == id {f = 1} END {exit !f}' <<<"$installed" && replace=1
            ext_install_one "$id" "$sha" "$ver" "$src" "$replace" || rc=1
        done
    fi
    local want=${PANEL_THEME:-classic} active; active=$(theme_active)
    if [[ $want != "$active" ]]; then
        if [[ $want == classic ]]; then compose exec -T panel php artisan p:theme:reset >/dev/null && info "theme: back to classic" || rc=1
        else compose exec -T panel php artisan p:theme:activate "$want" >/dev/null 2>&1 && info "theme: $want is now active" || { err "cannot activate theme '$want' (is it listed in PANEL_EXTENSIONS and installed?)"; rc=1; }; fi
    else info "theme: $want already active"; fi
    return $rc
}

cmd_ext() {
    local sub=${1:-}; shift || true
    case $sub in
        install)
            local nb=""; [[ ${1:-} == --no-backup ]] && nb=--no-backup
            prepare 0
            [[ $(svc_state panel) == healthy ]] || die "the Panel is not running: ./ptero setup" $EX_REFUSED
            ext_apply $nb || exit $EX_FAIL
            ;;
        list)
            prepare 0
            local installed id entry sha ver src line
            installed=$(ext_installed)
            printf '%-16s %-10s %-10s %s\n' ID LOCKED INSTALLED WANTED
            while read -r id sha ver src; do
                [[ -n $id ]] || continue
                line=$(awk -v id="$id" '$1 == id {print $2 "/" $3}' <<<"$installed")
                printf '%-16s %-10s %-10s %s\n' "$id" "$ver" "${line:--}" "$(ext_wanted | grep -qx "$id" && echo yes || echo no)"
            done < <(grep -v '^[[:space:]]*#' "$(ext_lock)" | awk 'NF >= 4')
            printf 'theme: wanted %s, active %s\n' "${PANEL_THEME:-classic}" "$(theme_active)"
            ;;
        vet)
            [[ -f ${1:-} ]] || die "usage: ./ptero ext vet <package.zip|.pteroext>" $EX_USAGE
            python3 "$PTERO_ROOT/lib/ext_vet.py" vet "$1"
            ;;
        *) die "usage: ./ptero ext {install [--no-backup]|list|vet FILE}" $EX_USAGE ;;
    esac
}

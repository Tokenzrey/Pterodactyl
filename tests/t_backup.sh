#!/usr/bin/env bash
# backup, restore, restore-config, encrypted backups (with a stand-in for `age`)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox; trap sandbox_cleanup EXIT

valid_config
seed_installed
p setup
assert_eq 0 "$RC" "setup on the seeded installation"

echo "backup"
p backup --label first
assert_eq 0 "$RC" "backup succeeds"
B=$(ls -d "$R"/backups/*-first)
assert_file "$B/db.sql.gz" "db.sql.gz"; assert_file "$B/panel_var.tgz" "panel_var.tgz"; assert_file "$B/extensions.tgz" "extensions.tgz"
assert_file "$B/config.tgz" "config.tgz"; assert_file "$B/MANIFEST" "MANIFEST"; assert_file "$B/SHA256SUMS" "SHA256SUMS"
assert_mode "$B" 700 "backup directory is 700"
assert_mode "$B/db.sql.gz" 600 "db dump is 600"
assert_mode "$B/panel_var.tgz" 600 "panel_var archive is 600 (it holds APP_KEY)"
assert_eq 0 "$(cd "$B" && sha256sum --check --quiet SHA256SUMS >/dev/null 2>&1; echo $?)" "checksums verify"
assert_contains "$(gzip -dc "$B/db.sql.gz")" "CREATE TABLE users" "dump contains the data"
assert_contains "$(tar -xzOf "$B/panel_var.tgz" ./.env)" "APP_KEY=base64:ORIGINALKEY" "APP_KEY is in the archive"
assert_contains "$(tar -tzf "$B/config.tgz")" "repo/secrets/db_password" "config.tgz carries the secrets"
assert_contains "$(cat "$B/MANIFEST")" "panel_image=ghcr.io/pterodactyl/panel@sha256:" "manifest records the pinned image"
ls "$R"/backups | grep -q partial && fail "no .partial leftovers" || pass "no .partial leftovers"

echo "backup failures never leave something that looks complete"
n_before=$(ls "$R/backups" | grep -vc partial)
FAKE_DUMP_FAIL=1 p backup --label broken
assert_eq 1 "$RC" "failed dump: exit 1"
assert_eq "$n_before" "$(ls "$R/backups" | grep -vc partial)" "no new complete backup directory"
FAKE_DUMP_TRUNCATE=1 p backup --label trunc
assert_eq 1 "$RC" "truncated dump (no 'Dump completed' trailer) is rejected"
assert_contains "$OUT" "incomplete or corrupt" "and says why"
echo unhealthy >"$FAKE_STATE/health/database"
p backup --label nodb
assert_eq 1 "$RC" "backup refuses when the database is not healthy"
echo healthy >"$FAKE_STATE/health/database"

echo "restore: refusals first (nothing may change)"
snap() { sha256sum "$FAKE_STATE/db.sql" "$FAKE_STATE/volumes/pterodactyl_panel_var/.env" | sha256sum; }
printf -- '-- CHANGED later\n' >"$FAKE_STATE/db.sql"
printf 'APP_KEY=base64:DIFFERENT\n' >"$FAKE_STATE/volumes/pterodactyl_panel_var/.env"
s0=$(snap)
p restore "$B"
assert_eq 4 "$RC" "no terminal and no --yes: refused"
assert_eq "$s0" "$(snap)" "nothing changed"
cp -r "$B" "$SB/corrupt"; echo x >>"$SB/corrupt/db.sql.gz"
p restore --yes "$SB/corrupt"
assert_eq 4 "$RC" "a corrupted backup is refused"
assert_contains "$OUT" "checksum mismatch" "reports the checksum mismatch"
assert_eq "$s0" "$(snap)" "nothing changed after the corrupt-backup refusal"
cp -r "$B" "$SB/oldver"; sed -i 's#^panel_image=.*#panel_image=ghcr.io/pterodactyl/panel@sha256:1111111111111111111111111111111111111111111111111111111111111111#' "$SB/oldver/MANIFEST"
(cd "$SB/oldver" && sha256sum db.sql.gz panel_var.tgz extensions.tgz config.tgz MANIFEST >SHA256SUMS)
p restore --yes "$SB/oldver"
assert_eq 4 "$RC" "a backup from another Panel version is refused"
assert_contains "$OUT" "version mismatch" "explains it"
assert_eq "$s0" "$(snap)" "nothing changed after the version refusal"
p restore --yes "$R/backups"
assert_eq 4 "$RC" "a directory that is not a backup is refused"

echo "restore: the safe path"
n=$(ls "$R/backups" | wc -l)
p restore --yes "$B"
assert_eq 0 "$RC" "restore succeeds"
assert_contains "$(cat "$FAKE_STATE/db.sql")" "CREATE TABLE users" "database content is back"
assert_contains "$(cat "$FAKE_STATE/volumes/pterodactyl_panel_var/.env")" "ORIGINALKEY" "APP_KEY is back"
assert_eq "$((n + 1))" "$(ls "$R/backups" | wc -l)" "exactly one new directory: the safety backup"
ls "$R/backups" | grep -q 'pre-restore' && pass "safety backup is labelled pre-restore" || fail "safety backup is labelled pre-restore"
assert_file "$B/db.sql.gz" "the backup that was restored is still there"
assert_contains "$(gzip -dc "$R"/backups/*-pre-restore/db.sql.gz)" "CHANGED later" "the safety backup holds the state that was replaced"

echo "restore: failing import leaves the Panel stopped, not half-started"
sleep 1   # backup names have 1-second resolution and refuse to overwrite
FAKE_IMPORT_FAIL=1 p restore --yes "$B"
assert_eq 1 "$RC" "failed import: exit 1"
assert_contains "$OUT" "left STOPPED" "says the Panel was left stopped"
[[ ! -e $FAKE_STATE/running/panel ]] && pass "panel is not running" || fail "panel is not running"
unset FAKE_IMPORT_FAIL

echo "restore-config on a clean checkout"
p up
valid_config
cp -r "$R" "$SB/other"; rm -rf "$SB/other/secrets" "$SB/other/config/deploy.env" "$SB/other/backups"
R_SAVE=$R; R=$SB/other
p restore-config --yes "$B"
assert_eq 0 "$RC" "restore-config fills an empty checkout"
assert_mode "$R/secrets/db_password" 600 "restored secret is 600"
assert_eq "$(cat "$R_SAVE/secrets/db_password")" "$(cat "$R/secrets/db_password")" "same DB password as the original"
p restore-config --yes "$B"
assert_eq 4 "$RC" "refuses to overwrite existing config/secrets"
R=$R_SAVE

echo "encrypted backups (age is stubbed: this tests the plumbing, not the cryptography)"
cat >"$SB/host/bin/age" <<'EOF'
#!/usr/bin/env bash
# stub: "encrypt" = cat; records the recipient
mode=enc; recip=""; out=""; ident=""
while (($#)); do case $1 in -d) mode=dec ;; -r) recip=$2; shift ;; -o) out=$2; shift ;; -i) ident=$2; shift ;; *) in=$1 ;; esac; shift; done
echo "age mode=$mode recipient=$recip" >>"$FAKE_STATE/age.log"
if [[ $mode == enc ]]; then if [[ -n $out ]]; then cat >"$out"; else cat; fi; else cat "${in:-/dev/stdin}"; fi
EOF
chmod +x "$SB/host/bin/age"; export PATH="$SB/host/bin:$PATH"
KEY=age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
sed -i "s/^BACKUP_AGE_RECIPIENT=.*/BACKUP_AGE_RECIPIENT=$KEY/" "$R/config/deploy.env"
p up
p backup --label enc
assert_eq 0 "$RC" "encrypted backup succeeds"
E=$(ls "$R"/backups/*-enc.tar.age)
assert_file "$E" "a single .tar.age file"
ls -d "$R"/backups/*-enc 2>/dev/null | grep -q . && fail "plaintext directory removed after encryption" || pass "plaintext directory removed after encryption"
assert_contains "$(cat "$FAKE_STATE/age.log")" "recipient=$KEY" "encrypted to the configured public key"
echo "AGE-SECRET-KEY-stub" >"$SB/id.txt"
sleep 1   # same reason as above: the safety backup of this restore must not land in the second of the previous one
p restore --yes --identity "$SB/id.txt" "$E"
assert_eq 0 "$RC" "restore from an encrypted backup with --identity"
p restore --yes "$E"
assert_eq 1 "$RC" "encrypted restore without --identity fails"
assert_contains "$OUT" "--identity" "tells how to pass the key"
sed -i "s/^BACKUP_AGE_RECIPIENT=.*/BACKUP_AGE_RECIPIENT=/" "$R/config/deploy.env"

echo "temp files are cleaned up"
leftover=$(find "$SB/tmp" -mindepth 1 -maxdepth 1 -name 'ptero.*' | wc -l)
assert_eq 0 "$leftover" "no ptero.* temp directories left behind (decrypted data included)"

finish

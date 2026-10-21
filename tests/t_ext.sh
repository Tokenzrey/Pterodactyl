#!/usr/bin/env bash
# Panel extensions and theme: the real lock file, the vetting tool, and the install/reconcile logic against a fake Panel
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox; trap sandbox_cleanup EXIT
cd "$REPO" || exit 1

echo "the shipped lock file"
python3 -B - <<'PY' && pass "extensions.lock is well formed, pinned and matches the local package" || fail "extensions.lock is well formed, pinned and matches the local package"
import hashlib, re, sys, json, subprocess
rows = [l.split() for l in open("extensions/extensions.lock") if l.strip() and not l.lstrip().startswith("#")]
assert {r[0] for r in rows} == {"announcements", "custom-buttons", "unix", "redirect", "oauth-login", "subdomain-manager",
    "player-manager", "minecraft-suite", "file-transfer", "modpack-installer", "multi-node-sync"}, rows
for id_, sha, ver, src in rows:
    assert re.fullmatch(r"[0-9a-f]{64}", sha), id_
    assert re.fullmatch(r"\d+\.\d+\.\d+", ver), id_
    if src.startswith("https://"):
        assert "/releases/download/v" in src and "latest" not in src, f"{id_}: pin a release tag, never latest"
    else:
        assert src.startswith("local:")
        data = open("extensions/" + src[6:], "rb").read()
        assert hashlib.sha256(data).hexdigest() == sha, f"{id_}: local package does not match its pin"
        info = json.loads(subprocess.check_output([sys.executable, "-B", "lib/ext_vet.py", "info", "extensions/" + src[6:]]))
        kind = "theme" if id_ == "unix" else "extension"
        assert (info["id"], info["version"], info["type"]) == (id_, ver, kind), info
PY
out=$(python3 -B lib/ext_vet.py vet extensions/unix/unix.pteroext); rc=$?
assert_eq 0 "$rc" "the unix theme package passes the vet tripwire"
assert_contains "$out" '"type": "theme"' "and is a theme"
assert_contains "$(cat extensions/unix/extension.json)" '"schemes"' "its source manifest declares both colour schemes (day/night)"
assert_contains "$(cat extensions/unix/src/theme.css)" ".light" "the stylesheet source defines the day palette"
assert_contains "$(cat extensions/unix/src/theme.css)" ".dark" "and the night palette"

echo "vet flags what deserves a human look"
mkdir -p "$SB/pk"
python3 -B - "$SB/pk" <<'PY'
import json, sys, zipfile
d = sys.argv[1]
def pkg(name, php):
    with zipfile.ZipFile(f"{d}/{name}.zip", "w") as z:
        z.writestr("extension.json", json.dumps({"id": name, "name": name, "version": "1.0.0", "type": "extension"}))
        z.writestr("src/X.php", php)
pkg("clean", "<?php\nreturn 1;\n")
pkg("evil", "<?php\nshell_exec($_GET['c']);\n$x = base64_decode($y);\nHttp::get('https://x');\n")
PY
python3 -B lib/ext_vet.py vet "$SB/pk/clean.zip" >/dev/null; assert_eq 0 "$?" "clean package: exit 0"
out=$(python3 -B lib/ext_vet.py vet "$SB/pk/evil.zip"); rc=$?
assert_eq 1 "$rc" "suspicious package: exit 1"
assert_contains "$out" "runs system commands" "reports command execution"
assert_contains "$out" "outbound HTTP" "reports outbound HTTP"
assert_contains "$out" "decodes opaque data" "reports opaque decoding"
echo "not a zip" >"$SB/pk/bad.zip"
python3 -B lib/ext_vet.py info "$SB/pk/bad.zip" >/dev/null 2>&1; assert_eq 2 "$?" "a file that is not an extension package: exit 2"

# ---- the installer logic against a fake Panel, with a test lock of local packages --------------------------------
valid_config
mkpkg() { # mkpkg id version type
    mkdir -p "$R/extensions/pkg"
    python3 -B - "$R/extensions/pkg/$1.zip" "$1" "$2" "$3" <<'PY'
import json, sys, zipfile
path, id_, ver, typ = sys.argv[1:]
with zipfile.ZipFile(path, "w") as z:
    z.writestr("extension.json", json.dumps({"id": id_, "name": id_, "version": ver, "type": typ}))
PY
}
mklock() { # mklock id:version:type ...
    : >"$R/extensions/extensions.lock"
    local spec id ver typ
    for spec in "$@"; do
        IFS=: read -r id ver typ <<<"$spec"
        mkpkg "$id" "$ver" "$typ"
        printf '%s  %s  %s  local:pkg/%s.zip\n' "$id" "$(sha256sum "$R/extensions/pkg/$id.zip" | cut -d' ' -f1)" "$ver" "$id" >>"$R/extensions/extensions.lock"
    done
}
setcfg() { sed -i "s/^PANEL_EXTENSIONS=.*/PANEL_EXTENSIONS=$1/; s/^PANEL_THEME=.*/PANEL_THEME=$2/" "$R/config/deploy.env"; }

echo "configuration rules"
mklock a1:1.0.0:extension unix2:1.0.0:theme
setcfg a1,unix2 unix2
p status
assert_not_contains "$OUT" "extension" "valid extension config accepted"
setcfg a1,nope classic
p status
assert_eq 3 "$RC" "an extension that is not in the lock is refused"
assert_contains "$OUT" "not in extensions/extensions.lock" "says why"
setcfg a1 unix2
p status
assert_eq 3 "$RC" "a theme that is not among the extensions is refused"
assert_contains "$OUT" "must also be listed in PANEL_EXTENSIONS" "says why"
setcfg 'a1;rm' classic
p status
assert_eq 3 "$RC" "a malformed list is refused"

echo "install / reconcile"
seed_installed; echo healthy >"$FAKE_STATE/health/panel"; touch "$FAKE_STATE/running/panel"; echo healthy >"$FAKE_STATE/health/database"; touch "$FAKE_STATE/running/database"
setcfg a1,unix2 unix2
: >"$FAKE_STATE/calls.log"
p ext install
assert_eq 0 "$RC" "ext install succeeds"
assert_contains "$(calls)" "p:extension:install /tmp/ptero-ext-a1.zip --enable" "extension a1 installed and enabled"
assert_contains "$(calls)" "p:extension:install /tmp/ptero-ext-unix2.zip --enable" "theme unix2 installed and enabled"
assert_contains "$(calls)" "p:theme:activate unix2" "and the theme activated"
assert_contains "$(calls)" "chown -R nginx:nginx /app/extensions" "web user owns the extension directories (upstream requirement)"
assert_contains "$(calls)" "rm -f /tmp/ptero-ext-a1.zip" "the package is removed from the container afterwards"
ls "$R/backups" | grep -q pre-extensions && pass "a backup was taken before touching extensions" || fail "a backup was taken before touching extensions"
b_line=$(calls | grep -n 'mariadb-dump' | head -n1 | cut -d: -f1); i_line=$(calls | grep -n 'p:extension:install' | head -n1 | cut -d: -f1)
[[ -n $b_line && -n $i_line && $b_line -lt $i_line ]] && pass "the backup precedes the first install" || fail "the backup precedes the first install"
: >"$FAKE_STATE/calls.log"
p ext install
assert_eq 0 "$RC" "second run succeeds"
assert_not_contains "$(calls)" "p:extension:install" "nothing is reinstalled when versions match (idempotent)"
assert_not_contains "$(calls)" "mariadb-dump" "and no needless backup"
assert_contains "$OUT" "already installed and enabled" "says so"
assert_contains "$OUT" "theme: unix2 already active" "theme unchanged"

echo "version drift reinstalls just that extension"
mklock a1:1.1.0:extension unix2:1.0.0:theme
: >"$FAKE_STATE/calls.log"
mkdir -p "$FAKE_STATE/ext_versions"; echo 1.1.0 >"$FAKE_STATE/ext_versions/a1"
sleep 1
p ext install
assert_eq 0 "$RC" "update to the locked version succeeds"
assert_contains "$(calls)" "ptero-ext-a1.zip" "a1 reinstalled"
assert_not_contains "$(calls)" "ptero-ext-unix2.zip" "unix2 untouched"

echo "an installed extension that is not registered is replaced, not refused (Panel: 'already installed ... --replace')"
mklock a1:1.0.0:extension unix2:1.0.0:theme
rm -f "$FAKE_STATE/ext_versions/a1"; sleep 1
p ext install >/dev/null
assert_eq 0 "$RC" "precondition: a fresh install succeeds"
sed -i 's/^a1|\(.*\)|enabled|-$/a1|\1|not registered|-/' "$FAKE_STATE/ext.list"
assert_contains "$(cat "$FAKE_STATE/ext.list")" "a1|1.0.0|not registered|-" "a1 is now installed but not registered, the state seen in a real Panel"
sleep 1   # backup names have 1-second resolution: a second backup in the same second would be refused
: >"$FAKE_STATE/calls.log"
p ext install
assert_eq 0 "$RC" "the same version in state 'not registered' is re-applied and succeeds"
assert_contains "$(calls)" "p:extension:install /tmp/ptero-ext-a1.zip --enable --no-interaction --replace" "with --replace (the Panel would otherwise refuse)"
assert_not_contains "$OUT" "must be confirmed" "and the Panel's refusal does not appear"
assert_contains "$(cat "$FAKE_STATE/ext.list")" "a1|1.0.0|enabled|-" "a1 is enabled again"
sleep 1
: >"$FAKE_STATE/calls.log"
p ext install >/dev/null
assert_not_contains "$(calls)" "p:extension:install" "a second run with a registered extension does not reinstall"

echo "a plain install of an installed id is refused by the Panel (the fake reproduces it)"
mklock a1:1.0.0:extension unix2:1.0.0:theme
rm -f "$FAKE_STATE/ext_versions/a1"
cp "$R/extensions/pkg/a1.zip" "$SB/a1.zip"
ptmp=/tmp/ptero-ext-a1.zip
out=$(docker compose -p pterodactyl exec -T panel php artisan p:extension:install "$ptmp" --enable --no-interaction 2>&1); rc=$?
assert_eq 1 "$rc" "the fake Panel refuses a plain install of an id it already has"
assert_contains "$out" "must be confirmed. Pass --replace" "with the Panel's own wording"

echo "refusals"
mklock a1:1.0.0:extension unix2:1.0.0:theme
echo tampered >>"$R/extensions/pkg/a1.zip"
rm -f "$FAKE_STATE/ext.list"; : >"$FAKE_STATE/calls.log"
sleep 1
p ext install
assert_eq 1 "$RC" "a package whose bytes differ from the lock is refused"
assert_contains "$OUT" "sha256 mismatch" "says so"
assert_not_contains "$(calls)" "ptero-ext-a1" "and never reaches the Panel"
mklock a1:2.0.0:extension unix2:1.0.0:theme
python3 -B - "$R/extensions/pkg/a1.zip" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("extension.json", json.dumps({"id": "a1", "name": "a1", "version": "9.9.9", "type": "extension"}))
PY
sed -i "s/^a1 .*/a1  $(sha256sum "$R/extensions/pkg/a1.zip" | cut -d' ' -f1)  2.0.0  local:pkg\/a1.zip/" "$R/extensions/extensions.lock"
rm -f "$FAKE_STATE/ext.list"; : >"$FAKE_STATE/calls.log"
sleep 1
p ext install
assert_eq 1 "$RC" "a package whose own version differs from the lock is refused"
assert_contains "$OUT" "says 'a1 9.9.9'" "says what it found"
mklock a1:1.0.0:extension unix2:1.0.0:theme
rm -f "$FAKE_STATE/ext.list"; sleep 1
FAKE_DUMP_FAIL=1 p ext install
assert_eq 1 "$RC" "a failed backup stops everything before any change"
assert_contains "$OUT" "NOT touching extensions" "and says why"
rm -f "$FAKE_STATE/ext.list"; sleep 1
FAKE_EXT_FAIL=1 p ext install
assert_eq 1 "$RC" "a Panel-side install failure is reported"
sed -i 's/^PANEL_EXTENSIONS_ENABLED=.*/PANEL_EXTENSIONS_ENABLED=false/' "$R/config/deploy.env"
: >"$FAKE_STATE/calls.log"
p ext install
assert_eq 0 "$RC" "with the kill-switch off nothing is attempted"
assert_not_contains "$(calls)" "p:extension" "no extension command is run"
sed -i 's/^PANEL_EXTENSIONS_ENABLED=.*/PANEL_EXTENSIONS_ENABLED=true/' "$R/config/deploy.env"

echo "theme back to classic; nothing is ever removed"
rm -f "$FAKE_STATE/ext.list"; rm -rf "$FAKE_STATE/ext_versions"; sleep 1
p ext install >/dev/null
setcfg a1 classic
: >"$FAKE_STATE/calls.log"
p ext install
assert_contains "$(calls)" "p:theme:reset" "PANEL_THEME=classic resets the theme"
assert_not_contains "$(calls)" "p:extension:remove" "dropping unix2 from the list does not remove it (tables would remain anyway)"
p ext list
assert_contains "$OUT" "unix2" "list shows locked packages"

echo "setup applies the desired state, the kill-switch reaches the Panel container"
rm -f "$FAKE_STATE/ext.list" "$FAKE_STATE/theme.active"; setcfg a1,unix2 unix2; sleep 1
p setup
assert_eq 0 "$RC" "setup succeeds"
assert_contains "$OUT" "applying Panel extensions and theme" "setup runs the extension step"
assert_contains "$(calls)" "p:theme:activate unix2" "theme active after setup"
setcfg a1,unix2 unix2; rm -f "$FAKE_STATE/ext.list"; sleep 1
FAKE_EXT_FAIL=1 p setup
assert_eq 0 "$RC" "a failing extension does not fail setup (the Panel is up)"
assert_contains "$OUT" "./ptero ext install" "and says how to retry"
assert_contains "$(cat "$REPO/compose.yml")" "PTERODACTYL_EXTENSIONS_ENABLED: \${PANEL_EXTENSIONS_ENABLED:-true}" "compose passes the kill-switch to the Panel"
assert_contains "$(cat "$REPO/compose.yml")" "APP_ACTIVITY_PRUNE_DAYS" "and the audit-log retention"

finish

#!/usr/bin/env bash
# Minimal test helpers (no framework). Each t_*.sh sources this, runs checks, and exits non-zero on any failure.
# Nothing here talks to a real Docker daemon, Cloudflare, or the network: docker/curl/systemctl are fakes in tests/fakebin.

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T_PASS=0 T_FAIL=0
T_FILE=$(basename "${BASH_SOURCE[1]:-test}")

pass() { T_PASS=$((T_PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2" | head -n 8; }

assert_eq()           { if [[ $1 == "$2" ]]; then pass "$3"; else fail "$3" "expected '$1', got '$2'"; fi; }
assert_contains()     { if [[ $1 == *"$2"* ]]; then pass "$3"; else fail "$3" "missing '$2' in: ${1:0:400}"; fi; }
assert_not_contains() { if [[ $1 != *"$2"* ]]; then pass "$3"; else fail "$3" "unexpected '$2' in: ${1:0:400}"; fi; }
assert_file()         { if [[ -e $1 ]]; then pass "$2"; else fail "$2" "missing file $1"; fi; }
assert_no_file()      { if [[ ! -e $1 ]]; then pass "$2"; else fail "$2" "unexpected file $1"; fi; }
assert_mode()         { local m; m=$(stat -c %a "$1" 2>/dev/null); assert_eq "$2" "$m" "$3"; }
calls() { cat "$FAKE_STATE/calls.log" 2>/dev/null; }
count_calls() { calls | grep -c -- "$1"; }

finish() {
    printf '%s: %d passed, %d failed\n' "$T_FILE" "$T_PASS" "$T_FAIL"
    [[ $T_FAIL -eq 0 ]]
}

# sandbox: a throw-away copy of the repo + a fake host. Everything the tests touch lives under $SB.
sandbox() {
    SB=$(mktemp -d "${TMPDIR:-/tmp}/ptero-test.XXXXXX")
    R=$SB/root
    mkdir -p "$R/config" "$SB/state" "$SB/host/bin" "$SB/host/etc" "$SB/host/systemd" "$SB/tmp"
    cp -r "$REPO/ptero" "$REPO/lib" "$REPO/compose.yml" "$REPO/systemd" "$REPO/eggs" "$REPO/extensions" "$R/"
    cp "$REPO/config/versions.env" "$REPO/config/deploy.env.example" "$R/config/"
    chmod +x "$R/ptero"
    export FAKE_STATE=$SB/state FAKE_PROJECT=pterodactyl
    export PATH="$REPO/tests/fakebin:$PATH"
    export PTERO_TEST_MODE=1 PTERO_PREFLIGHT_SKIP=net TMPDIR=$SB/tmp
    export PTERO_WINGS_BIN=$SB/host/bin/wings PTERO_WINGS_ETC=$SB/host/etc/pterodactyl PTERO_SYSTEMD_DIR=$SB/host/systemd
    unset FAKE_DUMP_FAIL FAKE_DUMP_TRUNCATE FAKE_IMPORT_FAIL FAKE_MIGRATE_RC FAKE_PULL_RC FAKE_UP_RC FAKE_NETWORKS FAKE_DOCKER_DOWN FAKE_WINGS_BIN
    unset FAKE_UFW_FAIL FAKE_UFW_DROP_RULES FAKE_SSHD_NONE FAKE_SSHD_PORT FAKE_DOCKER_PS PTERO_SS SSH_CONNECTION
    touch "$SB/state/ipt.chain"
    : >"$SB/state/http_map"
    printf '%s\n' 'http://127.0.0.1:18081/auth/login* 200' 'http://127.0.0.1:18443/* 401' \
        'https://panel.mytest.dev/* 200' 'https://wings.mytest.dev/* 401' >"$SB/state/http_map"
}
sandbox_cleanup() { [[ -n ${SB:-} && -d $SB ]] && rm -rf -- "$SB"; }

# p ARGS... : run ./ptero in the sandbox with stdin closed (no terminal). Output in $OUT, status in $RC.
p() { OUT=$(cd "$R" && ./ptero "$@" 2>&1 </dev/null); RC=$?; }

# valid_config: init + a real-looking deploy.env + a well-formed (fake) tunnel token
valid_config() {
    p init
    sed -i \
        -e 's/^PANEL_FQDN=.*/PANEL_FQDN=panel.mytest.dev/' \
        -e 's/^WINGS_FQDN=.*/WINGS_FQDN=wings.mytest.dev/' \
        -e 's/^ADMIN_EMAIL=.*/ADMIN_EMAIL=ops@mytest.dev/' \
        -e 's/^PTERO_ACCEPT_BETA=.*/PTERO_ACCEPT_BETA=yes/' \
        -e 's/^PANEL_EXTENSIONS=.*/PANEL_EXTENSIONS=/' \
        -e 's/^PANEL_THEME=.*/PANEL_THEME=classic/' \
        -e 's/^PANEL_BIND_PORT=.*/PANEL_BIND_PORT=18081/' \
        -e 's/^WINGS_API_PORT=.*/WINGS_API_PORT=18443/' \
        -e 's/^TUNNEL_METRICS_PORT=.*/TUNNEL_METRICS_PORT=12041/' \
        -e 's#^PANEL_EDGE_SUBNET=.*#PANEL_EDGE_SUBNET=10.77.250.0/24#' \
        "$R/config/deploy.env"
    printf '%s' '{"a":"0123456789abcdef","t":"11111111-2222-3333-4444-555555555555","s":"c2VjcmV0c2VjcmV0c2VjcmV0"}' | base64 -w0 >"$R/secrets/tunnel_token"
    chmod 600 "$R/secrets/tunnel_token"
}

# games_config: enable the game router in the sandbox's deploy.env
games_config() {
    sed -i -e 's/^GAMES_ENABLED=.*/GAMES_ENABLED=yes/' -e 's/^GAMES_DOMAIN=.*/GAMES_DOMAIN=mc.mytest.dev/' "$R/config/deploy.env"
}

# fake host state helpers
seed_installed() { # DB migrated + APP_KEY present
    echo 1 >"$FAKE_STATE/db_migrated"
    mkdir -p "$FAKE_STATE/volumes/pterodactyl_panel_var"
    printf 'APP_KEY=base64:ORIGINALKEY\nHASHIDS_SALT=salt\n' >"$FAKE_STATE/volumes/pterodactyl_panel_var/.env"
    for v in panel_extensions panel_extension_assets; do mkdir -p "$FAKE_STATE/volumes/pterodactyl_$v"; done
    echo "ext" >"$FAKE_STATE/volumes/pterodactyl_panel_extensions/a.txt"
    printf -- '-- original panel data\nCREATE TABLE users (id int);\n' >"$FAKE_STATE/db.sql"
}

#!/usr/bin/env bash
# Wings: config check/patch (pure), then install/configure/update against a fake host
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox; trap sandbox_cleanup EXIT
FIX=$REPO/tests/fixtures/wings-config.yml
WC="python3 $REPO/lib/wings_config.py"

echo "wings_config.py: check"
out=$($WC check "$FIX" --remote https://panel.mytest.dev --port 18443); rc=$?
assert_eq 0 "$rc" "the Panel-generated fixture passes the structural check"
assert_contains "$out" "api.port is '8080', expected '18443'" "warns about the port before patching"
assert_contains "$out" "api.host is '0.0.0.0'" "warns about listening beyond loopback"
assert_contains "$out" "system.sftp.bind_address is '0.0.0.0'" "warns about SFTP listening on every interface"

echo "wings_config.py: patch"
out=$($WC patch "$FIX" --out "$SB/patched.yml" --port 18443 --remote https://panel.mytest.dev --origin https://panel.mytest.dev); rc=$?
assert_eq 0 "$rc" "patch succeeds"
P=$(cat "$SB/patched.yml")
assert_contains "$P" '  host: "127.0.0.1"' "api.host -> loopback"
assert_contains "$P" "  port: 18443" "api.port set"
assert_contains "$P" "  trusted_proxies:
    - 127.0.0.1" "trusted_proxies gets the tunnel's source address"
assert_contains "$P" "allowed_origins:
- https://panel.mytest.dev" "allowed_origins gets the panel origin"
assert_contains "$P" "token: AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKKLLLLMMMMNNNNOOOOPPPP" "token untouched"
assert_contains "$P" "uuid: 11111111-2222-3333-4444-555555555555" "uuid untouched"
assert_contains "$P" "      gateway: 172.18.0.1" "docker network block untouched"
assert_not_contains "$out" "AAAABBBB" "the token is never printed"
assert_mode "$SB/patched.yml" 600 "output file is 600"
diff_lines=$(diff "$FIX" "$SB/patched.yml" | grep -c '^[<>]')
assert_eq 12 "$diff_lines" "only the intended lines changed (5 removed, 7 added)"
assert_contains "$P" '    bind_address: "127.0.0.1"' "SFTP bind_address -> loopback (SFTP is not carried by Cloudflare)"
assert_contains "$P" "    bind_port: 2022" "SFTP port untouched"
$WC patch "$SB/patched.yml" --out "$SB/patched2.yml" --port 18443 --remote https://panel.mytest.dev --origin https://panel.mytest.dev >"$SB/o2.txt"
assert_contains "$(cat "$SB/o2.txt")" "no changes needed" "patching twice is a no-op (idempotent)"
cmp -s "$SB/patched.yml" "$SB/patched2.yml" && pass "second patch leaves the file identical" || fail "second patch leaves the file identical"

echo "wings_config.py: tuning (existing keys only)"
out=$($WC patch "$FIX" --out "$SB/tuned.yml" --port 18443 --remote https://panel.mytest.dev --origin https://panel.mytest.dev --tune)
T=$(cat "$SB/tuned.yml")
assert_contains "$T" "  disk_check_interval: 300" "disk check interval 150 -> 300"
assert_contains "$T" "  websocket_log_count: 100" "websocket log count -> 100"
assert_contains "$T" "    detect_clean_exit_as_crash: false" "a clean console stop is not a crash"
assert_contains "$T" "    write_limit: 50" "backup write limit 50 MiB/s"
assert_contains "$out" "system.disk_check_interval: 150 -> 300" "changes are reported"
assert_eq 4 "$(grep -cE 'system\.(disk_check|websocket|crash_detection|backups)' <<<"$out" | tr -d ' ')" "only the four keys that differed from the tuning were changed"
sed '/^  backups:/,/compression_level/d' "$FIX" >"$SB/nobackups.yml"
$WC patch "$SB/nobackups.yml" --out "$SB/nb.yml" --port 18443 --remote https://panel.mytest.dev --origin https://panel.mytest.dev --tune >/dev/null
assert_not_contains "$(cat "$SB/nb.yml")" "write_limit" "keys that are absent are never added"

echo "wings_config.py: other list shapes and refusals"
sed 's/^allowed_origins: \[\]/allowed_origins:\n- https:\/\/other.dev/' "$FIX" >"$SB/f1.yml"
$WC patch "$SB/f1.yml" --out "$SB/f1o.yml" --port 18443 --remote https://panel.mytest.dev --origin https://panel.mytest.dev >/dev/null
assert_contains "$(grep -A3 '^allowed_origins' "$SB/f1o.yml")" "- https://other.dev" "keeps an existing origin"
assert_contains "$(grep -A3 '^allowed_origins' "$SB/f1o.yml")" "- https://panel.mytest.dev" "and adds ours"
sed 's/^  trusted_proxies: \[\]/  trusted_proxies: [10.0.0.0\/8]/' "$FIX" >"$SB/f2.yml"
$WC patch "$SB/f2.yml" --out "$SB/f2o.yml" --port 18443 --remote https://panel.mytest.dev --origin https://panel.mytest.dev >/dev/null
assert_contains "$(cat "$SB/f2o.yml")" "    - 10.0.0.0/8" "inline trusted_proxies list is converted without losing entries"
assert_contains "$(cat "$SB/f2o.yml")" "    - 127.0.0.1" "and gets 127.0.0.1"
sed -i 's/^    enabled: false/    enabled: true/' "$SB/f2.yml"
out=$($WC patch "$SB/f2.yml" --out "$SB/f2x.yml" --port 18443 --remote https://panel.mytest.dev --origin https://panel.mytest.dev); rc=$?
assert_eq 2 "$rc" "api.ssl.enabled: true is refused"
assert_contains "$out" "Behind Proxy" "tells the operator to set the node Behind Proxy"
assert_no_file "$SB/f2x.yml" "and writes nothing"
printf 'debug: false\napi:\n  port: 1\n' >"$SB/f3.yml"
out=$($WC patch "$SB/f3.yml" --out "$SB/f3o.yml" --port 18443 --remote https://x.dev --origin https://x.dev); rc=$?
assert_eq 2 "$rc" "a file that is not a Wings config is refused"
sed 's/^token: .*/token: /' "$FIX" >"$SB/f4.yml"
out=$($WC patch "$SB/f4.yml" --out "$SB/f4o.yml" --port 18443 --remote https://x.dev --origin https://x.dev); rc=$?
assert_eq 2 "$rc" "an empty token is refused"
$WC check "$SB/missing.yml" >/dev/null 2>&1; assert_eq 2 "$?" "missing file: exit 2"

echo "wings_config.py: the Panel's JSON configuration (GET /api/application/nodes/{id}/configuration)"
cat >"$SB/panel.json" <<'JSON'
{"debug":false,"uuid":"11111111-2222-3333-4444-555555555555","token_id":"tid123","token":"SECRETTOKEN123","api":{"host":"0.0.0.0","port":18443,"ssl":{"enabled":false,"cert":"/etc/letsencrypt/live/x/fullchain.pem","key":"/etc/letsencrypt/live/x/privkey.pem"},"upload_limit":100},"system":{"data":"/var/lib/pterodactyl/volumes","sftp":{"bind_port":2023}},"allowed_mounts":[],"remote":"https://panel.mytest.dev"}
JSON
$WC patch "$SB/panel.json" --out "$SB/fromjson.yml" --port 18443 --remote https://panel.mytest.dev --origin https://panel.mytest.dev --game-subnet 172.30.0.0/16 >"$SB/fj.out"; rc=$?
assert_eq 0 "$rc" "a JSON document is accepted and written as block YAML"
J=$(cat "$SB/fromjson.yml")
assert_contains "$J" '  host: "127.0.0.1"' "api.host set to loopback in the converted file"
assert_contains "$J" "    bind_address: \"127.0.0.1\"" "a MISSING sftp bind_address is added (Wings would otherwise bind every interface)"
assert_contains "$J" "    bind_port: 2023" "sftp port kept"
assert_contains "$J" "  interface: \"127.0.0.1\"" "docker.network.interface = loopback (Docker Desktop refuses a bridge-gateway bind)"
assert_contains "$J" "    enable_icc: false" "inter-container communication off"
assert_contains "$J" "        subnet: \"172.30.0.0/16\"" "docker subnet = GAME_NET_SUBNET"
assert_contains "$J" "        gateway: \"172.30.0.1\"" "gateway = first host address of that subnet"
assert_contains "$J" "allowed_origins:" "allowed_origins created"
assert_contains "$J" "token: \"SECRETTOKEN123\"" "the node token is kept in the file (Wings needs it)"
assert_not_contains "$(cat "$SB/fj.out")" "SECRETTOKEN123" "and never in the command output"
python3 -B -c "
import sys; sys.path.insert(0,'$REPO/lib'); import wings_config as w
errs, _ = w.check(w.read_lines('$SB/fromjson.yml'), 'https://panel.mytest.dev', 18443)
sys.exit(1 if errs else 0)" && pass "the converted, patched file passes the structural check" || fail "the converted, patched file passes the structural check"
$WC patch "$SB/fromjson.yml" --out "$SB/fromjson2.yml" --port 18443 --remote https://panel.mytest.dev --origin https://panel.mytest.dev --game-subnet 172.30.0.0/16 >"$SB/fj2.out"
assert_contains "$(cat "$SB/fj2.out")" "no changes needed" "patching the converted file again changes nothing (idempotent)"
$WC patch "$FIX" --out "$SB/nosub.yml" --port 18443 --remote https://panel.mytest.dev --origin https://panel.mytest.dev >/dev/null
assert_contains "$(cat "$SB/nosub.yml")" "    interface: 172.18.0.1" "without --game-subnet the docker block is left as it was"

echo "wings_config.py: container mode (Wings inside a container)"
$WC patch "$FIX" --out "$SB/ctr.yml" --port 18443 --remote http://panel:80 --origin https://panel.mytest.dev --trusted-proxy 10.77.250.0/24 --container >"$SB/ctr.out"; rc=$?
assert_eq 0 "$rc" "patch --container succeeds"
C=$(cat "$SB/ctr.yml")
assert_contains "$C" '  host: "0.0.0.0"' "api.host -> 0.0.0.0 inside the container (the published port is what stays on loopback)"
assert_contains "$C" '    bind_address: "0.0.0.0"' "SFTP listens on every interface inside the container"
assert_contains "$C" "    - 10.77.250.0/24" "trusted_proxies gets the edge network (the tunnel arrives from its gateway)"
assert_not_contains "$C" "    - 127.0.0.1" "and not 127.0.0.1, which is not where the tunnel arrives from here"
assert_not_contains "$(cat "$SB/ctr.out")" "AAAABBBB" "the token is never printed"
out=$($WC check "$SB/ctr.yml" --remote http://panel:80 --port 18443 --container); rc=$?
assert_eq 0 "$rc" "the container check passes"
assert_eq "" "$out" "and has nothing to warn about"
out=$($WC check "$SB/ctr.yml" --remote http://panel:80 --port 18443)
assert_contains "$out" "api.host is '0.0.0.0'" "the host-mode check still warns about listening beyond loopback"
out=$($WC check "$SB/patched.yml" --remote https://panel.mytest.dev --port 18443 --container)
assert_contains "$out" "inside the container Wings must listen on 0.0.0.0" "a host-mode file fails the container check"
sed 's/^    bind_port: 2022/    bind_port: 2023/' "$SB/ctr.yml" >"$SB/ctr2.yml"
out=$($WC check "$SB/ctr2.yml" --container)
assert_contains "$out" "publishes only port 2022" "an SFTP port other than 2022 is called out"
$WC patch "$SB/ctr.yml" --out "$SB/ctr3.yml" --port 18443 --remote http://panel:80 --origin https://panel.mytest.dev --trusted-proxy 10.77.250.0/24 --container >"$SB/ctr3.out"
assert_contains "$(cat "$SB/ctr3.out")" "no changes needed" "patching a container file again changes nothing (idempotent)"

echo "wings install on a fake host"
valid_config
# the repo pins the real release hash; the tests use their own fixture binary, so give the sandbox a matching pin
printf '#!/bin/sh\necho "wings v1.13.4 (fake)"\n' >"$SB/fake-wings"
sha=$(sha256sum "$SB/fake-wings" | cut -d' ' -f1)
export FAKE_WINGS_BIN=$SB/fake-wings
p wings install --yes
assert_eq 1 "$RC" "a download whose sha256 differs from the pin is refused"
assert_contains "$OUT" "sha256 mismatch" "says so"
assert_no_file "$PTERO_WINGS_BIN" "and installs nothing"
sed -i "s/^WINGS_SHA256_AMD64=.*/WINGS_SHA256_AMD64=$sha/; s/^WINGS_SHA256_ARM64=.*/WINGS_SHA256_ARM64=$sha/" "$R/config/versions.env"
p wings install --yes
assert_eq 0 "$RC" "install without a config succeeds (binary + unit only)"
assert_file "$PTERO_WINGS_BIN" "binary installed"
assert_mode "$PTERO_WINGS_BIN" 755 "binary mode 755"
assert_file "$PTERO_SYSTEMD_DIR/wings.service" "unit installed"
assert_contains "$(cat "$PTERO_SYSTEMD_DIR/wings.service")" "ExecStart=$PTERO_WINGS_BIN" "unit points at the installed binary"
assert_contains "$(cat "$PTERO_SYSTEMD_DIR/wings.service")" "WorkingDirectory=$PTERO_WINGS_ETC" "unit uses the config dir"
assert_mode "$PTERO_WINGS_ETC" 700 "config dir is 700"
assert_not_contains "$(calls)" "enable --now wings" "Wings is NOT started without a config"
assert_contains "$OUT" "Create the node in the Panel" "tells the operator what to do next"

echo "wings configure"
cp "$FIX" "$SB/node-config.yml"
p wings configure "$SB/node-config.yml"
assert_eq 0 "$RC" "configure succeeds"
assert_mode "$PTERO_WINGS_ETC/config.yml" 600 "installed config is 600"
assert_contains "$(cat "$PTERO_WINGS_ETC/config.yml")" "port: 18443" "patched to the configured API port"
assert_contains "$(cat "$PTERO_WINGS_ETC/config.yml")" "disk_check_interval: 300" "WINGS_TUNING=yes (default) applies the tuning"
assert_contains "$(cat "$PTERO_WINGS_ETC/config.yml")" 'remote: https://panel.mytest.dev' "remote = public panel URL (default mode)"
assert_contains "$OUT" "Delete it when done" "warns that the pasted file still holds the token"
assert_not_contains "$OUT" "AAAABBBB" "no token in the output"
sed -i 's/^WINGS_REMOTE_MODE=.*/WINGS_REMOTE_MODE=internal/' "$R/config/deploy.env"
p wings configure "$SB/node-config.yml"
assert_contains "$(cat "$PTERO_WINGS_ETC/config.yml")" 'remote: "http://127.0.0.1:18081"' "internal mode uses the loopback Panel URL"
ls "$PTERO_WINGS_ETC" | grep -q 'config.yml.bak-' && pass "previous config kept as a backup file" || fail "previous config kept as a backup file"
assert_mode "$(ls "$PTERO_WINGS_ETC"/config.yml.bak-* | head -n1)" 600 "and the backup copy is 600"
p wings configure "$SB/missing.yml"
assert_eq 1 "$RC" "configure with a missing file fails"

echo "wings install with --config starts the service"
rm -rf "$PTERO_WINGS_ETC"; rm -f "$FAKE_STATE/systemd/wings.active"
: >"$FAKE_STATE/calls.log"
printf '%s\n' 'http://127.0.0.1:18443/* 401' >"$FAKE_STATE/http_map"
p wings install --yes --config "$SB/node-config.yml"
assert_eq 0 "$RC" "install --config succeeds"
assert_contains "$(calls)" "enable --now wings" "service enabled and started"
p wings status
assert_eq 0 "$RC" "wings status: active and answering"
assert_contains "$OUT" "HTTP 401" "reports the API answer"

echo "wings update"
printf '#!/bin/sh\necho "wings v1.13.4 (rebuilt)"\n' >"$SB/fake-wings"
sha2=$(sha256sum "$SB/fake-wings" | cut -d' ' -f1)
p wings update --yes
assert_eq 1 "$RC" "update refuses a binary that does not match the pin"
sed -i "s/^WINGS_SHA256_AMD64=.*/WINGS_SHA256_AMD64=$sha2/; s/^WINGS_SHA256_ARM64=.*/WINGS_SHA256_ARM64=$sha2/" "$R/config/versions.env"
p wings update --yes
assert_eq 0 "$RC" "update with a matching pin succeeds"
assert_file "$PTERO_WINGS_BIN.prev" "previous binary kept for rollback"
assert_contains "$(cat "$PTERO_WINGS_BIN")" "rebuilt" "new binary in place"
p wings update
assert_eq 4 "$RC" "update without --yes and without a terminal is refused"

echo "WINGS_MODE=container: Wings as a Compose service (fresh fake host)"
sandbox_cleanup; sandbox
valid_config
sed -i 's/^WINGS_MODE=.*/WINGS_MODE=container/' "$R/config/deploy.env"
VOL=$FAKE_STATE/volumes/pterodactyl_wings_etc
cp "$FIX" "$SB/node-config.yml"
p setup
assert_eq 0 "$RC" "setup works in container mode"
assert_contains "$OUT" "Wings (container): no configuration yet" "setup does not start Wings before it has a configuration"
assert_eq 0 "$(count_calls 'egress-guard')" "and never names the Wings services"
p wings install --yes
assert_eq 0 "$RC" "install without a config succeeds"
assert_contains "$OUT" "Wings is NOT started" "and says nothing was started"
assert_no_file "$VOL/config.yml" "no config is invented"
: >"$FAKE_STATE/calls.log"
p wings install --yes --config "$SB/node-config.yml"
assert_eq 0 "$RC" "install --config succeeds"
assert_contains "$(calls)" "volume create --label com.docker.compose.project=pterodactyl --label com.docker.compose.volume=wings_etc pterodactyl_wings_etc" "the volume is created with the labels Compose looks for (no 'not created by Docker Compose' warning)"
assert_file "$VOL/config.yml" "the config is in the named volume"
assert_mode "$VOL/config.yml" 600 "and is mode 600"
[[ -z $(find "$R" -name 'config.yml*' 2>/dev/null) ]] && pass "no copy of the config (it holds the node token) in the repo tree" || fail "no copy of the config in the repo tree"
CC=$(cat "$VOL/config.yml")
assert_contains "$CC" '  host: "0.0.0.0"' "api.host listens inside the container"
assert_contains "$CC" "    - 10.77.250.0/24" "trusted_proxies = the edge network"
assert_contains "$CC" "  port: 18443" "api.port = WINGS_API_PORT"
assert_contains "$CC" 'remote: https://panel.mytest.dev' "remote = the public Panel URL in public mode"
assert_contains "$(calls)" "--profile wings" "the wings profile is enabled for these commands only"
assert_contains "$(calls)" "pull wings egress-guard" "the pinned images are pulled"
assert_contains "$(calls)" "up -d --wait --wait-timeout 240 wings egress-guard" "Wings and its egress guard start together, and are waited for"
assert_not_contains "$(calls)" "restart wings" "a first install does not restart anything"
assert_eq "" "$(calls | grep -E 'systemctl (enable|start|restart|stop|disable|daemon-reload)' || true)" "nothing starts, stops or installs anything in systemd (asking whether the native service is active is fine)"
assert_not_contains "$OUT" "AAAABBBB" "no token in the output"
assert_contains "$OUT" "Delete it when done" "warns that the pasted file still holds the token"
p wings status
assert_eq 0 "$RC" "wings status: running and answering"
assert_contains "$OUT" "mode     : container" "reports the mode"
assert_contains "$OUT" "service  : healthy" "and the container state"
assert_contains "$OUT" "guard    : healthy" "and the egress guard state"
assert_contains "$OUT" "HTTP 401" "and the API answer"
p status
assert_eq 0 "$RC" "status: everything healthy"
assert_contains "$OUT" "wings-container" "status lists the Wings container"
assert_contains "$OUT" "egress-guard" "and the egress guard"
p update --check
assert_eq 0 "$RC" "update --check works with Wings running as a container"
assert_contains "$OUT" "nothing to update" "and ignores Wings: like the host binary it is updated by ./ptero wings update, never by update"

echo "container mode: configure, update, logs, up"
sed -i 's/^WINGS_REMOTE_MODE=.*/WINGS_REMOTE_MODE=internal/' "$R/config/deploy.env"
: >"$FAKE_STATE/calls.log"
p wings configure "$SB/node-config.yml"
assert_eq 0 "$RC" "configure succeeds"
assert_contains "$(cat "$VOL/config.yml")" 'remote: "http://panel:80"' "internal mode: the Panel service on the Compose network"
ls "$VOL" | grep -q '^config.yml.bak-' && pass "the previous config is kept in the volume" || fail "the previous config is kept in the volume"
assert_mode "$(ls "$VOL"/config.yml.bak-* | head -n1)" 600 "and the backup copy is 600"
assert_contains "$(calls)" "restart wings" "a Wings container that exists is restarted"
assert_eq 0 "$(count_calls 'volume create')" "an existing volume is not created again"
n1=$(ls "$VOL" | grep -c '^config.yml.bak-')
p wings configure "$SB/node-config.yml"
assert_eq "$n1" "$(ls "$VOL" | grep -c '^config.yml.bak-')" "configuring with the same file again makes no new backup"
: >"$FAKE_STATE/calls.log"
p wings update --yes
assert_eq 0 "$RC" "update succeeds"
assert_contains "$(calls)" "pull wings egress-guard" "update pulls the pinned images"
p wings update
assert_eq 4 "$RC" "update without --yes and without a terminal is refused"
p wings logs 5
assert_eq 0 "$RC" "logs succeed"
assert_contains "$OUT" "fake log line" "and come from the container"
rm -f "$FAKE_STATE/running/wings" "$FAKE_STATE/running/egress-guard"
: >"$FAKE_STATE/calls.log"
p up
assert_eq 0 "$RC" "up succeeds"
assert_contains "$(calls)" "up -d --wait --wait-timeout 240 wings egress-guard" "up brings Wings back when a config exists"
seed_installed   # the extension volumes a backup archives (setup on a real host creates them)
p backup --label ctr
assert_eq 0 "$RC" "backup succeeds"
tar -tzf "$(ls -d "$R"/backups/*-ctr | head -n1)/config.tgz" | grep -qx 'wings/config.yml' && pass "the backup holds the Wings config from the volume" || fail "the backup holds the Wings config from the volume"
p diagnose
assert_contains "$OUT" "mode: container" "diagnose reports the container mode"
assert_not_contains "$OUT" "AAAABBBB" "and never the node token"

echo "container mode: refusals"
touch "$FAKE_STATE/systemd/wings.active"
p wings install --yes
assert_eq 4 "$RC" "install refuses while the native Wings service is active"
assert_contains "$OUT" "systemctl disable --now wings" "and says how to stop it"
p preflight
assert_eq 3 "$RC" "preflight fails: a second Wings would share the node"
assert_contains "$OUT" "native Wings service (systemd) is active" "and says why"
rm -f "$FAKE_STATE/running/wings" "$FAKE_STATE/running/egress-guard"
: >"$FAKE_STATE/calls.log"
p up
assert_eq 0 "$RC" "up still brings the Panel up"
assert_contains "$OUT" "the Wings container was NOT started" "but warns that Wings was not started"
assert_eq 0 "$(count_calls 'egress-guard')" "and does not start it"
rm -f "$FAKE_STATE/systemd/wings.active"
p firewall egress status
assert_eq 4 "$RC" "host egress commands are refused: they would edit the wrong iptables"
assert_contains "$OUT" "egress-guard service" "and point at the service that does the job"

echo "root is required outside test mode"
OUT=$(cd "$R" && PTERO_TEST_MODE=0 ./ptero wings install 2>&1 </dev/null); RC=$?
if [[ $(id -u) -ne 0 ]]; then assert_eq 4 "$RC" "non-root wings install refused"; else pass "running as root: skip non-root refusal check"; fi

finish

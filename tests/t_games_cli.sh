#!/usr/bin/env bash
# ./ptero games / game / key / egg: the shell side (refusals, environment hand-over, router reload, DNS help, timers)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox; trap 'kill "${MOCK_PID:-0}" "${LISTEN_PID:-0}" 2>/dev/null; sandbox_cleanup' EXIT
valid_config

echo "disabled by default"
p games sync
assert_eq 4 "$RC" "games sync refused while GAMES_ENABLED=no"
assert_contains "$OUT" "GAMES_ENABLED=yes" "tells how to enable"
p games status
assert_contains "$OUT" "disabled" "status says disabled"

echo "configuration rules for games"
games_config
p status
assert_not_contains "$OUT" "GAMES_" "valid games config accepted"
bad() { cp "$R/config/deploy.env" "$SB/env.bak"; sed -i "$1" "$R/config/deploy.env"; p status; assert_eq 3 "$RC" "$3: exit 3"; assert_contains "$OUT" "$2" "$3: message"; cp "$SB/env.bak" "$R/config/deploy.env"; }
bad 's/^GAMES_DOMAIN=.*/GAMES_DOMAIN=/' "GAMES_DOMAIN" "games enabled without a domain"
bad 's/^GAMES_DOMAIN=.*/GAMES_DOMAIN=mytest.dev/' "does not contain PANEL_FQDN" "games domain that contains the panel name"
bad 's/^GAMES_DOMAIN=.*/GAMES_DOMAIN=panel.mytest.dev/' "does not contain PANEL_FQDN" "games domain equal to the panel name"
bad 's/^GAMES_PORT=.*/GAMES_PORT=25650/' "outside the backend range" "router port inside the backend range"
bad 's/^GAMES_PORT=.*/GAMES_PORT=18081/' "collides" "router port equal to the panel port"
bad 's/^GAMES_BACKEND_FIRST=.*/GAMES_BACKEND_FIRST=80/' "GAMES_BACKEND" "privileged backend ports"
bad 's/^GAMES_BACKEND_LAST=.*/GAMES_BACKEND_LAST=27000/' "at most 1000 apart" "huge backend range"
bad 's/^GAMES_CONN_RATE=.*/GAMES_CONN_RATE=0/' "GAMES_CONN_RATE" "zero connection rate"

echo "keys"
p games sync
assert_eq 4 "$RC" "no Panel key: refused"
assert_contains "$OUT" "./ptero key set panel" "tells how to set it"
OUT=$(cd "$R" && echo "not-a-key" | ./ptero key set panel 2>&1); RC=$?
assert_eq 2 "$RC" "a value that is not a ptla_ key is rejected"
assert_no_file "$R/secrets/panel_api_key" "and nothing is stored"
CLIENT_KEY="ptl$(printf 'c')_aaaaaaaaaaaaaaaaaaaaaaaa"   # built at runtime so the repo secret scan stays meaningful
OUT=$(cd "$R" && echo "$CLIENT_KEY" | ./ptero key set panel 2>&1); RC=$?
assert_eq 2 "$RC" "a client key (ptlc_) is rejected: wrong key type"
KEY="ptla_$(printf 'k%.0s' {1..24})"
OUT=$(cd "$R" && echo "$KEY" | ./ptero key set panel 2>&1); RC=$?
assert_eq 0 "$RC" "a Panel application key is accepted"
assert_mode "$R/secrets/panel_api_key" 600 "stored mode 600"
assert_not_contains "$OUT" "$KEY" "never echoed"
OUT=$(cd "$R" && echo 'abc' | ./ptero key set curseforge 2>&1); RC=$?
assert_eq 2 "$RC" "a too-short CurseForge key is rejected"
CF='$2a$10$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV'
OUT=$(cd "$R" && printf '%s\n' "$CF" | ./ptero key set curseforge 2>&1); RC=$?
assert_eq 0 "$RC" "a CurseForge key (with \$ . / characters) is accepted"
assert_eq "$CF" "$(tr -d '\n' <"$R/secrets/curseforge_api_key")" "stored exactly"
assert_mode "$R/secrets/curseforge_api_key" 600 "mode 600"

echo "against a mock Panel"
PORTS=$SB/ports.json
export MOCK_PANEL_KEY=$KEY
python3 -B "$REPO/tests/mock_servers.py" "$PORTS" >/dev/null 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do [[ -s $PORTS ]] && break; sleep 0.2; done
panel_port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["panel"])' "$PORTS")
mod_port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["modrinth"])' "$PORTS")
export MODRINTH_API_BASE="http://127.0.0.1:$mod_port"
sed -i "s/^PANEL_BIND_PORT=.*/PANEL_BIND_PORT=$panel_port/" "$R/config/deploy.env"
touch "$FAKE_STATE/running/panel"; mkdir -p "$FAKE_STATE/health"; echo healthy >"$FAKE_STATE/health/panel"

p games sync
assert_eq 0 "$RC" "games sync works against the Panel API (loopback, key from secrets/, not argv)"
assert_contains "$OUT" "my-survival.mc.mytest.dev -> 127.0.0.1:25601" "route derived from the Panel's server list"
assert_file "$R/runtime/mc-router/routes.json" "routes file written"
assert_mode "$R/runtime/mc-router" 755 "routes dir readable by the router container"
assert_contains "$(cat "$R/runtime/mc-router/routes.json")" '"mappings"' "router file format"
assert_not_contains "$OUT" "$KEY" "key never printed"
assert_not_contains "$(calls)" "$KEY" "key never passed to another command"
assert_not_contains "$(calls)" "kill -s HUP" "router not running: nothing to reload"
touch "$FAKE_STATE/running/mc-router"
echo healthy >"$FAKE_STATE/health/mc-router"
rm "$R/runtime/mc-router/routes.json"
p games sync
assert_contains "$(calls)" "kill -s HUP mc-router" "a changed table makes the running router reload"
: >"$FAKE_STATE/calls.log"
p games sync --quiet
assert_eq "" "$OUT" "an unchanged table with --quiet prints nothing"
assert_not_contains "$(calls)" "kill -s HUP" "and does not reload"
p games list
assert_contains "$OUT" "my-survival.mc.mytest.dev" "list shows the hostname"
assert_contains "$OUT" "Exposed: allocation is 0.0.0.0:25603" "and servers that cannot be routed, with the reason"

echo "game create"
p game create --name Fresh --source modrinth --pack no-such-pack
assert_eq 3 "$RC" "unknown pack: refused before anything is created"
assert_contains "$OUT" "cannot read the pack" "says why"
p game create --name "My Survival!" --source modrinth --pack cool-pack
assert_eq 3 "$RC" "duplicate server name refused"
p game create --name Fresh
assert_eq 2 "$RC" "missing arguments: usage error from the parser"

echo "status and DNS help"
LISTEN_PORT=$((30000 + RANDOM % 20000))   # outside the game backend range 25600-25699
sed -i "s/^GAMES_PORT=.*/GAMES_PORT=$LISTEN_PORT/" "$R/config/deploy.env"
p games status
assert_eq 1 "$RC" "status fails while nothing listens on the game port"
python3 -c "import socket,time; s=socket.socket(); s.setsockopt(1,2,1); s.bind(('127.0.0.1',$LISTEN_PORT)); s.listen(1); time.sleep(30)" &
LISTEN_PID=$!
sleep 0.5
p games status
assert_eq 0 "$RC" "status ok when the router runs and listens"
p games dns
assert_contains "$OUT" "*.mc.mytest.dev" "DNS help shows the wildcard record"
assert_contains "$OUT" "DNS only" "and that it must not be proxied"

echo "timer"
p games timer install
assert_eq 0 "$RC" "timer install"
assert_contains "$(cat "$PTERO_SYSTEMD_DIR/ptero-games-sync.service")" "ExecStart=$R/ptero games sync --quiet" "service runs a quiet sync"
assert_contains "$(cat "$PTERO_SYSTEMD_DIR/ptero-games-sync.timer")" "OnUnitActiveSec=2min" "every 2 minutes"
assert_contains "$(calls)" "enable --now ptero-games-sync.timer" "enabled"
p games timer remove
assert_no_file "$PTERO_SYSTEMD_DIR/ptero-games-sync.timer" "timer removed"
assert_file "$R/runtime/mc-router/routes.json" "routes already written stay in place"

echo "egg"
p egg build
assert_eq 0 "$RC" "egg build works from the sandbox copy"
echo unhealthy >"$FAKE_STATE/health/panel"
p egg install
assert_eq 4 "$RC" "egg install refused while the Panel is not healthy"
echo healthy >"$FAKE_STATE/health/panel"
: >"$FAKE_STATE/calls.log"
p egg install
assert_eq 0 "$RC" "egg install succeeds"
assert_contains "$OUT" "egg imported" "reports the result"
assert_contains "$(calls)" "cat >/tmp/ptero-egg.json" "the egg is streamed into the Panel container (owned by the PHP user, removable afterwards)"
assert_contains "$(calls)" "rm -f /tmp/ptero-egg.json /tmp/ptero-egg-import.php" "and removed afterwards"
assert_contains "$(calls)" "tinker --execute=require '/tmp/ptero-egg-import.php'" "imported through the Panel's own action"
assert_not_contains "$(calls)" "$CF" "the CurseForge key is not on any command line"

finish

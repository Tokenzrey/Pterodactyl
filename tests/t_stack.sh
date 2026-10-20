#!/usr/bin/env bash
# setup (fresh / existing / unsafe states), idempotency, status, verify, update, admin, down
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox; trap sandbox_cleanup EXIT

echo "setup on a fresh machine"
valid_config
p setup
assert_eq 0 "$RC" "fresh setup succeeds"
assert_eq 1 "$(count_calls 'migrate --seed --force')" "migrate --seed runs exactly once"
assert_contains "$(calls)" "--profile tunnel" "tunnel profile enabled because a token exists"
assert_contains "$(calls)" "pull" "images are pulled before anything starts"
assert_contains "$OUT" "./ptero admin create" "prints the manual next steps"
key1=$(cat "$FAKE_STATE/volumes/pterodactyl_panel_var/.env")

echo "setup again (idempotent)"
p setup
assert_eq 0 "$RC" "second setup succeeds"
assert_eq 1 "$(count_calls 'migrate --seed --force')" "still exactly one migrate --seed in total"
assert_eq "$key1" "$(cat "$FAKE_STATE/volumes/pterodactyl_panel_var/.env")" "APP_KEY unchanged"
assert_contains "$OUT" "existing installation detected" "says it found the existing install"

echo "setup refuses unsafe states"
rm -f "$FAKE_STATE/volumes/pterodactyl_panel_var/.env"
: >"$FAKE_STATE/calls.log"
p setup
assert_eq 4 "$RC" "DB has tables but APP_KEY is gone: refused (exit 4)"
assert_contains "$OUT" "NEW key" "explains the danger"
assert_not_contains "$(calls)" "up -d --wait --wait-timeout 300" "the Panel is never started in that state"
assert_not_contains "$(calls)" "migrate --seed" "and nothing is migrated"
printf 'APP_KEY=base64:ORIGINALKEY\n' >"$FAKE_STATE/volumes/pterodactyl_panel_var/.env"
echo 2 >"$FAKE_STATE/pending"
p setup
assert_eq 4 "$RC" "pending migrations: refused (exit 4)"
assert_contains "$OUT" "./ptero update" "points at update"
echo 0 >"$FAKE_STATE/pending"

echo "setup stops on failures"
rm -rf "$FAKE_STATE"; mkdir -p "$FAKE_STATE"; : >"$FAKE_STATE/http_map"
FAKE_MIGRATE_RC=1 p setup
assert_eq 1 "$RC" "a failing migration stops setup"
assert_contains "$OUT" "migration failed" "and says so"
unset FAKE_MIGRATE_RC
FAKE_PULL_RC=1 p setup
assert_eq 1 "$RC" "a failing pull stops setup"
unset FAKE_PULL_RC
FAKE_DOCKER_DOWN=1 p setup
assert_eq 3 "$RC" "docker daemon down: preflight failure exit 3"
assert_contains "$OUT" "cannot talk to the Docker daemon" "with an actionable message"
unset FAKE_DOCKER_DOWN
FAKE_NETWORKS="10.77.0.0/16" p preflight
assert_eq 3 "$RC" "subnet overlapping an existing Docker network fails preflight"
assert_contains "$OUT" "overlaps existing network/route 10.77.0.0/16" "naming the conflicting network"

echo "preflight: a Wings game network left by an older stack must not be reused silently"
FAKE_WINGS_NET_SUBNET=172.22.0.0/16 p preflight
assert_eq 3 "$RC" "existing pterodactyl_nw with another subnet fails preflight"
assert_contains "$OUT" "already exists with subnet 172.22.0.0/16" "and names the subnet"
FAKE_WINGS_NET_SUBNET=172.18.0.0/16 p preflight
assert_eq 0 "$RC" "a matching pterodactyl_nw is accepted"
unset FAKE_WINGS_NET_SUBNET

echo "preflight: the game network must not overlap another Docker network (Wings stops with 'Pool overlaps')"
FAKE_OTHER_SUBNET=172.18.0.0/16 p preflight
assert_eq 3 "$RC" "a GAME_NET_SUBNET that overlaps another network fails preflight"
assert_contains "$OUT" "GAME_NET_SUBNET 172.18.0.0/16 overlaps existing network/route 172.18.0.0/16" "and names the network"
sed -i 's#^GAME_NET_SUBNET=.*#GAME_NET_SUBNET=10.201.0.0/16#' "$R/config/deploy.env"
FAKE_OTHER_SUBNET=172.22.0.0/16 p preflight
assert_eq 0 "$RC" "a free private range passes"
sed -i 's#^GAME_NET_SUBNET=.*#GAME_NET_SUBNET=172.18.0.0/16#' "$R/config/deploy.env"
unset FAKE_OTHER_SUBNET

echo "preflight port check"
python3 -m http.server 18081 --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
sleep 1
p preflight
kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
assert_eq 3 "$RC" "a port already in use by something else fails preflight"
assert_contains "$OUT" "PANEL_BIND_PORT 18081 is already in use" "naming the variable"

echo "status"
valid_config
seed_installed
p setup
p status
assert_eq 0 "$RC" "healthy stack: status exits 0"
assert_contains "$OUT" "database       healthy" "lists services"
echo unhealthy >"$FAKE_STATE/health/panel"
p status
assert_eq 1 "$RC" "an unhealthy service makes status exit 1"
echo healthy >"$FAKE_STATE/health/panel"
printf 'http://127.0.0.1:18081/auth/login* 502\n' >"$FAKE_STATE/http_map"
p status
assert_eq 1 "$RC" "Panel not answering makes status exit 1"
assert_contains "$OUT" "NOT ANSWERING" "and says so"

echo "verify (public path)"
printf '%s\n' 'https://panel.mytest.dev/* 200' 'https://wings.mytest.dev/* 401' >"$FAKE_STATE/http_map"
p verify
assert_contains "$OUT" "Panel login page over HTTPS: 200" "panel ok"
printf '%s\n' 'https://panel.mytest.dev/* 530' 'https://wings.mytest.dev/* 401' >"$FAKE_STATE/http_map"
p verify
assert_eq 1 "$RC" "Cloudflare 530 makes verify fail"
assert_contains "$OUT" "tunnel is down" "with the likely cause"

echo "admin create needs a terminal"
p admin create
assert_eq 4 "$RC" "refuses without a terminal (no password on argv, no piping)"
assert_not_contains "$(calls)" "p:user:make" "p:user:make is not invoked"

echo "down keeps data"
: >"$FAKE_STATE/calls.log"
p down
assert_eq 0 "$RC" "down succeeds"
assert_contains "$(calls)" "--profile * down" "stops every profile"
assert_not_contains "$(calls)" " -v" "never passes -v (volumes are kept)"
assert_not_contains "$(calls)" "volume rm" "never removes volumes"

echo "update"
valid_config
seed_installed
p setup
: >"$FAKE_STATE/calls.log"
p update --check
assert_contains "$OUT" "nothing to update" "no drift: nothing to do"
echo "ghcr.io/pterodactyl/panel@sha256:0000000000000000000000000000000000000000000000000000000000000000" >"$FAKE_STATE/image/panel"
p update --check
assert_contains "$OUT" "Pending change" "drift is reported"
assert_not_contains "$(calls)" "pull" "--check changes nothing"
p update
assert_eq 4 "$RC" "update without a terminal and without --yes is refused"
: >"$FAKE_STATE/calls.log"
FAKE_DUMP_FAIL=1 p update --yes
assert_eq 1 "$RC" "a failed backup aborts the update"
assert_contains "$OUT" "NOT updating" "and says so"
assert_not_contains "$(calls)" "pull" "nothing was pulled"
assert_not_contains "$(calls)" "stop panel" "the Panel was not stopped"
unset FAKE_DUMP_FAIL
sleep 1   # backup names have 1-second resolution and never overwrite
: >"$FAKE_STATE/calls.log"
p update --yes
assert_eq 0 "$RC" "update with a good backup succeeds"
order=$(calls | grep -n -E 'exec -T database|pull|stop panel|migrate --seed' | cut -d: -f1 | tr '\n' ' ')
assert_contains "$(calls)" "migrate --seed --force" "migrations run"
dump_line=$(calls | grep -n 'exec -T database' | head -n1 | cut -d: -f1)
pull_line=$(calls | grep -n ' pull' | head -n1 | cut -d: -f1)
stop_line=$(calls | grep -n 'stop panel' | head -n1 | cut -d: -f1)
mig_line=$(calls | grep -n 'migrate --seed' | head -n1 | cut -d: -f1)
if [[ $dump_line -lt $pull_line && $pull_line -lt $stop_line && $stop_line -lt $mig_line ]]; then pass "order: backup, pull, stop, migrate"; else fail "order: backup, pull, stop, migrate" "$order"; fi
assert_contains "$OUT" "Rollback point:" "prints the rollback point"
ls "$R/backups" | grep -q 'pre-update' && pass "a pre-update backup exists" || fail "a pre-update backup exists"

finish

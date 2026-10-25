#!/usr/bin/env bash
# lib/voice.sh: VOICE_PORT in server.env and compose.yaml (the published UDP port), cmd_voice (set, off, the refusals, the rollback),
# and voice_ports (what the guard opens). The guard's own rules are in t_router.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/modpack.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/rcon.sh"
source "$REPO/lib/router.sh"
source "$REPO/lib/cloudflare.sh"
source "$REPO/lib/sftp.sh"
source "$REPO/lib/settings.sh"
source "$REPO/lib/voice.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
canned() { printf '%s\n' "$2" >"$FAKE_STATE/docker.inspect.${1//[^A-Za-z0-9_-]/_}"; }
FMT_STATE='{{.State.Status}}'
FMT_LABEL='{{index .Config.Labels "mcctl.config_hash"}}'
run_as() { canned "$FMT_STATE" "$1"; canned "$FMT_LABEL" "$2"; }
# mk NAME [STATE]: a server folder with a compose.yaml of its current configuration, and Docker's answers for it. Clears the call log.
mk() {
    local n=$1 st=${2:-stopped}
    mkdir -p "$SB/servers/$n/data" "$SB/servers/$n/backups" "$SB/secrets"
    printf '# Written by mcctl create. mcctl reads this file; it never runs it.\nTYPE=PAPER\nVERSION=LATEST\nMEMORY=4G\nCPUS=2\nHOSTNAME_SLUG=%s\nEULA=TRUE\n' "$n" >"$SB/servers/$n/server.env"
    chmod 600 "$SB/servers/$n/server.env"
    write_compose "$n" && chmod 600 "$SB/servers/$n/compose.yaml"
    printf 'test-rcon-pass-%s\n' "$n" >"$SB/secrets/rcon-$n"; chmod 600 "$SB/secrets/rcon-$n"
    fake_server "$n" "$n" "$st"
    run_as "$st" "$(config_hash "$n")"
    reset
}
# the router stack is up: its egress guard answers as running (fakebin/docker replays docker.compose.ps.running.egress-guard)
guard_up()   { echo cid-guard >"$FAKE_STATE/docker.compose.ps.running.egress-guard"; }
guard_down() { rm -f "$FAKE_STATE/docker.compose.ps.running.egress-guard"; }
# the mod's config is there (the data helper's test -f answers 0), or not (1)
config_there() { echo 0 >"$FAKE_STATE/docker.run.test.rc"; }
config_gone()  { echo 1 >"$FAKE_STATE/docker.run.test.rc"; }
rm -f "$FAKE_STATE/docker.run.test.rc"

echo "voice_port_valid: a whole number from 1024 to 65535, not the game's router port"
for p in 1024 24454 65535; do voice_port_valid "$p"; assert_eq 0 $? "$p is a voice port"; done
for p in 1023x 65536 25565 0 "" 24454.5 -1; do voice_port_valid "$p"; assert_eq 1 $? "${p:-empty} is not a voice port"; done

echo "render: VOICE_PORT is published as UDP, and only when it is set"
mk v1
server_env_set v1 VOICE_PORT 24454
write_compose v1; assert_eq 0 $? "a server with VOICE_PORT renders"
ct=$(<"$SB/servers/v1/compose.yaml")
assert_contains "$ct" $'    ports:\n      - "24454:24454/udp"' "compose.yaml publishes 24454 as UDP, nothing else"
assert_eq 1 "$(grep -c '^    ports:' <<<"$ct")" "exactly one ports: block"
assert_not_contains "$(grep -v '^    ports:\|24454' <<<"$ct")" "/udp" "no other UDP port is published"
server_env_unset v1 VOICE_PORT
write_compose v1
assert_not_contains "$(<"$SB/servers/v1/compose.yaml")" "ports:" "without VOICE_PORT the compose has no ports: block (the game publishes nothing)"
for bad in 25565 80 abc 70000; do
    server_env_set v1 VOICE_PORT "$bad"
    render_server_compose v1 "" >/dev/null 2>&1; rc=$?
    assert_eq 3 "$rc" "VOICE_PORT=$bad is refused at render (EX_PREFLIGHT)"
done
server_env_unset v1 VOICE_PORT

echo "voice_ports: what the guard opens, sorted, each once"
mk v2; mk v3
server_env_set v2 VOICE_PORT 24455
server_env_set v3 VOICE_PORT 24454
assert_eq "24454
24455" "$(voice_ports)" "two servers, two ports, sorted"
server_env_unset v3 VOICE_PORT
assert_eq "24455" "$(voice_ports)" "a server without VOICE_PORT adds nothing"
server_env_unset v2 VOICE_PORT

echo "cmd_voice: the status, and the refusals that change nothing"
mk v1; reset
m voice v1; assert_eq 0 "$RC" "mcctl voice NAME (no action) exits 0"
assert_contains "$OUT" "no voice chat port" "and says there is none"
m voice v1 set 25565; assert_eq 2 "$RC" "the router port is refused: EX_USAGE"
assert_contains "$OUT" "is not a UDP port from 1024 to 65535 other than 25565" "and says why"
guard_down; config_there; reset
m voice v1 set 24454; assert_eq 4 "$RC" "no router stack running: EX_REFUSED"
assert_contains "$OUT" "the router stack is not running" "and says to run mcctl up"
assert_not_contains "$(<"$SB/servers/v1/server.env")" "VOICE_PORT" "server.env is unchanged"
assert_eq 0 "$(count_calls 'docker compose -p mcctl-v1')" "the server's compose project is not touched"
guard_up; config_gone; reset
m voice v1 set 24454; assert_eq 4 "$RC" "no voice config yet: EX_REFUSED"
assert_contains "$OUT" "has no voice chat config yet" "and says to start the server once"
assert_not_contains "$(<"$SB/servers/v1/server.env")" "VOICE_PORT" "server.env is unchanged after that refusal too"
config_there

echo "cmd_voice set: the port is written to server.env, compose.yaml and the mod's config; the guard is set; the server is made again"
mk v1; guard_up; config_there; reset
m voice v1 set 24454; assert_eq 0 "$RC" "mcctl voice v1 set 24454 exits 0"
assert_contains "$(<"$SB/servers/v1/server.env")" "VOICE_PORT=24454" "server.env has VOICE_PORT=24454"
assert_contains "$(<"$SB/servers/v1/compose.yaml")" $'      - "24454:24454/udp"' "compose.yaml publishes it"
assert_contains "$(calls)" "docker compose -p mcctl-stack -f $SB/templates/stack.compose.yml up -d --wait --no-deps egress-guard" "the guard alone is set (--no-deps: the router is not touched)"
assert_contains "$(calls)" "config/voicechat/voicechat-server.properties" "the mod's config is written in the data helper"
assert_contains "$(calls)" "docker compose -p mcctl-v1" "the server is made again with the new port"
order=$(calls | awk '/up -d --wait --no-deps egress-guard/ {print "guard"} /sed -i/ {print "config"} /compose -p mcctl-v1 -f/ {print "server"}' | paste -sd, -)
assert_eq "guard,config,server" "$order" "in this order: the guard, the mod's config, the server"
m voice v1; assert_contains "$OUT" "voice chat on UDP 24454" "the status shows the port"

echo "cmd_voice set: a port of another server is refused; the same server may keep its port"
mk v2; guard_up; config_there; reset
m voice v2 set 24454; assert_eq 4 "$RC" "UDP 24454 is v1's: EX_REFUSED"
assert_contains "$OUT" "is already the voice port of v1" "and names the owner"
m voice v1 set 24454; assert_eq 0 "$RC" "v1 may set its own port again"

echo "cmd_voice set: when the guard cannot be set, the server is put back as it was"
mk v4; guard_up; config_there
echo 1 >"$FAKE_STATE/docker.compose.up.rc"; reset
m voice v4 set 24456; assert_eq 1 "$RC" "the guard fails: EX_FAIL"
assert_contains "$OUT" "v4 is as it was" "and it says so"
assert_not_contains "$(<"$SB/servers/v4/server.env")" "VOICE_PORT" "server.env is as it was"
assert_not_contains "$(<"$SB/servers/v4/compose.yaml")" "ports:" "compose.yaml is as it was"
rm -f "$FAKE_STATE/docker.compose.up.rc"

echo "cmd_voice off: the port is no longer published; the mod's config keeps its number"
m voice v1 off; assert_eq 0 "$RC" "mcctl voice v1 off exits 0"
assert_not_contains "$(<"$SB/servers/v1/server.env")" "VOICE_PORT" "server.env has no VOICE_PORT"
assert_not_contains "$(<"$SB/servers/v1/compose.yaml")" "ports:" "compose.yaml publishes nothing"
assert_contains "$(calls)" "up -d --wait --no-deps egress-guard" "the guard is set again, so the port's rule is gone"

echo "structural: set refuses VOICE_PORT, and says which command sets it"
mk v5; reset
m set v5 VOICE_PORT=24460; assert_eq 4 "$RC" "mcctl set refuses VOICE_PORT: EX_REFUSED"
assert_contains "$OUT" "VOICE_PORT is structural" "and names mcctl voice"
assert_not_contains "$(<"$SB/servers/v5/server.env")" "VOICE_PORT" "server.env is unchanged"

echo "every cmd_voice shape: usage errors"
m voice; assert_eq 2 "$RC" "mcctl voice with no name: EX_USAGE"
mk v6
m voice v6 set; assert_eq 2 "$RC" "set without a port: EX_USAGE"
m voice v6 on; assert_eq 2 "$RC" "an unknown action: EX_USAGE"

sandbox_cleanup
finish

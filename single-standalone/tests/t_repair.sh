#!/usr/bin/env bash
# cmd_repair (mcctl repair NAME): data/, backups/ (755) and the RCON secret go to the game's user; only the backup sidecar is restarted.
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
mk() {
    local n=$1 st=${2:-stopped}
    mkdir -p "$SB/servers/$n/data" "$SB/servers/$n/backups" "$SB/secrets"
    printf 'TYPE=PAPER\nVERSION=LATEST\nMEMORY=4G\nCPUS=2\nHOSTNAME_SLUG=%s\nEULA=TRUE\n' "$n" >"$SB/servers/$n/server.env"
    chmod 600 "$SB/servers/$n/server.env"
    write_compose "$n" && chmod 600 "$SB/servers/$n/compose.yaml"
    printf 'test-rcon-pass-%s\n' "$n" >"$SB/secrets/rcon-$n"; chmod 600 "$SB/secrets/rcon-$n"
    fake_server "$n" "$n" "$st"
    canned "$FMT_STATE" "$st"; canned "$FMT_LABEL" "$(config_hash "$n")"
    reset
}

echo "repair: the three owners, in this order, and no restart of a stopped server"
mk r1 stopped
m repair r1; assert_eq 0 "$RC" "mcctl repair r1 exits 0"
assert_contains "$OUT" "owners repaired" "and says so"
order=$(calls | grep '^docker run' | sed -E 's#.*-v ([^ ]+):/m:[a-z]+ .* sh 1000( [0-7]+)?$#\1\2#' | sed "s#$SB/##" | paste -sd, -)
assert_eq "servers/r1/data,servers/r1/backups 755,secrets/rcon-r1" "$order" "data/, backups/ with mode 755, then the secret"
assert_eq "$(give_line "$SB/servers/r1/backups" 755)" "$(calls | grep 'backups:/m')" "backups/ is given with FOWNER, for the mode"
assert_eq 0 "$(count_calls 'restart backup')" "a stopped server's sidecar is not restarted (it starts with the server)"
assert_eq 0 "$(count_calls 'mcctl-r1 .* \(start\|stop\|up\|create\)')" "and nothing else of the server is touched"

echo "repair: a running server has only its backup sidecar restarted"
mk r2 running
m repair r2; assert_eq 0 "$RC" "mcctl repair r2 exits 0"
assert_eq 1 "$(count_calls "docker compose -p mcctl-r2 -f $SB/servers/r2/compose.yaml restart backup\$")" "the sidecar is restarted, by its service name"
assert_eq 0 "$(count_calls "mcctl-r2 .* restart\$")" "the game service is not restarted"
assert_contains "$OUT" "the game was not touched" "and the answer says so"

echo "repair: refusals change nothing"
mk r3 stopped; rm -f "$SB/secrets/rcon-r3"; reset
m repair r3; assert_eq 1 "$RC" "no secret: EX_FAIL"
assert_contains "$OUT" "secrets/rcon-r3 is missing" "and it names the file"
assert_eq 0 "$(count_calls '^docker run')" "no helper ran"
m repair; assert_eq 2 "$RC" "no name: EX_USAGE"
m repair ../x; assert_eq 2 "$RC" "a path as name: EX_USAGE"

sandbox_cleanup
finish

#!/usr/bin/env bash
# E13: command sequences run end to end against the fakes, with the ORDERED call log asserted (not only exit codes). Each task
# adds its own flows here. The fake docker is stateless, so a flow plays Docker's part between commands with fake_server and
# fake_gone (tests/lib.sh): "the container now exists" / "the container is gone".
# E4: the generated RCON password and the Cloudflare token never appear in any output or in the call log of a flow.
# fakebin/curl plays Cloudflare and keeps its records (dns_records in tests/lib.sh reads them).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
fake_cloudflare

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
# tags: the call log, one short tag per line. A compose call keeps its project name, and only counts when it names the file
# servers/NAME/compose.yaml of that same NAME. Tasks that add calls add their tags here.
tags() {
    sed -E \
        -e "s|^docker compose -p mcctl-([a-z0-9-]+) -f $SB/servers/\1/compose.yaml |compose[\1] |" \
        -e 's|^docker ps -a -q --filter label=mcctl\.name=(.*)$|name? \1|' \
        -e 's|^docker ps -a -q --filter label=mcctl\.hostname=(.*)$|host? \1|' \
        -e 's|^docker ps -a --filter label=mcctl\.hostname=([^ ]*) --format .*$|owner? \1|' \
        -e 's|^docker ps -a --filter label=mcctl\.managed=true --format .*$|list|' \
        -e 's|^docker inspect --format .* (mc-[a-z0-9-]+)$|inspect \1|' \
        -e "s|^docker compose -p mcctl-sftp -f $SB/sftp.compose.yml ps -q --status running sftp\$|sftp?|" \
        -e 's|^curl .* -X GET .*/dns_records\?name=(.*)$|dns? \1|' \
        -e 's|^curl .* -X GET .*/dns_records\?comment\.exact=mcctl%20name%3D(.*)$|dns-of? \1|' \
        -e 's|^curl .* -X POST .*"name":"([^"]*)".*$|dns+ \1|' \
        -e 's|^curl .* -X DELETE .*/dns_records/.*$|dns-|' \
        -e 's|^docker stats .*$|stats|' \
        -e 's|^docker logs --tail [0-9][0-9]* mc-[a-z0-9-]*$|logs|' \
        -e 's|^docker logs --tail [0-9][0-9]* -f mc-[a-z0-9-]*$|logs -f|' \
        -e 's|^docker run --rm .* -v [^ ]*/data:/m:rw .* sh -c chown .*$|give data|' \
        -e 's|^docker run --rm .* -v [^ ]*/backups:/m:rw .* sh -c chown .*$|give backups|' \
        -e 's|^docker run --rm .* -v [^ ]*\.TMP:/m:rw .* sh -c chown .*$|give secret|' \
        -e 's|^docker run --rm .* -v [^ ]*:/m:ro .* tar -czf .*$|archive|' \
        -e 's|^docker run --rm .* -v [^ ]*:/m:rw .* rm -rf -- /m/data.*$|clear|' <<<"$(calls)"
}
ALL=""   # every output of the flow, to search for the secret
run() { m "$@"; ALL+=$OUT$'\n'; }
# leftovers: everything under servers/ and secrets/ (the two folders themselves and the operator's Cloudflare token excepted)
leftovers() { (cd "$SB" && find servers secrets -mindepth 1 -print 2>/dev/null | grep -vx secrets/cloudflare_token | sort | paste -sd, -); }

echo "flow: create, upgrade (snapshot, pull, recreate), a modpack set, then modpack update --clean (one recreate with the flag, then none) (E13, ordered log)"
cp "$REPO/tests/fixtures/archives/clean.tar.gz" "$FAKE_STATE/docker.run.tar"   # what the snapshot's docker run ... tar replays
reset
run create f1 --type PAPER --accept-eula;               assert_eq 0 "$RC" "create f1"
fake_server f1 f1 exited; echo exited >"$FAKE_STATE/docker.inspect"
reset
run --yes upgrade f1;                                   assert_eq 0 "$RC" "upgrade f1 (stopped, VERSION unset)"
assert_eq "name? f1
inspect mc-f1
inspect mc-f1
snapshot
compose[f1] pull
compose[f1] create --force-recreate" "$(tags | sed -E 's/^docker run --rm .*/snapshot/')" "E13, ordered: the name check, the state for the guard, the snapshot (its state, then the tar), docker compose pull, create --force-recreate (stopped, so no reload)"
assert_eq 1 "$(ls "$SB/servers/f1/safety" | grep -c '^pre-upgrade-')" "the snapshot is in safety/"
run --yes modpack f1 set --source modrinth --pack adrenaserver; assert_eq 0 "$RC" "modpack f1 set (a Modrinth pack, --yes)"
# --clean needs a running server (R10): the container runs, has players 0, and its health goes starting, then healthy
echo running >"$FAKE_STATE/docker.inspect"
printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
printf 'starting\nhealthy\n' >"$FAKE_STATE/docker.inspect.___State_Health_Status__.seq"   # the fake's name for the health format
rm -f -- "$FAKE_STATE/docker.recreates" "$FAKE_STATE"/docker.compose.recreate.*   # numbering of this command's recreates starts at 1
reset
run --yes modpack f1 update --clean --timeout 5;        assert_eq 0 "$RC" "modpack f1 update --clean"
assert_eq "name? f1
snapshot
compose[f1] up -d --force-recreate
compose[f1] up -d --force-recreate" "$(tags | sed -E 's/^docker run --rm .*/snapshot/' | grep -E '^(name\?|snapshot|compose|reload)')" "E13, ordered: the snapshot, then the recreate with REMOVE_OLD_MODS, the health wait, then the recreate without it (two recreates, each followed by the router signal)"
assert_contains "$(<"$FAKE_STATE/docker.compose.recreate.1.yml")" 'REMOVE_OLD_MODS: "TRUE"' "the first recreate holds the flag"
assert_eq 0 "$(grep -c REMOVE_OLD_MODS "$FAKE_STATE/docker.compose.recreate.2.yml")" "the second recreate does not"
assert_eq 0 "$(grep -c REMOVE_OLD_MODS "$SB/servers/f1/server.env" "$SB/servers/f1/compose.yaml" | awk -F: '{s+=$2} END {print s+0}')" "afterwards server.env and compose.yaml do not hold it"
assert_not_contains "$ALL$(calls)" "$CF_TOKEN" "E4: the Cloudflare token is in no output and no call of these commands"
run --yes delete f1;                                    assert_eq 0 "$RC" "delete f1"
fake_gone f1 f1
rm -f -- "$FAKE_STATE/docker.inspect" "$FAKE_STATE/docker.exec"

echo "flow: create, list, start, status, restart, stop, kill, delete"
reset
run create s1 --type PAPER --accept-eula --memory 2G;  assert_eq 0 "$RC" "create"
pw1=$(<"$SB/secrets/rcon-s1")
fake_server s1 s1 created
run list;                                              assert_eq 0 "$RC" "list"
assert_contains "$OUT" "created" "the new server is listed as created (it exists, it is not running)"
run start s1;                                          assert_eq 0 "$RC" "start"
fake_server s1 s1 running
printf 'running|healthy|s1.mc.example.net|itzg/minecraft-server|2026-10-24T01:02:03Z\n' >"$FAKE_STATE/docker.inspect"
run status s1;                                         assert_eq 0 "$RC" "status"
assert_contains "$OUT" "mc-s1 (running, healthy)" "status shows the running container"
run restart s1;                                        assert_eq 0 "$RC" "restart"
run stop s1;                                           assert_eq 0 "$RC" "stop"
run --yes kill s1;                                     assert_eq 0 "$RC" "kill --yes"
run --yes delete s1;                                   assert_eq 0 "$RC" "delete --yes"
fake_gone s1 s1
run list;                                              assert_eq 0 "$RC" "list after the delete"
assert_contains "$OUT" "no servers yet" "nothing is listed"
assert_eq "name? s1
host? s1
dns? s1.mc.example.net
dns+ s1.mc.example.net
give data
give backups
give secret
sftp?
compose[s1] create
list
name? s1
compose[s1] start
name? s1
inspect mc-s1
name? s1
compose[s1] restart
name? s1
compose[s1] stop
name? s1
compose[s1] kill
name? s1
compose[s1] stop
archive
dns-of? s1
dns-
compose[s1] rm -s -f
sftp?
clear
list" "$(tags)" "the ordered call log: checks, DNS, create (the game's user is given data and the secret, then asking whether SFTP runs), list, every command asks Docker first and runs one compose verb, delete stops, archives, deletes the DNS record, removes the containers, updates SFTP and clears the game's data"
assert_eq "" "$(leftovers)" "and the delete left no folder and no secret"
assert_eq "" "$(dns_records)" "and no DNS record"
assert_eq 32 "${#pw1}" "(the password this flow looks for is real)"
assert_not_contains "$ALL$(calls)" "$pw1" "the RCON password is in no output and not in the call log (E4)"
rm -f "$FAKE_STATE/docker.inspect"

echo "flow: two servers, a hostname collision, then a free hostname"
reset; ALL=""
run create a --type PAPER --accept-eula --hostname play;   assert_eq 0 "$RC" "create a --hostname play"
fake_server a play
run create b --type PAPER --accept-eula --hostname play;   assert_eq 4 "$RC" "create b --hostname play is refused"
assert_contains "$OUT" "already used by server a" "and names the first server"
assert_eq "a" "$(ls "$SB/servers" | paste -sd, -)" "servers/ holds only a: the refused create left nothing"
run create b --type FABRIC --accept-eula --hostname play2; assert_eq 0 "$RC" "create b --hostname play2"
fake_server b play2
run list;                                                  assert_eq 0 "$RC" "list"
[[ $OUT == *a*play.mc.example.net* && $OUT == *b*play2.mc.example.net* ]] && pass "both servers are listed with their own address" || fail "both servers are listed" "$OUT"
assert_eq "name? a
host? play
dns? play.mc.example.net
dns+ play.mc.example.net
give data
give backups
give secret
sftp?
compose[a] create
name? b
host? play
owner? play
name? b
host? play2
dns? play2.mc.example.net
dns+ play2.mc.example.net
give data
give backups
give secret
sftp?
compose[b] create
list" "$(tags)" "the ordered call log: the refused create never reaches Cloudflare or compose"
assert_eq "play.mc.example.net mcctl name=a
play2.mc.example.net mcctl name=b" "$(dns_records)" "one DNS record each, named after its host and commented with its server"
assert_eq "a,b" "$(ls "$SB/servers" | paste -sd, -)" "servers/ now holds a and b"
assert_eq "cloudflare_token,rcon-a,rcon-b" "$(ls "$SB/secrets" | paste -sd, -)" "secrets/ holds one RCON secret each (and the operator's token)"
assert_not_contains "$ALL$(calls)" "$(<"$SB/secrets/rcon-a")" "the RCON password of a is in no output and not in the call log"
assert_not_contains "$ALL$(calls)" "$(<"$SB/secrets/rcon-b")" "nor that of b"
fake_gone a play; fake_gone b play2
run --yes delete a; run --yes delete b
assert_eq "" "$(leftovers)" "deleting both (their containers already gone) leaves no server folder and no secret"
assert_eq "" "$(dns_records)" "and no DNS record"

echo "flow: a failed create, then the same create again"
reset; ALL=""
echo 1 >"$FAKE_STATE/docker.compose.create.rc"
run create s1 --type PAPER --accept-eula;   assert_eq 1 "$RC" "create fails when docker compose create fails"
assert_eq "" "$(leftovers)" "nothing is left: no folder, no secret"
rm -f "$FAKE_STATE/docker.compose.create.rc"
run create s1 --type PAPER --accept-eula;   assert_eq 0 "$RC" "the same create, run again, completes"
assert_file "$SB/servers/s1/compose.yaml" "and the folder is there"
assert_file "$SB/secrets/rcon-s1" "and the secret"
assert_eq "name? s1
host? s1
dns? s1.mc.example.net
dns+ s1.mc.example.net
give data
give backups
give secret
sftp?
compose[s1] create
compose[s1] rm -s -f
dns? s1.mc.example.net
dns-
sftp?
clear
name? s1
host? s1
dns? s1.mc.example.net
dns+ s1.mc.example.net
give data
give backups
give secret
sftp?
compose[s1] create" "$(tags)" "the ordered call log: DNS, create, clean-up in reverse (containers, record, folder), then a clean retry"
assert_not_contains "$ALL$(calls)" "$(<"$SB/secrets/rcon-s1")" "the password is in no output and not in the call log"

echo "flow: a CurseForge pack, with and without the operator's API key"
run --yes delete s1   # the previous flow's server; its container is not in the fake
reset; ALL=""
run create atm --accept-eula --modpack-source curseforge --modpack all-the-mods-10 --modpack-version 9190157 --memory 6G
assert_eq 3 "$RC" "create without secrets/curseforge_api_key is refused (EX_PREFLIGHT)"
assert_eq "" "$(tags)" "and Docker is never asked"
assert_eq "" "$(leftovers)" "and nothing is written"
plant_canary "$SB/secrets/curseforge_api_key"
run create atm --accept-eula --modpack-source curseforge --modpack all-the-mods-10 --modpack-version 9190157 --memory 6G
assert_eq 0 "$RC" "create with the key file in place"
fake_server atm atm created
run start atm;                                         assert_eq 0 "$RC" "start"
fake_server atm atm running
run --yes delete atm;                                  assert_eq 0 "$RC" "delete --yes"
fake_gone atm atm
assert_eq "name? atm
host? atm
dns? atm.mc.example.net
dns+ atm.mc.example.net
give data
give backups
give secret
sftp?
compose[atm] create
name? atm
compose[atm] start
name? atm
compose[atm] stop
archive
dns-of? atm
dns-
compose[atm] rm -s -f
sftp?
clear" "$(tags)" "the ordered call log: the refused create never reaches Docker or Cloudflare; create, start, delete"
assert_eq "secrets/curseforge_api_key" "$(leftovers)" "delete removes the server and its RCON secret, and leaves the operator's key"
assert_not_contains "$ALL$(calls)" "$CANARY" "the CurseForge key is in no output and not in the call log (E4)"

echo "flow: a console on a stopped server, then start, RCON, players, a refused name, rotate-rcon, delete"
reset; ALL=""
run create s1 --type PAPER --accept-eula;              assert_eq 0 "$RC" "create"
plant_canary "$SB/secrets/rcon-s1"; old=$CANARY
fake_server s1 s1 created; echo created >"$FAKE_STATE/docker.inspect"
run console s1;                                        assert_eq 1 "$RC" "console on a server that was never started is refused"
assert_contains "$OUT" "mcctl start s1" "and names mcctl start"
run start s1;                                          assert_eq 0 "$RC" "start"
fake_server s1 s1 running; echo running >"$FAKE_STATE/docker.inspect"
printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
run whitelist add s1 Notch;                            assert_eq 0 "$RC" "whitelist add"
run ban s1 'x; stop';                                  assert_eq 2 "$RC" "ban 'x; stop' is refused"
run ban s1 Notch;                                      assert_eq 0 "$RC" "ban"
run kick s1 Notch;                                     assert_eq 0 "$RC" "kick"
run op s1 Notch;                                       assert_eq 0 "$RC" "op"
run players s1;                                        assert_eq 0 "$RC" "players"
run rcon s1 say hi;                                    assert_eq 0 "$RC" "rcon"
run --yes rotate-rcon s1;                              assert_eq 0 "$RC" "rotate-rcon"
new=$(<"$SB/secrets/rcon-s1")
run --yes delete s1;                                   assert_eq 0 "$RC" "delete"
fake_gone s1 s1
assert_eq "name? s1
host? s1
dns? s1.mc.example.net
dns+ s1.mc.example.net
give data
give backups
give secret
sftp?
compose[s1] create
name? s1
inspect mc-s1
name? s1
compose[s1] start
name? s1
inspect mc-s1
docker exec -i mc-s1 rcon-cli whitelist add Notch
name? s1
inspect mc-s1
docker exec -i mc-s1 rcon-cli ban Notch
name? s1
inspect mc-s1
docker exec -i mc-s1 rcon-cli kick Notch
name? s1
inspect mc-s1
docker exec -i mc-s1 rcon-cli op Notch
name? s1
inspect mc-s1
docker exec -i mc-s1 rcon-cli list
name? s1
inspect mc-s1
docker exec -i mc-s1 rcon-cli say hi
name? s1
inspect mc-s1
give secret
compose[s1] restart
name? s1
compose[s1] stop
archive
dns-of? s1
dns-
compose[s1] rm -s -f
sftp?
clear" "$(tags)" "the ordered call log: the console and the refused ban never reach rcon-cli; each command asks, checks, sends once; rotate-rcon gives the new secret to the game's user before the restart"
assert_eq "secrets/curseforge_api_key" "$(leftovers)" "and the delete left no folder and no RCON secret (the operator's CurseForge key of the flow above stays)"
assert_ne() { if [[ $1 != "$2" ]]; then pass "$3"; else fail "$3" "both are '$1'"; fi; }
assert_ne "$old" "$new" "rotate-rcon gave the server a different password"
assert_not_contains "$ALL$(calls)" "$old" "the old RCON password is in no output and not in the call log (E4)"
assert_not_contains "$ALL$(calls)" "$new" "nor is the new one"
rm -f "$FAKE_STATE/docker.inspect" "$FAKE_STATE/docker.exec"

echo "flow: create with a hostname, a delete whose DNS step fails (nothing is removed), then the same delete again"
reset; ALL=""
run create s7 --type PAPER --accept-eula --hostname seven;   assert_eq 0 "$RC" "create s7 --hostname seven"
assert_eq "seven.mc.example.net mcctl name=s7" "$(dns_records)" "its DNS record is seven.mc.example.net, commented 'mcctl name=s7'"
fake_server s7 seven
mkdir -p "$SB/servers/s7/data/world"; echo level >"$SB/servers/s7/data/world/level.dat"
before=$(leftovers)
echo 7 >"$FAKE_STATE/curl.DELETE.rc"                     # Cloudflare cannot be reached for the DELETE
run --yes delete s7;                                      assert_eq 1 "$RC" "delete: the DNS step fails, EX_FAIL"
assert_contains "$OUT" "could not delete the DNS record seven.mc.example.net" "and a warning names the record"
assert_contains "$OUT" "nothing was removed" "and says nothing was removed"
rm -f "$FAKE_STATE/curl.DELETE.rc"
assert_eq "$before" "$(leftovers)" "the folder and the secret are as they were"
assert_eq "seven.mc.example.net mcctl name=s7" "$(dns_records)" "and so is the record: it points at a server that still exists"
run --yes delete s7;                                      assert_eq 0 "$RC" "the same delete, run again, completes"
fake_gone s7 seven
assert_eq "" "$(dns_records)" "the record is gone"
assert_eq "secrets/curseforge_api_key" "$(leftovers)" "and so are the folder and the secret (the CurseForge key of an earlier flow stays)"
assert_eq "name? s7
host? seven
dns? seven.mc.example.net
dns+ seven.mc.example.net
give data
give backups
give secret
sftp?
compose[s7] create
name? s7
compose[s7] stop
archive
dns-of? s7
dns-
name? s7
compose[s7] stop
archive
dns-of? s7
dns-
compose[s7] rm -s -f
sftp?
clear" "$(tags)" "the ordered call log: create; the failed delete archives, then stops after the DNS DELETE; the second one archives again, deletes the record, then the containers, then clears the game's data"
assert_eq "level" "$(tar -xzOf "$(ls -t "$SB"/trash/s7-*.tar.gz | head -n 1)" data/world/level.dat)" "the world is in trash/s7-<UTC>.tar.gz"
assert_not_contains "$ALL$(calls)" "$CF_TOKEN" "the Cloudflare token is in no output and not in the call log (E4)"

echo "flow: up, up again while the router runs, down, up, then up while another process holds 25565"
reset; ALL=""
DPL='LISTEN 0 4096 0.0.0.0:25565 0.0.0.0:* users:(("docker-proxy",pid=811,fd=4))'
run up;                                                assert_eq 0 "$RC" "up: a free port, a new network"
printf '%s\n' "$DPL" >"$FAKE_STATE/ss.listen"                    # the router now holds the port, and compose knows it
echo cid1 >"$FAKE_STATE/docker.compose.ps.running.mc-router"
echo abc123 >"$FAKE_STATE/docker.network.ls"
printf '172.30.0.0/24 \n' >"$FAKE_STATE/docker.network.inspect"
run up;                                                assert_eq 0 "$RC" "up again: the listener is the stack's own router"
run down;                                              assert_eq 0 "$RC" "down"
rm -f "$FAKE_STATE/ss.listen" "$FAKE_STATE/docker.compose.ps.running.mc-router"
run up;                                                assert_eq 0 "$RC" "up after down: the network is still there"
printf '%s\n' 'LISTEN 0 4096 0.0.0.0:25565 0.0.0.0:* users:(("mc-router",pid=4242,fd=7))' >"$FAKE_STATE/ss.listen"
rm -f "$FAKE_STATE/docker.compose.ps.running.mc-router"
run up;                                                assert_eq 3 "$RC" "up while another mc-router holds the port: refused (EX_PREFLIGHT)"
assert_contains "$OUT" "pid=4242" "and the listener is named"
SS='ss -H -ltnp ( sport = :25565 )' NET='docker network ls -q --filter name=^mcctl_game$'
SFU="docker compose -p mcctl-sftp -f $SB/sftp.compose.yml up -d --force-recreate sftp" SFD="docker compose -p mcctl-sftp -f $SB/sftp.compose.yml down"   # SFTP follows the router stack up and down
INS='docker network inspect --format {{range .IPAM.Config}}{{.Subnet}} {{end}} mcctl_game'
STK="docker compose -p mcctl-stack -f $SB/templates/stack.compose.yml"
assert_eq "$SS
$NET
docker network create --driver bridge --subnet 172.30.0.0/24 --ip-range 172.30.0.128/25 --label mcctl.managed=true mcctl_game
$STK up -d --wait
$SS
$STK ps -q --status running mc-router
$NET
$INS
$STK up -d --wait
$STK down
$SFD
$SS
$NET
$INS
$STK up -d --wait
$SS
$STK ps -q --status running mc-router" "$(calls)" "the ordered call log: the refused up asks the port and the stack and stops there (no SFTP user here, so no SFTP stack)"
rm -f "$FAKE_STATE"/ss.* "$FAKE_STATE"/docker.network.* "$FAKE_STATE"/docker.compose.*

echo "flow: start, edit resources with --yes (recreate the whole project)"
reset; ALL=""
mkdir -p "$SB/servers/s1/data" "$SB/servers/s1/backups" "$SB/secrets"
printf '# Written by mcctl create. mcctl reads this file; it never runs it.\nTYPE=PAPER\nVERSION=LATEST\nMEMORY=4G\nCPUS=2\nHOSTNAME_SLUG=s1\nEULA=TRUE\n' >"$SB/servers/s1/server.env"
chmod 600 "$SB/servers/s1/server.env"
write_compose s1; chmod 600 "$SB/servers/s1/compose.yaml"
printf 'test-rcon-pass-s1\n' >"$SB/secrets/rcon-s1"; chmod 600 "$SB/secrets/rcon-s1"
fake_server s1 s1 created
run start s1;                                           assert_eq 0 "$RC" "start s1"
fake_server s1 s1 running; echo running >"$FAKE_STATE/docker.inspect"
printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
reset
run --yes edit s1 --memory 6G;                          assert_eq 0 "$RC" "edit s1 --memory 6G --yes"
assert_contains "$(<"$SB/servers/s1/server.env")" "MEMORY=6G" "server.env has the new memory"
assert_eq "name? s1
inspect mc-s1
docker exec -i mc-s1 rcon-cli list
compose[s1] up -d --force-recreate" "$(tags)" "the ordered call log from inspect to the recreate: name check, inspect, rcon list, compose up -d --force-recreate (no service name)"
rm -f "$FAKE_STATE/docker.inspect" "$FAKE_STATE/docker.exec"
fake_gone s1 s1
rm -rf "$SB/servers/s1" "$SB/secrets/rcon-s1"

echo "flow: firewall plan, apply, confirm, rollback"
reset; ALL=""
rm -f "$FAKE_STATE"/ufw.* "$FAKE_STATE"/sshd.* "$FAKE_STATE"/ss.* "$FAKE_STATE"/rollback.*
rm -rf "$FAKE_STATE/systemd"; mkdir -p "$FAKE_STATE/systemd"
echo 22 >"$FAKE_STATE/sshd.ports"
export FAKE_UID=0
run firewall plan;                                         assert_eq 0 "$RC" "firewall plan"
run --yes firewall apply;                                  assert_eq 0 "$RC" "firewall apply"
run firewall confirm;                                      assert_eq 0 "$RC" "firewall confirm"
run firewall rollback;                                     assert_eq 0 "$RC" "firewall rollback"
ufw_calls=$(calls | grep '^ufw ')
assert_eq "ufw status
ufw status verbose
ufw allow 22/tcp comment mcctl: ssh
ufw allow 25565/tcp comment mcctl: minecraft router
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
ufw status
ufw --force disable" "$ufw_calls" "the ordered ufw call log: status, save, allow SSH, allow router, defaults, enable, verify, then disable on rollback"
assert_eq 1 "$(calls | grep -c '^systemd-run')" "one systemd-run call (arm the timer)"
assert_eq 2 "$(calls | grep -c '^systemctl stop')" "two systemctl stop calls (confirm and rollback)"
unset FAKE_UID

echo "flow: create, start, top once, logs"
reset; ALL=""
run create s1 --type PAPER --accept-eula; assert_eq 0 "$RC" "create"
fake_server s1 s1 running
fake_server s2 s2 stopped
printf 'mc-s1|1.23%%|100MiB / 1GiB|10.00%%|1kB / 2kB|3kB / 4kB\n' >"$FAKE_STATE/docker.stats"
printf '[12:00:01] [Server thread/INFO]: Done starting\n' >"$FAKE_STATE/docker.logs"
reset
run top; assert_eq 0 "$RC" "top"
assert_contains "$OUT" "s1" "top shows the server"
assert_contains "$OUT" "running 1," "top counts the one running server (s2 is stopped)"
assert_contains "$(calls)" "mc-s1" "docker stats asks for the running server"
assert_not_contains "$(calls)" "mc-s2" "and not for the stopped one"
fake_gone s2 s2
run logs s1 --tail 3; assert_eq 0 "$RC" "logs"
assert_contains "$OUT" "Done starting" "logs shows the line"
assert_contains "$(calls)" "docker logs --tail 3 mc-s1" "docker logs asks for the last 3 lines of mc-s1"
assert_eq "list
stats
name? s1
logs" "$(tags)" "ordered call log: top (list, stats), logs (name check, logs)"

echo "flow: files: mkdir, put, ls, get, edit, rm on one server's data folder (ordered call log)"
reset; ALL=""; rm -f -- "$FAKE_STATE"/run.stdin.* "$FAKE_STATE"/docker.run.*
mkdir -p "$SB/servers/f1/data"; printf 'pack\n' >"$SB/pack.jar"
printf '#!/bin/sh\nprintf "edited\\n" >>"$1"\n' >"$SB/flow-edit.sh"; chmod +x "$SB/flow-edit.sh"
echo 1 >"$FAKE_STATE/docker.run.test.rc"               # nothing of that name exists (test -d, test -e)
echo 1 >"$FAKE_STATE/docker.run.stat.rc"               # nothing of that name exists (stat -c %F)
run files f1 mkdir mods; assert_eq 0 "$RC" "files mkdir mods"
run files f1 put pack.jar mods/a.jar; assert_eq 0 "$RC" "files put: the new file"
cmp -s "$SB/pack.jar" "$FAKE_STATE/run.stdin.1" && pass "put: the file is the helper's stdin" || fail "put: the file is the helper's stdin"
printf 'a.jar\n' >"$FAKE_STATE/docker.run.ls"
run files f1 ls mods; assert_contains "$OUT" "a.jar" "files ls mods lists it"
printf 'pack\n' >"$FAKE_STATE/docker.run.cat"
run files f1 get mods/a.jar got.jar; assert_eq 0 "$RC" "files get"
cmp -s "$SB/pack.jar" "$SB/got.jar" && pass "get: the local copy matches" || fail "get: the local copy matches"
rm -f -- "$FAKE_STATE/docker.run.stat.rc"; printf '5\n' >"$FAKE_STATE/docker.run.stat"   # the file exists now: its size
EDITOR=$SB/flow-edit.sh run files f1 edit mods/a.jar; assert_eq 0 "$RC" "files edit"
printf 'pack\nedited\n' >"$SB/want.jar"
cmp -s "$SB/want.jar" "$FAKE_STATE/run.stdin.2" && pass "edit: the edited copy is written back" || fail "edit: the edited copy is written back"
run files f1 rm mods/a.jar; assert_eq 0 "$RC" "files rm mods/a.jar"
assert_eq "confine
mkdir
confine
stat
store
confine
ls
confine
cat
confine
stat
cat
store
confine
test
rm" "$(sed -E -e 's/^docker run .* alpine:3[.]20 //' -e 's/^sh -c p=.*/confine/' -e 's/^sh -c cat > .*/store/' \
    -e 's/^(stat|cat|ls|test|mkdir|rm|mv) .*/\1/' <<<"$(calls)")" "ordered call log: each step's helper calls, in order"
rm -f -- "$SB/got.jar"

echo "flow: set, status (pending), apply, status (current): the config label carries the hash (E13)"
reset; ALL=""
# canned FORMAT OUT: the fake docker's answer to `docker inspect --format FORMAT ...` (the file is named after the sanitized format)
canned() { printf '%s\n' "$2" >"$FAKE_STATE/docker.inspect.${1//[^A-Za-z0-9_-]/_}"; }
F_STATE='{{.State.Status}}'
F_LABEL='{{index .Config.Labels "mcctl.config_hash"}}'
F_STATUS='{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{index .Config.Labels "mc-router.host"}}|{{.Config.Image}}|{{.State.StartedAt}}|{{index .Config.Labels "mcctl.config_hash"}}'
# run_as STATE LABEL: what Docker answers for s1 in STATE, whose game container carries the config label LABEL
run_as() {
    canned "$F_STATE" "$1"
    canned "$F_STATUS" "$1|healthy|s1.mc.example.net|itzg/minecraft-server|2026-10-24T01:02:03Z|$2"
    canned "$F_LABEL" "$2"
}
mkdir -p "$SB/servers/s1/data" "$SB/servers/s1/backups" "$SB/secrets"
printf '# Written by mcctl create. mcctl reads this file; it never runs it.\nTYPE=PAPER\nVERSION=LATEST\nMEMORY=4G\nCPUS=2\nHOSTNAME_SLUG=s1\nEULA=TRUE\n' >"$SB/servers/s1/server.env"
chmod 600 "$SB/servers/s1/server.env"
write_compose s1; chmod 600 "$SB/servers/s1/compose.yaml"
plant_canary "$SB/secrets/rcon-s1"
fake_server s1 s1 running
printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
run_as running "$(config_hash s1)"
reset
run status s1;                                 assert_contains "$OUT" "config:    current" "status: the container carries the hash of the current config"
run set s1 MOTD=flow-hello;                    assert_eq 0 "$RC" "set MOTD=flow-hello"
assert_contains "$OUT" "config pending: mcctl apply s1" "set says config pending"
run status s1;                                 assert_contains "$OUT" "config:    pending (mcctl apply s1)" "status: pending"
reset
run --yes apply s1;                            assert_eq 0 "$RC" "apply --yes (no players online)"
assert_eq "name? s1
inspect mc-s1
inspect mc-s1
docker exec -i mc-s1 rcon-cli list
compose[s1] up -d --force-recreate" "$(tags)" "the ordered call log of apply: name, label, state, list, up -d --force-recreate (no service name)"
run_as running "$(config_hash s1)"             # the recreated container carries the new hash
run status s1;                                 assert_contains "$OUT" "config:    current" "status: current once the container carries the new hash"
assert_not_contains "$ALL$(calls)" "$CANARY" "the RCON password is in no output and no call (E4)"
rm -f -- "$FAKE_STATE"/docker.inspect* "$FAKE_STATE/docker.exec"
fake_gone s1 s1
rm -rf -- "$SB/servers/s1" "$SB/secrets/rcon-s1"

echo "flow: world: create, new --use, start, a live backup, stop, restore the backup, delete a world that is not active (E13, ordered log)"
reset; ALL=""
WLBL="$FAKE_STATE/docker.inspect.$(printf '%s' '{{index .Config.Labels "mcctl.config_hash"}}' | sed 's/[^A-Za-z0-9_-]/_/g')"
WROWS=$'bonus\t1\t50\t1729000000\nold\t0\t-\t-'
run create w1 --type PAPER --accept-eula;  assert_eq 0 "$RC" "create w1"
pw_w1=$(<"$SB/secrets/rcon-w1")
fake_server w1 w1 exited
printf 'exited\n' >"$FAKE_STATE/docker.inspect"
printf '%s\n' "$(config_hash w1)" >"$WLBL"
printf '%s\n' "$WROWS" >"$FAKE_STATE/docker.run.sh"; echo 0 >"$FAKE_STATE/docker.run.sh.rc"
mkdir -p "$SB/tmp/n9/nether9" && echo level >"$SB/tmp/n9/nether9/level.dat"
tar -C "$SB/tmp/n9" -czf "$SB/n9.tar.gz" nether9 && cp "$SB/n9.tar.gz" "$FAKE_STATE/docker.run.tar" && echo 0 >"$FAKE_STATE/docker.run.tar.rc"
reset; run world w1 new nether9 --use --seed 42; assert_eq 0 "$RC" "world new nether9 --use --seed 42"
printf '%s\n' "$(config_hash w1)" >"$WLBL"               # the container is recreated with the new configuration
run start w1;                                              assert_eq 0 "$RC" "start: the server makes nether9 at its first start (fake)"
printf 'running\n' >"$FAKE_STATE/docker.inspect"
printf 'nether9\t1\t10\t1729771200\n%s\n' "$WROWS" >"$FAKE_STATE/docker.run.sh"
run world w1 backup nether9 --out "$SB/w1-backup.tar.gz"; assert_eq 0 "$RC" "backup nether9 on the running server (--out)"
assert_file "$SB/w1-backup.tar.gz" "the live backup is written"
run stop w1;                                               assert_eq 0 "$RC" "stop"
printf 'exited\n' >"$FAKE_STATE/docker.inspect"
run --yes world w1 restore nether9 "$SB/w1-backup.tar.gz"; assert_eq 0 "$RC" "restore nether9 from the backup (stopped)"
run --yes world w1 delete bonus;                           assert_eq 0 "$RC" "delete bonus, which is not the active world"
assert_eq 2 "$(ls "$SB/servers/w1/safety" | grep -c '^world-')" "the two safety archives (restore's copy of nether9, delete's copy of bonus) are in safety/"
assert_eq 0 "$(ls "$SB/servers/w1/backups" | grep -c '^world-')" "and none is in backups/"
wtags() { sed -E \
    -e 's|^docker run --rm -i .* alpine:3[.]20 tar -xzf - .*$|tar-in|' \
    -e 's|^docker run --rm -i .* alpine:3[.]20 sh -c .*$|pipe-sh|' \
    -e 's|^docker run .* alpine:3[.]20 tar -czf - -- (.*)$|tar-out \1|' \
    -e 's|^docker run .* alpine:3[.]20 rm -rf -- (.*)$|rm \1|' \
    -e 's|^docker run .* alpine:3[.]20 mv -- (.*)$|mv \1|' \
    -e 's|^docker run .* alpine:3[.]20 mkdir .*$|mkdir|' \
    -e 's|^docker run .* alpine:3[.]20 sh -c for d in .*$|scan|' \
    -e 's|^docker run .* alpine:3[.]20 sh -c .*$|sh|' \
    -e 's|^docker ps .*$|name?|' \
    -e 's|^docker inspect --format \{\{\.State\.Status\}\} .*$|state|' \
    -e 's|^docker inspect --format \{\{index .*$|label|' \
    -e 's|^docker exec -i mc-w1 rcon-cli (.*)$|rcon \1|' \
    -e 's|^docker compose -p mcctl-w1 -f [^ ]* ([a-z-]+).*$|compose \1|' <<<"$(calls)"; }
assert_eq "name?
state
scan
label
state
compose create
name?
compose start
name?
scan
state
rcon save-off
rcon save-all flush
tar-out nether9
rcon save-on
name?
compose stop
name?
state
scan
state
tar-out nether9
rm nether9
tar-in
name?
state
scan
state
tar-out bonus
rm bonus" "$(wtags)" "E1, ordered: new --use (apply), start, a live backup (save-off, flush, tar, save-on), stop, restore (copy, rm, extract), delete bonus"
assert_not_contains "$ALL$(calls)" "$pw_w1" "E4: the RCON password of w1 is in no output and no call"
rm -f -- "$FAKE_STATE/docker.run.tar" "$FAKE_STATE/docker.run.tar.rc"

echo "flow: whitelist import, ban-ip with a reason, pardon-ip, time, weather, save (E13, ordered log)"
reset; ALL=""
run create pl1 --type PAPER --accept-eula;              assert_eq 0 "$RC" "create"
pl_pw=$(<"$SB/secrets/rcon-pl1")
fake_server pl1 pl1 created; echo created >"$FAKE_STATE/docker.inspect"
run start pl1;                                          assert_eq 0 "$RC" "start"
fake_server pl1 pl1 running; echo running >"$FAKE_STATE/docker.inspect"
printf '# the list\nSteve\n\nAlex\n' >"$SB/pl-names.txt"
# ptags: the call log of pl1, one short tag per line (the two questions every command asks, then its one exec)
ptags() { sed -E \
    -e 's|^docker ps -a -q --filter label=mcctl\.name=(.*)$|name?|' \
    -e 's|^docker inspect --format \{\{\.State\.Status\}\} mc-[a-z0-9-]+$|state|' \
    -e 's|^docker exec -i mc-pl1 rcon-cli (.*)$|rcon \1|' <<<"$(calls)"; }
reset
run whitelist import pl1 "$SB/pl-names.txt";            assert_eq 0 "$RC" "whitelist import"
run ban-ip pl1 10.0.0.1 --reason 'too; many';           assert_eq 0 "$RC" "ban-ip with a reason"
run pardon-ip pl1 10.0.0.1;                             assert_eq 0 "$RC" "pardon-ip"
run time pl1 set day;                                   assert_eq 0 "$RC" "time set day"
run weather pl1 rain 600;                               assert_eq 0 "$RC" "weather rain 600"
run save pl1;                                           assert_eq 0 "$RC" "save"
assert_eq "name?
state
rcon whitelist add Steve
name?
state
rcon whitelist add Alex
name?
state
rcon ban-ip 10.0.0.1 too; many
name?
state
rcon pardon-ip 10.0.0.1
name?
state
rcon time set day
name?
state
rcon weather rain 600
name?
state
rcon save-all flush" "$(ptags)" "E13, ordered: two adds from the file (comments and blanks skipped), ban-ip with a reason, pardon-ip, time, weather, save; each asks Docker twice, then one exec"
assert_not_contains "$ALL$(calls)" "$pl_pw" "E4: the RCON password of pl1 is in no output and no call"
run --yes delete pl1;                                   assert_eq 0 "$RC" "delete"
fake_gone pl1 pl1
rm -f -- "$FAKE_STATE/docker.inspect" "$FAKE_STATE/docker.exec"

echo "flow: mods: modrinth add, mods add URL, sync (applies both), installed, mods remove, sync (E13, ordered log; Task 20)"
reset; ALL=""
run create m1 --type FABRIC --accept-eula;              assert_eq 0 "$RC" "create m1 (FABRIC)"
plant_canary "$SB/secrets/rcon-m1"                      # E4: the RCON password is a canary; no list command may print or pass it
fake_server m1 m1 exited
reset
run modrinth m1 add fabric-api;                         assert_eq 0 "$RC" "modrinth add fabric-api"
assert_contains "$OUT" "config pending: mcctl mods m1 sync" "and says config pending"
run mods m1 add https://cdn.example.net/a.jar;          assert_eq 0 "$RC" "mods add a URL"
assert_eq "name? m1
name? m1" "$(tags)" "E13, ordered: each add asks Docker the name, and nothing else (the lists are not rendered until sync)"
reset
run --yes mods m1 sync;                                 assert_eq 0 "$RC" "sync applies the two adds (stopped: create --force-recreate)"
assert_eq "name? m1
inspect mc-m1
inspect mc-m1
inspect mc-m1
compose[m1] create --force-recreate" "$(tags)" "E13, ordered: the name, the label twice (the sync and apply_pending), the state, then create --force-recreate"
assert_contains "$(<"$SB/servers/m1/compose.yaml")" $'      MODRINTH_PROJECTS: |\n        fabric-api\n' "compose.yaml carries the Modrinth list"
assert_contains "$(<"$SB/servers/m1/compose.yaml")" "        https://cdn.example.net/a.jar" "and the URL list"
assert_contains "$(<"$SB/servers/m1/compose.yaml")" "      - ./mods:/mods:ro" "and the attach point is mounted"
canned "$F_LABEL" "$(config_hash m1)"                   # the recreated container carries the new hash: nothing is pending
reset; printf 'a.jar\n' >"$FAKE_STATE/docker.run.ls"
run mods m1 installed;                                  assert_eq 0 "$RC" "mods installed"
assert_eq "name? m1
ls -la -- mods" "$(tags | sed -E 's/^docker run .* alpine:3[.]20 //')" "E13, ordered: the name, then the one helper run that lists data/mods"
reset
run mods m1 remove https://cdn.example.net/a.jar;       assert_eq 0 "$RC" "mods remove the URL"
run --yes mods m1 sync;                                 assert_eq 0 "$RC" "sync removes it from the container"
assert_eq "name? m1
name? m1
inspect mc-m1
inspect mc-m1
inspect mc-m1
compose[m1] create --force-recreate" "$(tags)" "E13, ordered: the remove, then the same sync sequence"
assert_not_contains "$(<"$SB/servers/m1/compose.yaml")" "https://cdn.example.net/a.jar" "compose.yaml no longer carries the URL"
assert_contains "$(<"$SB/servers/m1/compose.yaml")" "      MODRINTH_PROJECTS: |" "and the Modrinth list stays"
assert_not_contains "$ALL$(calls)" "$CANARY" "E4: the RCON password is in no output and no call of the flow"
rm -f -- "$FAKE_STATE"/docker.inspect* "$FAKE_STATE/docker.run.ls"
run --yes delete m1;                                    assert_eq 0 "$RC" "delete m1"
fake_gone m1 m1

echo "flow: create, clone (lists and a jar, no world), rename to a new hostname, export, delete, import: the round trip (Task 21, E13, ordered log, E4)"
# ftags: tags, and the PATCH of a relabelled record (tags does not know it)
ftags() { tags | sed -E 's|^curl .* -X PATCH .*$|dns~|'; }
: >"$FAKE_STATE/docker.stateful"                       # the containers follow the compose files, as they do on Docker
reset; ALL=""
run create fl1 --type PAPER --accept-eula --hostname flh; assert_eq 0 "$RC" "create fl1"
fl_pw=$(<"$SB/secrets/rcon-fl1")
echo exited >"$FAKE_STATE/docker.inspect"
mkdir -p "$SB/servers/fl1/lists" "$SB/servers/fl1/mods" "$SB/servers/fl1/data/world"
printf 'mod-x\n' >"$SB/servers/fl1/lists/mods.list"
printf 'PK jar\n' >"$SB/servers/fl1/mods/x.jar"; chmod 644 "$SB/servers/fl1/mods/x.jar"
echo level >"$SB/servers/fl1/data/world/level.dat"
reset
run clone fl1 fl2; assert_eq 0 "$RC" "clone fl1 fl2 (the default hostname fl2)"
assert_eq "mod-x" "$(<"$SB/servers/fl2/lists/mods.list")" "the clone has the list"
assert_eq "PK jar" "$(<"$SB/servers/fl2/mods/x.jar")" "and the jar"
assert_no_file "$SB/servers/fl2/data/world/level.dat" "and no world (no --with-data)"
reset
run --yes rename fl2 fl3 --hostname fl3h; assert_eq 0 "$RC" "rename fl2 fl3 --hostname fl3h"
assert_eq "name? fl2
name? fl3
host? fl3h
inspect mc-fl2
dns? fl3h.mc.example.net
dns+ fl3h.mc.example.net" "$(ftags | head -n 6)" "order: the names and the hostname are checked, then the new DNS record is made, before any container is touched"
assert_eq "dns-" "$(ftags | tail -n 1)" "the old record is deleted last"
assert_no_file "$SB/servers/fl2" "fl2 is gone from servers/"
assert_file "$SB/servers/fl3/lists/mods.list" "fl3 has its list"
assert_eq "HOSTNAME_SLUG=fl3h" "$(grep -E '^HOSTNAME_SLUG=' "$SB/servers/fl3/server.env")" "and its hostname"
assert_eq "fl3h.mc.example.net mcctl name=fl3" "$(dns_records | grep -E '^fl3h\.')" "the DNS record names fl3"
assert_eq "" "$(dns_records | grep -E '^fl2\.' || true)" "and no record of fl2 is left"
run --yes rename fl3 fl3 --hostname fl3h >/dev/null 2>&1; [[ $RC -eq 2 ]] && pass "rename onto itself is refused (exit 2)" || fail "rename onto itself is refused (exit 2)"
cp "$SB/servers/fl3/server.env" "$SB/fl3-env-before"
mkdir -p "$SB/servers/fl3/data/world" && echo level >"$SB/servers/fl3/data/world/level.dat"
tar -cf "$FAKE_STATE/docker.run.tar" -C "$SB/servers/fl3" data     # the helper's answer for export: data/ with the world
reset
run export fl3 "$SB/fl3.tgz"; assert_eq 0 "$RC" "export fl3"
rm -f -- "$FAKE_STATE/docker.run.tar"
assert_eq "data/ data/world/ data/world/level.dat lists/ lists/mods.list mcctl-export mods/ mods/x.jar plugins/ server.env" \
    "$(tar -tzf "$SB/fl3.tgz" | sort | paste -sd' ' -)" "the archive: marker, server.env, lists/, mods/, data/ (no secret, no backups, no compose.yaml)"
reset
run --yes delete fl3; assert_eq 0 "$RC" "delete fl3 (its data goes to trash/)"
fake_gone fl3 fl3h
assert_eq "" "$(dns_records | grep -E '^fl3h\.' || true)" "its DNS record is gone"
reset
rm -f -- "$FAKE_STATE"/run.stdin.*                    # the import's helper stdin is the first one of this flow
run import "$SB/fl3.tgz" fl4 --hostname fl4h; assert_eq 0 "$RC" "import fl3.tgz as fl4 (hostname fl4h)"
assert_eq "$(grep -v '^HOSTNAME_SLUG=' "$SB/fl3-env-before")" "$(grep -v '^HOSTNAME_SLUG=' "$SB/servers/fl4/server.env")" "round trip: server.env is the same but the hostname"
assert_eq "mod-x" "$(<"$SB/servers/fl4/lists/mods.list")" "round trip: lists/ is the same"
assert_eq "PK jar" "$(<"$SB/servers/fl4/mods/x.jar")" "round trip: mods/ is the same"
assert_eq "level" "$(tar -xzOf "$SB/fl3.tgz" data/world/level.dat)" "round trip: the world is in the archive; the import streams it to the helper"
assert_eq "docker run --rm -i --network none --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp --pids-limit 64 --memory 128m -v $SB/servers/fl4/data:/data -w /data alpine:3.20 tar -xzf - --no-same-owner --strip-components=1 -C /data data" \
    "$(calls | grep 'tar -xzf -')" "one helper, stdin is the archive, data/ only"
if cmp -s "$SB/fl3.tgz" "$FAKE_STATE/run.stdin.1"; then pass "the stdin is the archive itself"; else fail "the stdin is the archive itself"; fi
assert_eq "fl4h.mc.example.net mcctl name=fl4" "$(dns_records | grep -E '^fl4h\.')" "the DNS record of fl4h exists"
assert_eq "" "$(leftovers | grep -E 'fl[23]' || true)" "nothing of fl2 or fl3 is left under servers/ or secrets/"
assert_not_contains "$ALL$(calls)" "$fl_pw" "E4: the RCON password of fl1 is in no output and no call"
assert_not_contains "$ALL$(calls)" "$CF_TOKEN" "E4: the Cloudflare token is in no output and no call"
rm -f -- "$FAKE_STATE/docker.stateful" "$FAKE_STATE/docker.inspect" "$FAKE_STATE/docker.run.tar"

sandbox_cleanup
finish

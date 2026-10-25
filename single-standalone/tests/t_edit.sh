#!/usr/bin/env bash
# lib/servers.sh: cmd_edit (resource limits). The 14 cases of spec section 5.
# E1: the ordered call log. E4: the RCON password never reaches output or the call log.
# E7: a failing recreate (FAIL_AT). E12: file modes after a successful edit. Case 15: a failing server.env write (FAIL_MV, fakebin/mv).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/modpack.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/rcon.sh"
source "$REPO/lib/router.sh"
source "$REPO/lib/cloudflare.sh"
source "$REPO/lib/sftp.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
fake_cloudflare

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
# mk NAME [STATE]: set up a server directly (without m create, which hangs on Git Bash cf_api printf|curl),
# make Docker report it exists in STATE (default created), clear the call log
mk() {
    local n=$1 st=${2:-created}
    mkdir -p "$SB/servers/$n/data" "$SB/servers/$n/backups" "$SB/secrets"
    printf '# Written by mcctl create. mcctl reads this file; it never runs it.\nTYPE=PAPER\nVERSION=LATEST\nMEMORY=4G\nCPUS=2\nHOSTNAME_SLUG=%s\nEULA=TRUE\n' "$n" >"$SB/servers/$n/server.env"
    chmod 600 "$SB/servers/$n/server.env"
    write_compose "$n"
    chmod 600 "$SB/servers/$n/compose.yaml"
    printf 'test-rcon-pass-%s\n' "$n" >"$SB/secrets/rcon-$n"
    chmod 600 "$SB/secrets/rcon-$n"
    fake_server "$n" "$n" "$st"
    printf '%s\n' "$st" >"$FAKE_STATE/docker.inspect"
    reset
}
# clean NAME: remove the server folder, secret and fake docker state for NAME
clean() {
    local n=$1
    rm -rf -- "$SB/servers/$n"
    rm -f -- "$SB/secrets/rcon-$n"
    rm -f -- "$FAKE_STATE"/docker.ps.label_mcctl_name_$n "$FAKE_STATE"/docker.ps.label_mcctl_hostname_$n
    rm -f -- "$FAKE_STATE"/docker.inspect "$FAKE_STATE"/docker.exec "$FAKE_STATE"/docker.exec.rc
    reset
}
ASKS="docker ps -a -q --filter label=mcctl.name=s1
docker inspect --format {{.State.Status}} mc-s1"

echo "1. Usage"
reset
m edit;                    assert_eq 2 "$RC" "edit alone: EX_USAGE"
m edit s1;                 assert_eq 2 "$RC" "edit s1 (no option): EX_USAGE"
m edit s1 --memory;        assert_eq 2 "$RC" "edit s1 --memory (no value): EX_USAGE"
m edit s1 --bogus 1;       assert_eq 2 "$RC" "edit s1 --bogus 1: EX_USAGE"
m edit Bad --memory 2G;    assert_eq 2 "$RC" "edit Bad --memory 2G: EX_USAGE"
m edit nope --memory 2G;   assert_eq 1 "$RC" "edit nope --memory 2G: EX_FAIL (unknown server)"
assert_contains "$OUT" "no server named" "and says 'no server named'"

echo "2. Validation"
mk s1
env_before=$(cksum "$SB/servers/s1/server.env"); cmp_before=$(cksum "$SB/servers/s1/compose.yaml")
m edit s1 --memory '6 gigs'; assert_eq 2 "$RC" "--memory '6 gigs': EX_USAGE"; assert_contains "$OUT" "MEMORY" "names MEMORY"
m edit s1 --memory 0G;       assert_eq 2 "$RC" "--memory 0G: EX_USAGE"; assert_contains "$OUT" "MEMORY" "names MEMORY"
m edit s1 --cpus 0;          assert_eq 2 "$RC" "--cpus 0: EX_USAGE"; assert_contains "$OUT" "CPUS" "names CPUS"
m edit s1 --cpus abc;        assert_eq 2 "$RC" "--cpus abc: EX_USAGE"; assert_contains "$OUT" "CPUS" "names CPUS"
assert_eq "$env_before" "$(cksum "$SB/servers/s1/server.env")" "server.env byte-identical after validation failures"
assert_eq "$cmp_before" "$(cksum "$SB/servers/s1/compose.yaml")" "compose.yaml byte-identical after validation failures"
assert_eq 0 "$(count_calls '^docker compose')" "no docker compose call during validation failures"
clean s1
mk s1
m edit s1 --memory 6G --cpus 1.5; assert_eq 0 "$RC" "--memory 6G --cpus 1.5 together is valid"
clean s1

echo "3. Stopped server"
mk s1 exited
env_before=$(cksum "$SB/servers/s1/server.env")
m edit s1 --memory 6G
assert_eq 0 "$RC" "edit on a stopped server (no --yes, no terminal): exit 0"
assert_contains "$(<"$SB/servers/s1/server.env")" "MEMORY=6G" "server.env has MEMORY=6G"
assert_contains "$(<"$SB/servers/s1/server.env")" "# Written by mcctl create" "the comment line is unchanged"
assert_ne() { if [[ $1 != "$2" ]]; then pass "$3"; else fail "$3" "both are '$1'"; fi; }
assert_ne "$env_before" "$(cksum "$SB/servers/s1/server.env")" "server.env changed (sanity: cksum differs from before)"
assert_contains "$(<"$SB/servers/s1/compose.yaml")" 'MEMORY: "6G"' "compose.yaml has MEMORY: \"6G\""
assert_contains "$(<"$SB/servers/s1/compose.yaml")" 'mem_limit: "7936m"' "compose.yaml has mem_limit: \"7936m\""
assert_eq "$ASKS
docker compose -p mcctl-s1 -f $SB/servers/s1/compose.yaml create --force-recreate" "$(calls)" "calls: name check, inspect, compose create --force-recreate; no up, no start, no exec"
clean s1

echo "4. Running, 0 players, no --yes"
mk s1 running
printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
env_before=$(cksum "$SB/servers/s1/server.env"); cmp_before=$(cksum "$SB/servers/s1/compose.yaml")
m edit s1 --memory 6G
assert_eq 4 "$RC" "0 players, no --yes, no terminal: EX_REFUSED"
assert_contains "$OUT" "confirmation" "message contains 'confirmation'"
assert_eq "$env_before" "$(cksum "$SB/servers/s1/server.env")" "server.env byte-identical"
assert_eq "$cmp_before" "$(cksum "$SB/servers/s1/compose.yaml")" "compose.yaml byte-identical"
assert_eq 0 "$(count_calls '^docker compose')" "no compose call"
reset
m --yes edit s1 --memory 6G
assert_eq 0 "$RC" "0 players with --yes: exit 0"
assert_eq "$ASKS
docker exec -i mc-s1 rcon-cli list
docker compose -p mcctl-s1 -f $SB/servers/s1/compose.yaml up -d --force-recreate
$(reload_call)" "$(calls)" "calls: name, inspect, exec list, compose up -d --force-recreate (no service name), reload"
clean s1

echo "5. Running, 2 players"
mk s1 running
printf 'There are 2 of a max of 20 players online: a, b\n' >"$FAKE_STATE/docker.exec"
env_before=$(cksum "$SB/servers/s1/server.env"); cmp_before=$(cksum "$SB/servers/s1/compose.yaml")
m edit s1 --memory 6G
assert_eq 4 "$RC" "2 players, no --yes: EX_REFUSED"
assert_contains "$OUT" "2 players online" "message contains '2 players online'"
assert_contains "$OUT" "--yes" "message contains '--yes'"
assert_eq "$env_before" "$(cksum "$SB/servers/s1/server.env")" "server.env unchanged"
assert_eq "$cmp_before" "$(cksum "$SB/servers/s1/compose.yaml")" "compose.yaml unchanged"
reset
m --yes edit s1 --memory 6G
assert_eq 0 "$RC" "2 players with --yes: exit 0"
assert_contains "$(<"$SB/servers/s1/server.env")" "MEMORY=6G" "server.env has the new value"
clean s1

echo "6. RCON unknown"
mk s1 running
echo 1 >"$FAKE_STATE/docker.exec.rc"
m edit s1 --memory 6G
assert_eq 4 "$RC" "RCON fails (rc=1), no --yes: EX_REFUSED"
assert_contains "$OUT" "who is online" "message contains 'who is online'"
rm -f "$FAKE_STATE/docker.exec.rc"
reset
m --yes edit s1 --memory 6G
assert_eq 0 "$RC" "RCON fails with --yes: proceeds"
clean s1
mk s1 running
printf 'Unknown command\n' >"$FAKE_STATE/docker.exec"
m edit s1 --memory 6G
assert_eq 4 "$RC" "unparseable reply, no --yes: EX_REFUSED"
assert_contains "$OUT" "who is online" "message contains 'who is online'"
reset
m --yes edit s1 --memory 6G
assert_eq 0 "$RC" "unparseable reply with --yes: proceeds"
clean s1

echo "7. Preservation"
mk s1 exited
printf '# a comment\nTYPE=PAPER\nEULA=TRUE\nMOTD=Hello World\n' >"$SB/servers/s1/server.env"
m edit s1 --memory 3G
assert_eq 0 "$RC" "edit --memory 3G on a server with no MEMORY= line"
env=$(<"$SB/servers/s1/server.env")
assert_contains "$env" "MEMORY=3G" "MEMORY=3G is appended"
assert_contains "$env" "# a comment" "the comment is unchanged"
assert_contains "$env" "MOTD=Hello World" "the unrelated key is unchanged"
assert_eq 1 "$(grep -c '^MEMORY=' <<<"$env")" "MEMORY= appears exactly once"
clean s1
mk s1 exited
printf 'TYPE=PAPER\nCPUS=2\nEULA=TRUE\n' >"$SB/servers/s1/server.env"
m edit s1 --cpus 1
assert_eq 0 "$RC" "edit --cpus 1 replaces CPUS=2 in place"
env=$(<"$SB/servers/s1/server.env")
assert_eq "TYPE=PAPER
CPUS=1
EULA=TRUE" "$env" "CPUS=2 is replaced by CPUS=1, everything else unchanged"
clean s1

echo "8. Render failure rolls back"
mk s1 exited
env_before=$(cksum "$SB/servers/s1/server.env"); cmp_before=$(cksum "$SB/servers/s1/compose.yaml")
printf 'API_TOKEN=x\n' >"$SB/servers/s1/modpack.env"
m --yes edit s1 --memory 6G
assert_ne 0 "$RC" "render failure: non-zero exit"
assert_eq "$env_before" "$(cksum "$SB/servers/s1/server.env")" "server.env byte-identical to before"
assert_eq "$cmp_before" "$(cksum "$SB/servers/s1/compose.yaml")" "compose.yaml byte-identical to before"
assert_eq 0 "$(count_calls '^docker compose')" "no docker compose call"
assert_eq 0 "$(find "$SB/servers/s1" -name '*.tmp' | wc -l)" "no .tmp file left"
clean s1

echo "8b. Render failure, and the undo write fails too (FAIL_MV on the second move onto server.env)"
mk s1 exited
sf=$SB/servers/s1/server.env
cmp_before=$(cksum "$SB/servers/s1/compose.yaml")
printf 'API_TOKEN=x\n' >"$SB/servers/s1/modpack.env"
rm -f "$FAKE_STATE/mv.count"
FAIL_MV=$sf FAIL_MV_NTH=2 m --yes edit s1 --memory 6G
assert_eq 1 "$RC" "render failure, undo write fails: EX_FAIL"
assert_contains "$OUT" "could not be put back" "message says server.env could not be put back"
assert_contains "$OUT" "by hand" "message says to check it by hand"
assert_not_contains "$OUT" "put back as it was" "and does not claim it was put back"
assert_contains "$(<"$sf")" "MEMORY=6G" "server.env holds the new value (the MEMORY write got through, the undo did not)"
assert_eq "$cmp_before" "$(cksum "$SB/servers/s1/compose.yaml")" "compose.yaml byte-identical to before"
assert_eq 0 "$(count_calls '^docker compose')" "no docker compose call"
assert_eq 2 "$(<"$FAKE_STATE/mv.count")" "two moves onto server.env: the MEMORY write, then the undo that failed"
assert_eq 0 "$(find "$SB/servers/s1" -name '*.tmp' | wc -l)" "no .tmp file left"
clean s1
mk s1 exited
printf 'API_TOKEN=x\n' >"$SB/servers/s1/modpack.env"
m --yes edit s1 --memory 6G
assert_eq 1 "$RC" "render failure, undo write succeeds: EX_FAIL"
assert_contains "$OUT" "server.env was put back as it was" "message says server.env was put back (the undo succeeded)"
assert_not_contains "$OUT" "by hand" "and does not ask for a check by hand"
clean s1

echo "9. Recreate failure (E7)"
mk s1 running
printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
FAIL_AT=1 m --yes edit s1 --memory 6G
assert_eq 1 "$RC" "FAIL_AT=1 on a running server: EX_FAIL"
assert_contains "$OUT" "files are already written" "message says the files are written"
assert_contains "$(<"$SB/servers/s1/server.env")" "MEMORY=6G" "server.env has the new value"
reset
m --yes edit s1 --memory 6G
assert_eq 0 "$RC" "second run without FAIL_AT: exit 0"
clean s1

echo "10. Missing server.env"
mk s1 exited
rm -f "$SB/servers/s1/server.env"
m edit s1 --memory 6G
assert_eq 1 "$RC" "missing server.env: EX_FAIL"
assert_contains "$OUT" "server.env" "message names the file"
assert_eq 0 "$(count_calls '^docker compose')" "no compose call"
clean s1

echo "11. Secret canary (E4)"
mk s1 running
plant_canary "$SB/secrets/rcon-s1"
printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
reset
m --yes edit s1 --memory 6G
assert_eq 0 "$RC" "edit with --yes succeeds"
assert_not_contains "$OUT$(calls)" "$CANARY" "the RCON password is in neither output nor the call log (E4)"
assert_eq 1 "$(count_calls '^docker exec -i mc-s1 rcon-cli list$')" "the list call is exactly 'docker exec -i mc-s1 rcon-cli list'"
clean s1

echo "12. Modes (E12)"
mk s1 exited
m edit s1 --memory 6G
assert_eq 0 "$RC" "edit succeeds"
assert_mode "$SB/servers/s1/server.env" 600 "server.env is mode 600"
assert_mode "$SB/servers/s1/compose.yaml" 600 "compose.yaml is mode 600"
clean s1

echo "13. Help and E3"
m help
assert_contains "$OUT" "edit" "help lists edit"
assert_eq "cmd_edit" "cmd_edit" "cmd_edit is named (E3)"

echo "14. Flow (E13) is in t_flows.sh"

echo "15. A failing server.env write puts the file back (FAIL_MV, FAIL_MV_NTH of fakebin/mv)"
# NTH=1: the MEMORY write fails. NTH=2: MEMORY is written, then the CPUS write fails. The undo is one more move onto server.env and
# goes through, so mv.count (the moves onto server.env seen) is NTH+1: that also proves the hook fired where the case says it did.
what=(x "the MEMORY write" "the CPUS write after MEMORY was written")
for nth in 1 2; do
    mk s1 exited
    sf=$SB/servers/s1/server.env
    env_before=$(cksum "$sf"); cmp_before=$(cksum "$SB/servers/s1/compose.yaml")
    rm -f "$FAKE_STATE/mv.count"
    FAIL_MV=$sf FAIL_MV_NTH=$nth m edit s1 --memory 6G --cpus 1
    assert_eq 1 "$RC" "${what[nth]} fails: EX_FAIL"
    assert_contains "$OUT" "cannot write $sf; server.env was put back as it was" "message names the file and says it was put back"
    assert_eq "$((nth + 1))" "$(<"$FAKE_STATE/mv.count")" "the moves onto server.env: those up to the failed one, then the undo, nothing after"
    assert_eq "$env_before" "$(cksum "$sf")" "server.env byte-identical to before"
    assert_eq "$cmp_before" "$(cksum "$SB/servers/s1/compose.yaml")" "compose.yaml byte-identical to before"
    assert_eq 0 "$(count_calls '^docker compose')" "no docker compose call"
    assert_eq 0 "$(find "$SB/servers/s1" -name '*.tmp' | wc -l)" "no .tmp file left"
    clean s1
done
mk s1 exited
sf=$SB/servers/s1/server.env
env_before=$(cksum "$sf"); cmp_before=$(cksum "$SB/servers/s1/compose.yaml")
rm -f "$FAKE_STATE/mv.count"
FAIL_MV=$sf m edit s1 --memory 6G
assert_eq 1 "$RC" "every write of server.env fails, the undo too: EX_FAIL"
assert_contains "$OUT" "cannot write $sf, and it could not be put back as it was" "message says the undo failed"
assert_not_contains "$OUT" "server.env was put back as it was" "and does not claim the file was put back"
assert_eq "$env_before" "$(cksum "$sf")" "server.env is still as it was (the first write never got through)"
assert_eq "$cmp_before" "$(cksum "$SB/servers/s1/compose.yaml")" "compose.yaml byte-identical to before"
assert_eq 0 "$(count_calls '^docker compose')" "no docker compose call"
clean s1

sandbox_cleanup
finish

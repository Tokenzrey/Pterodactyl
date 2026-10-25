#!/usr/bin/env bash
# E7: failure injection. FAIL_AT=n makes the n-th mutating call of one mcctl run fail: docker compose create/up/rm/stop/kill, the
# restore's extraction (docker run; a run is mutating unless its command only reads, see fakebin/docker), and the Cloudflare
# POST/DELETE (fakebin/curl), counted together in $FAKE_STATE/mutations. Each fails the worse way: a compose create or up has made
# its containers first, a rm, stop, kill or run changed nothing, a POST was applied and only its answer lost, a DELETE was not
# applied. The docker fake keeps container state here (docker.stateful), so a re-run sees what the
# failed run left. For every mutating command below and every n from 1 to its call count:
#   - the exit is EX_FAIL or EX_REFUSED;
#   - no container without its folder and no folder without its container; the RCON secret goes with the folder;
#   - no DNS record points at nothing: there is never a record (the fake Cloudflare's state) without the server's container, and
#     never more than one. A container may lose its record first (delete removes the record before the containers);
#   - when the failing call is a DNS call of delete, nothing has been removed: the containers, the folder, the secret and the
#     record are all still there;
#   - the world is never lost: it is in servers/NAME/data or in a trash/ archive that reads back (a restore keeps it in data/ or
#     in data.pre-restore-<ts>);
#   - a re-run without FAIL_AT completes and leaves the state a run without failure leaves.
# E4: the API token and the RCON password are in no output and not in the call log. Later tasks add their commands here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
fake_cloudflare
: >"$FAKE_STATE/docker.stateful"

N=s1 HOST=play
CREATE=(create "$N" --type PAPER --accept-eula --hostname "$HOST")
ALL="" PWS=()   # every output, and every RCON password made, searched at the end (E4)
run() {
    m "$@"; ALL+=$OUT$'\n'
    [[ -f $SB/secrets/rcon-$N ]] && PWS+=("$(<"$SB/secrets/rcon-$N")")
}
truncate_log() { cat "$FAKE_STATE/calls.log" >>"$SB/all-calls.log" 2>/dev/null; : >"$FAKE_STATE/calls.log"; T_UNK=0; }
# world: what exists of the server, in WC (container) WF (folder) WS (secret) WD (DNS records of it)
world() {
    WC=0 WF=0 WS=0
    [[ -s $FAKE_STATE/docker.ps.label_mcctl_name_$N ]] && WC=1
    [[ -e $SB/servers/$N ]] && WF=1
    [[ -e $SB/secrets/rcon-$N ]] && WS=1
    WD=$(dns_records ".[] | select(.comment == \"mcctl name=$N\") | .name" | grep -c .)
}
# clean: nothing of the server exists; the trash, the call log and the mutation count start empty
clean() {
    rm -rf -- "$SB/servers/$N" "$SB/trash"
    rm -f -- "$SB/secrets/rcon-$N" "$FAKE_STATE"/docker.ps.label_mcctl_* "$FAKE_STATE/curl.records.json" "$FAKE_STATE/mutations"
    truncate_log
}
# created: the server exists (container, folder, secret, DNS record) and has a world
created() {
    clean
    run "${CREATE[@]}"
    mkdir -p "$SB/servers/$N/data/world" && echo level >"$SB/servers/$N/data/world/level.dat"
    rm -f -- "$FAKE_STATE/mutations"; truncate_log
}
# nth_mutation N: the N-th mutating call in the call log
nth_mutation() {
    calls | grep -E "^docker compose -p [^ ]+ -f [^ ]+ (create|up|rm|stop|kill)( |\$)|^docker run |^curl .* -X (POST|DELETE) " |
        grep -vE "^docker run .* alpine:3[.]20 (ls|cat|stat|test|readlink|find|du|wc|head)( |\$)" | sed -n "${1}p"
}
# world_kept: the world is in the folder, or in an archive in trash/ that reads back
world_kept() {
    local a
    [[ -f $SB/servers/$N/data/world/level.dat ]] && return 0
    for a in "$SB"/trash/"$N"-*.tar.gz; do
        [[ -f $a ]] && [[ $(tar -xzOf "$a" data/world/level.dat 2>/dev/null) == level ]] && return 0
    done
    return 1
}
# after_failure LABEL: the invariants after a run that FAIL_AT broke
after_failure() {
    local l=$1 call
    call=$(nth_mutation "$FAIL_AT_N")
    [[ $RC == 1 || $RC == 4 ]] && pass "$l: exit $RC (EX_FAIL or EX_REFUSED)" || fail "$l: exit is EX_FAIL or EX_REFUSED" "rc=$RC $OUT"
    [[ -n $call ]] && pass "$l: the injected failure hit: ${call%% https*}" || fail "$l: the injected failure hit a call" "$(calls)"
    world
    if [[ $l == delete* && $call == *"rm -rf -- /m/data"* ]]; then
        # the last steps of delete: the containers are gone, then the helper could not clear data/. What is left is the folder, its
        # secret and the archive (which holds the world); the next delete removes the folder
        assert_eq "0 1 1" "$WC $WF $WS" "$l: the containers are gone; the folder, the secret and the archive are left, and the next delete finishes"
    else
        assert_eq "$WC" "$WF" "$l: no container without its folder, no folder without its container"
        assert_eq "$WF" "$WS" "$l: the RCON secret goes with the folder"
    fi
    ((WD <= WC)) && pass "$l: no DNS record points at nothing (records $WD, containers $WC)" \
        || fail "$l: no DNS record without its container" "records $WD, containers $WC"
    if [[ $l == delete* && $call == curl* ]]; then
        assert_eq "1 1 1 1" "$WC $WF $WS $WD" "$l: the DNS call failed, so the containers, the folder, the secret and the record are all in place"
        assert_contains "$OUT" "could not delete the DNS record $HOST.$MCCTL_DOMAIN" "$l: and the output names the record"
    fi
}

echo "create"
clean
FAIL_AT=0 run "${CREATE[@]}"
assert_eq 0 "$RC" "create, counting its mutating calls"
total=$(<"$FAKE_STATE/mutations")
assert_eq 5 "$total" "create makes 5 mutating calls (DNS POST, the chown of data/ and of backups/, the chown of the RCON secret, compose create)"
for ((FAIL_AT_N = 1; FAIL_AT_N <= total; FAIL_AT_N++)); do
    clean
    FAIL_AT=$FAIL_AT_N run "${CREATE[@]}"
    after_failure "create, FAIL_AT=$FAIL_AT_N"
    world
    assert_eq "0 0 0 0" "$WC $WF $WS $WD" "create, FAIL_AT=$FAIL_AT_N: nothing is left (a failed create takes everything back)"
    rm -f -- "$FAKE_STATE/mutations"
    run "${CREATE[@]}"
    world
    assert_eq "0 1 1 1 1" "$RC $WC $WF $WS $WD" "create, FAIL_AT=$FAIL_AT_N: the re-run completes (container, folder, secret, record)"
done

echo "delete"
created
FAIL_AT=0 run --yes delete "$N"
assert_eq 0 "$RC" "delete, counting its mutating calls"
total=$(<"$FAKE_STATE/mutations")
assert_eq 5 "$total" "delete makes 5 mutating calls (stop, the archive, the DNS DELETE, compose rm, the helper's rm of data/)"
assert_eq "stop tar DELETE rm rm" "$(for i in 1 2 3 4 5; do nth_mutation "$i" | grep -oE ' (stop|tar|rm|kill)( |$)|-X DELETE' | head -n 1 | tr -d ' ' | sed 's/^-XDELETE$/DELETE/'; done | paste -sd ' ' -)" \
    "in this order: compose stop, the archive, the DNS DELETE (before the containers), compose rm, then the helper's rm of data/"
for ((FAIL_AT_N = 1; FAIL_AT_N <= total; FAIL_AT_N++)); do
    created
    FAIL_AT=$FAIL_AT_N run --yes delete "$N"
    after_failure "delete, FAIL_AT=$FAIL_AT_N"
    world_kept && pass "delete, FAIL_AT=$FAIL_AT_N: the world is in the folder or in a trash/ archive that reads back" \
        || fail "delete, FAIL_AT=$FAIL_AT_N: the world is kept" "$(ls -R "$SB/servers" "$SB/trash" 2>&1)"
    rm -f -- "$FAKE_STATE/mutations"
    run --yes delete "$N"
    world
    assert_eq "0 0 0 0" "$WC $WF $WS $WD" "delete, FAIL_AT=$FAIL_AT_N: after the re-run nothing of $N is left"
    if [[ $RC == 0 ]]; then
        pass "delete, FAIL_AT=$FAIL_AT_N: the re-run exits 0"
    elif [[ $RC == 1 && $OUT == *"no server named '$N'"* ]]; then
        pass "delete, FAIL_AT=$FAIL_AT_N: the failed run had already removed everything; the re-run says there is nothing left (exit 1)"
    else
        fail "delete, FAIL_AT=$FAIL_AT_N: the re-run completes" "rc=$RC $OUT"
    fi
    world_kept && pass "delete, FAIL_AT=$FAIL_AT_N: and the world is in trash/" || fail "delete, FAIL_AT=$FAIL_AT_N: the world is in trash/"
done

echo "counting: a read-only docker run (ls, cat, ...) takes no FAIL_AT slot; the extraction (tar) does"
clean
for c in ls cat stat test readlink find du wc head; do
    echo 1 >"$FAKE_STATE/docker.run.$c.rc"
    out=$(FAIL_AT=1 docker run --rm alpine:3.20 "$c" 2>&1); rc=$?
    assert_eq 1 "$rc" "docker run $c, failed by its replay: exit 1"
    assert_not_contains "$out" "injected" "and not by FAIL_AT"
    rm -f -- "$FAKE_STATE/docker.run.$c.rc"
done
assert_no_file "$FAKE_STATE/mutations" "none of the nine read-only runs took a FAIL_AT slot"
out=$(FAIL_AT=1 docker run --rm alpine:3.20 tar -xzf - 2>&1 </dev/null); rc=$?
assert_eq 1 "$rc" "docker run tar (the extraction), FAIL_AT=1: exit 1"
assert_contains "$out" "injected failure (FAIL_AT=1)" "and it is the injected failure"
assert_eq 1 "$(<"$FAKE_STATE/mutations")" "it took the first slot"

echo "restore: the chown of data/ and the extraction are the docker runs that change something"
FX=$REPO/tests/fixtures/archives
# restore_setup: server s1 with its world ("level") and clean.tar.gz in backups/; the call log and the counter start empty
restore_setup() { created; mkdir -p "$SB/servers/$N/backups" && cp -- "$FX/clean.tar.gz" "$SB/servers/$N/backups/"; }
# restore_kept: the world is in data/, or in data.pre-restore-* or data.failed-restore-* (a restore moves it, never removes it)
restore_kept() {
    local d
    for d in "$SB/servers/$N/data" "$SB/servers/$N"/data.pre-restore-* "$SB/servers/$N"/data.failed-restore-*; do
        [[ $(cat -- "$d/world/level.dat" 2>/dev/null) == level ]] && return 0
    done
    return 1
}
restore_setup
FAIL_AT=0 MCCTL_YES=1 run backup "$N" restore clean.tar.gz
assert_eq 0 "$RC" "restore, counting its mutating calls"
total=$(<"$FAKE_STATE/mutations")
assert_eq 2 "$total" "restore makes 2 mutating calls (the chown of data/, the extraction)"
for ((FAIL_AT_N = 1; FAIL_AT_N <= total; FAIL_AT_N++)); do
    restore_setup
    FAIL_AT=$FAIL_AT_N MCCTL_YES=1 run backup "$N" restore clean.tar.gz
    after_failure "restore, FAIL_AT=$FAIL_AT_N"
    assert_eq level "$(cat -- "$SB/servers/$N/data/world/level.dat" 2>/dev/null)" "restore, FAIL_AT=$FAIL_AT_N: the previous data is back in data/"
    assert_eq "" "$(compgen -G "$SB/servers/$N/data.failed-restore-*")" "restore, FAIL_AT=$FAIL_AT_N: nothing was extracted, so no data.failed-restore-* is left"
    assert_not_contains "$OUT" "what was extracted" "restore, FAIL_AT=$FAIL_AT_N: the message does not say what was extracted"
    restore_kept && pass "restore, FAIL_AT=$FAIL_AT_N: the world is kept" \
        || fail "restore, FAIL_AT=$FAIL_AT_N: the world is kept" "$(ls -R "$SB/servers/$N" 2>&1)"
    rm -f -- "$FAKE_STATE/mutations"
    MCCTL_YES=1 run backup "$N" restore clean.tar.gz
    assert_eq 0 "$RC" "restore, FAIL_AT=$FAIL_AT_N: the re-run completes"
    restore_kept && pass "restore, FAIL_AT=$FAIL_AT_N: and after the re-run the world is kept" \
        || fail "restore, FAIL_AT=$FAIL_AT_N: after the re-run the world is kept" "$(ls -R "$SB/servers/$N" 2>&1)"
done

echo "clone, rename and import (Task 21, E7): whatever call fails, exactly one of the two servers is complete (never neither, never both)"
# nt_world NAME HOST: 0 when NAME is complete here: its container, its folder (with the world unless NT_WORLD=0: a clone without
# --with-data and an import of an archive without data have none), its RCON secret, and one DNS record of HOST.MCCTL_DOMAIN that
# carries its comment
nt_world() {
    local n=$1 h=$2 d
    [[ -s $FAKE_STATE/docker.ps.label_mcctl_name_$n ]] || return 1
    [[ -f $SB/servers/$n/compose.yaml ]] || return 1
    grep -q -x "HOSTNAME_SLUG=$h" "$SB/servers/$n/server.env" 2>/dev/null || return 1
    grep -q "container_name: \"mc-$n\"" "$SB/servers/$n/compose.yaml" || return 1
    [[ ${NT_WORLD:-1} == 0 || -f $SB/servers/$n/data/world/level.dat ]] || return 1
    [[ -f $SB/secrets/rcon-$n ]] || return 1
    grep -q "^$n::1000:1000:$n\$" "$SB/sftp-users.conf" 2>/dev/null || return 1
    d=$(dns_records ".[] | select(.comment == \"mcctl name=$n\") | .name" | grep -c -x "$h.$MCCTL_DOMAIN")
    [[ $d == 1 ]]
}
# nt_none NAME HOST: 0 when nothing of NAME is left: no container, folder, secret, SFTP user, and no DNS record of the host or of the name
nt_none() {
    local n=$1 h=$2
    [[ ! -e $FAKE_STATE/docker.ps.label_mcctl_name_$n && ! -e $SB/servers/$n && ! -e $SB/secrets/rcon-$n ]] || return 1
    ! grep -q "^$n::" "$SB/sftp-users.conf" 2>/dev/null || return 1
    [[ -z $(dns_records ".[] | select(.name == \"$h.$MCCTL_DOMAIN\" or .comment == \"mcctl name=$n\") | .name") ]]
}
# nt_outcome NAME-OLD HOST-OLD NAME-NEW HOST-NEW: exactly one of the two is complete
nt_one() { local o=0 n=0; nt_world "$1" "$2" && o=1; nt_world "$3" "$4" && n=1; ((o + n == 1)); }

# clone: NEW is made from s1 (created above); a failure takes NEW back, s1 stays complete
created; echo exited >"$FAKE_STATE/docker.inspect"
FAIL_AT=0 run clone s1 c1; assert_eq 0 "$RC" "clone, counting its mutating calls"
total=$(<"$FAKE_STATE/mutations")
assert_eq 5 "$total" "clone makes 5 mutating calls (DNS POST, the chown of data/ and of backups/, the chown of the RCON secret, compose create)"
run --yes delete c1 >/dev/null
for ((FAIL_AT_N = 1; FAIL_AT_N <= total; FAIL_AT_N++)); do
    rm -f -- "$FAKE_STATE/mutations"; truncate_log
    FAIL_AT=$FAIL_AT_N run clone s1 c1
    [[ $RC == 1 || $RC == 4 ]] && pass "clone, FAIL_AT=$FAIL_AT_N: exit $RC" || fail "clone, FAIL_AT=$FAIL_AT_N: exit is EX_FAIL or EX_REFUSED" "rc=$RC $OUT"
    [[ -n $(nth_mutation "$FAIL_AT_N") ]] && pass "clone, FAIL_AT=$FAIL_AT_N: the injected failure hit a call" || fail "clone, FAIL_AT=$FAIL_AT_N: the injected failure hit a call"
    nt_none c1 c1 && pass "clone, FAIL_AT=$FAIL_AT_N: nothing of c1 is left (container, folder, secret, DNS record)" \
        || fail "clone, FAIL_AT=$FAIL_AT_N: nothing of c1 is left" "$(ls -R "$SB/servers" 2>&1 | head -n 5) $(dns_records | grep c1)"
    nt_world s1 play && pass "clone, FAIL_AT=$FAIL_AT_N: the source is complete" || fail "clone, FAIL_AT=$FAIL_AT_N: the source is complete"
    rm -f -- "$FAKE_STATE/mutations"
    run clone s1 c1
    assert_eq 0 "$RC" "clone, FAIL_AT=$FAIL_AT_N: the re-run completes"
    NT_WORLD=0 nt_world c1 c1 && pass "clone, FAIL_AT=$FAIL_AT_N: and c1 is complete after it" || fail "clone, FAIL_AT=$FAIL_AT_N: c1 is complete after the re-run"
    run --yes delete c1 >/dev/null; fake_gone c1 c1
done

# rename: NAME s1 becomes s2 (another hostname: the new record is made, and the old one deleted at the end). Three variants: stopped; running
# (stopped and started again); stopped with the SFTP container up (each SFTP change recreates it, a mutating call). Whatever fails, exactly
# one of s1 and s2 is complete, and the same rename run again completes.
for variant in exited running exited-sftp; do
    state=${variant%%-*}
    rm -f -- "$SB/sftp-users.conf"; created; echo "$state" >"$FAKE_STATE/docker.inspect"
    [[ $variant != *sftp ]] || echo cid >"$FAKE_STATE/docker.compose.ps"   # the SFTP container runs
    rm -rf -- "$SB/servers/s2" "$SB/secrets/rcon-s2"
    FAIL_AT=0 run --yes rename s1 s2; assert_eq 0 "$RC" "rename ($variant), counting its mutating calls"
    total=$(<"$FAKE_STATE/mutations")
    want=4; [[ $state == running ]] && want=5; [[ $variant == *sftp ]] && want=$((want + 2))
    assert_eq "$want" "$total" "rename ($variant) makes $want mutating calls (DNS POST, [stop,] compose rm, compose create, DNS DELETE[, two SFTP recreates])"
    for ((FAIL_AT_N = 1; FAIL_AT_N <= total; FAIL_AT_N++)); do
        rm -f -- "$SB/sftp-users.conf"; created; echo "$state" >"$FAKE_STATE/docker.inspect"; rm -rf -- "$SB/servers/s2" "$SB/secrets/rcon-s2"
        rm -f -- "$FAKE_STATE/docker.compose.ps"; [[ $variant != *sftp ]] || echo cid >"$FAKE_STATE/docker.compose.ps"
        rm -f -- "$FAKE_STATE/mutations"; truncate_log
        FAIL_AT=$FAIL_AT_N run --yes rename s1 s2
        [[ $RC == 0 || $RC == 1 ]] && pass "rename ($variant), FAIL_AT=$FAIL_AT_N: exit $RC" || fail "rename ($variant), FAIL_AT=$FAIL_AT_N: exit 0 or 1" "rc=$RC $OUT"
        nt_one s1 play s2 s2 && pass "rename ($variant), FAIL_AT=$FAIL_AT_N: exactly one of s1, s2 is complete (never neither, never both)" \
            || fail "rename ($variant), FAIL_AT=$FAIL_AT_N: exactly one of s1, s2 is complete" "$(ls -R "$SB/servers" 2>&1 | head -n 6) | $(dns_records | paste -sd, -)"
        if nt_world s2 s2; then
            # the rename is done: the old DNS record may be the one left (its failure is a warning that names it)
            run --yes delete s1; [[ $RC == 0 || $RC == 1 ]] || fail "rename ($variant), FAIL_AT=$FAIL_AT_N: the old record is removed by delete s1" "rc=$RC"
            nt_none s1 play && pass "rename ($variant), FAIL_AT=$FAIL_AT_N: and the old name leaves nothing behind (after delete s1)" \
                || fail "rename ($variant), FAIL_AT=$FAIL_AT_N: the old name leaves nothing behind" "$(dns_records | paste -sd, -)"
        else
            if [[ $state == running && $FAIL_AT_N -ge 2 ]]; then
                calls | grep -q -E 'mcctl-s1 .* start$' && pass "rename ($variant), FAIL_AT=$FAIL_AT_N: the running server is started again" \
                    || fail "rename ($variant), FAIL_AT=$FAIL_AT_N: the running server is started again" "$(calls | tail -n 4)"
            fi
            rm -f -- "$FAKE_STATE/mutations"
            run --yes rename s1 s2; assert_eq 0 "$RC" "rename ($variant), FAIL_AT=$FAIL_AT_N: the same rename, run again, completes"
            nt_world s2 s2 && pass "rename ($variant), FAIL_AT=$FAIL_AT_N: and s2 is complete" || fail "rename ($variant), FAIL_AT=$FAIL_AT_N: s2 is complete after the re-run"
        fi
    done
    rm -f -- "$FAKE_STATE/docker.compose.ps"
done

# rename to the same hostname (play): the record is relabelled by a PATCH, and a failure sets it back to the old comment
rm -f -- "$SB/sftp-users.conf"; created; echo exited >"$FAKE_STATE/docker.inspect"; rm -rf -- "$SB/servers/s2" "$SB/secrets/rcon-s2"
FAIL_AT=0 run --yes rename s1 s2 --hostname play; assert_eq 0 "$RC" "rename to the same hostname, counting its mutating calls"
total=$(<"$FAKE_STATE/mutations")
assert_eq 3 "$total" "rename to the same hostname makes 3 mutating calls (PATCH, compose rm, compose create)"
for ((FAIL_AT_N = 1; FAIL_AT_N <= total; FAIL_AT_N++)); do
    rm -f -- "$SB/sftp-users.conf"; created; echo exited >"$FAKE_STATE/docker.inspect"; rm -rf -- "$SB/servers/s2" "$SB/secrets/rcon-s2"
    rm -f -- "$FAKE_STATE/mutations"; truncate_log
    FAIL_AT=$FAIL_AT_N run --yes rename s1 s2 --hostname play
    assert_eq 1 "$RC" "rename to the same hostname, FAIL_AT=$FAIL_AT_N: exit 1"
    nt_one s1 play s2 play && pass "rename to the same hostname, FAIL_AT=$FAIL_AT_N: exactly one of s1, s2 is complete" \
        || fail "rename to the same hostname, FAIL_AT=$FAIL_AT_N: exactly one of s1, s2 is complete" "$(dns_records | paste -sd, -)"
    rm -f -- "$FAKE_STATE/mutations"
    run --yes rename s1 s2 --hostname play; assert_eq 0 "$RC" "rename to the same hostname, FAIL_AT=$FAIL_AT_N: the re-run completes"
    nt_world s2 play && pass "rename to the same hostname, FAIL_AT=$FAIL_AT_N: and s2 is complete" || fail "rename to the same hostname, FAIL_AT=$FAIL_AT_N: s2 is complete"
done

# import: an export of s1 (with its world) is made into i1, with its own hostname; a failure takes i1 back
created
mkdir -p "$SB/servers/s1" && tar -cf "$FAKE_STATE/docker.run.tar" -C "$SB/servers/s1" data
echo exited >"$FAKE_STATE/docker.inspect"
run export s1 "$SB/imp.tgz"; assert_eq 0 "$RC" "export s1 for the import loop"
rm -f -- "$FAKE_STATE/docker.run.tar"
reset_import() { rm -f -- "$FAKE_STATE/mutations"; truncate_log; }
FAIL_AT=0 run import "$SB/imp.tgz" i1 --hostname ih1; assert_eq 0 "$RC" "import, counting its mutating calls"
total=$(<"$FAKE_STATE/mutations")
assert_eq 6 "$total" "import makes 6 mutating calls (DNS POST, the chown of data/ and of backups/, the chown of the RCON secret, the helper's data extraction, compose create)"
run --yes delete i1 >/dev/null; fake_gone i1 ih1
for ((FAIL_AT_N = 1; FAIL_AT_N <= total; FAIL_AT_N++)); do
    reset_import
    FAIL_AT=$FAIL_AT_N run import "$SB/imp.tgz" i1 --hostname ih1
    [[ $RC == 1 || $RC == 4 ]] && pass "import, FAIL_AT=$FAIL_AT_N: exit $RC" || fail "import, FAIL_AT=$FAIL_AT_N: exit is EX_FAIL or EX_REFUSED" "rc=$RC $OUT"
    [[ -n $(nth_mutation "$FAIL_AT_N") ]] && pass "import, FAIL_AT=$FAIL_AT_N: the injected failure hit a call" || fail "import, FAIL_AT=$FAIL_AT_N: the injected failure hit a call"
    nt_none i1 ih1 && pass "import, FAIL_AT=$FAIL_AT_N: nothing of i1 is left" || fail "import, FAIL_AT=$FAIL_AT_N: nothing of i1 is left" "$(dns_records | grep ih1)"
    nt_world s1 play && pass "import, FAIL_AT=$FAIL_AT_N: the export's source s1 is complete" || fail "import, FAIL_AT=$FAIL_AT_N: s1 is complete"
    rm -f -- "$FAKE_STATE/mutations"
    run import "$SB/imp.tgz" i1 --hostname ih1; assert_eq 0 "$RC" "import, FAIL_AT=$FAIL_AT_N: the re-run completes"
    NT_WORLD=0 nt_world i1 ih1 && pass "import, FAIL_AT=$FAIL_AT_N: and i1 is complete" || fail "import, FAIL_AT=$FAIL_AT_N: i1 is complete after the re-run"
    run --yes delete i1 >/dev/null; fake_gone i1 ih1
done

echo "secrets (E4), over every run above"
truncate_log
log=$(<"$SB/all-calls.log")
assert_eq 32 "${#PWS[0]}" "(the RCON passwords looked for are real: ${#PWS[@]} seen)"
leaks=0
for pw in "${PWS[@]}"; do [[ $ALL$log == *"$pw"* ]] && leaks=$((leaks + 1)); done
assert_eq 0 "$leaks" "no RCON password is in any output or in the call log"
assert_not_contains "$ALL$log" "$CF_TOKEN" "nor is the Cloudflare token"

sandbox_cleanup
finish

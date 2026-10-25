#!/usr/bin/env bash
# Minimal test helpers (no framework). Each t_*.sh sources this, runs checks, ends with `finish`.
# Nothing here talks to a real Docker daemon, Cloudflare, or the network: docker/curl/rcon-cli/iptables/ss are the strict fakes in
# tests/fakebin, put first on PATH by `sandbox`, and DOCKER_HOST points at a socket that does not exist.

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)   # the single-standalone/ tree
T_PASS=0 T_FAIL=0 T_SKIP=0
T_FILE=$(basename "${BASH_SOURCE[1]:-test}")

pass() { T_PASS=$((T_PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2" | head -n 8; }
skip() { T_SKIP=$((T_SKIP + 1)); printf '  SKIP %s\n' "$1"; }   # a check this host cannot run; never counted as a pass

assert_eq()           { if [[ $1 == "$2" ]]; then pass "$3"; else fail "$3" "expected '$1', got '$2'"; fi; }
assert_contains()     { if [[ $1 == *"$2"* ]]; then pass "$3"; else fail "$3" "missing '$2' in: ${1:0:400}"; fi; }
assert_not_contains() { if [[ $1 != *"$2"* ]]; then pass "$3"; else fail "$3" "unexpected '$2' in: ${1:0:400}"; fi; }
assert_file()         { if [[ -e $1 ]]; then pass "$2"; else fail "$2" "missing file $1"; fi; }
assert_no_file()      { if [[ ! -e $1 ]]; then pass "$2"; else fail "$2" "unexpected file $1"; fi; }

# posix_modes_ok PATH: does the filesystem holding PATH keep POSIX modes? (Git Bash on NTFS reports 644 whatever chmod says.)
posix_modes_ok() {
    if [[ -z ${T_POSIX:-} ]]; then
        local probe
        probe=$(mktemp "$(dirname -- "$1")/.modeprobe.XXXXXX" 2>/dev/null) || return 0   # unknown: let the assertion decide
        chmod 640 "$probe"
        [[ $(stat -c %a "$probe" 2>/dev/null) == 640 ]] && T_POSIX=0 || T_POSIX=1
        rm -f -- "$probe"
    fi
    return "$T_POSIX"
}
assert_mode() { # FILE MODE MSG
    if ! posix_modes_ok "$1"; then skip "$3 (this host has no POSIX file modes)"; return; fi
    assert_eq "$2" "$(stat -c %a "$1" 2>/dev/null)" "$3"
}

calls() { cat "$FAKE_STATE/calls.log" 2>/dev/null; }
count_calls() { calls | grep -c -- "$1"; }

# strip_ansi S: remove ANSI escape sequences (ESC [ ... letter) from S
strip_ansi() { sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' <<<"$1"; }

# finish: print the summary, and tell run.sh the counts (it fails a file that recorded zero assertions).
finish() {
    local extra=""
    ((T_SKIP > 0)) && extra=", $T_SKIP skipped"
    printf '%s: %d passed, %d failed%s\n' "$T_FILE" "$T_PASS" "$T_FAIL" "$extra"
    if [[ -n ${MCCTL_TEST_COUNTS:-} ]]; then
        printf '%s %d %d %d\n' "$T_FILE" "$T_PASS" "$T_FAIL" "$T_SKIP" >>"$MCCTL_TEST_COUNTS"
    fi
    [[ $T_FAIL -eq 0 ]]
}

# assert_fakes_first: every tool the suite fakes must resolve to the sandbox copy, never to the real one. If one does not, stop
# at once (exit 99): the suite would otherwise act on this machine (an unprotected run of the sibling ptero suite once stopped
# and removed a live stack).
assert_fakes_first() {
    local tool
    for tool in docker curl rcon-cli iptables ss; do
        [[ $(command -v "$tool") == "$SB/fakebin/$tool" ]] && continue
        printf 'FATAL: %s resolves to %s, not to the test fake. Refusing to run: the suite would act on this machine.\n' \
            "$tool" "$(command -v "$tool" || echo nothing)" >&2
        sandbox_cleanup   # the sandbox was already created; do not leave it behind
        exit 99
    done
}

# sandbox: a throw-away copy of the mcctl tree and a fake host. Everything the tests touch lives under $SB, which is also
# $R (where `m` runs ./mcctl) and $MCCTL_ROOT (where mcctl keeps servers/).
sandbox() {
    # TMPDIR is re-pointed into every sandbox below, so remember where sandboxes belong: a second sandbox() in one test (after
    # sandbox_cleanup) must not look for the first one's directory.
    : "${MCCTL_TEST_BASE_TMP:=${TMPDIR:-/tmp}}"; export MCCTL_TEST_BASE_TMP
    SB=$(mktemp -d "$MCCTL_TEST_BASE_TMP/mcctl-test.XXXXXX") && [[ -d $SB ]] \
        || { echo "FATAL: cannot create the test sandbox under $MCCTL_TEST_BASE_TMP" >&2; exit 99; }
    R=$SB
    mkdir -p "$SB/state" "$SB/tmp" "$SB/home" "$SB/fakebin"
    # the router's group_add reads the group of the Docker socket: a stand-in file, so no test looks at the host's socket
    : >"$SB/docker.sock"; export MCCTL_DOCKER_SOCKET=$SB/docker.sock
    cp -r "$REPO/mcctl" "$REPO/lib" "$SB/"
    [[ -d $REPO/templates ]] && cp -r "$REPO/templates" "$SB/"
    chmod +x "$SB/mcctl"
    # The fakes are copied into the sandbox and made executable here. Git records them as 100644 on a checkout made from
    # Windows, and without the executable bit `docker` would resolve to the real client.
    cp "$REPO"/tests/fakebin/* "$SB/fakebin/" && chmod +x "$SB"/fakebin/*
    export PATH="$SB/fakebin:$PATH"
    # Second layer: even a real docker client cannot reach a daemon from inside the suite.
    export DOCKER_HOST=unix:///nonexistent/mcctl-tests-never-reach-a-real-daemon.sock
    export FAKE_STATE=$SB/state MCCTL_ROOT=$SB MCCTL_TEST_MODE=1 TMPDIR=$SB/tmp HOME=$SB/home
    unset MCCTL_YES T_UNK
    assert_fakes_first
}
sandbox_cleanup() { [[ -n ${SB:-} && -d $SB ]] && rm -rf -- "$SB"; }

# m ARGS... : run ./mcctl in the sandbox with stdin closed (no terminal). Output in $OUT, status in $RC.
# A call the fakes do not model is logged as UNKNOWN and fails the test here, even if mcctl swallowed the exit 97.
m() {
    local n
    OUT=$(cd "$R" && ./mcctl "$@" 2>&1 </dev/null); RC=$?
    n=$(grep -c '^UNKNOWN' "$FAKE_STATE/calls.log" 2>/dev/null)
    if ((${n:-0} > ${T_UNK:-0})); then
        T_UNK=$n
        fail "the fakes received a call they do not model" "$(grep '^UNKNOWN' "$FAKE_STATE/calls.log" | tail -n 3)"
    fi
}

# plant_canary PATH: write a unique value into a secret file (mode 600) and leave it in $CANARY. Flow tests then assert that
# the value appears in neither `calls` (the fakes' log) nor the command's stdout and stderr ($OUT).
plant_canary() {
    CANARY="canary-$(date +%s%N)-$$-$RANDOM$RANDOM"
    (umask 077; printf '%s\n' "$CANARY" >"$1") && chmod 600 "$1"
}

# fake_cloudflare: what create and delete need to make DNS records (lib/cloudflare.sh): MCCTL_PUBLIC_IPV4, MCCTL_CF_ZONE_ID and a
# token in secrets/cloudflare_token. The token is a canary, also kept in $CF_TOKEN. fakebin/curl plays the Cloudflare API; its records
# are in $FAKE_STATE/curl.records.json. Run it again after a test removed secrets/.
fake_cloudflare() {
    export MCCTL_PUBLIC_IPV4=203.0.113.7 MCCTL_CF_ZONE_ID=0123456789abcdef0123456789abcdef
    (umask 077; mkdir -p "$SB/secrets")
    plant_canary "$SB/secrets/cloudflare_token"
    CF_TOKEN=$CANARY
}
# dns_records [JQ-FILTER]: the fake Cloudflare's records, one "name comment" line each (default), sorted
dns_records() { jq -r "${1:-.[] | \"\\(.name) \\(.comment)\"}" "$FAKE_STATE/curl.records.json" 2>/dev/null | tr -d '\r' | sort; }
# The calls create and delete make for DNS and the router, as the fakes log them (for ordered call-log assertions):
#   cf_get QUERY, cf_post HOST [NAME], cf_del ID; dns_made HOST [NAME] (look-up and POST of create); dns_gone NAME ID (look-up by
#   and DELETE of delete); cf_last_id (the id of the record the fake made last); reload_call (router_reload)
cf_url()  { echo "https://api.cloudflare.com/client/v4/zones/$MCCTL_CF_ZONE_ID/dns_records$1"; }
cf_get()  { echo "curl -q -sS --proto =https --max-time 30 --config - -X GET -H Content-Type: application/json $(cf_url "?$1")"; }
cf_post() { echo "curl -q -sS --proto =https --max-time 30 --config - -X POST -H Content-Type: application/json --data {\"type\":\"A\",\"name\":\"$1.$MCCTL_DOMAIN\",\"content\":\"$MCCTL_PUBLIC_IPV4\",\"ttl\":120,\"proxied\":false,\"comment\":\"mcctl name=${2:-$1}\"} $(cf_url)"; }
cf_del()  { echo "curl -q -sS --proto =https --max-time 30 --config - -X DELETE -H Content-Type: application/json $(cf_url "/$1")"; }
dns_made() { cf_get "name=$1.$MCCTL_DOMAIN"; cf_post "$1" "${2:-$1}"; }
dns_gone() { cf_get "comment.exact=mcctl%20name%3D$1"; cf_del "$2"; }
cf_last_id() { echo "rec$(<"$FAKE_STATE/curl.ids")"; }
reload_call() { echo "docker compose -p mcctl-stack -f $SB/templates/stack.compose.yml kill -s HUP mc-router"; }
# sftp_ps_call: the question every SFTP change asks ("is the SFTP container running?"); create and delete log it where they change SFTP
sftp_ps_call() { echo "docker compose -p mcctl-sftp -f $SB/sftp.compose.yml ps -q --status running sftp"; }

# fake_server NAME HOST [STATE]: make the docker fake report a container for server NAME that uses the host name HOST. The fake
# replays canned files named after the words of the call (see fakebin/docker): one answers `docker ps ... label=mcctl.name=NAME`,
# one the hostname query, and one row (name|state|address|status, the format `mcctl list` asks for) goes into the managed list.
# NAME and HOST are plain server names, so they are already safe in a file name.
fake_server() {
    local n=$1 h=$2 s=${3:-running}
    fake_gone "$n" "$h"
    echo "id-$n" >"$FAKE_STATE/docker.ps.label_mcctl_name_$n"
    echo "$n" >"$FAKE_STATE/docker.ps.label_mcctl_hostname_$h"
    printf '%s|%s|%s.%s|%s\n' "$n" "$s" "$h" "${MCCTL_DOMAIN:-mc.example.net}" "Up 1 hour" >>"$FAKE_STATE/docker.ps.label_mcctl_managed_true"
}
# fake_gone NAME HOST: the container of NAME no longer exists (someone ran `docker rm`)
fake_gone() {
    local f=$FAKE_STATE/docker.ps.label_mcctl_managed_true
    rm -f -- "$FAKE_STATE/docker.ps.label_mcctl_name_$1" "$FAKE_STATE/docker.ps.label_mcctl_hostname_$2"
    [[ -f $f ]] || return 0
    grep -v "^$1|" "$f" >"$f.new"; mv -f "$f.new" "$f"
    [[ -s $f ]] || rm -f "$f"
}

# scan_word WORD FILE...: non-comment lines where WORD stands alone as a word
scan_word() {
    local w=$1; shift
    (($# > 0)) || return 0
    grep -nHE "(^|[^[:alnum:]_.-])$w([^[:alnum:]_-]|\$)" -- "$@" 2>/dev/null | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#'
}

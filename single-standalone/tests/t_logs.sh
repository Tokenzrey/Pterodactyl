#!/usr/bin/env bash
# lib/logs.sh: colorize_log_line, cmd_logs. E3: cmd_logs named in tests.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/logs.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
unset NO_COLOR
load_config 2>/dev/null

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }

echo "colorize_log_line: INFO"
line='[12:00:01] [Server thread/INFO]: Starting done'
out=$(colorize_log_line "$line")
stripped=$(strip_ansi "$out")
assert_eq "$line" "$stripped" "INFO: text equals input after strip_ansi"
assert_contains "$out" $'\033[32m' "INFO: level is green"
assert_contains "$out" "INFO" "INFO: level word present"

echo "colorize_log_line: WARN and ERROR colours differ; ERROR colours message"
line='[12:00:02] [Thread/WARN]: something happened'
out=$(colorize_log_line "$line")
assert_contains "$out" $'\033[33m' "WARN: yellow"
assert_contains "$out" "something happened" "WARN: message present"
line='[12:00:03] [Thread/ERROR]: something broke'
out=$(colorize_log_line "$line")
assert_contains "$out" $'\033[1;31m' "ERROR: red bold"
assert_contains "$out" $'\033[1;31msomething broke\033[0m' "ERROR: message is coloured"

echo "colorize_log_line: stack trace takes preceding ERROR colour"
colorize_log_line '[12:00:01] [Thread/ERROR]: something broke' >/dev/null
out=$(colorize_log_line $'\tat net.minecraft.X.method')
stripped=$(strip_ansi "$out")
assert_eq $'\tat net.minecraft.X.method' "$stripped" "stack trace: text equals input after strip"
assert_contains "$out" $'\033[1;31m' "stack trace: takes ERROR colour"
out=$(colorize_log_line 'Caused by: java.lang.NullPointerException')
assert_contains "$out" $'\033[1;31m' "Caused by: takes ERROR colour"
out=$(colorize_log_line '... 12 more')
assert_contains "$out" $'\033[1;31m' "... 12 more: takes ERROR colour"
out=$(colorize_log_line '[12:00:02] [Thread/INFO]: recovered')
assert_contains "$out" $'\033[32m' "INFO after ERROR: green (reset)"

echo "colorize_log_line: unmatched line printed unchanged"
out=$(colorize_log_line '[init] starting')
assert_eq '[init] starting' "$out" "unmatched line: printed unchanged"

echo "colorize_log_line: byte for byte (no backslash or % interpretation)"
line='100% done \n'
out=$(NO_COLOR=1 colorize_log_line "$line")
assert_eq "$line" "$out" "100% done backslash-n: byte for byte"
line='%s %d \\'
out=$(NO_COLOR=1 colorize_log_line "$line")
assert_eq "$line" "$out" "%s %d backslash-backslash: byte for byte"

echo "colorize_log_line: C3 control char removal"
line=$'\x1b[2J\x07 test\there'
out=$(NO_COLOR=1 colorize_log_line "$line")
assert_not_contains "$out" $'\x1b' "C3 NO_COLOR: ESC byte removed"
assert_not_contains "$out" $'\x07' "C3 NO_COLOR: BEL byte removed"
assert_contains "$out" $'\t' "C3 NO_COLOR: tab survives"
out=$(colorize_log_line "$line")
assert_not_contains "$out" $'\x1b[2J' "C3 colour: ESC[2J removed"
assert_contains "$out" $'\t' "C3 colour: tab survives"

echo "_log_process: --level filter"
input=$(printf '[12:00:01] [T/INFO]: info line\n\tat info.stack\n[12:00:02] [T/WARN]: warn line\n\tat warn.stack\n[12:00:03] [T/ERROR]: error line\n[12:00:04] [T/FATAL]: fatal line\n')
out=$(_log_process 2 "" 0 <<<"$input")
assert_not_contains "$out" "info line" "--level WARN: hides INFO"
assert_not_contains "$out" "info.stack" "--level WARN: stack of hidden INFO goes"
assert_contains "$out" "warn line" "--level WARN: keeps WARN"
assert_contains "$out" "warn.stack" "--level WARN: stack of kept WARN stays"
assert_contains "$out" "error line" "--level WARN: keeps ERROR"
assert_contains "$out" "fatal line" "--level WARN: keeps FATAL"
input2=$(printf '[init] starting\n[12:00:01] [T/INFO]: info line\n')
out=$(_log_process 2 "" 0 <<<"$input2")
assert_contains "$out" "[init] starting" "unmatched line before any entry stays"

echo "_log_process: --grep case-insensitive literal"
input=$(printf '[12:00:01] [T/INFO]: Starting server\n[12:00:02] [T/INFO]: Loading world\n[12:00:03] [T/WARN]: Low memory\n')
out=$(_log_process 0 "STARTING" 0 <<<"$input")
assert_contains "$out" "Starting server" "--grep: case-insensitive match"
assert_not_contains "$out" "Loading world" "--grep: non-matching line hidden"
input2=$(printf '[12:00:01] [T/INFO]: file a.c not found\n[12:00:02] [T/INFO]: file abc not found\n')
out=$(_log_process 0 "a.c" 0 <<<"$input2")
assert_contains "$out" "file a.c not found" "--grep: a.c matched literally"
assert_not_contains "$out" "file abc not found" "--grep: a.c is not a regex"
input3=$(printf '[12:00:01] [T/INFO]: has [x in it\n[12:00:02] [T/INFO]: no brackets here\n')
out=$(_log_process 0 "[x" 0 <<<"$input3")
assert_contains "$out" "has [x in it" "--grep: [x matched literally"

echo "_log_process: C3 before the filters: a control character before the timestamp does not change the level"
input=$(printf '[12:00:00] [Server thread/INFO]: first\n\x1b[0m[12:00:00] [Server thread/ERROR]: boom\n\x1b[0m[12:00:00] [Server thread/INFO]: quiet\n')
out=$(_log_process 2 "" 0 <<<"$input")
assert_contains "$out" "boom" "--level WARN keeps an ERROR line with an ESC before its timestamp (its level is ERROR)"
assert_not_contains "$out" "first" "--level WARN still drops a plain INFO line"
assert_not_contains "$out" $'\x1b' "the kept line is printed without the ESC"
quiet=$(printf '\x1b[0m[12:00:00] [Server thread/INFO]: quiet\n')
out=$(_log_process 2 "" 0 <<<"$quiet")
assert_not_contains "$out" "quiet" "--level WARN drops an INFO line with an ESC before its timestamp"

echo "cmd_logs: end to end with fakes"
reset
fake_server s1 s1 running
printf '[12:00:01] [T/INFO]: line1\n[12:00:02] [T/INFO]: line2\n[12:00:03] [T/INFO]: line3\n' >"$FAKE_STATE/docker.logs"
m logs s1 --tail 5; assert_eq 0 "$RC" "logs s1 --tail 5 exit 0"
assert_contains "$(calls)" "docker logs --tail 5 mc-s1" "runs docker logs --tail 5 mc-s1"
assert_contains "$OUT" "line1" "shows line1"
assert_contains "$OUT" "line3" "shows line3"

m logs s1 -f --tail 3; assert_eq 0 "$RC" "logs s1 -f --tail 3 exit 0"
assert_contains "$(calls)" "docker logs --tail 3 -f mc-s1" "-f adds -f"

m logs s1; assert_contains "$(calls)" "docker logs --tail 100 mc-s1" "default --tail 100"

m logs s1 --tail abc;    assert_eq 2 "$RC" "--tail abc: exit 2"
m logs s1 --tail 100001; assert_eq 2 "$RC" "--tail 100001: exit 2"
m logs s1 --level DEBUG; assert_eq 2 "$RC" "--level DEBUG: exit 2"
m logs s1 --bogus;       assert_eq 2 "$RC" "unknown option: exit 2"
m logs;                  assert_eq 2 "$RC" "missing NAME: exit 2"
m logs nope;             assert_eq 1 "$RC" "nope: exit 1"
m logs s1 --grep "";     assert_eq 2 "$RC" "empty --grep: exit 2"
long_grep=$(printf 'x%.0s' {1..201})
m logs s1 --grep "$long_grep"; assert_eq 2 "$RC" "--grep 201 chars: exit 2"

echo "F3: an ordinary line forks no tr (a PATH shim logs each call, then runs the real tr)"
shim=$(mktemp -d)
cat >"$shim/tr" <<EOF
#!/usr/bin/env bash
echo x >>"$shim/calls"
exec "$(command -v tr)" "\$@"
EOF
chmod +x "$shim/tr"
ordinary=$(for ((i = 1; i <= 500; i++)); do printf '[12:00:%02d] [Server thread/INFO]: line %d\n' $((i % 60)) "$i"; done)
oldpath=$PATH; PATH="$shim:$PATH"
: >"$shim/calls"
out=$(while IFS= read -r l; do colorize_log_line "$l"; done <<<"$ordinary")
n=$(wc -l <"$shim/calls")
assert_eq 0 "$n" "colorize_log_line: 500 ordinary lines, no tr call"
assert_eq "$ordinary" "$(strip_ansi "$out")" "colorize_log_line: the 500 lines are unchanged"
reset
: >"$shim/calls"
fake_server s1 s1 running
printf '%s\n' "$ordinary" >"$FAKE_STATE/docker.logs"
m logs s1 --tail 500
n=$(wc -l <"$shim/calls")
[[ $n -le 1 ]] && pass "cmd_logs --tail 500: at most one tr call for the whole output (made $n)" \
              || fail "cmd_logs --tail 500: at most one tr call for the whole output" "made $n"
assert_eq "$ordinary" "$OUT" "cmd_logs --tail 500: the output is unchanged"
PATH=$oldpath
rm -f "$FAKE_STATE/docker.logs"

echo "F4: a failing docker logs is an error: docker's text is shown, exit 1"
reset
fake_server s1 s1 running
printf 'Error response from daemon: No such container: mc-s1\n' >"$FAKE_STATE/docker.logs"
echo 1 >"$FAKE_STATE/docker.logs.rc"
m logs s1 --tail 5; assert_eq 1 "$RC" "docker logs fails: exit 1"
assert_contains "$OUT" "cannot read the logs of s1" "the message says the logs could not be read"
assert_contains "$OUT" "No such container" "docker's own message is shown"
rm -f "$FAKE_STATE/docker.logs" "$FAKE_STATE/docker.logs.rc"

echo "F5: Ctrl-C while following ends with 0: the INT handler is set for the follow pipeline (a grep: a terminal is needed for a real Ctrl-C)"
fn=$(declare -f cmd_logs)
_line_of() { awk -v pat="$1" 'index($0, pat) { print NR; exit }' <<<"$fn"; }
t_set=$(_line_of 'trap : INT'); t_pipe=$(_line_of '_log_process')
if [[ -n $t_set && -n $t_pipe ]] && ((t_set <= t_pipe)); then
    pass "the INT handler is set on the follow pipeline (in its subshell)"
else
    fail "the INT handler is set on the follow pipeline (in its subshell)" "lines: set=$t_set pipe=$t_pipe"
fi

echo "F3 streaming: a followed line reaches the output while docker still runs (a buffered stage would hold it back)"
reset
fake_server s1 s1 running
stream=$(mktemp -d)
mkdir -p "$stream/fakebin"   # mcctl in test mode accepts only a docker at */fakebin/docker (mcctl, the guard at its top)
cat >"$stream/fakebin/docker" <<EOF
#!/usr/bin/env bash
if [[ \${1-} == logs && " \$* " == *" -f "* ]]; then
    echo '[12:00:01] [Server thread/INFO]: streamed line'
    exec sleep 30
fi
exec "$SB/fakebin/docker" "\$@"
EOF
chmod +x "$stream/fakebin/docker"
(cd "$R" && PATH="$stream/fakebin:$PATH" timeout 3 ./mcctl logs s1 -f --tail 3 >"$stream/out.txt" 2>&1 </dev/null)
if grep -q 'streamed line' "$stream/out.txt"; then
    pass "logs -f: the line is out within 3 seconds, while docker is still running"
else
    fail "logs -f: the line is out within 3 seconds, while docker is still running" "got: $(cat "$stream/out.txt")"
fi

echo "E3: cmd_logs named in tests"
declare -F cmd_logs >/dev/null && pass "cmd_logs exists" || fail "cmd_logs exists"

sandbox_cleanup
finish

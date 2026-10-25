#!/usr/bin/env bash
# lib/players.sh (Task 17): valid_ip, valid_runtime_arg, ban-ip, pardon, pardon-ip, deop, banlist, ops, whitelist reload, import and
# --names, the reason of ban, and the runtime commands (say, save, gamerule, time, weather, worldborder, difficulty,
# defaultgamemode). Every refusal is checked before Docker: the refusals assert an empty call log (no docker ps, inspect or exec).
# Replies come from the docker.exec fake, ops from docker.run.cat.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
for f in "$REPO"/lib/*.sh; do [[ $f == */common.sh ]] || source "$f"; done
sandbox
export MCCTL_DOMAIN=mc.example.net
load_config 2>/dev/null

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
# up NAME STATE: Docker has the container of NAME, in STATE (running, exited, created), as in tests/t_rcon.sh
up() { fake_server "$1" "$1" "$2"; echo "$2" >"$FAKE_STATE/docker.inspect"; }
# the two questions every command asks before it sends anything (for s1)
ASKS="docker ps -a -q --filter label=mcctl.name=s1
docker inspect --format {{.State.Status}} mc-s1"
# sends RCON-TEXT ARGS...: mcctl ARGS succeeds and sends exactly RCON-TEXT, after the two questions
sends() {
    local want=$1; shift
    reset
    m "$@"
    assert_eq 0 "$RC" "mcctl ${*}"
    assert_eq "$ASKS
docker exec -i mc-s1 rcon-cli $want" "$(calls)" "mcctl ${*}: sends '$want' and nothing else"
}
# refuse ARGS...: mcctl ARGS is refused with EX_USAGE, and Docker is not asked anything
refuse() {
    reset
    m "$@"
    assert_eq 2 "$RC" "refused: mcctl ${*@Q}"
    assert_eq "" "$(calls)" "  and Docker was not asked"
}
# stopped ARGS...: a stopped server: mcctl ARGS exits 1, names mcctl start, and sends nothing
stopped() {
    reset
    m "$@"
    assert_eq 1 "$RC" "a stopped server: mcctl ${*} exits 1"
    assert_contains "$OUT" "mcctl start s1" "  and says mcctl start"
    assert_eq 0 "$(count_calls '^docker exec')" "  and sends nothing"
}
# table_ok WANT CMD... -- INPUT...: CMD INPUT exits WANT on every INPUT and prints nothing on stdout (one assertion for the table)
table_ok() {
    local want=$1 x out rc bad=0 first="" label
    local -a cmd=()
    shift
    while [[ $1 != -- ]]; do cmd+=("$1"); shift; done
    shift
    label="${cmd[*]}"
    for x in "$@"; do
        out=$("${cmd[@]}" "$x" 2>/dev/null); rc=$?
        if [[ $rc != "$want" || -n $out ]]; then bad=$((bad + 1)); first=${first:-"$x"}; fi
    done
    if ((bad == 0)); then pass "$label: exit $want on all $# inputs, nothing on stdout"
    else fail "$label: exit $want on all $# inputs" "$bad wrong, first ${first@Q}"; fi
}

long256=$(printf '%256s' ''); long256=${long256// /a}
long257="${long256}a"
long100=$(printf '%100s' ''); long100=${long100// /a}
long101="${long100}a"
long65=$(printf '%65s' ''); long65=${long65// /a}
long64=${long65:1}
two_lines=$(printf 'a\nb')

echo "valid_ip and valid_runtime_arg"
table_ok 0 valid_ip -- 1.2.3.4 0.0.0.0 255.255.255.255 10.0.0.1 0.10.100.200 2001:db8::1 fe80::1:2:3 1:2:3:4:5:6:7:8 ABCD:ef01::2
table_ok 2 valid_ip -- 999.1.1.1 1.2.3 01.2.3.4 1.2.3.04 1.2.3.4.5 256.0.0.1 -1.2.3.4 ' 1.2.3.4' $'1.2.3.4\n' '' a :: ::1 1:2 \
    1:2:3:4:5:6:7:8:9 1::2::3 1:::2 12345::1 g::1 :1:2:3:4:5:6:7 1:2:3:4:5:6:7: '$(id)'
table_ok 0 valid_runtime_arg say -- hello 'a;b|c&d$e' '   ' "$long256"
table_ok 2 valid_runtime_arg say -- '' "$two_lines" $'a\tb' $'a\x7f' "$long257"
table_ok 0 valid_runtime_arg reason -- 'a;b' "$long100"
table_ok 2 valid_runtime_arg reason -- '' "$two_lines" "$long101"
table_ok 0 valid_runtime_arg rule -- doDaylightCycle dayLight a1_b "$long64"
table_ok 2 valid_runtime_arg rule -- 'x;stop' 1abc '' "$long65" a-b
table_ok 0 valid_runtime_arg rule_value -- true false 0 123456789
table_ok 2 valid_runtime_arg rule_value -- maybe 1234567890 TRUE '' 1e3
table_ok 0 valid_runtime_arg time -- day night noon midnight 0 6000 12345678
table_ok 2 valid_runtime_arg time -- 1e3 123456789 -5 Day ''
table_ok 0 valid_runtime_arg weather -- clear rain thunder
table_ok 2 valid_runtime_arg weather -- snow Rain ''
table_ok 0 valid_runtime_arg difficulty -- peaceful easy normal hard
table_ok 2 valid_runtime_arg difficulty -- extreme Hard ''
table_ok 0 valid_runtime_arg gamemode -- survival creative adventure spectator
table_ok 2 valid_runtime_arg gamemode -- hardcore ''
table_ok 0 valid_runtime_arg seconds -- 1 0100 1000000
table_ok 2 valid_runtime_arg seconds -- 0 1000001 1e3 -1 ''
table_ok 0 valid_runtime_arg border -- 1 59999968
table_ok 2 valid_runtime_arg border -- 0 59999969 60000000
table_ok 0 valid_runtime_arg border_seconds -- 0 1000000
table_ok 2 valid_runtime_arg border_seconds -- 1000001 -1
table_ok 0 valid_runtime_arg center -- 0 -0 -29999984 29999984
table_ok 2 valid_runtime_arg center -- 29999985 -29999985 1.5 +5 ''
table_ok 2 valid_runtime_arg nope -- x

echo "refusals: each one before Docker is asked"
up s1 running
refuse ban s1 'x; stop'
refuse ban s1 @a
refuse ban s1 ''
refuse ban s1 aaaaaaaaaaaaaaaaa
refuse ban s1 Steve extra
refuse ban s1 Steve --reason "$two_lines"
refuse ban s1 Steve --reason "$long101"
refuse ban s1 Steve --reason ''
refuse ban-ip s1 999.1.1.1
refuse ban-ip s1 1.2.3
refuse ban-ip s1 01.2.3.4
refuse ban-ip s1 ::
refuse ban-ip s1 a
refuse ban-ip s1 1.2.3.4 --reason "$two_lines"
refuse ban-ip s1 1.2.3.4 --reason "$long101"
refuse ban-ip s1 1.2.3.4 --why x
refuse pardon-ip s1 999.1.1.1
refuse pardon s1 'x; stop'
refuse deop s1 '$(id)'
refuse banlist s1 --all
refuse gamerule s1 'x;stop' true
refuse gamerule s1 dayLight maybe
refuse gamerule s1 doDaylightCycle 1234567890
refuse time s1 set 1e3
refuse time s1 add 5
refuse weather s1 rain 0
refuse weather s1 snow
refuse weather s1 rain 1000001
refuse worldborder s1 set 0
refuse worldborder s1 set 60000000
refuse worldborder s1 center 30000000 0
refuse worldborder s1 jump 5
refuse say s1 "$two_lines"
refuse say s1 "$long257"
refuse say s1 ''
refuse difficulty s1 extreme
refuse difficulty s1 hard extra
refuse defaultgamemode s1 hardcore
refuse whitelist import s1 /nonexistent/names.txt
refuse ops 'Bad Name'
refuse save
refuse say

echo "the runtime commands: what is sent"
sends "ban Notch"                       ban s1 Notch
sends "ban Notch a;b c"                 ban s1 Notch --reason 'a;b c'
sends "ban-ip 10.0.0.1"                 ban-ip s1 10.0.0.1
sends "ban-ip 2001:db8::1 x"            ban-ip s1 2001:db8::1 --reason x
sends "pardon Notch"                    pardon s1 Notch
sends "pardon-ip 10.0.0.1"              pardon-ip s1 10.0.0.1
sends "deop Notch"                      deop s1 Notch
sends "whitelist reload"                whitelist reload s1
sends "say hello world"                 say s1 'hello world'
sends "save-all flush"                  save s1
sends "gamerule doDaylightCycle"        gamerule s1 doDaylightCycle
sends "gamerule doDaylightCycle false"  gamerule s1 doDaylightCycle false
sends "time set day"                    time s1 set day
sends "time set 6000"                   time s1 set 6000
sends "weather rain"                    weather s1 rain
sends "weather thunder 600"             weather s1 thunder 600
sends "worldborder get"                 worldborder s1 get
sends "worldborder set 100"             worldborder s1 set 100
sends "worldborder set 100 30"          worldborder s1 set 100 30
sends "worldborder center -100 25"      worldborder s1 center -100 25
sends "difficulty hard"                 difficulty s1 hard
sends "defaultgamemode creative"        defaultgamemode s1 creative

echo "whitelist list --names, banlist --names"
printf 'There are 2 whitelisted players: a, b\n' >"$FAKE_STATE/docker.exec"
reset; m whitelist list s1 --names
assert_eq 0 "$RC" "whitelist list --names: exit 0"
assert_eq "a
b" "$OUT" "--names: one name per line"
assert_eq "$ASKS
docker exec -i mc-s1 rcon-cli whitelist list" "$(calls)" "  and it sends whitelist list"
printf 'There are no whitelisted players\n' >"$FAKE_STATE/docker.exec"
m whitelist list s1 --names
assert_eq "" "$OUT" "an empty list prints nothing with --names"
m whitelist list s1
assert_eq "There are no whitelisted players" "$OUT" "without --names the reply is printed as it is"
printf 'There are 2 whitelisted players: a, b\n' >"$FAKE_STATE/docker.exec"
m whitelist list s1
assert_eq "There are 2 whitelisted players: a, b" "$OUT" "without --names, a list is printed as it is too"
printf 'There are 2 bans:\nNotch was banned by Server: x\n/10.0.0.1 was banned by Server: y\n' >"$FAKE_STATE/docker.exec"
m banlist s1 --names
assert_eq "Notch
/10.0.0.1" "$OUT" "banlist --names: the name or address of each entry"
m banlist s1
assert_contains "$OUT" "Notch was banned by Server" "banlist without --names prints the reply"
printf 'There are no bans\n' >"$FAKE_STATE/docker.exec"
m banlist s1 --names
assert_eq "" "$OUT" "an empty banlist prints nothing with --names"
rm -f "$FAKE_STATE/docker.exec"

echo "whitelist import"
printf '# the list\nSteve\n\n   \nAlex\r\n' >"$SB/names.txt"
reset; m whitelist import s1 "$SB/names.txt"
assert_eq 0 "$RC" "a file with comments, blank lines and a CR at the end: exit 0"
assert_eq "$ASKS
docker exec -i mc-s1 rcon-cli whitelist add Steve
$ASKS
docker exec -i mc-s1 rcon-cli whitelist add Alex" "$(calls)" "each name is one whitelist add, in file order, after the two questions"
printf 'Steve\n# ok\nx;stop\nAlex\n' >"$SB/bad.txt"
reset; m whitelist import s1 "$SB/bad.txt"
assert_eq 2 "$RC" "one bad line: exit 2"
assert_contains "$OUT" "line 3" "  and the message gives its line number"
assert_not_contains "$OUT" "x;stop" "  but not its text"
assert_eq "" "$(calls)" "  and nothing was sent"
yes '#' | head -n 500 >"$SB/500.txt"
reset; m whitelist import s1 "$SB/500.txt"
assert_eq 0 "$RC" "500 lines is the most: exit 0"
assert_eq "" "$(calls)" "  (all comments here: nothing sent)"
yes '#' | head -n 501 >"$SB/501.txt"
reset; m whitelist import s1 "$SB/501.txt"
assert_eq 2 "$RC" "501 lines: exit 2"
assert_contains "$OUT" "501 lines" "  and the message says how many"
assert_eq "" "$(calls)" "  and nothing was sent"
reset; m whitelist import s1 "$SB/none.txt"
assert_eq 2 "$RC" "a file that cannot be read: exit 2"
for i in $(seq 1 50); do printf 'p%02d\n' "$i"; done >"$SB/50.txt"
reset; m whitelist import s1 "$SB/50.txt"
assert_contains "$OUT" "whitelist import: 50 of 50 names sent" "50 names: a progress line at 50"
assert_eq 50 "$(count_calls 'whitelist add')" "  and 50 whitelist adds"
up s1 exited; reset; m whitelist import s1 "$SB/names.txt"
assert_eq 1 "$RC" "a stopped server: the import stops at the first name, exit 1"
assert_contains "$OUT" "mcctl start s1" "  and says mcctl start"
assert_eq 0 "$(count_calls 'whitelist add')" "  and nothing was added"
up s1 running

echo "ban and ban-ip with a reason"
reset; m ban s1 Steve --reason 'a;b'
assert_eq 0 "$RC" "a reason with ';' is accepted"
assert_contains "$(calls)" "rcon-cli ban Steve a;b" "  and sent as one argument after the name"
m ban s1 Steve extra
assert_eq 2 "$RC" "ban with a third word and no --reason: refused (Task 5 grammar)"

echo "ops: ops.json through the helper container, on a stopped server too"
up s1 exited
mkdir -p "$SB/servers/s1/data"
printf '[{"uuid":"u1","name":"Notch","level":4},{"name":"Dinnerbone","level":2}]\n' >"$FAKE_STATE/docker.run.cat"
reset; m ops s1
assert_eq 0 "$RC" "ops: exit 0"
assert_eq "Notch
Dinnerbone" "$OUT" "prints the names, in file order"
assert_eq 1 "$(count_calls 'cat -- ops.json$')" "  and reads ops.json once, in the helper container"
assert_eq 0 "$(count_calls '^docker exec')" "  and sends nothing"
printf '[{"name":' >"$FAKE_STATE/docker.run.cat"
m ops s1
assert_eq 1 "$RC" "ops: invalid JSON exits 1"
assert_contains "$OUT" "ops.json of s1" "  and says which file"
printf '[]\n' >"$FAKE_STATE/docker.run.cat"
m ops s1
assert_eq "no operators" "$OUT" "an empty list: no operators"
rm -f "$FAKE_STATE/docker.run.cat"; echo 1 >"$FAKE_STATE/docker.run.cat.rc"
m ops s1
assert_eq "no operators" "$OUT" "no ops.json (cat exits 1): no operators"
assert_eq 0 "$RC" "  and exit 0"
echo 125 >"$FAKE_STATE/docker.run.cat.rc"
m ops s1
assert_eq 1 "$RC" "Docker fails while reading (status 125): exit 1, not 'no operators'"
rm -f "$FAKE_STATE/docker.run.cat" "$FAKE_STATE/docker.run.cat.rc"
up s1 running

echo "difficulty: --persist stores it for mcctl apply"
mkdir -p "$SB/servers/s1"
printf 'EULA=TRUE\nDIFFICULTY=easy\n' >"$SB/servers/s1/server.env"
reset; m difficulty s1 hard --persist
assert_eq 0 "$RC" "difficulty hard --persist: exit 0"
assert_eq "$ASKS
docker exec -i mc-s1 rcon-cli difficulty hard" "$(calls)" "the runtime command is sent first"
assert_eq "EULA=TRUE
DIFFICULTY=hard" "$(<"$SB/servers/s1/server.env")" "server.env: DIFFICULTY=hard, the other line kept"
assert_contains "$OUT" "config pending: mcctl apply s1" "  and it says the config is pending"
reset; m difficulty s1 peaceful
assert_eq "EULA=TRUE
DIFFICULTY=hard" "$(<"$SB/servers/s1/server.env")" "without --persist, server.env is not touched"
up s2 running; reset; m difficulty s2 hard --persist
assert_eq 1 "$RC" "--persist where server.env cannot be written: exit 1"
assert_contains "$OUT" "cannot write server.env of s2" "  and says so, after the runtime change"
up s1 exited; reset; m difficulty s1 hard --persist
assert_eq 1 "$RC" "a stopped server: --persist is refused before anything is stored"
assert_eq "EULA=TRUE
DIFFICULTY=hard" "$(<"$SB/servers/s1/server.env")" "  and server.env is unchanged"
up s1 running

echo "a stopped server: every runtime command stops at the running check"
up s1 exited
stopped say s1 hi
stopped save s1
stopped gamerule s1 doDaylightCycle
stopped time s1 set day
stopped weather s1 rain
stopped worldborder s1 get
stopped difficulty s1 hard
stopped defaultgamemode s1 survival
stopped ban-ip s1 10.0.0.1
stopped pardon-ip s1 10.0.0.1
stopped deop s1 Notch
stopped pardon s1 Notch
stopped banlist s1
stopped whitelist reload s1
up s1 running

echo "E4: the RCON secret is in no output and no call"
mkdir -p "$SB/secrets"; plant_canary "$SB/secrets/rcon-s1"; assert_file "$SB/secrets/rcon-s1" "the secret the check looks for exists"; ALL=""
reset; m say s1 hi;                        ALL+=$OUT$'\n'
m save s1;                                 ALL+=$OUT$'\n'
m whitelist import s1 "$SB/names.txt";     ALL+=$OUT$'\n'
m banlist s1 --names;                      ALL+=$OUT$'\n'
m ban-ip s1 10.0.0.1 --reason 'x';         ALL+=$OUT$'\n'
assert_not_contains "$ALL$(calls)" "$CANARY" "no output and no call of these commands holds the password"

echo "the commands exist"
m help
for c in ban-ip pardon pardon-ip banlist deop ops say save gamerule time weather worldborder difficulty defaultgamemode; do
    assert_contains "$OUT" " $c " "help lists $c"
done
for fn in cmd_ban_ip cmd_pardon cmd_pardon_ip cmd_banlist cmd_deop cmd_ops cmd_say cmd_save cmd_gamerule cmd_time cmd_weather cmd_worldborder cmd_difficulty cmd_defaultgamemode; do
    reset; ( "$fn" ) >/dev/null 2>&1; assert_eq 2 $? "$fn with no arguments: EX_USAGE"
    assert_eq "" "$(calls)" "  and Docker was not asked"
done

sandbox_cleanup
finish

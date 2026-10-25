#!/usr/bin/env bash
# lib/rcon.sh: the RCON secret (create, ensure_rcon_secret), valid_player, check_rcon_words, rcon_exec and the commands cmd_rcon,
# cmd_console, cmd_whitelist, cmd_ban, cmd_kick, cmd_op, cmd_players and cmd_rotate_rcon. E1: the ordered call log of every
# command. E4: neither the old nor the new password reaches output or the call log. Player names and RCON text are refused
# before ANY Docker call. The fake docker is stateless: `up` writes the canned answers for "this container exists, in this state".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/modpack.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/rcon.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
fake_cloudflare   # the DNS settings and secrets/cloudflare_token that create needs (tests/lib.sh)
load_config 2>/dev/null

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }
assert_ne() { if [[ $1 != "$2" ]]; then pass "$3"; else fail "$3" "both are '$1'"; fi; }
# up NAME STATE: Docker has the container of NAME, and reports STATE for it (running, exited, created)
up() { fake_server "$1" "$1" "$2"; echo "$2" >"$FAKE_STATE/docker.inspect"; }
# the two questions every command asks before it sends anything: does the server exist, does it run
ASKS="docker ps -a -q --filter label=mcctl.name=s1
docker inspect --format {{.State.Status}} mc-s1"
# sends RCON-TEXT ARGS...: mcctl ARGS succeeds and sends exactly RCON-TEXT, through one docker exec
sends() {
    local want=$1; shift
    reset
    m "$@"
    assert_eq 0 "$RC" "mcctl $*"
    assert_eq "$ASKS
docker exec -i mc-s1 rcon-cli $want" "$(calls)" "mcctl $*: asks Docker, then sends '$want' and nothing else"
}

echo "create: the RCON secret"
reset
m create s1 --type PAPER --accept-eula
assert_eq 0 "$RC" "create s1"
pw=$(<"$SB/secrets/rcon-s1")
assert_eq 32 "${#pw}" "secrets/rcon-s1 holds a 32 character password"
[[ $pw =~ ^[A-Za-z0-9]{32}$ ]] && pass "of letters and digits" || fail "of letters and digits" "$pw"
assert_mode "$SB/secrets/rcon-s1" 600 "mode 600"
yaml=$(<"$SB/servers/s1/compose.yaml")
assert_contains "$yaml" 'file: "../../secrets/rcon-s1"' "compose.yaml mounts it as a secret"
assert_eq 2 "$(grep -c 'RCON_PASSWORD_FILE: "/run/secrets/rcon_password"' <<<"$yaml")" "and hands it to both containers as RCON_PASSWORD_FILE"
assert_not_contains "$yaml$OUT$(calls)" "$pw" "its value is in no file but its own, nor in the output or the call log (E4)"
assert_eq "secrets/rcon-s1" "$(cd "$SB" && find secrets -type f ! -name cloudflare_token | paste -sd, -)" "and no temporary file is left beside it"

echo "ensure_rcon_secret"
(umask 077; printf 'keep-me\n' >"$SB/secrets/rcon-e1")
ensure_rcon_secret e1 2>/dev/null; assert_eq 0 $? "a secret that exists: 0"
assert_eq "keep-me" "$(<"$SB/secrets/rcon-e1")" "and it is left as it was"
ensure_rcon_secret e2; assert_eq 0 $? "a missing secret: 0"
assert_eq 33 "$(wc -c <"$SB/secrets/rcon-e2" | tr -d ' ')" "a new one is made (32 characters and a newline)"
assert_mode "$SB/secrets/rcon-e2" 600 "mode 600"
: >"$SB/secrets/rcon-e3"
ensure_rcon_secret e3; assert_eq 0 $? "an empty secret: 0"
assert_eq 33 "$(wc -c <"$SB/secrets/rcon-e3" | tr -d ' ')" "it is filled"
mkdir "$SB/secrets/rcon-e4"
out=$(ensure_rcon_secret e4 2>&1); assert_eq 1 $? "a directory where the secret belongs (Docker makes one): 1"
assert_contains "$out" "is a directory" "and it says so"
assert_eq "" "$(ls "$SB/secrets/rcon-e4")" "nothing was moved into it"
ensure_rcon_secret Bad 2>/dev/null; assert_eq 2 $? "a name that cannot be a server: EX_USAGE"
rmdir "$SB/secrets/rcon-e4"; rm -f "$SB/secrets"/rcon-e[123]

echo "valid_player"
for ok in Notch a _ . .Floodgate_09 Dinnerbone 1234567890123456 A_b.C; do
    valid_player "$ok" && pass "valid_player ${ok@Q}" || fail "valid_player ${ok@Q} is valid"
done
for bad in '' 12345678901234567 'x; stop' 'a b' ' Notch' 'Notch ' $'Notch\n' $'Notch\nstop' '$(id)' '`id`' '@a' '@p' '-h' 'a-b' 'a|b' 'a&b' "a'b" 'a"b' 'a\b' '../x' 'a/b' '*' '?' $'\xc3\x9c' '%s' '#a' '{a}' 'a=b' $'a\tb'; do
    valid_player "$bad" && fail "valid_player ${bad@Q} must be refused" || pass "valid_player refuses ${bad@Q}"
done

echo "check_rcon_words"
words() { WOUT=$(check_rcon_words "$@" 2>/dev/null); WRC=$?; }
for w in "say hi" "tp Notch -100 64 -200" "give Notch minecraft:stone 1" "say a;b|c&d\$e\`f\"g'h"; do
    # shellcheck disable=SC2086  # the first three are several words on purpose; the last has none that matter
    words $w; assert_eq 0 "$WRC" "accepted: $w"
done
words say $'a\x01'; assert_eq 2 "$WRC" "a control character (SOH): EX_USAGE"
words;               assert_eq 2 "$WRC" "no word: EX_USAGE"
words '';            assert_eq 2 "$WRC" "an empty command: EX_USAGE"
words -h;            assert_eq 2 "$WRC" "a first word with a leading '-': EX_USAGE"
words --password x;  assert_eq 2 "$WRC" "(rcon-cli would read it as an option)"
words say $'a\nstop'; assert_eq 2 "$WRC" "a newline: EX_USAGE"
words say $'a\rb';   assert_eq 2 "$WRC" "a carriage return: EX_USAGE"
words say $'a\tb';   assert_eq 2 "$WRC" "a tab: EX_USAGE"
words say $'a\x7f';  assert_eq 2 "$WRC" "DEL: EX_USAGE"
assert_eq "" "$WOUT" "a refusal prints nothing on stdout"
words tp Notch -100; assert_eq 0 "$WRC" "a '-' after the first word is a negative number, not an option"

echo "rcon_exec"
up s1 running
printf 'Said hi\n' >"$FAKE_STATE/docker.exec"
reset
assert_eq "Said hi" "$(rcon_exec s1 say hi)" "rcon_exec: the server's reply is stdout"
assert_eq "docker exec -i mc-s1 rcon-cli say hi" "$(calls)" "and it is one docker exec of rcon-cli with the words, no password"
reset
rcon_exec s1 say $'a\nstop' 2>/dev/null; assert_eq 2 $? "rcon_exec refuses a newline (EX_USAGE)"
rcon_exec Bad say hi 2>/dev/null;         assert_eq 2 $? "rcon_exec refuses a name that cannot be a server (EX_USAGE)"
rcon_exec s1 2>/dev/null;                 assert_eq 2 $? "rcon_exec refuses no command (EX_USAGE)"
assert_eq "" "$(calls)" "none of them reached Docker"
echo 3 >"$FAKE_STATE/docker.exec.rc"
rcon_exec s1 say hi >/dev/null; assert_eq 3 $? "rcon_exec returns the status of rcon-cli"
rm -f "$FAKE_STATE/docker.exec.rc" "$FAKE_STATE/docker.exec"

echo "rcon"
up s1 running
printf 'Said hi\n' >"$FAKE_STATE/docker.exec"
plant_canary "$SB/secrets/rcon-s1"
reset
m rcon s1 say hi
assert_eq 0 "$RC" "rcon s1 say hi"
assert_eq "Said hi" "$OUT" "the output is the server's reply"
assert_eq "$ASKS
docker exec -i mc-s1 rcon-cli say hi" "$(calls)" "calls: ask Docker, then rcon-cli with the argument list 'say hi'"
assert_eq 1 "$(count_calls '^docker exec')" "exactly one docker exec"
assert_not_contains "$(calls)" "pass" "and no password option on the command line"
assert_not_contains "$OUT$(calls)" "$CANARY" "the password is in neither the output nor the call log (E4)"
reset
m rcon s1 say 'a; stop & $HOME `id`'
assert_eq 0 "$RC" "the raw primitive passes shell metacharacters on as text (there is no shell between mcctl and rcon-cli)"
assert_contains "$(calls)" 'rcon-cli say a; stop & $HOME `id`' "as arguments of one exec"
reset
m rcon s1 say $'a\nstop';   assert_eq 2 "$RC" "a newline in the text: EX_USAGE"
m rcon s1 --password x;     assert_eq 2 "$RC" "a first word that rcon-cli would take as an option: EX_USAGE"
m rcon s1;                  assert_eq 2 "$RC" "no command: EX_USAGE"; assert_contains "$OUT" "usage: mcctl rcon NAME COMMAND" "and the usage"
m rcon;                     assert_eq 2 "$RC" "no arguments: EX_USAGE"
m rcon '../x' say hi;       assert_eq 2 "$RC" "a path as the name: EX_USAGE"
m rcon Bad say hi;          assert_eq 2 "$RC" "an upper-case name: EX_USAGE"
assert_eq "" "$(calls)" "none of these refusals reached Docker"
m rcon nope say hi
assert_eq 1 "$RC" "an unknown server: EX_FAIL"; assert_contains "$OUT" "no server named 'nope'" "named"
assert_eq "docker ps -a -q --filter label=mcctl.name=nope" "$(calls)" "calls: only the name check"
up s1 exited; reset
m rcon s1 say hi
assert_eq 1 "$RC" "a stopped server: EX_FAIL"
assert_contains "$OUT" "mcctl start s1" "the message says how to start it"
assert_eq 0 "$(count_calls '^docker exec')" "and nothing was sent"
up s1 running; reset
echo 1 >"$FAKE_STATE/docker.exec.rc"
m rcon s1 say hi
assert_eq 1 "$RC" "rcon-cli fails: EX_FAIL"; assert_contains "$OUT" "rcon-cli failed on s1" "and the message says so"
rm -f "$FAKE_STATE/docker.exec.rc"
reset
echo 1 >"$FAKE_STATE/docker.ps.label_mcctl_name_s1.rc"
m rcon s1 say hi
assert_eq 1 "$RC" "Docker cannot be asked: EX_FAIL"; assert_contains "$OUT" "cannot ask Docker" "and it says so"
assert_eq 0 "$(count_calls '^docker exec')" "nothing was sent"
rm -f "$FAKE_STATE/docker.ps.label_mcctl_name_s1.rc"
reset
echo 1 >"$FAKE_STATE/docker.inspect.rc"
m rcon s1 say hi
assert_eq 1 "$RC" "the container cannot be inspected: EX_FAIL"; assert_contains "$OUT" "cannot inspect mc-s1" "and it says so"
assert_eq 0 "$(count_calls '^docker exec')" "nothing was sent"
rm -f "$FAKE_STATE/docker.inspect.rc" "$FAKE_STATE/docker.exec"

echo "player commands: what is sent"
up s1 running
sends "ban Notch"                 ban s1 Notch
sends "kick Notch"                kick s1 Notch
sends "op Notch"                  op s1 Notch
sends "whitelist add Notch"       whitelist add s1 Notch
sends "whitelist remove .Flo_09"  whitelist remove s1 .Flo_09
sends "whitelist list"            whitelist list s1
sends "whitelist on"              whitelist on s1
sends "whitelist off"             whitelist off s1
sends "list"                      players s1
printf 'There are 1 of a max of 20 players online: Notch\n' >"$FAKE_STATE/docker.exec"
m players s1
assert_eq "There are 1 of a max of 20 players online: Notch" "$OUT" "players prints the server's own reply"
rm -f "$FAKE_STATE/docker.exec"

echo "player commands: hostile names and arguments are refused before Docker is asked"
reset
m ban s1 'x; stop'
assert_eq 2 "$RC" "ban s1 'x; stop': EX_USAGE"
assert_contains "$OUT" "invalid player name 'x; stop'" "the message names the name"
assert_eq "" "$(calls)" "and not one Docker call was made (no ps, no inspect, no exec)"
HOSTILE=('x; stop' 'a b' '$(id)' '`id`' $'Notch\nstop' 'aaaaaaaaaaaaaaaaa' '@a' '-h' 'a|b' "a'b" '' '../x' '*' $'\xc3\x9c' 'Notch ' ' Notch' 'a&b' 'a;b' 'Notch,Herobrine' '%n')
bad=0 first=""
for h in "${HOSTILE[@]}"; do
    for fn in "cmd_ban s1" "cmd_kick s1" "cmd_op s1" "cmd_whitelist add s1" "cmd_whitelist remove s1"; do
        # shellcheck disable=SC2086  # $fn is a command and its fixed arguments, on purpose
        out=$( $fn "$h" 2>&1 ); rc=$?
        if ((rc != 2)) || [[ $out != *"invalid player name"* ]]; then bad=$((bad + 1)); first=${first:-"$fn ${h@Q}: exit $rc"}; fi
    done
done
assert_eq 0 "$bad" "${#HOSTILE[@]} hostile names against ban, kick, op, whitelist add and remove: every one is EX_USAGE ${first:+(first: $first)}"
assert_eq "" "$(calls)" "and none of those made a Docker call"
m ban s1 Notch extra;       assert_eq 2 "$RC" "ban with a reason or a second name: EX_USAGE (the wrappers send a name and nothing else)"
m ban s1;                   assert_eq 2 "$RC" "ban with no player: EX_USAGE"; assert_contains "$OUT" "usage: mcctl ban SERVER PLAYER" "and the usage"
m ban;                      assert_eq 2 "$RC" "ban with no arguments: EX_USAGE"
m kick s1;                  assert_eq 2 "$RC" "kick with no player: EX_USAGE"
m op s1;                    assert_eq 2 "$RC" "op with no player: EX_USAGE"
m whitelist;                assert_eq 2 "$RC" "whitelist with no action: EX_USAGE"
m whitelist frobnicate s1 x; assert_eq 2 "$RC" "whitelist with an unknown action: EX_USAGE"
m whitelist add s1;         assert_eq 2 "$RC" "whitelist add with no player: EX_USAGE"
m whitelist list s1 Notch;  assert_eq 2 "$RC" "whitelist list with a player: EX_USAGE"
m whitelist add;            assert_eq 2 "$RC" "whitelist add with no arguments: EX_USAGE"
m players;                  assert_eq 2 "$RC" "players with no name: EX_USAGE"
m ban Bad Notch;            assert_eq 2 "$RC" "ban on a name that cannot be a server: EX_USAGE"
assert_eq "" "$(calls)" "no usage error made a Docker call"
m ban nope Notch;           assert_eq 1 "$RC" "ban on an unknown server: EX_FAIL"
assert_eq "docker ps -a -q --filter label=mcctl.name=nope" "$(calls)" "calls: only the name check"
up s1 exited; reset
m op s1 Notch
assert_eq 1 "$RC" "op on a stopped server: EX_FAIL"; assert_contains "$OUT" "mcctl start s1" "the message says how to start it"
assert_eq 0 "$(count_calls '^docker exec')" "and nothing was sent"
up s1 running

echo "console"
up s1 exited; reset
m console s1
assert_eq 1 "$RC" "a stopped server: EX_FAIL"
assert_contains "$OUT" "mcctl start s1" "the message names mcctl start"
assert_eq 0 "$(count_calls '^docker exec')" "and no console was opened"
up s1 running; reset
m console s1
assert_eq 2 "$RC" "no terminal: EX_USAGE"; assert_contains "$OUT" "mcctl rcon s1 COMMAND" "the message offers the one-command form"
assert_eq 0 "$(count_calls '^docker exec')" "and no console was opened"
reset
(_have_terminal() { return 0; }; cmd_console s1) >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" "with a terminal"
assert_eq "$ASKS
docker exec -it mc-s1 rcon-cli" "$(calls)" "calls: ask Docker, then an interactive rcon-cli with no argument and no password"
m console;         assert_eq 2 "$RC" "console with no name: EX_USAGE"
m console s1 s2;   assert_eq 2 "$RC" "console with two names: EX_USAGE"
m console Bad;     assert_eq 2 "$RC" "console Bad: EX_USAGE"

echo "rotate-rcon"
up s1 running
plant_canary "$SB/secrets/rcon-s1"; old=$CANARY
reset
m rotate-rcon s1
assert_eq 4 "$RC" "a running server, no --yes and no terminal: EX_REFUSED"
assert_eq "$old" "$(<"$SB/secrets/rcon-s1")" "the password is unchanged"
assert_eq "$ASKS" "$(calls)" "and the server was not restarted"
out=$( (confirm() { echo "ASKED: $1"; return 1; }; cmd_rotate_rcon s1) 2>&1 ); rc=$?
assert_contains "$out" "ASKED: Restart s1" "the question names the server"
assert_contains "$out" "disconnected" "and says that its players are disconnected"
assert_eq 4 "$rc" "a no answer is EX_REFUSED"
assert_eq "$old" "$(<"$SB/secrets/rcon-s1")" "and changes nothing"
reset
m --yes rotate-rcon s1
assert_eq 0 "$RC" "rotate-rcon --yes"
new=$(<"$SB/secrets/rcon-s1")
assert_ne "$old" "$new" "the password is a different one"
[[ $new =~ ^[A-Za-z0-9]{32}$ ]] && pass "32 letters and digits" || fail "32 letters and digits" "$new"
assert_mode "$SB/secrets/rcon-s1" 600 "mode 600"
assert_eq "$ASKS
$(give_line "$SB/secrets/rcon-s1.TMP")
docker compose -p mcctl-s1 -f $SB/servers/s1/compose.yaml restart" "$(calls)" "calls: ask Docker, the new secret is given to the game's user, then restart both containers so that they read it"
assert_not_contains "$OUT$(calls)" "$old" "the old password is in no output and not in the call log (E4)"
assert_not_contains "$OUT$(calls)" "$new" "nor is the new one"
assert_eq "rcon-s1" "$(cd "$SB" && ls secrets | grep -vx cloudflare_token | paste -sd, -)" "and no temporary file is left beside it"
assert_not_contains "$(<"$SB/servers/s1/compose.yaml")" "$new" "compose.yaml never holds it"
reset
echo 1 >"$FAKE_STATE/docker.compose.restart.rc"
m --yes rotate-rcon s1
assert_eq 1 "$RC" "the restart fails: EX_FAIL"
assert_contains "$OUT" "mcctl restart s1" "the message says how to finish"
assert_ne "$new" "$(<"$SB/secrets/rcon-s1")" "the new password is in place, and applies at the next restart"
rm -f "$FAKE_STATE/docker.compose.restart.rc"
up s1 exited; before=$(<"$SB/secrets/rcon-s1"); reset
m rotate-rcon s1
assert_eq 0 "$RC" "a stopped server needs no confirmation"
assert_ne "$before" "$(<"$SB/secrets/rcon-s1")" "it gets a new password"
assert_eq "$ASKS
$(give_line "$SB/secrets/rcon-s1.TMP")" "$(calls)" "and is not restarted (its secret is given to the game's user)"
assert_contains "$OUT" "next starts" "the message says when it applies"
up d exited; mkdir "$SB/secrets/rcon-d"; reset
m rotate-rcon d
assert_eq 1 "$RC" "the secret cannot be written: EX_FAIL"; assert_contains "$OUT" "is a directory" "and it says why"
rmdir "$SB/secrets/rcon-d"; fake_gone d d
m rotate-rcon nope;       assert_eq 1 "$RC" "an unknown server: EX_FAIL"
m rotate-rcon Bad;        assert_eq 2 "$RC" "rotate-rcon Bad: EX_USAGE"
m rotate-rcon;            assert_eq 2 "$RC" "rotate-rcon with no name: EX_USAGE"
m rotate-rcon s1 s2;      assert_eq 2 "$RC" "rotate-rcon with two names: EX_USAGE"

echo "create: a directory where the secret belongs"
mkdir "$SB/secrets/rcon-s9"; reset
m create s9 --type PAPER --accept-eula
assert_eq 1 "$RC" "create fails: EX_FAIL"; assert_contains "$OUT" "secrets/rcon-s9" "and names the secret"
assert_no_file "$SB/servers/s9" "the folder was taken back"
assert_eq 0 "$(count_calls 'compose')" "and compose never ran"
rmdir "$SB/secrets/rcon-s9"

echo "the commands exist"
m help
for c in rcon console whitelist ban kick op players rotate-rcon; do assert_contains "$OUT" " $c " "help lists $c"; done
for fn in cmd_rcon cmd_console cmd_whitelist cmd_ban cmd_kick cmd_op cmd_players cmd_rotate_rcon; do
    ( "$fn" ) >/dev/null 2>&1; assert_eq 2 $? "$fn with no arguments: EX_USAGE"
done

sandbox_cleanup
finish

#!/usr/bin/env bash
# lib/data.sh: safe_path, the helper's docker run line (data_run, data_pipe), and every `mcctl files` subcommand (cmd_files) with
# its refusals and its calls. E4: a planted RCON secret is in neither the output nor the call log. E3: no eval, no sudo in
# lib/data.sh (t_invariants.sh); every rm -rf in it goes through safe_path on the line above.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/data.sh"
sandbox

reset() { : >"$FAKE_STATE/calls.log"; rm -f -- "$FAKE_STATE"/run.stdin.*; T_UNK=0; }
# canned CMD RC [STDOUT]: the helper's answer to CMD (the word after the image): exit RC, and STDOUT when given
canned() {
    rm -f -- "$FAKE_STATE/docker.run.$1" "$FAKE_STATE/docker.run.$1.rc"
    echo "$2" >"$FAKE_STATE/docker.run.$1.rc"
    if (($# >= 3)); then printf '%s' "$3" >"$FAKE_STATE/docker.run.$1"; fi
}
# the docker run line every helper call starts with, for server s1
HELPER="docker run --rm --network none --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp --pids-limit 64 --memory 128m -v $SB/servers/s1/data:/data -w /data alpine:3.20"

echo "safe_path"
for v in /etc/passwd ../x a/../../x a/.. $'a\nb' $'a\x1bb' $'a\tb' ''; do
    out=$(safe_path "$v" 2>/dev/null); rc=$?
    assert_eq 2 "$rc" "safe_path refuses ${v@Q}"
done
assert_eq "world/level.dat" "$(safe_path world/level.dat)" "safe_path keeps world/level.dat"
assert_eq "mods/a.jar" "$(safe_path ./mods/a.jar)" "./mods/a.jar prints mods/a.jar"
assert_eq "a/b" "$(safe_path a//b/)" "a//b/ prints a/b"
assert_eq "./-rf" "$(safe_path -rf)" "-rf prints ./-rf (no command reads it as an option)"
assert_eq "." "$(safe_path ./)" "./ prints . (the folder itself)"

echo "data_run: the helper's docker run line"
mkdir -p "$SB/servers/s1/data/world" "$SB/servers/s1/data/mods" "$SB/secrets"
echo level >"$SB/servers/s1/data/world/level.dat"
plant_canary "$SB/secrets/rcon-s1"; rcon=$CANARY
reset; m files s1 ls world; assert_eq 0 "$RC" "ls of a folder exits 0"
assert_contains "$(calls)" "$HELPER sh -c " "the check runs in the helper with the fixed flags, the image and data/ as /data"
assert_contains "$(calls)" "$HELPER ls -la -- world" "ls runs with the same flags, after --"
assert_not_contains "$OUT$(calls)" "$rcon" "E4: the planted RCON secret is in neither the output nor the calls"
reset; MCCTL_UID=2000 m files s1 ls; assert_contains "$(calls)" "--user 2000:2000" "MCCTL_UID=2000 changes the user"
reset; MCCTL_DATA_IMAGE=busybox:1.36 m files s1 ls; assert_contains "$(calls)" " busybox:1.36 " "MCCTL_DATA_IMAGE changes the image"
for u in 0 abc 65536; do
    reset; MCCTL_UID=$u m files s1 ls
    assert_eq 3 "$RC" "MCCTL_UID=$u: refused with EX_PREFLIGHT"
    assert_eq "" "$(calls)" "MCCTL_UID=$u: before any Docker call"
done
for i in 'x y' 'x;y' 'Alpine'; do
    reset; MCCTL_DATA_IMAGE=$i m files s1 ls
    assert_eq 3 "$RC" "MCCTL_DATA_IMAGE=${i@Q}: refused with EX_PREFLIGHT"
    assert_eq "" "$(calls)" "MCCTL_DATA_IMAGE=${i@Q}: before any Docker call"
done

echo "files: usage, the server, the path"
reset; m files; assert_eq 2 "$RC" "no arguments: EX_USAGE"
m files s1; assert_eq 2 "$RC" "no verb: EX_USAGE"
m files s1 bogus; assert_eq 2 "$RC" "an unknown verb: EX_USAGE"
m files ../x ls; assert_eq 2 "$RC" "a name that cannot be a server: EX_USAGE"
m files nosuch ls; assert_eq 1 "$RC" "a server with no data/ folder: exit 1"
assert_contains "$OUT" "no server named 'nosuch'" "and the message says which server"
reset; m files s1 cat; assert_eq 2 "$RC" "cat without a path: EX_USAGE"
reset; m files s1 cat /etc/passwd; assert_eq 2 "$RC" "cat of an absolute path: EX_USAGE"
assert_eq "" "$(calls)" "and no Docker call"
reset; m files s1 cat ../x; assert_eq 2 "$RC" "cat of a .. path: EX_USAGE"
reset; m files s1 ls ""; assert_eq 2 "$RC" "an empty path: EX_USAGE"
assert_eq "" "$(calls)" "and no Docker call for it"

echo "files rm: the data folder, folders, confirmation"
canned test 0   # test -d holds: world is a folder
reset; m files s1 rm .; assert_eq 4 "$RC" "rm . is refused: the data folder itself cannot be removed"
reset; m files s1 rm ./; assert_eq 4 "$RC" "rm ./ is refused too"
reset; m files s1 rm ''; assert_eq 2 "$RC" "rm '' is refused (an empty path)"
assert_eq "" "$(calls)" "none of the three made a Docker call"
reset; m files s1 rm world; assert_eq 4 "$RC" "rm of a folder without --recursive is refused"
assert_eq 0 "$(count_calls ' rm -')" "and nothing was removed"
reset; m files s1 rm world --recursive; assert_eq 4 "$RC" "rm --recursive asks first: no terminal, so refused"
assert_eq 0 "$(count_calls ' rm -')" "and nothing was removed"
reset; m --yes files s1 rm world --recursive; assert_eq 0 "$RC" "rm --recursive --yes removes the folder"
assert_contains "$(calls)" "$HELPER rm -rf -- world" "the call is rm -rf -- world: the path follows --"
canned test 1   # test -d fails: a file
reset; m files s1 rm world/level.dat; assert_eq 0 "$RC" "rm of a file needs no --recursive"
assert_contains "$(calls)" "$HELPER rm -- world/level.dat" "the call is rm -- world/level.dat"
assert_eq 0 "$(count_calls ' rm -r')" "and no recursive rm"
reset; m files s1 rm -x; assert_eq 0 "$RC" "a name that starts with a dash is removed by its ./ name"
assert_contains "$(calls)" "$HELPER rm -- ./-x" "the call is rm -- ./-x"

echo "files put: no overwrite without --force; the content is streamed"
printf 'jar\n' >"$SB/a.jar"
canned stat 0 "regular file"$'\n'   # the target exists
reset; m files s1 put a.jar mods/a.jar; assert_eq 4 "$RC" "put over an existing file is refused without --force"
assert_eq 0 "$(count_calls mcctl-tmp)" "and nothing was written"
reset; m files s1 put a.jar mods/a.jar --force; assert_eq 0 "$RC" "put --force replaces it"
assert_contains "$(calls)" "mcctl-tmp" "through a temp file and mv"
cmp -s "$SB/a.jar" "$FAKE_STATE/run.stdin.1" && pass "the file arrives as the helper's stdin" || fail "the file arrives as the helper's stdin"
canned stat 0 "directory"$'\n'  # the target is a folder: never replaced, not even with --force
reset; m files s1 put a.jar mods/a.jar --force; assert_eq 4 "$RC" "put --force over a folder is refused"
assert_contains "$OUT" "is a folder" "and the message says so"
assert_eq 0 "$(count_calls mcctl-tmp)" "and nothing was written"
canned stat 1   # not there
reset; m files s1 put a.jar mods/new.jar; assert_eq 0 "$RC" "put to a new name"
assert_contains "$(calls)" "docker run --rm -i --network none" "the store runs in the helper with its stdin (-i)"
reset; m files s1 put nosuch.jar mods/x.jar; assert_eq 1 "$RC" "put of a missing local file: exit 1"
assert_eq "" "$(calls)" "and no Docker call"

echo "files get: never over a local file, atomic"
canned cat 0 "LEVEL"$'\n'
rm -f -- "$SB/level.dat"; reset
m files s1 get world/level.dat; assert_eq 0 "$RC" "get copies to ./level.dat"
assert_eq "LEVEL" "$(<"$SB/level.dat")" "the local copy has the content"
printf 'mine\n' >"$SB/level.dat"; reset
m files s1 get world/level.dat; assert_eq 4 "$RC" "get refuses an existing local file"
assert_eq "mine" "$(<"$SB/level.dat")" "and leaves it unchanged"
rm -f -- "$SB/level.dat"; canned cat 1
reset; m files s1 get world/level.dat; assert_eq 1 "$RC" "a failing copy exits 1"
assert_no_file "$SB/level.dat" "and leaves no local file"
assert_eq "" "$(compgen -G "$SB/*.tmp")" "and no temp file"
canned cat 0 "LEVEL"$'\n'

echo "confinement: a link that leads out of data/ is refused before any read or write"
canned sh 3
reset; m files s1 cat world/level.dat; assert_eq 2 "$RC" "cat: refused with EX_USAGE"
assert_eq 1 "$(count_calls 'alpine:3.20 sh -c')" "one helper call only: the check"
assert_eq 0 "$(count_calls ' cat -- ')" "and no cat after it"
reset; m files s1 put a.jar mods/a.jar --force; assert_eq 2 "$RC" "put: refused before the write"
assert_eq 0 "$(count_calls mcctl-tmp)" "and no store call"
reset; m files s1 rm world; assert_eq 2 "$RC" "rm: refused before the test or the removal"
assert_eq 0 "$(count_calls 'alpine:3.20 test ')" "and no test call after it"
canned sh 0

echo "files edit: EDITOR, write-back only on a change, 1 MB, the temp file"
cat >"$SB/append.sh" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(stat -c %a "$1")" "$(stat -c %a "$(dirname "$1")")" >"$FAKE_STATE/editor.modes"
printf '%s\n' "$1" >"$FAKE_STATE/editor.path"
printf 'added\n' >>"$1"
EOF
cat >"$SB/grow.sh" <<'EOF'
#!/bin/sh
head -c 1100000 /dev/zero >>"$1"
EOF
cat >"$SB/hang.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >"$FAKE_STATE/editor.path"
sleep 30
EOF
chmod +x "$SB/append.sh" "$SB/grow.sh" "$SB/hang.sh"
canned cat 0 "one"$'\n'
canned stat 0 "4"$'\n'
printf 'one\nadded\n' >"$SB/want"
reset; EDITOR=$SB/append.sh m files s1 edit notes.txt; assert_eq 0 "$RC" "edit: exit 0"
assert_contains "$(calls)" "$HELPER stat -c %s -- notes.txt" "the size is asked of the helper first"
cmp -s "$SB/want" "$FAKE_STATE/run.stdin.1" && pass "the edited content is written back" || fail "the edited content is written back"
assert_eq "600 700" "$(<"$FAKE_STATE/editor.modes")" "the copy is mode 600, in a folder of mode 700"
p1=$(cat "$FAKE_STATE/editor.path" 2>/dev/null)
if [[ -n $p1 ]]; then assert_no_file "$p1" "after a normal end the copy is gone"; else fail "the editor saw its copy"; fi
assert_eq "" "$(compgen -G "$SB/tmp/tmp.*")" "and so is its folder"
reset; EDITOR=true m files s1 edit notes.txt; assert_eq 0 "$RC" "an editor that changes nothing: exit 0"
assert_eq 0 "$(count_calls mcctl-tmp)" "and no write-back"
assert_contains "$OUT" "no changes" "and it says so"
reset; EDITOR=$SB/grow.sh m files s1 edit notes.txt; assert_eq 4 "$RC" "an edit that grows past 1 MB is refused"
assert_eq 0 "$(count_calls mcctl-tmp)" "and nothing is written"
canned stat 0 "2000000"$'\n'
reset; EDITOR=true m files s1 edit big.bin; assert_eq 4 "$RC" "a file over 1 MB is refused before the copy"
assert_eq 0 "$(count_calls ' cat -- ')" "and it is not copied"
canned stat 0 "4"$'\n'
rm -f -- "$FAKE_STATE/editor.path"
export EDITOR=$SB/hang.sh
# setsid gives mcctl its own process group (its pid is the group id), so the INT below reaches mcctl, its editor and nothing else
( cd "$R" && exec setsid ./mcctl files s1 edit notes.txt </dev/null ) >"$SB/int.out" 2>&1 &
pid=$!
for _ in $(seq 1 200); do [[ -s $FAKE_STATE/editor.path ]] && break; sleep 0.05; done
unset EDITOR
kill -INT -- "-$pid" 2>/dev/null
wait "$pid"; rc=$?
ip=$(cat "$FAKE_STATE/editor.path" 2>/dev/null)
if [[ -n $ip ]]; then
    pass "the editor started (the test can interrupt it)"
    assert_no_file "$ip" "after SIGINT the copy is gone"
else
    fail "the editor started (the test can interrupt it)" "$(cat "$SB/int.out" 2>/dev/null; calls | tail -n 3)"
fi
assert_eq "" "$(compgen -G "$SB/tmp/tmp.*")" "after SIGINT its folder is gone"
((rc != 0)) && pass "after SIGINT the command does not report success" || fail "after SIGINT the command does not report success"
canned cat 0; canned stat 0

echo "files ls: the same calls for a running and a stopped server, and no container question"
fake_server s1 s1 running
reset; m files s1 ls world; running=$(calls)
fake_gone s1 s1; fake_server s1 s1 stopped
reset; m files s1 ls world; stopped=$(calls)
assert_eq "$running" "$stopped" "running and stopped: the same calls"
assert_not_contains "$running" "docker ps" "no docker ps"
assert_not_contains "$running" "docker inspect" "no docker inspect"
fake_gone s1 s1

echo "a user value is one argument after the fixed script"
v='x y"$(id)";z'
reset; m files s1 cat "$v"
assert_eq "$v" "$(calls | grep 'alpine:3[.]20 sh -c' | sed 's/.* sh //')" "the check gets the value as its one argument"
assert_eq "$HELPER cat -- $v" "$(calls | tail -n 1)" "cat gets it after --, as one argument"

echo "files mkdir, mv"
canned test 1
reset; m files s1 mkdir backups; assert_eq 0 "$RC" "mkdir of a new folder"
assert_contains "$(calls)" "$HELPER mkdir -- backups" "the call is mkdir -- backups"
reset; m files s1 mv world/level.dat mods/x; assert_eq 0 "$RC" "mv to a new name"
assert_contains "$(calls)" "$HELPER mv -- world/level.dat mods/x" "the call is mv -- SRC DEST"
canned test 0
reset; m files s1 mv world/level.dat mods/x; assert_eq 4 "$RC" "mv onto an existing DEST is refused"
assert_eq 0 "$(count_calls ' mv -- ')" "and nothing was moved"
canned test 0

sandbox_cleanup
finish

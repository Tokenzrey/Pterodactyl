#!/usr/bin/env bash
# lib/mods.sh (mcctl mods, plugins, modrinth) and the list rendering of lib/compose.sh: the validators (C4), block_escape (C1, C3),
# the lists written and rendered, the attach points (C2), the type guards, sync (C6), --remove-installed (C5), the command names (E3).
# Docker is the fake: each test says which calls it expects, in order, and the flows in t_flows.sh assert the same for a whole run.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/mods.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
fake_cloudflare
load_config 2>/dev/null

# srv NAME [SERVER.ENV LINE...]: servers/NAME with the given server.env and no lists (renderer tests)
srv() {
    local n=$1; shift
    rm -rf -- "$SB/servers/$n"; mkdir -p "$SB/servers/$n/data"
    printf '%s\n' "$@" >"$SB/servers/$n/server.env"
}
# render NAME: OUT = stdout, ERR = stderr, RC = status
render() { OUT=$(render_server_compose "$@" 2>"$SB/err"); RC=$?; ERR=$(<"$SB/err"); }
# mk NAME TYPE: a stopped server as create leaves it (server.env, data/, the containers Docker answers for); no lists, no attach points
mk() {
    srv "$1" "TYPE=$2" 'VERSION=1.21.1' 'MEMORY=2G' 'CPUS=2' "HOSTNAME_SLUG=$1" 'EULA=TRUE'
    fake_server "$1" "$1" exited
}
# canned FORMAT OUT: what `docker inspect --format FORMAT ...` answers (the fake names the file after the sanitised FORMAT)
canned() { printf '%s\n' "$2" >"$FAKE_STATE/docker.inspect.${1//[^A-Za-z0-9_-]/_}"; }
LABEL_FMT='{{index .Config.Labels "mcctl.config_hash"}}'
STATE_FMT='{{.State.Status}}'
NAMECALL="docker ps -a -q --filter label=mcctl.name=fab"
reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }

echo "the three commands exist (E3: named here, no eval, no sudo)"
for f in cmd_mods cmd_plugins cmd_modrinth; do
    declare -F "$f" >/dev/null && pass "$f is defined in lib/mods.sh" || fail "$f is defined in lib/mods.sh"
done

echo "valid_mod_entry (C4): an https:// URL or a container path under /mods/ or /plugins/, 500 characters at most"
OK_ENTRIES=(https://x.example/a.jar https://cdn.example.net/p/a-1.2_3.jar https://x.example /mods/a.jar /plugins/common
            /mods/a..b /plugins/x/y.jar "https://x.example/$(printf 'a%.0s' $(seq 1 482))")
BAD_ENTRIES=(http://x.example/a.jar $'https://x.example/a\n.jar' 'https://x.example/a b.jar' 'https://x.example/a$.jar'
             'https://x.example/"a".jar' 'https://x.example/`a`.jar' "https://x.example/a'.jar" 'https://u:p@x.example/a.jar'
             'https://user@x.example/a.jar' 'https://' 'https:///a.jar' $'https://x.example/a\tb.jar' 'https://x.example/a\b.jar'
             /mods/../etc /mods/a/../../etc /etc/x /mods/ /plugins mods/a.jar a.jar '' ' /mods/a.jar' '/mods/a b.jar' '/mods/a$b.jar'
             "https://x.example/$(printf 'a%.0s' $(seq 1 483))")
bad=""
for e in "${OK_ENTRIES[@]}"; do valid_mod_entry "$e" || bad+=" refused:${e@Q}"; done
for e in "${BAD_ENTRIES[@]}"; do valid_mod_entry "$e" && bad+=" accepted:${e@Q}"; done
assert_eq "" "$bad" "valid_mod_entry: ${#OK_ENTRIES[@]} entries accepted and ${#BAD_ENTRIES[@]} refused, as the rule says"
out=$(valid_mod_entry 'https://x.example/a.jar' 2>&1); assert_eq "" "$out" "valid_mod_entry prints nothing (a yes/no check)"

echo "valid_modrinth_entry (C4)"
OK_SLUGS=(fabric-api lithium lithium:mc1.21-0.13.0 a 1 a_b-c:1.0 x:v.1)
BAD_SLUGS=("x y" A x: :1 x:y:z "" x/y x.y "x:a b" "$(printf 'a%.0s' $(seq 1 65))")
bad=""
for e in "${OK_SLUGS[@]}"; do valid_modrinth_entry "$e" || bad+=" refused:${e@Q}"; done
for e in "${BAD_SLUGS[@]}"; do valid_modrinth_entry "$e" && bad+=" accepted:${e@Q}"; done
assert_eq "" "$bad" "valid_modrinth_entry: ${#OK_SLUGS[@]} accepted and ${#BAD_SLUGS[@]} refused"

echo "block_escape (C1, C3): only \$ is special in a literal block"
assert_eq 'a\b"c' "$(block_escape 'a\b"c')" 'block_escape keeps a backslash and a quote (compose_escape would double them)'
assert_eq 'x$$y$${HOME}' "$(block_escape 'x$y${HOME}')" 'block_escape doubles every $'
assert_eq '{{NAME}} & !' "$(block_escape '{{NAME}} & !')" 'block_escape leaves the rest alone'
for v in $'a\tb' $'a\x01b' $'a\x7fb'; do
    out=$(block_escape "$v" 2>/dev/null); rc=$?
    [[ $rc -eq 2 && -z $out ]] && pass "block_escape refuses a control character ($(printf %q "$v")): exit 2, no output" \
        || fail "block_escape refuses a control character ($(printf %q "$v"))" "rc=$rc out=$out"
done

echo "list_file (the path of each list; a key that is not one of the three is refused)"
assert_eq "$SB/servers/fab/lists/mods.list" "$(list_file fab MODS)" "MODS is lists/mods.list"
assert_eq "$SB/servers/fab/lists/plugins.list" "$(list_file fab PLUGINS)" "PLUGINS is lists/plugins.list"
assert_eq "$SB/servers/fab/lists/modrinth_projects.list" "$(list_file fab MODRINTH_PROJECTS)" "MODRINTH_PROJECTS is lists/modrinth_projects.list"
out=$(list_file fab NOPE 2>/dev/null); rc=$?
[[ $rc -eq 2 && -z $out ]] && pass "another key is refused (exit 2)" || fail "another key is refused" "rc=$rc out=$out"
out=$(list_file ../x MODS 2>/dev/null); rc=$?
[[ $rc -eq 2 && -z $out ]] && pass "a bad server name is refused (exit 2)" || fail "a bad server name is refused" "rc=$rc"

echo "renderer: the list blocks (C1, C3)"
srv fab 'TYPE=FABRIC' 'VERSION=1.21.1' 'MEMORY=4G' 'CPUS=2' 'HOSTNAME_SLUG=fab' 'EULA=TRUE'
render fab; base=$OUT
assert_not_contains "$OUT" "MODS:" "an absent list file emits nothing"
mkdir -p "$SB/servers/fab/lists"
printf '%s\n' 'https://cdn.example.net/a.jar' '/mods/local.jar' >"$SB/servers/fab/lists/mods.list"
render fab
assert_contains "$OUT" $'      MODS: |\n        https://cdn.example.net/a.jar\n        /mods/local.jar\n    labels:' "MODS is a literal block, entries in file order, indented 8 spaces, before the labels"
printf '%s\n' 'https://x.example/a$b.jar' >"$SB/servers/fab/lists/mods.list"; render fab
assert_contains "$OUT" '        https://x.example/a$$b.jar' 'a hand-edited $ becomes $$ (C3: the validator refuses it, the renderer still escapes it)'
printf '%s\n' 'a\"b' >"$SB/servers/fab/lists/mods.list"; render fab
assert_contains "$OUT" '        a\"b' 'a backslash and a quote are kept as they are in a block (C1)'
printf 'https://x.example/a\001.jar\n' >"$SB/servers/fab/lists/mods.list"; render fab
[[ $RC -eq 4 && -z $OUT ]] && pass "a control character in a hand-edited list fails the render (exit 4, nothing emitted)" \
    || fail "a control character in a list fails the render" "rc=$RC out=${OUT:0:80}"
printf 'a\tb\n' >"$SB/servers/fab/lists/mods.list"; render fab
[[ $RC -eq 4 && -z $OUT ]] && pass "a tab in a list entry fails the render too" || fail "a tab in a list entry" "rc=$RC"
printf ' /mods/a.jar\n' >"$SB/servers/fab/lists/mods.list"; render fab
[[ $RC -eq 4 && -z $OUT && $ERR == *"starts with a space"* ]] && pass "a leading space fails the render, named (it would break the block's indentation)" \
    || fail "a leading space fails the render" "rc=$RC err=$ERR"
: >"$SB/servers/fab/lists/mods.list"; render fab
assert_contains "$OUT" $'      MODS: ""\n' "an empty list file renders MODS: \"\" (the --remove-installed state)"
printf '%s\n' '/plugins/common' >"$SB/servers/fab/lists/plugins.list"
printf '%s\n' 'fabric-api' 'lithium:mc1.21-0.13.0' >"$SB/servers/fab/lists/modrinth_projects.list"
render fab
assert_contains "$OUT" $'      MODS: ""\n      PLUGINS: |\n        /plugins/common\n      MODRINTH_PROJECTS: |\n        fabric-api\n        lithium:mc1.21-0.13.0\n    labels:' \
    "three lists, in the order MODS, PLUGINS, MODRINTH_PROJECTS"
rm -f -- "$SB/servers/fab/lists/mods.list" "$SB/servers/fab/lists/plugins.list" "$SB/servers/fab/lists/modrinth_projects.list"
assert_eq "$base" "$(render_server_compose fab 2>/dev/null)" "with no list file the render is what it was before lists existed"

echo "renderer: a list key may not also come from server.env or modpack.env"
printf '%s\n' 'https://x.example/a.jar' >"$SB/servers/fab/lists/mods.list"
printf 'MODS=https://y.example/b.jar\n' >>"$SB/servers/fab/server.env"; render fab
[[ $RC -eq 3 && -z $OUT && $ERR == *MODS* ]] && pass "MODS in server.env next to a MODS list: refused, named (exit 3)" || fail "MODS twice" "rc=$RC err=$ERR"
srv fab 'TYPE=FABRIC' 'EULA=TRUE' 'HOSTNAME_SLUG=fab'; mkdir -p "$SB/servers/fab/lists"
printf '%s\n' 'fabric-api' >"$SB/servers/fab/lists/modrinth_projects.list"
printf 'MODRINTH_PROJECTS=lithium\n' >"$SB/servers/fab/modpack.env"; render fab
[[ $RC -eq 3 && -z $OUT && $ERR == *MODRINTH_PROJECTS* ]] && pass "MODRINTH_PROJECTS in modpack.env next to the list: refused (exit 3)" || fail "MODRINTH_PROJECTS twice" "rc=$RC err=$ERR"
rm -f -- "$SB/servers/fab/modpack.env"; render fab; assert_eq 0 "$RC" "without the modpack line the list renders"
h1=$(config_hash fab)
printf '%s\n' 'fabric-api' 'lithium' >"$SB/servers/fab/lists/modrinth_projects.list"
[[ $(config_hash fab) != "$h1" ]] && pass "a list change changes config_hash (so it is pending)" || fail "a list change changes config_hash"

echo "commands: a list is the truth; add, remove, list, clear, and the type guards"
mk fab FABRIC; mk pap PAPER; rm -rf -- "$SB/servers/fab/lists"
reset
m mods fab add https://cdn.example.net/a.jar; assert_eq 0 "$RC" "mods add a URL: exit 0"
assert_contains "$OUT" "config pending: mcctl mods fab sync" "and says config pending"
assert_eq "$NAMECALL" "$(calls)" "the only call is the name check: nothing reaches Docker (the list is not rendered here)"
assert_eq "https://cdn.example.net/a.jar" "$(<"$SB/servers/fab/lists/mods.list")" "the list holds the entry"
m mods fab add https://cdn.example.net/a.jar; assert_eq 0 "$RC" "a duplicate add exits 0"
assert_contains "$OUT" "already in the list" "and says so"
assert_eq 1 "$(wc -l <"$SB/servers/fab/lists/mods.list")" "and the list still has one line"
m mods fab add /mods/zz.jar https://b.example/b.jar; assert_eq 0 "$RC" "two entries in one command"
assert_eq $'https://cdn.example.net/a.jar\n/mods/zz.jar\nhttps://b.example/b.jar' "$(<"$SB/servers/fab/lists/mods.list")" "they follow the file order: appended at the end"
m mods fab add http://x.example/a.jar; assert_eq 2 "$RC" "an http:// entry is refused: exit 2"
m mods fab add https://u:p@x.example/a.jar; assert_eq 2 "$RC" "a URL with credentials is refused: exit 2"
assert_eq 3 "$(wc -l <"$SB/servers/fab/lists/mods.list")" "and the list is as it was"
m mods fab remove /mods/zz.jar; assert_eq 0 "$RC" "remove an entry"
assert_contains "$OUT" "config pending: mcctl mods fab sync" "says config pending"
assert_not_contains "$OUT" "is empty now" "a list that still has entries gets no warning"
m mods fab remove /mods/zz.jar; assert_eq 1 "$RC" "a second remove fails: the entry is not there"
assert_contains "$OUT" "not in the list" "and says so"
m mods fab list; assert_eq 0 "$RC" "list"
assert_eq $'https://cdn.example.net/a.jar\nhttps://b.example/b.jar' "$(head -n 2 <<<"$OUT")" "list shows the declared list"
m mods fab; assert_eq 2 "$RC" "a missing verb is a usage error"
m mods fab bogus; assert_eq 2 "$RC" "an unknown verb is a usage error"
m mods fab list extra; assert_eq 2 "$RC" "list takes no argument"
m mods nosuch list; assert_eq 1 "$RC" "a server Docker does not have: exit 1"
assert_contains "$OUT" "no server named 'nosuch'" "and says so"
m mods fab remove https://cdn.example.net/a.jar https://b.example/b.jar; assert_eq 2 "$RC" "remove takes one entry"

echo "type guards: a mod on a plugin server and a plugin on a mod loader need --force"
m mods pap add https://cdn.example.net/m.jar; assert_eq 4 "$RC" "mods add on PAPER: refused (exit 4)"
assert_contains "$OUT" "PAPER is a plugin server" "and says why"
assert_eq "" "$(ls "$SB/servers/pap/lists" 2>/dev/null)" "nothing was written to the list"
m mods pap add --force https://cdn.example.net/m.jar; assert_eq 0 "$RC" "--force lifts the guard"
m plugins fab add https://p.example/p.jar; assert_eq 4 "$RC" "plugins add on FABRIC: refused (exit 4)"
m plugins fab add --force --hybrid https://p.example/p.jar; assert_eq 0 "$RC" "--force --hybrid: added"
assert_eq "USES_PLUGINS=true" "$(grep '^USES_PLUGINS=' "$SB/servers/fab/server.env")" "--hybrid writes USES_PLUGINS=true to server.env"
m mods pap add --hybrid https://cdn.example.net/m.jar; assert_eq 2 "$RC" "--hybrid is for plugins: a usage error on mods"
m plugins pap add https://p.example/p.jar; assert_eq 0 "$RC" "plugins add on PAPER: fine"
m mods fab add; assert_eq 2 "$RC" "add with nothing to add: a usage error"

echo "modrinth (C4): slugs, optionally with :version"
m modrinth fab add fabric-api; assert_eq 0 "$RC" "modrinth add fabric-api"
m modrinth fab add lithium:mc1.21-0.13.0; assert_eq 0 "$RC" "modrinth add lithium:mc1.21-0.13.0"
m modrinth fab add "x y"; assert_eq 2 "$RC" "a slug with a space is refused"
m modrinth fab add A; assert_eq 2 "$RC" "an upper-case slug is refused"
m modrinth fab add x:; assert_eq 2 "$RC" "an empty version is refused"
m modrinth fab list; assert_eq $'fabric-api\nlithium:mc1.21-0.13.0' "$(head -n 2 <<<"$OUT")" "modrinth list shows them in order"
m modrinth fab remove fabric-api; assert_eq 0 "$RC" "modrinth remove"
assert_eq "lithium:mc1.21-0.13.0" "$(<"$SB/servers/fab/lists/modrinth_projects.list")" "and the list keeps the other one"
m modrinth fab remove lithium:mc1.21-0.13.0; assert_eq 0 "$RC" "remove the last entry"
assert_contains "$OUT" "is empty now" "the list is empty now: the warning says what the next sync does"
assert_file "$SB/servers/fab/lists/modrinth_projects.list" "the empty file stays (it renders MODRINTH_PROJECTS: \"\")"
m modrinth fab clear; assert_eq 0 "$RC" "modrinth clear"
assert_no_file "$SB/servers/fab/lists/modrinth_projects.list" "clear without the flag deletes the list file"

echo "local jars: the attach point, not the list (C2)"
mkdir -p "$SB/jars"; printf 'PK\003\004 a jar' >"$SB/jars/a.jar"; printf 'MZ not a jar' >"$SB/jars/b.exe"
reset
m mods fab add "$SB/jars/a.jar"; assert_eq 0 "$RC" "a jar (PK, small) is added"
assert_contains "$OUT" "used at the next start" "and says when it takes effect"
assert_file "$SB/servers/fab/mods/a.jar" "the jar is in servers/fab/mods"
assert_mode "$SB/servers/fab/mods/a.jar" 644 "its mode is 644 (the game's user reads it through the read-only mount)"
assert_eq "" "$(grep -x 'a.jar' "$SB/servers/fab/lists/mods.list" 2>/dev/null)" "and it is not in the list"
assert_mode "$SB/servers/fab/mods" 755 "servers/fab/mods is made with mode 755 (Docker would make a root-owned one otherwise)"
m mods fab add "$SB/jars/b.exe"; assert_eq 4 "$RC" "a file that does not start with PK is refused (exit 4)"
assert_no_file "$SB/servers/fab/mods/b.exe" "and nothing is copied"
m mods fab add "$SB/jars"; assert_eq 2 "$RC" "a folder is refused (exit 2)"
m mods fab add "$SB/jars/nope.jar"; assert_eq 2 "$RC" "a missing file is refused, as a bad entry (exit 2)"
cp "$SB/jars/a.jar" "$SB/jars/-x.jar"; m mods fab add "$SB/jars/-x.jar"; assert_eq 4 "$RC" "a jar name that starts with '-' is refused (exit 4)"
{ printf 'PK'; } >"$SB/jars/big.jar"; truncate -s 209715201 "$SB/jars/big.jar"
m mods fab add "$SB/jars/big.jar"; assert_eq 4 "$RC" "a jar over 200 MB is refused (exit 4)"
assert_contains "$OUT" "more than 200 MB" "and says so"
printf 'PK\003\004 c' >"$SB/jars/c.jar"
m mods fab add "$SB/jars/c.jar" "$SB/jars/b.exe"; assert_eq 4 "$RC" "with two arguments, one bad: exit 4"
assert_no_file "$SB/servers/fab/mods/c.jar" "and the good one is not copied either (nothing changes unless all pass)"
m mods fab list; assert_contains "$OUT" "a.jar  (local file, not in the list)" "list shows the attach-point files after the list"
m mods fab remove a.jar; assert_eq 0 "$RC" "remove a local jar by its name"
assert_no_file "$SB/servers/fab/mods/a.jar" "the file is gone from the attach point"
m mods fab remove a.jar; assert_eq 1 "$RC" "a second remove of it fails"
m mods fab remove ../x; assert_eq 1 "$RC" "a name with '..' is not a file of the attach point: refused"

echo "installed: one docker run ls, and nothing else (works for a stopped server)"
printf 'a.jar\n' >"$FAKE_STATE/docker.run.ls"
reset; m mods fab installed; assert_eq 0 "$RC" "installed: exit 0"
assert_eq 2 "$(calls | wc -l)" "two calls: the name check and the one run"
assert_contains "$(calls | tail -n 1)" "alpine:3.20 ls -la -- mods" "the run lists data/mods inside the helper container"
assert_contains "$OUT" "a.jar" "and prints what it lists"
reset; m plugins pap installed; assert_eq 0 "$RC" "installed for plugins lists data/plugins: exit 0"
assert_contains "$(calls | tail -n 1)" "alpine:3.20 ls -la -- plugins" "(the run names plugins)"
echo 2 >"$FAKE_STATE/docker.run.ls.rc"
m mods fab installed; assert_eq 1 "$RC" "when the listing fails (no folder yet): exit 1, and it says so"
assert_contains "$OUT" "appears once the server has started" "with the reason"
rm -f -- "$FAKE_STATE/docker.run.ls" "$FAKE_STATE/docker.run.ls.rc"

echo "clear (C5): clear deletes the list; --remove-installed asks first and leaves an empty file"
printf '%s\n' 'https://cdn.example.net/a.jar' >"$SB/servers/fab/lists/mods.list"
printf 'PK\003\004 keep' >"$SB/servers/fab/mods/keep.jar"
reset; m mods fab clear; assert_eq 0 "$RC" "clear"
assert_no_file "$SB/servers/fab/lists/mods.list" "the list file is gone"
assert_file "$SB/servers/fab/mods/keep.jar" "and the jars are left alone"
assert_eq "$NAMECALL" "$(calls)" "clear makes no Docker call beyond the name check"
printf '%s\n' 'https://cdn.example.net/a.jar' >"$SB/servers/fab/lists/mods.list"
m mods fab clear --remove-installed; assert_eq 4 "$RC" "--remove-installed without --yes: declined, refused (exit 4)"
assert_eq "https://cdn.example.net/a.jar" "$(<"$SB/servers/fab/lists/mods.list")" "and the list is as it was"
m --yes mods fab clear --remove-installed; assert_eq 0 "$RC" "--remove-installed --yes: done"
assert_file "$SB/servers/fab/lists/mods.list" "the list file is kept, empty"
assert_eq 0 "$(wc -c <"$SB/servers/fab/lists/mods.list")" "and it has no bytes"
render fab; assert_contains "$OUT" $'      MODS: ""\n' "and it renders MODS: \"\""
assert_file "$SB/servers/fab/mods/keep.jar" "the local jar is still there (its removal is itzg's business at the next start, unverified)"
rm -f -- "$SB/servers/fab/lists/mods.list"; rm -f -- "$SB/servers/fab/mods/keep.jar"

echo "sync (C6): sync is apply_pending; with nothing pending and --restart it restarts after the guard"
m mods fab add https://cdn.example.net/a.jar; assert_eq 0 "$RC" "a pending change"
reset; canned "$LABEL_FMT" "old-config"; canned "$STATE_FMT" exited
m --yes mods fab sync; assert_eq 0 "$RC" "sync with a pending change: exit 0"
assert_eq "$NAMECALL
docker inspect --format {{index .Config.Labels \"mcctl.config_hash\"}} mc-fab
docker inspect --format {{index .Config.Labels \"mcctl.config_hash\"}} mc-fab
docker inspect --format {{.State.Status}} mc-fab
docker compose -p mcctl-fab -f $SB/servers/fab/compose.yaml create --force-recreate" "$(calls)" "the calls of apply_pending: the label, then the recreate (stopped: create --force-recreate)"
assert_contains "$(<"$SB/servers/fab/compose.yaml")" $'      MODS: |\n        https://cdn.example.net/a.jar\n' "compose.yaml now carries the list"
assert_mode "$SB/servers/fab/mods" 755 "and the attach points of a server made before them exist now (sync makes them, mode 755)"
assert_mode "$SB/servers/fab/plugins" 755 "plugins too"
reset; canned "$LABEL_FMT" "$(config_hash fab)"
m mods fab sync; assert_eq 0 "$RC" "sync with nothing pending: exit 0"
assert_contains "$OUT" "nothing to apply" "says so"
assert_eq 0 "$(grep -c ' compose ' <<<"$(calls)")" "and makes no compose call"
reset; canned "$STATE_FMT" running; printf 'There are 0 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
m --yes mods fab sync --restart; assert_eq 0 "$RC" "sync --restart with nothing pending: exit 0"
assert_eq "$NAMECALL
docker inspect --format {{index .Config.Labels \"mcctl.config_hash\"}} mc-fab
docker inspect --format {{.State.Status}} mc-fab
docker exec -i mc-fab rcon-cli list
docker compose -p mcctl-fab -f $SB/servers/fab/compose.yaml restart" "$(calls)" "it asks the guard (the state, who is online), then runs compose restart, and nothing else"
printf 'There are 2 of a max of 20 players online: \n' >"$FAKE_STATE/docker.exec"
reset; m mods fab sync --restart; assert_eq 4 "$RC" "sync --restart with 2 players online and no --yes: refused (exit 4)"
assert_not_contains "$(calls)" " restart" "and nothing is restarted"
m mods fab sync extra; assert_eq 2 "$RC" "sync takes at most --restart"
rm -f -- "$FAKE_STATE/docker.exec" "$FAKE_STATE"/docker.inspect*

echo "a write that fails leaves the old list (E11)"
printf '%s\n' 'https://cdn.example.net/a.jar' >"$SB/servers/fab/lists/mods.list"
chmod 500 "$SB/servers/fab/lists"
if [[ -w $SB/servers/fab/lists ]]; then
    skip "E11: this user can write a read-only folder (root, or no POSIX modes)"
else
    m mods fab add https://cdn.example.net/z.jar; assert_eq 1 "$RC" "the list folder is read-only: the add fails (exit 1)"
    assert_eq "https://cdn.example.net/a.jar" "$(<"$SB/servers/fab/lists/mods.list")" "and the old list is as it was"
fi
chmod 700 "$SB/servers/fab/lists"; rm -f -- "$SB/servers/fab/lists/mods.list"

echo "the lists stay private to the server (mode 600 on the list, the folder made 700 by umask)"
m mods fab add https://cdn.example.net/a.jar >/dev/null 2>&1
assert_mode "$SB/servers/fab/lists/mods.list" 600 "the list file is 600"
rm -f -- "$SB/servers/fab/lists/mods.list"

sandbox_cleanup
finish

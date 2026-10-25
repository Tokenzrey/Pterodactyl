#!/usr/bin/env bash
# lib/common.sh: archive_safe_members (E8, C2), the one checker that backup restore, world restore and world import all run before
# they extract anything. Every fixture in tests/fixtures/archives is checked: the safe ones pass (a..b is a legal name), each hostile
# one is refused and named, an unreadable file is 2. No Docker here; the callers' own refusals are in t_worlds.sh and t_backup.sh.
# E8 (Task 21): `mcctl import` refuses the same hostile fixtures with exit 4 before any Docker call (the last section).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
FX=$REPO/tests/fixtures/archives
T=$(mktemp -d) || exit 1

asm() { OUT=$(archive_safe_members "$1" 2>&1); RC=$?; }

echo "fixtures: the set the checks below read (made by make_archives.py, committed)"
for f in clean names symlink symlink-rel hardlink abs-path dotdot device newline owner-newline mixed empty; do
    assert_file "$FX/$f.tar.gz" "$f.tar.gz is committed"
done

echo "safe archives: regular files and directories with relative names (a..b is legal, names with dots and spaces too)"
asm "$FX/clean.tar.gz"; assert_eq "0:" "$RC:$OUT" "clean.tar.gz: 0, nothing printed"
asm "$FX/names.tar.gz"; assert_eq "0:" "$RC:$OUT" "names.tar.gz (a..b, ..c, c.., my file.dat): 0, nothing printed"
asm "$FX/empty.tar.gz"; assert_eq "0:" "$RC:$OUT" "an archive with no members: 0"

echo "hostile archives: each is 1, and the bad member is named with the reason"
asm "$FX/symlink.tar.gz"
assert_eq 1 "$RC" "an absolute symbolic link: 1"
assert_contains "$OUT" "unsafe member 'world/escape': a symbolic link" "named, as a symbolic link"
asm "$FX/symlink-rel.tar.gz"
assert_eq 1 "$RC" "a relative symbolic link (../..): 1"
assert_contains "$OUT" "unsafe member 'world/escape': a symbolic link" "named, as a symbolic link"
asm "$FX/hardlink.tar.gz"
assert_eq 1 "$RC" "a hard link: 1 (the first column of tar -tv is h, not -)"
assert_contains "$OUT" "unsafe member 'world/copy': a hard link" "named, as a hard link"
asm "$FX/abs-path.tar.gz"
assert_eq 1 "$RC" "an absolute path: 1"
assert_contains "$OUT" "unsafe member '/tmp/mcctl-abs-escape': an absolute path" "named"
asm "$FX/dotdot.tar.gz"
assert_eq 1 "$RC" "a .. component: 1"
assert_contains "$OUT" "'../escape': a path with a .. component" "../x is named"
assert_contains "$OUT" "'world/../../escape2': a path with a .. component" "x/../../y is named"
assert_contains "$OUT" "'world/../': a path with a .. component" "x/.. is named"
asm "$FX/device.tar.gz"
assert_eq 1 "$RC" "a character device: 1"
assert_contains "$OUT" "unsafe member 'world/null': of type 'c'" "named, with its type"
asm "$FX/newline.tar.gz"
assert_eq 1 "$RC" "a newline in a member name (newline-name): 1"
assert_contains "$OUT" "unsafe member 'world/a\\nb'" "named, escaped"
asm "$FX/owner-newline.tar.gz"
assert_eq 1 "$RC" "a newline in an owner name: the two listings cannot be paired: 1"
assert_contains "$OUT" "listings differ in length" "and it says so"

echo "unreadable input: 2, with a message"
echo "not a tar.gz" >"$T/not.tar.gz"
asm "$T/not.tar.gz"; assert_eq 2 "$RC" "a file that is not a gzip tar: 2"
assert_contains "$OUT" "cannot list" "and says so"
asm "$T/no-such.tar.gz"; assert_eq 2 "$RC" "a missing file: 2"

echo "the one checker: no copy of it is left in lib/"
assert_eq "" "$(grep -rl '_backup_safe_members' "$REPO/lib" 2>/dev/null)" "_backup_safe_members is gone (C2: backup restore calls archive_safe_members)"
grep -q 'archive_safe_members' "$REPO/lib/backup.sh" && pass "lib/backup.sh calls archive_safe_members" || fail "lib/backup.sh calls archive_safe_members"

echo "import (E8, Task 21): every hostile fixture is refused by the same check, before any Docker call and before any extraction"
sandbox
for f in symlink symlink-rel hardlink abs-path dotdot device newline owner-newline; do
    : >"$FAKE_STATE/calls.log"; T_UNK=0
    m import "$FX/$f.tar.gz"
    assert_eq 4 "$RC" "import $f.tar.gz: exit 4"
    if [[ $f == owner-newline ]]; then
        assert_contains "$OUT" "listings differ in length" "import owner-newline.tar.gz: refused, its two listings cannot be paired (named)"
    else
        assert_contains "$OUT" "unsafe member" "import $f.tar.gz: the member is named"
    fi
    assert_eq "" "$(calls)" "import $f.tar.gz: no Docker call (nothing was asked or extracted)"
    assert_eq "" "$(ls -A "$SB/servers" 2>/dev/null)" "import $f.tar.gz: no server folder"
done
: >"$FAKE_STATE/calls.log"; T_UNK=0
m import "$FX/clean.tar.gz"
assert_eq 4 "$RC" "a safe archive that is not an export (a world/ at the top) is refused too (exit 4)"
assert_contains "$OUT" "'world/' at its top level, which an export never writes" "and it says why (the top-level names are checked first)"
assert_eq "" "$(calls)" "and still no Docker call"
sandbox_cleanup

rm -rf -- "$T"
finish

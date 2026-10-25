#!/usr/bin/env bash
# lib/common.sh: name rules and the secret writer.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
sandbox

assert_eq "kampung-2"  "$(slugify 'Kampung 2!')"        "slug of a name with punctuation"
assert_eq ""           "$(slugify '!!!')"               "slug of punctuation only is empty"
assert_eq "$(printf 'a%.0s' {1..40})" "$(slugify "$(printf 'a%.0s' {1..60})")" "slug is cut to 40 characters"
valid_server_name "survival-1"  && pass "valid name accepted"  || fail "valid name accepted"
valid_server_name "Survival"    && fail "upper case refused"   || pass "upper case refused"
valid_server_name ""            && fail "empty refused"        || pass "empty refused"
write_secret "$SB/s" "v"; assert_mode "$SB/s" 600 "write_secret sets mode 600"

echo "write_atomic (E11)"
D=$SB/wa; mkdir "$D"
listing() { ls -A "$D" | paste -sd, -; }
echo "old" >"$D/f"
write_atomic "$D/f" printf '%s
' "new" "lines"
assert_eq $'new
lines' "$(<"$D/f")" "write_atomic PATH CMD: the output of CMD replaces the file"
assert_eq "f" "$(listing)" "and no temp file is left"
printf 'from stdin
' | write_atomic "$D/g"
assert_eq "from stdin" "$(<"$D/g")" "write_atomic PATH: reads stdin when there is no CMD, and creates the file"
assert_mode "$D/g" 600 "the new file is mode 600 (private by default)"
gen() { echo "from a function"; }
write_atomic "$D/f" gen; assert_eq "from a function" "$(<"$D/f")" "CMD may be a shell function"
write_atomic "$D/f" sh -c 'echo partial; exit 3' 2>/dev/null; assert_eq 3 $? "a failing producer: write_atomic returns its status"
assert_eq "from a function" "$(<"$D/f")" "and the previous file is unchanged (the partial output never reached it)"
assert_eq "f,g" "$(listing)" "and no *.tmp is left behind"
write_atomic "$D/fresh" false 2>/dev/null; assert_eq 1 $? "a failing producer for a file that does not exist yet fails too"
assert_no_file "$D/fresh" "and creates nothing"; assert_eq "f,g" "$(listing)" "and no *.tmp either"
write_atomic "$D/f" sh -c 'exit 0'; assert_eq "" "$(<"$D/f")" "a producer that succeeds with no output empties the file"
write_atomic "$D/with space" printf 'x
'; assert_eq "x" "$(<"$D/with space")" "a path with a space"
write_atomic "$D/nodir/x" printf 'x
' 2>/dev/null; assert_eq 1 $? "a missing directory fails"
write_atomic "$D" printf 'x
' 2>/dev/null; assert_eq 1 $? "a directory as the target is refused (mv would move the temp file into it)"
write_atomic "" printf 'x
' 2>/dev/null; assert_eq 1 $? "an empty path is refused"
assert_eq "f,g,with space" "$(listing)" "the directory holds exactly the files written, nothing else"

sandbox_cleanup
finish

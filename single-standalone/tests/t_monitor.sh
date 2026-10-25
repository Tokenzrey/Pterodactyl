#!/usr/bin/env bash
# lib/monitor.sh: render_bar, render_top_frame, cmd_top. E10: widths under LC_ALL=C.UTF-8 and LC_ALL=C.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/data.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/servers.sh"
source "$REPO/lib/monitor.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
unset NO_COLOR
load_config 2>/dev/null

reset() { : >"$FAKE_STATE/calls.log"; T_UNK=0; }

count_filled() {
    local out=$1
    if [[ $(locale charmap 2>/dev/null) == UTF-8 ]]; then
        local fc=$'\xe2\x96\x88'
        local temp=${out//"$fc"/X}
        temp=${temp//[^X]/}
        printf '%s' "${#temp}"
    else
        local temp=${out//[^#]/}
        printf '%s' "${#temp}"
    fi
}

echo "render_bar: filled cells, clamping, edge cases"
for loc in C.UTF-8 C; do
    export LC_ALL=$loc
    b=$(NO_COLOR=1 render_bar 50 10); assert_eq 5  "$(count_filled "$b")" "render_bar 50 10 has 5 filled ($loc)"
    assert_eq 10 "${#b}" "render_bar 50 10 has 10 visible cells ($loc)"
    b=$(NO_COLOR=1 render_bar 0 10);  assert_eq 0  "$(count_filled "$b")" "render_bar 0 10 all empty ($loc)"
    b=$(NO_COLOR=1 render_bar 100 10); assert_eq 10 "$(count_filled "$b")" "render_bar 100 10 all filled ($loc)"
    b=$(NO_COLOR=1 render_bar 150 10); assert_eq 10 "$(count_filled "$b")" "render_bar 150 10 clamps to full ($loc)"
    b=$(NO_COLOR=1 render_bar -5 10);  assert_eq 0  "$(count_filled "$b")" "render_bar -5 10 clamps to empty ($loc)"
    b=$(NO_COLOR=1 render_bar 49.6 10); assert_eq 5 "$(count_filled "$b")" "render_bar 49.6 10 gives 5 ($loc)"
    b=$(NO_COLOR=1 render_bar 50% 10); assert_eq 5  "$(count_filled "$b")" "render_bar 50% works ($loc)"
    b=$(NO_COLOR=1 render_bar 50 1);   assert_eq 1  "${#b}" "render_bar 50 1 does not crash ($loc)"
    b=$(NO_COLOR=1 render_bar 50 0);   assert_eq 0  "${#b}" "render_bar 50 0 prints nothing ($loc)"
done
unset LC_ALL

echo "render_bar: colour thresholds"
b=$(render_bar 59 10);  assert_contains "$b" $'\033[32m' "59 is green"
b=$(render_bar 60 10);  assert_contains "$b" $'\033[33m' "60 is yellow"
b=$(render_bar 84 10);  assert_contains "$b" $'\033[33m' "84 is yellow"
b=$(render_bar 85 10);  assert_contains "$b" $'\033[31m' "85 is red"
b=$(render_bar 100 10); assert_contains "$b" $'\033[31m' "100 is red"

echo "render_top_frame: structure"
export LC_ALL=C.UTF-8
input=$(printf 'b\t2.34%%\t200MiB\t1GiB\t20.00%%\t2kB / 3kB\t4kB / 5kB\na\t1.23%%\t100MiB\t1GiB\t10.00%%\t1kB / 2kB\t3kB / 4kB\nc\t-\t-\t-\t-\t-\t-\n')
frame=$(NO_COLOR=1 COLUMNS=120 render_top_frame <<<"$input")
assert_contains "$frame" "a" "frame contains server a"
assert_contains "$frame" "b" "frame contains server b"
assert_contains "$frame" "c" "frame contains server c"
assert_contains "$frame" "total" "frame has a totals row"
assert_contains "$frame" "NAME" "frame has a header"
assert_contains "$frame" "servers" "frame has a summary"
lines=$(strip_ansi "$frame")
a_line=$(grep -n '1.23%' <<<"$lines" | head -1 | cut -d: -f1)
b_line=$(grep -n '2.34%' <<<"$lines" | head -1 | cut -d: -f1)
c_line=$(grep -n 'c ' <<<"$lines" | head -1 | cut -d: -f1)
[[ -n $a_line && -n $b_line && -n $c_line && $a_line -lt $b_line && $b_line -lt $c_line ]] \
    && pass "rows sorted by name" || fail "rows sorted by name" "a=$a_line b=$b_line c=$c_line"
c_row=$(sed -n "${c_line}p" <<<"$lines")
assert_contains "$c_row" "-" "stopped server shows -"
unset LC_ALL

echo "render_top_frame: E10 widths"
input=$(printf 'a\t1.23%%\t100MiB\t1GiB\t10.00%%\t1kB / 2kB\t3kB / 4kB\nb\t2.34%%\t200MiB\t1GiB\t20.00%%\t2kB / 3kB\t4kB / 5kB\n')
for loc in C.UTF-8 C; do
    export LC_ALL=$loc
    for cols in 80 120 200 40; do
        frame=$(NO_COLOR=1 COLUMNS=$cols render_top_frame <<<"$input")
        expected=$cols; ((expected > 140)) && expected=140; ((expected < 60)) && expected=60
        all_ok=1; bad_w=0
        while IFS= read -r line; do
            [[ -z $line ]] && continue
            w=${#line}
            if ((w != expected)); then all_ok=0; bad_w=$w; break; fi
        done <<<"$frame"
        ((all_ok)) && pass "COLUMNS=$cols $loc: all lines width $expected" \
                  || fail "COLUMNS=$cols $loc: all lines width $expected" "got width $bad_w"
    done
done
unset LC_ALL
export LC_ALL=C.UTF-8
frame80=$(NO_COLOR=1 COLUMNS=80 render_top_frame <<<"$input")
frame120=$(NO_COLOR=1 COLUMNS=120 render_top_frame <<<"$input")
assert_contains "$frame120" "NET" "COLUMNS=120 has NET column"
assert_contains "$frame120" "BLOCK" "COLUMNS=120 has BLOCK column"
assert_not_contains "$frame80" "NET" "COLUMNS=80 has no NET column"
assert_not_contains "$frame80" "BLOCK" "COLUMNS=80 has no BLOCK column"
unset LC_ALL

echo "render_top_frame: NO_COLOR and long name"
input=$(printf 'a\t1.23%%\t100MiB\t1GiB\t10.00%%\t1kB / 2kB\t3kB / 4kB\n')
frame=$(NO_COLOR=1 render_top_frame <<<"$input")
assert_not_contains "$frame" $'\033' "NO_COLOR=1: no ESC byte in frame"
longname=$(printf 'a%.0s' {1..40})
input=$(printf '%s\t1.23%%\t100MiB\t1GiB\t10.00%%\t1kB / 2kB\t3kB / 4kB\n' "$longname")
for loc in C.UTF-8 C; do
    export LC_ALL=$loc
    frame=$(NO_COLOR=1 COLUMNS=80 render_top_frame <<<"$input")
    all_ok=1; bad_w=0
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        if ((${#line} != 80)); then all_ok=0; bad_w=${#line}; break; fi
    done <<<"$frame"
    ((all_ok)) && pass "40-char name: box intact ($loc)" || fail "40-char name: box intact ($loc)" "line width $bad_w"
done
unset LC_ALL

echo "render_top_frame: F1 a CPU or MEM of 100% or more keeps every line W wide, and the bar stays"
input=$(printf 'a\t800.00%%\t100MiB\t1GiB\t100.00%%\t1kB / 2kB\t3kB / 4kB\nb\t1600.00%%\t200MiB\t1GiB\t100.00%%\t2kB / 3kB\t4kB / 5kB\n')
for loc in C.UTF-8 C; do
    export LC_ALL=$loc
    bar=$'\xe2\x96\x88'; [[ $loc == C ]] && bar='#'
    for cols in 80 120 200; do
        frame=$(NO_COLOR=1 COLUMNS=$cols render_top_frame <<<"$input")
        stripped=$(strip_ansi "$frame")
        expected=$cols; ((expected > 140)) && expected=140
        all_ok=1; bad_w=0
        while IFS= read -r line; do
            [[ -z $line ]] && continue
            if ((${#line} != expected)); then all_ok=0; bad_w=${#line}; break; fi
        done <<<"$stripped"
        ((all_ok)) && pass "COLUMNS=$cols $loc: 800% and 1600% rows: all lines width $expected" \
                  || fail "COLUMNS=$cols $loc: 800% and 1600% rows: all lines width $expected" "got width $bad_w"
        assert_contains "$stripped" "800.00%" "COLUMNS=$cols $loc: the value 800.00% is shown whole"
        row=$(grep '1600.00%' <<<"$stripped")
        assert_contains "$row" "$bar" "COLUMNS=$cols $loc: the 1600.00% row keeps its bar"
    done
done
unset LC_ALL

echo "cmd_top: end to end with fakes"
reset
fake_server a a running
fake_server b b running
printf 'mc-a|1.23%%|100MiB / 1GiB|10.00%%|1kB / 2kB|3kB / 4kB\nmc-b|2.34%%|200MiB / 1GiB|20.00%%|2kB / 3kB|4kB / 5kB\n' >"$FAKE_STATE/docker.stats"
m top; assert_eq 0 "$RC" "top exit 0"
assert_contains "$OUT" "a" "top shows server a"
assert_contains "$OUT" "b" "top shows server b"
assert_contains "$(calls)" "docker ps -a --filter label=mcctl.managed=true" "top queries server list"
assert_contains "$(calls)" "docker stats --no-stream" "top calls docker stats"
assert_contains "$(calls)" "mc-a mc-b" "docker stats called with mc-a mc-b"

reset
fake_server a a running
fake_server b b stopped
printf 'mc-a|1.23%%|100MiB / 1GiB|10.00%%|1kB / 2kB|3kB / 4kB\n' >"$FAKE_STATE/docker.stats"
m top; assert_eq 0 "$RC" "top with stopped server exit 0"
assert_contains "$OUT" "a" "top shows running server a"
assert_contains "$OUT" "b" "top shows stopped server b"
assert_not_contains "$(calls)" "mc-b" "stopped server not in docker stats call"

reset
fake_server s1 s1 running
printf 'mc-s1|1.23%%|100MiB / 1GiB|10.00%%|1kB / 2kB|3kB / 4kB\n' >"$FAKE_STATE/docker.stats"
m top s1; assert_eq 0 "$RC" "top s1 exit 0"
assert_contains "$OUT" "s1" "top s1 shows s1"

m top nope; assert_eq 1 "$RC" "top nope exit 1"

MCCTL_REFRESH=0 m top;   assert_eq 2 "$RC" "MCCTL_REFRESH=0 exit 2"
MCCTL_REFRESH=abc m top; assert_eq 2 "$RC" "MCCTL_REFRESH=abc exit 2"
MCCTL_REFRESH=-1 m top;  assert_eq 2 "$RC" "MCCTL_REFRESH=-1 exit 2"
MCCTL_REFRESH=1e3 m top; assert_eq 2 "$RC" "MCCTL_REFRESH=1e3 exit 2"

echo "cmd_top: failing docker stats"
reset
fake_server s1 s1 running
printf 'mc-s1|1.23%%|100MiB / 1GiB|10.00%%|1kB / 2kB|3kB / 4kB\n' >"$FAKE_STATE/docker.stats"
echo 1 >"$FAKE_STATE/docker.stats.rc"
m top; assert_eq 0 "$RC" "failing stats: exit 0"
assert_contains "$OUT" "note:" "failing stats: note appears"
rm -f "$FAKE_STATE/docker.stats.rc"

echo "cmd_top: no cursor codes when not a terminal"
reset
fake_server s1 s1 running
printf 'mc-s1|1.23%%|100MiB / 1GiB|10.00%%|1kB / 2kB|3kB / 4kB\n' >"$FAKE_STATE/docker.stats"
m top
assert_not_contains "$OUT" $'\033[H' "no cursor home code"
assert_not_contains "$OUT" $'\033[?1049h' "no alt screen code"

echo "cmd_top: F6 a running server whose stats are missing is counted as running"
reset
rm -f "$FAKE_STATE/docker.ps.label_mcctl_managed_true"
fake_server a a running
fake_server b b running
printf 'mc-a|1.23%%|100MiB / 1GiB|10.00%%|1kB / 2kB|3kB / 4kB\n' >"$FAKE_STATE/docker.stats"
m top; assert_contains "$OUT" "running 2," "b has no stats line and is still counted as running"
echo 1 >"$FAKE_STATE/docker.stats.rc"
m top; assert_contains "$OUT" "running 2," "docker stats failing: both are still counted as running"
rm -f "$FAKE_STATE/docker.stats.rc"

echo "cmd_top: F2 docker ps failing on the first frame: the message, no alternate screen"
reset
fake_server s1 s1 running
echo 1 >"$FAKE_STATE/docker.ps.label_mcctl_managed_true.rc"
m top; assert_eq 1 "$RC" "docker ps fails: exit 1"
assert_contains "$OUT" "'docker ps' failed" "the message names docker ps"
assert_not_contains "$OUT" $'\033[?1049h' "no alternate-screen code"
rm -f "$FAKE_STATE/docker.ps.label_mcctl_managed_true.rc"

echo "E3: cmd_top named in tests"
declare -F cmd_top >/dev/null && pass "cmd_top exists" || fail "cmd_top exists"

sandbox_cleanup
finish

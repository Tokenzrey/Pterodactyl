#!/usr/bin/env bash
# Runs every tests/t_*.sh (or the files named on the command line) in its own process. Needs only bash and coreutils.
# Run it as:  DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/run.sh
# It refuses to start unless DOCKER_HOST is a socket that does not exist and the fakes win on PATH (assert_fakes_first), and it
# fails any test file that recorded zero assertions (a file that silently does nothing is not a pass).
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./lib.sh

case ${DOCKER_HOST:-} in
    unix:///nonexistent*) ;;
    *) echo "FATAL: DOCKER_HOST must point at a socket that does not exist (DOCKER_HOST=unix:///nonexistent). Refusing to run." >&2; exit 99 ;;
esac
( sandbox; sandbox_cleanup ) || exit 99   # exits 99 itself when a fake does not come first on PATH

counts=$(mktemp) || exit 1
trap 'rm -f -- "$counts"' EXIT
export MCCTL_TEST_COUNTS=$counts

files=("$@")
((${#files[@]})) || files=(t_*.sh)
P=0 F=0 S=0
for t in "${files[@]}"; do
    printf '\n== %s\n' "$t"
    : >"$counts"
    bash "$t"; rc=$?
    p=0 f=0 s=0
    read -r _ p f s <<<"$(tail -n 1 "$counts")"
    if ((p + f + s == 0)); then
        printf '  FAIL %s records zero assertions\n' "$t"; F=$((F + 1))
    elif ((rc != 0 && f == 0)); then
        printf '  FAIL %s exited %d without a failed assertion\n' "$t" "$rc"; F=$((F + 1))
    fi
    P=$((P + p)) F=$((F + f)) S=$((S + s))
done
printf '\n%d passed, %d failed, %d skipped\n' "$P" "$F" "$S"
((F == 0))

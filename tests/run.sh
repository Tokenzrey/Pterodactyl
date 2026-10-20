#!/usr/bin/env bash
# Runs every tests/t_*.sh in its own process. Needs only bash, python3 and coreutils (docker is faked).
# Optional extras: `docker` for compose-file and shellcheck lint (t_static.sh skips them when absent).
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
rc=0
for t in ${1:-t_*.sh}; do
    printf '\n== %s\n' "$t"
    bash "$t" || rc=1
done
printf '\n%s\n' "$([[ $rc -eq 0 ]] && echo 'ALL TEST FILES PASSED' || echo 'SOME TESTS FAILED')"
exit $rc

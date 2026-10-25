#!/usr/bin/env bash
# Runs the test files in parallel: one `run.sh FILE` per file, JOBS at a time (default 12), then adds the totals in file order.
# Each run.sh keeps its own assertion counter and sandboxes (mktemp), so the files do not share state. Same guards as run.sh.
# Usage:  DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/run-par.sh [-j N] [t_file.sh ...]
# Exit status 0 only when every file exits 0 and reports a summary line with no failed assertion.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

case ${DOCKER_HOST:-} in
    unix:///nonexistent*) ;;
    *) echo "FATAL: DOCKER_HOST must point at a socket that does not exist (DOCKER_HOST=unix:///nonexistent). Refusing to run." >&2; exit 99 ;;
esac

jobs=${JOBS:-12}
if [[ ${1-} == -j ]]; then jobs=${2-}; shift 2; fi
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "FATAL: -j needs a number of jobs" >&2; exit 2; }

files=("$@")
((${#files[@]})) || files=(t_*.sh)

out=$(mktemp -d) || exit 1
trap 'rm -rf -- "$out"' EXIT

# one run.sh per file, output and status kept in $out/<file>.log and $out/<file>.rc
printf '%s\n' "${files[@]}" | xargs -P "$jobs" -I{} bash -c 'bash ./run.sh "$1" >"$2/$1.log" 2>&1; echo $? >"$2/$1.rc"' _ {} "$out"

P=0 F=0 S=0 bad=0
for t in "${files[@]}"; do
    cat -- "$out/$t.log" 2>/dev/null || echo "FAIL $t: no output"
    rc=$(cat -- "$out/$t.rc" 2>/dev/null || echo 99)
    line=$(grep -E '^[0-9]+ passed, [0-9]+ failed, [0-9]+ skipped$' "$out/$t.log" 2>/dev/null | tail -n 1)
    if [[ -z $line ]]; then
        printf '  FAIL %s: no summary line (exit %s)\n' "$t" "$rc"; bad=$((bad + 1)); continue
    fi
    read -r p _ f _ s _ <<<"$line"
    P=$((P + p)) F=$((F + f)) S=$((S + s))
    ((rc == 0)) || { printf '  FAIL %s: exit %s\n' "$t" "$rc"; bad=$((bad + 1)); }
done

printf '\n%d passed, %d failed, %d skipped (%d files, %d jobs)\n' "$P" "$F" "$S" "${#files[@]}" "$jobs"
((F == 0 && bad == 0))

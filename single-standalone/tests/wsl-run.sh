#!/usr/bin/env bash
# Runs the mcctl tests in WSL, in a disposable copy on the Linux filesystem: fast fork, real file modes, jq installed.
# No live Docker: DOCKER_HOST is a socket that does not exist, and every test sandboxes its own MCCTL_ROOT.
# Each run gets its own directory, so several runs can go at once.
# Run it from Windows through WSL, for example (the path is the Windows tree seen from WSL):
#   wsl.exe bash -c 'bash /mnt/d/Documents/code/pterodactyl/single-standalone/tests/wsl-run.sh t_sftp.sh t_edit.sh'
# With no file names it runs the whole suite. Prints the time, every failing file or assertion, and the totals.
set -u
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
SRC=$(cd -- "$here/.." && pwd -P) || exit 1
DST=$(mktemp -d "$HOME/mcctl-run.XXXXXX") || exit 1
# remove only this run's directory: DST came from mktemp under $HOME, and the case guard refuses anything else
cleanup() { case $DST in "$HOME"/mcctl-run.*) rm -rf -- "$DST" ;; esac; }
trap cleanup EXIT
mkdir -p -- "$DST/single-standalone"
# the whole tree, docs included: tests/t_docs.sh checks the docs themselves
tar -C "$SRC" -cf - . | tar -C "$DST/single-standalone" -xf - || { echo "copy failed"; exit 1; }
cd -- "$DST/single-standalone" || exit 1
chmod +x mcctl tests/run.sh tests/run-par.sh tests/wsl-run.sh tests/fakebin/* 2>/dev/null
export DOCKER_HOST=unix:///nonexistent
jobs=$(nproc 2>/dev/null || echo 8)
start=$(date +%s.%N)
bash tests/run-par.sh -j "$jobs" "$@" > "$DST/out.txt" 2>&1
rc=$?
end=$(date +%s.%N)
echo "rc=$rc jobs=$jobs secs=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.1f", b-a}')"
grep -E '^  FAIL|passed, [0-9]+ failed' "$DST/out.txt" | grep -v ' 0 failed' | tail -n 40
tail -n 1 "$DST/out.txt"
exit "$rc"

#!/usr/bin/env bash
# Modpack installer (eggs/modpack-installer/installer.py): offline unit tests against mock servers
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO" || exit 1

echo "installer unit tests (mock Modrinth / CurseForge / CDN on localhost)"
out=$(python3 -B tests/test_installer.py 2>&1); rc=$?
printf '%s\n' "$out" | tail -n 25 | sed 's/^/       /'
n=$(grep -oE 'Ran [0-9]+ tests' <<<"$out" | grep -oE '[0-9]+')
assert_eq 0 "$rc" "python unittest suite passes (${n:-0} tests)"

finish

#!/usr/bin/env bash
# Documentation checks: relative links and #anchors in README.md and docs/*.md resolve, and docs/README.md indexes every page.
# The headings that lib/*.sh messages point at (architecture, operations) are asserted here too, so a rename cannot go unnoticed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO" || exit 1

echo "links and anchors"
out=$(python3 -I tests/check_docs.py 2>&1); rc=$?
if ((rc == 0)); then pass "all links, anchors and index entries resolve ($(tail -n 1 <<<"$out"))"; else fail "documentation links" "$out"; fi

echo "sections referenced by messages in lib/"
# config.sh: docs/architecture.md (Versions and beta risk); stack.sh: operations.md "Wings" and "Rollback"; backup.sh: operations.md Backups
grep -q '^## Versi dan risiko beta$' docs/architecture.md && pass "architecture.md: Versi dan risiko beta" || fail "architecture.md lost the section 'Versi dan risiko beta'"
grep -q '^## Wings: dari node di Panel sampai hijau$' docs/operations.md && pass "operations.md: Wings section" || fail "operations.md lost the Wings section"
grep -q '^### Rollback$' docs/operations.md && pass "operations.md: Rollback section" || fail "operations.md lost the Rollback section"
grep -q '^## Backup$' docs/operations.md && pass "operations.md: Backup section" || fail "operations.md lost the Backup section"

echo "tool must catch real mistakes"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ptero-docs.XXXXXX")
mkdir -p "$tmp/docs" "$tmp/tests"
cp tests/check_docs.py "$tmp/tests/"
printf '# Title\n\n[ok](docs/a.md#real-heading) [bad file](docs/missing.md) [bad anchor](docs/a.md#nope)\n' >"$tmp/README.md"
printf '# A\n\n## Real heading\n' >"$tmp/docs/a.md"
printf '# Index\n' >"$tmp/docs/README.md"
out=$(python3 -I "$tmp/tests/check_docs.py" 2>&1); rc=$?
assert_eq 1 "$rc" "a broken checkout fails the check"
assert_contains "$out" "no such file: docs/missing.md" "reports a missing file"
assert_contains "$out" "broken anchor #nope" "reports a bad anchor"
assert_contains "$out" "does not link to docs/a.md" "reports a page missing from the index"
assert_not_contains "$out" "real-heading" "a valid anchor is accepted"
rm -rf -- "$tmp"

finish

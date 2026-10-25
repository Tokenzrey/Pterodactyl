# Fix spec: prune fails safe, and the guard script gets a syntax test

Status: written, not dispatched. Written on 2026-10-25 from the review of Task 11 and of the Task 8 open item (prune by archive name).
Model for the implementer: `haiku` at effort `xhigh` (user instruction).
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Why

`prune` deletes every archive after the first PRUNE_BACKUPS_COUNT in the order given by `_backup_list`. The order is taken from the file NAMES. The archives that itzg/mc-backup writes are not verified (its documentation was not reachable). If the names do not sort by time, prune deletes the NEWEST archives. That is data loss, so the code must not delete unless it can prove the order.

Best practice applied here: sort by the timestamp that the name carries, compare the digits only (so 2026-01-03_12.00.00 and 20260103T120000Z order the same way), and refuse to delete at all when that is not possible. A refusal costs nothing; a wrong delete cannot be undone.

## 2. Required behaviour (lib/backup.sh)

1. `_backup_stamp BASENAME`: print the 14-digit UTC stamp `YYYYMMDDHHMMSS` found in BASENAME, or print nothing and return 1. Accepted forms, each as a regex on the basename: `([0-9]{4})-?([0-9]{2})-?([0-9]{2})[T_ -]?([0-9]{2})[.:_-]?([0-9]{2})[.:_-]?([0-9]{2})`. Use the first match. Validate the parts: month 01 to 12, day 01 to 31, hour 00 to 23, minute and second 00 to 59. An invalid match is "no stamp".
2. `_backup_list NAME`: unchanged output (one path per line), but the order is by stamp, newest first. Archives without a stamp are listed last, sorted by name. Use only bash and `LC_ALL=C sort` on `stamp<TAB>path` lines built in bash (no fork per file where avoidable). Keep the existing behaviour for `backup list`.
3. `prune`: before deleting anything, check every archive in the list:
   - every archive must have a stamp; if one does not, refuse with EX_REFUSED and name the first such file: "cannot prune: <file> has no UTC timestamp in its name, so its age is unknown; nothing was deleted";
   - no two archives may have the same stamp; if they do, refuse with EX_REFUSED and name both: "cannot prune: <a> and <b> have the same timestamp; nothing was deleted";
   - the check happens before the "keeping all" message as well, so a prune with a bad name set is always a refusal, not a silent pass.
   Only when the check passes: delete the archives after the first PRUNE_BACKUPS_COUNT, oldest last, and print the same message as now.
4. `restore` is unchanged: it takes an explicit archive name.
5. Do not change `now`, `delete`, or the trash logic.

## 3. Required tests (tests/t_backup.sh)

Use the existing sandbox helpers. Create archives with `touch -d` for mtimes only where the test needs them; the order must come from the name stamps.
1. Mixed separators sort by time: `20260101T000000Z`, `2026-01-02_12.00.00`, `2026-01-03 00-00-00` (with the stamps 20260101000000, 20260102120000, 20260103000000): `backup list` prints them newest first (03, 02, 01), with the mtimes deliberately reversed.
2. prune keeps the newest N by stamp and deletes the oldest, with the mixed names above and PRUNE_BACKUPS_COUNT=2: the file of 2026-01-01 is removed, the other two remain.
3. prune refuses when one name has no stamp (for example `world-backup.tar.gz`): exit 4 (EX_REFUSED), the message names the file, and NO file is deleted (check the count before and after).
4. prune refuses when two names carry the same stamp (`a-20260101T000000Z.tar.gz` and `b-20260101T000000Z.tar.gz`): exit 4, names both, nothing deleted.
5. prune with names that have stamps and a count at or above the number of archives: "keeping all", nothing deleted.
6. A stamp with an impossible date (`20261340T000000Z`, month 13) counts as no stamp: prune refuses.
7. Repeat the listing 20 times and assert the same output each time (stability).
8. E4 and E3 as in the other cases: no `eval`, no `sudo`, no new `rm -rf`.

## 4. Required test (tests/t_router.sh): the guard script is valid POSIX sh

The guard script is the `command:` block of service `egress-guard` in `templates/stack.compose.yml`: the lines after `- |` until `exec sleep infinity` inclusive. In compose the `$$` is written for a single `$`.

Add a test that:
1. extracts that block from the template with awk (lines between the `- |` line of `egress-guard`'s command and the `exec sleep infinity` line), strips the 8-space indentation, and replaces every `$$` with `$`;
2. runs `sh -n` on the result (the POSIX parser; the guard runs under `sh` in Alpine) and asserts status 0;
3. also runs `sh -n` on the healthcheck `CMD-SHELL` block the same way (its own block, `$$` replaced by `$`);
4. asserts the extracted text contains `MCCTL-INGRESS`, `connlimit-above`, `hashlimit-above`, and `$CONN_LIMIT` and `$RATE`.

## 5. Constraints

- Edit only `lib/backup.sh`, `tests/t_backup.sh`, `tests/t_router.sh`. Do not change `templates/stack.compose.yml`, `lib/firewall.sh`, or any other file. If the guard script itself fails `sh -n`, stop and report it; do not fix the template silently.
- Another session may edit files; re-read each file right before you edit it, and never revert an edit you did not make.
- No real docker, sudo, ssh, iptables, ufw, or network call. LF line endings. No Python. No new subcommands.
- Do not dispatch subagents.

## 6. Gate

Run in WSL, never on Windows, and never with the Windows tests/run.sh:
`wsl.exe bash -c 'bash /mnt/d/Documents/code/pterodactyl/single-standalone/tests/wsl-run.sh t_backup.sh t_router.sh'` (must show 0 failed), then the whole suite with `wsl.exe bash -c 'bash /mnt/d/Documents/code/pterodactyl/single-standalone/tests/wsl-run.sh'`. Report every summary line and the secs= value.

Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\fix-prune-guard-report.md`, with the changed files, the summaries, and any Ruling.

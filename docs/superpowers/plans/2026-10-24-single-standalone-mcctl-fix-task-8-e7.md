# Fix spec: Task 8 open item, restore extraction is not covered by failure injection (E7)

Status: written, not dispatched. Written on 2026-10-24. The fix of 2026-10-24 for Task 8 (`fix-task-8.md`) is in the tree and its own suite is green (`t_backup.sh` 192 passed). This item is the one it left open.
Model for the implementer: `haiku` at effort `xhigh` (user instruction, 2026-10-24: every subagent). Restore is the data-loss path, so the controller reads the diff of `lib/backup.sh` and the test output before accepting.
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## Problem

Restore has three steps that can fail after data was moved: moving `data/` aside, the extraction in a helper container, and moving the previous data back. The failure path is written (`lib/backup.sh`, `restore)` branch: a failed extraction moves the partial result to `data.failed-restore-<ts>` and moves the previous data back). No test injects a failure at the extraction, so that path has never run under test.

The fake `docker` (`tests/fakebin/docker`) does not count `docker run` as a mutating call, so `FAIL_AT=n` never reaches the extraction. The fake's header says so explicitly.

## Required

1. **`tests/fakebin/docker`**: a `docker run` is a mutating call for `FAIL_AT`, unless its command (the word after the image) is one of `ls cat stat test readlink find du wc head`. Count it exactly like `compose create|up|rm|stop|kill` (the same counter in `$FAKE_STATE/mutations`). A failing run exits 1 and does not change the fake's state. Update the header comment. No other behaviour changes.

2. **`tests/t_backup.sh`**: a new E7 block for `backup restore`.
   - Set up a server folder with a `data/` that holds one sentinel file whose content is known (`data/world/level.dat` with the text `previous`). Use a `clean.tar.gz` fixture for the restore.
   - For each `n` from 1 to the number of mutating calls of a successful restore (the extraction is the only `docker run` that is mutating; measure it, do not hard-code it), run `FAIL_AT=n MCCTL_YES=1 m backup s1 restore clean.tar.gz` and assert:
     - exit 1 (EX_FAIL), and the message names the path where the previous data is, or says it was put back;
     - the sentinel file in `data/` has the content `previous` again (the previous data is back);
     - no `data.pre-restore-*` directory is left behind;
     - a `data.failed-restore-*` directory exists only if something was extracted (with a fake that fails before any effect, none is expected; assert that as well);
     - a re-run without `FAIL_AT` exits 0 and the extraction call appears in `calls`.
   - Run the cases in a fresh sandbox each time, as the other E7 blocks do.

3. **`tests/t_failure.sh`**: add the restore to its list of mutating commands, so the E7 summary covers it. If `t_failure.sh` builds its own sandbox per command, follow that pattern; do not share state between cases.

4. **Assertions for the mutating count**: a test that a failed `docker run` for `ls` (a read-only command) does NOT consume a `FAIL_AT` slot. This keeps the counting rule honest.

## Constraints

- Only `tests/fakebin/docker`, `tests/t_backup.sh`, `tests/t_failure.sh`. Do not change `lib/backup.sh` unless a test exposes a real bug there; if one does, stop, write it up, and do not fix it silently.
- Another session works on Task 11 (`lib/firewall.sh`, `tests/t_firewall.sh`, `tests/t_config.sh`, `templates/stack.compose.yml`) and on Task 9/10 logic (`lib/sftp.sh`, `lib/servers.sh`, `tests/t_sftp.sh`, `tests/t_edit.sh`). Do not edit those. Re-read each file right before you edit it.
- LF line endings only. No `eval`, no `sudo`. The tests never run Python. No real Docker.

## Gate

`bash tests/t_backup.sh` and `bash tests/t_failure.sh` directly, both 0 failed. Then the full suite in the background (`run.sh` and `t_invariants.sh`). Expect Task 11 failures (see above); report any failure outside those.

Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\fix-task-8-e7-report.md`, with the changed files, the counts, the number of mutating calls the restore has, the gate summary, and any Ruling.

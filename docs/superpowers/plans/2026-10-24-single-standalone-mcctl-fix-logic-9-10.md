# Fix spec: logic misses in Task 9 (SFTP users) and Task 10 (edit), found on review 2026-10-24

Status: written, not dispatched. Found by reading the code after the Task 9 and Task 10 suites went green. Tests were green because no test covers these failure paths.
Model for the implementer: Sonnet (small, precise changes, each with a test).
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## Items

### L1 (Task 10): `cmd_edit` ignores the status of `_env_put`

Where: `lib/servers.sh`, `cmd_edit`, the two lines `if ((have_mem)); then _env_put "$dir/server.env" MEMORY "$opt_mem"; fi` and the CPUS line.

Problem: `_env_put` writes through `write_atomic`. If that write fails (disk full, permissions, a rename error), the status is dropped. `cmd_edit` then renders `compose.yaml` from the old file and reports "applied". The operator is told something that is not true, and with `MEMORY` written but `CPUS` not, the file can be half-changed.

Required behaviour:
- Check every `_env_put` call. On a failure, put the saved `old_env` text back (the same way the render-failure branch already does), print an error that names the file, and exit `EX_FAIL` (1). Nothing is rendered and no Docker call is made.
- A failing `_env_put` for CPUS after MEMORY was written must also restore the file. Writing the old text back is the only undo; do not try to undo key by key.
- Message: `cannot write <file>; server.env was put back as it was`.

Test (`tests/t_edit.sh`, new case): make one `write_atomic` of server.env fail (see the test approach below), then assert: exit 1; `server.env` byte-identical to before (`cksum`); `compose.yaml` byte-identical; no `docker compose` call in `calls`.

### L2 (Task 9): `sftp_add_user` and `sftp_remove_user` do not check the status of `grep -v`

Where: `lib/sftp.sh`. Both functions run `grep -v "^$name:" "$users" >"$users.tmp" 2>/dev/null; mv -f "$users.tmp" "$users"`.

Problem: `grep -v` exits 1 when nothing is left (legitimate) and 2 on a read error. On status 2, the partial `users.tmp` is moved over `users.conf`, and every other user's line can be lost. The error is hidden by `2>/dev/null`.

Required behaviour:
- Status 0 and 1 are fine. Status 2 (or any other) aborts before the `mv`: remove `users.tmp`, print `cannot read <users.conf>; nothing was changed`, return `EX_FAIL`.
- Do not hide stderr: let grep's own message show.

Test (`tests/t_sftp.sh`, new case): define a shell function `grep() { return 2; }` inside a subshell that calls `sftp_add_user` for an existing user, and assert: the status is non-zero; `users.conf` is byte-identical; no `users.tmp` left. Do the same for `sftp_remove_user`. (Bash functions shadow external commands, so this runs without touching the system grep.)

### L3 (Task 9 and 10): no test proves the write-failure path

Both L1 and L2 need a way to make a write fail inside a test. Choose the simplest reliable one and state it in the report:
- Preferred: a `tests/fakebin/mv` that passes its arguments to the real `mv` (found with `command -p mv`), but fails with exit 1 when the environment variable `FAIL_MV` names a path that is the destination of the call. Default behaviour must be identical to the real `mv`. Add it to the fakebin header comment.
- Or a shell function in the test, as in L2, if the call can be reached that way.

Whichever is chosen, it must not change any existing test's result. Run `tests/t_edit.sh`, `tests/t_sftp.sh`, `tests/t_servers.sh` and `tests/t_flows.sh` before and after.

## Constraints

- Only `lib/servers.sh` (`cmd_edit` only), `lib/sftp.sh` (the two functions only), `tests/t_edit.sh`, `tests/t_sftp.sh`, and, if needed, `tests/fakebin/mv`. Do not touch `lib/backup.sh`, `tests/t_backup.sh`, `tests/fakebin/docker`, or `templates/*`.
- Another session is working on Task 11 (`lib/firewall.sh`, `tests/t_firewall.sh`, `tests/t_config.sh`, `templates/stack.compose.yml`). Do not edit those, and do not fix their failures. Re-read each file right before you edit it.
- LF line endings only. No `eval`, no `sudo`. No new subcommand.

## Gate

Run each file directly first: `bash tests/t_edit.sh`, `bash tests/t_sftp.sh`. Both must show 0 failed. Then the full suite in the background (`run.sh` and `t_invariants.sh`). Expect failures from Task 11 (`t_firewall.sh`, `t_config.sh` and two `t_router.sh` checks, all in the other session's work). Report any failure outside those as yours.

Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\fix-logic-9-10-report.md`, with the changed files, the two test counts, the gate summary, the injection method chosen for L3, and any Ruling.

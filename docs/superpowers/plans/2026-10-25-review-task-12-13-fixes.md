# Fix spec: review of Task 12 (mcctl top) and Task 13 (mcctl logs, merged into 12)

Status: written, not dispatched. Written on 2026-10-25 after reading lib/monitor.sh and lib/logs.sh in full and running tests/t_monitor.sh (53 assertions) and tests/t_logs.sh (48 assertions): both green in WSL, 118 passed. The findings below are the ones the green tests do not catch.
Plan: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl.md` (Task 12, which holds Task 13). Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-12.md`.
Model for the implementer: `haiku` at effort `xhigh` (user instruction).
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## Findings (each one verified or read in the code)

| # | Where | Finding | Verified how |
|---|---|---|---|
| F1 | lib/monitor.sh, render_top_frame, the CPU and MEM cells (`printf '%6s '`) | A CPU value of 100% or more (multi-core, for example `800.00%`, 7 chars) is wider than the 6-char label, so the row is one character too wide and the right border moves. The total row has the same problem (`801.2%`). | Reproduced: a row with `800.00%` is 81 chars at COLUMNS=80, and 121 at COLUMNS=120. |
| F2 | lib/monitor.sh, cmd_top | If `docker ps` fails after the loop has started, `_top_one_frame` calls `die` inside `$(...)`, and the message is printed while the alternate screen is active. `_top_restore` then leaves the alternate screen, so the user sees the screen flip back with no error. | Read in code; the message goes to stderr in the alternate screen. |
| F3 | lib/logs.sh, colorize_log_line and _log_process | `tr` is called once per line through `$(...)` (a fork per line), even for ordinary lines. `--tail` allows up to 100000 lines, so one `mcctl logs --tail 100000` starts 100000 processes. | Read in code. |
| F4 | lib/logs.sh, cmd_logs without -f | `output=$(docker ... 2>&1)` ignores the status of docker, so a docker error is printed as if it were log text and mcctl exits 0. | Read in code. |
| F5 | lib/logs.sh, cmd_logs with -f | Ctrl-C: the spec (section 4.4) says exit 0. The code has no SIGINT handling; bash exits with the signal status (130) when a foreground pipeline dies of SIGINT. A plain `trap '' INT` would be wrong, because children inherit ignored signals and docker would not stop. | Read in code and in bash semantics; check with acceptance step 8. |
| F6 | lib/monitor.sh, _top_one_frame and render_top_frame | `running N` in the summary counts rows whose CPU is not `-`, so a running server whose `docker stats` failed is counted as not running. | Read in code. |
| F7 | tests | No test for CPU of 100% or more (F1). No E13 flow for `top` in tests/t_flows.sh (the Task 12 spec, section 5 item 19, asks for one). No test for F2, F4, or F3 (per-line process count). | Grep of the test files. |

## Required changes

### F1 (monitor.sh)
- Give the CPU and MEM value a fixed label width of 8 characters: use `_pad_right "$value" 8` (it truncates and pads), not `printf '%6s'`. Shrink the bar by the same amount, so the cell width stays `cpu_w` and `mem_w` as now. Apply to the total row too.
- Test (t_monitor.sh): a frame with `800.00%` and `1600.00%` (CPU) and `100.00%` (MEM) has every line of exactly W visible characters at COLUMNS 80, 120, and 200 (strip ANSI before measuring, as the other width tests do), and the bar in those rows is still present.

### F2 (monitor.sh, cmd_top)
- Build the first frame before the alternate screen is entered: call `_top_one_frame "$name"` once, outside the loop, and if it fails the process dies there (normal screen, the message stays visible, exit 1, as `docker ps` failure already does in `cmd_list`).
- Inside the loop, a failure still restores the terminal and exits 1, but the message must be printed AFTER `_top_restore`. Do this by capturing the stderr of the frame call into a variable, or by running the frame call with `2>` to a temp file in a mktemp -d directory that is removed on exit (check the variable is non-empty before any rm). Keep it simple.
- Test: with `docker ps` failing on the first call, `mcctl top` exits 1 with the "docker ps failed" message on stderr and no alternate-screen escape in stdout. (The loop itself is covered by acceptance.)

### F3 (logs.sh)
- No `tr` process per ordinary line. In `cmd_logs`:
  - non-follow: pass the whole output through one `LC_ALL=C tr -d '\000-\010\013-\037\177'` (as a pipeline stage, once);
  - follow: add the same `tr` as a stage in the pipeline before `_log_process`, so it streams.
- In `colorize_log_line` keep the control-character removal (spec C3, the function must work on its own), but only fork when the line really has a control character: test with a bash pattern first, for example `[[ $line == *[[:cntrl:]]* ]]` and call tr only then. Tab is in `[:cntrl:]`, so stack-trace lines containing tabs would fork; accept that, or use an explicit class without tab (`$'\001'-$'\010'`, `$'\013'-$'\037'`, `$'\177'`) if it works in bash on WSL. State which you chose.
- Test (t_logs.sh): a PATH shim named `tr` (in a mktemp -d directory placed first on PATH for that one test, that logs each call and then calls the real tr) fed 500 ordinary lines through `colorize_log_line` and through `cmd_logs --tail 500` produces zero calls per line (at most one call for the whole output in cmd_logs). Output is unchanged.

### F4 (logs.sh, cmd_logs without -f)
- Capture the status: `output=$(docker "${dargs[@]}" 2>&1) || die "cannot read the logs of $name (docker logs failed, see above): is the daemon running?" "$EX_FAIL"`. Keep the existing behaviour otherwise.
- Test (t_logs.sh): a failing `docker logs` (fake `docker.logs.rc` = 1) makes `mcctl logs s1` exit 1 with that message and print no log lines.

### F5 (logs.sh, cmd_logs with -f)
- Make a Ctrl-C while following end with exit 0, as the spec says, without ignoring SIGINT for the children: install `trap : INT` (a handler that does nothing; signals with a handler are reset to default in children, so docker still stops) around the follow pipeline, and restore the previous INT trap afterwards.
- Test: not automatable without a terminal. Add a test that the function sets the trap before the pipeline and restores it after (grep the trap calls in the function text, or run the function with a stub docker that exits with status 130 and check the function's exit status is 0). State in the report which test you chose.

### F6 (monitor.sh, render_top_frame or _top_one_frame)
- `running N` counts the servers whose container state is running (from the list query, the `sstate` field), not the rows with a CPU value. Pass the count in, or count in `_top_one_frame` and pass it to `render_top_frame` through a variable or an extra first line; keep the rendering functions testable with the same stdin format.
- Test: a server in state running whose stats are missing (`docker.stats.rc` = 1, or the name absent from the stats output) is counted in `running`.

### F7 (tests)
- F1 test above.
- E13 flow in tests/t_flows.sh: `top` once (`NO_COLOR` not needed; the non-terminal path prints one frame), then `logs s1 --tail 3`; assert the ordered call log: `docker ps` (list query), `docker stats` (only for running servers), then `docker logs --tail 3 mc-s1`.

## Constraints

- Edit only lib/monitor.sh, lib/logs.sh, tests/t_monitor.sh, tests/t_logs.sh, tests/t_flows.sh, and tests/lib.sh only if a helper is needed. Do not touch lib/firewall.sh, lib/servers.sh, templates/*, or any Task 10 or 11 file.
- Another session may edit files. Re-read each file right before you edit it, change only the lines named here, and never revert an edit you did not make.
- No real docker, sudo, ssh, or network call. Tests use the fakes. No Python. LF line endings.
- Do not delete or move anything outside a mktemp -d sandbox. Never run a delete command in the real WSL home (/home/surip): the incident of 2026-10-25 happened that way.
- Do not dispatch subagents.

## Gate (WSL only; never the Windows tests/run.sh)

- `wsl.exe bash -c 'bash /mnt/d/Documents/code/pterodactyl/single-standalone/tests/wsl-run.sh t_monitor.sh t_logs.sh t_flows.sh'` must show 0 failed.
- The whole suite with `wsl.exe bash -c 'bash /mnt/d/Documents/code/pterodactyl/single-standalone/tests/wsl-run.sh'`, with its summary line and secs=.

Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\fix-review-task-12-13-report.md`, with the changed files, the counts before and after, the summaries with secs=, and the Ruling for F3 and F5.

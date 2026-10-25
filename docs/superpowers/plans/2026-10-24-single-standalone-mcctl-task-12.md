# Task 12 spec: live monitoring (`mcctl top`) and live logs (`mcctl logs`)

Status: written, not dispatched. Verified against the working tree on 2026-10-24 (after 15:32). Task 13 is merged into this task.
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 12").
Code root: `D:\Documents\code\pterodactyl\single-standalone\`. This task adds two new library files and touches no existing one.

## 1. Goal

`mcctl top [NAME]` is a live, flicker-free table of every server (or one): CPU, memory, network and disk, with colour bars. `mcctl logs NAME` streams a server's console log with colour, a level filter, and a text filter. Both restore the terminal when they end.

## 2. Corrections to the plan text (the corrections win)

| # | Plan text | What is true | Rule for this task |
|---|---|---|---|
| C1 | E10 widths in `tests/t_views.sh` (Test Gate table) while this task's Files list names `t_monitor.sh` and `t_logs.sh` | Two names for one thing. | The E10 cases live in `tests/t_monitor.sh` and `tests/t_logs.sh`. There is no `t_views.sh`. |
| C2 | "every line of the frame has the same visible width" | Bash counts characters in `${#s}` only under a UTF-8 locale; under `LANG=C` (a minimal VPS, a cron job, `sudo -i` on some images) it counts bytes, and `█`, `░` and box-drawing characters are 3 bytes each, so the padding is wrong and the box tears. | Detect once: `[[ $(locale charmap 2>/dev/null) == UTF-8 ]]`. When it is not, draw with ASCII (`#`, `-`, `+`, `\|`). Tests run both ways (`LC_ALL=C.UTF-8` and `LC_ALL=C`). |
| C3 | colour only | The log can carry text a player or a plugin chose. A raw ESC byte reaching the terminal can clear the screen or retitle the window. | `colorize_log_line` removes control characters (everything below space except tab, and DEL) from the text it prints. "Byte-identical with `NO_COLOR=1`" holds for lines that contain none. |
| C4 | "filter to `mcctl.managed` containers" | `docker stats` has no label filter. The backup sidecar has only the label `mcctl.backup-for`, so it is already outside `mcctl.managed`. The fake `docker` replays one canned file per call whatever `--format` says. | List servers with the query `cmd_list` uses and take the first `\|` field of each row (`${row%%\|*}`); that works for the real client (which prints only the name when the format has only the name) and for the fake. Then ask `docker stats` for the running ones by container name `mc-NAME`. |
| C5 | `cmd_top` loops forever | Piped, redirected, or run by a test, an endless loop with cursor codes is wrong. | Standard output not a terminal: print one frame without colour or cursor codes, then exit 0. |
| C6 | `tput` for the terminal | `COLUMNS` is not exported to non-interactive shells. | Width is `${COLUMNS:-$(tput cols 2>/dev/null)}`, else 80. |

## 3. Verified facts

| Thing | Where | Behaviour |
|---|---|---|
| Container names | `lib/compose.sh` | `container_name NAME` is `mc-NAME`; the sidecar is `mc-NAME-backup` with label `mcctl.backup-for=NAME` only. |
| Server query | `lib/servers.sh`, `cmd_list` | `docker ps -a --filter label=mcctl.managed=true --format '{{.Label "mcctl.name"}}\|{{.State}}\|{{.Label "mc-router.host"}}\|{{.Status}}'`. |
| `docker stats` fields | Docker CLI | `.Name .CPUPerc .MemUsage .MemPerc .NetIO .BlockIO`. `.MemUsage`, `.NetIO`, `.BlockIO` are single strings of the form `A / B`. |
| Fake `docker` | `tests/fakebin/docker` | `ps`, `stats`, `logs` are modelled. Replay file is named after the non-option words, longest match first: `docker.stats` is the default for any `docker stats --no-stream … NAMES`; `docker.logs` for `docker logs`; managed rows come from `docker.ps.label_mcctl_managed_true` (use `fake_server NAME HOST [STATE]` from `tests/lib.sh`). |
| Helpers | `tests/lib.sh` | `sandbox`, `m`, `calls`, `count_calls`, `assert_*`, `fake_server`. `strip_ansi` does not exist yet: add it to `tests/lib.sh` (`sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'`). |
| Dispatch | `mcctl` | new `lib/monitor.sh` and `lib/logs.sh` are sourced and their `cmd_*` functions become commands. `mcctl` is not changed. |
| Environment | here | `locale charmap` is `UTF-8`, `tput cols` answers 80. |

## 4. Behaviour

### 4.1 Pure functions (`lib/monitor.sh`)

- `render_bar PCT WIDTH`: PCT is an integer or decimal (a trailing `%` is allowed); clamp to 0 to 100; filled cells = `round(PCT * WIDTH / 100)` using integer arithmetic (`(PCT*WIDTH + 50) / 100` on the integer part). Cells are `█` filled and `░` empty (ASCII `#` and `-` when the locale is not UTF-8). Colour (unless `NO_COLOR` is non-empty): green below 60, yellow from 60 to 84, red from 85. Output has exactly WIDTH visible cells.
- `render_top_frame`: reads lines `name<TAB>cpu%<TAB>mem_used<TAB>mem_limit<TAB>mem%<TAB>net_io<TAB>block_io` on stdin (a missing or empty field is shown as `-`, a stopped server has all `-`), prints the whole frame.
  - Width W = clamp(columns, 60, 140). Every line of the frame, including borders, has exactly W visible characters.
  - Lines: top border with the title ` mcctl top `; a summary line (`servers N, running R, cpu T%, mem U / L`); the column header; one row per server sorted by name; a totals row; the bottom border.
  - Columns: NAME (up to 24, longer names cut with `…` or `~` in ASCII), CPU with a bar, MEM with a bar, and, only when W is at least 100, NET and BLOCK. Below 100 the last two columns are dropped, not wrapped.
- `NO_COLOR` non-empty: no ESC byte anywhere in the output.

### 4.2 `cmd_top [NAME]` (`lib/monitor.sh`)

1. `NAME` given: `_need_server NAME`; show only that server. More than one argument: usage, exit 2.
2. `MCCTL_REFRESH` (default 2): a number from 0.2 to 3600 (`^[0-9]+(\.[0-9]+)?$`); anything else: exit 2.
3. Each round: run the server query (C4); for the running servers run one `docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}' mc-a mc-b ...`; split `MemUsage` on ` / `; build the stdin of `render_top_frame`; draw.
4. Terminal (standard output is a terminal): enter the alternate screen and hide the cursor (`\033[?1049h\033[?25l`); every round `\033[H`, each line followed by `\033[K`, and `\033[J` after the last, so there is no clear-screen flicker; leave with `\033[?25h\033[?1049l` from one `trap` on `INT`, `TERM` and `EXIT`; Ctrl-C exits 0.
5. Not a terminal (C5): one frame, `NO_COLOR` forced, exit 0.
6. `docker ps` fails: `die` exit 1 with the same message as `cmd_list`. `docker stats` fails or returns nothing for a running server: its row shows `-` and a one-line note under the frame; the loop continues.

### 4.3 `colorize_log_line LINE` (`lib/logs.sh`)

- Prints LINE with `printf '%s\n'` (no backslash or `%` interpretation), after removing control characters (C3).
- Recognises `^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] \[[^]]*/(INFO|WARN|ERROR|FATAL|DEBUG|TRACE)\]: `. Colours the level word only for INFO (green), DEBUG and TRACE (dim); for WARN (yellow) and ERROR or FATAL (red, bold) it colours the level word and the message. The timestamp is dim.
- Continuation lines (start with a tab, `at `, `Caused by:`, or `... N more`) take the colour of the last WARN or ERROR entry; the next entry line resets it.
- Any other line is printed unchanged.
- `NO_COLOR` non-empty: no ESC byte; the text is the input after C3.

### 4.4 `cmd_logs NAME [-f] [--tail N] [--level INFO|WARN|ERROR] [--grep TEXT]` (`lib/logs.sh`)

- `_need_server NAME`; `--tail` integer 0 to 100000 (default 100); `--level` case-insensitive, one of INFO, WARN, ERROR; `--grep` non-empty, at most 200 characters; anything else: usage, exit 2.
- Runs `docker logs --tail N [-f] mc-NAME 2>&1` into a `while IFS= read -r line` loop. A stopped server's log is shown too.
- `--level L` keeps entries at or above L (INFO: INFO WARN ERROR FATAL; WARN: WARN ERROR FATAL; ERROR: ERROR FATAL). Continuation lines and unrecognised lines follow the decision made for the entry before them; before any entry they are kept.
- `--grep TEXT`: case-insensitive substring match (`[[ ${line,,} == *"${text,,}"* ]]`, never a regex), applied to each physical line.
- Ctrl-C while following: exit 0. Colour only when standard output is a terminal and `NO_COLOR` is empty.

## 5. Tests

`single-standalone/tests/t_monitor.sh` and `single-standalone/tests/t_logs.sh`. Pure functions are tested by sourcing the files, no Docker. Run the width and bar cases under `LC_ALL=C.UTF-8` and again under `LC_ALL=C` (E10 and C2).

`t_monitor.sh`
1. `render_bar 50 10` has 5 filled cells; `0` all empty; `100` all filled; `150` and `-5` clamp; `49.6 10` gives 5; `50%` works; WIDTH 1 and 0 do not crash (0 prints nothing).
2. Colour code: green at 59, yellow at 60 and 84, red at 85 and 100.
3. `render_top_frame` with three rows prints three server rows, a header, a summary, and a totals row; rows are sorted by name; a row with a missing field prints `-`; a stopped server prints `-` everywhere.
4. E10: at `COLUMNS` 80, 120, 200 and 40 the visible width (after `strip_ansi`, counted with `${#}`) of every line is equal, and equals 80, 120, 140 and 60. At 80 there is no NET or BLOCK column; at 120 both are there.
5. `NO_COLOR=1`: no ESC byte in the frame; `NO_COLOR=` and a terminal-less run both produce plain text through `cmd_top`.
6. Name of 40 characters is cut to the column width and the box stays intact.
7. `cmd_top` end to end with the fakes: two servers (`fake_server`), `docker.stats` with two lines; the call log is the query, then one `docker stats` with exactly `mc-a mc-b`; output (not a terminal, so one frame) has both rows and exit 0. A stopped server is in the table but not in the `docker stats` call. `cmd_top s1` shows only `s1`. `cmd_top nope` exits 1. `MCCTL_REFRESH=0`, `abc`, `-1`, `1e3` exit 2.
8. A failing `docker stats` (`docker.stats.rc` = 1): the row shows `-`, the note appears, exit 0.
9. No cursor code (`\033[H`, `\033[?1049h`) in the not-a-terminal output.

`t_logs.sh`
10. `INFO` line: after `strip_ansi` the text equals the input; the level word is wrapped in a colour code and the message is not. `WARN` and `ERROR` colours differ; `ERROR` colours the message too.
11. A stack trace (`\tat net.minecraft.X`, `Caused by: ...`, `... 12 more`) takes the colour of the preceding ERROR; the next `INFO` line resets it.
12. An unmatched line (`[init] starting`) is printed unchanged, never dropped.
13. `100% done \n` and a line with `%s %d \\` come back byte for byte.
14. C3: a line with `ESC[2J` and a BEL loses those bytes in both colour modes; a tab survives.
15. `--level WARN` hides INFO and keeps WARN, ERROR, FATAL; stack lines of a kept ERROR stay, stack lines of a hidden INFO-level entry go; an unmatched line before any entry stays.
16. `--grep` is case-insensitive; a regex metacharacter (`a.c`, `[x`) is matched literally; empty or 201 characters: exit 2.
17. `cmd_logs s1 --tail 5` runs exactly `docker logs --tail 5 mc-s1`; `-f` adds `-f`; default is `--tail 100`; `--tail abc`, `--tail 100001`, `--level DEBUG`, unknown option, missing NAME: exit 2; `nope`: exit 1.
18. E3: `cmd_top` and `cmd_logs` are named in the tests; no `eval`, no `sudo`.
19. Flow (E13), one block in `tests/t_flows.sh`: create, start (fake running), `top` once, `logs --tail 3`; assert the ordered call log.

## 6. Files

- Create: `single-standalone/lib/monitor.sh`, `single-standalone/lib/logs.sh`, `single-standalone/tests/t_monitor.sh`, `single-standalone/tests/t_logs.sh`.
- Modify: `single-standalone/tests/lib.sh` (add `strip_ansi`), `single-standalone/tests/t_flows.sh` (one flow), `single-standalone/docs/reference.md` (sections `## mcctl top` and `## mcctl logs`).
- Do not modify: `single-standalone/mcctl`, `lib/servers.sh`, `lib/compose.sh`.

`ponytail:` the server query repeats the one in `cmd_list`; fold both into one helper when a third caller appears.

## 7. Documentation

`## mcctl top`: the columns, the colour thresholds, `MCCTL_REFRESH`, the one-frame behaviour when piped, the ASCII fallback without UTF-8, and how it ends. `## mcctl logs`: the options, how the level filter treats stack traces, that `--grep` is a plain substring, and that control characters are removed.

## 8. Not provable in the sandbox (owed to acceptance, Task 23 step 8)

Flicker-free redraw and terminal restore after Ctrl-C on a real terminal at 80 columns and wider; real `docker stats` output formats; real server log lines from itzg (the `[init]` lines and the Java stack traces).

## 9. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_monitor.sh`, `t_logs.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-12-report.md`.

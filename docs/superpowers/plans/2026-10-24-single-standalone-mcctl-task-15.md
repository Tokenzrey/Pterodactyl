# Task 15 spec: data access primitive and file manager (`mcctl files`)

Status: written, not dispatched. Verified against the working tree on 2026-10-24 (after 15:32).
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 15").
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Goal

Read and change the files in a server's `data/` directory without depending on the host user's permissions and without `sudo`. Every access goes through one throwaway helper container that sees only that directory. Task 16 (worlds), Task 18, Task 20 and Task 21 build on `data_run`.

## 2. Corrections to the plan text (the corrections win)

| # | Plan text | What is true | Rule for this task |
|---|---|---|---|
| C1 | "Modify `tests/fakebin/docker` (record `docker run` calls and replay canned output)" | The fake already knows `run` but replays by the non-option words of the call, and it treats the **values** of `--network`, `--user`, `-v`, `-w` as words: `docker run --rm --network none --user 1000:1000 -v P:/data -w /data alpine ls` has the words `run none 1000:1000 P:/data /data alpine ls`. No useful replay file name comes out of that. | Teach the fake `docker run`: parse its options (`--rm -i --network V --user V -v V -w V --cap-drop V --security-opt V --tmpfs V --pids-limit V --memory V`), then the image, then the command. Log the whole line. Replay `$FAKE_STATE/docker.run.<command>` (stdout) and `docker.run.<command>.rc`, where `<command>` is the first word after the image. With `-i`, store stdin in `$FAKE_STATE/run.stdin.<n>`. For E7, count a `run` as a mutating call unless its command is one of `ls cat stat test readlink find du wc head`. |
| C2 | `alpine` | An unpinned image changes under the operator, and `--network none` means the image is pulled on first use by `docker run` itself. | Constant `DATA_IMAGE=alpine:3.20`, overridable by `MCCTL_DATA_IMAGE` (`^[a-z0-9][a-z0-9./:_-]*$`, else `EX_PREFLIGHT`). Docs say the first call pulls the image. |
| C3 | a bare `docker run … alpine CMD` | The helper only touches `/data`, so it can run with almost nothing. | Add `--cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp --pids-limit 64 --memory 128m`. |
| C4 | `data_run NAME CMD...` for everything | `put` and `import` need stdin in the container; `docker run` without `-i` drops it. | Two functions: `data_run NAME CMD...` (no `-i`) and `data_pipe NAME CMD...` (adds `-i`, reads the caller's stdin). |
| C5 | `safe_path` "exit 2 for … a NUL" | A NUL cannot be in a Bash string or an argument. | Drop the NUL case. Reject absolute paths, a `..` component, a newline, any other control character, and an empty path (except where the command defaults to `.`). |
| C6 | paths handed to `rm`, `mv`, `cat` | A name that starts with `-` becomes an option. | `safe_path` prints a name that starts with `-` as `./-name`, and every command in the container is written with `--` before its paths. |
| C7 | symlink check "against `/data/`" | The helper container sees only `/data`; a link to `/etc` lands in the image's own `/etc`, not on the host. | Keep the check (a clear error, and a barrier if the mount ever grows), but do not describe it as the host's protection in the docs; the container boundary is that. |
| C8 | `icon NAME FILE` was in Task 14 | Task 14 moved the file form here (its spec, C6). | Extend `cmd_icon` (Task 14) with the FILE form (section 4.3). |
| C9 | "Modify: `mcctl`" | Dispatch discovers `cmd_*`. | `mcctl` is not changed. |

## 3. Verified facts

| Thing | Where | Behaviour |
|---|---|---|
| `server_dir NAME` | `lib/compose.sh` | `$MCCTL_ROOT/servers/NAME`; the data directory is `$(server_dir NAME)/data`. |
| `confirm`, `write_atomic`, `mkdir_private`, `die`, `err` | `lib/common.sh` | as in the Task 10 spec. |
| Container user | itzg image | runs the game as UID 1000 and sets ownership of `/data` at start. `MCCTL_UID` (default 1000) matches it. |
| Fake `docker` | `tests/fakebin/docker` | `run` is in the known list; see C1 for what is missing. `FAIL_AT` counts compose and curl mutations today. |
| `confirm` | `lib/common.sh` | `MCCTL_YES=1` answers yes; no terminal and no `MCCTL_YES`: error and 1. `--yes` is a global flag (Task 10, C1). |
| Planned (Task 14) | Task 14 spec | `cmd_icon NAME URL`, `server_env_unset NAME KEY`. |

## 4. Behaviour

### 4.1 Primitives (`lib/data.sh`)

- `data_run NAME CMD...` and `data_pipe NAME CMD...` run: `docker run --rm [-i] --network none --user $UID:$UID --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp --pids-limit 64 --memory 128m -v <servers/NAME/data>:/data -w /data $DATA_IMAGE CMD...`, with `UID=${MCCTL_UID:-1000}` (an integer 1 to 65535, else `EX_PREFLIGHT`). NAME goes through `_need_name`; the data directory must exist.
- `safe_path PATH` prints the normalised relative path (`./mods/a.jar` -> `mods/a.jar`, `a//b/` -> `a/b`, `-x` -> `./-x`) and returns 0, or prints a message and returns 2 (C5).
- A value from the user is never put into a script string. A container script is a fixed string and the values follow it as positional arguments: `data_run NAME sh -c 'script' sh "$path"`.
- `_confine NAME PATH`: `data_run NAME sh -c 'p=$(readlink -f -- "$1") && case $p in /data|/data/*) ;; *) exit 3 ;; esac' sh "$path"`; a non-zero status refuses the operation before any read or write (a missing file is fine for `put`).

### 4.2 `mcctl files NAME …`

`ls [PATH]` (default `.`) lists with `ls -la`; works whether the server runs or not (never asks about container state). `cat PATH`. `get PATH [DEST]`: writes the file to DEST (default `./` plus the base name), refuses an existing local file, writes through `write_atomic`. `put SRC PATH [--force]`: SRC is a local file; refuses an existing target without `--force`; the content is streamed with `data_pipe NAME sh -c 'cat > "$1.mcctl-tmp" && mv -- "$1.mcctl-tmp" "$1"' sh PATH`. `rm PATH [--recursive]`: the data root can never be removed (`.` and the empty string are refused); a directory needs `--recursive` and `confirm`. `mkdir PATH`. `mv SRC DEST`: refuses an existing DEST. `edit PATH`: copy to a private temp file (mode 600, in a mode-700 directory, removed by a trap on EXIT, INT and TERM), open `${EDITOR:-vi}`, write back only when the content changed, refuse files over 1 MB.

Usage errors and unsafe paths exit 2; unknown server 1; refusals (existing target, root removal, no confirmation) 4.

### 4.3 `icon NAME FILE` (extends Task 14's `cmd_icon`)

FILE must start with the 8-byte PNG signature, be at most 1 MB, and have width and height 64 (IHDR bytes 16 to 23). It is written to `server-icon.png` with `data_pipe`, and `ICON` is removed from `server.env` (`server_env_unset`), because the image would overwrite the file at start. A URL still takes Task 14's path.

## 5. Tests (`single-standalone/tests/t_files.sh`, plus the fake in `tests/fakebin/docker`)

1. `safe_path`: rejects `/etc/passwd`, `../x`, `a/../../x`, a newline, an ESC byte, empty; accepts `world/level.dat`; prints `mods/a.jar` for `./mods/a.jar`, `a/b` for `a//b/`, `./-rf` for `-rf`.
2. Every `data_run` line in `calls` contains `--rm`, `--network none`, `--user 1000:1000`, `--cap-drop ALL`, `--read-only`, `--pids-limit 64`, the image `alpine:3.20`, and a `-v` whose host side is `<root>/servers/NAME/data`; `MCCTL_UID=2000` changes the user; `0` and `abc` are refused; `MCCTL_DATA_IMAGE='x y'` is refused.
3. `files rm NAME .` and `files rm NAME ''` refused with no `run` call; a directory without `--recursive` refused; with it, `confirm` is asked and a `rm -rf --` call follows; the path follows `--`.
4. `put` refuses an existing target without `--force`; `get` refuses an existing local file and leaves it unchanged; `get` writes atomically (a failing `docker run` leaves no local file and no `*.tmp`).
5. A path whose confinement check fails (`docker.run.sh.rc` = 3) is refused before any further `run` call.
6. `files edit`: `EDITOR` is a script that appends a line; the write-back call happens; with an editor that changes nothing there is no write-back; a file over 1 MB is refused; the temp file is gone after a normal end and after SIGINT (kill the process group in the test); the temp file mode is 600.
7. `files ls` makes the same calls for a running and a stopped server and no `docker inspect`.
8. A user value with spaces, quotes, `$(x)`, and `;` appears in the `calls` line as one argument after the fixed script, never inside it.
9. `icon NAME FILE`: refuses a non-PNG, a PNG over 1 MB, a PNG that is not 64x64; accepts a real 64x64 PNG (the test builds one with a few bytes: signature plus IHDR is enough for the check); writes `server-icon.png`; removes `ICON` from `server.env`.
10. E4: planted RCON secret absent from output and calls. E12: not applicable (no new secret files). E3: `cmd_files`, `data_run`, `data_pipe`, `safe_path` named in tests; no `eval`, no `sudo`; every `rm` in `lib/data.sh` runs inside the container, none on the host.
11. Fake `docker run` (C1): a unit block in `t_harness.sh` shows the parse, the replay by command, the stdin capture, `FAIL_AT` counting for `rm` and not for `ls`.
12. Flow (E13): put, ls, get, edit, rm in `tests/t_flows.sh` with the ordered call log.

## 6. Files

- Create: `single-standalone/lib/data.sh`, `single-standalone/tests/t_files.sh`.
- Modify: `single-standalone/tests/fakebin/docker`, `single-standalone/tests/t_harness.sh`, `single-standalone/tests/t_flows.sh`, `single-standalone/lib/settings.sh` (the FILE form of `cmd_icon`), `single-standalone/lib/config.sh` (validate `MCCTL_UID`, `MCCTL_DATA_IMAGE`), `single-standalone/config/mcctl.env.example`, `single-standalone/docs/reference.md`.
- Do not modify: `single-standalone/mcctl`.

## 7. Documentation

`## mcctl files` with every subcommand and its refusals; why a helper container instead of `sudo` or host permissions; that the first call pulls `alpine:3.20`; that the helper sees only `data/`; `MCCTL_UID` and `MCCTL_DATA_IMAGE`.

## 8. Carry-overs

Tasks 16, 18, 20 and 21 call `data_run` and `data_pipe`. Task 23 step 16 additionally checks, on real Docker, that busybox `tar` accepts `--no-same-owner`, that `readlink -f` resolves as the plan expects, and that files written through the helper belong to UID 1000.

## 9. Not provable in the sandbox

Real busybox behaviour in `alpine:3.20`; ownership of files written through the helper; Docker Desktop bind mounts from WSL; that `--read-only` plus `--tmpfs /tmp` is enough for every command used.

## 10. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_files.sh`, `t_harness.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-15-report.md`.

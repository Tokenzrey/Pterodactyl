# Task 10 spec: `mcctl edit` (resource limits)

Status: written, not dispatched. Verified against the code in the working tree at 15:32 on 2026-10-24.
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` (section "Task 10: Edit resources").
Spec: `D:\Documents\code\pterodactyl\docs\superpowers\specs\2026-10-24-single-standalone-mcctl-design.md`.
Code root: `D:\Documents\code\pterodactyl\single-standalone\` (Git Bash: `/d/Documents/code/pterodactyl/single-standalone`).

## 1. Goal

`mcctl edit NAME [--memory SIZE] [--cpus N]` changes the memory and CPU limits of one server. It regenerates `servers/NAME/server.env` and `servers/NAME/compose.yaml`, and recreates the containers so the new limits take effect. It never restarts a server that has players online unless the caller passes `--yes`.

## 2. Corrections to the plan text (the corrections win over the plan's Task 10 wording)

Each row was checked in the code. Function names are given instead of line numbers, because Task 9 is editing `lib/servers.sh` at the same time.

| # | Plan text | What the code says | Rule for this task |
|---|---|---|---|
| C1 | `cmd_edit NAME [--memory M] [--cpus C] [--yes]` | `mcctl` removes `--yes` from the arguments before dispatch and sets `MCCTL_YES=1` (`mcctl`, the loop under "--yes is accepted anywhere"). `cmd_edit` never sees `--yes`. | `cmd_edit` parses only `--memory` and `--cpus`. It reads `MCCTL_YES`. A test that passes `--yes` passes it to `m`, which puts it anywhere on the line. |
| C2 | "editing a stopped server regenerates the files and recreates nothing" | `cmd_start` is `_lifecycle start`, which runs `docker compose start`. That starts the existing container with its old limits; a changed `compose.yaml` is ignored. | A stopped server gets `dc NAME create --force-recreate`: new container, not started. Without this the edit silently does nothing. |
| C3 | "recreate the game container only (the backup sidecar is left running)" | `templates/server.compose.tmpl` gives the sidecar `network_mode: "service:mc"` and `depends_on: [mc]` (Task 6 decision). A sidecar left running after `mc` is recreated stays in the old, dead network namespace and cannot reach RCON. | Recreate the whole project: `dc NAME up -d --force-recreate` with no service name. Project-wide rule for every later recreate (Tasks 14, 16, 18, 21). |
| C4 | "rewrites server.env and compose.yaml and does not call `docker compose up` before confirmation" | Task 14 (drift detection through `mcctl.config_hash`) does not exist yet. Files rewritten before a "no" disagree with the running container, and nothing shows it. | Order: validate, ask, then write, then recreate. A "no" or a refusal changes nothing on disk. |
| C5 | tests in `tests/t_servers.sh` | `tests/t_servers.sh` already has 256 assertions and runs in every fix round. | New file `single-standalone/tests/t_edit.sh`. E3 only needs `cmd_edit` named in some test file. |
| C6 | "refuses silently-restarting a server that has players online" | Nothing says what happens when RCON does not answer. | Unknown player count counts as players online (section 4, step 5). |

## 3. Verified facts to build on

| Thing | File | Behaviour (checked) |
|---|---|---|
| `_need_server NAME` | `lib/servers.sh` | invalid name: exit 2; no container with label `mcctl.name=NAME`: `die` exit 1 ("no server named"). |
| `server_dir NAME`, `container_name NAME` (`mc-NAME`), `dc NAME ARGS...` | `lib/compose.sh` | `dc` runs `docker compose -p mcctl-NAME -f $MCCTL_ROOT/servers/NAME/compose.yaml ARGS...`. |
| `kv_lines FILE` | `lib/compose.sh` | prints `KEY=VALUE` lines (comments, blanks, trailing CR dropped); exit 1 naming the line number on a bad line. |
| `check_server_values TYPE VERSION MEMORY CPUS EULA HOST BACKUP_ENV_FILE` | `lib/compose.sh` | prints every problem, returns `EX_PREFLIGHT` (3) when any value is invalid. `SE_CTX` prefixes the messages. MEMORY must match `^[1-9][0-9]{0,5}[MmGg]$`; CPUS `^(0\|[1-9][0-9]{0,2})(\.[0-9]{1,2})?$` and be above 0. |
| `write_compose NAME` | `lib/compose.sh` | renders `compose.yaml` from `server.env` and `modpack.env` through `write_atomic`; on failure the old file stays. |
| `write_atomic PATH [CMD...]` | `lib/common.sh` | temp file beside PATH, then `mv`; a failing CMD leaves the old file and no `*.tmp`. |
| `confirm PROMPT` | `lib/common.sh` | `MCCTL_YES=1`: yes. No terminal and no `MCCTL_YES`: prints an error, returns 1. |
| `rcon_exec NAME CMD...` | `lib/rcon.sh` | `docker exec -i mc-NAME rcon-cli CMD...`; the caller makes sure the server runs. `_need_running` dies on a stopped server, so do not use it here. |
| `router_reload` | `lib/router.sh` | `stack_dc kill -s HUP mc-router`. |
| renderer defaults | `lib/compose.sh` (`render_server_compose`) | TYPE `VANILLA`, MEMORY `2G`, CPUS `2`, HOSTNAME_SLUG = NAME, EULA `FALSE`; `mem_limit` = heap + 25% + 256 MiB, in MiB (6G -> `7936m`). |
| services | `templates/server.compose.tmpl` | `mc` (container `mc-NAME`) and `backup` (container `mc-NAME-backup`). |
| dispatch | `mcctl` | any `cmd_*` function in `lib/*.sh` is a command, and `usage` lists it. `mcctl` itself needs no change. |
| exit codes | `lib/common.sh` | `EX_FAIL=1 EX_USAGE=2 EX_PREFLIGHT=3 EX_REFUSED=4`. |

## 4. Behaviour

Syntax: `mcctl [--yes] edit NAME [--memory SIZE] [--cpus N]`. At least one option. Examples: `mcctl edit s1 --memory 6G`, `mcctl --yes edit s1 --cpus 1.5 --memory 4G`.

1. **Parse.** `NAME` first. No arguments, a missing `NAME`, an unknown option, an option without a value, or no option at all: usage message, exit 2.
2. **Find the server.** `_need_server NAME`. Missing `servers/NAME/server.env`: `die` exit 1, naming the file.
3. **Merge and validate.** Read `server.env` with `kv_lines`; take TYPE, VERSION, MEMORY, CPUS, HOSTNAME_SLUG, EULA, BACKUP_ENV_FILE with the renderer's defaults; overlay the flags. Run `SE_CTX="mcctl edit" check_server_values ...`. Any problem: every problem printed, exit 2, nothing touched, no Docker call.
4. **State.** `docker inspect --format '{{.State.Status}}' mc-NAME`. `running`, `restarting` and `paused` are live; anything else (`exited`, `created`) is stopped.
5. **Live server: who is online.** `rcon_exec NAME list`. Parse the reply with `There are ([0-9]+) of a max`. Print `NAME: N players online` (or `NAME: could not ask who is online`) with `info`.
   - N above 0, or RCON failed, or the reply does not parse: require `MCCTL_YES=1`. Without it: exit 4, message contains `players online` (or `who is online`) and `--yes`. An interactive "y" does not replace `--yes` here.
   - N equal to 0: `confirm "Restart NAME now to apply ...?"`. A no (or no terminal): exit 4, "nothing was changed".
6. **Stopped server.** No question: nothing is lost.
7. **Write.** Keep the old `server.env` text in memory. Replace the `MEMORY=` and `CPUS=` lines in place (append a line when the key is absent), keep every other line and comment byte for byte, and write through `write_atomic` (helper `_env_put`, private to `lib/servers.sh`). Then `write_compose NAME`. If it fails, put the old `server.env` back and exit with the renderer's status; both files end as they were.
8. **Apply.**
   - Live: `dc NAME up -d --force-recreate` (whole project), then `router_reload`; a failed reload is only a `warn` (the container is already up).
   - Stopped: `dc NAME create --force-recreate`.
   - If the Docker call fails: exit 1, message says the files are already written and that running the same `mcctl edit` again re-applies them.
9. **Success.** `info "NAME: memory M, cpus C applied (restarted | recreated, still stopped)"`, exit 0.

An `edit` with values equal to the current ones still writes and recreates: it doubles as "apply again". No other command re-applies before Task 14.

## 5. Tests (`single-standalone/tests/t_edit.sh`; every refusal produces zero `docker compose` calls unless stated)

Helpers: `sandbox`, `m`, `calls`, `count_calls`, `fake_server NAME HOST [STATE]`, `plant_canary`, `assert_*` in `single-standalone/tests/lib.sh`. Make a server with `m create s1 --type PAPER --accept-eula` (the existing tests show the setup). The fake `docker` replays `$FAKE_STATE/docker.inspect` (State.Status), `docker.exec` (stdout of `rcon-cli`) and `docker.exec.rc`; `docker.compose.up.rc` fails the recreate. A call the fakes do not know fails the test.

1. **Usage.** `edit` alone, `edit s1` (no option), `edit s1 --memory` (no value), `edit s1 --bogus 1`, and `edit Bad --memory 2G`: exit 2 each; unknown server `edit nope --memory 2G`: exit 1 and `no server named`.
2. **Validation.** `--memory '6 gigs'`, `--memory 0G`, `--cpus 0`, `--cpus abc`: exit 2, message names MEMORY or CPUS, `server.env` and `compose.yaml` byte-identical (compare `cksum` before and after), `count_calls '^docker compose'` is 0. `--memory 6G --cpus 1.5` together is valid.
3. **Stopped server.** `docker.inspect` = `exited`, no `--yes`, no terminal: exit 0. `server.env` has `MEMORY=6G`; its comment line and every other line are unchanged; `compose.yaml` has `MEMORY: "6G"` and `mem_limit: "7936m"`. The call log is `docker inspect ...` then `docker compose -p mcctl-s1 -f <root>/servers/s1/compose.yaml create --force-recreate`; no `up`, no `start`, no `exec`.
4. **Running, 0 players, no `--yes`.** Reply `There are 0 of a max of 20 players online:`. Exit 4, message contains `confirmation`; files byte-identical; no `compose` call. With `--yes` (global flag): exit 0; calls in order: `docker inspect`, `docker exec -i mc-s1 rcon-cli list`, `docker compose ... up -d --force-recreate` with **no service name after it**, then `... kill -s HUP mc-router`.
5. **Running, 2 players.** Reply `There are 2 of a max of 20 players online: a, b`. Without `--yes`: exit 4, message contains `2 players online` and `--yes`; files unchanged. With `--yes`: proceeds as in test 4.
6. **RCON unknown.** `docker.exec.rc` = 1: exit 4 without `--yes`, message contains `who is online`; with `--yes`: proceeds. Same for a reply that does not parse (`Unknown command`).
7. **Preservation.** A `server.env` with a comment, an unrelated key (`MOTD`-like) and no `MEMORY=`: after `edit --memory 3G` the key is appended once, everything else is unchanged. A `server.env` with `CPUS=2` between other keys: `--cpus 1` replaces that line in place.
8. **Render failure rolls back.** Put `API_TOKEN=x` in `servers/s1/modpack.env` (the renderer refuses credential-looking keys): `edit s1 --memory 6G --yes` exits non-zero, `server.env` and `compose.yaml` are byte-identical to before, and there is no `docker compose` call and no `*.tmp` file left in the server folder.
9. **Recreate failure (E7).** `FAIL_AT=1` on a running server with `--yes`: exit 1, message says the files are written; `server.env` has the new value. A second run without `FAIL_AT` exits 0 and recreates.
10. **Missing `server.env`.** Delete it: exit 1 naming the file, no `compose` call.
11. **Secret canary (E4).** `plant_canary "$R/secrets/rcon-s1"`; after tests 3 to 6 the canary is in neither `calls` nor `$OUT`. The `list` call is exactly `docker exec -i mc-s1 rcon-cli list`.
12. **Modes (E12).** After a successful edit `server.env` and `compose.yaml` are mode 600 (`posix_modes_ok`, otherwise the harness prints SKIP).
13. **Help and E3.** `m help` lists `edit`. `cmd_edit` is named in `t_edit.sh`. No new recursive `rm`.
14. **Flow (E13).** One block in `single-standalone/tests/t_flows.sh`: create, start (fake running), `edit s1 --memory 6G` with `--yes`, then assert the whole ordered call log from `inspect` to the HUP.

## 6. Files

- Create: `single-standalone/tests/t_edit.sh`.
- Modify: `single-standalone/lib/servers.sh` (add `cmd_edit` and `_env_put`; append after `cmd_kill`, and do not touch create or delete), `single-standalone/tests/t_flows.sh` (one flow), `single-standalone/docs/reference.md` (new `## mcctl edit` section).
- Do not modify: `single-standalone/mcctl`, `single-standalone/lib/compose.sh`, `single-standalone/templates/*`.

Task 9 (SFTP) edits `lib/servers.sh`, `templates/stack.compose.yml`, and `docs/reference.md` while this spec is being written. Re-read each file right before editing it, and change only the lines you add.

## 7. Documentation (`single-standalone/docs/reference.md`, section `## mcctl edit`)

Syntax and two examples; what is rewritten; the three outcomes (live restart, stopped recreate, refused); the player rule with the exact messages; the exit codes (0 applied, 1 Docker or unknown server, 2 bad input, 4 refused); why the whole project is recreated (the backup sidecar shares the server's network namespace); that running the same command again re-applies; and one troubleshooting row for "files written but the recreate failed".

## 8. Carry-overs this task creates (the controller copies them to the ledger)

- Recreate rule, project-wide: a recreate always covers the whole compose project, never `mc` alone. Binding on Tasks 14 (`apply_pending`), 16, 18, 21.
- `_env_put FILE KEY VALUE` is private to Task 10. Task 14's `server_env_set NAME KEY [VALUE]` replaces it; Task 14 deletes `_env_put` and moves the recreate call from `cmd_edit` into `apply_pending`, keeping this task's call-log tests green.
- Acceptance (Task 23, step 10) gains: with `--yes` the server returns with the new limit (`docker stats` shows it) and `mcctl backup NAME now` still works afterwards.

## 9. Not provable in the sandbox (owed to the user's acceptance run)

- That `docker compose create --force-recreate` and `up -d --force-recreate` behave as stated on the installed Compose version.
- That the sidecar reaches RCON after a recreate, and that mc-router routes to the recreated container.
- That the JVM heap and `mem_limit` really change (`docker stats`, `docker inspect`).

## 10. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_edit.sh`, then the whole suite in the background (about ten minutes on this host): `DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/run.sh` and `bash single-standalone/tests/t_invariants.sh`, both at 0 failed. Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-10-report.md`.

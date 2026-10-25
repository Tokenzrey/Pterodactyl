# mcctl (single-standalone) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure-Bash, UI-less CLI (`mcctl`) that creates and operates many independent `itzg/minecraft-server` containers behind one mc-router port, with Cloudflare DNS, backups, SFTP, RCON player management, host firewall, and live monitoring/log views.

**Architecture:** One folder per server (`servers/<name>/` with a generated `compose.yaml`, a `server.env`, a `secrets/` dir and a `data/` bind mount). Docker labels are the only registry: `mcctl list` reads containers, never a file. One shared stack (`mc-router`, `egress-guard`, one SFTP container) is started once by `mcctl init`; each server adds an `itzg/mc-backup` sidecar. Library files under `lib/` mirror `ptero`'s one-concern-per-file split, and the test harness copies `ptero`'s fakebin + sandbox discipline.

**Tech Stack:** Bash >= 4.4, Docker Engine + Compose plugin, `curl`, `jq`, ufw/iptables, images `itzg/minecraft-server`, `itzg/mc-backup`, `itzg/mc-router`, `atmoz/sftp`.

**Spec:** `docs/superpowers/specs/2026-10-24-single-standalone-mcctl-design.md`. Reference only (never imported or called): `ptero`, `lib/firewall.sh`, `compose.wings.yml` (`egress-guard`), `tests/lib.sh`, and `single-standalone/docs/itzg/` (itzg docs).

## Global Constraints

- Platform: Ubuntu VPS (primary) and WSL; no code path that works on only one.
- Language: pure Bash >= 4.4; no new interpreter or TUI library. Monitoring and logs use ANSI escapes and `tput` only.
- Independence: no call into, config read from, or shared state with Pterodactyl, Wings, or `ptero`.
- Image: every Minecraft server runs `itzg/minecraft-server`; modpacks use itzg's built-in `AUTO_CURSEFORGE` / `MODRINTH` support, never a custom installer.
- State: Docker (containers and labels) is the only source of truth. No `servers.json`, no database.
- Deploy unit: one folder per server, one generated `compose.yaml` per server.
- Secrets: no credential is ever a plain `environment:` value. Each is a file (mode 600) referenced with the `_FILE` suffix. Never in flags, `ps`, shell history, or `docker inspect`.
- Network: one public port (25565) plus SSH. Game containers cannot reach the host, LAN, or cloud metadata. Cloudflare records for the game port are DNS-only (`proxied: false`), and the docs never claim a hidden origin IP.
- RCON: password overridable per server through its env file; wrappers are thin layers over one raw `mcctl rcon` primitive.
- Resource edits: `mcctl edit` regenerates compose and recreates the container only after an explicit confirm (and refuses silently-restarting a server that has players online).
- Router: `create` and `delete` both signal mc-router (`compose kill -s HUP mc-router`) after changing labels.
- Scope cuts: no Velocity/BungeeCord automation (docs only), no generic cron (backup scheduling only), no web UI.
- Commits: no `git commit` unless the user has asked for it. Steps that say "Commit" are skipped otherwise.
- File and world safety: every path argument is confined to the server's `data/` directory (no absolute path, no `..`, no symlink that leaves it). Every archive that is imported has its member names checked before anything is extracted (no absolute path, no `..`, no link members). Operations that rewrite or delete a world, the mods, or the server version take a verified safety archive first and change nothing when it fails.
- One-shot flags (`*_FORCE_REINSTALL`, `FORCE_REDOWNLOAD`, `REMOVE_OLD_MODS`) are applied once and removed again; they never count as pending configuration.
- EULA: `create` writes `EULA=TRUE` only when the caller passes `--accept-eula`; there is no default acceptance.
- Compose safety: every value written into a rendered compose file is escaped (`$` becomes `$$`, quotes and newlines are refused or escaped), so a MOTD, mod URL, or player name cannot inject a variable or a key.
- Docs: every task that adds a command also adds its section to `single-standalone/docs/` (Task 22 assembles and checks them).
- Execution: subagent-driven on the main working tree (`D:\Documents\code\pterodactyl`, branch `main`). No git worktree and no commits. Verification is the Test Gate below, not per-task code review.
- Sandbox: every test runs with `MCCTL_ROOT` set to a fresh `mktemp -d`, `tests/fakebin` first on `PATH`, and `DOCKER_HOST=unix:///nonexistent`. `run.sh` refuses to start otherwise. Tests never touch real Docker, Cloudflare, or the network; the 2026-10-21 Pterodactyl incident (a test removed the live stack) is the reason.
- Line endings: LF only. A CR byte in a `.sh` file fails under WSL (`$'\r': command not found`); E3 enforces it.
- Recreate: a recreate always covers the whole compose project (game container and backup sidecar together), never `mc` alone. The sidecar shares the game container's network namespace (`network_mode: "service:mc"`), so recreating `mc` alone leaves it attached to a dead namespace. `docker compose start` does not apply a changed `compose.yaml`; a stopped server is recreated with `create --force-recreate`.

## Review Focus

Failure modes the spec implies but no feature task exercises by itself. Each has a pinning test in the owning task. (Items 1 to 5 came with the first plan; 6 to 9 were added with the world and server management tasks.)

1. **Name that yields an empty or colliding slug** (`!!!`, or `Survival` vs `survival`): `create` must refuse, never produce a host like `.mc.example.com`. Pinned in Task 3.
2. **Half-finished create or delete** (DNS record made but container fails, or container removed but DNS call fails): no orphan record, no orphan container, and a re-run finishes the job. Pinned in Task 7.
3. **Player name that is really a command** (`mcctl ban s1 "x; stop"`): rejected before it reaches RCON. Pinned in Task 5.
4. **Port 25565 already taken on the host** (for example by an existing `ptero` mc-router): router start refuses with a message naming the listener. Pinned in Task 6.
5. **Restore overwriting a live world**: restore takes a safety backup first and refuses while the server runs. Pinned in Task 8.
6. **A backup that leaves autosave off**: `world backup` and `clone --with-data` on a running server turn saving off; if `tar` fails, saving must still be switched back on. Pinned in Task 16.
7. **A hostile or damaged archive** (`world import`, `import`): member names with `..`, absolute paths, or links must be refused before any file is written. Pinned in Tasks 16 and 21.
8. **A mod or plugin entry that is really markup** (`$`, quotes, newlines in a URL, MOTD, or list entry): must never reach the rendered compose as anything but inert text. Pinned in Tasks 14 and 20.
9. **Downgrading a world's Minecraft version**: refused unless the caller says otherwise. Pinned in Task 18.

## Execution and Test Gate (replaces per-task code review)

**Execution.** One implementer subagent at a time, in task order. Its brief is the task section, Global Constraints, this section, and the Interfaces of the tasks it consumes. It reads nothing else of the plan. It never dispatches subagents and never runs real `docker`, `sudo`, or `git` history commands.

**Gate.** No reviewer subagent runs per task or at the end. The controller runs the gate itself after each implementer report. A task is complete when all four pass:
1. The task's own tests (the failing-then-passing tests in its Step 1).
2. The whole suite in WSL, 0 failed: `wsl.exe bash -c 'bash /mnt/d/Documents/code/pterodactyl/single-standalone/tests/wsl-run.sh'` (copies code and tests to a disposable directory, runs `tests/run-par.sh` with one job per core, about 20 seconds). Windows `tests/run.sh` is not the gate: the Git Bash fork makes it about thirty times slower.
3. `bash single-standalone/tests/t_invariants.sh`, 0 failed.
4. The expanded tests the task owns (table below).

A skip is never a pass. A check the host cannot run (a POSIX permission check on Git Bash for Windows, `shellcheck` when absent) prints `SKIP <reason>`. `run.sh` ends with `N passed, M failed, K skipped`, and the controller records K in the ledger.

**Fix loop.** Red gate: the controller resumes the same implementer with the failing output, three rounds at most. Then the same brief goes to an implementer on the next model tier, with the failure history. A plan defect the implementer hits is decided by the implementer, written in its report as `Ruling: <what> — <why> — <cost if wrong>`, and copied by the controller to the ledger.

**Models.** All subagents: `haiku` at effort `xhigh` (user instruction, 2026-10-24). The per-task choices below are superseded. Previously: Sonnet for most tasks. Opus for Tasks 7, 16 and 21 (create/delete ordering, world deletion and restore, rename and import: a mistake loses data). Task 12 (widths in two locales) and Task 22 (a link and anchor checker in Bash) are real code and also take Sonnet. Task 23 is run by a person.

**Ledger.** `.superpowers/sdd/2026-10-24-single-standalone-mcctl/progress.md`, git-ignored. One line per task: `Task N: complete (gate green, K skipped, assertions A)`. The assertion count never decreases from one task to the next.

**Expanded tests.** Owner builds it; "Extended by" lists the tasks that add cases to it.

| ID | What it checks | Owner | Extended by |
|---|---|---|---|
| E1 | Strict fakebin: `docker`, `curl`, and `rcon-cli` fakes append every call (argv, one line) to `$FAKE_STATE/calls.log`. An unknown subcommand exits 97 and logs `UNKNOWN`. Flow tests assert the ordered call log, not only exit codes. | 0 | every task |
| E2 | `run.sh` fails any `t_*.sh` that records zero assertions. | 0 | — |
| E3 | `tests/t_invariants.sh`, static, whole tree: `bash -n` on every `.sh` and on `mcctl`; no `eval`; no `sudo`; every `rm -rf` in `lib/` sits on a line, or directly under a line, that calls `safe_path` or `valid_server_name`, or takes a literal target; no CR byte in `mcctl`, `lib/`, `tests/`, `templates/`; every `cmd_*` function in `lib/` is named in at least one `tests/t_*.sh`; `shellcheck` when installed, else SKIP. | 0 | every task appends its rules |
| E4 | Secret canary: `tests/lib.sh` gets `plant_canary PATH`, which writes a unique value into a secret file. Flow tests assert the value appears in neither `calls.log` nor the command's stdout or stderr. Exempt: `export --with-secrets`, tested in Task 21. | 0 | 2, 3, 7, 9, 14, 21 |
| E5 | Golden renders: `tests/golden/*.compose.yaml` for six fixtures (vanilla, paper, fabric with modrinth, curseforge, forge, and a MOTD containing `$`, a double quote, and a backslash). `UPDATE_GOLDEN=1` rewrites them; without it a diff fails. | 2 | 14, 18, 20 |
| E6 | Property test `tests/t_fuzz.sh`: 300 inputs from lower-case letters, digits, space, tab, newline, `/`, `.`, `..`, and the metacharacters `$ ' " \ ; \| & `backtick` ( ) * ? [ ] { } % # !`, generated with `RANDOM=20261024`. Each input goes in a subshell through `valid_server_name`, `slugify`, `safe_path`, `valid_world_name`, `valid_mod_entry`, `valid_modrinth_entry`, and `compose_escape`. Pass: exit 0 with output only `[a-z0-9-]` for slugs, or refusal with exit 2; in `compose_escape` every `$` is doubled and every `"` is escaped; no run exits with any code other than 0 or 2. | 3 | 4, 14, 16, 20 |
| E7 | Failure injection `tests/t_failure.sh`: the fakebin reads `FAIL_AT=n` and fails the n-th mutating call (`docker compose create/up/rm/stop/kill`, curl `POST/PUT/DELETE`). For every mutating command and every n from 1 to its call count: exit is EX_FAIL or EX_REFUSED; no container without its folder and no folder without its container; the DNS fake state matches the containers; a re-run without `FAIL_AT` completes. | 7 | 8, 9, 16, 18, 21 |
| E8 | Hostile archives `tests/t_archive.sh`: tar fixtures with `../escape`, an absolute path, a symlink to `/etc` and one to `../..`, a hardlink to a file outside, and a member name containing a newline. `world import`, `world restore`, and `import` exit EX_REFUSED and write zero files outside the target (sentinel checked). Symlink fixtures SKIP where symlinks are unsupported. | 16 | 21 |
| E9 | Version table in `tests/t_versions.sh`: at least 20 pairs for `version_cmp`, including `1.9 < 1.10`, `1.21 < 1.21.1`, `1.20.4 > 1.20`, `LATEST` and `SNAPSHOT` tokens, and snapshot ids such as `24w14a`, which downgrade decisions refuse. | 18 | — |
| E10 | Output widths in `tests/t_monitor.sh` and `tests/t_logs.sh`: `render_top_frame` and `colorize_log_line` at `COLUMNS` 80, 120, and 200; every visible line of a frame has the same width; `NO_COLOR=1` output is byte-identical to the text. | 12 | — |
| E11 | Atomic writes: `write_atomic PATH` writes a temp file in the same directory, then `mv`. A failing producer leaves the previous file unchanged and no `*.tmp` behind. Every writer in Tasks 14, 17, and 20 uses it. | 3 | 14, 17, 20 |
| E12 | Permissions: secret files mode 600 and server folders mode 700 after `create`, `files put`, and `import`. On hosts without POSIX modes, SKIP with reason. | 3 | 15, 21 |
| E13 | Flow tests `tests/t_flows.sh`: each command sequence in acceptance steps 2 and 11 to 17 runs against the fakes, with the ordered call log asserted. Example: `world backup` produces save-off, save-all flush, tar, save-on, in that order, with save-on also run when tar fails. Each task adds its own flow. | 3 | 5 onward |

## Decisions the planner made (check these while reading)

- **No published host ports.** The design text said servers bind `127.0.0.1:<port>`. With itzg's label-based mc-router the router reaches game containers over the shared Docker network, so game containers publish nothing and only the router publishes 25565. Smaller attack surface; deviates from the earlier conversation wording.
- **RCON password is generated once per server, not per restart.** `itzg/mc-backup` and `mcctl rcon` must authenticate to a server whose password is random per restart. Unless Spike S2 (Task 5) proves the sidecar can read the live password without a shared file, the default is: a random 32-character password written to `servers/<name>/secrets/rcon_password` at `create`, passed to the server and the sidecar via `RCON_PASSWORD_FILE`, editable by hand, regenerated by `mcctl rotate-rcon <name>`. This departs from "random per restart".
- **The egress guard needs a router exemption.** `ptero`'s guard drops `GAME_SUBNET -> 172.16.0.0/12`. If the router sits on the game subnet, that rule also drops router-to-game connections. The guard gets a static router IP and an explicit `RETURN` for `router -> GAME_SUBNET` placed before the drops. Fake iptables cannot prove packet flow, so Task 6 has a real-Docker spike and Task 23 re-checks it.
- **Upstream names to pin in-task, not from memory:** `itzg/mc-backup` variable names, the Modrinth modpack variable, and `CF_API_KEY_FILE`. Each owning task starts with a step that reads the upstream page and records the names in the task's test.
- **Command name `mcctl`.**
- **Lists are declarative.** Mods, plugins, and Modrinth projects are kept as one-entry-per-line files under `servers/NAME/lists/` and rendered as itzg block-scalar variables, matching how itzg treats them (an entry removed from `MODS` or `PLUGINS` is removed from disk). An empty or absent list means "do nothing"; deleting installed files is a separate, confirmed option.
- **File and world access goes through a throwaway helper container** (`data_run`), not through the host's file permissions and not through `sudo`. It runs with `--network none` as the game's UID.
- **Pending configuration is detected, not stored.** The rendered compose is hashed into a `mcctl.config_hash` label at create/apply time; `status` compares it with the current render. That keeps Docker the only registry.
- **Worlds are found, not registered.** A world is any directory in `data/` that holds `level.dat`; the active one is the `LEVEL` variable. World changes go through the environment (itzg rewrites `server.properties` from it), never by editing `server.properties`.
- **Runtime wrappers are validated, not free-form.** `gamerule`, `time`, `weather`, `worldborder`, `say`, and the player commands accept only values from a fixed grammar; anything else is refused before RCON. `mcctl rcon` remains the one raw escape hatch.
- **EULA stays an explicit act.** `create` needs `--accept-eula`.

## File Structure

```
single-standalone/
├── mcctl                         entrypoint: dispatch, sources lib/*.sh
├── lib/
│   ├── common.sh                 logging, die/confirm, mkdir_private, write_secret, slugify, valid_server_name
│   ├── config.sh                 load/validate config/mcctl.env
│   ├── compose.sh                paths, render_server_compose, dc wrapper
│   ├── servers.sh                create/start/stop/restart/kill/delete/list/status/edit
│   ├── modpack.sh                modpack_env: source+id+version -> itzg env lines
│   ├── rcon.sh                   rcon_exec, player wrappers, rcon secret
│   ├── router.sh                 init/up router stack, reload, port check
│   ├── cloudflare.sh             DNS create/delete, token secret
│   ├── backup.sh                 sidecar env mapping, now/list/restore/prune
│   ├── sftp.sh                   shared SFTP container, per-server chroot user
│   ├── firewall.sh               ufw plan/apply/confirm/rollback, rate limit
│   ├── monitor.sh                `mcctl top` renderer + loop
│   ├── logs.sh                   `mcctl logs` colorizer + stream
│   ├── settings.sh               set/get/unset, properties, drift hash, apply, motd/icon/resourcepack/autostart
│   ├── data.sh                   data_run helper container, safe_path, file manager
│   ├── worlds.sh                 world list/info/use/new/rename/delete/backup/restore/export/import/reset/seed/datapack
│   ├── versions.sh               version, type, upgrade, reinstall, downgrade guard
│   ├── mods.sh                   mods/plugins/modrinth list files and commands
│   └── portable.sh               info, clone, rename, export, import, exec, shell
├── templates/
│   ├── server.compose.tmpl       one server + its backup sidecar
│   └── stack.compose.yml         mc-router + egress-guard + sftp
├── config/mcctl.env.example
├── tests/                        lib.sh, run.sh, fakebin/, t_*.sh
├── docs/                         README, architecture, prerequisites, reference, troubleshooting, velocity
├── secrets/                      gitignored, mode 700
└── servers/                      gitignored
```

## Tasks

### Task 0: Scaffold, shared helpers, test harness

**Files:**
- Create: `single-standalone/mcctl`, `single-standalone/lib/common.sh`, `single-standalone/tests/lib.sh`, `single-standalone/tests/run.sh`, `single-standalone/tests/fakebin/docker`, `single-standalone/tests/t_common.sh`, `single-standalone/.gitignore`
- Test: `single-standalone/tests/t_common.sh`

**Interfaces:**
- Produces (`lib/common.sh`): `info MSG`, `warn MSG`, `err MSG`, `die MSG [CODE]`, `confirm PROMPT` (returns 0 yes / 1 no, honours `MCCTL_YES=1`), `mkdir_private DIR...` (mode 700), `write_secret PATH VALUE` (atomic, mode 600), `slugify NAME` (stdout), `valid_server_name NAME` (0/1). Exit codes `EX_FAIL=1 EX_USAGE=2 EX_PREFLIGHT=3 EX_REFUSED=4`.
- Produces (Test Gate E1–E4): the strict fakebin logging to `$FAKE_STATE/calls.log` and exiting 97 on unknown subcommands; the zero-assertion guard in `run.sh`; `tests/t_invariants.sh`; `plant_canary PATH` in `tests/lib.sh`.
- Produces (`tests/lib.sh`): the same helpers `ptero` uses: `pass`, `fail`, `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_file`, `assert_mode`, `sandbox`, `sandbox_cleanup`, `m` (runs `./mcctl` in the sandbox, sets `OUT` and `RC`), plus `assert_fakes_first` (refuses to run if `docker` on `PATH` is not the fake).

- [ ] **Step 1: Write the failing tests** in `tests/t_common.sh`:

```bash
assert_eq "kampung-2"  "$(slugify 'Kampung 2!')"        "slug of a name with punctuation"
assert_eq ""           "$(slugify '!!!')"               "slug of punctuation only is empty"
assert_eq "$(printf 'a%.0s' {1..40})" "$(slugify "$(printf 'a%.0s' {1..60})")" "slug is cut to 40 characters"
valid_server_name "survival-1"  && pass "valid name accepted"  || fail "valid name accepted"
valid_server_name "Survival"    && fail "upper case refused"   || pass "upper case refused"
valid_server_name ""            && fail "empty refused"        || pass "empty refused"
write_secret "$SB/s" "v"; assert_mode "$SB/s" 600 "write_secret sets mode 600"
```

- [ ] **Step 2: Run** `bash single-standalone/tests/t_common.sh`. Expected: FAIL (`slugify: command not found`).
- [ ] **Step 3: Implement** `lib/common.sh` per the Interfaces block. `slugify` uses the same rule as `lib/games.py slugify` in the repo root (lower-case, runs of non `[a-z0-9]` become one `-`, trim `-`, cut to 40, trim `-` again). `valid_server_name` accepts `^[a-z0-9][a-z0-9-]{0,39}$`. `tests/fakebin/docker` appends its arguments to `$FAKE_STATE/calls.log` and replays canned output from `$FAKE_STATE/docker.*` files. `mcctl` dispatches `mcctl <cmd>` to `cmd_<cmd>` and prints usage for unknown commands with `EX_USAGE`. `tests/run.sh` runs every `t_*.sh` and exits non-zero on any failure, and refuses to start unless `assert_fakes_first` passes.
- [ ] **Step 4: Run** `bash single-standalone/tests/run.sh`. Expected: `t_common.sh: 7 passed, 0 failed`.
- [ ] **Step 5: Commit** `feat(mcctl): scaffold, helpers and test harness`.

### Task 1: Configuration and `mcctl init`

**Files:**
- Create: `lib/config.sh`, `config/mcctl.env.example`, `tests/t_config.sh`
- Modify: `mcctl` (source `lib/config.sh`; add `init`, `doctor`)

**Interfaces:**
- Consumes: `die`, `mkdir_private`, `write_secret` (Task 0).
- Produces: `load_config` (exports `MCCTL_ROOT`, `MCCTL_DOMAIN`, `MCCTL_PUBLIC_IPV4`, `MCCTL_CF_ZONE_ID`, `MCCTL_GAME_SUBNET` default `172.30.0.0/24`, `MCCTL_ROUTER_IP` default `172.30.0.2`), `require_config KEY...` (dies with `EX_PREFLIGHT` naming each missing key), `cmd_init`, `cmd_doctor`.

- [ ] **Step 1: Write the failing tests** (`t_config.sh`): `init` creates `secrets/` and `servers/` with mode 700; `require_config MCCTL_DOMAIN` exits 3 and prints the key name when unset; a `secrets/cloudflare_token` with mode 644 makes `doctor` fail with the `chmod 600` hint (the same message `ptero`'s `lib/config.sh` gives); an invalid `MCCTL_PUBLIC_IPV4` (`999.1.1.1`) is rejected.
- [ ] **Step 2: Run** `bash tests/t_config.sh`. Expected: FAIL.
- [ ] **Step 3: Implement** `load_config` (source `config/mcctl.env` if present; values already in the environment win), the validators, and `cmd_init` (dirs only, no Docker yet). `cmd_doctor` checks bash version, `docker compose version`, `jq`, `curl`, secret file modes, and prints one `[ok]`/`[FAIL]` line each.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): config loading, init and doctor`.

### Task 2: Server compose renderer

**Files:**
- Create: `templates/server.compose.tmpl`, `lib/compose.sh`, `tests/t_compose.sh`, `tests/fixtures/server.env.basic`

**Interfaces:**
- Consumes: `load_config` (Task 1).
- Produces: `server_dir NAME` (`$MCCTL_ROOT/servers/NAME`), `container_name NAME` (`mc-NAME`), `render_server_compose NAME` (reads `servers/NAME/server.env`, prints compose YAML to stdout), `dc NAME ARGS...` (`docker compose -p mcctl-NAME -f servers/NAME/compose.yaml ARGS...`), `compose_escape VALUE` (stdout the value made safe for a compose scalar: `$` becomes `$$`, a double quote and a backslash are escaped, a newline is an error). The renderer also reads the list files under `servers/NAME/lists/` and `modpack.env`; Task 14 adds the `mcctl.config_hash` label and Task 20 adds the list-file block scalars, both through this same renderer.
- `server.env` keys read by the renderer: `TYPE`, `VERSION`, `MEMORY`, `CPUS`, `HOSTNAME_SLUG`, `MODPACK_ENV` (zero or more extra `KEY=VALUE` lines kept in a separate file `servers/NAME/modpack.env`), `BACKUP_ENV_FILE`.

- [ ] **Step 1: Write the failing tests** (snapshot-style assertions on the rendered text, no Docker): the output has `image: itzg/minecraft-server`; labels `mcctl.managed=true`, `mcctl.name=NAME`, `mcctl.hostname=HOST`, `mc-router.host=HOST.DOMAIN`; `mem_limit` and `cpus` present; **no `ports:` key at all**; `RCON_PASSWORD_FILE` appears and `RCON_PASSWORD:` does not; the backup sidecar service uses `itzg/mc-backup`; no secret value appears anywhere in the output (a canary string put in `secrets/` is absent); rendering twice yields identical output; the game container is attached to the `mcctl_game` network; `compose_escape 'a$b"c'` returns `a$$b\"c`, and a value containing a newline makes the renderer exit non-zero instead of emitting it.
- [ ] **Step 2: Run** `bash tests/t_compose.sh`. Expected: FAIL.
- [ ] **Step 3: Implement** the template and `render_server_compose` with `envsubst`-free pure Bash substitution (ponytail: no new dependency); the renderer never writes files itself.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): server compose renderer`.

### Task 3: Server lifecycle (create, start, stop, restart, kill, delete, list, status)

**Files:**
- Create: `lib/servers.sh`, `tests/t_servers.sh`
- Modify: `mcctl`, `lib/compose.sh`

**Interfaces:**
- Consumes: `slugify`, `valid_server_name`, `render_server_compose`, `dc`, `container_name`.
- Produces: `server_exists NAME` (0/1, asks Docker: `docker ps -a -q --filter label=mcctl.name=NAME`), `server_label NAME KEY` (stdout, via `docker inspect`), `hostname_taken HOST` (0/1, same label query), `cmd_create`, `cmd_start`, `cmd_stop`, `cmd_restart`, `cmd_kill`, `cmd_delete`, `cmd_list`, `cmd_status`.
- `mcctl create NAME --type T --accept-eula [--version V] [--memory 4G] [--cpus 2] [--hostname H] [--modpack-source curseforge|modrinth --modpack ID [--modpack-version V]]`. Defaults: `--version LATEST`, `--memory 4G`, `--cpus 2`, `--hostname` = `slugify NAME`.

- [ ] **Step 1: Write the failing tests** (fake `docker`): `create s1 --type PAPER` without `--accept-eula` is refused with `EX_USAGE` and a message that links the Mojang EULA, and with the flag `server.env` has `EULA=TRUE`; `create Survival` is refused (`EX_USAGE`, upper case); `create '!!!'` and a name whose slug is empty are refused with a message naming the problem; creating a second server whose hostname equals an existing one is refused and names the first server; `create s1` writes `servers/s1/{server.env,compose.yaml}` and `docker compose ... create` was called; `list` prints one row per fake container carrying `mcctl.managed=true`, and **never reads** `servers/` (prove it by deleting the folder and still listing); `delete s1` without `--yes` asks `confirm`; `delete` of an unknown server exits non-zero; `delete` is idempotent when the container is already gone.
- [ ] **Step 2: Run** `bash tests/t_servers.sh`. Expected: FAIL.
- [ ] **Step 3: Implement** the commands. `create` order: validate → check name/hostname → write files → `dc NAME create` (container exists but is stopped; Docker is now the record). DNS and router signalling are added in Task 7, not here.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): server lifecycle`.

### Task 4: Modpack environment mapping (CurseForge and Modrinth)

**Files:**
- Create: `lib/modpack.sh`, `tests/t_modpack.sh`
- Modify: `lib/servers.sh` (write `modpack.env` during `create`), `lib/compose.sh` (include `modpack.env` via `env_file:`)

**Interfaces:**
- Consumes: `write_secret`, `server_dir`.
- Produces: `modpack_env SOURCE ID [VERSION]` (prints `KEY=VALUE` lines to stdout; exit 2 on an unknown source or an empty ID).

- [ ] **Step 1: Read upstream and record the names.** Read the itzg CurseForge and Modrinth modpack pages (links in `single-standalone/docs/itzg/modpacks.md`) and the `CF_API_KEY` / `CF_API_KEY_FILE` note. Put the exact variable names in the test below. `single-standalone/docs/itzg/examples.md` already shows `MOD_PLATFORM: AUTO_CURSEFORGE` with `CF_SLUG`; `CF_PAGE_URL` is shown in `server-types.md`.
- [ ] **Step 2: Write the failing tests**: `modpack_env curseforge all-the-mods-10 9190157` prints `MOD_PLATFORM=AUTO_CURSEFORGE`, `CF_SLUG=all-the-mods-10`, `CF_FILE_ID=9190157` (confirm the file-id name in Step 1); a numeric CurseForge ID maps to the numeric-id variable instead of the slug; `modpack_env modrinth adrenaserver` prints the Modrinth platform variables from Step 1; an unknown source, an empty ID, or an ID containing a newline or `=` is refused; the CurseForge key is **never** printed: `create` with `--modpack-source curseforge` and no `secrets/curseforge_api_key` fails with `EX_PREFLIGHT`, and with the file present the rendered compose references it only through `CF_API_KEY_FILE`.
- [ ] **Step 3: Implement** `modpack_env`. The key file is mounted read-only into the container; the value never enters `modpack.env`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): CurseForge and Modrinth modpack mapping`.

### Task 5: RCON, console, and player management

**Files:**
- Create: `lib/rcon.sh`, `tests/t_rcon.sh`
- Modify: `lib/servers.sh` (generate the RCON secret in `create`), `lib/compose.sh` (mount it), `mcctl`

**Interfaces:**
- Consumes: `container_name`, `server_dir`, `write_secret`, `confirm`.
- Produces: `rcon_exec NAME CMD...` (stdout = server reply; runs `docker exec -i mc-NAME rcon-cli CMD...`, so no password is read by the script), `valid_player NAME` (0/1, regex `^[.A-Za-z0-9_]{1,16}$`), `ensure_rcon_secret NAME`, `cmd_rcon`, `cmd_console` (`docker exec -it ... rcon-cli`), `cmd_whitelist`, `cmd_ban`, `cmd_kick`, `cmd_op`, `cmd_players`, `cmd_rotate_rcon`.

- [ ] **Step 1: Spike S2 (real Docker, manual, 15 min).** Start one `itzg/minecraft-server` and one `itzg/mc-backup` and check, in this order: (a) does `rcon-cli` inside the server need no password argument; (b) can the sidecar obtain a per-restart random password without a shared file. Record the result in `docs/architecture.md`. If (b) is no, the default in "Decisions the planner made" stands. If (b) is yes, delete `ensure_rcon_secret` and the secret mount, and say so in the task commit.
- [ ] **Step 2: Write the failing tests** (fake docker): `rcon s1 say hi` runs exactly one `docker exec` with `rcon-cli`, the argument list `say hi`, and no password on the command line; `ban s1 "x; stop"` is refused before any `docker exec` (count calls: 0); `ban s1 Notch` is accepted and sends `ban Notch`; `whitelist add s1 Notch` sends `whitelist add Notch`; `kick`/`op` likewise; `create` writes `servers/s1/secrets/rcon_password` with mode 600 and 32 characters; `rotate-rcon` writes a different value and asks to restart; `console` on a stopped server fails with a message naming `mcctl start`.
- [ ] **Step 3: Implement** the functions. Player wrappers build the RCON string only after `valid_player`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): rcon, console and player management`.

### Task 6: Router stack and egress guard

**Files:**
- Create: `templates/stack.compose.yml`, `lib/router.sh`, `tests/t_router.sh`
- Modify: `lib/config.sh` (`MCCTL_GAME_SUBNET`, `MCCTL_ROUTER_IP`), `mcctl` (`up`, `down`)

**Interfaces:**
- Consumes: `load_config`, `die`.
- Produces: `router_port_free` (0 free / 1 taken; prints the listener from `ss -ltnp` when taken), `cmd_up` (checks the port, creates the `mcctl_game` network with `MCCTL_GAME_SUBNET`, then `docker compose -p mcctl-stack up -d --wait`), `cmd_down`, `router_reload` (`docker compose -p mcctl-stack kill -s HUP mc-router`).
- `stack.compose.yml` services: `mc-router` (image `itzg/mc-router`, `IN_DOCKER=true`, docker socket mounted `:ro`, the only published port `25565`, static IP `MCCTL_ROUTER_IP`), `egress-guard` (same shape as `compose.wings.yml`: `network_mode: host`, `cap_add: [NET_ADMIN]`, rules for `GAME_SUBNET` to `10/8 172.16/12 192.168/16 169.254/16 100.64/10`, a `RETURN` for `-s MCCTL_ROUTER_IP -d GAME_SUBNET` placed **before** the drops, and a healthcheck that is healthy only once the rules exist), `sftp` (added in Task 9).

- [ ] **Step 1: Spike S1 (real Docker, manual).** On Ubuntu and on WSL: start the stack, create a game container with the label `mc-router.host=probe.example.com`, and from the router container open a TCP connection to the game container's port 25565 **with the egress guard healthy**. It must succeed. Also confirm a game container cannot reach `192.168.0.1`, the host's docker bridge gateway, or `169.254.169.254`. If the first fails, fix the rule order in the template before writing the tests below. Record both results in `docs/architecture.md`.
- [ ] **Step 2: Write the failing tests**: `router_port_free` returns 1 and names the process when the fake `ss` shows a listener on 25565 (Review Focus 4); `up` refuses with `EX_PREFLIGHT` in that case and creates nothing; the stack template mounts `docker.sock` with `:ro`; it publishes exactly one port; the egress `RETURN` for the router appears before the first `DROP` in the rendered rule script; the healthcheck test string contains both an `INPUT` and a `DOCKER-USER` rule; `router_reload` issues `kill -s HUP mc-router`.
- [ ] **Step 3: Implement** the template and `lib/router.sh`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): mc-router stack and egress guard`.

### Task 7: Cloudflare DNS, and create/delete ordering

**Files:**
- Create: `lib/cloudflare.sh`, `tests/t_cloudflare.sh`, `tests/fakebin/curl`
- Modify: `lib/servers.sh` (call DNS and `router_reload` from `cmd_create` and `cmd_delete`)

**Interfaces:**
- Consumes: `require_config`, `router_reload`, `server_label`.
- Produces: `fqdn_for HOST` (`HOST.$MCCTL_DOMAIN`), `cf_api METHOD PATH [JSON]` (token read from `secrets/cloudflare_token` inside the function; never placed in an argument visible to `ps`: it is sent with `curl --config -` reading the header from stdin), `cf_create_record HOST` (prints the record id; creates `A`, `proxied:false`, `ttl:120`, `comment:"mcctl name=<server>"`), `cf_delete_record HOST` (deletes only a record whose name matches and whose comment starts with `mcctl `).

- [ ] **Step 1: Write the failing tests** (`fakebin/curl` is a small state machine over JSON files): the create request body has `"proxied": false` and the configured public IPv4; an existing record with the same name that **lacks** the `mcctl` comment makes `cf_create_record` fail without writing (never overwrites a foreign record); the token string never appears in the recorded `curl` argument lists; `cf_delete_record` on a foreign record deletes nothing; deleting an already-missing record succeeds (idempotent). **Ordering (Review Focus 2):** with the fake API failing the create call, `create s1` exits non-zero and `docker compose ... create` was **not** called; with the container create failing after DNS succeeded, the DNS record is deleted again; `delete s1` removes the container even when the DNS delete fails, prints a warning naming the record, and a second `delete s1` finishes the DNS step. `create` and `delete` each call `router_reload` exactly once.
- [ ] **Step 2: Run** `bash tests/t_cloudflare.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.** `create` order: validate → DNS record → write files → container create → `router_reload`; any later failure rolls back earlier steps in reverse. `delete` order: stop → container remove → DNS delete → `router_reload` → remove folder only after `--purge`; each step is safe to repeat.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): Cloudflare DNS and ordered create/delete`.

### Task 8: Backup and restore

**Files:**
- Create: `lib/backup.sh`, `tests/t_backup.sh`
- Modify: `lib/compose.sh` (sidecar env), `mcctl`

**Interfaces:**
- Consumes: `container_name`, `server_dir`, `confirm`, `dc`.
- Produces: `backup_env NAME` (prints the sidecar's `KEY=VALUE` lines from `servers/NAME/backup.env`), `cmd_backup NAME now|list|restore ID|prune`, `backup_dir NAME` (`servers/NAME/backups`).
- `create` accepts `--backup local|s3|rsync` and `--backup-interval 24h`; the destination's credentials are files under `servers/NAME/secrets/`.

- [ ] **Step 1: Read upstream and record the names.** Read the `itzg/mc-backup` README for the interval, method, destination, prune, initial-delay, and RCON variables, and for how S3 and rsync credentials are supplied (prefer its `_FILE` forms). Put the names in the tests below.
- [ ] **Step 2: Write the failing tests**: the rendered sidecar contains the interval and destination variables from Step 1 and no plain secret; `backup s1 now` triggers the sidecar's immediate backup (the exact command recorded in Step 1) and fails clearly when the server is stopped; `backup s1 list` lists files in `backups/` newest first; **(Review Focus 5)** `backup s1 restore ID` refuses while the container runs, takes a safety backup of the current `data/` before extracting, and aborts without touching `data/` if the archive fails `tar -tzf`; restore with `--yes` omitted asks `confirm`; `prune` keeps the configured number of newest archives.
- [ ] **Step 3: Implement.** Restore flow: refuse if running → verify archive → move current `data/` to `data.pre-restore-<timestamp>` → extract → report both paths.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): backup sidecar, list, restore, prune`.

### Task 9: Shared SFTP container

**Files:**
- Create: `lib/sftp.sh`, `tests/t_sftp.sh`
- Modify: `templates/stack.compose.yml` (add `sftp`), `lib/servers.sh` (call add/remove), `mcctl`

**Interfaces:**
- Consumes: `server_dir`, `die`.
- Produces: `sftp_add_user NAME` (creates the chrooted user `NAME`, mapped to the same UID/GID the game container uses, with `servers/NAME/data` as its writable directory), `sftp_remove_user NAME`, `cmd_sftp add-key NAME PUBKEYFILE` (key-only login; password login stays off).

- [ ] **Step 1: Write the failing tests**: `add-key` appends the key to that server's `authorized_keys` file with mode 600 and refuses a file that is not an OpenSSH public key; the generated users file contains one user per server and no password field; one server's user cannot list another server's directory (the rendered mount paths differ and none is a parent of another); `delete` removes the user entry and the key file; the SFTP port is **not** published on `0.0.0.0` unless `MCCTL_SFTP_PUBLIC=1` (default: bound to `127.0.0.1` only, reached through an SSH tunnel), and the firewall plan in Task 11 lists it only in that case.
- [ ] **Step 2: Implement** with `atmoz/sftp`; pin the chroot mechanics (root-owned chroot directory, writable subdirectory) in `docs/architecture.md`.
- [ ] **Step 3: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 4: Commit** `feat(mcctl): shared SFTP container with per-server users`.

### Task 10: Edit resources

Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-10.md`. It is binding for the exact behaviour, the corrections to the first version of this task (global `--yes`, stopped servers, the sidecar's network namespace, ask-before-write), and the 14 test cases.

**Files:**
- Create: `tests/t_edit.sh`
- Modify: `lib/servers.sh` (append `cmd_edit` and `_env_put`; do not touch create or delete), `tests/t_flows.sh` (one flow), `docs/reference.md` (section `## mcctl edit`)

**Interfaces:**
- Consumes: `_need_server`, `kv_lines`, `check_server_values`, `write_atomic`, `write_compose`, `confirm`, `rcon_exec`, `dc`, `container_name`, `router_reload`.
- Produces: `cmd_edit NAME [--memory SIZE] [--cpus N]` (`--yes` is the global flag, read as `MCCTL_YES`), private `_env_put FILE KEY VALUE` (replaced by Task 14's `server_env_set`).

- [ ] **Step 1: Write the failing tests** in `tests/t_edit.sh`, the 14 cases of the spec's section 5: usage; validation (`6 gigs`, `0G`, `--cpus 0`); a stopped server (`create --force-recreate`, no `up`, no `start`); a running server with 0 players (asks, exit 4 without `--yes`); with players or an unknown count (needs `--yes`, message names the count); every other `server.env` line kept; rollback when the render fails; a failing recreate (`FAIL_AT=1`) and the re-run; a missing `server.env`; the secret canary; file modes; `help` lists `edit`; one ordered flow in `tests/t_flows.sh`.
- [ ] **Step 2: Run** `bash tests/t_edit.sh`. Expected: FAIL (`cmd_edit` is not defined).
- [ ] **Step 3: Implement** the spec's section 4: validate, ask, write, then recreate the whole project (live: `up -d --force-recreate`, then `router_reload`, a failed reload only warns; stopped: `create --force-recreate`). Add the `## mcctl edit` section to `docs/reference.md`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): edit resource limits`.

### Task 11: Host firewall and rate limit
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-11.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Create: `lib/firewall.sh`, `tests/t_firewall.sh`, `tests/fakebin/ufw`, `tests/fakebin/iptables`, `tests/fakebin/ss`
- Modify: `mcctl`

**Interfaces:**
- Produces: `cmd_firewall plan|apply|confirm|rollback`, `ssh_ports` (same detection order as `ptero`'s `lib/firewall.sh`: configured list, then `sshd -T`, then `ss`, then `$SSH_CONNECTION`, then 22), `firewall_plan_text`. `apply` allows only the detected SSH ports and 25565, adds a per-source connection limit and a new-connection rate limit on 25565 (defaults `MCCTL_CONN_LIMIT=10`, `MCCTL_RATE=10/second`, both configurable), and starts a dead-man timer that switches the firewall off unless `confirm` runs from a new session.

- [ ] **Step 1: Write the failing tests** (fake `ufw`/`iptables`/`ss`): `plan` makes no change (zero mutating calls) and lists SSH ports and 25565; `apply` refuses with `EX_REFUSED` when no SSH port can be detected; the current session's port and source address are checked before enabling; `apply` allows SSH before enabling; the rate-limit rules are present in the recorded `iptables` calls; `confirm` cancels the timer; `rollback` disables the firewall; SFTP is opened only when `MCCTL_SFTP_PUBLIC=1`.
- [ ] **Step 2: Implement** by porting the logic, not by calling `ptero`: copy the shape of `ssh_ports`, `firewall_check_lockout`, and the rollback unit into this file with `mcctl-` names.
- [ ] **Step 3: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 4: Commit** `feat(mcctl): host firewall with rollback and rate limit`.

### Task 12: Live monitoring (`mcctl top`) and live logs (`mcctl logs`)
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-12.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Create: `lib/monitor.sh`, `lib/logs.sh`, `tests/t_monitor.sh`, `tests/t_logs.sh`

**Interfaces:**
- Produces: `render_bar PCT WIDTH` (stdout: a filled/empty bar made of `█` and `░`, green below 60, yellow below 85, red above, with ANSI colour), `render_top_frame` (reads tab-separated lines `name cpu% mem_used mem_limit mem% net_io block_io` on stdin, prints the full frame as a box-drawn table plus a header with server count and totals), `cmd_top [NAME]` (loop: `docker stats --no-stream --format ...`, filter to `mcctl.managed` containers, move the cursor home with `\033[H`, redraw, sleep `${MCCTL_REFRESH:-2}`, restore the terminal and cursor on `INT`/`TERM`/exit), `colorize_log_line LINE` (stdout; recognises the Minecraft line shape `[HH:MM:SS] [Thread/LEVEL]: message`), `cmd_logs NAME [-f] [--tail N] [--level INFO|WARN|ERROR] [--grep TEXT]`.

- [ ] **Step 1: Write the failing tests** (pure functions, no Docker).
  - Top: `render_bar 50 10` has 5 filled cells; `render_bar 0 10` is all empty and `render_bar 100 10` all filled; `render_bar 150 10` clamps to full; the colour code is green at 59, yellow at 60 and 84, red at 85; `render_top_frame` given three input rows prints three server rows and a total line; a row with a missing field prints `-` instead of breaking the box alignment; with `NO_COLOR=1` the output contains no `\033`; every line of the frame has the same visible width (strip ANSI before measuring).
  - Logs: an `INFO` line gets the info colour on the level only and keeps the message text unchanged once ANSI is stripped; `WARN` and `ERROR` get distinct colours; a Java stack-trace line (`\tat net.minecraft...`) takes the colour of the preceding error line; a line that does not match the shape is printed unchanged (never dropped); `--level WARN` hides `INFO` lines and keeps `WARN` and `ERROR`; `--grep` filters case-insensitively; `NO_COLOR=1` gives output byte-identical to the input; the function does not interpret backslashes or `%` in the message (feed `100% done \n` and expect it back unchanged).
- [ ] **Step 2: Implement both** with Bash string operations and `printf` only. Logs are a streaming `while IFS= read -r line` filter over `docker logs --tail N [-f] mc-NAME`. The refresh loop itself is covered by the manual acceptance run (Task 23), not by a test.
- [ ] **Step 3: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 4: Commit** `feat(mcctl): live top view and coloured logs`.

### Task 13: merged into Task 12

Kept as a heading so cross-references still resolve. Nothing to build here.

### Task 14: Settings engine (`set`, `get`, `properties`, drift, apply)
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-14.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Create: `lib/settings.sh`, `tests/t_settings.sh`
- Modify: `lib/compose.sh` (stamp the `mcctl.config_hash` label), `lib/servers.sh` (`status` shows `config pending`), `mcctl`

**Interfaces:**
- Consumes: `server_dir`, `render_server_compose`, `dc`, `confirm`, `server_label`.
- Produces: `settings_type KEY` (stdout one of `bool|int|enum:a,b,c|size|text|https-url|sha1`; exit 1 for an unknown key), `settings_validate KEY VALUE` (0/1), `server_env_set NAME KEY VALUE`, `server_env_get NAME KEY`, `server_env_unset NAME KEY`, `config_hash NAME` (sha256 of the rendered compose with the one-shot keys `*_FORCE_REINSTALL` and `FORCE_REDOWNLOAD` removed first), `apply_pending NAME [--yes]` (recreates the game container only when `config_hash` differs from its `mcctl.config_hash` label), `property_to_env PROPERTY` (`max-players` -> `MAX_PLAYERS`; exit 2 unless the result is in the mapping table of `single-standalone/docs/itzg/configuration.md` "Other Server Property Mappings" or one of `MOTD DIFFICULTY MODE LEVEL LEVEL_TYPE SEED`), `cmd_set`, `cmd_get`, `cmd_unset`, `cmd_env`, `cmd_apply`, `cmd_properties`, `cmd_motd`, `cmd_icon`, `cmd_resourcepack`, `cmd_autostart`.
- Syntax: `mcctl set NAME KEY=VALUE... [--apply] [--force]`; `mcctl get NAME KEY`; `mcctl unset NAME KEY...`; `mcctl env NAME`; `mcctl apply NAME [--yes]`; `mcctl properties NAME list|get KEY|set KEY VALUE|dump`; `mcctl motd NAME TEXT`; `mcctl icon NAME FILE|URL [--override]`; `mcctl resourcepack NAME URL --sha1 HEX [--enforce]`; `mcctl autostart NAME on|off`.

- [ ] **Step 1: Write the failing tests**: an unknown key is refused without `--force` and the message names the key; `set s1 PVP=maybe` is refused (bool); `set s1 DIFFICULTY=hard` is accepted and `DIFFICULTY=impossible` is refused (enum `peaceful,easy,normal,hard`); `properties set s1 max-players 20` writes `MAX_PLAYERS=20`; `properties set s1 rcon.port 1` is refused with the message that `rcon.port` must not be changed (`single-standalone/docs/itzg/configuration.md`); a value containing a newline is refused; **credential keys are refused** (`RCON_PASSWORD`, `CF_API_KEY`, `*_PASSWORD`, `*_TOKEN`, `*_KEY`) with a message pointing to the secrets directory (Global Constraints); `set` without `--apply` leaves the container alone and `status` prints `config pending`; after `apply` the container's `mcctl.config_hash` label equals `config_hash`; setting then unsetting a one-shot key does not make `status` show `config pending`; a MOTD containing `$HOME`, a double quote, `\n`, and `§` renders as inert text in the compose output (`$` becomes `$$`, quotes escaped): assert the rendered line and that no variable is interpolated; `autostart off` renders `restart: "no"`, `on` renders `restart: unless-stopped`; `icon` refuses a file that does not start with the PNG signature or exceeds 1 MB, and refuses a non-`https` URL; `resourcepack` requires a 40-hex `--sha1` and an `https` URL.
- [ ] **Step 2: Run** `bash tests/t_settings.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.** The known-key table lives in one place (`settings_type`), built from the groups in `single-standalone/docs/itzg/environment-variables.md`. `apply_pending` and `cmd_edit` (Task 10) share one recreate routine, so the player-count guard of Task 10 applies to every apply.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): settings engine, properties and drift detection`.

### Task 15: Data access primitive and file manager
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-15.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Create: `lib/data.sh`, `tests/t_files.sh`
- Modify: `tests/fakebin/docker` (record `docker run` calls and replay canned output), `mcctl`

**Interfaces:**
- Consumes: `server_dir`, `confirm`.
- Produces: `data_run NAME CMD...` (runs `docker run --rm --network none --user ${MCCTL_UID:-1000}:${MCCTL_UID:-1000} -v <servers/NAME/data>:/data -w /data alpine CMD...`, so file access never depends on the host user's permissions and never needs sudo), `safe_path PATH` (stdout the normalised relative path; exit 2 for an absolute path, a `..` component, a NUL, or a newline), `cmd_files`.
- Syntax: `mcctl files NAME ls [PATH] | cat PATH | get PATH [DEST] | put SRC PATH [--force] | rm PATH [--recursive] | mkdir PATH | mv SRC DEST | edit PATH`.

- [ ] **Step 1: Write the failing tests**: `safe_path` rejects `/etc/passwd`, `../x`, `a/../../x`, and a path with a newline, and accepts `world/level.dat` and `./mods/a.jar` (printed as `mods/a.jar`); `files rm NAME .` and `files rm NAME ''` are refused (the data root can never be deleted); `files rm` of a directory needs `--recursive` and `confirm`; `files put` refuses to overwrite an existing file without `--force`; `files get` refuses to overwrite a local file; every `data_run` call line contains `--network none`, `--user`, and a `-v` whose host side is under `servers/NAME/data`; a symlink that resolves outside `/data` (the fake `readlink -f` answers `/etc`) is refused before any read or write; `files edit` copies to a temp file, opens `$EDITOR`, writes back only when the content changed, refuses files over 1 MB, and removes the temp file on interrupt; `files ls` gives the same result whether the server is running or stopped (it never asks about container state).
- [ ] **Step 2: Run** `bash tests/t_files.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.** Path confinement is checked twice: lexically by `safe_path`, then inside the helper container with `readlink -f` against `/data/`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): data access primitive and file manager`.

### Task 16: World management
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-16.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Create: `lib/worlds.sh`, `tests/t_worlds.sh`
- Modify: `mcctl`

**Interfaces:**
- Consumes: `data_run`, `safe_path`, `rcon_exec`, `server_env_set`, `server_env_get`, `apply_pending`, `confirm`, `backup_dir`.
- Produces: `valid_world_name W` (`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`), `active_world NAME` (value of `LEVEL`, default `world`), `world_dirs NAME` (one directory per line, only those holding a `level.dat`), `world_group NAME WORLD` (the world plus the Paper-layout siblings `WORLD_nether` and `WORLD_the_end` when they exist), `world_snapshot NAME WORLD OUTFILE` (tar of the group; on a running server it runs `save-off`, `save-all flush`, `tar`, then `save-on`, with `save-on` in a trap that also fires when `tar` fails), `cmd_world`.
- Syntax: `mcctl world NAME list | info [WORLD] | use WORLD | new WORLD [--seed S] [--type T] [--generator-settings FILE] [--hardcore] [--datapacks-enable a,b] [--datapacks-disable a,b] [--use] | rename OLD NEW | delete WORLD | backup [WORLD] [--out FILE] | restore WORLD ARCHIVE | export WORLD OUT.tar.gz | import ARCHIVE [--as WORLD] [--use] | reset [WORLD] | seed | datapack list|add FILE|remove PACK [--world W]`; every destructive subcommand takes `--yes`.
- Rules: `use`, `new --use`, `rename`, `delete`, `restore`, `import` over an existing name, and `reset` require the server to be **stopped** (the message names `mcctl stop`, exit `EX_REFUSED`). `list`, `info`, `backup`, `export`, `seed`, and `datapack list` work on a running server.

- [ ] **Step 1: Write the failing tests** (fake docker; archives are real small tarballs made in the sandbox):
  - `world list` marks the active world, shows size and modified time, sorts newest first, and ignores directories without `level.dat`; it never reads a registry file.
  - `world delete` refuses the active world; `delete`, `restore`, and `reset` first write `backups/world-<WORLD>-<timestamp>.tar.gz`, verify it with `tar -tzf`, and abort **without deleting anything** when the snapshot fails (fake `tar` fails: assert no `rm` call).
  - `world backup` on a running server calls `save-off`, `save-all flush`, then `save-on`; with a failing `tar` it still calls `save-on` (Review Focus 6).
  - `world new` sets `LEVEL` (and `SEED`, `LEVEL_TYPE`, `GENERATOR_SETTINGS`, `HARDCORE`, `INITIAL_ENABLED_PACKS`, `INITIAL_DISABLED_PACKS` when given) in `server.env`, refuses a name that already exists, accepts a negative or text seed, and rejects a `--generator-settings` file that is not valid JSON (`jq -e .`).
  - `world import` refuses an archive whose members are absolute paths, contain `..`, or are symlinks or hard links (Review Focus 7); refuses an archive without `level.dat` at depth 0 or 1; refuses an existing world name unless `--as NEW` names a free one; extracts with `--no-same-owner` through `data_run`.
  - `world rename` also renames the Paper-layout siblings and updates `LEVEL` when the renamed world is the active one.
  - `world use` on a world that does not exist is refused (creating one is `world new`'s job).
  - `world datapack add FILE` refuses a zip without `pack.mcmeta` at its root and a pack name that fails `safe_path`; `datapack list` reads `<world>/datapacks/`.
  - Every mutating subcommand on a running server exits `4` before any change.
- [ ] **Step 2: Run** `bash tests/t_worlds.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.** Active-world changes go through `server_env_set` plus `apply_pending`; nothing edits `server.properties` directly (itzg rewrites it from the environment).
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): world management`.

### Task 17: Player lists and runtime commands
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-17.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Modify: `lib/rcon.sh`, `tests/t_rcon.sh`, `mcctl`

**Interfaces:**
- Consumes: `rcon_exec`, `valid_player` (Task 5).
- Produces: `cmd_whitelist list|add|remove|on|off|reload|import FILE`, `cmd_ban list|add|ip|pardon|pardon-ip`, `cmd_op list|add|remove`, `cmd_say`, `cmd_save`, `cmd_gamerule`, `cmd_time`, `cmd_weather`, `cmd_worldborder`, `cmd_difficulty`, `cmd_defaultgamemode`, `valid_ip ADDR`, `valid_runtime_arg ARG`.
- Syntax: `mcctl whitelist NAME list|add P|remove P|on|off|reload|import FILE`; `mcctl ban NAME list|add P [REASON]|ip ADDR|pardon P|pardon-ip ADDR`; `mcctl op NAME list|add P|remove P`; `mcctl say NAME MESSAGE`; `mcctl save NAME`; `mcctl gamerule NAME RULE [VALUE]`; `mcctl time NAME set day|night|noon|midnight|N`; `mcctl weather NAME clear|rain|thunder [SECONDS]`; `mcctl worldborder NAME set N [SECONDS]`; `mcctl difficulty NAME LEVEL [--persist]`; `mcctl defaultgamemode NAME survival|creative|adventure|spectator`.

- [ ] **Step 1: Write the failing tests**: `whitelist list` turns the vanilla reply `There are 2 whitelisted players: a, b` into one name per line and prints nothing for `There are no whitelisted players`; `whitelist import FILE` skips blank and `#` lines, refuses any line that fails `valid_player`, and refuses more than 500 lines; `ban ip` accepts IPv4 and IPv6 only; a ban reason containing a newline or `;` is refused; `gamerule s1 doDaylightCycle false` is accepted and `gamerule s1 "x;stop" true` is refused before any `docker exec`; `gamerule` values are `true`, `false`, or an integer; `time set noon` and `time set 6000` send `time set noon` and `time set 6000`; `weather rain 300` sends `weather rain 300`; `say` refuses a newline and anything over 256 characters; `save` sends `save-all flush`; `difficulty s1 hard` sends the runtime command only, and `--persist` also writes `DIFFICULTY=hard` with `server_env_set` and leaves the apply to the user; every refused input produces zero `docker exec` calls.
- [ ] **Step 2: Run** `bash tests/t_rcon.sh`. Expected: FAIL on the new cases.
- [ ] **Step 3: Implement** as thin layers over `rcon_exec`; validation first, always.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): complete player lists and runtime commands`.

### Task 18: Version, loader type, upgrade, reinstall, and modpack management
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-18.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Create: `lib/versions.sh`, `tests/t_versions.sh`
- Modify: `lib/modpack.sh`, `tests/t_modpack.sh`, `mcctl`

**Interfaces:**
- Consumes: `server_env_set`, `server_env_unset`, `server_env_get`, `apply_pending`, `cmd_backup`, `confirm`, `dc`, `data_run`, `modpack_env` (Task 4).
- Produces: `version_cmp A B` (0 equal, 1 A newer, 2 A older, 3 not comparable: a snapshot, `LATEST`, or `SNAPSHOT`), `loader_var TYPE` (`FORGE` -> `FORGE_VERSION`, `NEOFORGE` -> `NEOFORGE_VERSION`, `FABRIC` -> `FABRIC_LOADER_VERSION`; empty for other types), `reinstall_flag TYPE` (`FORGE` -> `FORGE_FORCE_REINSTALL`, `FABRIC` -> `FABRIC_FORCE_REINSTALL`, `PURPUR` and `PUFFERFISH` -> `FORCE_REDOWNLOAD`; empty otherwise), `cmd_version`, `cmd_upgrade`, `cmd_type`, `cmd_reinstall`, `cmd_modpack NAME info|set|update|remove`. Valid types: `VANILLA FORGE NEOFORGE FABRIC QUILT PAPER PUFFERFISH PURPUR LEAF FOLIA SPIGOT BUKKIT` (`single-standalone/docs/itzg/server-types.md`); the modpack platforms are set only by `mcctl modpack`.
- Syntax: `mcctl version NAME show|set V [--allow-downgrade] [--yes]`; `mcctl upgrade NAME [--to V] [--yes]`; `mcctl type NAME set TYPE [--loader-version V] [--yes]`; `mcctl reinstall NAME [--timeout 600]`; `mcctl modpack NAME info`; `mcctl modpack NAME set --source curseforge|modrinth --pack ID [--version V] [--yes]`; `mcctl modpack NAME update [--latest | --version V] [--clean] [--yes]`; `mcctl modpack NAME remove [--purge-mods] [--yes]`.

- [ ] **Step 1: Write the failing tests** for both halves.
  - Versions: `version set s1 1.20.4` on a server at `1.21.1` is refused (a world saved by a newer version can be corrupted by an older one) unless `--allow-downgrade`; `version_cmp 1.21.1 1.20.4` is `1`, `1.20` vs `1.20.0` is `0`, `LATEST` vs `1.21` is `3`; a not-comparable change asks `confirm` instead of silently passing or blocking; `set` and `upgrade` run a full backup first and abort, changing nothing, when it fails; `upgrade` on `VERSION=LATEST` runs `docker compose pull` and recreates; `type set s1 FABRIC` writes `TYPE=FABRIC` and **removes** a stale `FORGE_VERSION` from `server.env`; a switch away from a mod loader or plugin type is refused while `mods/` or `plugins/` hold jars unless `--yes`, and the message gives the count; `--loader-version 0.16.9` writes `FABRIC_LOADER_VERSION=0.16.9` and is refused for a type with no loader variable; an unknown type is refused; `reinstall` sets the type's flag, applies, waits until the container reports healthy (or the timeout, which fails non-zero), then removes the flag from `server.env` **without** recreating, and `status` does not show `config pending` afterwards (Task 14's one-shot rule); `reinstall` on a type with no flag says so and exits `EX_USAGE`.
  - Modpack: `info` prints the source, the pack id, `pinned <version>` or `latest`, and the resolved pack name and version when the running container exposes `MODPACK_NAME` and `MODPACK_VERSION` (`single-standalone/docs/itzg/configuration.md`), otherwise `unknown`; `set` runs a full backup first, asks `confirm`, rewrites `modpack.env` through `modpack_env`, and leaves the CurseForge key as a file reference only; `set` with an unknown source or an empty id exits `EX_USAGE`; `update` on a pinned server prints the pin and refuses to change it without `--latest` or `--version`; `update --clean` adds `REMOVE_OLD_MODS=TRUE` for that apply only (backup first, and the message quotes the itzg warning that the whole `mods` directory is deleted) and the flag is gone from `server.env` afterwards; `remove` keeps the installed mods unless `--purge-mods` (backup first); a server with no modpack answers `info` with `no modpack` and `update` with a non-zero exit.
- [ ] **Step 2: Run** `bash tests/t_versions.sh` and `bash tests/t_modpack.sh`. Expected: FAIL on the new cases.
- [ ] **Step 3: Implement.** `version_cmp` compares dotted numeric versions with `sort -V` and returns `3` for anything else. The one-shot `REMOVE_OLD_MODS` follows the Task 14 rule (excluded from `config_hash`, removed after the apply).
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): version, loader, upgrade, reinstall and modpack management`.

### Task 19: merged into Task 18

Kept as a heading so cross-references still resolve. Nothing to build here.

### Task 20: Mods, plugins and Modrinth project lists
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-20.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Create: `lib/mods.sh`, `tests/t_mods.sh`
- Modify: `lib/compose.sh` (emit list files as block scalars), `templates/server.compose.tmpl`, `mcctl`

**Interfaces:**
- Consumes: `data_run`, `apply_pending`, `server_env_get`, `confirm`.
- Produces: `list_file NAME KEY` (`servers/NAME/lists/<key lower-case>.list`, one entry per line), `list_add`, `list_remove`, `list_clear`, `list_show` (all `NAME KEY [ENTRY]`), `valid_mod_entry ENTRY` (an `https://` URL, or a container path under `/mods` or `/plugins`; no whitespace, quote, backtick, newline, or `$`; at most 500 characters), `valid_modrinth_entry ENTRY` (`^[a-z0-9_-]{1,64}(:[A-Za-z0-9._-]{1,64})?$`), `cmd_mods`, `cmd_plugins`, `cmd_modrinth`. The renderer emits `MODS`, `PLUGINS`, and `MODRINTH_PROJECTS` as `KEY: |` block scalars from the list files, and emits nothing for an absent or empty list file.
- Syntax: `mcctl mods NAME list|installed|add URL|FILE...|remove ENTRY|clear [--remove-installed]|sync [--restart]`; `mcctl plugins NAME ...` (same, plus `add --hybrid`); `mcctl modrinth NAME list|add PROJECT[:VERSION]|remove PROJECT|clear`.

- [ ] **Step 1: Write the failing tests**: `mods add s1 http://x/a.jar` is refused (`https` only); a URL with a newline, `$`, or a quote is refused; adding a duplicate is ignored; the rendered compose has `MODS: |` with the entries in file order and `$` escaped as `$$`; a local jar is copied to `servers/NAME/mods/` (mounted at `/mods`, the attach point in `single-standalone/docs/itzg/mods-and-plugins.md`) only when it starts with the zip signature `PK` and is at most 200 MB, and is not added to the list; `mods list` shows the declared list and the attach-point files; `mods installed` lists the jars actually present under `data/mods` through `data_run`; `mods remove` removes a list line or a local file; **`clear` omits the key and leaves the installed jars alone, while `clear --remove-installed` renders the key empty so itzg removes them** (docs: an empty list removes all) and asks `confirm`; `mods add` on a plugin type (`PAPER SPIGOT BUKKIT PURPUR PUFFERFISH LEAF FOLIA`) and `plugins add` on a mod loader (`FORGE NEOFORGE FABRIC QUILT`) are refused without `--force`, and `plugins add --hybrid` writes `USES_PLUGINS=true`; `sync` applies the pending change and, with `--restart`, restarts; `modrinth add fabric-api` and `modrinth add lithium:mc1.21-0.13.0` are accepted and `modrinth add "x y"` is refused.
- [ ] **Step 2: Run** `bash tests/t_mods.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): mod, plugin and Modrinth lists`.

### Task 21: Server information, clone, rename, export, import, exec
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-21.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Create: `lib/portable.sh`, `tests/t_portable.sh`
- Modify: `mcctl`

**Interfaces:**
- Consumes: `server_label`, `server_exists`, `hostname_taken`, `cf_create_record`, `cf_delete_record`, `router_reload`, `ensure_rcon_secret`, `world_snapshot`, `data_run`, `render_server_compose`, `confirm`.
- Produces: `cmd_info`, `cmd_clone`, `cmd_rename`, `cmd_export`, `cmd_import`, `cmd_exec`, `cmd_shell`.
- Syntax: `mcctl info NAME`; `mcctl clone NAME NEW [--with-data] [--hostname H] [--yes]`; `mcctl rename NAME NEW [--hostname H] [--yes]`; `mcctl export NAME OUT.tar.gz [--with-secrets]`; `mcctl import ARCHIVE [NAME] [--yes]`; `mcctl exec NAME CMD...`; `mcctl shell NAME`.

- [ ] **Step 1: Write the failing tests**: `info` of an unknown server exits non-zero; `info` prints the type, version, modpack source and id, memory, cpus, hostname and fqdn, state, uptime, `config pending` when the hash differs, the active world and its size, the data size, the backup destination and the time of the last backup; `clone` refuses an existing `NEW`, uses a unique hostname (default `slugify NEW`), writes a **different** RCON secret, and copies neither `secrets/` nor `backups/`; `clone --with-data` of a running source uses `world_snapshot`'s save-off/save-on trap or refuses without `--yes`; clone's DNS, container, and router steps use Task 7's order and roll back in reverse on failure; `rename` stops the server (after `confirm`), creates the DNS record for the new hostname **before** deleting the old one, moves the folder including `backups/`, regenerates, recreates, starts, and leaves no container called `mc-OLD`; if the new DNS call fails, nothing is moved; `rename` keeps the old hostname only when `--hostname` says so; `export` writes an archive without `secrets/` by default, and `--with-secrets` writes it with mode 600 and prints a warning; `import` refuses absolute, `..`, symlink, and hard-link members, refuses an existing name, refuses an archive without `server.env`, and creates a fresh RCON secret when the archive had none; `exec s1 ls` runs one `docker exec` as the container user; `shell` runs `docker exec -it mc-s1 bash` and refuses on a stopped server with a message naming `mcctl start`.
- [ ] **Step 2: Run** `bash tests/t_portable.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.** `import` extracts through `data_run` for `data/` and with plain `tar --no-same-owner` for the small config files, after the member-name check.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(mcctl): info, clone, rename, export, import and exec`.

### Task 22: Documentation set
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-22.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Create: `single-standalone/docs/README.md`, `architecture.md`, `prerequisites.md`, `reference.md`, `management-guide.md`, `troubleshooting.md`, `velocity.md`, `single-standalone/README.md`, `tests/t_docs.sh`

**Interfaces:**
- Consumes: every `cmd_*` name from Tasks 0 to 21.
- `management-guide.md` is task-oriented (reference.md is per command). One section each for: worlds, settings and drift, files, players, mods/plugins/Modrinth, versions and loaders, modpacks, and clone/rename/export/import. Each section has a "when to use it" line, a worked example with the exact command and its expected output, and a "what this refuses and why" list copied from the owning task's failing tests.

- [ ] **Step 1: Write the failing test** (`t_docs.sh`): every `cmd_*` function defined under `lib/` has a section in `docs/reference.md`; every relative link in `docs/` resolves; `docs/prerequisites.md` contains the sentence stating the game-port DNS record is DNS-only and the origin IP is reachable; `docs/architecture.md` contains one Mermaid diagram each for `create`, `delete`, `backup restore`, and the router/egress layout; `docs/management-guide.md` has the eight section headings listed above, and every `mcctl <command>` it shows exists in the dispatch table of `mcctl` (extract the commands with `grep -o 'mcctl [a-z-]*'`); `docs/troubleshooting.md` has one row per failure message the code can print (extract them with `grep -h 'die \|err '`); `single-standalone/README.md` links to the itzg docs at `single-standalone/docs/itzg/` and states in its first paragraph that the two folders are different things.
- [ ] **Step 2: Run** `bash tests/t_docs.sh`. Expected: FAIL.
- [ ] **Step 3: Write the documents.** `velocity.md` documents Velocity as a manual extension only: it states plainly that no script manages it. `prerequisites.md` covers Docker and Compose versions, the Cloudflare zone and token scope (DNS edit for that zone only), the WSL notes from Spikes S1 and S2, and the firewall assumptions.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `docs(mcctl): architecture, prerequisites, reference and troubleshooting`.

### Task 23: Acceptance run on real Docker (manual, produces a report)
Spec: `docs/superpowers/plans/2026-10-24-single-standalone-mcctl-task-23.md`. Where it differs from the text below, the spec wins (its section 2 lists the corrections and why).


**Files:**
- Create: `single-standalone/docs/acceptance.md`

No automated test can prove this task. Run each check on a real host and record the date, host, command, and result in `docs/acceptance.md`. A failing check is a bug in an earlier task, not a reason to loosen this list.

- [ ] **Step 1: Fresh host path.** On a clean Ubuntu VPS: `mcctl doctor`, `init`, `firewall plan`, `firewall apply`, `firewall confirm`, `up`. Expected: the stack is healthy and only 25565 plus SSH listen publicly.
- [ ] **Step 2: Vanilla server end to end.** `create`, `start`, join from a Minecraft client with the hostname and no port, `rcon list`, `whitelist add`, `backup now`, `backup list`, `backup restore`, `delete`. Expected: each works and the DNS record disappears after `delete`.
- [ ] **Step 3: Two servers at once.** Two servers with different hostnames; each client reaches the right one. Stop one: the other keeps working.
- [ ] **Step 4: Modpack — nested server zip.** Create a server from CurseForge `prominence-2-hasturian-era` pinned to file `9184730` (a server pack that is a zip holding the real zip; the Pterodactyl installer once failed on exactly this). Expected: itzg installs real mods. If it does not, record the failure and the workaround in `docs/troubleshooting.md`.
- [ ] **Step 5: Modpack — loader not stated.** Create a server from CurseForge `all-the-mods-10` (a server pack that does not state the NeoForge version; the Pterodactyl installer needed `LOADER_VERSION`). Expected: it starts, or the docs name the variable that fixes it.
- [ ] **Step 6: Modrinth.** One server from a Modrinth modpack. Expected: starts.
- [ ] **Step 7: Egress guard on WSL.** Repeat Spike S1's checks on WSL. Expected: the router still reaches game containers, and a game container cannot reach the LAN gateway or `169.254.169.254`.
- [ ] **Step 8: Live views.** Run `mcctl top` and `mcctl logs s1 -f` for a few minutes on a terminal of 80 columns and again on a wide one. Expected: no flicker, no wrapped box lines, and the terminal is restored after Ctrl-C.
- [ ] **Step 9: SFTP.** Add a key, connect, and confirm that server A's user cannot see server B's files.
- [ ] **Step 10: Edit under load.** With a player online, `edit --memory`. Expected: refused without `--yes`. With `--yes`: the server returns with the new limit (`docker stats` shows it), the router still routes to it, and `mcctl backup NAME now` works afterwards (the sidecar was recreated together with the server).
- [ ] **Step 11: World management.** On a running server run `world backup` and check that autosave is back on afterwards. Then stop it and run `world new --seed 123`, `world use`, `world rename`, `world export`, `world import --as`, `world delete` of a non-active world, and `world reset`. Expected: each refuses on a running server where Task 16 says it must, the safety archive exists before each deletion, and the player's inventory in the original world is intact after switching back.
- [ ] **Step 12: Settings and drift.** `set s1 MAX_PLAYERS=5`, check `status` shows `config pending`, `apply`, check it clears and that `get s1 MAX_PLAYERS` and the in-game player cap agree. Set a MOTD containing `$` and a double quote and read it in the client server list.
- [ ] **Step 13: Mods and plugins.** On a Fabric server run `modrinth add fabric-api`, `mods add` a real https jar URL, `sync --restart`, and check `mods installed`. Then `mods remove` the URL and check that the jar disappears after the next restart. On a Paper server `plugins add` one plugin URL.
- [ ] **Step 14: Version and loader.** `upgrade` a server on `VERSION=LATEST` (backup first). `version set` an older release and confirm it is refused. `type set` from PAPER to FABRIC with plugins present and confirm the refusal and the plugin count. `reinstall` a Forge server and confirm the flag is gone from `server.env` afterwards.
- [ ] **Step 15: Modpack lifecycle.** `modpack set` a pack, `modpack update` while pinned (refused), `modpack update --version V`, `modpack update --clean` (backup first), `modpack remove`.
- [ ] **Step 16: Files.** `files put` a text file, `files get` it back, `files edit` it, `files rm` it. Try `files get s1 ../../etc/passwd` and a `files put` onto a symlink that points outside, and confirm both are refused.
- [ ] **Step 17: Clone, rename, export, import.** `clone --with-data` of a running server, `rename` it, `export` it, `delete` it, `import` it back. Expected: DNS records and routes follow each step with no orphan, and the imported server has a new RCON secret.

## Self-review

- **Spec coverage:** lifecycle (3), console and player management (5, 17), backup/restore (8), monitoring and logs (12, 13), versions, loaders, and upgrade (3, 18), world management (16), plugin and mod management (20), modpack CurseForge/Modrinth including update and removal (4, 19), settings and server.properties (14), files (15), SFTP (9), Cloudflare (7), firewall and egress (6, 11), resource edit (10), clone/rename/export/import (21), secrets pattern (2, 4, 5, 7, 8, 14), docs (22), Velocity docs-only (22). **No known gap.** Deliberately not built: generic cron beyond the backup sidecar, Velocity/BungeeCord automation, a web UI, and any Pterodactyl integration (all in the spec's non-goals).
- **Placeholders:** the three upstream names (mc-backup variables, Modrinth variable, `CF_API_KEY_FILE`) are deliberately resolved inside Tasks 4 and 8 by reading upstream first; they are not guessed here.
- **Type consistency:** `container_name NAME` (`mc-NAME`) is used by Tasks 5, 8, 12, 21; `server_dir`, `dc`, `rcon_exec`, `router_reload`, `data_run`, `server_env_set`, `apply_pending`, and `world_snapshot` have one definition each, and later tasks only consume them. `apply_pending` (Task 14) is the single recreate routine, shared with `cmd_edit` (Task 10).
- **Proportion:** 22 implementation tasks plus the acceptance run (Tasks 13 and 19 are merged into 12 and 18; numbers kept so cross-references hold) for a spec with 21 decisions plus the world and server management scope; code appears only where a step needs exact values.

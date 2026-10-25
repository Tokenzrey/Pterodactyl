# Task 17 spec: player lists and runtime commands

Status: written, not dispatched. Verified against the working tree on 2026-10-24 (after 15:32). Needs Task 14 (`server_env_set`) only for `difficulty --persist`, and Task 15 (`data_run`) for `ops`.
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 17").
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Goal

Finish the player and console surface with thin, validated wrappers over `rcon_exec`: the rest of the whitelist, ban and operator lists, and the runtime commands (`say`, `save`, `gamerule`, `time`, `weather`, `worldborder`, `difficulty`, `defaultgamemode`). Every input is checked before any Docker call.

## 2. Corrections to the plan text (the corrections win)

| # | Plan text | What is true | Rule for this task |
|---|---|---|---|
| C1 | `mcctl whitelist NAME list\|add P\|…`, `mcctl ban NAME list\|add P\|…`, `mcctl op NAME list\|add P\|remove P` (server first, then a subcommand) | Task 5 shipped and tests (`tests/t_rcon.sh`, 208 assertions): `whitelist add\|remove SERVER PLAYER`, `whitelist list\|on\|off SERVER`, `ban SERVER PLAYER`, `kick SERVER PLAYER`, `op SERVER PLAYER`. The plan's grammar contradicts them: `ban s1 add Steve` against `ban s1 Steve`. | Keep Task 5's grammar unchanged. Add new commands named after the Minecraft commands, which cannot clash: `ban-ip`, `pardon`, `pardon-ip`, `banlist`, `deop`, `ops`, `whitelist reload`, `whitelist import`. |
| C2 | "`whitelist list` turns the vanilla reply into one name per line" | Task 5's `whitelist list` prints the server's own reply, and its tests expect that. | Leave the default. Add `--names` (`mcctl whitelist list SERVER --names`) for one name per line. The same flag on `banlist`. |
| C3 | `op NAME list` | Vanilla has no command that lists operators; they are in `ops.json`. | `mcctl ops SERVER` reads `ops.json` with `data_run` and `jq`; works on a stopped server; no operators prints `no operators`. |
| C4 | a ban reason containing `;` is refused | `;` is not special for RCON. Only control characters (a newline) can end a command, and `check_rcon_words` already refuses them. | A reason is one argument of at most 100 characters without control characters. `;` is allowed. |
| C5 | "Modify `lib/rcon.sh`, `tests/t_rcon.sh`" | Task 5's files are green and large. | New `lib/players.sh` and `tests/t_players.sh`. Task 5's files change only if a helper must move. |
| C6 | `difficulty NAME LEVEL [--persist]` writes `DIFFICULTY=hard` and "leaves the apply to the user" | After Task 14 that is exactly the pending model. | `--persist` calls `server_env_set NAME DIFFICULTY hard` and prints `config pending: mcctl apply NAME`. |
| C7 | `gamerule` values "true, false, or an integer" | A rule name is `[A-Za-z][A-Za-z0-9_]*`. | Validate the rule name too (below). |
| C8 | "`mcctl`" | Dispatch discovers `cmd_*`. | `mcctl` is not changed. |

## 3. Verified facts

| Thing | Where | Behaviour |
|---|---|---|
| `valid_player NAME` | `lib/rcon.sh` | `^[.A-Za-z0-9_]{1,16}$`. |
| `check_rcon_words WORD...` | `lib/rcon.sh` | first word not empty, not starting with `-`, no control character in any word; exit 2. |
| `_need_player`, `_send SERVER WORD...` | `lib/rcon.sh` | `_send` checks the words first (no Docker call on a refusal), then `_need_server`, then `_need_running`, then `rcon_exec`; a failure tells the operator a fresh server needs a minute. |
| `_player_cmd VERB SERVER PLAYER` | `lib/rcon.sh` | exactly two arguments. |
| `cmd_whitelist` | `lib/rcon.sh` | `add\|remove SERVER PLAYER`; `list\|on\|off SERVER`. |
| Refusal exit code | Task 5 ruling | refused names and RCON text exit 2. |
| Vanilla replies | Minecraft | `There are N whitelisted players: a, b` / `There are no whitelisted players`; `banlist` replies similarly (`There are N bans:` followed by entries). |
| Planned | Tasks 14, 15 | `server_env_set`, `data_run`. |

## 4. Behaviour

All commands: server name first, refuse before Docker, then `_send`.

- `mcctl whitelist reload SERVER` sends `whitelist reload`. `mcctl whitelist import SERVER FILE`: FILE is a local text file; blank lines and lines starting with `#` are skipped; every other line must pass `valid_player`, and one bad line refuses the whole file before anything is sent (the message gives the line number, never the line); more than 500 lines refuses; each name becomes one `whitelist add NAME` through `_send`, with a progress line every 50 names.
- `mcctl whitelist list SERVER --names`: parses `: a, b` into one name per line; `There are no whitelisted players` prints nothing.
- `mcctl ban SERVER PLAYER [REASON]` (extends Task 5's `ban`): REASON per C4. `mcctl ban-ip SERVER ADDR [REASON]`, `mcctl pardon SERVER PLAYER`, `mcctl pardon-ip SERVER ADDR`, `mcctl banlist SERVER [--names]`, `mcctl deop SERVER PLAYER`.
- `valid_ip ADDR`: IPv4 as four decimal parts 0 to 255 without leading zeros beyond a single `0`, or IPv6 of 2 to 8 groups of hex digits with at least two colons, at most 45 characters. Anything else is refused.
- `mcctl ops SERVER`: `data_run SERVER cat -- ops.json` through `jq -r '.[].name'`; invalid JSON is an error (exit 1).
- `mcctl say SERVER MESSAGE`: at most 256 characters, no control character. `mcctl save SERVER` sends `save-all flush`.
- `mcctl gamerule SERVER RULE [VALUE]`: RULE `^[A-Za-z][A-Za-z0-9_]{0,63}$`; VALUE `true`, `false` or `^[0-9]{1,9}$`; without VALUE it reads the rule.
- `mcctl time SERVER set day|night|noon|midnight|N` (N is `^[0-9]{1,8}$`); `mcctl weather SERVER clear|rain|thunder [SECONDS]` (SECONDS 1 to 1000000); `mcctl worldborder SERVER get`, `set N [SECONDS]` (N 1 to 59999968, SECONDS 0 to 1000000), `center X Z` (integers, absolute value at most 29999984).
- `mcctl difficulty SERVER peaceful|easy|normal|hard [--persist]` (C6); `mcctl defaultgamemode SERVER survival|creative|adventure|spectator`.
- `valid_runtime_arg KIND VALUE` is the one function that holds these patterns; the commands only call it.

## 5. Tests (`single-standalone/tests/t_players.sh`; fake setup as in `t_rcon.sh`: `fake_server`, `docker.inspect` = `running`, `docker.exec` for the reply)

1. Each new command sends exactly one `docker exec -i mc-s1 rcon-cli <words>` (the sentence is asserted in `calls`), after `docker inspect`.
2. Table of refusals, at least 40 inputs, each exit 2 and **zero `docker exec`**: bad player names (`x; stop`, `@a`, empty, 17 chars), bad IPs (`999.1.1.1`, `1.2.3`, `01.2.3.4`, `::`, `a`), `gamerule "x;stop" true`, `gamerule dayLight maybe`, `time set 1e3`, `weather rain 0`, `weather snow`, `worldborder set 0`, `worldborder set 60000000`, `say` with a newline and with 257 characters, a ban reason with a newline or 101 characters, `difficulty extreme`, `defaultgamemode hardcore`.
3. `;` in a ban reason is accepted (C4). `ban s1 Steve` still sends `ban Steve` (Task 5 unchanged).
4. `whitelist list s1 --names`: `There are 2 whitelisted players: a, b` gives `a` and `b` on two lines; the empty reply gives nothing; the default still prints the raw reply.
5. `whitelist import`: blank and `#` lines skipped; one invalid line refuses the whole file with its line number and no `docker exec`; 501 lines refuse; 3 valid names make 3 `whitelist add` calls in order.
6. `ops`: with `docker.run.cat` returning a JSON array, prints names; invalid JSON exits 1; missing `ops.json` (`docker.run.cat.rc` = 1) prints `no operators`; works with the container stopped and makes no `docker exec`.
7. `difficulty s1 hard` sends only the runtime command; `--persist` also writes `DIFFICULTY=hard` (Task 14 stores an enum in its listed lower-case form), and prints `config pending`.
8. `save s1` sends `save-all flush`; `gamerule s1 doDaylightCycle` (no value) sends the read form.
9. A stopped server: every runtime command exits 1 with `mcctl start`, after the checks.
10. E6 additions: `valid_ip` and `valid_runtime_arg` joined to the property test (300 inputs, only exit 0 or 2).
11. E3: new `cmd_*` named in tests; no `eval`, no `sudo`. E4: planted RCON secret in no output or call.
12. Flow (E13): `whitelist import`, `ban-ip`, `pardon-ip`, `time`, `weather`, `save` in `tests/t_flows.sh` with the ordered log.

## 6. Files

- Create: `single-standalone/lib/players.sh` (`valid_ip`, `valid_runtime_arg`, `cmd_ban_ip cmd_pardon cmd_pardon_ip cmd_banlist cmd_deop cmd_ops cmd_say cmd_save cmd_gamerule cmd_time cmd_weather cmd_worldborder cmd_difficulty cmd_defaultgamemode`, and the `reload`, `import`, `--names` additions through small wrapper functions that `cmd_whitelist` calls), `single-standalone/tests/t_players.sh`.
- Modify: `single-standalone/lib/rcon.sh` (only: `cmd_whitelist` dispatches `reload`, `import` and the flag to `lib/players.sh`; `cmd_ban` accepts the optional reason), `single-standalone/tests/t_flows.sh`, `single-standalone/tests/t_fuzz.sh`, `single-standalone/docs/reference.md`.
- Do not modify: `single-standalone/mcctl`.

## 7. Documentation

Extend `## mcctl whitelist, ban, kick, op` and add a section per new command with the exact accepted values; say plainly that `ops` reads `ops.json` and works on a stopped server; the `--persist` pending model; the 500-line import limit.

## 8. Not provable in the sandbox

The exact wording of the real server's replies (`There are N whitelisted players:` and the `banlist` layout vary a little by version); that `save-all flush` blocks until the world is saved; that `worldborder` limits match the installed version.

## 9. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_players.sh`, `t_rcon.sh` (must stay green unchanged), then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-17-report.md`.

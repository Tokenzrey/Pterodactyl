# Task 11 spec: host firewall (`mcctl firewall`) and ingress rate limit

Status: written, not dispatched. Verified against the working tree on 2026-10-24 (after 15:32), and against `D:\Documents\code\pterodactyl\lib\firewall.sh` (the `ptero` firewall this one is modelled on).
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 11: Host firewall and rate limit").
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Goal

`mcctl firewall plan|apply|confirm|rollback` puts a default-deny host firewall (ufw) in front of the VPS with SSH and the Minecraft router port open, and gives the router port a per-source connection limit and a new-connection rate limit. A bad `apply` must never lock the operator out: SSH is allowed before the firewall is enabled, and a dead-man timer switches it off again unless the operator confirms from a new session.

## 2. Corrections to the plan text (the corrections win)

| # | Plan text | What is true | Rule for this task |
|---|---|---|---|
| C1 | `apply` "adds a per-source connection limit and a new-connection rate limit on 25565" through ufw or host iptables calls | Port 25565 is published by Docker. Published traffic is DNAT-ed in `nat/PREROUTING` and then crosses `FORWARD` and the `DOCKER-USER` chain. `INPUT` and ufw rules never see it, so a limit placed there does nothing. | The limits are rules in a private chain `MCCTL-INGRESS`, jumped to from `DOCKER-USER`. |
| C2 | the same sentence: `apply` writes them | Rules added to `DOCKER-USER` from the host are gone after a reboot (Docker recreates the chain empty). The egress-guard container (`templates/stack.compose.yml`, service `egress-guard`) rebuilds `MCCTL-EGRESS` at every start; that is the place that survives restarts. | `MCCTL-INGRESS` is built by the guard script, next to `MCCTL-EGRESS`. `firewall apply` handles ufw only, and reports whether the chain is active. |
| C3 | "limit … on 25565" for every connection | The router container connects to each game server on port 25565 from one source IP. A per-source limit that covers those connections cuts off the router once more than `MCCTL_CONN_LIMIT` players are online. | The limit rules match only connections whose destination is the router: `-d $ROUTER_IP -p tcp --dport 25565 -m conntrack --ctstate NEW`. Router-to-game traffic never matches. |
| C4 | "Create: `tests/fakebin/ufw`, `iptables`, `ss`" | `tests/fakebin/iptables` and `tests/fakebin/ss` already exist (Task 6) and are strict. `ss` models only `ss -H -ltnp "( sport = :PORT )"`; an unmodelled call exits 97. `iptables` already models `-S -N -F -C -A -I` and keeps rules as the words given. | Do not recreate them. Extend `ss` with two shapes (below). Create `ufw`, `sshd`, `systemd-run`, `systemctl`, `id`. |
| C5 | "`ssh_ports` same detection order as `ptero`" | `ptero`'s `lib/firewall.sh` also uses `python3` for CIDR lists (`cidr_contains`, `valid_cidr_list`). `mcctl` is pure Bash. | Port `ssh_ports` and `firewall_check_lockout` only. No CIDR allow-lists in this task. |
| C6 | "Modify: `mcctl`" | `mcctl` dispatches by discovering `cmd_*` functions in `lib/*.sh`. | `mcctl` is not changed. |
| C7 | `MCCTL_CONN_LIMIT` / `MCCTL_RATE` "both configurable" | `lib/config.sh` accepts any `MCCTL_*` key without checking it. These two values end up as arguments of an `iptables` command inside the guard container's shell script. | Validate both in `lib/config.sh` before use (section 4.5). |
| C8 | root | `ptero` uses `need_root` with the text `sudo ./ptero ...` in its message. The E3 invariant scans `mcctl`, `lib/` and `templates/` for the word `sudo` and fails the suite. | `_need_root` checks `id -u`; its message says "run as root". The word `sudo` appears nowhere. |

## 3. Verified facts to build on

| Thing | Where | Behaviour |
|---|---|---|
| Guard script | `templates/stack.compose.yml`, service `egress-guard` | Waits for `DOCKER-USER`, then `ipt -N MCCTL-EGRESS 2>/dev/null \|\| ipt -F MCCTL-EGRESS`, appends rules, then `ipt -C DOCKER-USER -j MCCTL-EGRESS 2>/dev/null \|\| ipt -I DOCKER-USER 1 -j MCCTL-EGRESS`. The script runs `set -eu` and uses `$$` for compose escaping. |
| Guard healthcheck | same service | `ipt -C` for every rule the script adds; healthy only when all exist. A new rule needs a matching `ipt -C` line. |
| Guard env | same service | `ROUTER_IP`, `GAME_SUBNET`, `PRIVATE_RANGES` (the new `CONN_LIMIT` and `RATE` go beside them, from `${MCCTL_CONN_LIMIT:-10}` and `${MCCTL_RATE:-10/second}`). |
| Router port | `lib/router.sh` | `ROUTER_PORT=25565` is a constant. `cmd_up` checks the port with `ss -H -ltnp "( sport = :25565 )"`. |
| Fake `iptables` | `tests/fakebin/iptables` | modelled: `-S -N -F -C -A -I` (with `-w`); `iptables.fail` makes a call containing a string fail. |
| Fake `ss` | `tests/fakebin/ss` | replays `$FAKE_STATE/ss.listen`; `ss.rc` sets the exit status. |
| Ptero flow | `D:\Documents\code\pterodactyl\lib\firewall.sh` | `ssh_ports`; `firewall_rules` (lines `rule<TAB>comment`); `firewall_check_lockout` (no port found: refuse; the session's server port must be in the list); `ufw_is_active` (status line or `ufw-before-input` in `iptables -S INPUT`); `ufw_allows_port`; `apply` (root, ufw present, lockout check, plan text, confirm, save previous state, add rules, defaults, enable, verify SSH accepted or disable again, arm the timer only when ufw was inactive); `confirm` stops the timer; the timer is `systemd-run --unit=… --on-active=Ns ufw --force disable`; with no `systemd-run` and a timer wanted, `apply` refuses. |
| Fake shapes to copy | `D:\Documents\code\pterodactyl\tests\fakebin\systemd-run`, `systemctl` | `systemd-run` appends to `calls.log` and touches `rollback.armed`; `systemctl` models units under `$FAKE_STATE/systemd`. |
| Exit codes | `lib/common.sh` | `EX_FAIL=1 EX_USAGE=2 EX_PREFLIGHT=3 EX_REFUSED=4`. |

## 4. Behaviour

### 4.1 Commands

`mcctl firewall plan | apply | confirm | rollback`. Anything else: usage, exit 2.

- `plan`: no root needed, changes nothing. Prints the SSH ports that stay open, the policy ("default deny incoming, allow outgoing; Docker forwarding is not touched"), each ufw rule it would add, the ingress limits (`connections per source: N`, `new connections per source: RATE`), and whether the guard's ingress chain is active (`iptables -S MCCTL-INGRESS` succeeds: `active`; otherwise `not active: run mcctl up`).
- `apply`: root only (`_need_root`, exit 4). ufw missing: exit 3 with the install hint. `firewall_check_lockout` fails: exit 4. Then print the plan, `confirm`, save the previous state (`ufw status verbose` and `iptables -S`) to `$MCCTL_ROOT/backups/firewall-before-<UTC>.txt` (mode 600, directory mode 700), add every rule with its comment, set `default deny incoming` and `default allow outgoing`, enable, and check from the live rule set that every SSH port is accepted; if one is not, `ufw --force disable` at once and exit 1. Arm the dead-man timer only when ufw was inactive before and `MCCTL_FIREWALL_ROLLBACK_SECONDS` (default 300) is above 0. Without `systemd-run` and with a timer wanted: refuse with exit 3 before touching anything. If arming fails after enabling, disable again and exit 1. End with the instruction to open a new SSH session and run `mcctl firewall confirm`.
- `confirm`: root only. Stops `mcctl-firewall-rollback.timer` and `.service`. Says the firewall stays on.
- `rollback`: root only. `ufw --force disable` and stop the timer; says the firewall is off.

### 4.2 `ssh_ports` (stdout, one port per line, sorted unique; the reason on stderr)

Order: `MCCTL_SSH_PORTS` (comma list) if set; else `sshd -T` lines `port N`; plus `ss -H -ltnp` lines whose process is `sshd`; plus the server port of `$SSH_CONNECTION`; if still nothing and something listens on 22 (`ss -H -ltn "( sport = :22 )"`), 22. Every port must be an integer from 1 to 65535; a configured value that is not: exit 3 naming it.

### 4.3 `firewall_rules` (lines `rule<TAB>comment`)

`allow PORT/tcp<TAB>mcctl: ssh` for each SSH port; `allow 25565/tcp<TAB>mcctl: minecraft router`; and `allow 2222/tcp<TAB>mcctl: sftp` only when `MCCTL_SFTP_PUBLIC=1` (Task 9 binds the SFTP port to `127.0.0.1` otherwise).

### 4.4 The guard's ingress chain (`templates/stack.compose.yml`)

After the egress rules, the guard script adds, in this order and with the same flush-and-refill pattern:

```
ipt -N MCCTL-INGRESS 2>/dev/null || ipt -F MCCTL-INGRESS
ipt -A MCCTL-INGRESS -s "$$GAME_SUBNET" -j RETURN
ipt -A MCCTL-INGRESS -d "$$ROUTER_IP" -p tcp --dport 25565 -m conntrack --ctstate NEW \
    -m connlimit --connlimit-above "$$CONN_LIMIT" --connlimit-mask 32 -j DROP
ipt -A MCCTL-INGRESS -d "$$ROUTER_IP" -p tcp --dport 25565 -m conntrack --ctstate NEW \
    -m hashlimit --hashlimit-above "$$RATE" --hashlimit-mode srcip --hashlimit-name mcctl-new -j DROP
ipt -C DOCKER-USER -j MCCTL-INGRESS 2>/dev/null || ipt -I DOCKER-USER 2 -j MCCTL-INGRESS
```

The jump sits after the egress jump (position 2), so both chains are consulted and Docker's own `RETURN` stays last. The healthcheck gains one `ipt -C` per rule above. Add `CONN_LIMIT` and `RATE` to the service's `environment:`.

### 4.5 Config validation (`lib/config.sh`, `config/mcctl.env.example`)

- `MCCTL_CONN_LIMIT`: integer 1 to 65535 (default 10).
- `MCCTL_RATE`: `^[1-9][0-9]{0,5}/(second|minute|hour)$` (default `10/second`).
- `MCCTL_SSH_PORTS`: comma list of ports 1 to 65535 (default empty).
- `MCCTL_FIREWALL_ROLLBACK_SECONDS`: integer 0 to 3600 (default 300).
- `MCCTL_SFTP_PUBLIC`: `0` or `1` (it may already be validated by Task 9; do not duplicate).
Each failure is `EX_PREFLIGHT` and names the key. Document all of them in `config/mcctl.env.example`.

## 5. Tests

`single-standalone/tests/t_firewall.sh` (new), additions to `single-standalone/tests/t_router.sh` and `single-standalone/tests/t_config.sh`. New fakes in `single-standalone/tests/fakebin/`: `ufw` (state in `$FAKE_STATE/ufw.*`: active flag, rules, `ufw.fail`), `sshd` (answers `sshd -T` from `$FAKE_STATE/sshd.ports`), `systemd-run`, `systemctl`, `id` (answers `-u` with `${FAKE_UID:-0}`, passes every other call to `/usr/bin/id`). Each new fake is strict (E1): log every call, unmodelled call exits 97 and the test fails.

1. `plan`: zero mutating calls (no `ufw allow|default|enable|disable`, no `iptables -A|-I|-N|-F`, no `systemd-run`), works with `FAKE_UID=1000`, lists the SSH ports, `25565`, `connections per source: 10` and `new connections per source: 10/second`, and says `not active` or `active` according to the fake chain.
2. `apply` as `FAKE_UID=1000`: exit 4, no `ufw` call. Without `ufw` on `PATH`: exit 3.
3. No SSH port detectable (`sshd.ports` empty, `ss.listen` empty, `SSH_CONNECTION` unset): exit 4, no mutating call.
4. Lockout: `MCCTL_SSH_PORTS=22` with `SSH_CONNECTION="198.51.100.7 5555 192.0.2.1 2222"`: exit 4, message names port 2222, no mutating call.
5. Order in `calls`: every `ufw allow` for SSH comes before `ufw --force enable`; both `default` calls come before it too.
6. SSH not accepted after enabling (the fake ufw drops the SSH rule): `ufw --force disable` is called, exit 1.
7. Timer: ufw inactive, `systemd-run` present: one `systemd-run` call with `--on-active=300s` and `ufw --force disable`. No `systemd-run`: exit 3 and `ufw` not touched. `MCCTL_FIREWALL_ROLLBACK_SECONDS=0`: enabled, no `systemd-run`. ufw already active: no timer.
8. `confirm` calls `systemctl stop` on the timer and the service; `rollback` calls `ufw --force disable` and the same stop. Both refuse as non-root.
9. SFTP: the `2222` rule appears only with `MCCTL_SFTP_PUBLIC=1`.
10. The saved state file exists under `backups/` with mode 600 and its directory 700 (E12; SKIP on hosts without POSIX modes).
11. `ssh_ports` table, at least 8 cases: configured list; configured list wins over `sshd`; `sshd -T`; `ss` with `sshd`; `SSH_CONNECTION` port; 22 fallback; sorted unique; configured `0`, `70000`, `abc`, `22;x` each refused with exit 3.
12. Guard (in `t_router.sh`): the guard script text has `MCCTL-INGRESS`, the `GAME_SUBNET` RETURN first, the two limit rules restricted to `-d "$$ROUTER_IP" -p tcp --dport 25565 -m conntrack --ctstate NEW`, the jump at position 2, and a matching `ipt -C` for each in the healthcheck; the service environment passes `CONN_LIMIT` and `RATE`. Every earlier Task 6 assertion stays green; where it counts services or rules, update it with the new numbers.
13. Config (in `t_config.sh`): `MCCTL_CONN_LIMIT` 0, `abc`, `10;x`, `70000` refused; `MCCTL_RATE` `10/day`, `0/second`, `1000000/second`, `10/second;x` refused, `10/second` and `5/minute` accepted; `MCCTL_FIREWALL_ROLLBACK_SECONDS` `-1`, `99999`, `x` refused.
14. E3: `cmd_firewall` is named in `t_firewall.sh`; the word `sudo` appears in no file the invariant scans; no new `eval`.
15. Flow (E13), one block in `tests/t_flows.sh`: `plan`, `apply`, `confirm`, `rollback` as root with ufw inactive; assert the whole ordered `calls` log from the first `ufw` call to the last.

## 6. Files

- Create: `single-standalone/lib/firewall.sh`, `single-standalone/tests/t_firewall.sh`, `single-standalone/tests/fakebin/ufw`, `sshd`, `systemd-run`, `systemctl`, `id`.
- Modify: `single-standalone/tests/fakebin/ss` (two new call shapes: `ss -H -ltnp` with no filter, and `ss -H -ltn "( sport = :PORT )"`; the same strictness), `single-standalone/templates/stack.compose.yml` (guard), `single-standalone/lib/config.sh`, `single-standalone/config/mcctl.env.example`, `single-standalone/tests/t_router.sh`, `single-standalone/tests/t_config.sh`, `single-standalone/tests/t_flows.sh`, `single-standalone/docs/reference.md` (section `## mcctl firewall`).
- Do not modify: `single-standalone/mcctl`.

Task 9 edits `templates/stack.compose.yml` and `docs/reference.md` at the same time as this spec is written. Re-read each file right before editing it and change only the lines you add. The tree needs a clean full gate after Task 9 before Task 11 starts.

## 7. Documentation (`docs/reference.md`, section `## mcctl firewall`)

The four commands; the dead-man timer and what to do on a locked-out session; why ufw does not filter Docker-published ports and what does (the guard's `MCCTL-INGRESS`); the limits and their defaults; each config key; IPv4 only; a note that many players behind one shared address (a school, a household) count as one source, so raise `MCCTL_CONN_LIMIT`; and what to do when the guard is unhealthy because the kernel lacks `xt_connlimit` or `xt_hashlimit` (`modprobe -n -v xt_hashlimit`).

## 8. Carry-overs

- Task 22 (docs): `prerequisites.md` lists the kernel modules `xt_connlimit`, `xt_hashlimit`, `xt_conntrack`, and `systemd-run` for the timer.
- Task 23, step 1 gains: after `firewall apply` and `up`, `iptables -S MCCTL-INGRESS` shows the three rules; 12 quick connections from one source to port 25565 are cut off past the limit while a normal client still joins; a reboot keeps both chains (the guard rebuilds them). On WSL, run step 7 and check that the kernel has the two modules.

## 9. Not provable in the sandbox (owed to the user's acceptance run)

Real ufw behaviour; that the limits actually drop packets; that the kernel (especially WSL's) has `xt_connlimit` and `xt_hashlimit`; that the rules survive a reboot through the guard; `systemd-run` on WSL; that a limit of 10 does not hurt a normal household.

## 10. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_firewall.sh`, then `t_router.sh` and `t_config.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-11-report.md`.

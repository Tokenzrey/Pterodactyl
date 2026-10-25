# Fix spec: honest undo message in `mcctl edit`, and `firewall plan` shows what the policy would block

Status: written, not dispatched. Written on 2026-10-25 from the safety review of Task 10 and Task 11.
Model for the implementer: `haiku` at effort `xhigh` (user instruction).
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## A. Task 10: the render-failure undo must report what really happened

Where: `lib/servers.sh`, `cmd_edit`, the branch that runs when `write_compose "$name"` fails. It currently is:

    if ! write_compose "$name"; then
        printf '%s' "$old_env" | write_atomic "$dir/server.env"
        die "cannot render $dir/compose.yaml (see above); server.env was put back as it was" "$EX_FAIL"
    fi

Problem: the status of the undo write is not checked, so the message claims a restore that may not have happened.

Required: follow the pattern of the env branch just above it:
- check the status of the undo write;
- if it succeeded: `die "cannot render $dir/compose.yaml (see above); server.env was put back as it was" "$EX_FAIL"` (unchanged message);
- if it failed: `die "cannot render $dir/compose.yaml (see above), and server.env could not be put back: check it by hand (the new values are in it)" "$EX_FAIL"`.
- Nothing is recreated in either case.

Test (tests/t_edit.sh, new case, next to the existing "render failure rolls back" case):
- Make the render fail as the existing case does (a credential-looking key in modpack.env, so the renderer refuses).
- Use the mv fake for the undo only: `FAIL_MV=<servers/s1/server.env>` and `FAIL_MV_NTH=2`. The first move onto server.env is the MEMORY write (it must succeed); the second is the undo (it must fail).
- Assert: exit 1; the message contains "could not be put back" and "by hand"; no docker compose call; the server.env content is the new value (not the old one, because the undo failed).
- Keep the existing case unchanged; it must still say "put back as it was" when the undo succeeds.

## B. Task 11: `firewall plan` (and so `firewall apply`, which prints the plan) shows what the policy would block

Where: `lib/firewall.sh`. Add `firewall_listeners` and extend `firewall_plan_text`.

`firewall_listeners`: reads `ss -H -ltn` (no pipes into external sort if avoidable; a while loop is fine) and prints one line per listening TCP socket whose local address is NOT loopback (`127.*`, `[::1]`, `::1`). Format: `PORT<TAB>ADDRESS<TAB>PROCESS` where PROCESS is the name inside `users:(("name",...` if present, else `-`. Keep it pure: no writes.

Classification in `firewall_plan_text`, after the existing rules section:
1. Allowed: a port that appears in `firewall_rules` (SSH ports, the router port, and 2222 when public). Not listed.
2. Published by Docker (PROCESS is `docker-proxy`): listed under the heading "published by Docker (ufw does not filter these; the egress guard and MCCTL-INGRESS do)". Not counted as blocked.
3. Everything else: listed under "WILL BE BLOCKED by the default deny policy (not in the allow list)".
4. If section 3 is empty, print "none: no other public listener would be blocked".

The text must say, in plain words, that these services stop accepting connections from outside when the policy is applied, and that the operator must add an allow rule first (or accept the block) before running `firewall apply`.

Tests (tests/t_firewall.sh, new cases; the ss fake in tests/fakebin/ss must answer these calls, extend it strictly if it does not):
1. A listener on `0.0.0.0:8080` with process `java` appears under "WILL BE BLOCKED".
2. A listener on `127.0.0.1:3306` and on `[::1]:5432` does not appear at all.
3. The SSH port (22) and the router port (25565) do not appear.
4. A listener on `0.0.0.0:25566` with process `docker-proxy` appears under the Docker heading, not under "WILL BE BLOCKED".
5. A listener on `[::]:443` appears under "WILL BE BLOCKED" with address `[::]`.
6. With no other public listener, the output contains "none: no other public listener would be blocked".
7. `firewall plan` still makes no mutating call (the existing assertion stays green).
8. `firewall apply` prints the same blocked list before its confirm; with the confirm declined (no terminal, no MCCTL_YES) it exits 4 and makes no ufw call.

## Constraints

- Edit only `lib/servers.sh` (the one branch in cmd_edit), `tests/t_edit.sh`, `lib/firewall.sh`, `tests/t_firewall.sh`, and `tests/fakebin/ss` if it needs a new call shape. Do not change `templates/*`, `lib/backup.sh`, or `lib/sftp.sh`.
- Another session works on Task 12 (`lib/monitor.sh`, `lib/logs.sh`): do not touch those files, and do not fix the t_invariants failure about cmd_top, which is theirs.
- Re-read each file right before you edit it. Never revert an edit you did not make.
- No real docker, sudo, ssh, ufw, iptables, or network call. LF line endings. No Python.
- Do not dispatch subagents.

## Gate (WSL only; never the Windows tests/run.sh)

- `wsl.exe bash -c 'bash /mnt/d/Documents/code/pterodactyl/single-standalone/tests/wsl-run.sh t_edit.sh t_firewall.sh t_router.sh t_config.sh t_flows.sh'` must show 0 failed.
- The whole suite with `wsl.exe bash -c 'bash /mnt/d/Documents/code/pterodactyl/single-standalone/tests/wsl-run.sh'`. Expect exactly one failure, the t_invariants cmd_top rule (Task 12, another session). Report it as not yours.

Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\fix-undo-firewall-plan-report.md`, with the changed files, the summaries with secs=, and any Ruling.

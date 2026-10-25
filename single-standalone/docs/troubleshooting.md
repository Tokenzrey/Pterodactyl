# Troubleshooting

Find the text of the message you see in the first column. The text in backticks is a fragment of the real message, so search for it. A message can also be followed by more words; the fragment is the part that does not change. `mcctl doctor` checks the host and the configuration in one run.

| Symptom (message fragment) | Cause | Fix |
|---|---|---|
| `confirmation required but there is no terminal` | a command asks a question and there is no terminal (cron, CI, a pipe) | read what the command changes, then pass `--yes` or set `MCCTL_YES=1` for that run |
| `must be accepted to run a server` | `create` without `--accept-eula` | read the EULA at the URL in the message, then add `--accept-eula` |
| `--type is required` | `create` without `--type` | pass a type such as `VANILLA`, `PAPER`, `FABRIC` or `FORGE` |
| `invalid server name` | the name has capitals, spaces, or more than 40 characters | use lower-case letters, digits and `-`; the message suggests a slug |
| `has no letter or digit` | the name has no letter or digit left | give a name that has one |
| `needs a value` | an option was given without its value | add the value after the option |
| `unknown option` | a misspelt or unsupported flag | compare with the usage line the message prints |
| `--modpack and --modpack-version need` | modpack flags given without `--modpack-source` | add `--modpack-source curseforge` or `--modpack-source modrinth` |
| `is neither curseforge nor modrinth` | `--modpack-source` has another value | use `curseforge` or `modrinth` |
| `leave --type out` | `--type` given with a modpack source | drop `--type`; the source sets it |
| `is not a duration` | `--backup-interval` is not a duration | use a value such as `24h`, `30m`, `2h` or `7d` |
| `is neither local, s3 nor rsync` | `--backup` has another value | pick `local`, `s3` or `rsync` |
| `already exists (mcctl list shows the servers)` | `create` with a name that is in use | choose another name, or delete the old server first |
| `is already used by server` | the host name is taken by another server | pass `--hostname` with another name |
| `a leftover of an interrupted create or delete` | a folder under `servers/` with no container behind it | look inside it, then run `mcctl delete NAME` |
| `no DNS record for` | Cloudflare refused the record (the cause is printed above it) | fix that cause; nothing was created, so run `create` again |
| `no Cloudflare API token` | `secrets/cloudflare_token` is missing or not readable | put a token there, mode 600, with DNS edit on the one zone |
| `could not be deleted` | the DNS record of a server could not be removed (Cloudflare unreachable, or the token is wrong) | nothing was removed; fix the token or the network, then run `mcctl delete NAME` again |
| `could not archive` | the archive of a server's data failed (disk full, permissions) | nothing was deleted; fix the cause, then run `mcctl delete NAME` again |
| `could not delete` | `delete` could not clear the server's folder; the helper's error is above it | its containers and DNS record are gone and the archive is kept; fix the cause (Docker running, the image there), then run `mcctl delete NAME` again |
| `no server named` | the name is misspelt, or the server is already deleted | run `mcctl list` to see the names |
| `is not running` | a command needs the server running (for example RCON) | start it with `mcctl start NAME`, then run the command again |
| `is running: stop it first` | a restore of a running server, refused to protect the world | run `mcctl stop NAME`, then restore |
| `stop it first (mcctl stop` | a world change on a running server | stop the server, then run the world command again |
| `config pending: mcctl apply` | a setting is saved but the container still runs the old one | run `mcctl apply NAME` (or `set --apply` next time) |
| `players online; pass --yes` | `apply` or `edit` would restart a server with players on it | wait until the players leave, or pass `--yes` knowingly |
| `could not ask who is online` | RCON did not answer the player count | check with `mcctl status NAME`; retry, and pass `--yes` only if you know no one is on |
| `is structural: set does not change it` | `set` was given `MEMORY` or `CPUS` | use `mcctl edit NAME --memory ...` or `--cpus ...` |
| `is reserved: mcctl's RCON and CurseForge wiring` | `set` was given a key that mcctl itself uses | do not set it; use the command that owns it |
| `is not a known setting` | the key is misspelt, or it is not a setting | check the spelling in the settings table in reference.md |
| `needs jq, which is not installed` | a JSON setting needs `jq` | install `jq` |
| `is not a valid server.env` | `server.env` was edited by hand into a bad line | fix the line the message names; `mcctl set` writes valid lines |
| `has unsafe members` | a backup archive has an absolute, `..` or link member | do not extract it by hand; restore another archive |
| `is not a readable archive` | the backup file is missing or damaged | check the name under `backups/` and run `tar -tzf` on it |
| `has no members` | the backup archive is empty | restore another archive |
| `invalid archive id` | the restore ID is a path, not a file name | pass the file name only, as `mcctl backup NAME list` shows it |
| `must be a number from 1 to 65535` | `MCCTL_UID` in `config/mcctl.env` is not a valid UID | set the UID the game runs as (1000 for itzg's image) |
| `a world archive holds only` | the archive has other top-level names than the world | restore the archive of that world |
| `autosave state unknown` | the RCON save-off before a world backup or export failed, so mcctl does not know whether autosave is on | run `mcctl rcon NAME save-on`, check the server with `mcctl status NAME`, then run the command again |
| `ufw is not installed` | `firewall apply` on a host without `ufw` | install it (`apt install ufw` on Ubuntu) and run it again |
| `needs systemd-run, which this host does not have` | the firewall's dead-man timer needs systemd | run on a systemd host (WSL: enable systemd), or set `MCCTL_FIREWALL_ROLLBACK_SECONDS=0` if you accept no timer |
| `is not accepted by the active rule set` | an SSH port would be closed by the new rules | add the port to `MCCTL_SSH_PORTS`; the firewall was switched off again, so nothing is locked out |
| `ufw rejected:` | a rule ufw does not accept | fix the rule; nothing was enabled |
| `is already in use, so the router cannot start` | another process listens on port 25565 | stop it (the message names it), then run `mcctl up` |
| `ss not found` | `iproute2` is not installed | install `iproute2` |
| `cannot tell whether port` | `ss` failed, so the port cannot be checked | run `ss -ltnp` by hand and fix what it reports |
| `docker compose stop failed` | Docker failed on a stop | nothing was deleted; check Docker, then run the command again |
| `docker compose create failed` | Docker failed on `create` | nothing is kept (the undo ran); read the compose output above it, then run `create` again |
| `the files are already written but docker compose up failed` | `apply` stopped after it wrote the files | run the same `apply` again |
| `SFTP could not be set up` | SFTP failed during `create` | the server was created; fix the cause, then run `mcctl sftp repair` |
| `the SFTP stack did not start` | the SFTP container failed in `mcctl up` | fix the cause, then run `mcctl sftp repair` |
| `needs your CurseForge API key in the file` | `secrets/curseforge_api_key` is missing or empty | put the key alone on one line in that file, mode 600 |
| `is not a Modrinth project` | a Modrinth entry has characters outside the allowed set | use a project slug, or `slug:version` |
| `is not a file, an https:// URL` | a mod entry is neither a file nor an `https://` URL | use an `https://` URL without credentials, or a file in `mods/` |
| `is older than` | an upgrade to an older version | keep the newer version, or pass `--allow-downgrade` if you accept the risk |
| `no environment variable for the server property` | `properties` was given a name that is not mapped | run `mcctl properties NAME list` for the mapped names |
| `rcon.password is not set here` | `properties` was asked to set the RCON password | use `mcctl rotate-rcon NAME` |
| `unknown command:` | the command is misspelt | run `mcctl help` for the list |
| `SFTP is not running, so the change takes effect` | `add-key`, `remove-key` or `repair` ran while the SFTP container is stopped; nothing was started | run `mcctl up`: it starts SFTP with the current users and keys |
| `SFTP not started: no user yet` | `mcctl up` with no SFTP user in `sftp-users.conf`, so SFTP is not started (it would exit at once) | create a server (its user is added) or run `mcctl sftp add-key NAME PUBKEYFILE`, then `mcctl up` |
| `could not recreate the SFTP container` | docker compose could not recreate the container; the error from docker is printed above this line | read that error, then `docker logs --tail 20 mcctl-sftp`, fix the cause and run `mcctl sftp repair` |
| `could not start the SFTP container` | `mcctl up` could not start SFTP; the error from docker is printed above | the same as above, then `mcctl up` again |
| `cannot read the group of the Docker socket` | the Docker socket is missing, or this user cannot read it, so the router cannot be given its group | start Docker, check that `docker ps` works without `sudo`, or point `MCCTL_DOCKER_SOCKET` at the right socket |
| `must be on (a DNS record per server` | `MCCTL_DNS` has a value other than `on` or `off` | set `MCCTL_DNS=on` (records in Cloudflare) or `MCCTL_DNS=off` (local play) in `config/mcctl.env` |
| `DNS is off: no DNS record is touched` | informational: `delete` ran with `MCCTL_DNS=off` | a record made while DNS was on stays in Cloudflare; remove it in the dashboard |
| `dead-man switch cancelled` | informational: `firewall confirm` ran | nothing to do: the firewall stays on |

## Problems outside mcctl's messages

mcctl does not print the messages below. Each entry gives the usual cause and the check that tells them apart.

### `Permission denied (publickey)` on SSH or SFTP

The key you offer is not the one the server has. Run `ssh -v -i KEY USER@HOST` and read the `Offering public key` lines to see which key is sent.
On the server, compare the public key with `~/.ssh/authorized_keys` (SSH to the VPS) or with `sftp-keys/NAME` (SFTP). Install the right public
key: see [VPS setup step 2](vps-setup.md#2-create-an-admin-user-and-an-ssh-key) or `mcctl sftp add-key`.

### `REMOTE HOST IDENTIFICATION HAS CHANGED`

The server's host key differs from the one your client remembers. For SFTP this happens when a different server answers on that port,
for example a local mcctl SFTP container on the same laptop using port 2222. Check which port your tunnel forwards to. If the change
is expected (the host key volume was removed), remove the old entry with `ssh-keygen -R "[127.0.0.1]:PORT"` and connect again, checking
the new fingerprint. If you did not expect it, do not remove the entry.

### `Address already in use` when a tunnel starts

Something on your machine already listens on the local port: an earlier `ssh -L` still running, or a local container. Use another local
port, for example `2223`. To find the process: on Linux `ss -ltnp | grep :2222`, on Windows `netstat -ano | findstr :2222`.

### `Connection refused` on the tunnel port

The tunnel is not running, or nothing listens at the far end. Start the tunnel first and keep its terminal open. On the host,
`docker ps --filter name=mcctl-sftp` must show `Up`. A tunnel opened in Windows is not visible from WSL on its `127.0.0.1` (unless
mirrored networking is on): open the tunnel in the same environment as the client.

### The SFTP container shows `Restarting`

Read `docker logs --tail 20 mcctl-sftp`. `no hostkeys available` means the first start did not finish, usually because a file it had to
change could not be (for example `Operation not permitted` from `chmod`, when the capability `FOWNER` is missing). `mcctl up` recreates the
container; the current templates include the capability and the host-key volume.

### The server container restarts with `Permission denied` on `/run/secrets/rcon_password`

The server runs as UID 1000 and cannot read `secrets/rcon-NAME`, which belongs to another user (usually `deploy`, UID 1001). Check with
`ls -ln secrets/` and `id -u deploy`. mcctl gives the file to UID 1000 itself whenever it writes it (`create`, `rotate-rcon`,
`import`), so this comes back only for a file made before that change. Then, once, as root: `chown 1000:1000 secrets/rcon-NAME`, and
`mcctl start NAME`. Do not change `cloudflare_token`: the host reads it. See [VPS setup step 11](vps-setup.md#11-secrets-and-who-can-read-them).

### Cloudflare: `10000 Authentication error` or `can not be used before`

The token is wrong, expired, or has a start date in the future. Check it with
`curl -s -H "Authorization: Bearer $(cat secrets/cloudflare_token)" https://api.cloudflare.com/client/v4/user/tokens/verify`: the answer must
say `"status":"active"` and show no messages. Otherwise create a new token without a start date and store it again with `read -rs`. See
[VPS setup step 10](vps-setup.md#10-cloudflare).

### A password prompt appears although a key exists

Either the server still allows passwords, or the client does not offer the key. On the server, `sudo sshd -T | grep passwordauthentication`
must say `no`. If it says `yes`, a file that is read earlier than yours sets it: cloud images ship `50-cloud-init.conf` with
`PasswordAuthentication yes`, so name your file `00-hardening.conf` (see [VPS setup step 4](vps-setup.md#4-harden-ssh-key-login-only-no-root-over-ssh)).
On the client, pass the key with `-i`.

### The router is `Exited`, or its log shows a panic in `RoutesConfigLoader`

An older mcctl sent SIGHUP to the router to reload its routes, and mc-router panicked on it. Start the router again with `mcctl up`.
The current code does not send SIGHUP. Check `docker logs --tail 20 mcctl-router`.

### `Address already in use` when the router starts

Docker could not give the router its address (`MCCTL_ROUTER_IP`). This happens when a game server started while the router was down and
was given the router's address, because the network was made by an older mcctl. Check the network:

```
docker network inspect mcctl_game --format '{{json .IPAM.Config}}'
```

For `172.30.0.0/24`, the configuration must contain the IP range `172.30.0.128/25`, which keeps the router's half free. To fix a network
made without it: stop the servers (`mcctl stop NAME`), run `mcctl down`, remove the leftover game containers (`docker rm -f mc-NAME`; their
data stays in `servers/NAME/`), run `docker network rm mcctl_game`, then `mcctl up` and start the servers again.

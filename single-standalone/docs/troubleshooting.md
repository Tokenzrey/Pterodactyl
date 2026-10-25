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
| `files owned by another user` | `delete` cannot remove a file that another user owns | remove that folder by hand, then run `mcctl delete NAME` again |
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
| `could not signal mc-router` | mc-router did not take the HUP | run `mcctl up`; the routes are read again when it starts |
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

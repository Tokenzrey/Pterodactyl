# Prerequisites

What a host needs before `mcctl init`. `mcctl doctor` checks most of it and prints one line per check.

## Docker

- Docker Engine with the Compose v2 plugin. `mcctl` calls `docker compose`, not `docker-compose`.
- Compose 2.1.1 or newer: `mcctl up` runs `docker compose up -d --wait`, which first appeared in 2.1.1. Servers are recreated with `create --force-recreate` (stopped) and `up -d --force-recreate` (running).
- The Engine version is not pinned by the code. Test on the Engine your distribution ships.
- The user that runs `mcctl` must be able to talk to the Docker socket. No `sudo` is used by `mcctl`.

## Shell and tools

- `bash` 4.4 or newer (`mcctl doctor` checks it).
- `jq` and `curl`: `doctor` checks both. `curl` is used only for Cloudflare.
- `ss` (package `iproute2`): checks that port 25565 is free before `mcctl up`.
- `tar`, and GNU `sort -V` (coreutils): archives, and version comparisons.
- `sshd` and `ufw`: the firewall commands read the SSH ports from `sshd -T`, and `mcctl firewall apply` needs `ufw`.
- `systemd-run`: the firewall's dead-man timer. Without it `firewall apply` refuses to enable ufw, unless `MCCTL_FIREWALL_ROLLBACK_SECONDS=0` is set, which turns the timer off.

## Kernel modules

The egress guard's rules use the iptables matches `xt_connlimit`, `xt_hashlimit` and `xt_conntrack`. `mcctl` does not load them. If a match is missing, the guard's rules cannot be written and the guard stays unhealthy, so `mcctl up` fails.

## Cloudflare

- The zone of `MCCTL_DOMAIN` is on Cloudflare. Its Zone ID goes in `MCCTL_CF_ZONE_ID` in `config/mcctl.env`.
- The API token is a file, `secrets/cloudflare_token`, mode 600. It is not a value in any config file.
- Token scope: DNS edit on that one zone, and nothing else.
- `mcctl` writes A records with `proxied: false`, so each record is DNS-only.

The Cloudflare record for the game port is DNS-only (grey cloud); the origin IP is reachable directly, because Cloudflare's free plan cannot proxy raw Minecraft traffic. This is a protocol limit, not a defect; the firewall, the egress guard and the rate limit are what protect that address.

## CurseForge

Packs from CurseForge need an API key in `secrets/curseforge_api_key`, mode 600, with the key alone on one line. `mcctl create --modpack-source curseforge` refuses to run without it. Modrinth packs need no key.

## Firewall assumptions

- `mcctl firewall apply` makes ufw the host firewall with `default deny incoming` and `default allow outgoing`. It keeps the SSH ports open (`MCCTL_SSH_PORTS`, or the ports found from `sshd -T`, `ss` and `SSH_CONNECTION`) and 25565. It checks that the SSH port is accepted before it leaves ufw on.
- ufw filters only the host's INPUT chain. Traffic published by Docker goes through DNAT and FORWARD, so ufw does not filter it. The egress guard's DOCKER-USER chain and its MCCTL-INGRESS chain do.
- The connection and rate limits on 25565 live in MCCTL-INGRESS: `MCCTL_CONN_LIMIT` per source and `MCCTL_RATE` for new connections. Many players behind one address count as one source.
- The dead-man timer switches ufw off again after `MCCTL_FIREWALL_ROLLBACK_SECONDS` (default 300) unless `mcctl firewall confirm` runs from a new session.
- SFTP is published on 127.0.0.1:2222 only. It is public on 0.0.0.0 only when `MCCTL_SFTP_PUBLIC=1`.

## Ubuntu and WSL

- Ubuntu (a VPS) is the primary host. Every path in `mcctl` must work there.
- WSL works for development and for the test suite. `systemd-run` needs systemd running in the distribution (`[boot] systemd=true` in `/etc/wsl.conf`). Without it, use `MCCTL_FIREWALL_ROLLBACK_SECONDS=0` or do not run `firewall apply`.
- Under Docker Desktop, "the host's network namespace" that the egress guard uses is the Docker VM, not Windows. The guard's rules live there.
- Spike S1 (router to game container with the guard healthy, and no route from a game container to the gateway or the metadata address) on Ubuntu and on WSL: not yet recorded. Task 23 records the result.
- Spike S2 (the backup sidecar's access to the RCON password): not yet recorded. See [architecture.md](architecture.md#spike-results).

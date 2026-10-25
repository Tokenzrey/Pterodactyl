# Security

> **Type:** Concept + Guide · **For:** Operator · **Updated:** 2026-10-23

## EULA Acceptance

Mojang/Microsoft requires EULA acceptance before the Minecraft server will start. Always include `-e EULA=TRUE` in your commands and container definitions.

**Source**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/)

## RCON Security

RCON is **enabled by default** on port 25575 within the container. The default password is randomly generated on each startup.

### Recommended Practices

- Use `RCON_PASSWORD_FILE` instead of `RCON_PASSWORD` for managing sensitive data, as it supports [Docker Secrets](https://docs.docker.com/compose/how-tos/use-secrets/)

```yaml
services:
  mc:
    image: itzg/minecraft-server:latest
    environment:
      EULA: "TRUE"
      RCON_PASSWORD_FILE: /run/secrets/rcon_pass
    secrets:
      - rcon_pass

secrets:
  rcon_pass:
    file: ./rcon_password
```

> [!WARNING]
> **BE CAUTIOUS OF MAPPING THE RCON PORT EXTERNALLY** unless you are aware of all consequences and have set a **secure password**. Most production Docker deployments do not need any of the Minecraft ports mapped externally from the server itself.

> [!IMPORTANT]
> Do not change `rcon.port` via `server.properties` or integrations will break. Use the `RCON_PORT` environment variable if you must change the port.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Whitelist for Public Servers

> [!IMPORTANT]
> For public servers, it is very important to consider setting a whitelist of expected players.

Configure via `WHITELIST` or `WHITELIST_FILE`:

```yaml
environment:
  WHITELIST: |
    user1
    user2
    user3
```

To enforce whitelist changes immediately when whitelist commands are used, set `ENFORCE_WHITELIST` to "true".

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Server Port Configuration

> [!WARNING]
> Only change `SERVER_PORT` if you know what you're doing. It only needs to be changed when using host-networking, and it is rare that host networking should be used. Use `-p` port mappings instead.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Loading Environment from Packs

> [!WARNING]
> When using `LOAD_ENV_FROM_GENERIC_PACK`, `LOAD_ENV_FROM_FILE`, or `LOAD_ENV_FROM_ARCHIVE`, the env file is sourced by `bash`, so any shell syntax it contains will be evaluated. Only point these variables at sources you trust. `EULA` cannot be set this way — it is checked before the env file is loaded.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Cross-References

- [Configuration](configuration.md) — Full configuration reference
- [Deployment](deployment.md) — Deployment patterns
- [Environment Variables](environment-variables.md) — Complete variable reference
- [Glossary](GLOSSARY.md) — Domain terminology

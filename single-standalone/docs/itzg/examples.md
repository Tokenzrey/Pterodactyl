# Examples

> **Type:** Reference · **For:** Beginner, Operator · **Updated:** 2026-10-23

Various examples are maintained in the [GitHub repository examples directory](https://github.com/itzg/docker-minecraft-server/tree/master/examples). The sections below highlight particular ones from the [ReadTheDocs examples page](https://docker-minecraft-server.readthedocs.io/en/latest/misc/examples/).

## Basic Vanilla Server

The simplest example — a vanilla Minecraft server with the latest version:

```yaml
services:
  mc:
    image: itzg/minecraft-server:latest
    pull_policy: daily
    tty: true
    stdin_open: true
    ports:
      - "25565:25565"
    environment:
      EULA: "TRUE"
    volumes:
      - ./data:/data
```

**Source**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/)

## Bedrock Compatible Server

Using the [GeyserMC plugin](https://geysermc.org/) with a Paper server "enables clients from Minecraft Bedrock Edition to join your Minecraft Java server". The example also includes [Floodgate](https://wiki.geysermc.org/floodgate/) which "allows Xbox Live authenticated Bedrock users to join without a Java Edition account".

```yaml
services:
  mc:
    image: itzg/minecraft-server:latest
    pull_policy: daily
    environment:
      EULA: "true"
      TYPE: "PAPER"
      PLUGINS: |
        https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot
        https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot
    ports:
      - "25565:25565"
      - "19132:19132/udp"
    volumes:
      - ./data:/data
```

**Source**: [S2 misc/examples](https://docker-minecraft-server.readthedocs.io/en/latest/misc/examples/) · [S1 examples/geyser](https://github.com/itzg/docker-minecraft-server/blob/master/examples/geyser/docker-compose.yml)

## mc-router with Auto-Scale

See [deployment.md](deployment.md#mc-router-with-auto-scale) for the full example.

Using [mc-router](https://github.com/itzg/mc-router) to route players based on hostname, with auto-scale up/down.

**Source**: [S2 misc/examples](https://docker-minecraft-server.readthedocs.io/en/latest/misc/examples/)

## Lazymc — Put Your Minecraft Server to Rest When Idle

See [deployment.md](deployment.md#lazymc--put-your-minecraft-server-to-rest-when-idle) for the full example.

Using [lazymc-docker-proxy](https://github.com/joesturge/lazymc-docker-proxy) with the Minecraft container.

**Source**: [S2 misc/examples](https://docker-minecraft-server.readthedocs.io/en/latest/misc/examples/)

## Lazytainer — Stop Minecraft Container Based on Traffic

See [deployment.md](deployment.md#lazytainer--stop-minecraft-container-based-on-traffic) for the full example.

Using [Lazytainer](https://github.com/vmorganp/Lazytainer) to monitor network traffic and stop/pause the container when idle.

**Source**: [S2 misc/examples](https://docker-minecraft-server.readthedocs.io/en/latest/misc/examples/)

## Loading Mods from a Local Directory

The most basic mod loading example, where `./mods` is mounted as `/mods`:

```yaml
environment:
  EULA: "TRUE"
  TYPE: "NEOFORGE"
volumes:
  - "./data:/data"
  - "./mods:/mods"
```

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Using Cardboard Plugins with Fabric

```yaml
environment:
  EULA: "TRUE"
  TYPE: "FABRIC"
  MODRINTH_PROJECTS: |
    fabric-api
    cardboard
  USES_PLUGINS: true
```

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Auto-Downloading Plugins

```yaml
environment:
  PLUGINS: |
    https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot
    https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot
```

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Multiple Source Directories for Plugins

```yaml
environment:
  TYPE: PAPER
  COPY_PLUGINS_SRC: /plugins-common,/plugins-local
volumes:
  - mc-data:/data
  - ../plugins-common:/plugins-common:ro
  - ./plugins:/plugins-local:ro
```

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## MOTD with Placeholders

```yaml
environment:
  MOD_PLATFORM: AUTO_CURSEFORGE
  CF_SLUG: craftoria
  MOTD: |
    A %TYPE% server on %VERSION%
    running %MODPACK_NAME% %MODPACK_VERSION%
```

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Cross-References

- [Deployment](deployment.md) — Full deployment patterns
- [Server Types](server-types.md) — Server type configuration
- [Modpacks](modpacks.md) — Modpack installation
- [Glossary](GLOSSARY.md) — Domain terminology

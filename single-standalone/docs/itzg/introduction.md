# Introduction to itzg/docker-minecraft-server

> **Type:** Concept + Tutorial · **For:** Beginner · **Updated:** 2026-10-23

## What is itzg/docker-minecraft-server?

The `itzg/minecraft-server` Docker image provides a Minecraft Server for Java Edition that automatically downloads, installs, and upgrades the server version, modloaders, modpacks, and more at container startup. It is published to [Docker Hub](https://hub.docker.com/r/itzg/minecraft-server/) and the source code is available on [GitHub](https://github.com/itzg/docker-minecraft-server).

> [!INFO]
> This image only supports Java Edition natively. For Bedrock Edition compatibility, use [itzg/minecraft-bedrock-server](https://github.com/itzg/docker-minecraft-bedrock-server) or add Bedrock compatibility via [GeyserMC](examples.md#bedrock-compatible-server) to a Java Edition server.

**Sources**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/), [S1 README](https://github.com/itzg/docker-minecraft-server)

## Quick Start

### Using docker run

To simply use the latest stable version of the vanilla Minecraft server:

```bash
docker run -d -it -p 25565:25565 -e EULA=TRUE itzg/minecraft-server
```

This exposes the standard server port `25565` on your host machine.

> [!IMPORTANT]
> Always include `-e EULA=TRUE` in your commands and container definitions, as Mojang/Microsoft requires EULA acceptance.

**Source**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/)

### Using Docker Compose

1. Create a new directory
2. Put the contents below in a file called `compose.yaml`
3. Run `docker compose up -d` in that directory
4. Point your client at your host's name/IP address and port 25565

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

To apply changes made to the compose file, run `docker compose up -d` again. Follow logs with `docker compose logs -f`, check status with `docker compose ps`, and stop with `docker compose stop`.

> [!NOTE]
> If you plan on running a server for a longer amount of time, it is highly recommended using a management layer such as Docker Compose or Kubernetes to allow for incremental reconfiguration and image upgrades.

**Source**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/)

## Persistent Data

The Minecraft server stores its data in the container's `/data` directory. This directory can be [mounted](https://docs.docker.com/storage/volumes/) from the host machine or a managed volume.

Using `docker run`, add a `-v` option before the image name:

```bash
docker run -d -it -p 25565:25565 -e EULA=TRUE -v /path/on/host:/data itzg/minecraft-server
```

Using Docker Compose, add a `volumes` section:

```yaml
services:
  mc:
    image: itzg/minecraft-server:latest
    environment:
      EULA: "TRUE"
    volumes:
      - ./data:/data
```

**Source**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/)

## What This Image Provides

By default, the container downloads the latest version of the "vanilla" [Minecraft: Java Edition server](https://www.minecraft.net/en-us/download/server) provided by Mojang. The image provides:

- **Automatic version management** — Download the latest stable version at startup, or upgrade to any specific version or the latest snapshot. See [versions.md](versions.md).
- **Server type selection** — Configure `TYPE` to create many variations: VANILLA, FORGE, FABRIC, SPIGOT, PAPER, NEOFORGE, QUILT, and more. See [server-types.md](server-types.md).
- **Modpack support** — Automatically download and install modpacks from CurseForge, Modrinth, ATLauncher, FTB, and more. See [modpacks.md](modpacks.md).
- **Mod and plugin management** — Automated downloads and cleanup of individual mods and plugins. See [mods-and-plugins.md](mods-and-plugins.md).
- **Server properties via environment variables** — All known `server.properties` entries manageable via env vars. See [configuration.md](configuration.md).
- **Deployment patterns** — Docker Compose, Kubernetes (Helm, Kustomize), and more. See [deployment.md](deployment.md).

The `VERSION` and `TYPE` environment variables can be configured to create many variations of the desired Minecraft server.

**Sources**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/), [S1 README](https://github.com/itzg/docker-minecraft-server)

## Configurator Tool

If you prefer an interactive tool to create or edit a Docker Compose file for this image, you can use [setupmc.com's configurator](https://setupmc.com/java-server/). It provides a form that supports most of the image variables and generates the `compose.yaml` file in real time.

**Source**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/)

## More Examples

There are more examples in the [GitHub examples directory](https://github.com/itzg/docker-minecraft-server/tree/master/examples) and on the [examples page](examples.md). The [deployments page](deployment.md) provides more examples of deployment with and beyond Docker Compose.

**Sources**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/), [S1 examples/](https://github.com/itzg/docker-minecraft-server/tree/master/examples)

## Sponsors

This project is supported by sponsors including:

- **[SpawnBox](https://spawnbox.app)** — A Windows desktop app powered by `itzg/minecraft-server` for parents, teens, and friend groups who want a Minecraft server on their own PC without learning Docker, WSL2, or networking.
- **[Server.pro](https://server.pro)** — A game server hosting platform offering one-click Minecraft server deployment powered by `itzg/minecraft-server`, with global locations and an easy-to-use control panel.
- **[Seedloaf](https://seedloaf.com)** — Built on top of `itzg/minecraft-server`, offering free and premium Minecraft servers with full control.

**Source**: [S1 README](https://github.com/itzg/docker-minecraft-server)

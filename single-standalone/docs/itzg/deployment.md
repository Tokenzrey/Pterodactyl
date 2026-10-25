# Deployment

> **Type:** Guide + Reference · **For:** Operator · **Updated:** 2026-10-23

## Docker Compose

The recommended way to run the Minecraft server for longer periods is using Docker Compose:

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

To apply changes, run `docker compose up -d` again. Follow logs with `docker compose logs -f`, check status with `docker compose ps`, and stop with `docker compose stop`.

> [!NOTE]
> Using `pull_policy: daily` ensures the image is updated daily when the container starts.

**Source**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/)

## Kubernetes

### Using Helm

- **itzg Helm Chart**:
  - [GitHub repo](https://github.com/itzg/minecraft-server-charts)
  - [Helm Chart repo](https://itzg.github.io/minecraft-server-charts/)
- [mcsh/server-deployment](https://github.com/mcserverhosting-net/charts)

### Using Shulker

[Shulker](https://github.com/jeremylvln/Shulker) is a Kubernetes operator for managing complex and dynamic Minecraft infrastructures, including game servers and proxies. It uses the docker-minecraft-server and docker-bungeecord images under-the-hood.

**Source**: [S2 misc/deployment](https://docker-minecraft-server.readthedocs.io/en/latest/misc/deployment/)

## With Ansible

[Ansible](https://docs.ansible.com/ansible/latest/getting_started/introduction.html) is an open-source task automation tool built in Python. Ansible playbooks can automate deploying remote Minecraft servers.

### Using the MASH Playbook

[The MASH Playbook](https://github.com/mother-of-all-self-hosting/mash-playbook) is a premade playbook that can deploy a wide variety of open-source services, including [docker-minecraft-server](https://github.com/mother-of-all-self-hosting/ansible-role-minecraft).

1. Check out the [Installation Guide](https://github.com/mother-of-all-self-hosting/mash-playbook/blob/main/docs/README.md) for the MASH playbook
2. Enable [Minecraft](https://github.com/mother-of-all-self-hosting/mash-playbook/blob/main/docs/services/minecraft.md) in your `vars.yml`
3. Enable supporting services as needed (user authentication, remote backups, email relay, monitoring, databases, etc.)

**Source**: [S2 misc/deployment](https://docker-minecraft-server.readthedocs.io/en/latest/misc/deployment/)

## On CloudFormation (AWS)

For deploying to Amazon Web Services, check out the [Minecraft Server Deployment (CloudFormation) repository](https://github.com/vatertime/minecraft-spot-pricing). This repository contains a CloudFormation template that gets you running in AWS in minutes. It optionally uses Spot Pricing for cost savings and can be turned off when not in use.

**Source**: [S2 misc/deployment](https://docker-minecraft-server.readthedocs.io/en/latest/misc/deployment/)

## mc-router with Auto-Scale

Using [mc-router](https://github.com/itzg/mc-router) in front of one or multiple Minecraft server containers allows you to route players based on the hostname they use to connect.

With `AUTO_SCALE_UP` and `AUTO_SCALE_DOWN` enabled, mc-router can automatically start a target server when a player connects and stop it after a period of inactivity.

```yaml
services:
  router:
    image: itzg/mc-router
    environment:
      IN_DOCKER: true
      AUTO_SCALE_DOWN: true
      AUTO_SCALE_UP: true
      AUTO_SCALE_DOWN_AFTER: 2h
      AUTO_SCALE_ASLEEP_MOTD: "Server is asleep. Join again to wake it up!"
    ports:
      - "25565:25565"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

  vanilla:
    image: itzg/minecraft-server
    environment:
      EULA: "TRUE"
    labels:
      mc-router.host: "vanilla.example.com"

  paper:
    image: itzg/minecraft-server
    environment:
      EULA: "TRUE"
      TYPE: PAPER
    labels:
      mc-router.host: "paper.example.com"
```

**Source**: [S2 misc/examples](https://docker-minecraft-server.readthedocs.io/en/latest/misc/examples/)

## Lazymc — Put Your Minecraft Server to Rest When Idle

With [lazymc-docker-proxy](https://github.com/joesturge/lazymc-docker-proxy) you can use [lazymc](https://github.com/timvisee/lazymc) with the Minecraft container. Lazymc requires the Minecraft server to have a static IP.

```yaml
networks:
  minecraft-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.18.0.0/16

services:
  lazymc:
    image: ghcr.io/joesturge/lazymc-docker-proxy:latest
    networks:
      minecraft-network:
        ipv4_address: 172.18.0.2
    restart: unless-stopped
    volumes:
      - data:/server:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "25565:25565"

  mc:
    image: itzg/minecraft-server:java21
    pull_policy: daily
    networks:
      minecraft-network:
        ipv4_address: 172.18.0.3
    labels:
      - lazymc.enabled=true
      - lazymc.group=mc
      - lazymc.server.address=mc:25565
    tty: true
    stdin_open: true
    restart: no
    environment:
      EULA: "TRUE"
    volumes:
      - data:/data

volumes:
  data:
```

**Source**: [S2 misc/examples](https://docker-minecraft-server.readthedocs.io/en/latest/misc/examples/)

## Lazytainer — Stop Minecraft Container Based on Traffic

[Lazytainer](https://github.com/vmorganp/Lazytainer) monitors network traffic to the Minecraft containers. If there is traffic, the container runs; otherwise, it is stopped/paused.

```yaml
services:
  lazytainer:
    image: ghcr.io/vmorganp/lazytainer:master
    environment:
      VERBOSE: false
    ports:
      - 25565:25565
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - lazytainer.group.minecraft.sleepMethod=stop
      - lazytainer.group.minecraft.ports=25565
      - lazytainer.group.minecraft.minPacketThreshold=2
      - lazytainer.group.minecraft.inactiveTimeout=600
    restart: unless-stopped
    network_mode: bridge
  mc:
    image: itzg/minecraft-server:latest
    pull_policy: daily
    environment:
      EULA: TRUE
      TYPE: PAPER
      MEMORY: 4G
    volumes:
      - ./data:/data
    labels:
      - lazytainer.group=minecraft
    depends_on:
      - lazytainer
    network_mode: service:lazytainer
    tty: true
    stdin_open: true
    restart: unless-stopped
```

**Source**: [S2 misc/examples](https://docker-minecraft-server.readthedocs.io/en/latest/misc/examples/)

## Supporting Articles

- "Zero to Minecraft Server with Docker Desktop and Compose" — https://dev.to/rela-v/zero-to-minecraft-server-with-docker-desktop-and-compose-500a

**Source**: [S2 misc/deployment](https://docker-minecraft-server.readthedocs.io/en/latest/misc/deployment/)

## Cross-References

- [Examples](examples.md) — Curated usage examples
- [Configuration](configuration.md) — Server configuration
- [Glossary](GLOSSARY.md) — Domain terminology

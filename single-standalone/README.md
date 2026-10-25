# mcctl

mcctl runs several Minecraft servers (itzg/minecraft-server) on one Docker host, behind one public port (25565) and SSH, with one folder per server and Docker as the only record of what exists. The folder `docs/itzg/` is the documentation of the itzg image, not of mcctl: the two folders differ, and mcctl's own documentation is in [docs/](docs/README.md).

## Quick start

```
./mcctl init                      # writes config/mcctl.env from the example; creates secrets/
./mcctl doctor                    # checks the host and the configuration
./mcctl up                        # starts the router (port 25565) and the egress guard
./mcctl create survival --type PAPER --accept-eula --memory 4G
./mcctl start survival
```

Read [prerequisites](docs/prerequisites.md) first. A server is reached at `survival.<MCCTL_DOMAIN>` on the game port, through the router.

## Documentation

- [docs/README.md](docs/README.md): the index of mcctl's pages.
- [docs/reference.md](docs/reference.md): every command, flag and configuration key.
- [docs/management-guide.md](docs/management-guide.md): worked tasks.
- [docs/troubleshooting.md](docs/troubleshooting.md): messages and fixes.
- [docs/itzg/README.md](docs/itzg/README.md): the itzg image's own documentation (a different thing; not mcctl's).

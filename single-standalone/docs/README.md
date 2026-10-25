# mcctl documentation

Start with [prerequisites](prerequisites.md) on a new host, then [architecture](architecture.md) to see what mcctl changes and where it can fail.

- [Prerequisites](prerequisites.md): Docker and Compose, the tools, Cloudflare, CurseForge, the firewall, Ubuntu and WSL.
- [Architecture](architecture.md): the create, delete, backup restore, world restore, router and egress, and drift flows.
- [Management guide](management-guide.md): worlds, settings, files, players, mods, versions, modpacks, and clone, rename, export and import, with examples and refusals.
- [Command reference](reference.md): every command and its flags, the configuration keys, the settings table, exit codes, and the file layout.
- [Troubleshooting](troubleshooting.md): the messages mcctl prints, their causes, and their fixes.
- [Velocity and BungeeCord](velocity.md): not managed by mcctl; how an operator can add one by hand.
- [Acceptance run](acceptance.md): the protocol a person runs on real hosts before a release. It records no results itself.

The folder `docs/itzg/` next to this one is the documentation of the itzg/minecraft-server image that every server runs. It is not mcctl's documentation.

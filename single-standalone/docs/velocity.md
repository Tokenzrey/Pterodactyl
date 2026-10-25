# Velocity and BungeeCord

mcctl does not manage Velocity or BungeeCord: no script manages a proxy. Nothing installs, configures, starts, or updates one. Every server is a plain itzg server behind the router, and the router sends a player to the server named by the host name they typed.

An operator who wants a proxy in front can set one up by hand. mcctl does not test these steps:

1. Run the proxy as its own container, on the game network `mcctl_game` or on a network it can reach the game servers through. Nothing in mcctl creates such a network for the proxy.
2. Point the proxy at each game server by its container name.
3. Point the router at the proxy instead of at the servers: give the proxy's container the `mc-router.host` label that the player-facing name uses, and remove that label from the game server. `mcctl create` and `mcctl delete` do not know about this, and a re-create of the server writes the label back from its folder.
4. Tell mc-router to re-read its routes: `docker compose -p mcctl-stack -f templates/stack.compose.yml kill -s HUP mc-router`. `mcctl up` does not do this.

The egress guard was written for the router's path. Its allow rule inside the game subnet is from the router's address to the game subnet. A proxy at another address falls under the drop rule for the private ranges, and the default `MCCTL_GAME_SUBNET` lies inside 172.16.0.0/12. Test the proxy-to-server path before you rely on it. The guard rebuilds its chain at every start, so a change made by hand in it does not last.

The per-source limits on port 25565 (`MCCTL_CONN_LIMIT`, `MCCTL_RATE`) apply at the router, the first hop. They count each player's address, not the proxy's. The proxy's connections to the game servers do not use port 25565 and are not limited by them.

Nothing here is tested by mcctl. If you use a proxy, you own its setup, its updates, and its player data.

[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service
PartOf=docker.service
# No start-rate limit: after a reboot Wings may start before the Panel container and the tunnel are up;
# it must keep retrying instead of giving up (upstream's unit allows 30 starts in 180 s).
StartLimitIntervalSec=0

[Service]
User=root
WorkingDirectory=@ETC_DIR@
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=@WINGS_BIN@
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target

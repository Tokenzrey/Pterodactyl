[Unit]
Description=Block game containers from the host, the LAN and the cloud metadata service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
ExecStart=@PTERO_ROOT@/ptero firewall egress apply --quiet

[Install]
WantedBy=multi-user.target

[Unit]
Description=Sync Minecraft server hostnames from the Panel into mc-router
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=@PTERO_ROOT@
ExecStart=@PTERO_ROOT@/ptero games sync --quiet
# the table is only rewritten when it changed, and left untouched if the Panel cannot be reached

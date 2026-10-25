#!/usr/bin/env bash
# Run one mcctl command on a VPS, in the code folder there, and print its output and exit status here.
#
#   bash tools/vps-mcctl.sh USER@HOST [IDENTITY_FILE] [REMOTE_DIR] COMMAND [ARGS...]
#   bash tools/vps-mcctl.sh deploy@203.0.113.7 ~/.ssh/id_ed25519_vps mcctl status deceased
#   bash tools/vps-mcctl.sh deploy@203.0.113.7 ~/.ssh/id_ed25519_vps mcctl edit deceased --memory 7G --yes
#
# The folder is the account's own home (from the password database), so a login whose $HOME is wrong still reaches the right code.
# Every argument is passed as one word; nothing is run through a shell on this side. Pass --yes yourself: without it, a command that
# needs confirmation refuses when there is no terminal, and changes nothing.
set -euo pipefail

target=${1:?usage: bash tools/vps-mcctl.sh USER@HOST [IDENTITY_FILE] [REMOTE_DIR] COMMAND [ARGS...]}
key=${2:-}
remote=${3:?REMOTE_DIR is missing (for example mcctl)}
shift 3 || true
case $remote in
    ''|*/*|*..*) echo "REMOTE_DIR must be one plain folder name under the home directory, for example mcctl" >&2; exit 2 ;;
esac
(($#)) || { echo "COMMAND is missing, for example: status deceased" >&2; exit 2; }

ssh_cmd=(ssh)
[[ -n $key ]] && ssh_cmd+=(-i "$key")

# each argument quoted for the remote shell, so that it arrives as the same single word
args_q=""
for a in "$@"; do args_q+=" $(printf '%q' "$a")"; done

remote_home=$("${ssh_cmd[@]}" "$target" 'getent passwd "$(id -un)" | cut -d: -f6')
case $remote_home in
    /*) ;;
    *) echo "cannot read the home folder of $target (got '$remote_home')" >&2; exit 1 ;;
esac
dest_q=$(printf '%q' "$remote_home/$remote")

echo "== on $target in $remote_home/$remote: mcctl$args_q" >&2
"${ssh_cmd[@]}" "$target" "cd $dest_q && ./mcctl$args_q"

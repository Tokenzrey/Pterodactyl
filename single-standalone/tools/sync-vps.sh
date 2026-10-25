#!/usr/bin/env bash
# Copy this checkout's code to a VPS, then compare the code on both sides by checksum.
#
#   bash tools/sync-vps.sh USER@HOST [IDENTITY_FILE] [REMOTE_DIR]
#   bash tools/sync-vps.sh deploy@203.0.113.7 ~/.ssh/id_ed25519_vps mcctl
#
# Only code is sent: mcctl, lib/, templates/, tests/, docs/ and config/mcctl.env.example. The VPS keeps its own config/mcctl.env,
# secrets/, servers/, trash/, backups/ and the generated SFTP files, which are never sent. Files removed here are NOT removed there:
# delete them on the VPS by hand if they matter. Run it from WSL or Git Bash, in any checkout of this repository.
set -euo pipefail

target=${1:?usage: bash tools/sync-vps.sh USER@HOST [IDENTITY_FILE] [REMOTE_DIR]}
key=${2:-}
remote=${3:-mcctl}
case $remote in
    ''|*/*|*..*) echo "REMOTE_DIR must be one plain folder name under the home directory, for example mcctl" >&2; exit 2 ;;
esac

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ssh_cmd=(ssh)
[[ -n $key ]] && ssh_cmd+=(-i "$key")
code_paths=(mcctl lib templates tests docs config/mcctl.env.example)

# The folder is the account's own home from the password database, not $HOME: a login can carry a $HOME that is not that account's.
remote_home=$("${ssh_cmd[@]}" "$target" 'getent passwd "$(id -un)" | cut -d: -f6')
case $remote_home in
    /*) ;;
    *) echo "cannot read the home folder of $target (got '$remote_home')" >&2; exit 1 ;;
esac
dest=$remote_home/$remote
dest_q=$(printf '%q' "$dest")

echo "== sending the code to $target:$dest"
tar -C "$here" \
    --exclude=./config/mcctl.env --exclude=./secrets --exclude=./servers --exclude=./trash --exclude=./backups \
    --exclude=./sftp-keys --exclude=./sftp-users.conf --exclude=./sftp.compose.yml --exclude=./.git \
    -cf - . \
    | "${ssh_cmd[@]}" "$target" "mkdir -p $dest_q && tar -C $dest_q -xf - && chmod +x $dest_q/mcctl"

# One checksum over every code file, computed the same way on both sides (sorted in the C locale, paths relative to the code root).
sum_cmd='find '"${code_paths[*]}"' -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum'
local_sum=$(cd "$here" && eval "$sum_cmd")
remote_sum=$("${ssh_cmd[@]}" "$target" "cd $dest_q && $sum_cmd")

echo "== checksum here:   $local_sum"
echo "== checksum there:  $remote_sum"
if [[ $local_sum == "$remote_sum" ]]; then
    echo "== in sync. On the VPS, run './mcctl up' (or the command that matches the change) to apply it."
else
    echo "== NOT in sync: the copy on the VPS differs. Run this script again; if it still differs, compare the files by hand." >&2
    exit 1
fi

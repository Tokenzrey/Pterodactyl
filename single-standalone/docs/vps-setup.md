# VPS setup

The whole path from a fresh Ubuntu VPS to a running Minecraft server reachable by name, with the firewall on and SSH hardened. The
commands are shown as they are typed. `203.0.113.7` is an example public IPv4 (use your VPS's address) and `mc.example.com` is an
example name (use a name inside your Cloudflare zone). Read [prerequisites](prerequisites.md) first for the requirements.

Run the steps in order. Steps marked **Check** must print what is described before you go on.

**Keep a console open** (the provider's VNC or web console) until step 13 is verified. A wrong SSH or firewall setting can lock you out,
and the console is then the only way back in.

## What you need

- A VPS with Ubuntu 22.04 or 24.04 (mcctl is tested only there), a public IPv4 address, and root access on first login.
- A domain whose DNS is on Cloudflare, with the zone **Active**.
- An SSH key pair on the machine you connect from (step 2).
- A Cloudflare API token limited to that one zone (step 10).

## 1. Log in and check the system

```bash
ssh root@203.0.113.7
cat /etc/os-release | head -3        # Ubuntu 22.04 or 24.04
uname -r
```

**Check:** the release is 22.04 or 24.04. Other distributions need changes that mcctl does not make.

## 2. Create an admin user and an SSH key

Daily work runs as a normal user, `deploy`, which can use `sudo`. Root is not used over SSH (step 4).

```bash
adduser deploy                      # asks for a password: make it strong
usermod -aG sudo deploy
```

On your own machine, make a key pair once per device. The private key stays on the machine; only the `.pub` file is copied:

```bash
ssh-keygen -t ed25519 -C "laptop-name" -f ~/.ssh/id_ed25519_vps
```

Copy the public key to the VPS (you can still log in with a password at this point):

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_vps.pub deploy@203.0.113.7
```

**Check** in a second terminal, before you close the first one:

```bash
ssh -i ~/.ssh/id_ed25519_vps deploy@203.0.113.7 'echo login-ok'
```

It must print `login-ok` with no password prompt.

Keys are per environment. On Windows, Git Bash's `~` is `C:\Users\<you>`, and WSL has its own home directory. A key made in one is not
visible in the other. To use a Windows key in WSL:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp /mnt/c/Users/<you>/.ssh/id_ed25519_vps ~/.ssh/ && chmod 600 ~/.ssh/id_ed25519_vps
```

## 3. Packages and updates

```bash
sudo apt update && sudo apt -y upgrade
sudo apt install -y jq curl ufw tar iproute2 dnsutils fail2ban unattended-upgrades
sudo systemctl enable --now fail2ban
```

What each package is for: `jq` and `curl` for mcctl's Cloudflare calls and `doctor`; `ufw` is the firewall mcctl applies; `tar` for
archives; `iproute2` provides `ss`; `dnsutils` provides `dig` for checks; `fail2ban` bans addresses after repeated failed SSH logins;
`unattended-upgrades` installs security updates by itself.

**Check:** `sudo fail2ban-client status sshd` shows the `sshd` jail running.

## 4. Harden SSH: key login only, no root over SSH

Ubuntu reads the files in `/etc/ssh/sshd_config.d/` in alphabetical order, and the **first** value of a setting wins. Cloud images often
ship `50-cloud-init.conf` with `PasswordAuthentication yes`. A file named `99-hardening.conf` is read after it, so its setting is ignored.
Name the file `00-hardening.conf`, so that it is read first.

```bash
sudo tee /etc/ssh/sshd_config.d/00-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
EOF
sudo sshd -t && sudo systemctl reload ssh
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|maxauthtries) '
```

`sshd -T` prints the **effective** values, which are the ones that count.

**Check:** the last command prints `permitrootlogin no`, `passwordauthentication no`, `pubkeyauthentication yes`, `maxauthtries 3`. If it still
prints `passwordauthentication yes`, find the file that sets it:

```bash
sudo grep -ri 'passwordauthentication' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
```

Then open a **new** terminal and log in with the key (step 2) before you close the old session.

## 5. Root and deploy: who logs in and how

| You want | How |
|---|---|
| Log in over SSH | `ssh -i ~/.ssh/id_ed25519_vps deploy@203.0.113.7` |
| Run one command as root | `sudo <command>` (asks for the password of `deploy`) |
| A root shell | `sudo -i` (asks for the password of `deploy`) |
| Log in over SSH as root | Not possible: `PermitRootLogin no` |
| Log in as root without SSH | The provider's console (VNC), with the root password |

Root's password is only for the console. Keep it strong and stored safely.

**Add a new device to `deploy`.** On the new device, make a key (step 2). Then, either from a device that already logs in:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_new.pub deploy@203.0.113.7
```

or, logged in as `deploy` on the VPS, paste the public key by hand:

```bash
echo 'ssh-ed25519 AAAA...the-public-key... laptop-baru' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Test the new device in a new session. **Remove a device** by deleting its line from `~/.ssh/authorized_keys`. Give each device its own key,
so one line can be removed without affecting the others.

## 6. Install Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker deploy
sudo systemctl enable --now docker
```

The script installs Docker Engine and the Compose plugin from Docker's own repository. To install by hand instead, follow Docker's
documentation for Ubuntu. Membership of the `docker` group is equal to root access, so add only users you trust.

Log out and back in, so that the new group applies to your session, then:

```bash
docker version
docker compose version
docker ps                    # must work without sudo
```

## 7. Kernel modules for the router

The router limits connections per source with netfilter modules. Load them and check:

```bash
sudo modprobe xt_connlimit xt_hashlimit xt_conntrack
lsmod | grep -E 'xt_(connlimit|hashlimit|conntrack)'
modinfo xt_hashlimit | head -2
sudo iptables -m hashlimit -h >/dev/null 2>&1 && echo "hashlimit OK"
```

**Check:** `modinfo` finds `xt_hashlimit.ko` and the last line prints `hashlimit OK`. A module that is not built in is loaded on demand when
iptables first uses it, so it can be missing from `lsmod` until then. mcctl's preflight accepts a module that is loadable.

## 8. Copy mcctl to the VPS

Copy the **code**, never your config, secrets, data or the generated SFTP files. Those are made per host. From WSL, where `~/mcctl`
holds the code:

```bash
tar -C ~/mcctl --exclude=./config/mcctl.env --exclude=./secrets --exclude=./servers \
    --exclude=./trash --exclude=./backups --exclude=./sftp-keys --exclude=./sftp-users.conf \
    --exclude=./sftp.compose.yml -cf - . | ssh -i ~/.ssh/id_ed25519_vps deploy@203.0.113.7 'mkdir -p ~/mcctl && tar -C ~/mcctl -xf -'
```

On the VPS:

```bash
cd ~/mcctl
chmod +x mcctl
cp config/mcctl.env.example config/mcctl.env
./mcctl init                 # creates secrets/ and servers/ (mode 700)
```

## 9. Configure mcctl

```bash
nano config/mcctl.env
chmod 600 config/mcctl.env
```

| Key | Value for this setup |
|---|---|
| `MCCTL_DNS` | `on`: one DNS record per server in Cloudflare |
| `MCCTL_DOMAIN` | `mc.example.com`: a name inside your zone, not a name a panel or website uses |
| `MCCTL_PUBLIC_IPV4` | `203.0.113.7`: the VPS's public IPv4 |
| `MCCTL_CF_ZONE_ID` | The Zone ID of the zone (Cloudflare dashboard, Overview, right-hand column) |
| `MCCTL_SSH_PORTS` | Only if SSH is not on port 22: a comma-separated list, for example `2222` |

Leave the other keys as they are in the example. Do not put tokens or passwords in this file: those go in `secrets/`.

## 10. Cloudflare

1. The domain is **Active** on Cloudflare (the nameservers at your registrar point to Cloudflare).
2. Create the API token: **My Profile → API Tokens → Create Token → Edit zone DNS**. Under **Zone Resources**, choose **Include → Specific
   zone** and pick your zone. Leave the **TTL / Start date / End date** fields empty. A token with a start date in the future is refused
   with `This API Token can not be used before ...`, and every call fails with `10000 Authentication error`. Do not use the Global API Key.
3. Store the token on the VPS without it reaching the shell history:

   ```bash
   cd ~/mcctl
   (umask 077; read -rs -p 'Cloudflare API token: ' t; printf '%s\n' "$t" > secrets/cloudflare_token)
   chmod 600 secrets/cloudflare_token
   ```

   `read -rs` does not echo the token. Paste it and press Enter.

4. **Check** the token:

   ```bash
   curl -s -H "Authorization: Bearer $(cat secrets/cloudflare_token)" \
     https://api.cloudflare.com/client/v4/user/tokens/verify
   ```

   The answer must contain `"status":"active"`, `"success":true` and `"messages":[]`. A message `can not be used before` means the start
   date is set: create a new token. Do not paste the answer anywhere public; it names your token.

5. **Check** the zone ID matches your domain:

   ```bash
   curl -s -H "Authorization: Bearer $(cat secrets/cloudflare_token)" \
     https://api.cloudflare.com/client/v4/zones/YOUR_ZONE_ID | grep -o '"name":"[^"]*"' | head -1
   ```

   It prints the zone's apex name, for example `"name":"example.com"`.

6. **Check** the names you will use are free. In the DNS tab, `mc.example.com` and `s1.mc.example.com` must not exist. Records for a
   panel, a website or a tunnel (for example `panel.example.com`) do not conflict with them.

How the records work: `create` adds an `A` record `<name>.<MCCTL_DOMAIN>` pointing at `MCCTL_PUBLIC_IPV4`, with the **DNS only** (grey
cloud) setting, and `delete` removes it. The router picks the server from the name the client sends, so each server needs its own
record and no wildcard is needed. Do not turn on the proxy (orange cloud) for a game record: Minecraft traffic does not pass through
Cloudflare's proxy.

## 11. Secrets and who can read them

Files in `secrets/`, and who needs to read each one:

| File | Read by | Owner and mode |
|---|---|---|
| `cloudflare_token` | mcctl, running as `deploy` on the host | `deploy`, 600 |
| `rcon-NAME` (one per server) | the server container, which runs as UID 1000 | `1000:<deploy group>`, 600 (mcctl sets the owner) |
| `curseforge_api_key` (only for CurseForge modpacks) | the server container, UID 1000 | `1000:<deploy group>`, 640 (you set it once) |

The server container runs as UID 1000. A file it must read has to be owned by UID 1000. mcctl gives `rcon-NAME` to UID 1000 itself
when it writes it (`create`, `rotate-rcon`, `import`), through a helper container that holds the single capability `CHOWN`; the host
user needs no `sudo` for that. Without it the container restarts with `cat: /run/secrets/rcon_password: Permission denied`.

The CurseForge key is your file, so mcctl does not change it: it checks the owner before a CurseForge pack is created and says what to
run if the owner is wrong. Once, as root, make it readable by the server and by `deploy`:

```bash
sudo chown 1000:$(id -g deploy) secrets/curseforge_api_key && sudo chmod 640 secrets/curseforge_api_key
```

Do not change `cloudflare_token` to 1000: mcctl on the host reads it as `deploy`.

## 12. Checks before the first server

```bash
./mcctl doctor
bash tests/acceptance-preflight.sh; echo "exit $?"
```

**Check:** `doctor` prints `[ok]` for every line and a `DNS on` line. The preflight exits with `0`. With DNS on it requires the three
values from step 9 and the token from step 10. A missing CurseForge key is only a note, because it is needed only for CurseForge modpacks.

## 13. Firewall

mcctl's firewall uses `ufw` and `iptables`, so run it as root through `sudo`. The first `apply` changes which ports the host accepts. Keep
the console open.

```bash
sudo ./mcctl firewall plan
sudo ./mcctl firewall apply          # prints the rules, then asks y/N
sudo ufw status verbose
```

`plan` shows the rules mcctl adds (`22/tcp` for SSH and `25565/tcp` for the router) and the public listeners that the policy would
block. `plan` does not read rules you added yourself, so a port that is already allowed by hand can still appear under
`WILL BE BLOCKED`. Compare it with `ufw status`.

`apply` makes ufw the host firewall with `default deny incoming`. If ufw was **already active**, there is no dead-man switch, and the
rules take effect at once. If ufw was **inactive**, a timer switches it off again after `MCCTL_FIREWALL_ROLLBACK_SECONDS` (300 by
default). In that case, from a **new** SSH session, run `sudo ./mcctl firewall confirm` to keep it on.

**Check** with `sudo ufw status verbose`: `22/tcp` and `25565/tcp` must be `ALLOW IN` (with their `(v6)` lines). Rules you added yourself,
such as `80/tcp` or `443/tcp`, are left alone.

If your VPS provider has a firewall panel of its own, allow TCP `22` and `25565` there too.

## 14. Start the router and the first server

```bash
./mcctl up
ss -ltnp | grep 25565                 # 0.0.0.0:25565 (DNS on)
sudo iptables -S DOCKER-USER | head   # the MCCTL-EGRESS and MCCTL-INGRESS jumps are present
./mcctl create s1 --type PAPER --accept-eula
./mcctl start s1
docker ps --filter name=mc- --format '{{.Names}} {{.Status}}'
docker logs --tail 3 mc-s1            # wait for a line with "Done"
dig +short s1.mc.example.com          # 203.0.113.7; a new record can take a few minutes
```

**Check:** `mc-s1` is `Up`, `mc-s1-backup` is `Up`, the router is `Up` and not `Restarting`. Then join from a Minecraft client outside the
VPS with `s1.mc.example.com`, with no port.

`create` adds the record, the server folder and the SFTP user, and prints the name to join. Use `./mcctl list` and `./mcctl status s1` to
check the server later.

## 15. Check that it is secure

```bash
ss -ltnp                                  # public: 22 (SSH) and 25565 (router); 80 and 443 only if you run a web server
sudo ufw status verbose
sudo fail2ban-client status sshd
./mcctl firewall plan                     # every entry under WILL BE BLOCKED must be one you want closed
sudo grep -ri 'passwordauthentication' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/   # only 00-hardening and the cloud-init file
```

Turn off the provider's console (VNC) access when you no longer need it. Keep the Cloudflare token limited to one zone.

## 16. Files of a server over SFTP

Follow [Connecting step by step](reference.md#connecting-step-by-step) in the SFTP section of the command reference. The SFTP port is
on the host's loopback only, so connect through an SSH tunnel.

## 17. Backups of what matters

- `config/mcctl.env` and `secrets/`: keep an encrypted copy off the VPS. They hold the Cloudflare token.
- `servers/NAME/backups/` and `trash/`: copy them off the VPS regularly. They hold the worlds.
- The Docker volume `mcctl-sftp-hostkeys` holds the SFTP server's host keys. If it is lost, clients see a changed host key and must
  forget the old one.

## Updating mcctl on the VPS

Send the new code from the checkout on your machine with `tools/sync-vps.sh`. It copies the code only (never `config/mcctl.env`,
`secrets/`, `servers/`, `trash/`, `backups/` or the generated SFTP files), then compares the checksum of the code on both sides and says
whether they are in sync:

```bash
bash tools/sync-vps.sh deploy@203.0.113.7 ~/.ssh/id_ed25519_vps mcctl
```

Run it from WSL or Git Bash, in the checkout of this repository. Then, on the VPS:

```bash
cd ~/mcctl
./mcctl up                          # applies the code; containers are recreated only when their configuration changed
./mcctl doctor
bash tests/acceptance-preflight.sh; echo "exit $?"
```

A file removed from the checkout stays on the VPS: delete it there by hand if it matters. Read the changes of the release before you run
`up`, because a Java or image change recreates the containers of every server it applies to.

## When something goes wrong

Look up the message in [troubleshooting](troubleshooting.md). For SSH, tunnel and router problems that mcctl does not print, the
section "Problems outside mcctl's messages" there lists the usual causes and the checks.

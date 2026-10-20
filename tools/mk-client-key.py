#!/usr/bin/env python3
"""Create the root-admin CLIENT API key (ptlc_...) that mc-deploy.py needs, without the web UI.

  python3 tools/mk-client-key.py            # owner = Panel user id 1 (the first admin)

Normal route: Panel -> Account -> API Credentials -> Create, then paste the key into
~/pterodactyl-stack/.panel-api.env as PANEL_CLIENT_KEY=. Use this script only if that page is unavailable.
It asks the Panel's own key service for the key, writes it straight into .panel-api.env (chmod 600)
and never prints it. It replaces any earlier key with the memo 'ptero-deploy' for that user.
"""
import os, re, subprocess, sys, urllib.error, urllib.request

STACK = os.path.expanduser("~/pterodactyl-stack")
ENVF = os.path.join(STACK, ".panel-api.env")


def sh(cmd, check=True):
    r = subprocess.run(cmd, shell=True, cwd=STACK, capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit(f"command failed: {cmd}\n{r.stderr[-400:]}")
    return r.stdout


cfg = dict(l.split("=", 1) for l in open(ENVF).read().splitlines() if "=" in l and not l.startswith("#"))
url = (cfg.get("PANEL_URL") or sys.exit("PANEL_URL is missing in .panel-api.env")).rstrip("/")

# 1) the class the Client API controller uses to mint account keys (its name differs between betas)
use_line = sh("docker compose exec -T panel sh -c 'grep -h \"use .*CreatesAccountApiKeys;\" "
              "/app/app/Http/Controllers/Api/Client/ApiKeyController.php'").strip()
m = re.search(r"use\s+([\w\\]+\\CreatesAccountApiKeys);", use_line)
if not m:
    sys.exit(f"could not find CreatesAccountApiKeys in ApiKeyController (got: {use_line!r})")
fqcn = m.group(1).replace("\\", "\\\\")

# 2) PHP via tinker: key for user 1; the secret goes to a container temp file, never to stdout
php = f"""<?php
$u = \\Pterodactyl\\Models\\User::find(1);
\\Pterodactyl\\Models\\ApiKey::where('memo', 'ptero-deploy')->where('user_id', 1)->delete();
$t = app('{fqcn}')->create($u, 'ptero-deploy', null);
file_put_contents('/tmp/newkey', $t->accessToken->identifier . $t->plainTextToken);  // identifier + secret = the full key
echo "key created for " . $u->email . PHP_EOL;
"""
open("/tmp/mkkey.php", "w").write(php)
sh("docker cp /tmp/mkkey.php pterodactyl-panel-1:/tmp/mkkey.php")
print(sh("docker compose exec -T panel php artisan tinker --execute=\"require '/tmp/mkkey.php';\"", check=False).strip()[-300:])
key = sh("docker compose exec -T panel cat /tmp/newkey", check=False).strip()
sh("docker compose exec -T panel rm -f /tmp/newkey /tmp/mkkey.php", check=False)
os.remove("/tmp/mkkey.php")
if not re.fullmatch(r"ptlc_[A-Za-z0-9]{20,}", key or ""):
    sys.exit("the created key does not look like a client key (ptlc_...). Nothing was saved.")

# 3) save into .panel-api.env
lines, out, done = open(ENVF).read().splitlines(), [], False
for ln in lines:
    done |= ln.startswith("PANEL_CLIENT_KEY=")
    out.append(f"PANEL_CLIENT_KEY={key}" if ln.startswith("PANEL_CLIENT_KEY=") else ln)
if not done:
    out.append(f"PANEL_CLIENT_KEY={key}")
open(ENVF, "w").write("\n".join(out) + "\n")
os.chmod(ENVF, 0o600)
print(f"PANEL_CLIENT_KEY saved (length {len(key)}), file mode 600")

# 4) prove it on the Client API (read-only). The User-Agent is required: Cloudflare 403s the default Python one.
req = urllib.request.Request(url + "/api/client/account", headers={
    "Authorization": f"Bearer {key}", "Accept": "application/json",
    "User-Agent": "ptero-ops/1.0 (" + cfg.get("ADMIN_EMAIL", "admin@example.com") + ")"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        print("client API: OK (HTTP", r.status, ")")
except urllib.error.HTTPError as e:
    print("client API: HTTP", e.code, e.read(200).decode(errors="replace"))

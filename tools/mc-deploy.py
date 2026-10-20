#!/usr/bin/env python3
"""End to end: modpack (CurseForge or Modrinth) -> Panel server -> install -> pack -> start.

  mc-deploy.py --source curseforge --slug <slug> --mc 1.20.1 --loader forge --name <server-name> --port 25565 [--yes]
  mc-deploy.py --source modrinth   --slug <slug> --mc 1.21.1 --loader fabric --name <server-name> --port 25566 [--yes]

Default is a dry run. It downloads the pack, reads its versions from the pack itself, checks the node's
memory and the port, and prints the exact request it would send. Nothing is created until --yes.

Config (chmod 600): ~/pterodactyl-stack/.panel-api.env
  PANEL_URL=https://panel.example.com
  PANEL_KEY=ptla_...                 # Application API key: create server, read nodes/eggs/users
  PANEL_CLIENT_KEY=ptlc_...          # root-admin CLIENT key (Account -> API Credentials): power signal only
  ADMIN_EMAIL=you@example.com        # Panel user that will own the new server
  PANEL_NODE_ID=1                    # optional
CurseForge also needs CURSEFORGE_API_KEY (see modpack.py).
The server's EULA is not accepted for you: the first start stops at eula=false (see the guide, Phase 6).
"""
import argparse, json, os, re, shutil, subprocess, sys, time, urllib.error, urllib.parse, urllib.request, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import modpack as mp  # reuses CurseForge lookup, verified downloads, and the volume apply step

ENVFILE = os.path.expanduser("~/pterodactyl-stack/.panel-api.env")
MODPACK = os.path.join(HERE, "modpack.py")
UA = "ptero-ops/1.0 (" + os.environ.get("ADMIN_EMAIL", "admin@example.com") + ")"
EGG_NAME = {"forge": "Forge Minecraft", "fabric": "Fabric"}


# ---------- config and Panel API ----------

def load_cfg():
    cfg = {}
    if os.path.exists(ENVFILE):
        for line in open(ENVFILE):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    for k, v in os.environ.items():
        if k.startswith(("PANEL_", "ADMIN_EMAIL")):
            cfg[k] = v
    return cfg


class Panel:
    """Application API calls use `key`. Client API calls (power, resources) use `client_key`.
    An Application key (ptla_) cannot start servers, so the two can differ."""

    def __init__(self, url, key, client_key=None):
        self.url, self.key, self.ckey = url.rstrip("/"), key, client_key or key

    def call(self, method, path, body=None, client=False):
        data = json.dumps(body).encode() if body is not None else None
        token = self.ckey if client else self.key
        req = urllib.request.Request(self.url + path, data=data, method=method, headers={
            "Authorization": f"Bearer {token}", "Accept": "application/json",
            "Content-Type": "application/json", "User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            sys.exit(f"Panel {method} {path} failed: HTTP {e.code} {e.read(400).decode(errors='replace')}")
        except urllib.error.URLError as e:
            sys.exit(f"cannot reach the Panel at {self.url}: {e.reason}")

    def all(self, path):
        out, page = [], 1
        while True:
            sep = "&" if "?" in path else "?"
            r = self.call("GET", f"{path}{sep}page={page}&per_page=100")
            out += r["data"]
            pg = (r.get("meta") or {}).get("pagination") or {}
            if not pg or page >= pg.get("total_pages", 1):
                return out
            page += 1


# ---------- pack resolution and version reading ----------

FORGE_RE = r"(\d+\.\d+(?:\.\d+)?)-([\d.]+)"


def inspect_zip(path):
    """Server pack zip. Versions are read in this order, most reliable first:
    1) the pack's own launcher (run.sh / run.bat) names the exact Forge build it starts,
    2) libraries shipped inside the pack, 3) the installer jar name."""
    z = zipfile.ZipFile(path)
    names = z.namelist()
    mc = forge = fabric = None
    for n in names:
        if re.search(r"(^|/)run\.(sh|bat)$", n):
            m = re.search(r"libraries/net/minecraftforge/forge/" + FORGE_RE + r"/unix_args", z.read(n).decode("utf-8", "replace"))
            if m:
                mc, forge = m.group(1), m.group(2)
                break
    for n in names:
        if forge is None:
            m = re.search(r"libraries/net/minecraftforge/forge/" + FORGE_RE + r"/", n)
            if m:
                mc, forge = m.group(1), m.group(2)
        if fabric is None:
            m = re.search(r"libraries/net/fabricmc/fabric-loader/([\d.]+)/", n)
            if m:
                fabric = m.group(1)
        if mc is None:
            m = re.search(r"libraries/net/minecraft/server/(\d+\.\d+(?:\.\d+)?)/", n)
            if m:
                mc = m.group(1)
    for n in names:
        if forge is None:
            m = re.search(r"(?:^|/)forge-" + FORGE_RE + r"(?:-installer)?\.jar$", n)
            if m:
                mc, forge = m.group(1), m.group(2)
    mods = sum(1 for n in names if re.search(r"(^|/)mods/[^/]+\.jar$", n))
    loader = "forge" if forge else "fabric" if fabric else None
    return {"kind": "zip", "mc": mc, "loader": loader, "forge": forge, "fabric": fabric, "mods": mods}


def inspect_manifest(path):
    """CurseForge client pack: versions come from manifest.json."""
    man = json.loads(zipfile.ZipFile(path).read("manifest.json"))
    mc = man["minecraft"]["version"]
    forge = fabric = None
    for ml in man["minecraft"].get("modLoaders", []):
        if not ml.get("primary", True):
            continue
        lid = ml.get("id", "")
        if lid.startswith("forge-"):
            forge = lid[len("forge-"):]
        elif lid.startswith("fabric-"):
            fabric = lid[len("fabric-"):]
    loader = "forge" if forge else "fabric" if fabric else None
    return {"kind": "cf-manifest", "mc": mc, "loader": loader, "forge": forge, "fabric": fabric,
            "mods": len(man.get("files", []))}


def inspect_mrpack(path):
    idx = json.loads(zipfile.ZipFile(path).read("modrinth.index.json"))
    d = idx.get("dependencies", {})
    loader = "forge" if "forge" in d else "fabric" if "fabric-loader" in d else None
    mods = sum(1 for x in idx["files"] if x.get("env", {}).get("server") != "unsupported")
    return {"kind": "mrpack", "mc": d.get("minecraft"), "loader": loader, "forge": d.get("forge"),
            "fabric": d.get("fabric-loader"), "mods": mods}


def resolve(a, staging):
    if a.pack_file:
        info = inspect_manifest(a.pack_file) if "manifest.json" in zipfile.ZipFile(a.pack_file).namelist() \
            else inspect_zip(a.pack_file)
        info.update(path=a.pack_file, label=os.path.basename(a.pack_file))
        return info
    if a.source == "curseforge":
        mod = mp.cf_find_modpack(a.slug)
        f = mp.cf_pick_file(mod, a.mc, a.loader, a.file_id)
        spid = f.get("serverPackFileId")
        if spid and not a.client:
            sp = mp.cf(f"/v1/mods/{mod['id']}/files/{spid}")
            url = mp.cf_download_url(mod["id"], sp)
            if not url:
                sys.exit("the server pack has no download URL (author disabled it). "
                         "Download it in the browser and re-run with --pack-file <zip>.")
            path = os.path.join(staging, sp["fileName"])
            mp.fetch(url, path, "sha1", mp.cf_sha1(sp))
            info = inspect_zip(path)
            label = sp["fileName"]
        else:
            url = mp.cf_download_url(mod["id"], f)
            if not url:
                sys.exit("the client pack has no download URL. Download it in the browser and re-run "
                         "with --pack-file <zip>.")
            path = os.path.join(staging, f["fileName"])
            mp.fetch(url, path, "sha1", mp.cf_sha1(f))
            info = inspect_manifest(path)
            label = f["fileName"]
        info.update(path=path, label=f"{mod.get('name') or a.slug} / {label}")
        return info
    # modrinth
    q = urllib.parse.urlencode({"loaders": json.dumps([a.loader]), "game_versions": json.dumps([a.mc])})
    versions = json.loads(mp.http_get(f"https://api.modrinth.com/v2/project/{a.slug}/version?{q}"))
    if a.version_id:
        versions = [v for v in versions if v["id"] == a.version_id]
    if not versions:
        sys.exit(f"no {a.loader} {a.mc} version of modpack '{a.slug}' on Modrinth")
    v = next((x for x in versions if x["version_type"] == "release"), versions[0])
    f = next((x for x in v["files"] if x.get("primary")), v["files"][0])
    path = os.path.join(staging, f["filename"])
    mp.fetch(f["url"], path, "sha512", f["hashes"].get("sha512"))
    info = inspect_mrpack(path)
    info.update(path=path, label=f"{v['name']} ({v['version_number']})")
    return info


# ---------- Panel objects ----------

def egg_for(P, loader):
    want = EGG_NAME[loader]
    e = next((x for x in P.all("/api/application/eggs") if x["attributes"]["name"] == want), None)
    if not e:
        sys.exit(f"egg '{want}' not found in the Panel")
    eid = e["attributes"]["id"]
    full = P.call("GET", f"/api/application/eggs/{eid}?include=variables")
    attrs = full["attributes"]
    rel = full.get("relationships") or attrs.get("relationships") or {}  # the Panel nests it in attributes
    return eid, attrs, rel["variables"]["data"]


def startup_for(loader, template):
    """Keep the egg's launch logic, but size the heap to 80% of the container (not 95%)."""
    if loader == "forge":
        return template.replace("-XX:MaxRAMPercentage=95.0", "-XX:MaxRAMPercentage=80.0")
    return template.replace("-Xmx{{SERVER_MEMORY}}M", "-XX:MaxRAMPercentage=80.0")


def image_for(docker_images, java):
    for _, url in docker_images.items():
        if url.endswith(":" + java):
            return url
    sys.exit(f"the egg has no image for {java}")


def env_for(variables, values):
    env = {}
    for v in variables:
        a = v["attributes"]
        env[a["env_variable"]] = a.get("default_value") or ""
    env.update(values)
    return env


def auto_memory(mods):
    return 8192 if mods >= 200 else 6144 if mods >= 120 else 4096


def owner_id(P, email):
    u = next((x for x in P.all("/api/application/users") if x["attributes"]["email"] == email), None)
    if not u:
        sys.exit(f"no Panel user with email {email}")
    return u["attributes"]["id"]


def wait_install(P, sid, timeout=2400):
    time.sleep(5)
    t0 = time.time()
    while time.time() - t0 < timeout:
        s = P.call("GET", f"/api/application/servers/{sid}")["attributes"]
        st = s.get("status")
        if st == "install_failed":
            sys.exit("the Panel reports install_failed. Open the server's console in the Panel to see why.")
        if not st:
            return
        print(f"  install status: {st}")
        time.sleep(10)
    sys.exit("timed out waiting for the install to finish")


def check_client_access(P):
    """Fail before anything is created if the client key cannot start servers."""
    try:
        P.call("GET", "/api/client/account", client=True)
    except SystemExit as e:
        if "HTTP 4" not in str(e.code):
            raise  # Panel unreachable or other failure: report that, do not blame the key
        sys.exit("the client key is rejected by the Client API (HTTP 403 or 401). An Application key (ptla_) "
                 "cannot start servers. Create a client key (ptlc_) as a root admin: Account → API Credentials, "
                 "then put it in ~/pterodactyl-stack/.panel-api.env as PANEL_CLIENT_KEY=...")


def wait_running(uuid, timeout=1800):
    t0 = time.time()
    while time.time() - t0 < timeout:
        out = subprocess.run(["docker", "logs", "--tail", "400", uuid], capture_output=True, text=True)
        clean = re.sub(r"\x1b\[[0-9;]*m", "", (out.stdout or "") + (out.stderr or ""))
        if re.search(r"Done \(\d", clean):
            return
        if "OutOfMemoryError" in clean:
            sys.exit("the server ran out of memory. Raise the server's memory in the Panel (or pass a larger --memory).")
        if subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", uuid],
                          capture_output=True, text=True).stdout.strip() != "true" and time.time() - t0 > 90:
            sys.exit("the container is not running. Last log lines:\n" + "\n".join(clean.splitlines()[-15:]))
        time.sleep(10)
    sys.exit("timed out waiting for 'Done' in the server log")


# ---------- main flow ----------

def cmd_deploy(a):
    cfg = load_cfg()
    key = cfg.get("PANEL_KEY") or sys.exit("PANEL_KEY is missing in ~/pterodactyl-stack/.panel-api.env")
    P = Panel(cfg.get("PANEL_URL") or sys.exit("PANEL_URL is missing in ~/pterodactyl-stack/.panel-api.env"),
              key, cfg.get("PANEL_CLIENT_KEY"))
    email = cfg.get("ADMIN_EMAIL") or sys.exit("ADMIN_EMAIL is missing in .panel-api.env")
    node_id = a.node_id or int(cfg.get("PANEL_NODE_ID", "1"))
    check_client_access(P)  # before any download or create

    staging = os.path.join(mp.STAGE, "deploy-" + re.sub(r"[^A-Za-z0-9_-]", "", a.name))
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging)

    info = resolve(a, staging)
    print(f"pack: {info['label']}  kind={info['kind']}  minecraft={info['mc']}  loader={info['loader']}  mods={info['mods']}")
    if info.get("mc") and a.mc != info["mc"]:
        sys.exit(f"the pack is for Minecraft {info['mc']}, not {a.mc}")
    if info.get("loader") and a.loader != info["loader"]:
        sys.exit(f"the pack is {info['loader']}, not {a.loader}")
    forge_ver = info.get("forge") or a.forge_version
    fabric_ver = info.get("fabric") or a.loader_version
    if a.loader == "forge" and not forge_ver:
        sys.exit("cannot read the Forge version from the pack. Pass --forge-version, e.g. 47.4.10")
    if a.loader == "fabric" and not fabric_ver:
        sys.exit("cannot read the Fabric loader version from the pack. Pass --loader-version")
    mc = info["mc"] or a.mc
    java = mp.java_for(mc)
    memory = a.memory or auto_memory(info["mods"])

    servers = P.all("/api/application/servers")
    if any(s["attributes"]["name"] == a.name for s in servers):
        sys.exit(f"a server named '{a.name}' already exists")
    node = P.call("GET", f"/api/application/nodes/{node_id}")["attributes"]
    used = sum(s["attributes"]["limits"]["memory"] for s in servers if s["attributes"]["node"] == node_id)
    cap = node["memory"] * (100 + node.get("memory_overallocate", 0)) // 100
    if used + memory > cap:
        sys.exit(f"not enough node memory: already {used} MB, new server {memory} MB, node limit {cap} MB. "
                 f"Lower --memory or free a server first.")

    allocs = P.all(f"/api/application/nodes/{node_id}/allocations")
    match = [x["attributes"] for x in allocs if x["attributes"]["ip"] == "127.0.0.1"
             and x["attributes"]["port"] == a.port]
    if not match:
        if not a.create_port:
            sys.exit(f"no allocation 127.0.0.1:{a.port} on node {node_id}. Add it in the Panel or pass --create-port.")
        alloc_id = "(created at deploy time)"
    else:
        if match[0]["assigned"]:
            sys.exit(f"127.0.0.1:{a.port} is already used by another server")
        alloc_id = match[0]["id"]

    egg_id, egg, variables = egg_for(P, a.loader)
    values = {"SERVER_JARFILE": "server.jar", "MC_VERSION": mc}
    if a.loader == "forge":
        values.update(FORGE_VERSION=f"{mc}-{forge_ver}", BUILD_TYPE="recommended")
    else:
        values.update(FABRIC_VERSION="latest", LOADER_VERSION=fabric_ver)
    body = {
        "name": a.name, "user": owner_id(P, email), "egg": egg_id,
        "docker_image": image_for(egg["docker_images"], java),
        "startup": startup_for(a.loader, egg["startup"]),
        "environment": env_for(variables, values), "skip_scripts": False, "oom_disabled": False,
        "limits": {"memory": memory, "swap": 0, "disk": a.disk, "io": 500, "cpu": a.cpu, "threads": None},
        "feature_limits": {"databases": 0, "allocations": 0, "backups": 3},
        "allocation": {"default": alloc_id}, "start_on_completion": False,
    }
    print(f"plan: server '{a.name}' on node {node_id}, 127.0.0.1:{a.port} (allocation {alloc_id})")
    print(f"      memory {memory} MB (node used {used}/{cap}), disk {a.disk} MB, java {java}, egg '{egg['name']}'")
    print(f"      startup heap: MaxRAMPercentage=80 (of {memory} MB ≈ {memory * 0.8:.0f} MB)")
    print("      request body:")
    print(json.dumps(body, indent=2))

    if not a.yes:
        shutil.rmtree(staging, ignore_errors=True)
        print("\ndry run: nothing created. Re-run with --yes to create, install, copy the pack and start.")
        return

    if not match and a.create_port:
        P.call("POST", f"/api/application/nodes/{node_id}/allocations", {"ip": "127.0.0.1", "ports": [str(a.port)]})
        allocs = P.all(f"/api/application/nodes/{node_id}/allocations")
        match = [x["attributes"] for x in allocs if x["attributes"]["ip"] == "127.0.0.1"
                 and x["attributes"]["port"] == a.port]
        body["allocation"]["default"] = match[0]["id"]

    created = P.call("POST", "/api/application/servers", body)["attributes"]
    sid, uuid = created["id"], created["uuid"]
    print(f"created server id={sid} uuid={uuid}. Waiting for the Panel to install it...")
    wait_install(P, sid)
    print("install finished. Copying the pack into the server...")

    if info["kind"] == "zip":
        cmd = [sys.executable, MODPACK, "zip", info["path"], uuid, "--yes"]
    elif info["kind"] == "mrpack":
        cmd = [sys.executable, MODPACK, "mrpack", info["path"], uuid, "--yes"]
    else:
        cmd = [sys.executable, MODPACK, "curseforge", a.slug or "x", mc, uuid, "--loader", a.loader,
               "--pack-file", info["path"], "--yes"] + (["--manual-dir", a.manual_dir] if a.manual_dir else [])
    subprocess.run(cmd, check=True, env=dict(os.environ, ADMIN_EMAIL=email))
    shutil.rmtree(staging, ignore_errors=True)

    print("starting the server...")
    P.call("POST", f"/api/client/servers/{uuid}/power", {"signal": "start"}, client=True)
    wait_running(uuid)
    print(f"\nDONE: '{a.name}' is running. Connect to 127.0.0.1:{a.port} from this PC, "
          f"or add the playit / SRV address for friends.")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--source", choices=["curseforge", "modrinth"], required=True)
    p.add_argument("--slug", required=True)
    p.add_argument("--mc", required=True)
    p.add_argument("--loader", choices=["forge", "fabric"], required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--port", type=int, default=25565)
    p.add_argument("--node-id", type=int)
    p.add_argument("--memory", type=int, help="MB; default picked from the mod count")
    p.add_argument("--disk", type=int, default=20480)
    p.add_argument("--cpu", type=int, default=400)
    p.add_argument("--file-id", type=int)
    p.add_argument("--version-id")
    p.add_argument("--client", action="store_true", help="use the client pack even if a server pack exists")
    p.add_argument("--pack-file", help="a pack you downloaded yourself (server or client zip)")
    p.add_argument("--manual-dir", help="folder with mods that CurseForge says must be downloaded by hand")
    p.add_argument("--forge-version", help="only if the pack does not reveal it")
    p.add_argument("--loader-version", help="only if the pack does not reveal it")
    p.add_argument("--create-port", action="store_true", help="create the 127.0.0.1 allocation if missing")
    p.add_argument("--yes", action="store_true")
    a = p.parse_args()
    cmd_deploy(a)


if __name__ == "__main__":
    main()

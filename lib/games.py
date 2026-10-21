#!/usr/bin/env python3
"""Game-server automation against the Panel's Application API (standard library only).

  games.py sync    [--quiet]   derive mc-router's hostname table from the Panel's Minecraft servers; write it if it changed
  games.py list                show server -> hostname -> backend
  games.py create  ...         plan (default) or --apply: create a modpack server through the API and wire its hostname

Environment (set by ./ptero; the key is read from secrets/panel_api_key and never appears on a command line):
  PANEL_API_URL   http://127.0.0.1:<PANEL_BIND_PORT>     PANEL_API_KEY   ptla_...
  GAMES_DOMAIN    mc.example.com   (servers are <name>.GAMES_DOMAIN)
  ROUTES_FILE     path of mc-router's routes.json
  GAMES_NODE_ID, GAMES_BACKEND_FIRST, GAMES_BACKEND_LAST, ADMIN_EMAIL, CURSEFORGE_API_KEY

Exit codes: 0 ok, 1 error, 2 Panel unreachable / not authorised (routes file left untouched), 3 refused (conflict).
A server is routed only when its default allocation is on 127.0.0.1: anything else would already be reachable
without going through the router, so it is reported and left out.
"""
import argparse
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
EGG_NAME = "Minecraft Modpack (CurseForge / Modrinth)"
LOOPBACK = ("127.0.0.1", "localhost")


class Fail(Exception):
    def __init__(self, msg, code=1):
        super().__init__(msg)
        self.code = code


class Panel:
    def __init__(self, url, key):
        self.url, self.key = url.rstrip("/"), key

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path, data=data, method=method, headers={
            "Authorization": f"Bearer {self.key}", "Accept": "application/json", "Content-Type": "application/json",
            "User-Agent": "ptero-games/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise Fail(f"the Panel rejected the API key (HTTP {e.code}). It needs Application API permissions Servers: Read+Write, Allocations: Read+Write, Nodes: Read, Eggs: Read, Users: Read. Create one in Admin -> Application API, then: ./ptero key set panel", 2)
            detail = e.read(300).decode(errors="replace")
            raise Fail(f"Panel {method} {path} failed: HTTP {e.code} {detail}")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            raise Fail(f"cannot reach the Panel at {self.url}: {getattr(e, 'reason', e)}", 2)

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


def rel(obj, name):
    """Relationship list; the Panel nests `relationships` inside `attributes`."""
    r = obj.get("relationships") or obj.get("attributes", {}).get("relationships") or {}
    return (r.get(name) or {}).get("data", [])


def slugify(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:40].strip("-")
    if not s:
        raise Fail(f"server name {name!r} cannot be turned into a hostname label")
    return s


def minecraft_servers(panel):
    eggs = {e["attributes"]["id"]: e["attributes"] for e in panel.all("/api/application/eggs")}
    out = []
    for s in panel.all("/api/application/servers?include=allocations"):
        a = s["attributes"]
        egg = eggs.get(a["egg"], {})
        # Identify Minecraft servers by the egg's name. The `features` list is not a reliable marker: the Panel's API can
        # return it empty for an egg that has it in the database, which silently routed nothing.
        if "minecraft" not in (egg.get("name") or "").lower():
            continue                          # not a Minecraft egg
        default = next((x["attributes"] for x in rel(s, "allocations") if x["attributes"]["id"] == a["allocation"]), None)
        out.append({"id": a["id"], "uuid": a["uuid"], "name": a["name"],
                    "suspended": bool(a.get("suspended")) or a.get("status") == "suspended", "alloc": default})
    return out


def build_routes(servers, domain):
    routes, notes, owners = {}, [], {}
    for s in servers:
        if s["suspended"]:
            notes.append(f"{s['name']}: suspended, not routed")
            continue
        if not s["alloc"] or s["alloc"]["ip"] not in LOOPBACK:
            if not s["alloc"]:
                notes.append(f"{s['name']}: its allocation is not visible -> not routed (does the API key have Allocations: Read?)")
            else:
                notes.append(f"{s['name']}: allocation is {s['alloc']['ip']}:{s['alloc']['port']}, not 127.0.0.1 -> not routed (it would be reachable directly). Use a 127.0.0.1 allocation")
            continue
        host = f"{slugify(s['name'])}.{domain}"
        if host in owners:
            raise Fail(f"servers '{owners[host]}' and '{s['name']}' would both be {host}; rename one", 3)
        owners[host] = s["name"]
        routes[host] = f"127.0.0.1:{s['alloc']['port']}"
    return routes, notes


def write_routes(path, routes):
    """Atomic write; returns True when the file content changed."""
    doc = json.dumps({"mappings": dict(sorted(routes.items()))}, indent=2) + "\n"
    try:
        with open(path) as f:
            if f.read() == doc:
                return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(doc)
    os.chmod(tmp, 0o644)   # holds only hostnames and loopback ports; the router container user must be able to read it
    os.replace(tmp, path)
    return True


def env_panel():
    url, key = os.environ.get("PANEL_API_URL"), os.environ.get("PANEL_API_KEY")
    if not url or not key:
        raise Fail("PANEL_API_URL / PANEL_API_KEY missing (./ptero key set panel)", 2)
    return Panel(url, key)


def require_domain():
    d = os.environ.get("GAMES_DOMAIN", "")
    if not d:
        raise Fail("GAMES_DOMAIN is not set in config/deploy.env")
    return d


def panel_file_exists(url, client_key, uuid, path):
    """True when the Client API can read `path` in the server (the file exists). Uses the client key, never the app key."""
    q = urllib.parse.urlencode({"file": "/" + path.lstrip("/")})
    req = urllib.request.Request(f"{url.rstrip('/')}/api/client/servers/{uuid}/files/contents?{q}", headers={
        "Authorization": f"Bearer {client_key}", "Accept": "application/json", "User-Agent": "ptero-games/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=60):
            return True
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise Fail("the client key was rejected by the Client API (./ptero key set client)", 2)
        return False
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        raise Fail(f"cannot reach the Panel to verify the install: {getattr(e, 'reason', e)}", 2)


def cmd_sync(a):
    panel, domain = env_panel(), require_domain()
    routes, notes = build_routes(minecraft_servers(panel), domain)
    changed = write_routes(os.environ["ROUTES_FILE"], routes)
    if changed or not a.quiet:      # a quiet run (the 2-minute timer) stays silent unless something changed
        for n in notes:
            print(f"note: {n}", file=sys.stderr)
    if changed or not a.quiet:
        print(f"routes {'updated' if changed else 'unchanged'}: {len(routes)} server(s)")
        for h, b in sorted(routes.items()):
            print(f"  {h} -> {b}")
    if changed:
        print("CHANGED")
    return 0


def cmd_list(a):
    panel, domain = env_panel(), require_domain()
    routes, notes = build_routes(minecraft_servers(panel), domain)
    print(f"{'HOSTNAME':45} BACKEND")
    for h, b in sorted(routes.items()):
        print(f"{h:45} {b}")
    for n in notes:
        print(f"note: {n}")
    return 0


# ---------------------------------------------------------------- create

_INSTALLER = None   # the egg's installer module, loaded once (tests substitute a patched one)


def load_installer():
    global _INSTALLER
    if _INSTALLER is None:
        spec = importlib.util.spec_from_file_location("installer", os.path.join(os.path.dirname(HERE), "eggs", "modpack-installer", "installer.py"))
        _INSTALLER = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_INSTALLER)
    return _INSTALLER


def auto_memory(mods):
    if not mods:
        return 6144
    return 8192 if mods >= 200 else 6144 if mods >= 120 else 4096


def cmd_create(a):
    panel, domain = env_panel(), require_domain()
    node_id = int(os.environ.get("GAMES_NODE_ID", "1"))
    first, last = int(os.environ["GAMES_BACKEND_FIRST"]), int(os.environ["GAMES_BACKEND_LAST"])
    label = a.label or slugify(a.name)
    host = f"{label}.{domain}"

    servers = panel.all("/api/application/servers?include=allocations")
    if any(s["attributes"]["name"] == a.name for s in servers):
        raise Fail(f"a server named '{a.name}' already exists", 3)
    existing, _ = build_routes(minecraft_servers(panel), domain)
    if host in existing:
        raise Fail(f"{host} is already used by another server", 3)

    egg = next((e["attributes"] for e in panel.all("/api/application/eggs") if e["attributes"]["name"] == EGG_NAME), None)
    if not egg:
        raise Fail(f"the egg '{EGG_NAME}' is not installed in the Panel. Run: ./ptero egg install", 3)
    egg_full = panel.call("GET", f"/api/application/eggs/{egg['id']}?include=variables")["attributes"]
    variables = rel(egg_full, "variables")

    probe_env = {"MODPACK_SOURCE": a.source, "MODPACK_ID": a.pack, "MODPACK_VERSION": a.version or "", "MODPACK_MC_VERSION": a.mc or "",
                 "LOADER_VERSION": a.loader_version or "", "CURSEFORGE_API_KEY": os.environ.get("CURSEFORGE_API_KEY", "")}
    print(f"probing {a.source}:{a.pack} ...", flush=True)
    try:
        info = load_installer().probe(probe_env)
    except Exception as e:                      # InstallError and anything the probe trips over
        raise Fail(f"cannot read the pack: {e}", 3)
    if a.loader and info.get("loader") and a.loader != info["loader"]:
        raise Fail(f"the pack uses {info['loader']}, not {a.loader}. Drop --loader or pick the matching pack", 3)
    java = info.get("java") or "java_21"
    image = next((u for u in egg_full["docker_images"].values() if u.endswith(":" + java)), None)
    if not image:
        raise Fail(f"the egg has no Docker image for {java}", 3)
    memory = a.memory or auto_memory(info.get("mods"))

    node = panel.call("GET", f"/api/application/nodes/{node_id}")["attributes"]
    used = sum(s["attributes"]["limits"]["memory"] for s in servers if s["attributes"]["node"] == node_id)
    cap = node["memory"] * (100 + node.get("memory_overallocate", 0)) // 100
    if used + memory > cap:
        raise Fail(f"not enough node memory: {used} MB used, new server {memory} MB, node limit {cap} MB. Lower --memory or free a server first", 3)

    allocs = [x["attributes"] for x in panel.all(f"/api/application/nodes/{node_id}/allocations")]
    free = sorted(x["port"] for x in allocs if x["ip"] == "127.0.0.1" and not x["assigned"] and first <= x["port"] <= last)
    taken = {x["port"] for x in allocs if x["ip"] == "127.0.0.1"}
    if a.port:
        port = a.port
        if not first <= port <= last:
            raise Fail(f"--port must be inside the backend range {first}-{last} (GAMES_BACKEND_FIRST/LAST)", 3)
        if port in taken and port not in free:
            raise Fail(f"127.0.0.1:{port} is already assigned to a server", 3)
    elif free:
        port = free[0]
    else:
        port = next((p for p in range(first, last + 1) if p not in taken), None)
        if port is None:
            raise Fail(f"no free backend port in {first}-{last}", 3)
    need_alloc = port not in free

    env = {v["attributes"]["env_variable"]: v["attributes"].get("default_value") or "" for v in variables}
    env.update({"MODPACK_SOURCE": a.source, "MODPACK_ID": a.pack, "MODPACK_VERSION": a.version or "", "MODPACK_MC_VERSION": a.mc or ""})
    if a.loader_version:
        if "LOADER_VERSION" not in env:
            raise Fail("the egg has no LOADER_VERSION variable yet. Run: ./ptero egg install", 3)
        env["LOADER_VERSION"] = a.loader_version
    owner_email = a.owner or os.environ.get("ADMIN_EMAIL", "")
    owner = next((u["attributes"]["id"] for u in panel.all("/api/application/users") if u["attributes"]["email"] == owner_email), None)
    if owner is None:
        raise Fail(f"no Panel user with e-mail {owner_email!r} (use --owner)", 3)

    body = {"name": a.name, "user": owner, "egg": egg["id"], "docker_image": image, "startup": egg_full["startup"], "environment": env,
            "skip_scripts": False, "oom_disabled": False,
            "limits": {"memory": memory, "swap": 0, "disk": a.disk, "io": 500, "cpu": a.cpu, "threads": None},
            "feature_limits": {"databases": 0, "allocations": 0, "backups": 3},
            "allocation": {"default": None}, "start_on_completion": False}
    print(f"pack    : {info.get('label')} {info.get('version')}  Minecraft {info.get('minecraft')}  loader {info.get('loader')}  mods {info.get('mods')}")
    print(f"server   : '{a.name}' on node {node_id}, 127.0.0.1:{port}{' (allocation will be created)' if need_alloc else ''}")
    print(f"resources: {memory} MB RAM (node {used}/{cap} used), {a.disk} MB disk, CPU {a.cpu}%, image {image}")
    print(f"address  : {host}  (players connect to this name on port {os.environ.get('GAMES_PORT', '25565')}, no port needed)")
    if not a.apply:
        print("\nplan only. Nothing was created.")
        return 0

    if need_alloc:
        panel.call("POST", f"/api/application/nodes/{node_id}/allocations", {"ip": "127.0.0.1", "ports": [str(port)]})
        allocs = [x["attributes"] for x in panel.all(f"/api/application/nodes/{node_id}/allocations")]
    alloc_id = next(x["id"] for x in allocs if x["ip"] == "127.0.0.1" and x["port"] == port)
    body["allocation"]["default"] = alloc_id
    created = panel.call("POST", "/api/application/servers", body)["attributes"]
    print(f"created server id={created['id']} uuid={created['uuid']}")
    if not a.no_wait:
        print("waiting for Wings to run the install (download the pack, install the loader) ...", flush=True)
        sid = created["id"]
        # `status` cannot be used alone: it is null before Wings starts AND after a fast install, and a short poll can miss
        # "installing" entirely. `container.installed` starts at 0 for a new server and becomes 1 when Wings reports success.
        t0 = time.time()
        while True:
            attrs = panel.call("GET", f"/api/application/servers/{sid}")["attributes"]
            if attrs.get("status") == "install_failed":
                raise Fail("the install failed. Open the server in the Panel and read the install output (Console)", 1)
            if not attrs.get("status") and attrs.get("container", {}).get("installed") in (1, True):
                break
            if time.time() - t0 > 2400:
                raise Fail("timed out waiting for the install (40 min). Check the Panel console", 1)
            if time.time() - t0 > 240 and not attrs.get("status") and not attrs.get("container", {}).get("installed"):
                raise Fail("Wings has not reported the install after 4 minutes. Is Wings online and connected to the Panel? (./ptero wings status)", 1)
            time.sleep(5)
        print("install finished.")
        # Wings 1.13 marks an install "completed" even when the install script exited with an error (seen in testing, exit 127
        # and a Python traceback alike). So "finished" is not proof. The launch file is the proof, read through the Client API.
        ckey = os.environ.get("PANEL_CLIENT_KEY", "")
        if ckey:
            if not panel_file_exists(panel.url, ckey, created["uuid"], "launch.args"):
                raise Fail("Wings reports the install finished, but launch.args is missing: the install script did not complete. "
                           "Open the server in the Panel and read the install output (Console), fix the cause, then reinstall", 1)
            print("verified: launch.args is in place")
        else:
            print("warning: not verified. Wings reports success even when the install script fails. Add a client key "
                  "(./ptero key set client) to verify launch.args automatically, or check the Console before you start the server")
    routes, _ = build_routes(minecraft_servers(panel), domain)
    write_routes(os.environ["ROUTES_FILE"], routes)
    print(f"\nrouted: {host} -> 127.0.0.1:{port}")
    print("next: open the server in the Panel, press Start, accept the Minecraft EULA when asked, then connect with the address above.")
    print("CHANGED")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sync")
    s.add_argument("--quiet", action="store_true")
    sub.add_parser("list")
    c = sub.add_parser("create")
    c.add_argument("--name", required=True)
    c.add_argument("--source", choices=["modrinth", "curseforge", "url"], required=True)
    c.add_argument("--pack", required=True)
    c.add_argument("--version")
    c.add_argument("--mc")
    c.add_argument("--loader", choices=["fabric", "forge", "neoforge", "quilt"], help="optional: must match the pack (the pack decides)")
    c.add_argument("--loader-version", help="optional: loader version for packs whose server files do not state it (e.g. 21.1.259)")
    c.add_argument("--owner")
    c.add_argument("--label", help="hostname label; default is the server name")
    c.add_argument("--port", type=int)
    c.add_argument("--memory", type=int)
    c.add_argument("--disk", type=int, default=20480)
    c.add_argument("--cpu", type=int, default=400)
    c.add_argument("--no-wait", action="store_true")
    c.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    try:
        return {"sync": cmd_sync, "list": cmd_list, "create": cmd_create}[a.cmd](a)
    except Fail as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return e.code


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Install a modpack into a Wings server volume (host side, no Panel upload needed).

  modpack.py modrinth   <slug> <fabric|forge|neoforge|quilt> <mc-version> <server-uuid> [--version-id ID] [--yes]
  modpack.py mrpack     <file.mrpack> <server-uuid> [--yes]
  modpack.py curseforge <slug> <mc-version> <server-uuid> [--loader forge|fabric|quilt|neoforge]
                        [--file-id ID] [--mode auto|server|manifest] [--manual-dir DIR] [--pack-file FILE] [--yes]
  modpack.py zip        <server-pack.zip> <server-uuid> [--yes]

Default is a dry run. --yes downloads and verifies each file, stages it, then copies it into
/var/lib/pterodactyl/volumes/<uuid>, keeping the owner the server already uses. The server must
be stopped. Existing files with the same name are overwritten, so back up first.

CurseForge needs an API key: CURSEFORGE_API_KEY in the environment, or in
~/pterodactyl-stack/.curseforge.env (chmod 600). The key is sent only to the API host,
never to the download CDN.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, time, urllib.error, urllib.parse, urllib.request, zipfile

VOLUMES = "/var/lib/pterodactyl/volumes"
STAGE = os.path.expanduser("~/pterodactyl-stack/staging")
KEYFILE = os.path.expanduser("~/pterodactyl-stack/.curseforge.env")
UA = "ptero-ops/1.0 (" + os.environ.get("ADMIN_EMAIL", "admin@example.com") + ")"
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
CF_BASE = os.environ.get("CURSEFORGE_API_BASE", "https://api.curseforge.com").rstrip("/")
CF_GAME_ID = 432          # Minecraft
CF_CLASS_MODPACKS = 4471  # Modpacks
CF_LOADER = {"forge": 1, "fabric": 4, "quilt": 5, "neoforge": 6}


# ---------- HTTP and hashing ----------

def http_get(url, headers=None):
    h = {"User-Agent": UA}
    h.update(headers or {})
    with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=120) as r:
        return r.read()


def fetch(url, dest, algo="sha512", digest=None):
    """Stream url to dest. The request carries no API key. Verifies the digest when given."""
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    h = hashlib.new(algo)
    tmp = dest + ".part"
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=300) as r, open(tmp, "wb") as f:
        for chunk in iter(lambda: r.read(1 << 16), b""):
            f.write(chunk)
            h.update(chunk)
    if digest and h.hexdigest() != digest.lower():
        os.remove(tmp)
        raise ValueError(f"{algo} mismatch for {url}")
    os.replace(tmp, dest)


def file_digest(path, algo):
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_rel(p):
    """Reject absolute paths and '..' so a pack can't write outside the server folder."""
    parts = [x for x in p.replace("\\", "/").split("/") if x not in ("", ".")]
    if not parts or ".." in parts or p.startswith(("/", "\\")):
        raise ValueError(f"unsafe path in pack: {p!r}")
    return os.path.join(*parts)


# ---------- server volume ----------

def running(uuid):
    out = subprocess.run(["docker", "ps", "-q", "--filter", f"name={uuid}"],
                         capture_output=True, text=True).stdout.strip()
    return bool(out)


def fresh_stage(uuid):
    d = os.path.join(STAGE, uuid)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    return d


def apply_stage(root, uuid):
    """Copy the staged tree into the volume as root, keeping the server's own owner."""
    if running(uuid):
        sys.exit("server container is running. Stop it in the Panel first, then re-run with --yes.")
    if not os.path.isdir(os.path.join(VOLUMES, uuid)):
        sys.exit(f"no volume {VOLUMES}/{uuid} (is this the server's UUID?)")
    script = (
        f"set -e; O=$(stat -c %u:%g /v/{uuid}); cd /s; "
        f"for t in $(ls -A); do cp -a \"$t\" /v/{uuid}/; chown -R \"$O\" /v/{uuid}/\"$t\"; done; "
        f"echo copied $(ls -A | wc -l) top-level entries, owner $O"
    )
    subprocess.run(["docker", "run", "--rm", "-v", f"{VOLUMES}:/v", "-v", f"{root}:/s:ro",
                    "alpine", "sh", "-c", script], check=True)


def print_deps(deps):
    print("\nSet these in the Panel (Startup / egg variables):")
    if "minecraft" in deps:
        print(f"  MC_VERSION     = {deps['minecraft']}")
    if "forge" in deps and "minecraft" in deps:
        print(f"  FORGE_VERSION  = {deps['minecraft']}-{deps['forge']}   (Forge egg)")
    if "fabric-loader" in deps:
        print(f"  LOADER_VERSION = {deps['fabric-loader']}   (Fabric egg)")
    for k in ("neoforge", "quilt-loader"):
        if k in deps:
            print(f"  {k} {deps[k]}: no matching egg in this stack. Use the matching egg from the eggs repo.")
    print(f"  Docker image   : {java_for(deps.get('minecraft', ''))}")


def java_for(mc):
    """Minecraft → Java: 1.20.5+ and 1.21+ need 21; 1.18–1.20.4 need 17; 1.17 needs 16; older 8."""
    nums = [int(x) for x in re.findall(r"\d+", mc)] + [0, 0, 0]
    minor, patch = nums[1], nums[2]
    if minor >= 21 or (minor == 20 and patch >= 5):
        return "java_21"
    if minor >= 18 or minor == 20:
        return "java_17"
    if minor == 17:
        return "java_16"
    return "java_8"


# ---------- zip (server pack) ----------

def zip_rel(name, prefix):
    """Path inside the server folder. A top-level overrides/ folder IS the server root (CurseForge style)."""
    rel = name[len(prefix):]
    return rel[len("overrides/"):] if rel.startswith("overrides/") else rel


def install_zip(path, uuid, apply, cleanup=False):
    z = zipfile.ZipFile(path)
    names = [n for n in z.namelist() if not n.endswith("/")]
    tops = {n.split("/")[0] for n in names}
    prefix = (tops.pop() + "/") if len(tops) == 1 and all("/" in n for n in names) else ""
    members = [n for n in names if n.startswith(prefix)]
    rels = [zip_rel(n, prefix) for n in members]
    mods = sum(1 for r in rels if r.startswith("mods/"))
    overrides = sum(1 for n in members if n[len(prefix):].startswith("overrides/"))
    print(f"zip: {len(members)} files, {mods} mods/*.jar, top folder stripped: {prefix or 'none'}"
          + (f", overrides/ folder merged into server root ({overrides} files)" if overrides else ""))
    if "manifest.json" in names and mods == 0:
        sys.exit("looks like a CurseForge client pack (manifest.json, no mods/). "
                 "Use the curseforge command with --pack-file <zip> instead.")
    if not apply:
        print("dry run: nothing written to the server. Re-run with --yes to apply.")
        if cleanup:
            os.remove(path)
        return
    root = fresh_stage(uuid)
    for n in members:
        dst = os.path.join(root, safe_rel(zip_rel(n, prefix)))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with z.open(n) as src, open(dst, "wb") as out:
            shutil.copyfileobj(src, out)
    if cleanup:
        os.remove(path)
    apply_stage(root, uuid)
    shutil.rmtree(root, ignore_errors=True)


def cmd_zip(a):
    install_zip(a.path, a.uuid, a.yes)


# ---------- Modrinth (.mrpack) ----------

def install_mrpack(pack_path, uuid, apply, cleanup=False):
    z = zipfile.ZipFile(pack_path)
    idx = json.loads(z.read("modrinth.index.json"))
    deps = idx.get("dependencies", {})
    server_files = [x for x in idx["files"] if x.get("env", {}).get("server") != "unsupported"]
    skipped = len(idx["files"]) - len(server_files)
    overrides = [n for n in z.namelist()
                 if n.startswith(("overrides/", "server-overrides/")) and not n.endswith("/")]
    print(f"pack: {idx.get('name')} ({idx.get('versionId')})  deps={deps}")
    print(f"plan: {len(server_files)} files to download, {skipped} client-only skipped, "
          f"{len(overrides)} override files")
    if not apply:
        print("dry run: nothing written to the server. Re-run with --yes to apply.")
        if cleanup:
            os.remove(pack_path)
        print_deps(deps)
        return
    root = fresh_stage(uuid)
    for prefix in ("overrides/", "server-overrides/"):  # server-overrides last, so it wins
        for n in overrides:
            if n.startswith(prefix):
                dst = os.path.join(root, safe_rel(n[len(prefix):]))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, "wb") as out:
                    out.write(z.read(n))
    for i, x in enumerate(server_files, 1):
        dst = os.path.join(root, safe_rel(x["path"]))
        sha = x.get("hashes", {}).get("sha512")
        last = None
        for url in x.get("downloads", []):
            try:
                fetch(url, dst, "sha512", sha)
                break
            except Exception as e:  # try the next mirror
                last = e
        else:
            sys.exit(f"download failed for {x['path']}: {last}")
        if i % 20 == 0 or i == len(server_files):
            print(f"  {i}/{len(server_files)} {x['path']}")
    if cleanup:
        os.remove(pack_path)
    apply_stage(root, uuid)
    shutil.rmtree(root, ignore_errors=True)
    print_deps(deps)


def cmd_mrpack(a):
    install_mrpack(a.path, a.uuid, a.yes)


def cmd_modrinth(a):
    q = urllib.parse.urlencode({"loaders": json.dumps([a.loader]), "game_versions": json.dumps([a.mc])})
    versions = json.loads(http_get(f"https://api.modrinth.com/v2/project/{a.slug}/version?{q}"))
    if a.version_id:
        versions = [v for v in versions if v["id"] == a.version_id]
    if not versions:
        sys.exit(f"no {a.loader} {a.mc} version of '{a.slug}'. Check the slug, loader and version.")
    v = next((x for x in versions if x["version_type"] == "release"), versions[0])
    f = next((x for x in v["files"] if x.get("primary")), v["files"][0])
    if not f["filename"].endswith(".mrpack"):
        sys.exit(f"'{f['filename']}' is not a .mrpack. Use the zip command for server packs.")
    print(f"modpack: {v['name']} ({v['version_number']}) file={f['filename']}")
    os.makedirs(STAGE, exist_ok=True)
    pack = os.path.join(STAGE, f"pack-{a.uuid}.mrpack")
    fetch(f["url"], pack, "sha512", f["hashes"].get("sha512"))
    install_mrpack(pack, a.uuid, a.yes, cleanup=True)


# ---------- CurseForge ----------

def cf_key():
    k = os.environ.get("CURSEFORGE_API_KEY", "").strip()
    if not k and os.path.exists(KEYFILE):
        for line in open(KEYFILE):
            if line.startswith("CURSEFORGE_API_KEY="):
                k = line.split("=", 1)[1].strip()
    if not k:
        sys.exit("no CurseForge API key. Set CURSEFORGE_API_KEY in ~/pterodactyl-stack/.curseforge.env "
                 "(chmod 600). Get one at console.curseforge.com.")
    return k


def cf(path, params=None):
    url = CF_BASE + path + ("?" + urllib.parse.urlencode(params) if params else "")
    try:
        body = http_get(url, {"x-api-key": cf_key(), "Accept": "application/json"})
    except urllib.error.HTTPError as e:
        sys.exit(f"CurseForge API {e.code} on {path}. Check the key and the ids.")
    return json.loads(body)["data"]


def cf_sha1(f):
    return next((h["value"] for h in f.get("hashes", []) if h.get("algo") == 1), None)


def cf_download_url(mod_id, f):
    if f.get("downloadUrl"):
        return f["downloadUrl"]
    try:
        return cf(f"/v1/mods/{mod_id}/files/{f['id']}/download-url")
    except SystemExit:
        return None  # author disabled third-party distribution


def cf_find_modpack(slug):
    hits = cf("/v1/mods/search", {"gameId": CF_GAME_ID, "classId": CF_CLASS_MODPACKS,
                                  "slug": slug, "pageSize": 10})
    exact = [h for h in hits if h.get("slug") == slug]
    if not exact:
        sys.exit(f"no CurseForge modpack with slug '{slug}'. Use the slug from the URL "
                 f"(curseforge.com/minecraft/modpacks/<slug>).")
    return exact[0]


def cf_pick_file(mod, mc, loader, file_id):
    if file_id:
        return cf(f"/v1/mods/{mod['id']}/files/{file_id}")
    params = {"pageSize": 50}
    if loader:
        params["modLoaderType"] = CF_LOADER[loader]
    files = sorted(cf(f"/v1/mods/{mod['id']}/files", params), key=lambda x: x.get("fileDate", ""), reverse=True)
    ok = [x for x in files if mc in (x.get("gameVersions") or [])]
    if not ok:
        sys.exit(f"no file of '{mod['slug']}' for Minecraft {mc}"
                 f"{' with ' + loader if loader else ''}. Try another version, or --file-id.")
    return ok[0]


def install_cf_manifest(pack, uuid, apply, manual_dir, cleanup):
    """Client-style CurseForge pack: resolve every mod from manifest.json via the API."""
    z = zipfile.ZipFile(pack)
    man = json.loads(z.read("manifest.json"))
    mc = man["minecraft"]["version"]
    deps = {"minecraft": mc}
    for ml in man["minecraft"].get("modLoaders", []):
        if not ml.get("primary", True):
            continue
        lid = ml.get("id", "")
        if lid.startswith("forge-"):
            deps["forge"] = lid[len("forge-"):]
        elif lid.startswith("fabric-"):
            deps["fabric-loader"] = lid[len("fabric-"):]
        elif lid.startswith("neoforge-"):
            deps["neoforge"] = lid[len("neoforge-"):]
    entries = man.get("files", [])
    print(f"manifest: {len(entries)} mod files, minecraft {mc}, deps={deps}")
    mods, blocked = [], []
    for i, e in enumerate(entries, 1):
        fd = cf(f"/v1/mods/{e['projectID']}/files/{e['fileID']}")
        name = fd["fileName"]
        url = cf_download_url(e["projectID"], fd)
        local = None
        if not url:
            cand = os.path.join(manual_dir, name) if manual_dir else None
            if cand and os.path.exists(cand):
                local = cand
            else:
                blocked.append((e["projectID"], e["fileID"], name))
                continue
        mods.append((name, url, cf_sha1(fd), local))
        if i % 25 == 0:
            print(f"  resolved {i}/{len(entries)}")
        time.sleep(0.05)  # be gentle with the API rate limit
    print(f"plan: {len(mods)} mods resolvable, {len(blocked)} need a manual download")
    for pid, fid, name in blocked:
        print(f"  MANUAL  {name}  (project {pid}, file {fid}): download it in the browser")
    print("note: a client pack does not mark client-only mods. If the server crashes on a client class, "
          "remove that mod. A Server Files pack is safer when one exists.")
    if not apply:
        print("dry run: nothing written to the server. Re-run with --yes to apply.")
        if cleanup:
            os.remove(pack)
        print_deps(deps)
        return
    if blocked:
        sys.exit(f"{len(blocked)} mod(s) must be downloaded by hand. Put them in one folder and re-run "
                 f"with --manual-dir <folder>. Missing: " + ", ".join(n for _, _, n in blocked))
    root = fresh_stage(uuid)
    ov = man.get("overrides", "overrides").strip("/")
    for n in z.namelist():
        if n.startswith(ov + "/") and not n.endswith("/"):
            dst = os.path.join(root, safe_rel(n[len(ov) + 1:]))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "wb") as out:
                out.write(z.read(n))
    os.makedirs(os.path.join(root, "mods"), exist_ok=True)
    unhashed = 0
    for name, url, sha, local in mods:
        dst = os.path.join(root, "mods", safe_rel(name))
        if url:
            if not sha:
                unhashed += 1
            fetch(url, dst, "sha1", sha)  # verified; raises on mismatch
        else:
            shutil.copy(local, dst)
            if sha and file_digest(dst, "sha1") != sha:
                sys.exit(f"sha1 mismatch for manual file {name}")
    if unhashed:
        print(f"warn: {unhashed} file(s) had no sha1 from CurseForge and were not verified")
    if cleanup:
        os.remove(pack)
    apply_stage(root, uuid)
    shutil.rmtree(root, ignore_errors=True)
    print_deps(deps)


def cmd_curseforge(a):
    mod = cf_find_modpack(a.slug)
    f = cf_pick_file(mod, a.mc, a.loader, a.file_id)
    print(f"modpack: {mod.get('name') or mod['slug']} (id {mod['id']})  file: {f.get('displayName') or f['fileName']}  [{f['fileName']}]")
    os.makedirs(STAGE, exist_ok=True)
    spid = f.get("serverPackFileId")
    if a.mode in ("auto", "server") and spid:
        sp = cf(f"/v1/mods/{mod['id']}/files/{spid}")
        if not a.yes:  # dry run: report from metadata only, never download the pack
            size = sp.get("fileLength")
            size_txt = f" ({size / 1e6:.0f} MB)" if size else ""
            print(f"server pack: {sp['fileName']}{size_txt}")
            print("dry run: nothing downloaded or written. Re-run with --yes to apply. "
                  "Startup values are printed after the pack is applied.")
            return
        url = cf_download_url(mod["id"], sp)
        if not url:
            sys.exit(f"server pack '{sp['fileName']}' has no download URL (author disabled it). "
                     f"Download it in the browser, then: modpack.py zip <file> {a.uuid} --yes")
        print(f"server pack: {sp['fileName']}")
        pack = os.path.join(STAGE, f"cf-server-{a.uuid}.zip")
        fetch(url, pack, "sha1", cf_sha1(sp))
        install_zip(pack, a.uuid, a.yes, cleanup=True)
        return
    if a.mode == "server":
        sys.exit("this file has no server pack. Use --mode manifest or pick another --file-id.")
    if a.pack_file:
        install_cf_manifest(a.pack_file, a.uuid, a.yes, a.manual_dir, cleanup=False)
        return
    url = cf_download_url(mod["id"], f)
    if not url:
        sys.exit("this client pack has no download URL. Download it in the browser and re-run "
                 "with --pack-file <file>.")
    pack = os.path.join(STAGE, f"cf-client-{a.uuid}.zip")
    fetch(url, pack, "sha1", cf_sha1(f))
    install_cf_manifest(pack, a.uuid, a.yes, a.manual_dir, cleanup=True)


# ---------- CLI ----------

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("modrinth")
    m.add_argument("slug")
    m.add_argument("loader", choices=["fabric", "forge", "neoforge", "quilt"])
    m.add_argument("mc")
    m.add_argument("uuid")
    m.add_argument("--version-id")
    m.add_argument("--yes", action="store_true")
    mr = sub.add_parser("mrpack")
    mr.add_argument("path")
    mr.add_argument("uuid")
    mr.add_argument("--yes", action="store_true")
    c = sub.add_parser("curseforge")
    c.add_argument("slug")
    c.add_argument("mc")
    c.add_argument("uuid")
    c.add_argument("--loader", choices=list(CF_LOADER))
    c.add_argument("--file-id", type=int)
    c.add_argument("--mode", choices=["auto", "server", "manifest"], default="auto")
    c.add_argument("--manual-dir")
    c.add_argument("--pack-file")
    c.add_argument("--yes", action="store_true")
    z = sub.add_parser("zip")
    z.add_argument("path")
    z.add_argument("uuid")
    z.add_argument("--yes", action="store_true")
    a = p.parse_args()
    if not UUID_RE.match(a.uuid):
        sys.exit("server UUID must be the full UUID (the volume folder name under /var/lib/pterodactyl/volumes).")
    try:
        {"modrinth": cmd_modrinth, "mrpack": cmd_mrpack, "zip": cmd_zip, "curseforge": cmd_curseforge}[a.cmd](a)
    except ValueError as e:  # hash mismatch or unsafe path: report plainly, nothing was copied
        sys.exit(f"stopped: {e}")
    except subprocess.CalledProcessError:
        sys.exit("copy into the volume failed (see the docker output above). The server was not started.")


if __name__ == "__main__":
    main()

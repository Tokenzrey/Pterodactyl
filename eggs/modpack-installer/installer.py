#!/usr/bin/env python3
"""Modpack installer for Pterodactyl: Modrinth (.mrpack), CurseForge, or a direct URL -> a startable Minecraft server.

Runs in two places with the same code:
  * inside the egg's install container (as root; Wings hands ownership to the server user afterwards)
  * on the host with --probe, to learn Minecraft version, loader and Java before a server is created

Configuration is read from the environment (the egg variables), never from arguments, so nothing secret is on a command line:
  MODPACK_SOURCE      modrinth | curseforge | url
  MODPACK_ID          Modrinth slug or id; CurseForge slug or numeric project id; or the https URL for `url`
  MODPACK_VERSION     optional: Modrinth version id or number; CurseForge file id; empty = newest
  MODPACK_MC_VERSION  optional filter for "newest" (e.g. 1.20.1)
  CURSEFORGE_API_KEY  required for curseforge
  SERVER_DIR          install target (default /mnt/server)

Result in SERVER_DIR: the pack's mods/configs, the loader (Fabric, Quilt, Forge, NeoForge), `launch.args` (what the
startup command appends to `java`), and `.ptero-modpack.json` (what was installed, for clean reinstalls).
The EULA is never accepted here: the Panel's "eula" feature asks the server owner on first start.
"""
import argparse
import fnmatch
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

UA = "ptero-modpack-installer/1.0 (+https://pterodactyl.io)"
CF_BASE = os.environ.get("CURSEFORGE_API_BASE", "https://api.curseforge.com").rstrip("/")
MODRINTH_BASE = os.environ.get("MODRINTH_API_BASE", "https://api.modrinth.com").rstrip("/")
MOJANG_MANIFEST = os.environ.get("MOJANG_MANIFEST_URL", "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")
CF_GAME_ID, CF_CLASS_MODPACKS = 432, 4471
CF_LOADER_ID = {"forge": 1, "fabric": 4, "quilt": 5, "neoforge": 6}
# Pack authors choose download URLs; only these hosts are followed (the .mrpack spec allows exactly these).
MODRINTH_FILE_HOSTS = ("cdn.modrinth.com", "github.com", "raw.githubusercontent.com", "gitlab.com")
CF_FILE_HOSTS = ("forgecdn.net", "edge.forgecdn.net", "media.forgecdn.net", "mediafilez.forgecdn.net")
# Never overwritten when a pack is (re)installed over an existing server: the owner's data and edits.
KEEP_PATTERNS = ("config/*", "defaultconfigs/*", "server.properties", "eula.txt", "ops.json", "whitelist.json",
                 "banned-ips.json", "banned-players.json", "usercache.json", "world/*", "world_*/*", "backups/*", "logs/*")


class InstallError(Exception):
    pass


def log(msg):
    print(f"[modpack] {msg}", flush=True)


# ---------------------------------------------------------------- HTTP, hashing, paths

def http_get(url, headers=None, retries=3):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 and e.code != 429:
                raise InstallError(f"HTTP {e.code} for {url_for_log(url)}")
            last = e
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last = e
        time.sleep(2 * (attempt + 1))
    raise InstallError(f"cannot fetch {url_for_log(url)}: {last}")


def url_for_log(url):
    p = urllib.parse.urlsplit(url)
    return f"{p.scheme}://{p.netloc}{p.path}"   # never log query strings


def host_allowed(url, hosts):
    p = urllib.parse.urlsplit(url)
    h = (p.hostname or "").lower()
    return p.scheme == "https" and any(h == a or h.endswith("." + a) for a in hosts)


def public_host(host):
    """True when every address `host` resolves to is a public one (blocks loopback, private, link-local, metadata)."""
    import ipaddress
    import socket
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast or ip.is_unspecified:
            return False
    return bool(infos)


class PublicOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://") or not public_host(urllib.parse.urlsplit(newurl).hostname or ""):
            raise InstallError(f"refusing redirect to {url_for_log(newurl)}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, dest, algo=None, digest=None, hosts=None, retries=3, public_only=False):
    """Stream url to dest, verifying `digest` (hex) when given. The download carries no API key."""
    if hosts is not None and not host_allowed(url, hosts):
        raise InstallError(f"refusing to download from {urllib.parse.urlsplit(url).netloc} (not an allowed host)")
    if public_only and not public_host(urllib.parse.urlsplit(url).hostname or ""):
        raise InstallError(f"refusing to download from {urllib.parse.urlsplit(url).netloc}: it does not resolve to a public address")
    opener = urllib.request.build_opener(PublicOnlyRedirect) if public_only else urllib.request.build_opener()
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    last = None
    for attempt in range(retries):
        tmp = dest + ".part"
        h = hashlib.new(algo) if algo and digest else None
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with opener.open(req, timeout=120) as r, open(tmp, "wb") as f:
                for chunk in iter(lambda: r.read(1 << 16), b""):
                    f.write(chunk)
                    if h:
                        h.update(chunk)
            if h and h.hexdigest() != digest.lower():
                os.remove(tmp)
                raise InstallError(f"{algo} mismatch for {os.path.basename(dest)}")
            os.replace(tmp, dest)
            return
        except InstallError:
            raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            last = e
            time.sleep(2 * (attempt + 1))
    raise InstallError(f"download failed for {url_for_log(url)}: {last}")


def safe_rel(p):
    """A relative path that cannot leave the server directory."""
    parts = [x for x in p.replace("\\", "/").split("/") if x not in ("", ".")]
    if not parts or ".." in parts or p.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", p):
        raise InstallError(f"unsafe path in pack: {p!r}")
    return os.path.join(*parts)


def keep_existing(rel):
    rel = rel.replace(os.sep, "/")
    return any(fnmatch.fnmatch(rel, pat) for pat in KEEP_PATTERNS)


YOLKS_JAVA = (8, 11, 16, 17, 21, 25)   # ghcr.io/pterodactyl/yolks:java_N images that exist


def mojang_java_major(mc):
    """The Java major version Mojang declares for this Minecraft version, or None when it cannot be looked up."""
    try:
        manifest = json.loads(http_get(MOJANG_MANIFEST, retries=2))
        entry = next(v for v in manifest["versions"] if v["id"] == mc)
        return int(json.loads(http_get(entry["url"], retries=2))["javaVersion"]["majorVersion"])
    except (InstallError, StopIteration, KeyError, ValueError):
        return None


def static_java_major(mc):
    nums = [int(x) for x in re.findall(r"\d+", mc or "")] + [0, 0, 0]
    if nums[0] > 1:                      # year-style versions (26.x) need Java 25
        return 25
    minor, patch = nums[1], nums[2]
    if minor >= 21 or (minor == 20 and patch >= 5):
        return 21
    if minor >= 18 or minor == 20:
        return 17
    return 16 if minor == 17 else 8


def java_major(mc):
    return mojang_java_major(mc) or static_java_major(mc)


def java_for(mc):
    """Minecraft version -> yolks image suffix (java_N): Mojang's declared requirement, else a built-in table."""
    need = java_major(mc)
    return "java_%d" % next((j for j in YOLKS_JAVA if j >= need), YOLKS_JAVA[-1])


# ---------------------------------------------------------------- pack descriptions

class Pack:
    """What a source resolved to, before any server file is written."""

    def __init__(self, **kw):
        self.source = kw.get("source")
        self.label = kw.get("label", "")
        self.version = kw.get("version", "")
        self.mc = kw.get("mc")                 # Minecraft version or None if unknown until the archive is read
        self.loader = kw.get("loader")         # fabric | quilt | forge | neoforge | None
        self.loader_version = kw.get("loader_version")
        self.mods = kw.get("mods")             # number of mod files, or None
        self.path = kw.get("path")             # local archive
        self.kind = kw.get("kind")             # mrpack | server-zip | cf-manifest
        self.cf = kw.get("cf")                 # CurseForge details (mod id, file)

    def summary(self):
        return {"source": self.source, "label": self.label, "version": self.version, "minecraft": self.mc,
                "loader": self.loader, "loader_version": self.loader_version, "mods": self.mods,
                "java": java_for(self.mc) if self.mc else None}


# ---------------------------------------------------------------- Modrinth

def modrinth(path, params=None):
    url = MODRINTH_BASE + path + ("?" + urllib.parse.urlencode(params) if params else "")
    return json.loads(http_get(url))


def modrinth_pick_version(slug, version, mc):
    if version:
        try:
            return modrinth(f"/v2/version/{urllib.parse.quote(version)}")
        except InstallError:
            pass
    try:
        versions = modrinth(f"/v2/project/{urllib.parse.quote(slug)}/version")
    except InstallError as e:
        raise InstallError(f"Modrinth project '{slug}' not found or unavailable ({e})")
    if version:
        versions = [v for v in versions if v.get("version_number") == version or v.get("name") == version]
    if mc:
        versions = [v for v in versions if mc in v.get("game_versions", [])]
    if not versions:
        raise InstallError(f"no matching version of Modrinth project '{slug}'" + (f" for Minecraft {mc}" if mc else ""))
    return next((v for v in versions if v.get("version_type") == "release"), versions[0])


def read_mrpack_index(path):
    with zipfile.ZipFile(path) as z:
        return json.loads(z.read("modrinth.index.json"))


def mrpack_info(index):
    d = index.get("dependencies", {})
    loader = next((name for key, name in (("fabric-loader", "fabric"), ("quilt-loader", "quilt"), ("neoforge", "neoforge"),
                                          ("forge", "forge")) if key in d), None)
    lv = d.get({"fabric": "fabric-loader", "quilt": "quilt-loader", "neoforge": "neoforge", "forge": "forge"}.get(loader, ""), None)
    mods = sum(1 for x in index.get("files", []) if x.get("env", {}).get("server") != "unsupported")
    return d.get("minecraft"), loader, lv, mods


def resolve_modrinth(env, workdir):
    slug = env["MODPACK_ID"]
    v = modrinth_pick_version(slug, env.get("MODPACK_VERSION", ""), env.get("MODPACK_MC_VERSION", ""))
    f = next((x for x in v["files"] if x.get("primary")), v["files"][0])
    if not f["filename"].endswith(".mrpack"):
        raise InstallError(f"'{slug}' {v.get('version_number')} is not a modpack file ({f['filename']})")
    path = os.path.join(workdir, f["filename"])
    log(f"Modrinth: {v.get('name')} ({v.get('version_number')}), downloading the pack definition")
    fetch(f["url"], path, "sha512", f["hashes"].get("sha512"), hosts=("cdn.modrinth.com",))
    mc, loader, lv, mods = mrpack_info(read_mrpack_index(path))
    return Pack(source="modrinth", label=v.get("name") or slug, version=v.get("version_number", ""), mc=mc, loader=loader,
                loader_version=lv, mods=mods, path=path, kind="mrpack")


def apply_mrpack(pack, dest, record):
    with zipfile.ZipFile(pack.path) as z:
        index = json.loads(z.read("modrinth.index.json"))
        names = z.namelist()
        n = 0
        for prefix in ("overrides/", "server-overrides/"):     # server-overrides last so it wins
            for name in names:
                if name.startswith(prefix) and not name.endswith("/"):
                    n += write_member(z, name, safe_rel(name[len(prefix):]), dest, record)
        log(f"copied {n} override files (owner-kept files such as config/ were left as they are)")
    files = [x for x in index.get("files", []) if x.get("env", {}).get("server") != "unsupported"]
    skipped = len(index.get("files", [])) - len(files)
    for i, x in enumerate(files, 1):
        rel = safe_rel(x["path"])
        target = os.path.join(dest, rel)
        sha = x.get("hashes", {}).get("sha512")
        if not sha:
            raise InstallError(f"{rel}: the pack gives no sha512; refusing an unverifiable download")
        last = None
        for url in x.get("downloads", []):
            try:
                fetch(url, target, "sha512", sha, hosts=MODRINTH_FILE_HOSTS)
                record(rel)
                break
            except InstallError as e:
                last = e
        else:
            raise InstallError(f"cannot download {rel}: {last}")
        if i % 25 == 0 or i == len(files):
            log(f"  {i}/{len(files)} files")
    if skipped:
        log(f"skipped {skipped} client-only files")


def write_member(z, name, rel, dest, record):
    target = os.path.join(dest, rel)
    if os.path.exists(target) and keep_existing(rel):
        return 0
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with z.open(name) as src, open(target, "wb") as out:
        shutil.copyfileobj(src, out)
    record(rel)
    return 1


# ---------------------------------------------------------------- CurseForge

def cf_key(env):
    k = env.get("CURSEFORGE_API_KEY", "").strip()
    if not k:
        raise InstallError("CurseForge needs an API key (variable CURSEFORGE_API_KEY, set by the administrator; get one at console.curseforge.com)")
    return k


def cf(env, path, params=None):
    url = CF_BASE + path + ("?" + urllib.parse.urlencode(params) if params else "")
    return json.loads(http_get(url, {"x-api-key": cf_key(env), "Accept": "application/json"}))["data"]


def cf_sha1(f):
    return next((h["value"] for h in f.get("hashes", []) if h.get("algo") == 1), None)


def cf_download_url(env, mod_id, f):
    if f.get("downloadUrl"):
        return f["downloadUrl"]
    try:
        return cf(env, f"/v1/mods/{mod_id}/files/{f['id']}/download-url")
    except InstallError:
        return None   # the author disabled third-party downloads


def cf_find_modpack(env, ident):
    if re.fullmatch(r"\d+", ident):
        return cf(env, f"/v1/mods/{ident}")
    hits = cf(env, "/v1/mods/search", {"gameId": CF_GAME_ID, "classId": CF_CLASS_MODPACKS, "slug": ident, "pageSize": 10})
    exact = [h for h in hits if h.get("slug") == ident]
    if not exact:
        raise InstallError(f"no CurseForge modpack with slug '{ident}' (use the slug from curseforge.com/minecraft/modpacks/<slug>, or the numeric project id)")
    return exact[0]


def cf_pick_file(env, mod, version, mc):
    if version:
        return cf(env, f"/v1/mods/{mod['id']}/files/{version}")
    files = sorted(cf(env, f"/v1/mods/{mod['id']}/files", {"pageSize": 50}), key=lambda x: x.get("fileDate", ""), reverse=True)
    if mc:
        files = [x for x in files if mc in (x.get("gameVersions") or [])]
    files = [x for x in files if x.get("releaseType", 1) == 1] or files   # prefer release files
    if not files:
        raise InstallError(f"no file of '{mod.get('slug')}'" + (f" for Minecraft {mc}" if mc else ""))
    return files[0]


def cf_meta_versions(f):
    gv = f.get("gameVersions") or []
    mc = next((g for g in gv if re.fullmatch(r"\d+\.\d+(\.\d+)?", g)), None)
    low = {g.lower() for g in gv}
    loader = next((n for n in ("neoforge", "forge", "fabric", "quilt") if n in low), None)
    return mc, loader


def resolve_curseforge(env, workdir, download=True):
    mod = cf_find_modpack(env, env["MODPACK_ID"])
    f = cf_pick_file(env, mod, env.get("MODPACK_VERSION", ""), env.get("MODPACK_MC_VERSION", ""))
    label = mod.get("name") or mod.get("slug")
    mc, loader = cf_meta_versions(f)
    spid = f.get("serverPackFileId")
    # A pinned server pack is its own download; a client pack names the server pack it goes with.
    server = bool(spid) or bool(f.get("isServerPack"))
    use = cf(env, f"/v1/mods/{mod['id']}/files/{spid}") if spid else f
    log(f"CurseForge: {label} / {f.get('displayName') or f.get('fileName')}" + (" (server pack)" if server else " (client pack: mods resolved one by one)"))
    pack = Pack(source="curseforge", label=label, version=str(f["id"]), mc=mc, loader=loader, kind="server-zip" if server else "cf-manifest",
                cf={"mod": mod, "file": use})
    if not download:
        return pack
    url = cf_download_url(env, mod["id"], use)
    if not url:
        raise InstallError(f"the author disabled downloads of '{use.get('fileName')}' through the API. Download it in a browser and use the url source with a direct link you host, or ask the author for an API-enabled file")
    pack.path = os.path.join(workdir, use["fileName"])
    fetch(url, pack.path, "sha1", cf_sha1(use), hosts=CF_FILE_HOSTS)
    if pack.kind == "server-zip":
        pack.path = unwrap_server_zip(pack.path, workdir)
    if pack.kind == "cf-manifest":
        with zipfile.ZipFile(pack.path) as z:
            man = json.loads(z.read("manifest.json"))
        pack.mc = man["minecraft"]["version"]
        for ml in man["minecraft"].get("modLoaders", []):
            if ml.get("primary", True):
                lid = ml.get("id", "")
                for name in ("neoforge", "forge", "fabric", "quilt"):
                    if lid.startswith(name + "-"):
                        pack.loader, pack.loader_version = name, lid[len(name) + 1:]
        pack.mods = len(man.get("files", []))
    else:
        info = inspect_server_zip(pack.path)
        pack.mc = info["mc"] or pack.mc
        pack.loader = info["loader"] or pack.loader
        pack.loader_version = info["loader_version"]
        pack.mods = info["mods"]
    return pack


def unwrap_server_zip(path, workdir):
    """Some server packs are a zip that holds the real server zip next to a readme. Use the inner zip; any other zip stays as it is."""
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        if any(re.search(r"(^|/)(mods/|libraries/|run\.(sh|bat)$)", n) for n in names):
            return path
        inner = [n for n in names if n.lower().endswith(".zip")]
        if len(inner) != 1:
            return path
        out = os.path.join(workdir, "server-pack.zip")
        with z.open(inner[0]) as src, open(out, "wb") as dst:
            shutil.copyfileobj(src, dst)
    os.remove(path)   # the outer copy is no longer needed: keep the server disk for the server itself
    log(f"the download holds the server zip '{inner[0]}': using that")
    return out


def apply_cf_manifest(env, pack, dest, record):
    with zipfile.ZipFile(pack.path) as z:
        man = json.loads(z.read("manifest.json"))
        ov = man.get("overrides", "overrides").strip("/")
        n = 0
        for name in z.namelist():
            if name.startswith(ov + "/") and not name.endswith("/"):
                n += write_member(z, name, safe_rel(name[len(ov) + 1:]), dest, record)
        log(f"copied {n} override files (owner-kept files such as config/ were left as they are)")
    entries = man.get("files", [])
    blocked, skipped_client = [], []
    for i, e in enumerate(entries, 1):
        fd = cf(env, f"/v1/mods/{e['projectID']}/files/{e['fileID']}")
        gv = set(fd.get("gameVersions") or [])
        if "Client" in gv and "Server" not in gv:           # the author marked it client-only
            skipped_client.append(fd["fileName"])
            continue
        url = cf_download_url(env, e["projectID"], fd)
        if not url:
            blocked.append(fd["fileName"])
            continue
        rel = os.path.join("mods", safe_rel(fd["fileName"]))
        fetch(url, os.path.join(dest, rel), "sha1" if cf_sha1(fd) else None, cf_sha1(fd), hosts=CF_FILE_HOSTS)
        record(rel)
        if i % 25 == 0:
            log(f"  {i}/{len(entries)} mods")
        time.sleep(0.05)   # gentle on the API rate limit
    if skipped_client:
        log(f"skipped {len(skipped_client)} mods the authors mark as client-only")
    if blocked:
        raise InstallError(f"{len(blocked)} mod(s) cannot be downloaded through the API (author opt-out): " + ", ".join(blocked[:10])
                           + (" ..." if len(blocked) > 10 else "") + ". Use a pack that ships a server pack, or another source.")


def inspect_server_zip(path):
    """Minecraft/loader versions from inside a server pack: run scripts first, then bundled libraries, then installer names."""
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        mc = loader = lv = None
        forge_re = r"libraries/net/(minecraftforge/forge|neoforged/neoforge)/([\w.\-]+)/unix_args"
        for n in names:
            if re.search(r"(^|/)run\.(sh|bat)$", n):
                m = re.search(forge_re, z.read(n).decode("utf-8", "replace"))
                if m:
                    loader, ver = ("neoforge" if m.group(1).startswith("neoforged") else "forge"), m.group(2)
                    mc, lv = split_forge_version(loader, ver)
                    break
        for n in names:
            if loader is None:
                m = re.search(r"libraries/net/(minecraftforge/forge|neoforged/neoforge)/([\w.\-]+)/", n)
                if m:
                    loader = "neoforge" if m.group(1).startswith("neoforged") else "forge"
                    mc, lv = split_forge_version(loader, m.group(2))
            if loader is None:
                m = re.search(r"libraries/net/fabricmc/fabric-loader/([\d.]+)/", n)
                if m:
                    loader, lv = "fabric", m.group(1)
            if mc is None:
                m = re.search(r"libraries/net/minecraft/server/(\d+\.\d+(?:\.\d+)?)/", n)
                if m:
                    mc = m.group(1)
        for n in names:
            m = re.search(r"(?:^|/)(neo)?forge-([\d.]+)-([\d.]+)(?:-installer)?\.jar$", n)
            if loader is None and m:
                loader, mc, lv = ("neoforge" if m.group(1) else "forge"), m.group(2), m.group(3)
        mods = sum(1 for n in names if re.search(r"(^|/)mods/[^/]+\.jar$", n))
    return {"mc": mc, "loader": loader, "loader_version": lv, "mods": mods}


def split_forge_version(loader, ver):
    """'1.20.1-47.4.0' -> ('1.20.1', '47.4.0'); NeoForge '21.1.77' -> (None, '21.1.77')."""
    m = re.match(r"^(\d+\.\d+(?:\.\d+)?)-([\w.\-]+)$", ver)
    return (m.group(1), m.group(2)) if m else (None, ver)


def apply_server_zip(pack, dest, record):
    with zipfile.ZipFile(pack.path) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        tops = {n.split("/")[0] for n in names}
        prefix = (tops.pop() + "/") if len(tops) == 1 and all("/" in n for n in names) else ""
        n_written = 0
        for name in names:
            if not name.startswith(prefix):
                continue
            rel = name[len(prefix):]
            if rel.startswith("overrides/"):
                rel = rel[len("overrides/"):]
            n_written += write_member(z, name, safe_rel(rel), dest, record)
    log(f"extracted {n_written} files from the server pack")


# ---------------------------------------------------------------- direct URL

def resolve_url(env, workdir):
    url = env["MODPACK_ID"]
    if not url.startswith("https://"):
        raise InstallError("the url source needs an https:// link to a .mrpack or a server-pack .zip")
    name = os.path.basename(urllib.parse.urlsplit(url).path) or "pack.zip"
    path = os.path.join(workdir, name)
    log(f"downloading {url_for_log(url)}")
    fetch(url, path, public_only=True)   # any public https host; never loopback/private/metadata addresses, also across redirects
    try:
        with zipfile.ZipFile(path) as z:
            members = z.namelist()
    except zipfile.BadZipFile:
        raise InstallError("the downloaded file is not a zip archive")
    if "modrinth.index.json" in members:
        mc, loader, lv, mods = mrpack_info(read_mrpack_index(path))
        return Pack(source="url", label=name, mc=mc, loader=loader, loader_version=lv, mods=mods, path=path, kind="mrpack")
    if "manifest.json" in members and not any(n.startswith("mods/") for n in members):
        raise InstallError("this looks like a CurseForge client pack; use the curseforge source")
    info = inspect_server_zip(path)
    return Pack(source="url", label=name, mc=info["mc"], loader=info["loader"], loader_version=info["loader_version"], mods=info["mods"],
                path=path, kind="server-zip")


# ---------------------------------------------------------------- loaders and launch arguments

def find_launch(dest):
    """The `java` arguments that start what is in dest, or None."""
    for pattern in ("libraries/net/neoforged/neoforge/*/unix_args.txt", "libraries/net/minecraftforge/forge/*/unix_args.txt"):
        hits = sorted(glob.glob(os.path.join(dest, pattern)))
        if hits:
            return "@" + os.path.relpath(hits[-1], dest).replace(os.sep, "/")
    for jar in ("fabric-server-launch.jar", "quilt-server-launch.jar"):
        if os.path.isfile(os.path.join(dest, jar)):
            return f"-jar {jar}"
    legacy = [p for p in sorted(glob.glob(os.path.join(dest, "forge-*.jar"))) if "installer" not in p]
    if legacy:
        return "-jar " + os.path.basename(legacy[-1])
    return None


def run(cmd, cwd):
    log("$ " + " ".join(cmd))
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        tail = "\n".join(p.stdout.splitlines()[-25:])
        raise InstallError(f"{cmd[0]} failed with exit code {p.returncode}:\n{tail}")


def system_java_major():
    try:
        out = subprocess.run(["java", "-version"], capture_output=True, text=True).stderr
        m = re.search(r'version "(\d+)(?:\.(\d+))?', out)
        return (int(m.group(2)) if m.group(1) == "1" else int(m.group(1))) if m else 0
    except OSError:
        return 0


JRE_SCRATCH = ".ptero-jre"   # inside the server folder, removed after the loader is installed


def java_for_installer(mc, dest):
    """The `java` to run Forge/NeoForge/Quilt installers with. Legacy packs (Java 8) and newer-than-container (Java 25)
    get a temporary Temurin JRE from Adoptium; otherwise the container's own Java is used.

    The JRE is unpacked into the server folder, not /tmp: Wings caps a container's /tmp (tmpfs_size, 100 MB by default),
    and a JRE is bigger than that, so the extraction failed with "No space left on device" in testing."""
    if os.environ.get("INSTALLER_JAVA"):
        return os.environ["INSTALLER_JAVA"]
    need = java_major(mc)
    have = system_java_major()
    if (need > 8 and have >= need) or (need <= 8 and have == 8):
        return "java"
    arch = {"x86_64": "x64", "aarch64": "aarch64", "arm64": "aarch64"}.get(os.uname().machine)
    if not arch:
        raise InstallError(f"no Java {need} build for this CPU")
    root = os.path.join(dest, JRE_SCRATCH, f"jre{need}")
    existing = glob.glob(root + "/*/bin/java")
    if existing:
        return existing[0]
    os.makedirs(root, exist_ok=True)
    tgz = os.path.join(dest, JRE_SCRATCH, f"jre{need}.tar.gz")
    log(f"fetching a temporary Java {need} for the installer (container has Java {have or 'none'})")
    fetch(f"https://api.adoptium.net/v3/binary/latest/{need}/ga/linux/{arch}/jre/hotspot/normal/eclipse", tgz)
    try:
        p = subprocess.run(["tar", "xzf", tgz, "-C", root], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    finally:
        os.remove(tgz)
    if p.returncode != 0:
        raise InstallError(f"could not unpack the temporary Java {need}: {p.stdout.strip().splitlines()[-1] if p.stdout.strip() else p.returncode}")
    found = glob.glob(root + "/*/bin/java")
    if not found:
        raise InstallError(f"the temporary Java {need} archive has no bin/java")
    return found[0]


def install_loader(pack, dest, workdir):
    loader, mc, lv = pack.loader, pack.mc, pack.loader_version
    if not loader or not mc:
        raise InstallError("cannot tell which mod loader / Minecraft version this pack needs; nothing installed")
    if loader == "fabric":
        meta = json.loads(http_get("https://meta.fabricmc.net/v2/versions/installer"))
        inst = next(i["version"] for i in meta if i.get("stable")) if any(i.get("stable") for i in meta) else meta[0]["version"]
        if not lv:
            lv = json.loads(http_get(f"https://meta.fabricmc.net/v2/versions/loader/{mc}"))[0]["loader"]["version"]
        log(f"Fabric loader {lv} for Minecraft {mc}")
        fetch(f"https://meta.fabricmc.net/v2/versions/loader/{mc}/{lv}/{inst}/server/jar", os.path.join(dest, "fabric-server-launch.jar"))
    elif loader == "quilt":
        inst = json.loads(http_get("https://meta.quiltmc.org/v3/versions/installer"))[0]["version"]
        jar = os.path.join(workdir, "quilt-installer.jar")
        fetch(f"https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/{inst}/quilt-installer-{inst}.jar", jar)
        lv = lv or json.loads(http_get("https://meta.quiltmc.org/v3/versions/loader"))[0]["version"]
        run([java_for_installer(mc, dest), "-jar", jar, "install", "server", mc, lv, "--download-server", "--install-dir=" + dest], dest)
    elif loader == "forge":
        ver = lv if "-" in (lv or "") else f"{mc}-{lv}"
        if not lv:
            raise InstallError("this pack does not state a Forge version")
        base = f"https://maven.minecraftforge.net/net/minecraftforge/forge/{ver}/forge-{ver}-installer.jar"
        jar = os.path.join(workdir, "forge-installer.jar")
        log(f"Forge {ver}")
        fetch(base, jar)
        run([java_for_installer(mc, dest), "-jar", jar, "--installServer"], dest)
    elif loader == "neoforge":
        if not lv:
            raise InstallError("this pack does not state a NeoForge version")
        jar = os.path.join(workdir, "neoforge-installer.jar")
        log(f"NeoForge {lv}")
        fetch(f"https://maven.neoforged.net/releases/net/neoforged/neoforge/{lv}/neoforge-{lv}-installer.jar", jar)
        run([java_for_installer(mc, dest), "-jar", jar, "--installServer"], dest)
    else:
        raise InstallError(f"unsupported loader: {loader}")


# ---------------------------------------------------------------- install orchestration

def remove_previous(dest):
    """Delete files a previous run of this installer put under mods/ or libraries/ (never anything else)."""
    marker = os.path.join(dest, ".ptero-modpack.json")
    if not os.path.isfile(marker):
        return
    try:
        with open(marker) as f:
            old = json.load(f).get("files", [])
    except (OSError, ValueError):
        return
    n = 0
    for rel in old:
        if rel.startswith(("mods/", "libraries/")):
            try:
                os.remove(os.path.join(dest, safe_rel(rel)))
                n += 1
            except (OSError, InstallError):
                pass
    if n:
        log(f"removed {n} files from the previous install")


def resolve(env, workdir, download=True):
    src = env.get("MODPACK_SOURCE", "").strip().lower()
    if not env.get("MODPACK_ID", "").strip():
        raise InstallError("MODPACK_ID is empty")
    if src == "modrinth":
        return resolve_modrinth(env, workdir)
    if src == "curseforge":
        return resolve_curseforge(env, workdir, download)
    if src == "url":
        return resolve_url(env, workdir)
    raise InstallError("MODPACK_SOURCE must be modrinth, curseforge or url")


def install(env, dest):
    os.makedirs(dest, exist_ok=True)
    # the download scratch goes on the server disk: the install container's /tmp is a 100 MB tmpfs (Wings tmpfs_size)
    with tempfile.TemporaryDirectory(prefix=".ptero-work-", dir=dest) as work:
        pack = resolve(env, work)
        log(f"pack: {pack.label} {pack.version} | Minecraft {pack.mc} | loader {pack.loader} {pack.loader_version or ''} | mods {pack.mods}")
        if env.get("MODPACK_MC_VERSION") and pack.mc and env["MODPACK_MC_VERSION"] != pack.mc:
            raise InstallError(f"the pack is for Minecraft {pack.mc}, not {env['MODPACK_MC_VERSION']}")
        remove_previous(dest)
        recorded = []
        record = recorded.append
        if pack.kind == "mrpack":
            apply_mrpack(pack, dest, record)
        elif pack.kind == "cf-manifest":
            apply_cf_manifest(env, pack, dest, record)
        else:
            apply_server_zip(pack, dest, record)
        launch = find_launch(dest)
        if launch is None:
            log("no bundled launcher found: installing the mod loader")
            if not pack.loader_version:
                pack.loader_version = env.get("LOADER_VERSION", "").strip() or None   # the pack does not state it: the owner may
            try:
                install_loader(pack, dest, work)
            finally:
                shutil.rmtree(os.path.join(dest, JRE_SCRATCH), ignore_errors=True)   # the temporary JRE is never kept
            launch = find_launch(dest)
        if launch is None:
            raise InstallError("the loader was installed but no launch file was found (unsupported layout)")
        for junk in glob.glob(os.path.join(dest, "*installer*.jar*")) + [os.path.join(dest, "installer.jar.log")]:
            if os.path.isfile(junk):
                os.remove(junk)
        with open(os.path.join(dest, "launch.args"), "w") as f:
            f.write(launch + "\n")
        props = os.path.join(dest, "server.properties")
        if not os.path.exists(props):   # safe defaults; the egg's config parser sets the port/ip at start
            with open(props, "w") as f:
                f.write("online-mode=true\nenable-rcon=false\nenable-command-block=false\n")
        with open(os.path.join(dest, ".ptero-modpack.json"), "w") as f:
            json.dump({"source": pack.source, "label": pack.label, "version": pack.version, "minecraft": pack.mc,
                       "loader": pack.loader, "loader_version": pack.loader_version, "launch": launch,
                       "files": sorted(set(recorded))}, f, indent=1)
        log(f"done. launch: java ... {launch} nogui")
        log(f"recommended Docker image: ghcr.io/pterodactyl/yolks:{java_for(pack.mc)}")
        log("the first start stops at the Minecraft EULA; the Panel asks the owner to accept it")


def probe(env):
    with tempfile.TemporaryDirectory(prefix="modpack-probe-") as work:
        src = env.get("MODPACK_SOURCE", "").strip().lower()
        if src == "curseforge":
            pack = resolve_curseforge(env, work, download=False)   # metadata only, no multi-hundred-MB download
        else:
            pack = resolve(env, work)
        return pack.summary()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dest", default=os.environ.get("SERVER_DIR", "/mnt/server"))
    ap.add_argument("--probe", action="store_true", help="print the pack's Minecraft/loader/Java as JSON and write nothing")
    a = ap.parse_args()
    env = dict(os.environ)
    try:
        if a.probe:
            print(json.dumps(probe(env)))
        else:
            install(env, a.dest)
    except InstallError as e:
        print(f"[modpack] ERROR: {e}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
